import Foundation

/// Where a scroll is in its lifecycle. Mirrors the phase vocabulary AppKit
/// expects, so apps get proper began/changed/ended and rubber-banding.
public enum ScrollPhase {
    case began, changed, ended
}

public struct ScrollUpdate {
    public init(phase: ScrollPhase, delta: Point, velocity: Point) {
        self.phase = phase
        self.delta = delta
        self.velocity = velocity
    }

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
    /// this ratio, *and* the fingers are moving against each other, treat the
    /// motion as a pinch and refuse to scroll.
    ///
    /// The second condition is not optional. Fingers rest side by side, so the
    /// line between them is horizontal: a vertical scroll hardly changes the
    /// gap at all — 20mm apart, moved 1mm up, the distance grows by 0.025mm —
    /// while a sideways swipe changes it one-for-one with any difference
    /// between the two fingers. And the centroid moves only half as far as a
    /// finger that leads, so a 2mm lead reads as 1mm of travel against 2mm of
    /// spread: rejected, every time, at exactly the moment of activation.
    ///
    /// So this test on its own rejected sideways swipes as pinches, and only
    /// the geometry of vertical scrolling hid it. What actually distinguishes a
    /// pinch is that the fingers move in *opposite* directions; one finger
    /// leading the other is not a pinch however much the gap changes.
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

    /// Which directions a scroll is allowed to move in. Decided once, when the
    /// scroll engages, and kept until the fingers lift.
    public enum Axis {
        case vertical, horizontal, free
    }

    /// Snap each scroll to one axis unless it clearly started diagonal.
    ///
    /// Apps choose the axis from the first few events, and the first event
    /// fires after well under a millimetre of travel. A vertical swipe that
    /// begins even slightly crooked can read as sideways at that scale, and a
    /// carousel or code block under the cursor takes the whole gesture.
    public var axisLockEnabled = true
    /// Lock vertical when sideways travel is less than this multiple of
    /// vertical travel at activation — anything within ~56° of vertical. Wider
    /// than the horizontal zone on purpose: most scrolling is vertical, and
    /// snagging on a horizontal element is the worse mistake.
    public var verticalLockSlope = 1.5
    /// Lock horizontal when vertical travel is less than this multiple of
    /// sideways travel — within ~17° of horizontal. Between the two zones the
    /// scroll stays free, so panning a map diagonally still works.
    public var horizontalLockSlope = 0.3

    private enum State {
        case idle
        /// Two fingers down, not yet moved far enough to commit. Each finger's
        /// starting position is kept by track ID, because telling a pinch from
        /// a swipe needs to know which way each one went, not just where the
        /// pair ended up.
        case pending(origin: TwoFingerState, positions: [Int: Point])
        case scrolling(last: Point, axis: Axis)
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

    private func positions(of tracks: [Track]) -> [Int: Point] {
        Dictionary(tracks.map { ($0.id, $0.position) }, uniquingKeysWith: { first, _ in first })
    }

    /// Did the fingers travel in opposing directions since the gesture began?
    ///
    /// This is what a pinch is. A swipe where one finger leads gives a dot
    /// product of zero — the other finger has not moved — and both fingers
    /// going the same way gives a positive one; neither is a pinch.
    ///
    /// Returns true if the starting positions are not available, which happens
    /// only when a track was replaced mid-gesture. Falling back to the old
    /// spread test there keeps the conservative behaviour for a case we cannot
    /// judge.
    private func movingAgainstEachOther(_ tracks: [Track],
                                        from origins: [Int: Point]) -> Bool {
        guard tracks.count == 2,
              let startA = origins[tracks[0].id],
              let startB = origins[tracks[1].id] else { return true }
        let a = tracks[0].position - startA
        let b = tracks[1].position - startB
        return a.x * b.x + a.y * b.y < 0
    }

    /// The axis a scroll that has travelled `travel` so far should keep to.
    private func axis(for travel: Point) -> Axis {
        guard axisLockEnabled else { return .free }
        let dx = abs(travel.x), dy = abs(travel.y)
        if dx < dy * verticalLockSlope { return .vertical }
        if dy < dx * horizontalLockSlope { return .horizontal }
        return .free
    }

    private func constrain(_ p: Point, to axis: Axis) -> Point {
        switch axis {
        case .vertical: return Point(x: 0, y: p.y)
        case .horizontal: return Point(x: p.x, y: 0)
        case .free: return p
        }
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
            // Momentum is seeded from this velocity, so constraining it keeps
            // the glide on the same axis as the scroll.
            guard case .scrolling(_, let axis) = state else {
                state = .idle
                history.removeAll()
                return nil
            }
            let velocity = constrain(releaseVelocity(), to: axis)
            state = .idle
            history.removeAll()
            return ScrollUpdate(phase: .ended, delta: Point(x: 0, y: 0), velocity: velocity)
        }

        switch state {
        case .idle:
            state = .pending(origin: now, positions: positions(of: usable))
            record(now.centroid, dt)
            return nil

        case .pending(let origin, let startPositions):
            record(now.centroid, dt)
            let travel = (now.centroid - origin.centroid).magnitude
            guard travel >= activationDistance else { return nil }

            // Fingers converging or diverging faster than they translate, and
            // doing it against each other, is a pinch; bail out rather than
            // scrolling the view sideways.
            let spreadChange = abs(now.spread - origin.spread)
            if spreadChange > travel * pinchRejectionRatio,
               movingAgainstEachOther(usable, from: startPositions) {
                state = .idle
                history.removeAll()
                return nil
            }

            let delta = now.centroid - origin.centroid
            let axis = axis(for: delta)
            state = .scrolling(last: now.centroid, axis: axis)
            return ScrollUpdate(phase: .began,
                                delta: constrain(delta, to: axis),
                                velocity: constrain(meanVelocity(usable), to: axis))

        case .scrolling(let last, let axis):
            record(now.centroid, dt)
            state = .scrolling(last: now.centroid, axis: axis)
            return ScrollUpdate(phase: .changed,
                                delta: constrain(now.centroid - last, to: axis),
                                velocity: constrain(meanVelocity(usable), to: axis))
        }
    }

    public func reset() {
        state = .idle
        history.removeAll()
    }
}
