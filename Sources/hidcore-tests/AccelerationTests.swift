import Foundation
import TouchEvents

// The acceleration curve is the transfer function from finger speed to screen
// pixels per millimetre. It is tuned by feel, so these tests pin the *shape*
// the feel depends on rather than the exact numbers — a value can move without
// breaking a test, but the character of the curve cannot.

/// Reproduces `PointerSynthesizer.move`'s factor, so the shape can be checked
/// without posting events into the window server.
private func factor(_ speed: Double,
                    _ c: PointerSynthesizer.Configuration) -> Double {
    min(c.maxAcceleration,
        max(c.minAcceleration,
            pow(speed / c.accelerationReference, c.accelerationCurve)))
}

private func pxPerMm(_ speed: Double,
                     _ c: PointerSynthesizer.Configuration) -> Double {
    c.gain * factor(speed, c)
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
            let rates = [10.0, 25, 60, 100].map { pxPerMm($0, config) }
            for rate in rates {
                expectClose(rate, rates[0], 0.001,
                            "the whole aiming range must be one flat rate")
            }
        }

        TestRunner.test("the flat region runs well past casual pointing") {
            // Where the power law finally overtakes the floor.
            let knee = config.accelerationReference
                * pow(config.minAcceleration, 1 / config.accelerationCurve)
            check(knee > 100,
                  "flat only up to \(Int(knee)) mm/s — amplification starts too early")
        }

        TestRunner.test("the flat rate is close to linear, not attenuated") {
            // The floor exists to take the edge off the sensor's deceleration
            // tail. Pushed lower it also swallows deliberate fine positioning,
            // which is exactly how 0.2 felt.
            check(config.minAcceleration >= 0.8,
                  "a floor of \(config.minAcceleration) makes fine placement sluggish")
            check(config.minAcceleration < 1.0,
                  "at 1.0 nothing is attenuated and the tail arrives at full gain")
        }

        TestRunner.test("fast movement is amplified, but not thrown") {
            let fast = factor(600, config)
            check(fast > 1.3, "a flick must cover ground, got ×\(fast)")
            check(fast <= 2.5, "×\(fast) overshoots — the cursor outruns the hand")
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

        TestRunner.test("a sub-1 curve exponent is what keeps the middle flat") {
            // Above 1 the curve is convex: it leaves the floor early and
            // reaches the ceiling late, so slow motion is attenuated across the
            // aiming range and fast motion keeps accelerating. That was the
            // 1.2 default, and it read as too slow when placing the cursor and
            // too fast when crossing the screen.
            check(config.accelerationCurve < 1.0,
                  "curve \(config.accelerationCurve) reintroduces the convex shape")
        }
    }
}
