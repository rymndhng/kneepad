import Foundation
import CoreGraphics
import ApplicationServices

// Stage 5 reconnaissance.
//
// macOS has no public API for synthesising pinch, rotate or swipe. The values
// live in undocumented CGEvent fields, and guessing the field numbers produces
// events that are silently ignored — the worst possible failure mode.
//
// So: measure instead. This installs a listen-only event tap over the gesture
// event types and dumps every populated field of whatever Apple's own trackpad
// emits. Perform a pinch on the built-in or Magic Trackpad and read off the
// encoding, rather than trusting anyone's remembered constants.

func printUsage() {
    print("""
    gesture-probe — discover the undocumented gesture CGEvent encoding

    USAGE
      gesture-probe                 dump gesture events from an Apple trackpad
      gesture-probe --all-fields    show zero-valued fields too
      gesture-probe --types A,B     watch specific CGEvent type numbers

    Perform pinch / rotate / two-finger swipe on an APPLE trackpad. The ZSA pad
    cannot produce these — that is the whole point of the exercise.

    Needs Accessibility permission.
    """)
}

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--help") || args.contains("-h") { printUsage(); exit(0) }
let showAllFields = args.contains("--all-fields")

/// AppKit's NSEvent type numbers for gesture events. These are public as
/// NSEvent types; what's undocumented is their CGEvent field layout.
let gestureTypes: [UInt32: String] = [
    18: "NSEventTypeRotate",
    19: "NSEventTypeBeginGesture",
    20: "NSEventTypeEndGesture",
    29: "NSEventTypeGesture",
    30: "NSEventTypeMagnify",
    31: "NSEventTypeSwipe",
    32: "NSEventTypeSmartMagnify",
]

var watched: [UInt32: String] = gestureTypes
if let i = args.firstIndex(of: "--types"), i + 1 < args.count {
    watched = [:]
    for part in args[i + 1].split(separator: ",") {
        if let n = UInt32(part.trimmingCharacters(in: .whitespaces)) {
            watched[n] = gestureTypes[n] ?? "type \(n)"
        }
    }
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
for type in watched.keys { mask |= (1 << CGEventMask(type)) }

/// Fields worth probing. CGEventField is a sparse enum; the gesture values live
/// in the undocumented range, so sweep rather than assume.
let fieldRange: [UInt32] = Array(0...200)

var seenSignatures = Set<String>()
var eventCount = 0

let callback: CGEventTapCallBack = { _, type, event, _ in
    let raw = UInt32(type.rawValue)
    eventCount += 1

    var integers: [(UInt32, Int64)] = []
    var doubles: [(UInt32, Double)] = []
    for field in fieldRange {
        guard let f = CGEventField(rawValue: field) else { continue }
        let i = event.getIntegerValueField(f)
        let d = event.getDoubleValueField(f)
        if showAllFields || i != 0 { integers.append((field, i)) }
        if d != 0 && Double(i) != d { doubles.append((field, d)) }
    }

    // Collapse repeats: the interesting output is the shape, not every frame.
    let signature = "\(raw)-" + integers.map { "\($0.0)" }.joined(separator: ",")
    let isNew = seenSignatures.insert(signature).inserted

    let name = watched[raw] ?? gestureTypes[raw] ?? "type \(raw)"
    print("\n── \(name) (CGEventType \(raw))\(isNew ? "  ★ new field shape" : "")")
    for (field, value) in integers {
        print(String(format: "   int    field %3d = %d", field, value))
    }
    for (field, value) in doubles {
        print(String(format: "   double field %3d = %.6f", field, value))
    }
    return Unmanaged.passUnretained(event)
}

guard let tap = CGEvent.tapCreate(tap: .cghidEventTap,
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

print("Watching CGEvent types: "
    + watched.keys.sorted().map { "\($0) (\(watched[$0]!))" }.joined(separator: ", "))
print("""

Now, on an APPLE trackpad:
  1. pinch to zoom      → expect NSEventTypeMagnify
  2. two-finger rotate  → expect NSEventTypeRotate
  3. three-finger swipe → expect NSEventTypeSwipe

Each distinct field shape is marked ★. Ctrl-C when done.
""")

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    print("\n\n\(eventCount) events, \(seenSignatures.count) distinct field shapes")
    exit(0)
}
sigint.resume()

CFRunLoopRun()
