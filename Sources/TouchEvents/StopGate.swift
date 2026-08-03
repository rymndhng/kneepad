import Foundation

/// Cuts the sensor's deceleration tail so an abrupt stop is an abrupt stop.
///
/// The trackpad firmware low-pass filters position before reporting it, so
/// when a finger stops dead the reports keep arriving for another 35–85ms,
/// decaying geometrically toward zero — about a millimetre of travel that the
/// finger never made. Multiplied by `gain`, that is the ~0.1s of glide.
///
/// It cannot be filtered out, because by the time it is distinguishable it has
/// already been emitted. It can only be *recognised and dropped*, which needs
/// something that separates it from real slow movement. Three things do:
///
/// 1. **It only follows fast movement.** A tail is the discharge of a filter
///    that was charged by speed. So the gate has to be armed before it can
///    fire, and deliberate slow movement never arms it.
/// 2. **It only decelerates.** The decay is monotonic, all the way down.
/// 3. **It never recovers.** A finger that is still moving speeds up again
///    within a few frames; a tail never does.
///
/// Together those make the gate specific: it fires after a fast movement that
/// is decaying, and any genuine re-acceleration reopens it immediately.
public struct StopGate {

    public var enabled = true

    /// Speed the finger must reach before a tail is possible at all.
    ///
    /// Below this the firmware's filter is barely charged, there is no tail
    /// worth cutting, and gating would only eat deliberate slow movement.
    public var armSpeed = 87.0

    /// Speed below which decaying movement is treated as tail, not finger.
    ///
    /// The whole tail cannot be cut — some of it is emitted before it is
    /// distinguishable from a finger genuinely slowing down. Raising this cuts
    /// more of the glide but starts truncating real deceleration, so the
    /// cursor stops while the hand is still moving.
    public var stopSpeed = 44.0

    /// Consecutive decelerating frames required before firing.
    ///
    /// One frame of decrease is noise; a tail decreases every frame.
    public var confirmFrames = 2

    /// Speed increase that reopens the gate, in mm/s.
    ///
    /// A tail decays monotonically, so any real acceleration breaks it. Kept
    /// above the noise floor so jitter alone cannot reopen it.
    public var reawakenDelta = 5.8

    private var armed = false
    private var engaged = false
    private var lastSpeed = 0.0
    private var decelerating = 0

    public init() {}

    /// True if this frame's motion should reach the cursor.
    public mutating func allows(speed: Double) -> Bool {
        guard enabled else { return true }
        defer { lastSpeed = speed }

        if engaged {
            // Only a genuine push reopens it. Comparing against the speed that
            // closed the gate, not the last frame, so a slow tail cannot creep
            // back open one small increment at a time.
            if speed > lastSpeed + reawakenDelta {
                engaged = false
                armed = false
                decelerating = 0
                return true
            }
            return false
        }

        if speed >= armSpeed { armed = true }

        if speed < lastSpeed {
            decelerating += 1
        } else {
            decelerating = 0
            // Speeding up again means whatever we were watching was a finger.
            if speed < armSpeed { armed = false }
        }

        if armed, speed < stopSpeed, decelerating >= confirmFrames {
            engaged = true
            return false
        }
        return true
    }

    /// Called when every finger lifts. A new touch starts from a clean state,
    /// or the gate would still be closed against the first frames of it.
    public mutating func reset() {
        armed = false
        engaged = false
        lastSpeed = 0
        decelerating = 0
    }

    /// Fire on the smallest hint of a stop, at the cost of clipping genuine
    /// deceleration. For when a hard stop matters more than a smooth one.
    public mutating func makeAggressive() {
        armSpeed = 36
        stopSpeed = 102
        confirmFrames = 1
    }
}
