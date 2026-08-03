import Foundation
import CoreGraphics
import ApplicationServices

// Prints the phase fields of every scroll event on the system.
//
// Exists because guessing what an app needs in order to stop coasting has now
// failed twice. A real trackpad already does the thing we are trying to
// reproduce, so the fastest way to learn the sequence is to watch one.
//
// The interesting capture is: flick two fingers to start a glide, let it run,
// then put two fingers back down. Whatever macOS emits at that moment is what
// makes Maps stop.

func printUsage() {
    print("""
    scroll-probe — show the phase fields of scroll events

    USAGE
      scroll-probe                  log every scroll event
      scroll-probe --raw            include zero-delta events (there are many)

    Use the BUILT-IN trackpad, with touchd not running, to see what macOS
    itself emits. Then run touchd and compare.

    THE CAPTURE THAT MATTERS
      1. Two-finger flick to start an inertial scroll, over any window.
      2. While it is still gliding, put two fingers back down.
      3. Ctrl-C.

    The line logged at step 2 is the one that stops the glide.

    Needs Accessibility permission.
    """)
}

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--help") || args.contains("-h") { printUsage(); exit(0) }
let showAll = args.contains("--raw")

guard AXIsProcessTrustedWithOptions(
        [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) else {
    print("Accessibility permission required. Approve, then re-run.")
    exit(1)
}

/// Scroll phase is a bit field; momentum phase is a plain enumeration.
func scrollPhaseName(_ value: Int64) -> String {
    switch value {
    case 0: return "—"
    case 1: return "began"
    case 2: return "changed"
    case 4: return "ended"
    case 8: return "cancelled"
    case 128: return "mayBegin"
    default: return "0x\(String(value, radix: 16))"
    }
}

func momentumPhaseName(_ value: Int64) -> String {
    switch value {
    case 0: return "—"
    case 1: return "begin"
    case 2: return "continue"
    case 3: return "end"
    default: return "?\(value)"
    }
}

var start: UInt64 = 0

let callback: CGEventTapCallBack = { _, _, event, _ in
    let now = DispatchTime.now().uptimeNanoseconds
    if start == 0 { start = now }

    let dy = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
    let dx = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
    let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
    let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
    let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous)

    // A resting hand produces a stream of zero-delta, zero-phase events.
    if !showAll, dx == 0, dy == 0, phase == 0, momentum == 0 {
        return Unmanaged.passUnretained(event)
    }

    print(String(format: "%8.3fs  dx %5d  dy %5d   phase %-9@  momentum %-9@  %@",
                 Double(now - start) / 1e9, dx, dy,
                 scrollPhaseName(phase) as NSString,
                 momentumPhaseName(momentum) as NSString,
                 continuous == 1 ? "continuous" : "notched"))
    return Unmanaged.passUnretained(event)
}

guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                  place: .headInsertEventTap,
                                  options: .listenOnly,
                                  eventsOfInterest: 1 << CGEventType.scrollWheel.rawValue,
                                  callback: callback,
                                  userInfo: nil) else {
    print("Failed to create the event tap.")
    exit(1)
}

let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

print("Watching scroll events. Flick to start a glide, then put two fingers")
print("back down. Ctrl-C when done.\n")
CFRunLoopRun()
