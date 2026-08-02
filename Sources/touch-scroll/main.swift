import Foundation
import HIDCore
import TouchEvents

// Stage 4 — two-finger scrolling.
//
// Contacts → tracks → scroll recognition → CGEvent injection. This is the first
// stage that produces real system behaviour rather than diagnostics.
//
// Note: in multitouch mode the device stops sending mouse reports, so the
// cursor will not move while this runs. Stage 3 (pointer) is what gives it back.

func printUsage() {
    print("""
    touch-scroll — two-finger scrolling (teach-touch Stage 4)

    USAGE
      touch-scroll                  scroll using the ZSA trackpad
      touch-scroll --gain N         pixels per millimetre (default 8)
      touch-scroll --reverse        invert vertical direction
      touch-scroll --invert-x       invert horizontal direction
      touch-scroll --no-momentum    disable inertial scrolling
      touch-scroll --friction N     momentum decay per tick (default 0.94)
      touch-scroll --activation N   mm of travel before scrolling starts
      touch-scroll --quiet          no per-event logging
      touch-scroll --dry-run        recognise but post nothing

    The cursor stops working while this runs — the device cannot send mouse
    reports in multitouch mode. Ctrl-C restores it.
    """)
}

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--help") || args.contains("-h") { printUsage(); exit(0) }

func value(_ flag: String) -> Double? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return Double(args[i + 1])
}

let quiet = args.contains("--quiet")
let dryRun = args.contains("--dry-run")

var config = ScrollSynthesizer.Configuration()
if let g = value("--gain") { config.gain = g }
if let f = value("--friction") { config.friction = f }
if args.contains("--reverse") { config.naturalDirection = false }
if args.contains("--invert-x") { config.invertHorizontal = true }
if args.contains("--no-momentum") { config.momentumEnabled = false }

// MARK: - Permissions

if !dryRun && !ScrollSynthesizer.hasAccessibilityPermission() {
    print("""
    Accessibility permission is required to post scroll events.

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

print("Device      \(session.device.info.summary)")
if let size = session.layout.surfaceSize {
    print(String(format: "Surface     %.1f × %.1f mm", size.x, size.y))
}
print(String(format: "Gain        %.1f px/mm   direction: %@%@",
             config.gain,
             config.naturalDirection ? "natural" : "reversed",
             config.momentumEnabled ? "   momentum: on" : "   momentum: off"))
if dryRun { print("Dry run     recognising only, posting nothing") }
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

let tracker = ContactTracker(layout: session.layout)
let recognizer = ScrollRecognizer()
if let a = value("--activation") { recognizer.activationDistance = a }
let synthesizer = ScrollSynthesizer(configuration: config)

func restoreAndExit(_ code: Int32) -> Never {
    synthesizer.cancelMomentum()
    print("\nRestoring mouse mode…")
    session.restoreMouseMode(log: log)
    session.stop()
    exit(code)
}

signal(SIGINT, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler { restoreAndExit(0) }
sigintSource.resume()

// MARK: - Pipeline

var lastWall = Date()
var scrollCount = 0
var previousContactCount = 0

session.onFraming = { _, _, _, _ in
    print("\nReady. Two fingers to scroll. Ctrl-C to stop and restore the cursor.\n")
}

session.onForeignReport = { reportID, _ in
    print("⚠️  report \(reportID) — device is still in mouse mode")
}

session.onFrame = { frame, _ in
    let now = Date()
    let wall = now.timeIntervalSince(lastWall)
    lastWall = now

    tracker.update(frame, wallClockDelta: wall)

    // A genuinely new touch should stop coasting, the way a real trackpad does.
    //
    // This must trigger on the 0 → N transition, not merely "some contact is
    // present". Two fingers never lift on the same frame, so the straggler from
    // the gesture that just ended would otherwise cancel the momentum it had
    // only just started — the faster the release, the worse it looked.
    if previousContactCount == 0 && !frame.contacts.isEmpty {
        synthesizer.cancelMomentum()
    }
    previousContactCount = frame.contacts.count

    guard let update = recognizer.update(tracks: tracker.active, dt: tracker.lastDelta)
    else { return }

    if !dryRun { synthesizer.handle(update) }

    if !quiet {
        switch update.phase {
        case .began:
            scrollCount += 1
            print(String(format: "scroll began  Δ(%.2f, %.2f)mm", update.delta.x, update.delta.y))
        case .changed:
            print(String(format: "\r  Δ(%+6.2f,%+6.2f)mm  v=(%+7.1f,%+7.1f) mm/s",
                         update.delta.x, update.delta.y,
                         update.velocity.x, update.velocity.y), terminator: "")
            fflush(stdout)
        case .ended:
            print(String(format: "\nscroll ended  final v=(%.0f, %.0f) mm/s",
                         update.velocity.x, update.velocity.y))
        }
    }
}

session.start()

atexit {
    if scrollCount > 0 { print("\n\(scrollCount) scroll gestures") }
    if tracker.idChurnDetected {
        print("⚠️  hardware contact IDs were unstable during this run")
    }
}

CFRunLoopRun()
restoreAndExit(0)
