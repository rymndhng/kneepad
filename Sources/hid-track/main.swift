import Foundation
import HIDCore

// Stage 2 — contact tracking.
//
// Reports are state snapshots, so this derives what the hardware never sends:
// finger births and deaths, per-finger velocity, and the two-finger geometry
// (centroid, spread, angle) that scroll, pinch and rotate are built from.

func printUsage() {
    print("""
    hid-track — follow fingers across frames (teach-touch Stage 2)

    USAGE
      hid-track                  live view: tracks and two-finger geometry
      hid-track --events         log began/moved/ended events instead
      hid-track --seize          open exclusively
      hid-track --no-restore     leave multitouch mode enabled on exit

    The device is restored to mouse mode on exit unless --no-restore is given.
    """)
}

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--help") || args.contains("-h") { printUsage(); exit(0) }
let eventMode = args.contains("--events")
let seize = args.contains("--seize")
let restoreOnExit = !args.contains("--no-restore")

let session: TouchSession
do {
    session = try TouchSession.discover()
} catch {
    print("\(error)"); exit(1)
}

let layout = session.layout
print("Device      \(session.device.info.summary)")
print("Touch data  input report \(layout.reportID), \(layout.maxContacts) contact slots")
if let size = layout.surfaceSize {
    print(String(format: "Surface     %.1f × %.1f mm", size.x, size.y))
}
if let seconds = layout.secondsPerCount {
    print(String(format: "Scan time   %.0f µs per count", seconds * 1_000_000))
}
print()

do {
    try session.open(seize: seize)
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
print()

func restoreAndExit(_ code: Int32) -> Never {
    if restoreOnExit {
        print("\nRestoring mouse mode…")
        session.restoreMouseMode(log: log)
    }
    session.stop()
    exit(code)
}

signal(SIGINT, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler { restoreAndExit(0) }
sigintSource.resume()

// MARK: - Tracking

let tracker = ContactTracker(layout: layout)
var previousTwoFinger: TwoFingerState?
/// Geometry captured when the second finger landed — the reference a gesture
/// measures against, rather than the previous frame.
var gestureBaseline: TwoFingerState?
var lastWall = Date()

session.onFraming = { _, _, _, _ in
    print("Streaming. Ctrl-C to stop and restore mouse mode.\n")
}

session.onForeignReport = { reportID, _ in
    print("⚠️  report \(reportID) — device is still in mouse mode")
}

session.onFrame = { frame, _ in
    let now = Date()
    let wall = now.timeIntervalSince(lastWall)
    lastWall = now

    let events = tracker.update(frame, wallClockDelta: wall)

    if eventMode {
        for event in events {
            let t = event.track
            switch event {
            case .began:
                print(String(format: "began  track %d (hw #%d) at (%.1f, %.1f)mm",
                             t.id, t.hardwareID, t.position.x, t.position.y))
            case .moved:
                // Movement is continuous; only log meaningful steps.
                guard (t.position - t.previous).magnitude > 0.2 else { continue }
                print(String(format: "moved  track %d → (%.1f, %.1f)mm  v=(%.0f, %.0f) mm/s",
                             t.id, t.position.x, t.position.y, t.velocity.x, t.velocity.y))
            case .ended:
                print(String(format: "ended  track %d after %.2fs, %.1fmm travelled, "
                             + "displacement %.1fmm",
                             t.id, t.age, t.distance, t.displacement.magnitude))
            }
        }
        return
    }

    // Live view
    let tracks = tracker.active
    var parts: [String] = []
    for t in tracks {
        parts.append(String(format: "T%d (%.1f,%.1f) v=%.0f%@",
                            t.id, t.position.x, t.position.y,
                            t.velocity.magnitude, t.confident ? "" : " ~palm"))
    }

    var geometry = ""
    if let state = TwoFingerState(tracks) {
        if gestureBaseline == nil { gestureBaseline = state }
        let base = gestureBaseline!
        let pinch = state.spread - base.spread
        let rotate = state.rotation(from: base) * 180 / .pi
        let pan = state.centroid - base.centroid
        geometry = String(format: "  │ spread %.1fmm (%+.1f)  rot %+.0f°  pan (%+.1f,%+.1f)",
                          state.spread, pinch, rotate, pan.x, pan.y)
        previousTwoFinger = state
    } else {
        gestureBaseline = nil
        previousTwoFinger = nil
    }

    let rate = tracker.lastDelta > 0 ? String(format: "%4.0fHz ", 1 / tracker.lastDelta) : "     "
    let line = rate + (parts.isEmpty ? "—" : parts.joined(separator: "  ")) + geometry
    print("\r" + line.padding(toLength: max(line.count, 110), withPad: " ", startingAt: 0),
          terminator: "")
    fflush(stdout)
}

session.start()

atexit {
    if tracker.idChurnDetected {
        print("\n⚠️  Hardware contact IDs are not stable across frames.")
        print("   Tracking by Contact Identifier is unreliable on this device;")
        print("   Stage 2 would need nearest-neighbour association instead.")
    }
}

CFRunLoopRun()
restoreAndExit(0)
