import Foundation
import CoreGraphics
import ApplicationServices

// Stage 5, second half: synthesis.
//
// Observation took us as far as it can. gesture-probe established the field
// layout of the type-29 gesture events Apple's trackpad emits, but two facts
// mean we cannot derive the recipe by watching alone:
//
//   * NSEventTypeMagnify (30) and Rotate (18) never appear at ANY tap level,
//     so AppKit very likely synthesises them in-process from type 29.
//   * Field 110 is 6 for both pinch and swipe, so it is not the discriminator
//     the name suggested.
//
// The decisive question is not "what does Apple send" but "what makes an app
// zoom". So this posts candidate events and lets a real app answer. Open
// Preview or Safari, run with --delay to focus it, and watch.

func printUsage() {
    print("""
    gesture-emit — post candidate gesture events and see what responds

    USAGE
      gesture-emit --pinch 0.5          pinch out by a magnification total
      gesture-emit --pinch -0.5         pinch in
      gesture-emit --rotate 20          rotate by degrees
      gesture-emit --replay-pinch       replay values captured from Apple's pad
      gesture-emit --delay 3            seconds to focus a target app first
      gesture-emit --hid-type N         override field 110 (default 6, try 7/8)
      gesture-emit --steps N            intermediate .changed events (default 10)
      gesture-emit --verbose            print each event as it is posted

    TESTING
      1. open Preview with an image, or Safari
      2. gesture-emit --delay 3 --pinch 0.5
      3. click the target window during the countdown

    If nothing happens, type 29 alone is insufficient and the remaining route
    is Mac Mouse Fix's implementation (GPL — read for constants, reimplement).
    """)
}

let args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args.contains("--help") || args.contains("-h") {
    printUsage(); exit(0)
}

func value(_ flag: String) -> Double? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return Double(args[i + 1])
}

let verbose = args.contains("--verbose")
let delay = value("--delay") ?? 0
let steps = Int(value("--steps") ?? 10)
let hidType = Int64(value("--hid-type") ?? 6)

guard AXIsProcessTrustedWithOptions(
        [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) else {
    print("Accessibility permission required. Approve, then re-run.")
    exit(1)
}

// MARK: - Field layout, as measured by gesture-probe

enum Field {
    static let gestureType: UInt32 = 110      // 6 on every captured gesture
    static let phase: UInt32 = 132            // NSEventPhase
    static let deviceCount: UInt32 = 135      // always 1

    /// Primary value (magnification on a pinch, delta on a swipe), seen both
    /// as a double and as a Float32 bit pattern in separate fields.
    static let valueDoubles: [UInt32] = [113, 114, 116, 118]
    static let valueFloats: [UInt32] = [115, 117, 164]

    /// Secondary value — rotation in degrees on a pinch.
    static let secondaryDoubles: [UInt32] = [119, 139]
    static let secondaryFloats: [UInt32] = [123, 165]

    static let unknown124: UInt32 = 124
}

/// NSEventPhase, confirmed against captured data.
enum Phase: Int64 {
    case none = 0, began = 1, stationary = 2, changed = 4
    case ended = 8, cancelled = 16, mayBegin = 128
}

/// The sentinel Apple uses for "this field carries no value": Float32 −0.0.
let absent: Int64 = -2147483648

func floatBits(_ value: Double) -> Int64 {
    Int64(Int32(bitPattern: Float(value).bitPattern))
}

func post(phase: Phase, primary: Double?, secondary: Double?) {
    guard let event = CGEvent(source: nil) else { return }
    // Type 29 is NSEventTypeGesture. CGEventType has no case for it, so go
    // through the raw value.
    guard let type = CGEventType(rawValue: 29) else { return }
    event.type = type

    func setInt(_ field: UInt32, _ v: Int64) {
        guard let f = CGEventField(rawValue: field) else { return }
        event.setIntegerValueField(f, value: v)
    }
    func setDouble(_ field: UInt32, _ v: Double) {
        guard let f = CGEventField(rawValue: field) else { return }
        event.setDoubleValueField(f, value: v)
    }

    setInt(Field.gestureType, hidType)
    setInt(Field.phase, phase.rawValue)
    setInt(Field.deviceCount, 1)
    setInt(Field.unknown124, 0)

    // Write both encodings, matching exactly what the captures showed.
    for field in Field.valueDoubles { setDouble(field, primary ?? 0) }
    for field in Field.valueFloats {
        setInt(field, primary.map(floatBits) ?? absent)
    }
    for field in Field.secondaryDoubles { setDouble(field, secondary ?? 0) }
    for field in Field.secondaryFloats {
        setInt(field, secondary.map(floatBits) ?? absent)
    }

    event.post(tap: .cghidEventTap)

    if verbose {
        let p = primary.map { String(format: "%.4f", $0) } ?? "absent"
        let s = secondary.map { String(format: "%.4f", $0) } ?? "absent"
        print("  posted phase=\(phase)  primary=\(p)  secondary=\(s)")
    }
}

/// A full gesture: mayBegin, began, a run of changed, then ended.
func emit(primaryTotal: Double, secondaryTotal: Double, label: String) {
    print("Emitting \(label): primary \(primaryTotal), secondary \(secondaryTotal)")

    post(phase: .mayBegin, primary: nil, secondary: nil)
    usleep(16_000)

    let stepPrimary = primaryTotal / Double(steps)
    let stepSecondary = secondaryTotal / Double(steps)

    post(phase: .began, primary: stepPrimary,
         secondary: secondaryTotal == 0 ? nil : stepSecondary)
    usleep(16_000)

    for _ in 1..<steps {
        post(phase: .changed, primary: stepPrimary,
             secondary: secondaryTotal == 0 ? nil : stepSecondary)
        usleep(16_000)
    }

    post(phase: .ended, primary: nil, secondary: nil)
    print("Done. Did anything respond?")
}

// MARK: - Entry

if delay > 0 {
    print("Focus the target app…")
    for remaining in stride(from: Int(delay), to: 0, by: -1) {
        print("  \(remaining)…")
        usleep(1_000_000)
    }
}

if args.contains("--replay-pinch") {
    // Exact values captured from a real pinch-out on the Magic Trackpad.
    emit(primaryTotal: 0.488785, secondaryTotal: -4.918915, label: "replayed pinch")
} else if let amount = value("--pinch") {
    emit(primaryTotal: amount, secondaryTotal: 0, label: "pinch")
} else if let degrees = value("--rotate") {
    emit(primaryTotal: 0, secondaryTotal: degrees, label: "rotate")
} else {
    printUsage()
    exit(1)
}
