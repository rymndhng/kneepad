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
        public var gain = 8.0
        /// Natural scrolling: content follows the fingers.
        public var naturalDirection = true
        public var invertHorizontal = false
        /// Momentum below this speed (px/s) is not worth animating.
        public var momentumThreshold = 60.0
        /// Per-tick velocity retention. Lower stops sooner.
        public var friction = 0.94
        /// Momentum animation rate.
        public var momentumHz = 90.0
        public var momentumEnabled = true

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
        let g = configuration.gain
        // Pad Y grows downward. With natural scrolling the content follows the
        // fingers, so a downward drag scrolls content down.
        let vertical = configuration.naturalDirection ? -millimetres.y : millimetres.y
        let horizontal = configuration.invertHorizontal ? -millimetres.x : millimetres.x
        return Point(x: horizontal * g, y: vertical * g)
    }

    // MARK: Momentum

    private func startMomentum(velocity: Point) {
        guard velocity.magnitude >= configuration.momentumThreshold else {
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
        momentumVelocity = Point(x: momentumVelocity.x * configuration.friction,
                                 y: momentumVelocity.y * configuration.friction)

        if momentumVelocity.magnitude < configuration.momentumThreshold {
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

        if let phase {
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
        }
        if momentum != .none {
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum.rawValue)
        }

        event.post(tap: .cghidEventTap)
    }
}
