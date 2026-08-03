import Foundation
import HIDCore
import TouchEvents

// teach-touch daemon — Stages 3 + 4 together.
//
// One finger moves the cursor and taps click; two fingers scroll. This is the
// first build that replaces everything mouse mode used to do, so the trackpad
// stays usable for the whole time it runs.

func printUsage() {
    print("""
    touchd — pointer and scrolling for the ZSA trackpad

    USAGE
      touchd                        run the driver
      touchd --pointer-gain N       cursor px per mm (default 12)
      touchd --scroll-gain N        scroll px per mm (default 32)
      touchd --friction N           per-tick friction (derived from --decay)
      touchd --flick N              mm/s release speed for momentum (default 2)
      touchd --accel-max N          multiplier ceiling, fast movement (default 3.2)
      touchd --accel-min N          multiplier floor, slow movement (default 0.6)
      touchd --accel-curve N        steepness above the knee (default 1.1)
      touchd --accel-ref N          mm/s where the multiplier is exactly 1 (170)
                                    lower = smaller flat zone, earlier accel
      touchd --no-accel             disable pointer acceleration
      touchd --decay N              momentum decay time constant (default 0.27s)
      touchd --no-momentum          disable inertial scrolling
      touchd --no-tap               disable tap-to-click
      touchd --no-right-tap         two-finger tap does not right click
      touchd --tap-time N           tap max duration (default 0.4s)
      touchd --tap-travel N         tap max travel (default 2mm)
      touchd --two-tap-time N       two-finger tap max duration (default 0.6s)
      touchd --two-tap-travel N     two-finger tap max travel (default 4mm)
      touchd --double-tap-time N    max gap between paired taps (default 0.4s)
      touchd --double-tap-dist N    how far apart paired taps may land (8mm)
      touchd --surface N            true pad width in mm, if the descriptor lies
      touchd --no-live              ignore the tuning file; use flags only
      touchd --reverse              invert scroll direction

      Two-finger tap not registering? Run --verbose; it prints why each
      touch failed to qualify, then raise whichever limit it names.

    STOPPING (cutting the firmware's deceleration tail)
      touchd --hard-stop            aggressive stop gate preset
      touchd --stop-speed N         mm/s below which a decaying move is tail (60)
      touchd --arm-speed N          mm/s the finger must reach first (120)
      touchd --no-stop-gate         let the tail through

      Cursor glides on after you stop   → --hard-stop, or raise --stop-speed
      Cursor stops while still moving   → lower --stop-speed, or --no-stop-gate

      The gate cannot remove lag *during* movement — it only drops the tail
      after it. That lag is the firmware's own low-pass, and nothing in
      userland removes it: lead compensation was tried and measured to do
      nothing at any setting that did not also add visible noise.

    POSITIONS
      touchd --minimal              strip the stop gate and acceleration too;
                                    raw delta x gain, nothing else

      Contact positions are used exactly as the device reports them.
      A 1€ filter and lead compensation both used to sit here; both were
      measured to do nothing useful on this hardware and deleted. See
      plan/README.md before adding either back.

      touchd --verbose              log recognised gestures
      touchd --stats                report rate and jitter measurements
      touchd --dry-run              recognise but post nothing

    Needs Input Monitoring (to read the pad) and Accessibility (to post
    events). Ctrl-C restores mouse mode.
    """)
}

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--help") || args.contains("-h") { printUsage(); exit(0) }

func value(_ flag: String) -> Double? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return Double(args[i + 1])
}

// Saved tuning underlies every default; command-line flags still override it,
// and the `tuner` app rewrites this file live while the daemon runs.
let liveTuning = args.contains("--no-live") ? nil : Tuning.load()

let verbose = args.contains("--verbose")
let dryRun = args.contains("--dry-run")
let tapEnabled = !args.contains("--no-tap")
// Separable from tap-to-click: right-clicking by two-finger tap is the part
// people most often want off on its own, because it can fire during scrolls.
let rightTapEnabled = tapEnabled && !args.contains("--no-right-tap")
// Built here rather than beside the rest of the pipeline so the startup
// summary can print its real values instead of restating the defaults, which
// is how the summary came to disagree with the code once already.
let pointerRecognizer = PointerRecognizer()
liveTuning?.apply(to: pointerRecognizer)
if args.contains("--no-tap") || args.contains("--no-right-tap") {
    pointerRecognizer.twoFingerTapEnabled = rightTapEnabled
}
if let t = value("--tap-time") { pointerRecognizer.tapMaxDuration = t }
if let d = value("--tap-travel") { pointerRecognizer.tapMaxTravel = d }
if let t = value("--two-tap-time") { pointerRecognizer.twoFingerTapMaxDuration = t }
if let d = value("--two-tap-travel") { pointerRecognizer.twoFingerTapMaxTravel = d }
if let t = value("--double-tap-time") { pointerRecognizer.doubleTapInterval = t }
if let d = value("--double-tap-dist") { pointerRecognizer.doubleTapMaxDistance = d }

let showStats = args.contains("--stats")

/// Set by `--surface`; the scroll recognizer is built later and its own
/// millimetre thresholds have to move with the corrected scale too.
var scrollRecognizerScale = 1.0

var scrollConfig = ScrollSynthesizer.Configuration()
liveTuning?.apply(to: &scrollConfig)
if let g = value("--scroll-gain") { scrollConfig.gain = g }
if let t = value("--flick") { scrollConfig.momentumThreshold = t }
if let d = value("--decay") { scrollConfig.momentumDecayTime = d }
if let f = value("--friction") { scrollConfig.friction = f }   // after momentumHz
if args.contains("--reverse") { scrollConfig.naturalDirection = false }
if args.contains("--no-momentum") { scrollConfig.momentumEnabled = false }

var pointerConfig = PointerSynthesizer.Configuration()
liveTuning?.apply(to: &pointerConfig)
if let g = value("--pointer-gain") { pointerConfig.gain = g }
if let a = value("--accel-max") { pointerConfig.maxAcceleration = a }
if let a = value("--accel-min") { pointerConfig.minAcceleration = a }
if let c = value("--accel-curve") { pointerConfig.accelerationCurve = c }
if let r = value("--accel-ref") { pointerConfig.accelerationReference = r }
if args.contains("--no-accel") { pointerConfig.accelerationEnabled = false }
if let s = value("--stop-speed") { pointerConfig.stopGate.stopSpeed = s }
if let s = value("--arm-speed") { pointerConfig.stopGate.armSpeed = s }
if args.contains("--no-stop-gate") { pointerConfig.stopGate.enabled = false }

// Strip the pipeline back to raw delta x gain. Every transform below was
// added to fix a specific symptom, and stacked they are hard to reason about;
// this is the baseline to build back up from, one stage at a time.
let minimal = args.contains("--minimal")
if minimal {
    pointerConfig.accelerationEnabled = false
    pointerConfig.stopGate.enabled = false
}


// One switch for "make it stop when I stop".
//
// Purely a gate preset. It cannot cut the whole tail — a tail is only
// recognisable once it has begun arriving — so some is always emitted.
//
// It used to also raise lead compensation, on the theory that the two attack
// the same lag from opposite sides. Lead has since been deleted outright: at
// the only setting that felt right it advanced motion by a quarter of a frame,
// 1.6ms, while still amplifying noise. The gate does all of this work.
if args.contains("--hard-stop") {
    pointerConfig.stopGate.makeAggressive()
    if let s = value("--stop-speed") { pointerConfig.stopGate.stopSpeed = s }
    if let s = value("--arm-speed") { pointerConfig.stopGate.armSpeed = s }
}

// MARK: - Permissions

if !dryRun && !ScrollSynthesizer.hasAccessibilityPermission() {
    print("""
    Accessibility permission is required to post events.

    Without it CGEventPost silently does nothing. Grant it to your terminal:
      System Settings ▸ Privacy & Security ▸ Accessibility

    Requesting now — approve, then re-run.
    """)
    _ = ScrollSynthesizer.hasAccessibilityPermission(prompt: true)
    exit(1)
}

// MARK: - Device

let session: TouchSession
do {
    session = try TouchSession.discover()
} catch {
    print("\(error)"); exit(1)
}

// MARK: - Surface calibration
//
// The descriptor's physical range is a claim, not a measurement — PTP
// descriptors get copied between projects, so it can be inherited boilerplate.
// When it is wrong, every millimetre downstream is wrong by the same factor.
// Everything stays self-consistent, which is why tuning by feel still
// converges; it converges on numbers whose units are a lie.
//
// Correcting it rescales positions, so the defaults — all tuned against the
// old scale — have to move with it or the feel changes. Speeds and lengths
// scale with the surface; gains, being px per mm, scale inversely. A value the
// user set explicitly is left alone, detected by it still differing from the
// pristine default.
if let trueWidth = value("--surface"),
   let declared = session.layout.declaredSurfaceSize, declared.x > 0 {
    let scale = trueWidth / declared.x
    session.layout.positionScale = scale

    let p = PointerSynthesizer.Configuration()
    let s = ScrollSynthesizer.Configuration()
    let r = PointerRecognizer()

    // px per mm — inverse.
    if pointerConfig.gain == p.gain { pointerConfig.gain /= scale }
    if scrollConfig.gain == s.gain { scrollConfig.gain /= scale }

    // mm/s.
    if pointerConfig.accelerationReference == p.accelerationReference {
        pointerConfig.accelerationReference *= scale
    }
    if pointerConfig.stopGate.armSpeed == p.stopGate.armSpeed {
        pointerConfig.stopGate.armSpeed *= scale
    }
    if pointerConfig.stopGate.stopSpeed == p.stopGate.stopSpeed {
        pointerConfig.stopGate.stopSpeed *= scale
    }
    pointerConfig.stopGate.reawakenDelta *= scale
    if scrollConfig.momentumThreshold == s.momentumThreshold {
        scrollConfig.momentumThreshold *= scale
    }

    // mm.
    if pointerRecognizer.tapMaxTravel == r.tapMaxTravel {
        pointerRecognizer.tapMaxTravel *= scale
    }
    if pointerRecognizer.twoFingerTapMaxTravel == r.twoFingerTapMaxTravel {
        pointerRecognizer.twoFingerTapMaxTravel *= scale
    }
    if pointerRecognizer.doubleTapMaxDistance == r.doubleTapMaxDistance {
        pointerRecognizer.doubleTapMaxDistance *= scale
    }

    scrollRecognizerScale = scale

    print(String(format: "Calibration   descriptor claims %.0f mm, measured %.0f mm → ×%.3f",
                 declared.x, trueWidth, scale))
}

print("Device        \(session.device.info.summary)")
if let size = session.layout.surfaceSize {
    print(String(format: "Surface       %.1f × %.1f mm, %d contacts",
                 size.x, size.y, session.layout.maxContacts))
}
// Spell out exactly what sits between the hardware and the cursor. Stacked
// transforms are the main reason the feel became hard to reason about.
func stage(_ name: String, _ on: Bool, _ detail: String) {
    print("              \(on ? "→" : "·") \(name.padding(toLength: 20, withPad: " ", startingAt: 0))"
        + (on ? detail : "off"))
}
print("Pipeline      raw report from device")
stage("acceleration", pointerConfig.accelerationEnabled,
      String(format: "×%.2f–%.2f, curve %.2f, ref %.0f mm/s",
             pointerConfig.minAcceleration, pointerConfig.maxAcceleration,
             pointerConfig.accelerationCurve, pointerConfig.accelerationReference))
stage("stop gate", pointerConfig.stopGate.enabled,
      String(format: "cut below %.0f mm/s, armed above %.0f",
             pointerConfig.stopGate.stopSpeed, pointerConfig.stopGate.armSpeed))
print(String(format: "              → %@%.0f px/mm",
             "gain                ", pointerConfig.gain))
print("              → CGEventPost")
if minimal && !pointerConfig.stopGate.enabled && !pointerConfig.accelerationEnabled {
    print("              (--minimal: raw delta × gain only)")
}
print()
print(String(format: "Scroll        %.0f px/mm, %@, decay %.2fs",
             scrollConfig.gain,
             scrollConfig.naturalDirection ? "natural" : "reversed",
             scrollConfig.momentumDecayTime))
// Times in seconds, matching the unit the flags take. Printing ms here once
// invited passing 500 back in, which parses as a 500-second window.
if tapEnabled {
    print(String(format: "Tap to click  left, max %.2fs and %.1f mm",
                 pointerRecognizer.tapMaxDuration, pointerRecognizer.tapMaxTravel))
    print(String(format: "Two-finger    %@",
                 rightTapEnabled
                     ? String(format: "right click, max %.2fs and %.1f mm",
                              pointerRecognizer.twoFingerTapMaxDuration,
                              pointerRecognizer.twoFingerTapMaxTravel)
                     : "right click off"))
    print(String(format: "Double click  within %.2fs of the last tap lifting, %.1f mm",
                 pointerRecognizer.doubleTapInterval,
                 pointerRecognizer.doubleTapMaxDistance))
} else {
    print("Tap to click  off")
}
if dryRun { print("Dry run       recognising only, posting nothing") }
print()

do {
    try session.open()
} catch {
    print("""
    \(error)

    If this is a permissions failure, grant Input Monitoring to your terminal:
      System Settings ▸ Privacy & Security ▸ Input Monitoring
    """)
    exit(1)
}

func log(_ message: String) { print("  \(message)") }

print("Switching to multitouch (Input Mode = \(ZSA.inputModeMultitouch))…")
do {
    try session.enableMultitouch(log: log)
} catch {
    print("  \(error)"); session.stop(); exit(1)
}

// MARK: - Pipeline

let tracker = ContactTracker(layout: session.layout)
let scrollRecognizer = ScrollRecognizer()
if scrollRecognizerScale != 1.0 {
    scrollRecognizer.activationDistance *= scrollRecognizerScale
    scrollRecognizer.stopFrameTravel *= scrollRecognizerScale
}
let scrollSynthesizer = ScrollSynthesizer(configuration: scrollConfig)
let pointerSynthesizer = PointerSynthesizer(configuration: pointerConfig)

var restoring = false
func restoreAndExit(_ code: Int32) -> Never {
    guard !restoring else { exit(code) }
    restoring = true
    scrollSynthesizer.cancelMomentum()
    // Never leave a button stuck down for the rest of the session.
    if !dryRun { pointerSynthesizer.releaseAll() }
    print("\nRestoring mouse mode…")
    session.restoreMouseMode(log: log)
    session.stop()
    exit(code)
}

signal(SIGINT, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler { restoreAndExit(0) }
sigintSource.resume()

// SIGTERM matters once this runs as a LaunchAgent.
signal(SIGTERM, SIG_IGN)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler { restoreAndExit(0) }
sigtermSource.resume()

var lastWall = Date()
var previousContactCount = 0
var taps = 0
var scrolls = 0

/// Measurements for --stats. Report rate caps how smooth anything can be, and
/// stationary jitter is what the 1€ filter has to suppress.
struct FeelStats {
    var intervals: [Double] = []
    /// Time spent inside the frame handler. If this approaches the report
    /// interval, processing falls behind during movement and drains after —
    /// felt as lag that outlasts the finger.
    var handlerTimes: [Double] = []
    /// Raw positions captured while a single finger was essentially still.
    var stillRaw: [Point] = []
    var stillFiltered: [Point] = []

    mutating func record(interval: Double) {
        guard interval > 0, interval < 1 else { return }
        intervals.append(interval)
        if intervals.count > 4000 { intervals.removeFirst() }
    }

    mutating func record(handler seconds: Double) {
        handlerTimes.append(seconds)
        if handlerTimes.count > 4000 { handlerTimes.removeFirst() }
    }

    static func spread(_ points: [Point]) -> Double {
        guard points.count > 2 else { return 0 }
        let n = Double(points.count)
        let mx = points.reduce(0.0) { $0 + $1.x } / n
        let my = points.reduce(0.0) { $0 + $1.y } / n
        let variance = points.reduce(0.0) {
            $0 + ($1.x - mx) * ($1.x - mx) + ($1.y - my) * ($1.y - my)
        } / n
        return variance.squareRoot()
    }

    func report() {
        guard !intervals.isEmpty else { print("\nNo reports measured."); return }
        let sorted = intervals.sorted()
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        let median = sorted[sorted.count / 2]
        let p99 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]

        print("\n── feel measurements ───────────────────────────────")
        print(String(format: "  report rate    %.0f Hz mean, %.0f Hz median",
                     1 / mean, 1 / median))
        print(String(format: "  worst gap      %.1f ms (p99)  — spikes read as stutter",
                     p99 * 1000))
        if !handlerTimes.isEmpty {
            let h = handlerTimes.sorted()
            let hmean = handlerTimes.reduce(0, +) / Double(handlerTimes.count)
            let hp99 = h[min(h.count - 1, Int(Double(h.count) * 0.99))]
            let budget = median * 1000
            print(String(format: "  handler time   %.2f ms mean, %.2f ms p99  (budget %.1f ms)",
                         hmean * 1000, hp99 * 1000, budget))
            if hp99 * 1000 > budget * 0.5 {
                print("                 ⚠️  over half the frame budget — processing")
                print("                     will fall behind during fast movement")
            }
        }
        print(String(format: "  jitter raw     %.4f mm", FeelStats.spread(stillRaw)))
        print(String(format: "  jitter filtered %.4f mm  (%d samples while still)",
                     FeelStats.spread(stillFiltered), stillFiltered.count))
        if !stillRaw.isEmpty && !stillFiltered.isEmpty {
            let before = FeelStats.spread(stillRaw)
            let after = FeelStats.spread(stillFiltered)
            if before > 0 {
                print(String(format: "  noise removed  %.0f%%", (1 - after / before) * 100))
            }
        }
    }
}
var stats = FeelStats()

session.onFraming = { _, _, _, _ in
    print("\nReady. One finger moves, tap clicks, two fingers scroll.")
    print("Ctrl-C to stop and restore mouse mode.\n")
}

session.onForeignReport = { reportID, _ in
    print("⚠️  report \(reportID) — device fell back to mouse mode")
}

session.onFrame = { frame, _ in
    let handlerStart = showStats ? DispatchTime.now() : nil
    let now = Date()
    let wall = now.timeIntervalSince(lastWall)
    lastWall = now

    tracker.update(frame, wallClockDelta: wall)
    let dt = tracker.lastDelta
    let tracks = tracker.active

    if showStats {
        stats.record(interval: dt)
        // Sample jitter only when one finger is down and barely moving, which
        // is the condition the filter is meant to clean up.
        if let raw = frame.contacts.first, frame.contacts.count == 1,
           let filtered = tracks.first, filtered.velocity.magnitude < 2.0 {
            stats.stillRaw.append(raw.position)
            stats.stillFiltered.append(filtered.position)
            if stats.stillRaw.count > 2000 {
                stats.stillRaw.removeFirst()
                stats.stillFiltered.removeFirst()
            }
        }
    }

    // A genuinely new touch stops coasting. Keyed to the 0 → N transition:
    // two fingers never lift on the same frame, so "any contact present" would
    // let the straggler cancel the momentum it just started.
    if previousContactCount == 0 && !frame.contacts.isEmpty {
        scrollSynthesizer.cancelMomentum()
    }
    // With no fingers down, drop our cursor belief so the next touch picks up
    // wherever the pointer actually is — it may have been moved by something
    // else in the meantime.
    if frame.contacts.isEmpty && previousContactCount != 0 {
        pointerSynthesizer.resync()
    }
    previousContactCount = frame.contacts.count

    // Scroll first — it owns two-finger input, and the pointer recognizer
    // suppresses itself for any sequence that ever had two fingers down.
    if let update = scrollRecognizer.update(tracks: tracks, dt: dt) {
        if !dryRun { scrollSynthesizer.handle(update) }
        if verbose, case .began = update.phase {
            scrolls += 1
            print("scroll began")
        }
    }

    let previousRejection = pointerRecognizer.lastTapRejection
    let pointerEvents = pointerRecognizer.update(tracks: tracks, buttons: frame.buttons, dt: dt)
    // A tap that does nothing looks identical to one that was never seen, so
    // say why. Only on change, or a resting hand would spam the log.
    if verbose, let reason = pointerRecognizer.lastTapRejection, reason != previousRejection {
        print("no tap: \(reason)")
    }

    for event in pointerEvents {
        // Filter before synthesising, not after — otherwise --no-tap only
        // silences the log line while still clicking.
        if case .tap = event, !tapEnabled { continue }

        if !dryRun { pointerSynthesizer.handle(event, dt: dt) }

        switch event {
        case .tap(let button, let count):
            taps += 1
            if verbose { print("tap \(button) ×\(count)") }
        case .buttonChanged(let button, let down):
            if verbose { print("button \(button) \(down ? "down" : "up")") }
        case .move:
            break
        }
    }

    if let handlerStart {
        let ns = DispatchTime.now().uptimeNanoseconds - handlerStart.uptimeNanoseconds
        stats.record(handler: Double(ns) / 1_000_000_000)
    }
}

// Live tuning: the `tuner` app rewrites the file, and the change lands without
// restarting. Handlers run on the main queue, which is where the HID callback
// runs too, so no locking is needed around the synthesiser configs.
var watcher: TuningWatcher?
if !args.contains("--no-live") {
    let w = TuningWatcher { updated in
        updated.apply(to: &pointerSynthesizer.configuration)
        updated.apply(to: &scrollSynthesizer.configuration)
        updated.apply(to: pointerRecognizer)
        print(String(format: "  tuning reloaded — gain %.0f px/mm, flat to %.0f mm/s",
                     updated.pointerGain, updated.accelerationKnee))
    }
    w.start()
    watcher = w
    _ = watcher
}

session.start()

atexit {
    if showStats { stats.report() }
    if taps > 0 || scrolls > 0 { print("\(taps) taps, \(scrolls) scrolls") }
    if tracker.idChurnDetected {
        print("⚠️  hardware contact IDs were unstable during this run")
    }
}

CFRunLoopRun()
restoreAndExit(0)
