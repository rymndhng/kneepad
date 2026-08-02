import Foundation

public enum MouseButton {
    case left, right, middle
}

public enum PointerEvent {
    /// Cursor movement, in millimetres of finger travel.
    case move(Point)
    /// A completed tap. `count` is 2 for a double tap.
    case tap(MouseButton, count: Int)
    /// Physical button on the pad pressed or released.
    case buttonChanged(MouseButton, down: Bool)
}

/// Recognises pointer motion, taps and physical clicks from tracked contacts.
///
/// Pure logic — no CoreGraphics, no hardware — so the timing rules are testable
/// offline. Two-finger gestures belong to `ScrollRecognizer`; this deliberately
/// stays out of the way whenever more than one finger is down.
public final class PointerRecognizer {

    /// Longest a touch can last and still count as a tap.
    public var tapMaxDuration = 0.25
    /// Furthest a finger can travel and still count as a tap.
    public var tapMaxTravel = 2.0
    /// Maximum gap between taps for the second to be a double.
    public var doubleTapInterval = 0.4
    /// How far apart two taps can land and still pair up.
    public var doubleTapMaxDistance = 8.0
    /// Two-finger tap produces a right click.
    public var twoFingerTapEnabled = true
    /// Ignore contacts the hardware marks as not confident.
    public var requireConfidence = true

    /// State for the current touch sequence — from first finger down to last up.
    private struct Sequence {
        var duration = 0.0
        var travel = 0.0
        /// Most fingers seen at once during this sequence. Pointer motion is
        /// only emitted while this is 1.
        var maxContacts = 0
        var lastPosition: Point?
        var startPosition: Point?
    }

    private var sequence: Sequence?
    private var buttonsDown: [Bool] = []

    /// When and where the last tap landed, for double-tap pairing.
    private var lastTapPosition: Point?
    private var timeSinceLastTap = Double.infinity
    private var lastTapCount = 0

    public init() {}

    /// True while a single finger is driving the cursor.
    public var isPointing: Bool { sequence?.maxContacts == 1 }

    public func reset() {
        sequence = nil
        lastTapPosition = nil
        timeSinceLastTap = .infinity
        lastTapCount = 0
    }

    /// - Parameters:
    ///   - tracks: currently active contacts
    ///   - buttons: physical button states from the report
    ///   - dt: seconds since the previous frame
    public func update(tracks: [Track], buttons: [Bool] = [], dt: Double) -> [PointerEvent] {
        var events: [PointerEvent] = []
        timeSinceLastTap += dt

        events.append(contentsOf: updateButtons(buttons))

        let usable = requireConfidence ? tracks.filter(\.confident) : tracks

        guard !usable.isEmpty else {
            if let finished = sequence {
                if let tap = tapEvent(for: finished) { events.append(tap) }
                sequence = nil
            }
            return events
        }

        var current = sequence ?? Sequence()
        current.duration += dt
        current.maxContacts = max(current.maxContacts, usable.count)

        // The primary contact is the oldest one still down, so a second finger
        // landing doesn't yank the cursor to a new position.
        let primary = usable.min { $0.id < $1.id }!

        if current.startPosition == nil { current.startPosition = primary.position }
        if let last = current.lastPosition {
            let step = primary.position - last
            current.travel += step.magnitude

            // Only one finger may drive the cursor. A sequence that ever had
            // two fingers stays suppressed until every finger lifts, so the
            // straggler from a scroll can't jump the pointer.
            if current.maxContacts == 1 {
                events.append(.move(step))
            }
        }
        current.lastPosition = primary.position
        sequence = current

        return events
    }

    // MARK: Taps

    private func tapEvent(for sequence: Sequence) -> PointerEvent? {
        guard sequence.duration <= tapMaxDuration,
              sequence.travel <= tapMaxTravel,
              let position = sequence.startPosition else { return nil }

        let button: MouseButton
        switch sequence.maxContacts {
        case 1: button = .left
        case 2 where twoFingerTapEnabled: button = .right
        default: return nil
        }

        // Only left taps pair into double clicks.
        var count = 1
        if button == .left,
           timeSinceLastTap <= doubleTapInterval,
           let previous = lastTapPosition,
           (position - previous).magnitude <= doubleTapMaxDistance {
            count = lastTapCount + 1
        }

        lastTapPosition = position
        timeSinceLastTap = 0
        lastTapCount = count
        return .tap(button, count: count)
    }

    // MARK: Physical buttons

    private func updateButtons(_ buttons: [Bool]) -> [PointerEvent] {
        guard !buttons.isEmpty else { return [] }
        if buttonsDown.count != buttons.count {
            buttonsDown = Array(repeating: false, count: buttons.count)
        }

        var events: [PointerEvent] = []
        for (index, isDown) in buttons.enumerated() where isDown != buttonsDown[index] {
            buttonsDown[index] = isDown
            let button: MouseButton
            switch index {
            case 0: button = .left
            case 1: button = .right
            default: button = .middle
            }
            events.append(.buttonChanged(button, down: isDown))
        }
        return events
    }
}
