import Foundation
import HIDCore

// Stage 0 — read the HID report descriptor and decode it into a field layout.
// Answers: what reports exist, what is in them, and at exactly which bit offsets.

func printUsage() {
    print("""
    hid-descriptor — decode a HID report descriptor (teach-touch Stage 0)

    USAGE
      hid-descriptor                 decode the ZSA digitizer interface
      hid-descriptor --list          list all HID devices on the system
      hid-descriptor --all           decode every ZSA interface
      hid-descriptor --hex <file>    decode a saved hex dump instead of hardware
      hid-descriptor --raw           also print the raw descriptor bytes
    """)
}

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--help") || args.contains("-h") { printUsage(); exit(0) }
let showRaw = args.contains("--raw")

// MARK: - Reporting

func describe(_ parsed: ParsedDescriptor, bytes: [UInt8]) {
    if showRaw {
        print("Raw descriptor (\(bytes.count) bytes):")
        let hex = hexDump(bytes)
        var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 78, limitedBy: hex.endIndex) ?? hex.endIndex
            print("  " + hex[index..<end])
            index = end
        }
        print()
    }

    print("Collection tree")
    print(String(repeating: "─", count: 78))
    for line in parsed.tree { print("  " + line) }
    print()

    print("Reports  (report IDs \(parsed.usesReportIDs ? "in use" : "NOT used"))")
    print(String(repeating: "─", count: 78))
    for report in parsed.reports {
        print("\n  Report \(report.id) — \(report.kind.rawValue), \(report.byteLength) byte body")
        print("    " + pad("bit", 8) + pad("size", 6) + pad("logical", 14) + "usage")
        for f in report.fields {
            var label = f.flags.isConstant ? "— padding —" : f.name
            if !f.flags.isConstant { label += "  (\(usagePageName(f.usagePage)))" }
            if let phys = f.physicalDescription { label += "  ⟶ \(phys)" }
            print("    " + pad("\(f.bitOffset)", 8)
                         + pad("\(f.bitSize)", 6)
                         + pad("\(f.logicalMin)…\(f.logicalMax)", 14)
                         + label)
        }
    }
    print()
}

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s + " " : s + String(repeating: " ", count: width - s.count)
}

/// Cross-check the descriptor against what the Windows Precision Touchpad spec
/// requires. This is the part that tells us whether the plan is viable.
func ptpAudit(_ parsed: ParsedDescriptor) {
    let dig = UInt16(ZSA.digitizerUsagePage)
    print("Precision Touchpad audit")
    print(String(repeating: "─", count: 78))

    func check(_ label: String, _ ok: Bool, _ detail: String) {
        print("  \(ok ? "✓" : "✗") \(pad(label, 24)) \(detail)")
    }

    let inputMode = parsed.fields(page: dig, usage: DigitizerUsage.inputMode.rawValue,
                                  kind: .feature).first
    check("Input Mode feature", inputMode != nil,
          inputMode.map { "report \($0.reportID), \($0.bitSize) bits @ bit \($0.bitOffset)" }
              ?? "MISSING — cannot switch to multitouch mode")

    let tips = parsed.fields(page: dig, usage: DigitizerUsage.tipSwitch.rawValue, kind: .input)
    check("Finger collections", !tips.isEmpty,
          "\(tips.count) contact\(tips.count == 1 ? "" : "s")"
          + (tips.first.map { " in report \($0.reportID)" } ?? ""))

    let ids = parsed.fields(page: dig, usage: DigitizerUsage.contactIdentifier.rawValue, kind: .input)
    check("Contact Identifier", !ids.isEmpty, "\(ids.count) field(s)")

    let count = parsed.fields(page: dig, usage: DigitizerUsage.contactCount.rawValue, kind: .input)
    check("Contact Count", !count.isEmpty,
          count.first.map { "\($0.bitSize) bits @ bit \($0.bitOffset)" } ?? "missing")

    let scan = parsed.fields(page: dig, usage: DigitizerUsage.scanTime.rawValue, kind: .input)
    check("Scan Time", !scan.isEmpty,
          scan.first.flatMap { $0.physicalDescription }
              ?? "missing — velocity would need wall-clock")

    let xs = parsed.fields(page: 0x01, usage: 0x30, kind: .input)
    let absX = xs.filter { !$0.flags.isRelative }
    check("Absolute X/Y", !absX.isEmpty,
          absX.first.map { f in
              "logical 0…\(f.logicalMax)" + (f.physicalDescription.map { ", \($0)" } ?? "")
          } ?? "only relative axes found")

    let confidence = parsed.fields(page: dig, usage: DigitizerUsage.confidence.rawValue, kind: .input)
    check("Confidence", !confidence.isEmpty,
          "\(confidence.count) field(s) — usable for palm rejection")

    // A mouse collection alongside the digitizer is the mouse-mode fallback path.
    let relX = xs.filter { $0.flags.isRelative }
    check("Mouse-mode collection", !relX.isEmpty,
          relX.first.map { "report \($0.reportID) — active until Input Mode = \(ZSA.inputModeMultitouch)" }
              ?? "none")

    print()
    if let inputMode, let firstTip = tips.first, !absX.isEmpty {
        print("  VERDICT: PTP-capable. Stage 1 should write \(ZSA.inputModeMultitouch) to")
        print("           feature report \(inputMode.reportID) and expect input report \(firstTip.reportID).")
        print("           Max simultaneous contacts: \(tips.count)")
    } else {
        print("  VERDICT: not a conforming PTP device — the plan needs revisiting.")
    }
    print()
}

// MARK: - Entry

if let hexIndex = args.firstIndex(of: "--hex") {
    guard hexIndex + 1 < args.count else { print("--hex needs a file path"); exit(1) }
    let path = args[hexIndex + 1]
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("cannot read \(path)"); exit(1)
    }
    let digits = Array(text.filter(\.isHexDigit))
    guard digits.count % 2 == 0 else { print("odd number of hex digits"); exit(1) }
    var bytes: [UInt8] = []
    for i in stride(from: 0, to: digits.count, by: 2) {
        guard let b = UInt8(String(digits[i...i+1]), radix: 16) else {
            print("bad hex at offset \(i)"); exit(1)
        }
        bytes.append(b)
    }
    print("Decoding \(bytes.count) bytes from \(path)\n")
    do {
        let parsed = try parseDescriptor(bytes)
        describe(parsed, bytes: bytes)
        ptpAudit(parsed)
    } catch {
        print("parse failed: \(error)"); exit(1)
    }
    exit(0)
}

if args.contains("--list") {
    let all = HIDDiscovery.devices()
    print("\(all.count) HID device interfaces\n")
    for d in all {
        print("  \(d.info.summary)" + (d.info.vendorID == ZSA.vendorID ? "  ←" : ""))
    }
    exit(0)
}

let wantAll = args.contains("--all")
let devices = wantAll
    ? HIDDiscovery.devices(vendorID: ZSA.vendorID)
    : HIDDiscovery.devices(vendorID: ZSA.vendorID,
                           usagePage: ZSA.digitizerUsagePage,
                           usage: ZSA.digitizerUsage)

guard !devices.isEmpty else {
    print("""
    No matching ZSA device found \
    (VID 0x\(String(ZSA.vendorID, radix: 16))\
    \(wantAll ? "" : ", usagePage \(ZSA.digitizerUsagePage), usage \(ZSA.digitizerUsage))").

    Is the board plugged in?  Try:  hid-descriptor --list
    """)
    exit(1)
}

for device in devices {
    print(String(repeating: "═", count: 78))
    print(device.info.summary)
    print(String(repeating: "═", count: 78) + "\n")

    guard let bytes = device.reportDescriptor else {
        print("  (no ReportDescriptor property)\n")
        continue
    }
    do {
        let parsed = try parseDescriptor(bytes)
        describe(parsed, bytes: bytes)
        if device.info.usagePage == ZSA.digitizerUsagePage { ptpAudit(parsed) }
    } catch {
        print("  parse failed: \(error)\n")
    }
}
