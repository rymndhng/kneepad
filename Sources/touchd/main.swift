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
      touchd --pointer-gain N       cursor px per mm (default 20)
      touchd --scroll-gain N        scroll px per mm (default 32)
      touchd --friction N           per-tick friction (derived from --decay)
      touchd --flick N              mm/s release speed for momentum (default 2)
      touchd --accel-max N          peak acceleration multiplier (default 3)
      touchd --accel-curve N        knee sharpness, 1=soft (default 1.8)
      touchd --accel-ref N          mm/s at the curve midpoint (default 150)
      touchd --no-accel             disable pointer acceleration
      touchd --decay N              momentum decay time constant (default 0.27s)
      touchd --no-momentum          disable inertial scrolling
      touchd --no-tap               disable tap-to-click
      touchd --reverse              invert scroll direction

    SMOOTHING (1€ filter over contact positions)
      touchd --cutoff N             Hz at rest; lower is steadier (default 1.2)
      touchd --beta N               speed coupling; higher is snappier (0.25)
      touchd --minimal              STRIP EVERYTHING: no filter, no lead, no
                                    acceleration. Raw delta x gain, nothing else.
                                    Start here when the feel is wrong.
      touchd --lead N               cancel firmware smoothing (default 1.0, 0=off)
      touchd --settle N             how hard a stop is snapped to (default 4)
      touchd --deadband N           mm treated as noise, not lag (default 0.25)
      touchd --no-smoothing         disable filtering entirely

      Jittery cursor when still  → lower --cutoff, or lower --beta
      Laggy when moving fast     → raise --beta
      Drifts on after you stop   → raise --lead (firmware smoothing)
      Overshoots / feels jumpy   → lower --lead

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

let verbose = args.contains("--verbose")
let dryRun = args.contains("--dry-run")
let tapEnabled = !args.contains("--no-tap")

let showStats = args.contains("--stats")

var scrollConfig = ScrollSynthesizer.Configuration()
if let g = value("--scroll-gain") { scrollConfig.gain = g }
if let t = value("--flick") { scrollConfig.momentumThreshold = t }
if let d = value("--decay") { scrollConfig.momentumDecayTime = d }
if let f = value("--friction") { scrollConfig.friction = f }   // after momentumHz
if args.contains("--reverse") { scrollConfig.naturalDirection = false }
if args.contains("--no-momentum") { scrollConfig.momentumEnabled = false }

var pointerConfig = PointerSynthesizer.Configuration()
if let g = value("--pointer-gain") { pointerConfig.gain = g }
if let a = value("--accel-max") { pointerConfig.maxAcceleration = a }
if let c = value("--accel-curve") { pointerConfig.accelerationCurve = c }
if let r = value("--accel-ref") { pointerConfig.accelerationReference = r }
if args.contains("--no-accel") { pointerConfig.accelerationEnabled = false }

// Strip the pipeline back to raw delta x gain. Every transform below was
// added to fix a specific symptom, and stacked they are hard to reason about;
// this is the baseline to build back up from, one stage at a time.
let minimal = args.contains("--minimal")
if minimal {
    pointerConfig.accelerationEnabled = false
}

var smoothing = SmoothingConfiguration()
if minimal {
    smoothing.enabled = false     // disables the 1€ filter AND lead compensation
    smoothing.leadGain = 0
}
if let c = value("--cutoff") { smoothing.minCutoff = c }
if let b = value("--beta") { smoothing.beta = b }
if let l = value("--lead") { smoothing.leadGain = l }
if let g = value("--settle") { smoothing.settleGain = g }
if let d = value("--deadband") { smoothing.settleDeadband = d }
if args.contains("--no-smoothing") { smoothing.enabled = false }

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
stage("lead compensation",
      smoothing.enabled && smoothing.leadGain > 0,
      String(format: "gain %.1f", smoothing.leadGain))
stage("1€ filter", smoothing.enabled,
      String(format: "cutoff %.2f Hz, beta %.3f, settle %.1f",
             smoothing.minCutoff, smoothing.beta, smoothing.settleGain))
stage("acceleration", pointerConfig.accelerationEnabled,
      String(format: "×%.1f, knee %.1f, ref %.0f mm/s",
             pointerConfig.maxAcceleration, pointerConfig.accelerationCurve,
             pointerConfig.accelerationReference))
print(String(format: "              → %@%.0f px/mm",
             "gain                ", pointerConfig.gain))
print("              → CGEventPost")
if minimal { print("              (--minimal: raw delta × gain only)") }
print()
print(String(format: "Scroll        %.0f px/mm, %@, decay %.2fs",
             scrollConfig.gain,
             scrollConfig.naturalDirection ? "natural" : "reversed",
             scrollConfig.momentumDecayTime))
print("Tap to click  \(tapEnabled ? "on" : "off")")
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
tracker.smoothing = smoothing
let scrollRecognizer = ScrollRecognizer()
let pointerRecognizer = PointerRecognizer()
pointerRecognizer.twoFingerTapEnabled = tapEnabled
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
            // Both in millimetres — frame.contacts is pre-smoothing, the track
            // is post-smoothing, so this compares like with like.
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

    for event in pointerRecognizer.update(tracks: tracks, buttons: frame.buttons, dt: dt) {
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
