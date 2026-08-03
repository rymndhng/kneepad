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
    public var tapMaxDuration = 0.4
    /// Furthest a finger can travel and still count as a tap.
    public var tapMaxTravel = 2.0

    /// Two-finger equivalents, deliberately looser.
    ///
    /// Two fingers do not land or lift together the way one does: the sequence
    /// starts on the first touchdown and ends on the last liftoff, so it spans
    /// both fingers' timing slop, and the primary contact rolls further while
    /// the second finger arrives. Reusing the one-finger numbers rejected most
    /// real two-finger taps.
    public var twoFingerTapMaxDuration = 0.6
    public var twoFingerTapMaxTravel = 4.0

    /// Maximum gap between taps for the second to be a double — measured from
    /// the first tap lifting to the second finger landing, so it is
    /// independent of how long either tap itself takes.
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
        /// Distinct fingers seen over the whole sequence, overlapping or not.
        ///
        /// Two fingers tapped together often miss each other by a frame — one
        /// lifts as the other lands — so they never coexist in a single report
        /// and `maxContacts` stays 1. That turned a right click into a left
        /// one. Track IDs are monotonic and never recycled, so counting them is
        /// safe: a sequence ends the moment every finger is up, and a genuine
        /// second single tap therefore starts a fresh sequence.
        var contactIDs = Set<Int>()
        var lastPosition: Point?
        var startPosition: Point?
        /// Which track `lastPosition` belongs to. Diffing positions across a
        /// change of primary would measure the gap between two fingers, not
        /// motion — tens of millimetres of phantom travel, and a cursor jump.
        var primaryID: Int?

        /// How many fingers this sequence should be judged as.
        var fingerCount: Int { max(maxContacts, contactIDs.count) }
    }

    private var sequence: Sequence?
    private var buttonsDown: [Bool] = []

    /// Why the last finished touch was not a tap, for `--verbose`. A tap that
    /// silently does nothing is otherwise indistinguishable from one that was
    /// never recognised at all.
    public private(set) var lastTapRejection: String?

    /// When and where the last tap landed, for double-tap pairing.
    private var lastTapPosition: Point?
    private var timeSinceLastTap = Double.infinity
    private var lastTapCount = 0

    public init() {}

    /// True while a single finger is driving the cursor.
    public var isPointing: Bool { sequence?.maxContacts == 1 }

    public func reset() {
        sequence = nil
        lastTapRejection = nil
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
        for track in usable { current.contactIDs.insert(track.id) }

        // The primary contact is the oldest one still down, so a second finger
        // landing doesn't yank the cursor to a new position.
        let primary = usable.min { $0.id < $1.id }!

        if current.startPosition == nil { current.startPosition = primary.position }

        // A change of primary — the oldest finger lifted while another stayed
        // down — is a discontinuity, not movement. Re-seed and skip this frame.
        if current.primaryID != primary.id {
            current.primaryID = primary.id
            current.lastPosition = primary.position
            sequence = current
            return events
        }

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
        let fingers = sequence.fingerCount

        let button: MouseButton
        switch fingers {
        case 1: button = .left
        case 2 where twoFingerTapEnabled: button = .right
        case 2: lastTapRejection = "two-finger tap disabled"; return nil
        default:
            lastTapRejection = "\(fingers) fingers — no tap gesture"
            return nil
        }

        // Two fingers get their own, looser budget; see the property comments.
        let maxDuration = fingers >= 2 ? twoFingerTapMaxDuration : tapMaxDuration
        let maxTravel = fingers >= 2 ? twoFingerTapMaxTravel : tapMaxTravel

        guard sequence.duration <= maxDuration else {
            // Seconds, because that is the unit --two-tap-time takes.
            lastTapRejection = String(format: "%d-finger touch held %.2fs (max %.2fs)",
                                      fingers, sequence.duration, maxDuration)
            return nil
        }
        guard sequence.travel <= maxTravel else {
            lastTapRejection = String(format: "%d-finger touch travelled %.1f mm (max %.1f)",
                                      fingers, sequence.travel, maxTravel)
            return nil
        }
        guard let position = sequence.startPosition else { return nil }
        lastTapRejection = nil

        // Only left taps pair into double clicks.
        //
        // The window is the gap between the taps — from the first liftoff to
        // the second touchdown. `timeSinceLastTap` runs from the first liftoff
        // to *now*, which is the second liftoff, so the second tap's own
        // duration has to come back out. Leaving it in charged the tap against
        // the window it was trying to land in: once tapMaxDuration reached
        // doubleTapInterval, a tap held for the full budget could never pair,
        // and raising --tap-time silently made double clicks harder.
        let gap = timeSinceLastTap - sequence.duration

        var count = 1
        if button == .left,
           gap <= doubleTapInterval,
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
