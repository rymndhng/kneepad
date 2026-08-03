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
            cancelMomentum()
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

    /// Stop any in-flight momentum — call when a new touch lands.
    public func cancelMomentum() {
        momentumTimer?.cancel()
        momentumTimer = nil
        momentumVelocity = Point(x: 0, y: 0)
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
            cancelMomentum()
            post(delta: Point(x: 0, y: 0), phase: nil, momentum: .end)
            return
        }
        post(delta: Point(x: momentumVelocity.x * dt, y: momentumVelocity.y * dt),
             phase: nil, momentum: .continue)
    }

    // MARK: Event construction

    private enum MomentumPhase: Int64 {
        case none = 0, begin = 1, `continue` = 2, end = 3
    }

    private enum Phase: Int64 {
        case began = 1, changed = 2, ended = 4
    }

    private func post(delta: Point, phase: Phase?, momentum: MomentumPhase) {
        // Carry sub-pixel remainder so slow drags still move.
        let wanted = Point(x: delta.x + residual.x, y: delta.y + residual.y)
        let dx = wanted.x.rounded(.towardZero)
        let dy = wanted.y.rounded(.towardZero)
        residual = Point(x: wanted.x - dx, y: wanted.y - dy)

        guard let event = CGEvent(scrollWheelEvent2Source: nil,
                                  units: .pixel,
                                  wheelCount: 2,
                                  wheel1: Int32(clamping: Int(dy)),
                                  wheel2: Int32(clamping: Int(dx)),
                                  wheel3: 0) else { return }

        // Continuous marks this as trackpad-style scrolling rather than a
        // notched wheel, which is what unlocks smooth per-pixel behaviour.
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))

        // The fixed-point fields carry sub-pixel precision. Apps that read them
        // (AppKit scroll views among them) get genuinely smooth motion instead
        // of the integer staircase the point deltas alone describe.
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: wanted.y)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: wanted.x)

        if let phase {
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
        }
        if momentum != .none {
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum.rawValue)
        }

        event.post(tap: .cghidEventTap)
    }
}
