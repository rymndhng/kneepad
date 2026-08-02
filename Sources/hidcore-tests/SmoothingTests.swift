import Foundation
import HIDCore

// The 1€ filter has to do two opposing things: hold still under noise, and not
// lag when the finger actually moves. These tests pin both.

private let dt = 0.01   // 100 Hz

/// Deterministic pseudo-noise, so the tests don't flake.
private struct Noise {
    private var state: UInt64 = 0x2545F4914F6CDD1D
    mutating func next(_ amplitude: Double) -> Double {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return (Double(state % 2000) / 1000.0 - 1.0) * amplitude
    }
}

private func spread(_ values: [Double]) -> Double {
    guard values.count > 1 else { return 0 }
    let mean = values.reduce(0, +) / Double(values.count)
    return (values.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
            / Double(values.count)).squareRoot()
}

func runSmoothingTests() {
    TestRunner.suite("Position smoothing") {

        TestRunner.test("a still finger's jitter is substantially reduced") {
            let filter = OneEuroFilter(minCutoff: 1.2, beta: 0.25)
            var noise = Noise()

            var raw: [Double] = []
            var filtered: [Double] = []
            for _ in 0..<300 {
                let sample = 20.0 + noise.next(0.15)   // still finger, ±0.15mm
                raw.append(sample)
                filtered.append(filter.filter(sample, dt: dt))
            }
            // Discard the warm-up, where the filter is still converging.
            let rawSpread = spread(Array(raw.suffix(200)))
            let filteredSpread = spread(Array(filtered.suffix(200)))

            check(filteredSpread < rawSpread * 0.5,
                  "expected >50% noise reduction, got \(rawSpread) → \(filteredSpread)")
        }

        TestRunner.test("fast movement is not left lagging behind") {
            let filter = OneEuroFilter(minCutoff: 1.2, beta: 0.25)
            var position = 0.0
            var output = 0.0
            // 200 mm/s for 200ms — a brisk swipe.
            for _ in 0..<20 {
                position += 200 * dt
                output = filter.filter(position, dt: dt)
            }
            let lag = position - output
            check(lag < 1.2, "lag of \(lag)mm is too much to feel connected")
        }

        // Reported from real use: "when I stop my finger there's lingering
        // deceleration". Fast motion leaves the output behind; if the cutoff
        // collapses the instant speed hits zero, that lag dribbles out as a
        // visible coast.
        TestRunner.test("stopping settles promptly instead of coasting") {
            let filter = OneEuroFilter(minCutoff: 1.2, beta: 0.25)
            var position = 0.0

            for _ in 0..<20 {                 // 200 mm/s
                position += 200 * dt
                _ = filter.filter(position, dt: dt)
            }

            // Finger stops dead. Measure motion still being emitted after.
            var previous = filter.filter(position, dt: dt)
            var residual: [Double] = []
            for _ in 0..<10 {
                let output = filter.filter(position, dt: dt)
                residual.append(abs(output - previous))
                previous = output
            }

            // Within three frames of stopping, output motion must be negligible.
            let afterThree = residual.dropFirst(3).reduce(0, +)
            check(afterThree < 0.05,
                  "still emitting \(afterThree)mm of motion 3 frames after stopping")
        }

        TestRunner.test("settling does not defeat jitter suppression") {
            // The deadband is what keeps resting noise from opening the cutoff.
            let filter = OneEuroFilter(minCutoff: 1.2, beta: 0.25)
            var noise = Noise()
            var raw: [Double] = []
            var filtered: [Double] = []
            for _ in 0..<300 {
                let sample = 20.0 + noise.next(0.15)
                raw.append(sample)
                filtered.append(filter.filter(sample, dt: dt))
            }
            check(spread(Array(filtered.suffix(200))) < spread(Array(raw.suffix(200))) * 0.5,
                  "settle term must not let resting jitter through")
        }

        TestRunner.test("higher beta reduces lag") {
            func lag(beta: Double) -> Double {
                let filter = OneEuroFilter(minCutoff: 1.2, beta: beta)
                var position = 0.0, output = 0.0
                for _ in 0..<20 {
                    position += 200 * dt
                    output = filter.filter(position, dt: dt)
                }
                return position - output
            }
            check(lag(beta: 0.5) < lag(beta: 0.001),
                  "beta is the speed-coupling knob; raising it must cut lag")
        }

        TestRunner.test("the filter starts at the first sample, not zero") {
            let filter = OneEuroFilter()
            // Otherwise the cursor would visibly slide in from the origin.
            expectClose(filter.filter(42.0, dt: dt), 42.0, 0.001)
        }

        TestRunner.test("a zero timestep passes through untouched") {
            let filter = OneEuroFilter()
            expectClose(filter.filter(7.0, dt: 0), 7.0, 0.001)
        }

        // MARK: Lead compensation
        //
        // The trackpad firmware runs its own IIR low-pass. Measured from
        // hid-stream --trace: after a fast swipe, per-frame deltas decay by a
        // near-constant ~0.72 for ~85ms, which is a filter, not a finger.

        /// Model of the firmware: y[n] = a·x[n] + (1-a)·y[n-1].
        func firmwareSmoothed(_ truth: [Double], a: Double) -> [Double] {
            var y: Double? = nil
            return truth.map { x in
                let out = y.map { a * x + (1 - a) * $0 } ?? x
                y = out
                return out
            }
        }

        /// The compensator: x[n] = y[n] + k·(y[n] - y[n-1]).
        func leadCompensated(_ input: [Double], gain: Double) -> [Double] {
            var previous: Double? = nil
            return input.map { y in
                let out = previous.map { y + gain * (y - $0) } ?? y
                previous = y
                return out
            }
        }

        TestRunner.test("lead compensation cancels the firmware's tail") {
            // Finger moves at a constant rate then stops dead.
            var truth: [Double] = []
            var x = 0.0
            for _ in 0..<25 { x += 2.0; truth.append(x) }
            for _ in 0..<25 { truth.append(x) }

            let a = 0.28
            let observed = firmwareSmoothed(truth, a: a)
            let restored = leadCompensated(observed, gain: (1 - a) / a)

            // Uncompensated, motion keeps arriving long after the stop.
            let tailBefore = zip(observed.dropFirst(26), observed.dropFirst(25))
                .reduce(0.0) { $0 + abs($1.0 - $1.1) }
            let tailAfter = zip(restored.dropFirst(26), restored.dropFirst(25))
                .reduce(0.0) { $0 + abs($1.0 - $1.1) }

            check(tailAfter < tailBefore * 0.05,
                  "tail should be all but gone: \(tailBefore) → \(tailAfter)")
        }

        TestRunner.test("lead compensation preserves total displacement") {
            var truth: [Double] = []
            var x = 0.0
            for _ in 0..<25 { x += 2.0; truth.append(x) }
            for _ in 0..<25 { truth.append(x) }

            let a = 0.28
            let restored = leadCompensated(firmwareSmoothed(truth, a: a), gain: (1 - a) / a)

            // It redistributes motion earlier in time; it must not invent or
            // lose any, or the cursor would drift relative to the finger.
            expectClose(restored.last ?? 0, truth.last ?? 0, 0.01,
                        "final position must match the finger")
        }

        TestRunner.test("lead compensation is disabled by a zero gain") {
            let tracker = ContactTracker(scanTimeModulus: 65536, secondsPerCount: 0.0001)
            tracker.smoothing.leadGain = 0
            tracker.smoothing.enabled = false

            tracker.update(Frame(contacts: [Contact(hardwareID: 0, rawX: 0, rawY: 0,
                                                    position: Point(x: 10, y: 10))],
                                 scanTime: 0))
            tracker.update(Frame(contacts: [Contact(hardwareID: 0, rawX: 0, rawY: 0,
                                                    position: Point(x: 12, y: 10))],
                                 scanTime: 100))
            expectClose(tracker.active[0].position.x, 12, 0.001)
        }

        // MARK: Integration with the tracker

        TestRunner.test("tracker smoothing can be disabled") {
            let tracker = ContactTracker(scanTimeModulus: 65536, secondsPerCount: 0.0001)
            tracker.smoothing.enabled = false

            tracker.update(Frame(contacts: [Contact(hardwareID: 0, rawX: 0, rawY: 0,
                                                    position: Point(x: 10, y: 10))],
                                 scanTime: 0))
            tracker.update(Frame(contacts: [Contact(hardwareID: 0, rawX: 0, rawY: 0,
                                                    position: Point(x: 30, y: 10))],
                                 scanTime: 100))
            expectClose(tracker.active[0].position.x, 30, 0.001,
                        "unfiltered positions must pass straight through")
        }

        TestRunner.test("a recycled contact ID does not inherit filter state") {
            let tracker = ContactTracker(scanTimeModulus: 65536, secondsPerCount: 0.0001)

            // A finger settles at x=10, then lifts.
            for i in 0..<20 {
                tracker.update(Frame(contacts: [Contact(hardwareID: 0, rawX: 0, rawY: 0,
                                                        position: Point(x: 10, y: 10))],
                                     scanTime: i * 100))
            }
            tracker.update(Frame(contacts: [], scanTime: 2000))

            // A new finger reuses ID 0 far away. It must land there, not slide
            // in from the old position.
            tracker.update(Frame(contacts: [Contact(hardwareID: 0, rawX: 0, rawY: 0,
                                                    position: Point(x: 45, y: 45))],
                                 scanTime: 2100))
            expectClose(tracker.active[0].position.x, 45, 0.001, "no stale filter state")
        }
    }
}
