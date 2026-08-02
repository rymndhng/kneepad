import Foundation

/// Where a scroll is in its lifecycle. Mirrors the phase vocabulary AppKit
/// expects, so apps get proper began/changed/ended and rubber-banding.
public enum ScrollPhase {
    case began, changed, ended
}

public struct ScrollUpdate {
    public let phase: ScrollPhase
    /// Movement since the previous update, in millimetres.
    public let delta: Point
    /// Current finger velocity in mm/s — what momentum is seeded from.
    public let velocity: Point
}

/// Recognises two-finger scrolling from tracked contacts.
///
/// Pure logic: no CoreGraphics, no hardware. Takes tracks in, emits phase
/// transitions out, so the whole state machine is testable offline.
public final class ScrollRecognizer {

    /// Millimetres the centroid must travel before scrolling engages. Prevents
    /// a two-finger rest from nudging the view.
    public var activationDistance = 1.0

    /// If the gap between fingers changes faster than the centroid moves by
    /// this ratio, treat the motion as a pinch and refuse to scroll.
    public var pinchRejectionRatio = 1.2

    /// Require both contacts to be confident before scrolling.
    public var requireConfidence = true

    private enum State {
        case idle
        /// Two fingers down, not yet moved far enough to commit.
        case pending(origin: TwoFingerState, spread: Double)
        /// Velocity is carried here because by the time the fingers lift their
        /// tracks are already gone — momentum would otherwise always get zero.
        case scrolling(last: Point, velocity: Point)
    }

    private var state: State = .idle

    public init() {}

    public var isScrolling: Bool {
        if case .scrolling = state { return true }
        return false
    }

    /// Mean velocity of the two contacts — the pair moves as one unit.
    private func meanVelocity(_ tracks: [Track]) -> Point {
        guard !tracks.isEmpty else { return Point(x: 0, y: 0) }
        let sum = tracks.reduce(Point(x: 0, y: 0)) { $0 + $1.velocity }
        return Point(x: sum.x / Double(tracks.count), y: sum.y / Double(tracks.count))
    }

    public func update(tracks: [Track]) -> ScrollUpdate? {
        let usable = requireConfidence ? tracks.filter(\.confident) : tracks

        guard usable.count == 2, let now = TwoFingerState(usable) else {
            // Fewer (or more) than two fingers ends any scroll in progress.
            if case .scrolling(_, let velocity) = state {
                state = .idle
                return ScrollUpdate(phase: .ended, delta: Point(x: 0, y: 0),
                                    velocity: velocity)
            }
            state = .idle
            return nil
        }

        switch state {
        case .idle:
            state = .pending(origin: now, spread: now.spread)
            return nil

        case .pending(let origin, let startSpread):
            let travel = (now.centroid - origin.centroid).magnitude
            guard travel >= activationDistance else { return nil }

            // Fingers converging or diverging faster than they translate is a
            // pinch; bail out rather than scrolling the view sideways.
            let spreadChange = abs(now.spread - startSpread)
            if spreadChange > travel * pinchRejectionRatio {
                state = .idle
                return nil
            }

            let velocity = meanVelocity(usable)
            state = .scrolling(last: now.centroid, velocity: velocity)
            return ScrollUpdate(phase: .began,
                                delta: now.centroid - origin.centroid,
                                velocity: velocity)

        case .scrolling(let last, _):
            let velocity = meanVelocity(usable)
            state = .scrolling(last: now.centroid, velocity: velocity)
            return ScrollUpdate(phase: .changed,
                                delta: now.centroid - last,
                                velocity: velocity)
        }
    }

    public func reset() { state = .idle }
}
