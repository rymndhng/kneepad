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
    /// Finger velocity in mm/s. On `.ended` this is the release velocity that
    /// momentum is seeded from, measured over a window before liftoff.
    public let velocity: Point
}

/// Recognises two-finger scrolling from tracked contacts.
///
/// Pure logic: no CoreGraphics, no hardware. Takes tracks in, emits phase
/// transitions out, so the whole state machine is testable offline.
public final class ScrollRecognizer {

    /// Millimetres the centroid must travel before scrolling engages. Prevents
    /// a two-finger rest from nudging the view.
    public var activationDistance = 0.73

    /// If the gap between fingers changes faster than the centroid moves by
    /// this ratio, treat the motion as a pinch and refuse to scroll.
    public var pinchRejectionRatio = 1.2

    /// Require both contacts to be confident before scrolling.
    public var requireConfidence = true

    /// Frames of centroid history to retain. Must comfortably cover
    /// `liftoffDiscardFrames` plus `releaseWindow` worth of frames.
    public var historyDepth = 16

    /// Frames immediately before liftoff to ignore when measuring release
    /// velocity. As fingers leave the surface the contact area shrinks and the
    /// reported centroid drifts, so the last frames show a spurious slowdown —
    /// sampling them turns a fast flick into no momentum at all.
    public var liftoffDiscardFrames = 2

    /// Seconds of travel to measure release velocity over. Long enough to
    /// average out per-frame noise, short enough that a deliberate pause before
    /// lifting reads as a stop rather than a flick.
    public var releaseWindow = 0.05

    /// If the fingers travelled less than `stopTravel` in the last
    /// `stopWindow` seconds, treat it as a deliberate stop and produce no
    /// momentum at all, however fast they were moving before.
    ///
    /// Needed because `releaseWindow` ends `liftoffDiscardFrames` before the
    /// lift, so a pause shorter than that gap never lands in the measurement
    /// and the scroll still flings — which reads as the content refusing to
    /// stop when you told it to.
    public var stopWindow = 0.07
    /// Per-frame travel below which a frame counts as stationary.
    public var stopFrameTravel = 0.22

    private enum State {
        case idle
        /// Two fingers down, not yet moved far enough to commit.
        case pending(origin: TwoFingerState, spread: Double)
        case scrolling(last: Point)
    }

    /// Centroid position and the time elapsed arriving at it.
    private struct Sample {
        let centroid: Point
        let dt: Double
    }

    private var state: State = .idle
    private var history: [Sample] = []

    public init() {}

    public var isScrolling: Bool {
        if case .scrolling = state { return true }
        return false
    }

    // MARK: History

    private func record(_ centroid: Point, _ dt: Double) {
        history.append(Sample(centroid: centroid, dt: dt))
        if history.count > historyDepth { history.removeFirst() }
    }

    /// Release velocity by finite difference over `releaseWindow`, ending
    /// `liftoffDiscardFrames` before the lift.
    ///
    /// Deliberately not derived from the tracks' smoothed velocity: an
    /// exponential average retains stale speed long after the finger has
    /// stopped, so a drag that halts before lifting would still fling.
    /// Displacement over a fixed window is naturally zero when nothing moved.
    /// Did the fingers come to rest before lifting?
    ///
    /// Counts the unbroken run of stationary frames at the end of the gesture.
    /// Both a duration and a frame count are required, because liftoff drift
    /// also looks stationary — but only for a frame or two. Demanding more
    /// frames than `liftoffDiscardFrames` is what separates "the user stopped"
    /// from "the fingers are leaving the surface".
    private func hasStopped() -> Bool {
        guard history.count >= 2 else { return false }

        var frames = 0
        var elapsed = 0.0
        var index = history.count - 1
        while index > 0 {
            let step = (history[index].centroid - history[index - 1].centroid).magnitude
            if step > stopFrameTravel { break }
            elapsed += history[index].dt
            frames += 1
            index -= 1
        }
        return elapsed >= stopWindow && frames >= liftoffDiscardFrames + 2
    }

    private func releaseVelocity() -> Point {
        // A deliberate stop beats any earlier speed.
        if hasStopped() { return Point(x: 0, y: 0) }

        var samples = history
        if samples.count > liftoffDiscardFrames + 1 {
            samples.removeLast(liftoffDiscardFrames)
        }
        guard samples.count >= 2, let end = samples.last else { return Point(x: 0, y: 0) }

        // Walk backwards until the window is covered or history runs out.
        var elapsed = 0.0
        var index = samples.count - 1
        while index > 0 && elapsed < releaseWindow {
            elapsed += samples[index].dt
            index -= 1
        }
        guard elapsed > 0 else { return Point(x: 0, y: 0) }

        let displacement = end.centroid - samples[index].centroid
        return Point(x: displacement.x / elapsed, y: displacement.y / elapsed)
    }

    /// Mean velocity of the two contacts — the pair moves as one unit.
    private func meanVelocity(_ tracks: [Track]) -> Point {
        guard !tracks.isEmpty else { return Point(x: 0, y: 0) }
        let sum = tracks.reduce(Point(x: 0, y: 0)) { $0 + $1.velocity }
        return Point(x: sum.x / Double(tracks.count), y: sum.y / Double(tracks.count))
    }

    // MARK: Update

    /// - Parameter dt: seconds since the previous frame, from Scan Time.
    public func update(tracks: [Track], dt: Double) -> ScrollUpdate? {
        let usable = requireConfidence ? tracks.filter(\.confident) : tracks

        guard usable.count == 2, let now = TwoFingerState(usable) else {
            // Fewer (or more) than two fingers ends any scroll in progress.
            let wasScrolling = isScrolling
            let velocity = wasScrolling ? releaseVelocity() : Point(x: 0, y: 0)
            state = .idle
            history.removeAll()
            guard wasScrolling else { return nil }
            return ScrollUpdate(phase: .ended, delta: Point(x: 0, y: 0), velocity: velocity)
        }

        switch state {
        case .idle:
            state = .pending(origin: now, spread: now.spread)
            record(now.centroid, dt)
            return nil

        case .pending(let origin, let startSpread):
            record(now.centroid, dt)
            let travel = (now.centroid - origin.centroid).magnitude
            guard travel >= activationDistance else { return nil }

            // Fingers converging or diverging faster than they translate is a
            // pinch; bail out rather than scrolling the view sideways.
            let spreadChange = abs(now.spread - startSpread)
            if spreadChange > travel * pinchRejectionRatio {
                state = .idle
                history.removeAll()
                return nil
            }

            state = .scrolling(last: now.centroid)
            return ScrollUpdate(phase: .began,
                                delta: now.centroid - origin.centroid,
                                velocity: meanVelocity(usable))

        case .scrolling(let last):
            record(now.centroid, dt)
            state = .scrolling(last: now.centroid)
            return ScrollUpdate(phase: .changed,
                                delta: now.centroid - last,
                                velocity: meanVelocity(usable))
        }
    }

    public func reset() {
        state = .idle
        history.removeAll()
    }
}
