import Foundation
import HIDCore

// The scroll recognizer is a state machine over tracked contacts. These tests
// drive it with synthetic frames so the phase transitions, activation
// threshold and pinch rejection are all checked without hardware.

private let modulus = 65536
private let tick = 0.0001

private func makeTracker() -> ContactTracker {
    let tracker = ContactTracker(scanTimeModulus: modulus, secondsPerCount: tick)
    // These tests assert exact positions; smoothing and lead compensation
    // are independent stages, both covered by their own suite.
    tracker.smoothing.enabled = false
    tracker.smoothing.leadGain = 0
    return tracker
}

private func contact(_ id: Int, _ x: Double, _ y: Double, confident: Bool = true) -> Contact {
    Contact(hardwareID: id, rawX: Int(x), rawY: Int(y),
            position: Point(x: x, y: y), confident: confident)
}

private func frame(_ contacts: [Contact], at scanTime: Int) -> Frame {
    Frame(contacts: contacts, declaredCount: contacts.count, scanTime: scanTime)
}

/// Feed a frame through tracker + recognizer, as the daemon does.
private func step(_ tracker: ContactTracker, _ recognizer: ScrollRecognizer,
                  _ contacts: [Contact], at scanTime: Int) -> ScrollUpdate? {
    tracker.update(frame(contacts, at: scanTime))
    return recognizer.update(tracks: tracker.active, dt: tracker.lastDelta)
}

func runScrollRecognizerTests() {
    TestRunner.suite("Scroll recognition") {

        TestRunner.test("a resting pair does not scroll") {
            let tracker = makeTracker(), recognizer = ScrollRecognizer()
            expectNil(step(tracker, recognizer, [contact(0, 10, 10), contact(1, 30, 10)], at: 0))
            // Jitter well under the activation threshold.
            expectNil(step(tracker, recognizer,
                           [contact(0, 10.2, 10.1), contact(1, 30.1, 10.2)], at: 1000))
        }

        TestRunner.test("moving past the activation distance begins a scroll") {
            let tracker = makeTracker(), recognizer = ScrollRecognizer()
            _ = step(tracker, recognizer, [contact(0, 10, 10), contact(1, 30, 10)], at: 0)

            let update = try require(step(tracker, recognizer,
                                          [contact(0, 10, 15), contact(1, 30, 15)], at: 1000))
            check(update.phase == .began, "expected began, got \(update.phase)")
            expectClose(update.delta.y, 5, 0.001, "centroid moved 5mm")
            check(recognizer.isScrolling, "recognizer is now active")
        }

        TestRunner.test("subsequent motion reports incremental deltas") {
            let tracker = makeTracker(), recognizer = ScrollRecognizer()
            _ = step(tracker, recognizer, [contact(0, 10, 10), contact(1, 30, 10)], at: 0)
            _ = step(tracker, recognizer, [contact(0, 10, 15), contact(1, 30, 15)], at: 1000)

            let update = try require(step(tracker, recognizer,
                                          [contact(0, 10, 18), contact(1, 30, 18)], at: 2000))
            check(update.phase == .changed, "expected changed, got \(update.phase)")
            expectClose(update.delta.y, 3, 0.001, "delta is since the last frame, not the start")
        }

        TestRunner.test("lifting a finger ends the scroll") {
            let tracker = makeTracker(), recognizer = ScrollRecognizer()
            _ = step(tracker, recognizer, [contact(0, 10, 10), contact(1, 30, 10)], at: 0)
            _ = step(tracker, recognizer, [contact(0, 10, 15), contact(1, 30, 15)], at: 1000)

            let update = try require(step(tracker, recognizer, [contact(0, 10, 15)], at: 2000))
            check(update.phase == .ended, "expected ended, got \(update.phase)")
            check(!recognizer.isScrolling, "recognizer is idle again")
        }

        TestRunner.test("ending carries velocity for momentum") {
            let tracker = makeTracker(), recognizer = ScrollRecognizer()
            _ = step(tracker, recognizer, [contact(0, 10, 0), contact(1, 30, 0)], at: 0)
            // 1000 counts = 0.1s, 10mm → 100 mm/s instantaneous.
            _ = step(tracker, recognizer, [contact(0, 10, 10), contact(1, 30, 10)], at: 1000)
            _ = step(tracker, recognizer, [contact(0, 10, 20), contact(1, 30, 20)], at: 2000)

            let update = try require(step(tracker, recognizer, [], at: 3000))
            check(update.phase == .ended, "expected ended")
            check(update.velocity.y > 0, "velocity must survive into the ended update")
        }

        TestRunner.test("a pinch is not treated as a scroll") {
            let tracker = makeTracker(), recognizer = ScrollRecognizer()
            _ = step(tracker, recognizer, [contact(0, 10, 10), contact(1, 30, 10)], at: 0)
            // Fingers separate 10mm while the centroid barely moves.
            expectNil(step(tracker, recognizer,
                           [contact(0, 5, 10), contact(1, 35, 10)], at: 1000),
                      "spread change dominates centroid travel")
            check(!recognizer.isScrolling, "must not have engaged")
        }

        TestRunner.test("one finger never scrolls") {
            let tracker = makeTracker(), recognizer = ScrollRecognizer()
            _ = step(tracker, recognizer, [contact(0, 10, 10)], at: 0)
            expectNil(step(tracker, recognizer, [contact(0, 10, 30)], at: 1000))
        }

        TestRunner.test("a non-confident contact is excluded") {
            let tracker = makeTracker(), recognizer = ScrollRecognizer()
            _ = step(tracker, recognizer,
                     [contact(0, 10, 10), contact(1, 30, 10, confident: false)], at: 0)
            expectNil(step(tracker, recognizer,
                           [contact(0, 10, 20), contact(1, 30, 20, confident: false)], at: 1000),
                      "a palm plus a finger is not a two-finger scroll")
        }

        TestRunner.test("horizontal scrolling works the same way") {
            let tracker = makeTracker(), recognizer = ScrollRecognizer()
            _ = step(tracker, recognizer, [contact(0, 10, 10), contact(1, 10, 30)], at: 0)

            let update = try require(step(tracker, recognizer,
                                          [contact(0, 18, 10), contact(1, 18, 30)], at: 1000))
            check(update.phase == .began, "expected began")
            expectClose(update.delta.x, 8, 0.001)
            expectClose(update.delta.y, 0, 0.001)
        }

        // A fast release is the case that broke in practice: the final frames
        // before liftoff show a spurious slowdown, so sampling velocity at the
        // instant of lift turned a flick into no momentum at all.
        TestRunner.test("release velocity ignores the liftoff slowdown") {
            let tracker = makeTracker(), recognizer = ScrollRecognizer()

            // Steady fast drag: 10mm per 0.1s = 100 mm/s.
            var y = 0.0
            for i in 0...6 {
                _ = step(tracker, recognizer,
                         [contact(0, 10, y), contact(1, 30, y)], at: i * 1000)
                y += 10
            }
            // Liftoff: the last two frames barely move as contact area shrinks.
            _ = step(tracker, recognizer, [contact(0, 10, y), contact(1, 30, y)], at: 7000)
            _ = step(tracker, recognizer,
                     [contact(0, 10, y + 0.1), contact(1, 30, y + 0.1)], at: 8000)

            let update = try require(step(tracker, recognizer, [], at: 9000))
            check(update.phase == .ended, "expected ended")
            check(update.velocity.y > 20,
                  "flick velocity must survive liftoff, got \(update.velocity.y) mm/s")
        }

        TestRunner.test("a stalled drag still ends with low velocity") {
            let tracker = makeTracker(), recognizer = ScrollRecognizer()
            _ = step(tracker, recognizer, [contact(0, 10, 0), contact(1, 30, 0)], at: 0)
            _ = step(tracker, recognizer, [contact(0, 10, 10), contact(1, 30, 10)], at: 1000)
            // Then hold still for a while before lifting — no flick intended.
            for i in 2...8 {
                _ = step(tracker, recognizer,
                         [contact(0, 10, 10), contact(1, 30, 10)], at: i * 1000)
            }
            let update = try require(step(tracker, recognizer, [], at: 9000))
            check(abs(update.velocity.y) < 5,
                  "a deliberate stop must not fling, got \(update.velocity.y) mm/s")
        }

        // Reported from real use: "when I stop my finger there's lingering
        // deceleration, it should just stop". A brief pause fell into the gap
        // between the release window and the liftoff frames, so the scroll
        // still flung from the speed before the pause.
        TestRunner.test("a brief pause before lifting cancels momentum") {
            let tracker = makeTracker(), recognizer = ScrollRecognizer()

            // Fast drag: 10mm per frame.
            var y = 0.0
            for i in 0...6 {
                _ = step(tracker, recognizer,
                         [contact(0, 10, y), contact(1, 30, y)], at: i * 1000)
                y += 10
            }
            // Stop dead for ~80ms (8 frames at 10ms), still touching.
            for i in 7...14 {
                _ = step(tracker, recognizer,
                         [contact(0, 10, y), contact(1, 30, y)], at: i * 100 + 6000)
            }
            let update = try require(step(tracker, recognizer, [], at: 8000))
            check(update.phase == .ended, "expected ended")
            check(abs(update.velocity.y) < 1,
                  "a deliberate stop must kill momentum, got \(update.velocity.y) mm/s")
        }

        TestRunner.test("a second scroll can start after the first ends") {
            let tracker = makeTracker(), recognizer = ScrollRecognizer()
            _ = step(tracker, recognizer, [contact(0, 10, 10), contact(1, 30, 10)], at: 0)
            _ = step(tracker, recognizer, [contact(0, 10, 15), contact(1, 30, 15)], at: 1000)
            _ = step(tracker, recognizer, [], at: 2000)   // lift

            _ = step(tracker, recognizer, [contact(0, 10, 10), contact(1, 30, 10)], at: 3000)
            let update = try require(step(tracker, recognizer,
                                          [contact(0, 10, 16), contact(1, 30, 16)], at: 4000))
            check(update.phase == .began, "a fresh gesture must begin cleanly")
        }
    }
}
