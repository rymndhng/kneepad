import Foundation
import HIDCore
import TouchEvents

// The driver loop, as a library.
//
// This used to live inside `touchd`'s main.swift, which meant the tuning app
// could only talk to it through a file on disk and a separate process the user
// had to remember to start. It is a library now so both front ends run the
// same code: the `touchd` command for a headless LaunchAgent, and the tuning
// app, which runs one of these for as long as its window is open.
//
// Nothing here prints or exits. Callers decide what to do with `onLog` and
// with a thrown error, because a terminal wants stdout and an app wants a
// label in its footer.

public enum DriverError: Error, CustomStringConvertible {
    case accessibilityDenied
    /// No digitizer found. Restated here rather than passed through as
    /// `SessionError` so a front end can report it without importing HIDCore.
    case deviceNotFound
    /// Another process holds the driver lock. The pid is whoever wrote the
    /// lock file, or nil if it could not be read.
    case alreadyRunning(pid: Int32?)

    public var description: String {
        switch self {
        case .accessibilityDenied:
            return "Accessibility permission is required to post events"
        case .deviceNotFound:
            return SessionError.noDigitizer.description
        case .alreadyRunning(let pid):
            return pid.map { "Another teach-touch driver is running (pid \($0))" }
                ?? "Another teach-touch driver is running"
        }
    }
}

public final class TouchDriver {

    public struct Options {
        public var pointer = PointerSynthesizer.Configuration()
        public var scroll = ScrollSynthesizer.Configuration()

        /// Tap-to-click, left button. Two-finger right click is a property of
        /// the recognizer; see `pointerRecognizer.twoFingerTapEnabled`.
        public var tapEnabled = true
        /// Set when the caller passed an explicit flag for tapping, so a live
        /// tuning reload does not quietly undo it.
        public var tapLocked = false

        /// Recognise but post nothing. Also skips the permission check, so the
        /// pipeline can be exercised without Accessibility granted.
        public var dryRun = false
        public var verbose = false
        public var collectStats = false

        /// Override for a unit whose sensor differs from the measured 40 mm.
        public var surfaceWidthMM: Double?

        public init() {}
    }

    // MARK: Callbacks

    /// Progress and diagnostics. A terminal prints these; an app can log them.
    public var onLog: ((String) -> Void)?
    /// Fired once the device is found and calibrated, before it is opened, so
    /// a caller can report what it is talking to.
    public var onDeviceReady: ((TouchSession) -> Void)?
    /// Fired when contacts start flowing.
    public var onReady: (() -> Void)?
    /// The device dropped back to mouse mode, reporting something unexpected.
    /// The driver puts it back on its own; this is for saying so.
    public var onForeignReport: ((UInt8) -> Void)?
    /// Fired when the driver's grip on the pad changes — lost, regained, or
    /// found in the wrong mode. See `Link`.
    public var onLinkChange: ((Link) -> Void)?

    // MARK: State

    /// Exposed so a caller can set tap limits before `start()` and read them
    /// back for a summary. Owned by the driver; do not swap it out.
    public let pointerRecognizer = PointerRecognizer()

    public private(set) var session: TouchSession?
    public private(set) var isRunning = false
    public private(set) var tapCount = 0
    public private(set) var scrollCount = 0

    public var options: Options

    /// Where the pointer is on the acceleration curve right now, for a UI in
    /// this process to plot.
    ///
    /// A stored value read at display rate rather than a callback fired per
    /// report: the frame handler has a 6.5 ms budget and publishes ~154 times a
    /// second, while nothing watching it needs more than 60. Writing a struct
    /// costs the handler nothing and cannot drag it into the watcher's work.
    public struct Motion {
        public var speed = 0.0
        public var pixelsPerMillimetre = 0.0
        public var contacts = 0
        /// Monotonic seconds, so a reader can tell a rested hand from a driver
        /// that has stopped reporting. See `TouchDriver.now`.
        public var at = 0.0

        public init() {}
    }

    public private(set) var motion = Motion()

    /// Monotonic seconds since boot. Only differences are meaningful.
    public static var now: Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    private let scrollRecognizer = ScrollRecognizer()
    private let pointerSynthesizer: PointerSynthesizer
    private let scrollSynthesizer: ScrollSynthesizer
    private var tracker: ContactTracker?
    private var lock: DriverLock?

    private var lastWall = Date()
    private var previousContactCount = 0
    private var stopped = false
    private var activity: NSObjectProtocol?

    private var watchdog: Timer?
    private var lastProbe = Date()
    private var lastReassert = 0.0

    public private(set) var stats = FeelStats()

    public init(options: Options = Options()) {
        self.options = options
        self.pointerSynthesizer = PointerSynthesizer(configuration: options.pointer)
        self.scrollSynthesizer = ScrollSynthesizer(configuration: options.scroll)
        self.pointerRecognizer.twoFingerTapEnabled = options.tapEnabled
    }

    public var pointerConfiguration: PointerSynthesizer.Configuration {
        get { pointerSynthesizer.configuration }
        set { pointerSynthesizer.configuration = newValue }
    }

    public var scrollConfiguration: ScrollSynthesizer.Configuration {
        get { scrollSynthesizer.configuration }
        set { scrollSynthesizer.configuration = newValue }
    }

    /// Apply a tuning snapshot to the live pipeline. Cheap enough to call on
    /// every slider tick — nothing here allocates or touches the device.
    public func apply(_ tuning: Tuning) {
        tuning.apply(to: &pointerSynthesizer.configuration)
        tuning.apply(to: &scrollSynthesizer.configuration)
        tuning.apply(to: pointerRecognizer)
        if !options.tapLocked { options.tapEnabled = tuning.tapEnabled }
    }

    // MARK: Lifecycle

    /// Find the pad, unlock multitouch and start streaming.
    ///
    /// Throws before touching the device if Accessibility is missing, because
    /// `CGEventPost` fails silently — a driver that has flipped the pad into
    /// multitouch mode and cannot post events leaves no working cursor at all.
    public func start() throws {
        precondition(!isRunning, "driver already started")

        if !options.dryRun && !ScrollSynthesizer.hasAccessibilityPermission() {
            throw DriverError.accessibilityDenied
        }

        // Before the device is touched, and before Input Mode is flipped: a
        // second driver that gets as far as unlocking multitouch and then backs
        // out has already taken the pad away from the first one.
        //
        // A dry run posts nothing and drives nothing, so it does not compete
        // for this — that is how the pipeline stays exercisable while the real
        // driver runs.
        if !options.dryRun {
            guard let held = DriverLock.acquire() else {
                throw DriverError.alreadyRunning(pid: DriverLock.holderPID())
            }
            lock = held
        }
        // Every failure below this point leaves the caller free to retry, and a
        // driver that is not running must not be sitting on the lock while it
        // waits for the board to be plugged in.
        defer { if !isRunning { lock = nil } }

        stopped = false
        try attach(firstTime: true)

        // Opt out of App Nap and timer coalescing for as long as we are
        // driving.
        //
        // This is the whole difference between the driver as a command and the
        // driver inside an app. A plain CLI is never napped; a GUI app whose
        // window is behind something else is exactly what App Nap targets, and
        // it throttles the process and coalesces its timers. The pointer
        // survives that better than scrolling does, because scrolling depends
        // on a 120 Hz momentum timer as well as on frames arriving on time —
        // coalescing that timer is felt directly as lag.
        //
        // `userInitiatedAllowingIdleSystemSleep` because the trackpad working
        // is not a reason to keep the machine awake; `latencyCritical` is what
        // asks for the timer precision.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "driving the trackpad")

        // After the pad is attached and streaming, so a start that throws on
        // the way here does not leave a session-wide event tap behind.
        if !options.dryRun, !pointerSynthesizer.startWatchingButtons() {
            log("could not watch mouse buttons — dragging with a button held "
                + "on another device may not register")
        }

        isRunning = true
        startWatchdog()
    }

    /// Find the pad, unlock multitouch, and start streaming from it.
    ///
    /// Split out of `start()` because the watchdog runs it again. Recovery has
    /// to be a fresh discovery rather than a retry on the handle we were
    /// holding: a pad that re-enumerates over sleep or a replug comes back as a
    /// different `IOHIDDevice`, with Input Mode reset to 0.
    private func attach(firstTime: Bool) throws {
        let session: TouchSession
        do {
            session = try TouchSession.discover()
        } catch SessionError.noDigitizer {
            throw DriverError.deviceNotFound
        }

        // The descriptor's claimed surface is already corrected at discovery
        // (see ZSA.measuredSurfaceWidthMM); this is only for a unit whose
        // sensor is a different size.
        if let trueWidth = options.surfaceWidthMM,
           let declared = session.layout.declaredSurfaceSize, declared.x > 0 {
            session.layout.positionScale = trueWidth / declared.x
            log(String(format: "Calibration   overriding %.0f mm with %.0f mm",
                       ZSA.measuredSurfaceWidthMM, trueWidth))
        }

        // The full summary is a startup thing. A reattach gets one line —
        // it happens every time the machine wakes, and it is the reattach
        // *count* that is interesting by then, not the pipeline again.
        if firstTime {
            onDeviceReady?(session)
        } else {
            log("pad back — \(session.device.info.summary)")
        }

        try session.open()
        do {
            try session.enableMultitouch(log: { [weak self] in self?.log($0) })
        } catch {
            // Let go of the device rather than leaving it open in a driver
            // that never started — a caller retrying would otherwise stack up
            // an open handle per attempt.
            session.stop()
            throw error
        }

        // Assigned only now that it is open and switched, so a failed attach
        // cannot leave the watchdog probing a handle we never got working.
        self.session = session
        tracker = ContactTracker(layout: session.layout)

        session.onFraming = { [weak self] _, _, _, _ in self?.onReady?() }
        session.onForeignReport = { [weak self] reportID, _ in
            guard let self else { return }
            self.onForeignReport?(reportID)
            // Report 6 is the mouse fallback: the pad has reset itself and has
            // stopped sending contacts. Put it back, rather than only saying
            // that it happened.
            self.reassertMultitouch(because: "report \(reportID)")
        }
        session.onFrame = { [weak self] frame, _ in self?.handle(frame) }

        lastWall = Date()
        lastProbe = Date()
        previousContactCount = 0
        setLink(.live)
        session.start()
    }

    /// Put the pad back in mouse mode and let go of it.
    ///
    /// Idempotent, and safe from a signal handler or an app terminating. Not
    /// calling this leaves the device in multitouch mode with nothing decoding
    /// it, which means no cursor until something restores it.
    public func stop() {
        guard !stopped else { return }
        stopped = true
        isRunning = false
        watchdog?.invalidate()
        watchdog = nil
        scrollSynthesizer.cancelMomentum()
        // Never leave a button stuck down for the rest of the login session.
        if !options.dryRun { pointerSynthesizer.releaseAll() }
        pointerSynthesizer.stopWatchingButtons()
        session?.restoreMouseMode(log: { [weak self] in self?.log($0) })
        session?.stop()
        motion = Motion()
        // Assigned, not `setLink`: a deliberate teardown is not a link event,
        // and firing one here made Ctrl-C report the pad as disconnected.
        link = .lost
        // Last, so the pad is back in mouse mode before anything else is let in.
        lock = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    // MARK: Staying attached

    /// How the driver's grip on the pad looks right now.
    public enum Link: Equatable {
        /// Open, in multitouch mode, frames expected.
        case live
        /// Present and answering, but in mouse mode, and the write to put it
        /// back was refused. Retried on every probe.
        case mouseMode
        /// Gone. Rediscovering on every probe.
        case lost
    }

    public private(set) var link: Link = .lost

    /// Seconds between health probes, and so the worst-case recovery delay.
    public var probeInterval = 2.0

    private func setLink(_ new: Link) {
        guard link != new else { return }
        link = new
        onLinkChange?(new)
    }

    /// Watch for the pad going away, because nothing else tells us.
    ///
    /// Discovery is one-shot and the frame callback is the only thing that
    /// would report otherwise — but the pad sends nothing at all while it is
    /// untouched, so silence is indistinguishable from an idle hand. Hence an
    /// active probe. Reading Input Mode back answers both questions at once: a
    /// read that throws means the handle is dead, and a read that returns 0
    /// means the pad reset itself and is in mouse mode. The same timer doubles
    /// as the wake detector — see `probe()`.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = Timer(timeInterval: probeInterval, repeats: true) { [weak self] _ in
            self?.probe()
        }
        // Common modes, for the same reason the HID source uses them: a probe
        // that only fires in the default mode stalls for as long as a menu is
        // open or a slider is held in the tuning app.
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func probe() {
        guard isRunning, !stopped else { return }

        // Timers do not fire while the machine is asleep, so an interval that
        // took far longer than it should have *is* the wake notification — no
        // AppKit, no power-source plumbing.
        let now = Date()
        let woke = now.timeIntervalSince(lastProbe) > 3 * probeInterval
        lastProbe = now

        // A wake does not probe, it re-initialises. The read below cannot see
        // every way this goes wrong: if IOKit stops delivering to our scheduled
        // source, Input Mode still reads back 3 while no frames arrive at all,
        // and a driver that reports itself healthy at a dead pad is the failure
        // this whole section exists to remove. Sleep is the likeliest moment for
        // that, and it is also the moment a brief re-init costs nothing.
        if woke, session != nil {
            log("woke after a gap — reattaching")
            detach(announce: false)
            recover()
            return
        }

        // A feature read is a synchronous control transfer on the same thread
        // the frame handler runs on, so never do one mid-gesture: it would land
        // inside the 6.5 ms frame budget. Frames stop the moment the last
        // finger lifts, so a fifth of a second of quiet is enough to be clear.
        if session != nil, TouchDriver.now - motion.at < 0.2 { return }

        guard let session else { recover(); return }

        do {
            let echo = try session.device.getFeature(
                reportID: session.inputModeReportID,
                bodyLength: session.inputModeBodyLength)
            if echo.body.first == ZSA.inputModeMultitouch {
                setLink(.live)
            } else {
                // Answering, but in mouse mode: a reset that did not
                // re-enumerate, so the handle is still good and a re-write is
                // the whole fix. Already rate-limited by the probe interval.
                reassertMultitouch(
                    because: "Input Mode read back as "
                        + (echo.body.first.map(String.init) ?? "nothing"),
                    force: true)
            }
        } catch {
            // The handle is dead — unplugged, or re-enumerated over sleep.
            log("lost the pad (\(error)) — rediscovering")
            detach()
            recover()
        }
    }

    /// Attach again. Quiet about failure: the pad may simply still be
    /// unplugged, and the next probe will try again.
    private func recover() {
        do { try attach(firstTime: false) } catch { setLink(.lost) }
    }

    /// Let go of the device.
    ///
    /// Deliberately does not restore mouse mode: in the case this exists for the
    /// handle is dead, so the write would fail anyway, and the pad has already
    /// reset itself — that is how we noticed. What does matter is not leaving
    /// the *system* mid-gesture, with a button held or momentum still coasting,
    /// and not carrying a half-finished tap across the gap into the next
    /// session.
    ///
    /// `announce: false` for the wake path, which detaches and reattaches in
    /// one tick: reporting a disconnection every time the machine wakes would
    /// be alarming and, if the reattach works, untrue.
    private func detach(announce: Bool = true) {
        scrollSynthesizer.cancelMomentum()
        if !options.dryRun { pointerSynthesizer.releaseAll() }
        pointerSynthesizer.resync()
        pointerRecognizer.reset()
        session?.stop()
        session = nil
        tracker = nil
        previousContactCount = 0
        motion = Motion()
        if announce { setLink(.lost) }
    }

    /// Put the pad back into multitouch after it has reset itself.
    ///
    /// Throttled, because the mouse-mode fallback *streams* reports and a
    /// control transfer per report would be both pointless and slow. Callers
    /// that are already rate-limited pass `force`.
    private func reassertMultitouch(because reason: String, force: Bool = false) {
        guard let session, isRunning, !stopped else { return }
        let now = TouchDriver.now
        guard force || now - lastReassert > 1 else { return }
        lastReassert = now
        log("\(reason) — re-asserting multitouch")
        if session.setInputMode(ZSA.inputModeMultitouch,
                                log: { [weak self] in self?.log($0) }) {
            setLink(.live)
        } else {
            setLink(.mouseMode)
        }
    }

    public var idChurnDetected: Bool { tracker?.idChurnDetected ?? false }

    // MARK: Health

    /// Whether frames are arriving, and being handled, on time.
    ///
    /// Always collected — unlike the `--stats` measurements, which sample
    /// positions too. It costs two clock reads and a ring append per frame,
    /// and it is the difference between "scrolling feels laggy" being a guess
    /// and being a reading: a rate well under the nominal ~154 Hz means frames
    /// are not reaching us (scheduling, App Nap, USB), while a handler time
    /// approaching the frame budget means we are the ones falling behind.
    public struct Health {
        public let reportRateHz: Double
        /// Longest gap between frames in the window. Spikes read as stutter.
        public let worstGapMs: Double
        /// Longest time spent inside the frame handler.
        public let worstHandlerMs: Double
        /// Frames arriving late enough to be felt, against the median rate.
        public var isStalling: Bool {
            reportRateHz > 0 && worstGapMs > 3 * (1000 / reportRateHz)
        }
    }

    /// `interval` is nil for the first frame of a touch, where the gap since
    /// the last one is however long you left the pad alone.
    private var recent: [(at: Double, interval: Double?, handler: Double)] = []

    public func health(window seconds: Double = 1.5) -> Health? {
        let cutoff = TouchDriver.now - seconds
        let samples = recent.filter { $0.at >= cutoff }
        let gaps = samples.compactMap(\.interval)
        guard gaps.count > 5 else { return nil }
        let total = gaps.reduce(0, +)
        guard total > 0 else { return nil }
        // Rate over the frames themselves, not over the window: a window that
        // is half idle would otherwise halve the apparent rate.
        return Health(reportRateHz: Double(gaps.count) / total,
                      worstGapMs: (gaps.max() ?? 0) * 1000,
                      worstHandlerMs: (samples.map(\.handler).max() ?? 0) * 1000)
    }

    private func record(interval: Double?, handler: Double) {
        let now = TouchDriver.now
        recent.append((at: now, interval: interval, handler: handler))
        // Two seconds of frames is ~310 at the nominal rate. Trimming in one
        // slice rather than per element keeps this off the frame budget.
        if recent.count > 512 {
            let cutoff = now - 2
            if let keep = recent.firstIndex(where: { $0.at >= cutoff }), keep > 0 {
                recent.removeFirst(keep)
            } else if recent.count > 1024 {
                recent.removeFirst(recent.count - 512)
            }
        }
    }

    private func log(_ message: String) { onLog?(message) }

    // MARK: Frame handling

    private func handle(_ frame: Frame) {
        guard let tracker else { return }
        let handlerStart = DispatchTime.now()
        let now = Date()
        let wall = now.timeIntervalSince(lastWall)
        lastWall = now
        // Health is about *arrival*, so it uses the wall clock rather than the
        // tracker's delta — that one comes from the device's own Scan Time,
        // which by design cannot show a frame reaching us late.
        //
        // Only gaps within a touch count: the pad stops reporting between
        // gestures, so the first frame of a touch otherwise carries however
        // long you left the pad alone. Two guards, because the contact-count
        // one is not sufficient on its own — in practice this still reported
        // the whole idle pause once, which means the last frame of a gesture
        // does not always arrive with its contacts cleared. Unexplained; the
        // ceiling covers it. Nothing between 250 ms and a pause is a *lag*
        // question anyway, and the numbers this line exists to tell apart are
        // 6 ms and 30 ms.
        let arrival: Double? = (previousContactCount > 0 && wall < 0.25) ? wall : nil

        tracker.update(frame, wallClockDelta: wall)
        let dt = tracker.lastDelta
        let tracks = tracker.active

        if options.collectStats {
            stats.record(interval: dt)
            // Sample jitter only when one finger is down and barely moving.
            if let raw = frame.contacts.first, frame.contacts.count == 1,
               let filtered = tracks.first, filtered.velocity.magnitude < 2.0 {
                stats.recordStill(raw: raw.position, filtered: filtered.position)
            }
        }

        // A genuinely new touch stops coasting. Keyed to the 0 → N transition:
        // two fingers never lift on the same frame, so "any contact present"
        // would let the straggler cancel the momentum it just started.
        if previousContactCount == 0 && !frame.contacts.isEmpty {
            scrollSynthesizer.cancelMomentum()
        }
        // With no fingers down, drop our cursor belief so the next touch picks
        // up wherever the pointer actually is — something else may have moved
        // it in the meantime.
        if frame.contacts.isEmpty && previousContactCount != 0 {
            pointerSynthesizer.resync()
        }
        previousContactCount = frame.contacts.count

        // Scroll first — it owns two-finger input, and the pointer recognizer
        // suppresses itself for any sequence that ever had two fingers down.
        if let update = scrollRecognizer.update(tracks: tracks, dt: dt) {
            if !options.dryRun { scrollSynthesizer.handle(update) }
            if case .began = update.phase {
                scrollCount += 1
                if options.verbose { log("scroll began") }
            }
        }

        let previousRejection = pointerRecognizer.lastTapRejection
        let pointerEvents = pointerRecognizer.update(tracks: tracks,
                                                     buttons: frame.buttons, dt: dt)
        // A tap that does nothing looks identical to one that was never seen,
        // so say why. Only on change, or a resting hand would spam the log.
        if options.verbose, let reason = pointerRecognizer.lastTapRejection,
           reason != previousRejection {
            log("no tap: \(reason)")
        }

        // Record before filtering, so the panel shows the speed the curve sees
        // even for motion the stop gate is about to drop.
        var speed = 0.0
        for case .move(let millimetres) in pointerEvents where dt > 0 {
            speed = millimetres.magnitude / dt
        }
        var sample = Motion()
        sample.speed = speed
        sample.pixelsPerMillimetre =
            pointerSynthesizer.configuration.pixelsPerMillimetre(atSpeed: speed)
        sample.contacts = tracks.count
        sample.at = TouchDriver.now
        motion = sample

        for event in pointerEvents {
            // Filter before synthesising, not after — otherwise disabling taps
            // only silences the log line while still clicking.
            if case .tap = event, !options.tapEnabled { continue }

            if !options.dryRun { pointerSynthesizer.handle(event, dt: dt) }

            switch event {
            case .tap(let button, let count):
                tapCount += 1
                if options.verbose { log("tap \(button) ×\(count)") }
            case .buttonChanged(let button, let down):
                if options.verbose { log("button \(button) \(down ? "down" : "up")") }
            case .move:
                break
            }
        }

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds
            - handlerStart.uptimeNanoseconds) / 1_000_000_000
        record(interval: arrival, handler: elapsed)
        if options.collectStats { stats.record(handler: elapsed) }
    }
}

/// Measurements for `--stats`. Report rate caps how smooth anything can be,
/// and stationary jitter is what a position filter would have to suppress.
public struct FeelStats {
    public var intervals: [Double] = []
    /// Time spent inside the frame handler. If this approaches the report
    /// interval, processing falls behind during movement and drains after —
    /// felt as lag that outlasts the finger.
    public var handlerTimes: [Double] = []
    /// Raw positions captured while a single finger was essentially still.
    public var stillRaw: [Point] = []
    public var stillFiltered: [Point] = []

    public init() {}

    public mutating func record(interval: Double) {
        guard interval > 0, interval < 1 else { return }
        intervals.append(interval)
        if intervals.count > 4000 { intervals.removeFirst() }
    }

    public mutating func record(handler seconds: Double) {
        handlerTimes.append(seconds)
        if handlerTimes.count > 4000 { handlerTimes.removeFirst() }
    }

    public mutating func recordStill(raw: Point, filtered: Point) {
        stillRaw.append(raw)
        stillFiltered.append(filtered)
        if stillRaw.count > 2000 {
            stillRaw.removeFirst()
            stillFiltered.removeFirst()
        }
    }

    public static func spread(_ points: [Point]) -> Double {
        guard points.count > 2 else { return 0 }
        let n = Double(points.count)
        let mx = points.reduce(0.0) { $0 + $1.x } / n
        let my = points.reduce(0.0) { $0 + $1.y } / n
        let variance = points.reduce(0.0) {
            $0 + ($1.x - mx) * ($1.x - mx) + ($1.y - my) * ($1.y - my)
        } / n
        return variance.squareRoot()
    }

    /// Rendered as lines of text so the caller decides where they go.
    public func report() -> [String] {
        guard !intervals.isEmpty else { return ["No reports measured."] }
        let sorted = intervals.sorted()
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        let median = sorted[sorted.count / 2]
        let p99 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]

        var lines = ["── feel measurements ───────────────────────────────"]
        lines.append(String(format: "  report rate    %.0f Hz mean, %.0f Hz median",
                            1 / mean, 1 / median))
        lines.append(String(format: "  worst gap      %.1f ms (p99)  — spikes read as stutter",
                            p99 * 1000))
        if !handlerTimes.isEmpty {
            let h = handlerTimes.sorted()
            let hmean = handlerTimes.reduce(0, +) / Double(handlerTimes.count)
            let hp99 = h[min(h.count - 1, Int(Double(h.count) * 0.99))]
            let budget = median * 1000
            lines.append(String(format: "  handler time   %.2f ms mean, %.2f ms p99  (budget %.1f ms)",
                                hmean * 1000, hp99 * 1000, budget))
            if hp99 * 1000 > budget * 0.5 {
                lines.append("                 ⚠️  over half the frame budget — processing")
                lines.append("                     will fall behind during fast movement")
            }
        }
        lines.append(String(format: "  jitter raw     %.4f mm", FeelStats.spread(stillRaw)))
        lines.append(String(format: "  jitter filtered %.4f mm  (%d samples while still)",
                            FeelStats.spread(stillFiltered), stillFiltered.count))
        if !stillRaw.isEmpty && !stillFiltered.isEmpty {
            let before = FeelStats.spread(stillRaw)
            let after = FeelStats.spread(stillFiltered)
            if before > 0 {
                lines.append(String(format: "  noise removed  %.0f%%", (1 - after / before) * 100))
            }
        }
        return lines
    }
}
