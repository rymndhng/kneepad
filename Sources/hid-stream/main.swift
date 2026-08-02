import Foundation
import IOKit
import IOKit.hid
import HIDCore

// Stage 1 — GO/NO-GO GATE.
//
// Flip the Precision Touchpad Input Mode feature to multitouch, then stream and
// decode contact reports. If two fingers on the pad produce two independent
// moving (x, y) pairs, everything downstream in the plan is ordinary software.
//
// Nothing here is hardcoded to a report ID: the layout is discovered from the
// descriptor via HIDCore, so this doubles as a check on Stage 0's parser.

func printUsage() {
    print("""
    hid-stream — unlock multitouch and stream contacts (teach-touch Stage 1)

    USAGE
      hid-stream                 unlock and stream decoded contacts
      hid-stream --raw           also dump every report as hex
      hid-stream --log           one decoded line per report instead of live view
      hid-stream --seize         open exclusively (if macOS competes for reports)
      hid-stream --restore       put the device back in mouse mode and exit
      hid-stream --no-restore    leave multitouch mode enabled on exit

    The device is restored to mouse mode on exit unless --no-restore is given.
    """)
}

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--help") || args.contains("-h") { printUsage(); exit(0) }
let showRaw = args.contains("--raw")
let logMode = args.contains("--log")
let seize = args.contains("--seize")
let restoreOnly = args.contains("--restore")
let restoreOnExit = !args.contains("--no-restore")

// MARK: - Contact layout, discovered from the descriptor

/// The set of fields describing one finger slot within an input report.
struct ContactLayout {
    var confidence: HIDField?
    var tipSwitch: HIDField?
    var contactID: HIDField?
    var x: HIDField?
    var y: HIDField?

    var isComplete: Bool { tipSwitch != nil && x != nil && y != nil }
}

struct TouchLayout {
    let reportID: UInt8
    let bodyLength: Int
    var contacts: [ContactLayout] = []
    var contactCount: HIDField?
    var scanTime: HIDField?
    var buttons: [HIDField] = []
}

/// Walk the report's fields in descriptor order, starting a new finger slot
/// whenever we meet a usage the current slot has already filled.
func discoverTouchLayout(_ parsed: ParsedDescriptor) -> TouchLayout? {
    let dig = UInt16(ZSA.digitizerUsagePage)
    guard let anchor = parsed.fields(page: dig,
                                     usage: DigitizerUsage.tipSwitch.rawValue,
                                     kind: .input).first,
          let report = parsed.report(id: anchor.reportID, kind: .input)
    else { return nil }

    var layout = TouchLayout(reportID: report.id, bodyLength: report.byteLength)
    var current = ContactLayout()

    func flush() {
        if current.tipSwitch != nil || current.x != nil { layout.contacts.append(current) }
        current = ContactLayout()
    }

    for f in report.fields where !f.flags.isConstant {
        switch (f.usagePage, f.usage) {
        case (dig, DigitizerUsage.confidence.rawValue):
            if current.confidence != nil { flush() }
            current.confidence = f
        case (dig, DigitizerUsage.tipSwitch.rawValue):
            if current.tipSwitch != nil { flush() }
            current.tipSwitch = f
        case (dig, DigitizerUsage.contactIdentifier.rawValue):
            if current.contactID != nil { flush() }
            current.contactID = f
        case (0x01, 0x30) where !f.flags.isRelative:
            if current.x != nil { flush() }
            current.x = f
        case (0x01, 0x31) where !f.flags.isRelative:
            if current.y != nil { flush() }
            current.y = f
            flush()  // Y closes a finger collection in every PTP layout
        case (dig, DigitizerUsage.contactCount.rawValue):
            flush(); layout.contactCount = f
        case (dig, DigitizerUsage.scanTime.rawValue):
            flush(); layout.scanTime = f
        case (0x09, _):
            flush(); layout.buttons.append(f)
        default:
            break
        }
    }
    flush()
    layout.contacts = layout.contacts.filter(\.isComplete)
    return layout.contacts.isEmpty ? nil : layout
}

/// Convert a logical axis value to millimetres using the descriptor's own
/// physical range and unit exponent, so nothing is hardcoded per-device.
func millimetres(_ field: HIDField, _ value: Int) -> Double? {
    guard field.logicalMax > field.logicalMin, field.physicalMax != field.physicalMin
    else { return nil }
    let fraction = Double(value - field.logicalMin)
        / Double(field.logicalMax - field.logicalMin)
    let span = Double(field.physicalMax - field.physicalMin) * pow(10.0, Double(field.unitExponent))
    return fraction * span * 10.0  // SI linear length is centimetres
}

// MARK: - Device setup

let devices = HIDDiscovery.devices(vendorID: ZSA.vendorID,
                                   usagePage: ZSA.digitizerUsagePage,
                                   usage: ZSA.digitizerUsage)
guard let device = devices.first else {
    print("""
    No ZSA digitizer interface found.

    Expected VID 0x\(String(ZSA.vendorID, radix: 16)), \
    usagePage \(ZSA.digitizerUsagePage), usage \(ZSA.digitizerUsage).
    Check the board is plugged in:  hid-descriptor --list
    """)
    exit(1)
}

guard let descriptorBytes = device.reportDescriptor else {
    print("Device exposes no ReportDescriptor — cannot proceed."); exit(1)
}

let parsed: ParsedDescriptor
do {
    parsed = try parseDescriptor(descriptorBytes)
} catch {
    print("Descriptor parse failed: \(error)"); exit(1)
}

guard let inputModeField = parsed.fields(page: UInt16(ZSA.digitizerUsagePage),
                                         usage: DigitizerUsage.inputMode.rawValue,
                                         kind: .feature).first else {
    print("""
    No Input Mode feature report in this descriptor.

    Without it the device cannot be switched out of mouse mode, and the
    userland approach in plan/README.md does not apply to this hardware.
    """)
    exit(1)
}

guard let layout = discoverTouchLayout(parsed) else {
    print("No usable finger collections found in any input report."); exit(1)
}

let inputModeReportID = inputModeField.reportID
let inputModeLength = parsed.report(id: inputModeReportID, kind: .feature)?.byteLength ?? 1

print("Device      \(device.info.summary)")
print("Input Mode  feature report \(inputModeReportID) (\(inputModeLength) byte body)")
print("Touch data  input report \(layout.reportID) (\(layout.bodyLength) byte body), "
    + "\(layout.contacts.count) contact slots")
print("Buttons     \(layout.buttons.count)   Scan time: \(layout.scanTime != nil ? "yes" : "no")")
print()

do {
    try device.open(seize: seize)
} catch {
    print("""
    \(error)

    If this is a permissions failure, grant Input Monitoring to your terminal:
      System Settings ▸ Privacy & Security ▸ Input Monitoring
    """)
    exit(1)
}

/// Write the Input Mode feature and read it back to confirm the device accepted it.
func setInputMode(_ mode: UInt8) -> Bool {
    var payload = [UInt8](repeating: 0, count: max(1, inputModeLength))
    payload[0] = mode
    do {
        try device.setFeature(reportID: inputModeReportID, bytes: payload)
    } catch {
        print("  SET_FEATURE failed: \(error)")
        return false
    }
    // Read-back is advisory: some firmware refuses GET on this report.
    if let echo = try? device.getFeature(reportID: inputModeReportID,
                                         length: max(1, inputModeLength)) {
        let value = echo.first.map { $0 == mode ? $0 : (echo.count > 1 ? echo[1] : $0) }
        print("  read back: \(hexDump(echo))"
            + (value == mode ? "  ✓ accepted" : "  ⚠️ echo does not match \(mode)"))
    } else {
        print("  (device declined GET_FEATURE read-back — not necessarily a failure)")
    }
    return true
}

if restoreOnly {
    print("Restoring mouse mode (Input Mode = \(ZSA.inputModeMouse))…")
    _ = setInputMode(ZSA.inputModeMouse)
    device.close()
    exit(0)
}

print("Switching to multitouch (Input Mode = \(ZSA.inputModeMultitouch))…")
guard setInputMode(ZSA.inputModeMultitouch) else {
    device.close()
    exit(1)
}
print()

// MARK: - Restore-on-exit

var restored = false
func restoreAndExit(_ code: Int32) -> Never {
    if restoreOnExit && !restored {
        restored = true
        print("\nRestoring mouse mode…")
        _ = setInputMode(ZSA.inputModeMouse)
    }
    device.close()
    exit(code)
}

signal(SIGINT, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler { restoreAndExit(0) }
sigintSource.resume()

// MARK: - Streaming

var framing: ReportFraming?
var reportCount = 0
var lastScanTime: Int?
var startedAt = Date()

func render(_ body: [UInt8]) {
    var actives: [String] = []
    for (index, contact) in layout.contacts.enumerated() {
        guard let tipField = contact.tipSwitch else { continue }
        let down = extract(tipField, from: body) != 0
        guard down else { continue }

        let xRaw = contact.x.map { extract($0, from: body) } ?? 0
        let yRaw = contact.y.map { extract($0, from: body) } ?? 0
        let id = contact.contactID.map { extract($0, from: body) } ?? index
        let confident = contact.confidence.map { extract($0, from: body) != 0 } ?? true

        var text = String(format: "#%d %4d,%-4d", id, xRaw, yRaw)
        if let xf = contact.x, let yf = contact.y,
           let mx = millimetres(xf, xRaw), let my = millimetres(yf, yRaw) {
            text += String(format: " (%.1f,%.1fmm)", mx, my)
        }
        if !confident { text += " ~palm" }
        actives.append(text)
    }

    let declared = layout.contactCount.map { extract($0, from: body) }
    let buttons = layout.buttons.enumerated()
        .filter { extract($0.element, from: body) != 0 }
        .map { "B\($0.offset + 1)" }

    var rate = ""
    if let scanField = layout.scanTime {
        let now = extract(scanField, from: body)
        if let previous = lastScanTime {
            // Scan Time wraps at the field's logical maximum.
            var delta = now - previous
            if delta < 0 { delta += scanField.logicalMax + 1 }
            let scale = pow(10.0, Double(scanField.unitExponent))  // seconds per count
            let seconds = Double(delta) * scale
            if seconds > 0 { rate = String(format: " %5.0fHz", 1.0 / seconds) }
        }
        lastScanTime = now
    }

    let line = "contacts \(declared.map(String.init) ?? "?")"
        + (buttons.isEmpty ? "" : " [\(buttons.joined(separator: " "))]")
        + rate + "  " + (actives.isEmpty ? "—" : actives.joined(separator: "   "))

    if logMode {
        print(line)
    } else {
        // Live view: overwrite a single line, padded to clear stale text.
        let padded = line.padding(toLength: max(line.count, 100), withPad: " ", startingAt: 0)
        print("\r" + padded, terminator: "")
        fflush(stdout)
    }
}

let bufferSize = max(64, layout.bodyLength + 1)
device.onInputReport(maxLength: bufferSize) { reportID, buffer in
    reportCount += 1

    if showRaw {
        print("rpt \(reportID)  len \(buffer.count)  \(hexDump(buffer))")
    }

    // Decide the framing question once, from real data rather than assumption.
    if framing == nil {
        let detected = ReportFraming.detect(bufferLength: buffer.count,
                                            reportID: reportID,
                                            firstByte: buffer.first,
                                            expectedBodyLength: layout.bodyLength)
        framing = detected
        print("Framing: IOKit buffer \(detected == .includesReportID ? "INCLUDES" : "omits") "
            + "the report-ID byte (len \(buffer.count), descriptor body \(layout.bodyLength))")
        print("Move fingers on the trackpad. Ctrl-C to stop and restore mouse mode.\n")
        startedAt = Date()
    }

    guard reportID == layout.reportID else { return }
    render(framing!.body(buffer))
}

device.schedule()

print("Waiting for input reports…")
print("If nothing appears, the device accepted the mode switch but is not")
print("reporting — see the NO-GO notes in plan/README.md.\n")

// Report a summary if the stream stays silent, so a no-go is unambiguous.
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
    }
}

CFRunLoopRun()
restoreAndExit(0)
