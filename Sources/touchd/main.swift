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
      touchd --friction N           momentum decay per tick (default 0.96)
      touchd --flick N              mm/s release speed for momentum (default 2)
      touchd --no-accel             disable pointer acceleration
      touchd --no-momentum          disable inertial scrolling
      touchd --no-tap               disable tap-to-click
      touchd --reverse              invert scroll direction
      touchd --verbose              log recognised gestures
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

var scrollConfig = ScrollSynthesizer.Configuration()
if let g = value("--scroll-gain") { scrollConfig.gain = g }
if let f = value("--friction") { scrollConfig.friction = f }
if let t = value("--flick") { scrollConfig.momentumThreshold = t }
if args.contains("--reverse") { scrollConfig.naturalDirection = false }
if args.contains("--no-momentum") { scrollConfig.momentumEnabled = false }

var pointerConfig = PointerSynthesizer.Configuration()
if let g = value("--pointer-gain") { pointerConfig.gain = g }
if args.contains("--no-accel") { pointerConfig.accelerationEnabled = false }

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
print(String(format: "Pointer       %.0f px/mm%@",
             pointerConfig.gain,
             pointerConfig.accelerationEnabled ? " with acceleration" : ""))
print(String(format: "Scroll        %.0f px/mm, %@, friction %.2f",
             scrollConfig.gain,
             scrollConfig.naturalDirection ? "natural" : "reversed",
             scrollConfig.friction))
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

session.onFraming = { _, _, _, _ in
    print("\nReady. One finger moves, tap clicks, two fingers scroll.")
    print("Ctrl-C to stop and restore mouse mode.\n")
}

session.onForeignReport = { reportID, _ in
    print("⚠️  report \(reportID) — device fell back to mouse mode")
}

session.onFrame = { frame, _ in
    let now = Date()
    let wall = now.timeIntervalSince(lastWall)
    lastWall = now

    tracker.update(frame, wallClockDelta: wall)
    let dt = tracker.lastDelta
    let tracks = tracker.active

    // A genuinely new touch stops coasting. Keyed to the 0 → N transition:
    // two fingers never lift on the same frame, so "any contact present" would
    // let the straggler cancel the momentum it just started.
    if previousContactCount == 0 && !frame.contacts.isEmpty {
        scrollSynthesizer.cancelMomentum()
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
}

session.start()

atexit {
    if taps > 0 || scrolls > 0 { print("\(taps) taps, \(scrolls) scrolls") }
    if tracker.idChurnDetected {
        print("⚠️  hardware contact IDs were unstable during this run")
    }
}

CFRunLoopRun()
restoreAndExit(0)
