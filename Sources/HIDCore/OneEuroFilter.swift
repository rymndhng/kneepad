import Foundation

/// One-pole low-pass filter with a caller-supplied smoothing factor.
final class LowPassFilter {
    private var value: Double?

    var hasValue: Bool { value != nil }

    func filter(_ x: Double, alpha: Double) -> Double {
        let result = value.map { alpha * x + (1 - alpha) * $0 } ?? x
        value = result
        return result
    }

    func reset() { value = nil }
}

/// The 1€ filter (Casiez, Roussel & Vogel, CHI 2012).
///
/// The problem it solves is exactly ours: a fixed low-pass either leaves jitter
/// visible when the finger is still, or adds lag you can feel when it moves.
/// The 1€ filter varies its cutoff with speed — heavy smoothing at rest for
/// precision, light smoothing when moving fast so nothing lags.
///
/// This is the single biggest contributor to a trackpad feeling "accurate"
/// rather than twitchy.
public final class OneEuroFilter {
    /// Cutoff frequency at zero speed, in Hz. Lower = steadier when still.
    public var minCutoff: Double
    /// How aggressively the cutoff opens up with speed. Higher = less lag when
    /// moving fast, at the cost of more jitter.
    public var beta: Double
    /// Cutoff for the derivative estimate itself.
    public var derivativeCutoff: Double

    private let xFilter = LowPassFilter()
    private let dxFilter = LowPassFilter()
    private var lastValue: Double?

    public init(minCutoff: Double = 1.0, beta: Double = 0.25,
                derivativeCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    /// Smoothing factor for a given cutoff and timestep.
    private func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2 * .pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }

    public func filter(_ x: Double, dt: Double) -> Double {
        guard dt > 0 else { return x }

        // Estimate speed, smoothed so noise in the derivative doesn't slam the
        // cutoff open and defeat the whole point.
        let dx = lastValue.map { (x - $0) / dt } ?? 0
        lastValue = x
        let smoothedDx = dxFilter.filter(dx, alpha: alpha(cutoff: derivativeCutoff, dt: dt))

        let cutoff = minCutoff + beta * abs(smoothedDx)
        return xFilter.filter(x, alpha: alpha(cutoff: cutoff, dt: dt))
    }

    public func reset() {
        xFilter.reset()
        dxFilter.reset()
        lastValue = nil
    }
}

/// A 1€ filter over a 2D point — one filter per axis.
public final class OneEuroPointFilter {
    private let x: OneEuroFilter
    private let y: OneEuroFilter

    public init(minCutoff: Double = 1.0, beta: Double = 0.25) {
        x = OneEuroFilter(minCutoff: minCutoff, beta: beta)
        y = OneEuroFilter(minCutoff: minCutoff, beta: beta)
    }

    public var minCutoff: Double {
        get { x.minCutoff }
        set { x.minCutoff = newValue; y.minCutoff = newValue }
    }

    public var beta: Double {
        get { x.beta }
        set { x.beta = newValue; y.beta = newValue }
    }

    public func filter(_ point: Point, dt: Double) -> Point {
        Point(x: x.filter(point.x, dt: dt), y: y.filter(point.y, dt: dt))
    }

    public func reset() {
        x.reset()
        y.reset()
    }
}

/// Tuning for contact position smoothing.
public struct SmoothingConfiguration {
    public var enabled = true
    /// Hz. Lower is steadier at rest; too low and slow movement feels sticky.
    public var minCutoff = 1.2
    /// Speed coupling. Higher responds faster but passes more jitter.
    public var beta = 0.25

    public init() {}
}
