import Foundation
import CoreGraphics
import ApplicationServices

// Measures what happens AFTER CGEventPost.
//
// Everything upstream has been ruled out: the raw trackpad data stops when the
// finger stops, the frame handler runs in under 0.5ms against a 6.5ms budget,
// and disabling our filtering changes nothing. The remaining suspect is the
// WindowServer itself — if it consumes posted mouse events more slowly than we
// produce them, a backlog builds during movement and drains afterwards, which
// is exactly lag that outlasts the gesture.
//
// This posts events at a chosen rate for a fixed time, then watches how long
// the cursor keeps moving after the last post. No trackpad involved.

func printUsage() {
    print("""
    pointer-latency — measure post-to-cursor lag and WindowServer backlog

    USAGE
      pointer-latency                  1s at 154Hz, the trackpad's report rate
      pointer-latency --rate N         events per second (default 154)
      pointer-latency --duration N     seconds to post for (default 1.0)
      pointer-latency --step N         pixels per event (default 2)
      pointer-latency --observe        log cursor deltas from ANY device, as CSV

    The cursor moves during the test and is restored afterwards.

    Reads: if the cursor keeps moving well after the last post, the
    WindowServer is behind and the fix is to post fewer events.
    """)
}

/// Timestamp of the first observed event. File scope because a C function
/// pointer cannot capture context.
var observeStart: UInt64 = 0

/// So the header/prompt can go to stderr and keep stdout clean CSV.
struct StandardError: TextOutputStream {
    func write(_ string: String) { FileHandle.standardError.write(Data(string.utf8)) }
}
var standardError = StandardError()

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--help") || args.contains("-h") { printUsage(); exit(0) }

// MARK: - Observe mode
//
// Every layer we control measures clean, so the remaining question is what
// "correct" even looks like. This taps mouseMoved events and prints the
// per-event delta, so the same gesture can be recorded on Apple's trackpad and
// on ours and the deceleration profiles compared directly.

if args.contains("--observe") {
    guard AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) else {
        print("Accessibility permission required. Approve, then re-run.")
        exit(1)
    }

    let mask: CGEventMask =
        (1 << CGEventType.mouseMoved.rawValue) |
        (1 << CGEventType.leftMouseDragged.rawValue)

    let callback: CGEventTapCallBack = { _, _, event, _ in
        let now = DispatchTime.now().uptimeNanoseconds
        if observeStart == 0 { observeStart = now }
        let dx = event.getIntegerValueField(.mouseEventDeltaX)
        let dy = event.getIntegerValueField(.mouseEventDeltaY)
        // Skip the resting stream of zero-delta events.
        if dx != 0 || dy != 0 {
            print(String(format: "%.1f,%d,%d",
                         Double(now - observeStart) / 1e6, dx, dy))
        }
        return Unmanaged.passUnretained(event)
    }

    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                      place: .headInsertEventTap,
                                      options: .listenOnly,
                                      eventsOfInterest: mask,
                                      callback: callback,
                                      userInfo: nil) else {
        print("Failed to create the event tap."); exit(1)
    }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    print("ms_since_first,deltaX,deltaY")
    print("# Do ONE fast swipe then stop dead. Ctrl-C when done.", to: &standardError)
    CFRunLoopRun()
    exit(0)
}

func value(_ flag: String, _ fallback: Double) -> Double {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count,
          let v = Double(args[i + 1]) else { return fallback }
    return v
}

let rate = value("--rate", 154)
let duration = value("--duration", 1.0)
let step = value("--step", 2)

guard AXIsProcessTrustedWithOptions(
        [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) else {
    print("Accessibility permission required. Approve, then re-run.")
    exit(1)
}

func cursorPosition() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

let origin = cursorPosition()
let interval = 1.0 / rate
let count = Int(duration * rate)

print("Posting \(count) events at \(Int(rate))Hz for \(duration)s, \(Int(step))px each…")
print("Expected total travel: \(Int(Double(count) * step))px\n")

// Post a there-and-back sweep so the cursor stays near where it started.
var posted = CGPoint(x: origin.x, y: origin.y)
let postStart = DispatchTime.now()

for i in 0..<count {
    let direction: Double = (i / 50) % 2 == 0 ? 1 : -1
    posted.x += step * direction
    guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                              mouseCursorPosition: posted,
                              mouseButton: .left) else { continue }
    event.setIntegerValueField(.mouseEventDeltaX, value: Int64(step * direction))
    event.setIntegerValueField(.mouseEventDeltaY, value: 0)
    event.post(tap: .cghidEventTap)

    // Busy-wait to hit the target rate accurately; usleep granularity is too
    // coarse at 154Hz and would understate the posting rate.
    let deadline = postStart.uptimeNanoseconds + UInt64(Double(i + 1) * interval * 1e9)
    while DispatchTime.now().uptimeNanoseconds < deadline { }
}

let lastPost = DispatchTime.now()
let elapsed = Double(lastPost.uptimeNanoseconds - postStart.uptimeNanoseconds) / 1e9
print(String(format: "Posted in %.3fs (%.0f Hz actual)", elapsed, Double(count) / elapsed))

// Watch the cursor settle.
var samples: [(Double, CGPoint)] = []
var lastChange = lastPost
var previous = cursorPosition()
let watchDeadline = lastPost.uptimeNanoseconds + UInt64(2.0 * 1e9)

while DispatchTime.now().uptimeNanoseconds < watchDeadline {
    let now = cursorPosition()
    let t = Double(DispatchTime.now().uptimeNanoseconds - lastPost.uptimeNanoseconds) / 1e9
    if abs(now.x - previous.x) > 0.5 || abs(now.y - previous.y) > 0.5 {
        lastChange = DispatchTime.now()
        samples.append((t, now))
    }
    previous = now
    // Stop early once it has been still for 250ms.
    if Double(DispatchTime.now().uptimeNanoseconds - lastChange.uptimeNanoseconds) / 1e9 > 0.25 {
        break
    }
    usleep(500)
}

let settle = Double(lastChange.uptimeNanoseconds - lastPost.uptimeNanoseconds) / 1e9
let final = cursorPosition()

print(String(format: "\nCursor kept moving for %.0f ms after the last post", settle * 1000))
print("  \(samples.count) position changes observed after posting stopped")
if let first = samples.first, let last = samples.last {
    print(String(format: "  from %.0f,%.0f to %.0f,%.0f over that window",
                 first.1.x, first.1.y, last.1.x, last.1.y))
}
print(String(format: "  final position %.0f,%.0f  (expected %.0f,%.0f)",
             final.x, final.y, posted.x, posted.y))

print("")
if settle > 0.05 {
    print("⚠️  BACKLOG: the WindowServer is consuming events more slowly than")
    print("    they were posted. Motion continues after input stops — post fewer,")
    print("    larger events instead of one per HID report.")
} else {
    print("✓  No backlog: the cursor tracks posting closely, so lag is not")
    print("   coming from the event pipeline.")
}

// Put it back where we found it.
if let restore = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                         mouseCursorPosition: origin, mouseButton: .left) {
    restore.post(tap: .cghidEventTap)
}
print("Cursor restored.")
