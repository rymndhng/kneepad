import Foundation
import HIDCore

// Stage 1 — flip Input Mode to multitouch and stream decoded contacts.
// The go/no-go gate: two fingers must produce two independent coordinate pairs.

func printUsage() {
    print("""
    hid-stream — unlock multitouch and stream contacts (teach-touch Stage 1)

    USAGE
      hid-stream                 unlock and stream decoded contacts
      hid-stream --trace         CSV of raw positions, for drift analysis
      hid-stream --raw           also dump every report as hex
      hid-stream --log           one line per report instead of a live view
      hid-stream --seize         open exclusively (if macOS competes for reports)
      hid-stream --restore       put the device back in mouse mode and exit
      hid-stream --no-restore    leave multitouch mode enabled on exit

    The device is restored to mouse mode on exit unless --no-restore is given.
    """)
}

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--help") || args.contains("-h") { printUsage(); exit(0) }
let showRaw = args.contains("--raw")
let trace = args.contains("--trace")
let logMode = args.contains("--log")
let seize = args.contains("--seize")
let restoreOnly = args.contains("--restore")
let restoreOnExit = !args.contains("--no-restore")

let session: TouchSession
do {
    session = try TouchSession.discover()
} catch {
    print("\(error)")
    exit(1)
}

let layout = session.layout
print("Device      \(session.device.info.summary)")
print("Input Mode  feature report \(session.inputModeReportID) "
    + "(\(session.inputModeBodyLength) byte body)")
print("Touch data  input report \(layout.reportID) (\(layout.bodyLength) byte body), "
    + "\(layout.maxContacts) contact slots")
if let size = layout.surfaceSize {
    print(String(format: "Surface     %.1f × %.1f mm", size.x, size.y))
}
print("Buttons     \(layout.buttons.count)   Scan time: \(layout.scanTime != nil ? "yes" : "no")")
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

if restoreOnly {
    print("Restoring mouse mode…")
    session.restoreMouseMode(log: log)
    session.stop()
    exit(0)
}

print("Switching to multitouch (Input Mode = \(ZSA.inputModeMultitouch))…")
do {
    try session.enableMultitouch(log: log)
} catch {
    print("  \(error)")
    session.stop()
    exit(1)
}
print()

// MARK: - Restore on exit

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

// MARK: - Streaming

var reportCount = 0
var seenReportIDs: [UInt8: Int] = [:]
var warnedForeign = false
var startedAt = Date()
var lastScanTime: Int?

func render(_ frame: Frame) {
    var actives: [String] = []
    for contact in frame.contacts {
        var text = String(format: "#%d %4d,%-4d", contact.hardwareID, contact.rawX, contact.rawY)
        text += String(format: " (%.1f,%.1fmm)", contact.position.x, contact.position.y)
        if !contact.confident { text += " ~palm" }
        actives.append(text)
    }

    var rate = ""
    if let now = frame.scanTime, let modulus = layout.scanTimeModulus,
       let scale = layout.secondsPerCount {
        if let previous = lastScanTime {
            var counts = now - previous
            if counts < 0 { counts += modulus }
            let seconds = Double(counts) * scale
            if seconds > 0 { rate = String(format: " %5.0fHz", 1.0 / seconds) }
        }
        lastScanTime = now
    }

    let buttons = frame.buttons.enumerated().filter(\.element).map { "B\($0.offset + 1)" }
    let line = "contacts \(frame.declaredCount.map(String.init) ?? "?")"
        + (buttons.isEmpty ? "" : " [\(buttons.joined(separator: " "))]")
        + rate + "  " + (actives.isEmpty ? "—" : actives.joined(separator: "   "))

    if logMode {
        print(line)
    } else {
        print("\r" + line.padding(toLength: max(line.count, 100), withPad: " ", startingAt: 0),
              terminator: "")
        fflush(stdout)
    }
}

session.onFraming = { framing, reportID, length, expected in
    print("Framing: IOKit buffer \(framing == .includesReportID ? "INCLUDES" : "omits") "
        + "the report-ID byte (report \(reportID), len \(length), body \(expected))")
    print("Move fingers on the trackpad. Ctrl-C to stop and restore mouse mode.\n")
    startedAt = Date()
}

session.onFrame = { frame, body in
    reportCount += 1

    if trace {
        // Straight from the report: no tracking, no smoothing, nothing of ours
        // between the hardware and this line.
        if let c = frame.contacts.first {
            print(String(format: "%d,%d,%d,%.3f,%.3f,%d",
                         frame.scanTime ?? 0, c.rawX, c.rawY,
                         c.position.x, c.position.y, frame.contacts.count))
        } else {
            print("\(frame.scanTime ?? 0),,,,,0")
        }
        return
    }
    seenReportIDs[layout.reportID, default: 0] += 1
    if showRaw { print("rpt \(layout.reportID)  \(hexDump(body))") }
    render(frame)
}

session.onForeignReport = { reportID, buffer in
    reportCount += 1
    seenReportIDs[reportID, default: 0] += 1
    if showRaw { print("rpt \(reportID)  len \(buffer.count)  \(hexDump(buffer))") }
    if !warnedForeign {
        warnedForeign = true
        print("""
        ⚠️  Receiving input report \(reportID), not \(layout.reportID).
            That is the mouse-mode collection — the Input Mode write did not take.
        """)
    }
}

session.start()

print("Waiting for input reports…")
print("If nothing appears, the device accepted the mode switch but is not")
print("reporting — see the NO-GO notes in plan/README.md.\n")

DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
    if reportCount == 0 {
        print("\n⚠️  No input reports after 5s.")
        print("   Try:  hid-stream --seize        (macOS may be holding the interface)")
        print("   Or:   hid-stream --raw          (to see any traffic at all)")
    }
}

atexit {
    let elapsed = Date().timeIntervalSince(startedAt)
    if reportCount > 0 {
        print(String(format: "\n%d reports in %.1fs (%.0f/s)",
                     reportCount, elapsed, Double(reportCount) / max(elapsed, 0.001)))
        let breakdown = seenReportIDs.sorted { $0.key < $1.key }
            .map { "report \($0.key): \($0.value)" }
            .joined(separator: ", ")
        print("  \(breakdown)")
    }
}

CFRunLoopRun()
restoreAndExit(0)
