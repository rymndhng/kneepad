import Foundation
import CoreGraphics
import ApplicationServices
import HIDCore

/// Posts scroll events into the macOS input stack.
///
/// `CGEventPost(.cghidEventTap, …)` injects at the bottom of the pipeline, so
/// events flow through the whole stack and every app treats them as genuine
/// input. The phase fields are what make apps render rubber-banding and
/// momentum instead of treating each delta as a discrete wheel click.
public final class ScrollSynthesizer {

    public struct Configuration {
        /// Screen pixels emitted per millimetre of finger travel.
        /// Tuned by hand on the 55mm ZSA pad.
        public var gain = 44.0
        /// Natural scrolling: content follows the fingers.
        ///
        /// The sign below was wrong in both directions until it was checked
        /// against the hardware — `--reverse` produced macOS's natural feel and
        /// the default produced its opposite.
        public var naturalDirection = true
        public var invertHorizontal = false

        /// Finger millimetres to scroll pixels, sign included.
        ///
        /// Pure, so the direction convention can be pinned by a test rather
        /// than rediscovered by scrolling a window. Pad Y grows downward; a
        /// CGEvent scroll delta is positive when content moves the way a wheel
        /// pushed away from you moves it. Natural scrolling means the content
        /// follows the fingers, which works out as passing the sign through
        /// rather than negating it — the opposite of what this code did until
        /// the hardware said otherwise.
        public func pixels(_ millimetres: Point) -> Point {
            let vertical = naturalDirection ? millimetres.y : -millimetres.y
            let horizontal = invertHorizontal ? -millimetres.x : millimetres.x
            return Point(x: horizontal * gain, y: vertical * gain)
        }
        /// Release speed below which momentum isn't worth animating.
        ///
        /// Expressed in **mm/s** rather than px/s so it stays a statement about
        /// how fast the finger moved, independent of `gain`. Otherwise raising
        /// gain silently makes momentum trigger on ever-slower releases.
        public var momentumThreshold = 1.45
        /// Seconds for momentum velocity to decay to 1/e.
        ///
        /// Expressed as a time constant rather than per-tick friction so the
        /// feel is independent of `momentumHz`. Per-tick decay silently
        /// changes the glide whenever the tick rate changes, which is
        /// physically wrong. 0.27s reproduces the hand-tuned 0.96-at-90Hz.
        public var momentumDecayTime = 0.27
        /// Momentum animation rate. Higher is smoother; 120 matches a
        /// ProMotion display's refresh.
        public var momentumHz = 120.0
        public var momentumEnabled = true

        /// Per-tick friction, kept as a convenience for tuning. Reading it
        /// derives from the time constant and the current tick rate.
        public var friction: Double {
            get { exp(-1.0 / (momentumHz * momentumDecayTime)) }
            set {
                guard newValue > 0, newValue < 1 else { return }
                momentumDecayTime = -1.0 / (momentumHz * log(newValue))
            }
        }

        public init() {}
    }

    public var configuration: Configuration

    private var momentumTimer: DispatchSourceTimer?
    private var momentumVelocity = Point(x: 0, y: 0)   // px/s
    /// Sub-pixel remainder, so slow scrolling doesn't get truncated to nothing.
    private var residual = Point(x: 0, y: 0)

    /// True between a `mayBegin` and whatever closes it. See `fingersLifted`.
    private var awaitingBegan = false

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: Permission

    /// Posting events requires Accessibility. Without it CGEventPost silently
    /// does nothing, which is a miserable thing to debug.
    public static func hasAccessibilityPermission(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: Public entry

    public func handle(_ update: ScrollUpdate) {
        switch update.phase {
        case .began:
            cancelMomentum(fingersLanded: true)
            residual = Point(x: 0, y: 0)
            post(delta: pixels(update.delta), phase: .began, momentum: .none)
        case .changed:
            post(delta: pixels(update.delta), phase: .changed, momentum: .none)
        case .ended:
            post(delta: Point(x: 0, y: 0), phase: .ended, momentum: .none)
            if configuration.momentumEnabled {
                startMomentum(velocity: pixels(update.velocity))
            }
        }
    }

    /// Stop any in-flight momentum, and tell the receiving app it has stopped.
    ///
    /// The end event is the part that matters. An app that has seen momentum
    /// begin runs its own animation until it sees momentum end — Maps and any
    /// AppKit scroll view both do — so simply dropping our timer left the view
    /// gliding on with nothing driving it. Putting two fingers back down
    /// looked like it did nothing.
    ///
    /// `fingersLanded` says *why* the glide stopped, and only a hand on the pad
    /// may claim it. Fingers landing also get mayBegin: ending the momentum
    /// phase is the correct protocol and satisfies AppKit scroll views, but
    /// Maps kept gliding anyway, and mayBegin is what a real trackpad sends
    /// when fingers land — the signal an app watches to abandon inertia it is
    /// animating itself.
    ///
    /// A glide that simply ran out, and a driver shutting down, must NOT send
    /// it. mayBegin opens a phase sequence and the window under the cursor
    /// takes hold of it; with no `began` or `cancelled` to close it, that hold
    /// survives, and the *next* scroll is delivered there however far the
    /// cursor has moved in between. Measured with two windows: after a glide
    /// decayed over one of them, a full scroll aimed at the other went
    /// entirely to the first, which is the whole of "scrolling doesn't
    /// consistently scroll what is under the cursor".
    public func cancelMomentum(fingersLanded: Bool) {
        let wasCoasting = momentumTimer != nil
        momentumTimer?.cancel()
        momentumTimer = nil
        momentumVelocity = Point(x: 0, y: 0)
        guard wasCoasting else { return }

        post(delta: Point(x: 0, y: 0), phase: nil, momentum: .end)
        guard fingersLanded else { return }
        post(delta: Point(x: 0, y: 0), phase: .mayBegin, momentum: .none)
    }

    /// Every finger has left the pad.
    ///
    /// Closes a mayBegin that never became a scroll, which is not an edge case:
    /// dropping two fingers on the pad and lifting them again is how you stop a
    /// glide, and it is exactly the path that opens a sequence and never
    /// finishes it. Cancelled is what a real trackpad sends there.
    ///
    /// Silent unless a mayBegin is actually outstanding, so it costs nothing to
    /// call on every liftoff.
    public func fingersLifted() {
        guard awaitingBegan else { return }
        post(delta: Point(x: 0, y: 0), phase: .cancelled, momentum: .none)
    }

    // MARK: Conversion

    private func pixels(_ millimetres: Point) -> Point {
        configuration.pixels(millimetres)
    }

    // MARK: Momentum

    /// The mm/s threshold converted into the px/s space momentum decays in.
    private var momentumFloor: Double {
        configuration.momentumThreshold * configuration.gain
    }

    private func startMomentum(velocity: Point) {
        guard velocity.magnitude >= momentumFloor else {
            post(delta: Point(x: 0, y: 0), phase: nil, momentum: .end)
            return
        }
        momentumVelocity = velocity
        post(delta: Point(x: 0, y: 0), phase: nil, momentum: .begin)

        let interval = 1.0 / configuration.momentumHz
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.stepMomentum(interval) }
        momentumTimer = timer
        timer.resume()
    }

    private func stepMomentum(_ dt: Double) {
        // Time-based decay, so the glide is identical whatever the tick rate.
        let decay = exp(-dt / configuration.momentumDecayTime)
        momentumVelocity = Point(x: momentumVelocity.x * decay,
                                 y: momentumVelocity.y * decay)

        if momentumVelocity.magnitude < momentumFloor {
            // cancelMomentum posts the end event; posting one here too would
            // send it twice. No fingers are involved — the glide ran out.
            cancelMomentum(fingersLanded: false)
            return
        }
        post(delta: Point(x: momentumVelocity.x * dt, y: momentumVelocity.y * dt),
             phase: nil, momentum: .continue)
    }

    // MARK: Event construction

    public enum MomentumPhase: Int64 {
        case none = 0, begin = 1, `continue` = 2, end = 3
    }

    public enum Phase: Int64 {
        case began = 1, changed = 2, ended = 4, cancelled = 8
        /// Fingers are resting on the pad but have not scrolled yet.
        ///
        /// A real trackpad emits this the moment fingers touch down, and it is
        /// what an app watches to abandon an inertial scroll — the momentum end
        /// event alone was not enough for Maps.
        case mayBegin = 128
    }

    /// Observes every event this would post. Exists so the phase sequence can
    /// be tested — the ordering bugs here are invisible from the outside and
    /// show up as an app that keeps scrolling after you have stopped it.
    public var onPost: ((Point, Phase?, MomentumPhase) -> Void)?

    /// When false, `onPost` still fires but nothing reaches the window server.
    public var postsEvents = true

    /// Pixels per line, the ratio CoreGraphics itself uses when converting a
    /// pixel-unit scroll into the line-based fields.
    ///
    /// Not a guess: build a `.pixel` event of 3, 28 and 100 and CoreGraphics
    /// fills the fixed-point field with 0.3, 2.8 and 10.0.
    public static let pixelsPerLine = 10.0

    /// Build the scroll event for a delta. Separate from posting so the field
    /// encoding can be tested — everything here is invisible from outside the
    /// process, and one field being wrong looked like working scrolling in
    /// every app that reads the other one.
    /// - Parameters:
    ///   - pixels: whole pixels to scroll, already rounded by the caller,
    ///     which is where the sub-pixel remainder is carried.
    ///   - lines: the same movement in lines. Passed separately rather than
    ///     derived, because it must *not* include the pixel remainder — that
    ///     is carried into the next frame, and counting it in both places
    ///     would scroll a line-based reader further than the finger moved.
    public static func makeEvent(pixels: Point, lines: Point, phase: Phase?,
                                 momentum: MomentumPhase) -> CGEvent? {
        let dx = pixels.x.rounded(.towardZero)
        let dy = pixels.y.rounded(.towardZero)

        guard let event = CGEvent(scrollWheelEvent2Source: nil,
                                  units: .pixel,
                                  wheelCount: 2,
                                  wheel1: Int32(clamping: Int(dy)),
                                  wheel2: Int32(clamping: Int(dx)),
                                  wheel3: 0) else { return nil }

        // Continuous marks this as trackpad-style scrolling rather than a
        // notched wheel, which is what unlocks smooth per-pixel behaviour.
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)

        // Two different units, and the pairing is the whole point:
        //
        //   PointDelta   pixels — NSEvent.scrollingDeltaY
        //   FixedPtDelta lines, fixed-point — NSEvent.deltaY
        //
        // These carried the same number once, pixels in both. Apps that read
        // scrollingDeltaY — AppKit scroll views, browsers — were fine, so
        // scrolling looked correct everywhere it was tested. Anything reading
        // deltaY saw ten times the scrolling it should, 154 times a second:
        // Emacs turned that into a torrent of wheel events and escalated them
        // to double- and triple-wheel-up.
        //
        // The fixed-point field keeps the fraction, which is what stops a slow
        // drag from being truncated away for a line-based reader.
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: lines.y)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: lines.x)

        if let phase {
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
        }
        if momentum != .none {
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum.rawValue)
        }
        return event
    }

    private func post(delta: Point, phase: Phase?, momentum: MomentumPhase) {
        // Kept here rather than at the call sites so the flag cannot drift from
        // the events actually sent.
        switch phase {
        case .mayBegin: awaitingBegan = true
        case .began, .cancelled, .ended: awaitingBegan = false
        case .changed, nil: break
        }

        onPost?(delta, phase, momentum)
        guard postsEvents else { return }

        // Carry sub-pixel remainder so slow drags still move. Only the pixel
        // field needs this; the line field is fixed-point and keeps its own
        // fraction, so it takes the frame's own movement untouched.
        let wanted = Point(x: delta.x + residual.x, y: delta.y + residual.y)
        let pixels = Point(x: wanted.x.rounded(.towardZero),
                           y: wanted.y.rounded(.towardZero))
        residual = Point(x: wanted.x - pixels.x, y: wanted.y - pixels.y)

        let lines = Point(x: delta.x / ScrollSynthesizer.pixelsPerLine,
                          y: delta.y / ScrollSynthesizer.pixelsPerLine)
        ScrollSynthesizer.makeEvent(pixels: pixels, lines: lines,
                                    phase: phase, momentum: momentum)?
            .post(tap: .cghidEventTap)
    }
}
