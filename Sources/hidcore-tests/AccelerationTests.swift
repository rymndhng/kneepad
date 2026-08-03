import Foundation
import TouchEvents

// The acceleration curve is the transfer function from finger speed to screen
// pixels per millimetre. It is tuned by feel, so these tests pin the *shape*
// the feel depends on rather than the exact numbers — a value can move without
// breaking a test, but the character of the curve cannot.

/// The driver's own curve, not a reimplementation of it — an earlier version of
/// this file restated the formula, which is how a test can keep passing while
/// the behaviour moves out from under it.
private func factor(_ speed: Double,
                    _ c: PointerSynthesizer.Configuration) -> Double {
    c.accelerationFactor(atSpeed: speed)
}

private func pxPerMm(_ speed: Double,
                     _ c: PointerSynthesizer.Configuration) -> Double {
    c.pixelsPerMillimetre(atSpeed: speed)
}

func runAccelerationTests() {
    TestRunner.suite("Pointer acceleration") {
        let config = PointerSynthesizer.Configuration()

        TestRunner.test("gain applies literally at the reference speed") {
            expectClose(pxPerMm(config.accelerationReference, config), config.gain, 0.001,
                        "that is what accelerationReference means")
        }

        // Reported from use: "at low speeds it's too slow, at high speeds too
        // fast — low and medium should behave linearly, and a bit faster."
        // Linear here means a *constant* px/mm, so the cursor tracks the finger
        // proportionally and the hand can aim.
        TestRunner.test("low and medium speeds share one constant rate") {
            let rates = [8.0, 18, 45, 70].map { pxPerMm($0, config) }
            for rate in rates {
                expectClose(rate, rates[0], 0.001,
                            "the whole aiming range must be one flat rate")
            }
        }

        // Where the power law finally overtakes the floor. This is a band, not
        // a floor: too narrow and the cursor accelerates while you are still
        // aiming; too wide and short strokes — vertical ones especially, since
        // a finger flexes over much less distance than it sweeps — never leave
        // the flat zone and the pad feels like hard work.
        TestRunner.test("the flat region covers aiming but not much more") {
            let knee = config.accelerationKnee
            check(knee > 45,
                  "flat only to \(Int(knee)) mm/s — amplification starts mid-aim")
            // The upper bound has moved twice, both times because a value
            // chosen by hand sat outside a bound chosen by argument. It is a
            // sanity rail against a typo, not a judgement about feel.
            check(knee < 200,
                  "flat to \(Int(knee)) mm/s — short strokes never get amplified")
        }

        TestRunner.test("the floor attenuates without deadening") {
            // Tuned by hand, between two failures either side: at 0.2 the
            // attenuation swallowed deliberate fine positioning and the pad
            // felt sluggish; at 1.0 nothing is attenuated at all.
            check(config.minAcceleration > 0.4,
                  "a floor of \(config.minAcceleration) makes fine placement sluggish")
            check(config.minAcceleration < 1.0,
                  "at 1.0 nothing is attenuated and the tail arrives at full gain")
        }

        TestRunner.test("a flick covers meaningfully more ground than aiming") {
            // The pad is small, so crossing a screen needs real amplification.
            // What matters is the ratio between the two ends, not either alone.
            let range = config.maxAcceleration / config.minAcceleration
            check(range >= 3,
                  "only ×\(range) between slowest and fastest — too little range "
                  + "to both aim and cross the screen on a pad this size")
            // Checked at a speed only a deliberate flick reaches. The shipped
            // curve is gentle enough that 440 mm/s is still mid-climb.
            check(factor(700, config) > 2,
                  "a fast flick must reach well up the curve")
        }

        TestRunner.test("the multiplier never leaves its bounds") {
            for speed in stride(from: 0.5, through: 4000, by: 5.5) {
                let f = factor(speed, config)
                check(f >= config.minAcceleration && f <= config.maxAcceleration,
                      "factor ×\(f) escaped at \(speed) mm/s")
            }
        }

        TestRunner.test("the curve never decreases with speed") {
            // Non-monotonic would mean moving faster moved the cursor less.
            var previous = 0.0
            for speed in stride(from: 1.0, through: 2000, by: 3.0) {
                let f = factor(speed, config)
                check(f >= previous - 1e-12, "factor dropped at \(speed) mm/s")
                previous = f
            }
        }

        // This suite briefly asserted that the exponent had to be below 1 to
        // keep the middle flat. Tuning by hand disproved it: the shipped curve
        // is 1.1 and the flat span is wider than it was at 0.6. The flat span
        // is set by the floor and the reference speed —
        // `reference × floor^(1/curve)` — and the exponent only shapes what
        // happens above the knee. The test that survives is the one that
        // measures the flat span directly, above.
        TestRunner.test("the knee is where the floor and the power law meet") {
            let knee = config.accelerationKnee
            expectClose(factor(knee, config), config.minAcceleration, 0.001,
                        "the curve must leave the floor exactly at the knee")
            check(factor(knee * 1.5, config) > config.minAcceleration,
                  "and must be climbing past it")
        }
    }
}
