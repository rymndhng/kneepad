import Foundation
import CoreGraphics
import ApplicationServices

// Stage 5 reconnaissance.
//
// macOS has no public API for synthesising pinch, rotate or swipe. The values
// live in undocumented CGEvent fields, and guessing the field numbers produces
// events that are silently ignored — the worst possible failure mode.
//
// So: measure. This taps the gesture event types and dumps the payload of
// whatever Apple's own trackpad emits.
//
// Two things learned from the first run, baked in here:
//   * Magnify/Rotate/Swipe do not exist at .cghidEventTap. That is the bottom
//     of the stack, where only raw type-29 gesture events live; the higher
//     level types are synthesised further up. Default tap is now the session.
//   * Most type-29 events are payload-free finger-tracking frames. They are
//     filtered out by default, along with the housekeeping fields that appear
//     identically on every event.

func printUsage() {
    print("""
    gesture-probe — discover the undocumented gesture CGEvent encoding

    USAGE
      gesture-probe                     tap the session, show only payloads
      gesture-probe --tap hid           tap .cghidEventTap (raw, bottom of stack)
      gesture-probe --tap annotated     tap .cgAnnotatedSessionEventTap
      gesture-probe --all-events        include payload-free events
      gesture-probe --all-fields        include housekeeping fields
      gesture-probe --label "pinch in"  tag the run in the output

    Perform ONE gesture per run on an APPLE trackpad, so the fields can be
    correlated with the gesture that produced them. The ZSA pad cannot make
    these — that is the point of the exercise.

    Needs Accessibility permission.
    """)
}

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--help") || args.contains("-h") { printUsage(); exit(0) }
let showAllFields = args.contains("--all-fields")
let showAllEvents = args.contains("--all-events")

func stringValue(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let label = stringValue("--label")

let tapLocation: CGEventTapLocation
switch stringValue("--tap") {
case "hid": tapLocation = .cghidEventTap
case "annotated": tapLocation = .cgAnnotatedSessionEventTap
default: tapLocation = .cgSessionEventTap
}

/// AppKit's NSEvent type numbers. Public as NSEvent types; what's undocumented
/// is their CGEvent field layout.
let gestureTypes: [UInt32: String] = [
    18: "NSEventTypeRotate",
    19: "NSEventTypeBeginGesture",
    20: "NSEventTypeEndGesture",
    29: "NSEventTypeGesture",
    30: "NSEventTypeMagnify",
    31: "NSEventTypeSwipe",
    32: "NSEventTypeSmartMagnify",
    33: "NSEventTypePressure",
]

/// Present and identical on every event — source and routing bookkeeping, not
/// gesture data. Hidden unless --all-fields.
let housekeeping: Set<UInt32> = [39, 40, 41, 42, 43, 44, 45, 50, 55, 58, 85, 87, 101, 169]

/// NSEventPhase. Confirmed against captured data: 128 and 8 both observed.
func phaseName(_ value: Int64) -> String {
    switch value {
    case 0: return "none"
    case 1: return "began"
    case 2: return "stationary"
    case 4: return "changed"
    case 8: return "ended"
    case 16: return "cancelled"
    case 128: return "mayBegin"
    default: return "0x\(String(value, radix: 16))"
    }
}

/// IOHIDEventType — the likely meaning of field 110. Unconfirmed.
func hidTypeName(_ value: Int64) -> String {
    switch value {
    case 1: return "VendorDefined?"
    case 2: return "Button?"
    case 4: return "Translation?"
    case 5: return "Rotation?"
    case 6: return "Scroll?"
    case 7: return "Scale?"
    case 8: return "Zoom?"
    case 9: return "Velocity?"
    case 10: return "Orientation?"
    case 11: return "Digitizer?"
    default: return "?"
    }
}

/// Integer fields carry Float32 bit patterns; 0x80000000 is -0.0, meaning
/// "no value". Reinterpreting makes the payload legible.
func asFloat(_ raw: Int64) -> String {
    let bits = UInt32(bitPattern: Int32(truncatingIfNeeded: raw))
    if bits == 0x8000_0000 { return "−0.0 (absent)" }
    let value = Float(bitPattern: bits)
    guard value.isFinite else { return "not a float" }
    return String(format: "%.6f", value)
}

guard AXIsProcessTrustedWithOptions(
        [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) else {
    print("""
    Accessibility permission is required to install an event tap.
      System Settings ▸ Privacy & Security ▸ Accessibility

    Approve, then re-run.
    """)
    exit(1)
}

var mask: CGEventMask = 0
for type in gestureTypes.keys { mask |= (1 << CGEventMask(type)) }

let fieldRange: [UInt32] = Array(0...200)

var seenSignatures = Set<String>()
var eventCount = 0
var payloadCount = 0
var typeCounts: [UInt32: Int] = [:]

let callback: CGEventTapCallBack = { _, type, event, _ in
    let raw = UInt32(type.rawValue)
    eventCount += 1
    typeCounts[raw, default: 0] += 1

    var fields: [(UInt32, Int64, Double)] = []
    for field in fieldRange {
        guard let f = CGEventField(rawValue: field) else { continue }
        let i = event.getIntegerValueField(f)
        let d = event.getDoubleValueField(f)
        guard i != 0 || d != 0 else { continue }
        if !showAllFields && housekeeping.contains(field) { continue }
        fields.append((field, i, d))
    }

    // Payload-free type-29 events are finger-tracking frames, not gestures.
    guard !fields.isEmpty || showAllEvents else { return Unmanaged.passUnretained(event) }
    payloadCount += 1

    let signature = "\(raw)-" + fields.map { "\($0.0)" }.joined(separator: ",")
    let isNew = seenSignatures.insert(signature).inserted

    let name = gestureTypes[raw] ?? "type \(raw)"
    print("\n── \(name) (\(raw))\(isNew ? "   ★ new field shape" : "")")
    for (field, i, d) in fields {
        var note = ""
        switch field {
        case 132: note = "   ← phase: \(phaseName(i))"
        case 110: note = "   ← gesture type: \(hidTypeName(i))"
        default: break
        }
        // Show the float reinterpretation when it differs from the integer.
        let floatView = (i != 0 && Double(i) != d) ? "  float=\(asFloat(i))" : ""
        let doubleView = d != 0 ? String(format: "  double=%.6f", d) : ""
        print(String(format: "   field %3d  int=%-12d", field, i)
              + floatView + doubleView + note)
    }
    return Unmanaged.passUnretained(event)
}

guard let tap = CGEvent.tapCreate(tap: tapLocation,
                                  place: .headInsertEventTap,
                                  options: .listenOnly,
                                  eventsOfInterest: mask,
                                  callback: callback,
                                  userInfo: nil) else {
    print("Failed to create the event tap — is Accessibility granted?")
    exit(1)
}

let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

let tapName: String
switch tapLocation {
case .cghidEventTap: tapName = "hid (bottom of stack)"
case .cgAnnotatedSessionEventTap: tapName = "annotated session"
default: tapName = "session"
}

print("Tap: \(tapName)")
if let label { print("Label: \(label)") }
print("""

Do ONE gesture, repeatedly, then Ctrl-C. Suggested runs:

  gesture-probe --label "pinch out"     then pinch open on the Apple trackpad
  gesture-probe --label "rotate cw"     then two-finger rotate
  gesture-probe --label "swipe left"    then three-finger swipe

Payload-free finger-tracking frames are hidden; pass --all-events to see them.
""")

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    print("\n\n\(eventCount) events seen, \(payloadCount) with payload, "
        + "\(seenSignatures.count) distinct shapes")
    let breakdown = typeCounts.sorted { $0.key < $1.key }
        .map { "\(gestureTypes[$0.key] ?? "type \($0.key)"): \($0.value)" }
        .joined(separator: ", ")
    print("  \(breakdown)")
    if let label { print("  label: \(label)") }
    exit(0)
}
sigint.resume()

CFRunLoopRun()
