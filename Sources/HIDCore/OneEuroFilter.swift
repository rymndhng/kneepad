import Foundation

/// One-pole low-pass filter with a caller-supplied smoothing factor.
final class LowPassFilter {
    private var value: Double?

    var hasValue: Bool { value != nil }
    var current: Double? { value }

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

    /// How hard residual error opens the cutoff.
    ///
    /// Without this the filter coasts after you stop: fast movement leaves the
    /// output lagging behind, and when the finger halts the speed term
    /// collapses back to `minCutoff`, so that accumulated lag bleeds out over a
    /// ~130ms tail instead of being delivered. Driving the cutoff from the
    /// error as well means a stop settles in a couple of frames.
    public var settleGain: Double

    /// Error below this is sensor noise, not lag, and must not open the cutoff
    /// — otherwise a resting finger's jitter would defeat the smoothing.
    /// In input units, i.e. millimetres.
    public var settleDeadband: Double

    private let xFilter = LowPassFilter()
    private let dxFilter = LowPassFilter()
    private var lastValue: Double?

    public init(minCutoff: Double = 1.0, beta: Double = 0.25,
                derivativeCutoff: Double = 1.0,
                settleGain: Double = 4.0, settleDeadband: Double = 0.25) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
        self.settleGain = settleGain
        self.settleDeadband = settleDeadband
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

        // How far behind the output currently is. Anything above the deadband
        // is real lag that should be delivered, not noise to be suppressed.
        let error = abs(x - (xFilter.current ?? x))
        let excess = max(0, error - settleDeadband)

        let cutoff = minCutoff
            + beta * abs(smoothedDx)
            + settleGain * excess / dt
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

    public init(minCutoff: Double = 1.0, beta: Double = 0.25,
                settleGain: Double = 4.0, settleDeadband: Double = 0.25) {
        x = OneEuroFilter(minCutoff: minCutoff, beta: beta,
                          settleGain: settleGain, settleDeadband: settleDeadband)
        y = OneEuroFilter(minCutoff: minCutoff, beta: beta,
                          settleGain: settleGain, settleDeadband: settleDeadband)
    }

    public var settleGain: Double {
        get { x.settleGain }
        set { x.settleGain = newValue; y.settleGain = newValue }
    }

    public var settleDeadband: Double {
        get { x.settleDeadband }
        set { x.settleDeadband = newValue; y.settleDeadband = newValue }
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

    /// Cancels the smoothing the trackpad firmware applies before we see the
    /// data — the cause of the deceleration tail after the finger stops.
    ///
    /// Modelled as an IIR low-pass `y[n] = a·x[n] + (1-a)·y[n-1]`, whose exact
    /// inverse is
    ///
    ///     x[n] = y[n] + ((1-a)/a)·(y[n] - y[n-1])
    ///
    /// making `leadGain` equal to (1-a)/a. Total displacement is preserved —
    /// motion is delivered when it happened rather than trailing after.
    ///
    /// ⚠️ How much smoothing the firmware actually applies is NOT well
    /// established. A first trace suggested a ≈ 0.28 (gain 2.57) over ~85ms,
    /// but a second trace of the same gesture showed a shorter, less regular
    /// decay that a single IIR does not fit.
    ///
    /// 0.25 was settled on by feel, and it is far below what inverting the
    /// measured decay would call for — a ≈ 0.28 implied 2.57, and even the
    /// most conservative reading of the traces implied over 1.
    ///
    /// Taking that seriously: if only a quarter of the modelled correction is
    /// wanted, the tail this is meant to cancel is largely being handled
    /// elsewhere. It is — `StopGate` drops it outright, and unlike this it
    /// costs no noise amplification. What remains for lead is a small nudge
    /// against the residual lag *during* movement, which the gate cannot touch
    /// because it only acts after a stop.
    ///
    /// So the two are not redundant, but their balance is the opposite of what
    /// the IIR model predicted: the gate does the work, and lead trims. Anyone
    /// re-deriving the "correct" value from a decay ratio should know it was
    /// tried and rejected by hand — see plan/FEEL-DEBUGGING.md.
    ///
    /// Set to 0 to disable.
    public var leadGain = 0.25
    /// Hz. Lower is steadier at rest; too low and slow movement feels sticky.
    public var minCutoff = 1.2
    /// Speed coupling. Higher responds faster but passes more jitter.
    public var beta = 0.25
    /// How hard residual lag opens the cutoff, so a stop settles at once
    /// instead of coasting. See OneEuroFilter.settleGain.
    public var settleGain = 4.0
    /// Error below this is treated as sensor noise rather than lag.
    public var settleDeadband = 0.25

    public init() {}
}
