import Foundation
import CoreGraphics
import HIDCore

/// Remembers which mouse-down the current press of each button belongs to.
///
/// AppKit's tracking loops — the one that drags a window by its title bar, the
/// one that rubber-bands a selection — pair a drag with the press that opened
/// it by `NSEvent.eventNumber`. A `…MouseDragged` carrying a different number
/// is not the drag they are waiting for and is dropped, silently. Posting the
/// right *type* of event is only half of it; see `PointerSynthesizer.move`.
///
/// The number cannot be guessed. It is stamped by the window server, it is not
/// the `CGEventSourceCounterForEventType` count (measured: counter 446 while
/// live presses were numbered 209–211), and a null event reads it back as 0.
/// The only way to learn the number of a press we did not post is to watch it
/// go by, which is what the tap here is for.
///
/// Watching also covers our *own* presses, rather than assuming they come out
/// as zero: the number a posted event ends up carrying is the window server's
/// to decide, and reading it back is how this stays right either way.
public final class ButtonWatch {

    /// The event number of the most recent press of each button.
    ///
    /// Never cleared on the release. A drag only happens while a button is
    /// held, so the last press of a held button *is* its press — whereas a
    /// release that clears the entry leaves a window in which a drag still in
    /// flight would be stamped 0 and dropped.
    private var numbers: [MouseButton: Int64] = [:]

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var mode: CFRunLoopMode = .commonModes

    public init() {}

    // MARK: Bookkeeping

    /// The number to stamp on a drag attributed to `button`.
    ///
    /// Zero for a press that was never seen — the value the field had before
    /// any of this existed, so a driver whose tap failed to start behaves
    /// exactly as it used to rather than worse.
    public func number(for button: MouseButton) -> Int64 { numbers[button] ?? 0 }

    /// Record a press, keyed by `CGMouseButton`'s numbering.
    ///
    /// Buttons past the middle one are ignored: `anyButtonDown` only ever
    /// attributes a drag to left, right or middle, so a mouse's back button
    /// has no drag to stamp and must not overwrite the middle one's press.
    public func record(button: Int64, number: Int64) {
        switch button {
        case 0: numbers[.left] = number
        case 1: numbers[.right] = number
        case 2: numbers[.middle] = number
        default: break
        }
    }

    // MARK: The tap

    private static let mask: CGEventMask =
        (CGEventMask(1) << CGEventMask(CGEventType.leftMouseDown.rawValue))
        | (CGEventMask(1) << CGEventMask(CGEventType.rightMouseDown.rawValue))
        | (CGEventMask(1) << CGEventMask(CGEventType.otherMouseDown.rawValue))

    /// Begin watching. Returns false if the tap could not be created, which in
    /// practice means Accessibility was refused.
    ///
    /// Presses only — a listen-only tap still holds up delivery of every event
    /// it is asked for until the callback returns, and the driver has no
    /// business sitting in the path of the whole session's mouse movement to
    /// learn something that changes a few times a minute.
    @discardableResult
    public func start(on runLoop: CFRunLoop = CFRunLoopGetCurrent(),
                      mode: CFRunLoopMode = .commonModes) -> Bool {
        guard tap == nil else { return true }

        let callback: CGEventTapCallBack = { _, type, event, context in
            if let context {
                Unmanaged<ButtonWatch>.fromOpaque(context)
                    .takeUnretainedValue().saw(type, event)
            }
            return Unmanaged.passUnretained(event)
        }

        // Unretained: the driver owns this object and `deinit` tears the tap
        // down, so the callback cannot outlive what it points at.
        guard let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .tailAppendEventTap,
                options: .listenOnly,
                eventsOfInterest: ButtonWatch.mask,
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }

        let loopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(runLoop, loopSource, mode)
        CGEvent.tapEnable(tap: port, enable: true)

        self.tap = port
        self.source = loopSource
        self.runLoop = runLoop
        self.mode = mode
        return true
    }

    public func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source, let runLoop { CFRunLoopRemoveSource(runLoop, source, mode) }
        tap = nil
        source = nil
        runLoop = nil
    }

    deinit { stop() }

    private func saw(_ type: CGEventType, _ event: CGEvent) {
        // A tap that takes too long over a callback is switched off by the
        // system and then delivers nothing at all, quietly. Turning it back on
        // is the only notice we get.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        record(button: event.getIntegerValueField(.mouseEventButtonNumber),
               number: event.getIntegerValueField(.mouseEventNumber))
    }
}
