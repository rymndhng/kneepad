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

/// Write the Input Mode feature and confirm by read-back.
///
/// macOS feature-report framing is ambiguous: IOKit returns the report-ID byte
/// on GET, and hidapi's darwin backend also sends it on SET — but firmware
/// varies. So try with the ID prefix, verify, and fall back to without.
func setInputMode(_ mode: UInt8) -> Bool {
    let body = max(1, inputModeLength)
    for includeID in [true, false] {
        let style = includeID ? "with ID prefix" : "without ID prefix"
        do {
            try device.setFeature(reportID: inputModeReportID,
                                  bytes: [mode], includeReportID: includeID)
        } catch {
            print("  SET_FEATURE \(style) failed: \(error)")
            continue
        }
        guard let echo = try? device.getFeature(reportID: inputModeReportID,
                                                bodyLength: body) else {
            print("  wrote \(mode) \(style); device declined read-back — assuming it took")
            return true
        }
        let value = echo.body.first
        let ok = value == mode
        print("  \(style): raw \(hexDump(echo.raw)) → body \(hexDump(echo.body))"
            + (ok ? "  ✓ accepted" : "  ✗ reads back as \(value.map(String.init) ?? "?")"))
        if ok { return true }
    }
    return false
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

// Every input report the descriptor declares, so framing can be judged against
// the report that actually arrived rather than the one we hoped for.
let inputBodyLengths: [UInt8: Int] = Dictionary(
    parsed.reports.filter { $0.kind == .input }.map { ($0.id, $0.byteLength) },
    uniquingKeysWith: { first, _ in first })

var seenReportIDs: [UInt8: Int] = [:]
var warnedWrongReport = false

let bufferSize = max(64, (inputBodyLengths.values.max() ?? layout.bodyLength) + 1)
device.onInputReport(maxLength: bufferSize) { reportID, buffer in
    reportCount += 1
    seenReportIDs[reportID, default: 0] += 1

    if showRaw {
        print("rpt \(reportID)  len \(buffer.count)  \(hexDump(buffer))")
    }

    // Decide framing once, using the expected length for *this* report ID.
    if framing == nil, let expected = inputBodyLengths[reportID] {
        let detected = ReportFraming.detect(bufferLength: buffer.count,
                                            reportID: reportID,
                                            firstByte: buffer.first,
                                            expectedBodyLength: expected)
        framing = detected
        print("Framing: IOKit buffer \(detected == .includesReportID ? "INCLUDES" : "omits") "
            + "the report-ID byte (report \(reportID), len \(buffer.count), body \(expected))")
        print("Move fingers on the trackpad. Ctrl-C to stop and restore mouse mode.\n")
        startedAt = Date()
    }

    guard reportID == layout.reportID else {
        // Traffic on another report means the mode switch silently failed.
        if !warnedWrongReport {
            warnedWrongReport = true
            print("""
            ⚠️  Receiving input report \(reportID), not \(layout.reportID).
                Report \(reportID) is the mouse-mode collection — the device is still
                in mouse mode, so the Input Mode write did not take effect.
            """)
        }
        return
    }
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
        let breakdown = seenReportIDs.sorted { $0.key < $1.key }
            .map { "report \($0.key): \($0.value)" }
            .joined(separator: ", ")
        print("  \(breakdown)")
    }
}

CFRunLoopRun()
restoreAndExit(0)
