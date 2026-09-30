import Foundation
import CoreGraphics
import HIDCore
import TouchEvents

// The scroll recognizer is a state machine over tracked contacts. These tests
// drive it with synthetic frames so the phase transitions, activation
// threshold and pinch rejection are all checked without hardware.

private let modulus = 65536
private let tick = 0.0001

private func makeTracker() -> ContactTracker {
    let tracker = ContactTracker(scanTimeModulus: modulus, secondsPerCount: tick)
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

        // Fingers rest side by side, so the line between them is horizontal.
        // A vertical scroll barely changes the gap — 20mm apart, moved 1mm up,
        // the distance grows by 0.025mm — but a horizontal swipe changes it
        // one-for-one with any difference between the two fingers. Since
        // fingers never start together, the pinch test saw every swipe as a
        // pinch, and only the geometry of vertical scrolling hid it.
        TestRunner.test("an uneven pinch is still rejected") {
            let tracker = makeTracker(), recognizer = ScrollRecognizer()
            _ = step(tracker, recognizer, [contact(0, 10, 10), contact(1, 30, 10)], at: 0)
            // Both fingers move, in opposite directions, one further than the
            // other — so the centroid drifts as well as the gap opening.
            expectNil(step(tracker, recognizer,
                           [contact(0, 4, 10), contact(1, 32, 10)], at: 1000),
                      "opposing motion is a pinch however lopsided")
            check(!recognizer.isScrolling, "must not have engaged")
        }

        TestRunner.test("a sideways swipe with one finger leading still scrolls") {
            let tracker = makeTracker(), recognizer = ScrollRecognizer()
            _ = step(tracker, recognizer, [contact(0, 10, 10), contact(1, 30, 10)], at: 0)

            // Swipe left. The left finger leads by 2mm; the other has not moved
            // yet. Centroid travel 1mm, gap change 2mm.
            let update = try require(step(tracker, recognizer,
                                          [contact(0, 8, 10), contact(1, 30, 10)], at: 1000),
                                     "a leading finger is not a pinch")
            check(update.phase == .began, "expected began, got \(update.phase)")
            check(update.delta.x < 0, "swipe went left")
        }

        TestRunner.test("fingers moving together sideways scroll") {
            let tracker = makeTracker(), recognizer = ScrollRecognizer()
            _ = step(tracker, recognizer, [contact(0, 10, 10), contact(1, 30, 10)], at: 0)
            let update = try require(step(tracker, recognizer,
                                          [contact(0, 8, 10), contact(1, 28, 10)], at: 1000))
            check(update.phase == .began, "expected began")
            expectClose(update.delta.x, -2, 0.001, "centroid moved 2mm left")
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

        // Reported from real use: vertical scrolling kept getting caught by
        // horizontal elements. A crooked start sent sideways deltas, and the
        // app handed the whole gesture to the carousel under the cursor.
        TestRunner.test("a crooked vertical swipe scrolls only vertically") {
            let tracker = makeTracker(), recognizer = ScrollRecognizer()
            _ = step(tracker, recognizer, [contact(0, 10, 10), contact(1, 30, 10)], at: 0)

            let began = try require(step(tracker, recognizer,
                                         [contact(0, 13, 15), contact(1, 33, 15)], at: 1000))
            check(began.phase == .began, "expected began")
            expectClose(began.delta.x, 0, 0.001, "sideways drift is dropped")
            expectClose(began.delta.y, 5, 0.001)
            expectClose(began.velocity.x, 0, 0.001)

            let changed = try require(step(tracker, recognizer,
                                           [contact(0, 16, 20), contact(1, 36, 20)], at: 2000))
            expectClose(changed.delta.x, 0, 0.001)
            expectClose(changed.delta.y, 5, 0.001)

            let ended = try require(step(tracker, recognizer, [], at: 3000))
            check(ended.phase == .ended, "expected ended")
            expectClose(ended.velocity.x, 0, 0.001, "momentum keeps to the axis")
        }

        TestRunner.test("the axis lock lasts the whole gesture") {
            let tracker = makeTracker(), recognizer = ScrollRecognizer()
            _ = step(tracker, recognizer, [contact(0, 10, 10), contact(1, 30, 10)], at: 0)
            _ = step(tracker, recognizer, [contact(0, 10, 15), contact(1, 30, 15)], at: 1000)

            // Now purely sideways: still locked vertical.
            let update = try require(step(tracker, recognizer,
                                          [contact(0, 20, 15), contact(1, 40, 15)], at: 2000))
            expectClose(update.delta.x, 0, 0.001)
        }

        TestRunner.test("a slightly tilted horizontal swipe scrolls only horizontally") {
            let tracker = makeTracker(), recognizer = ScrollRecognizer()
            _ = step(tracker, recognizer, [contact(0, 10, 10), contact(1, 10, 30)], at: 0)

            let update = try require(step(tracker, recognizer,
                                          [contact(0, 18, 11.5), contact(1, 18, 31.5)], at: 1000))
            expectClose(update.delta.x, 8, 0.001)
            expectClose(update.delta.y, 0, 0.001, "vertical drift is dropped")
        }

        TestRunner.test("a diagonal swipe moves on both axes") {
            let tracker = makeTracker(), recognizer = ScrollRecognizer()
            _ = step(tracker, recognizer, [contact(0, 10, 10), contact(1, 30, 10)], at: 0)

            let update = try require(step(tracker, recognizer,
                                          [contact(0, 14, 12), contact(1, 34, 12)], at: 1000))
            expectClose(update.delta.x, 4, 0.001)
            expectClose(update.delta.y, 2, 0.001)
        }

        TestRunner.test("turning the axis lock off passes deltas through") {
            let tracker = makeTracker(), recognizer = ScrollRecognizer()
            recognizer.axisLockEnabled = false
            _ = step(tracker, recognizer, [contact(0, 10, 10), contact(1, 30, 10)], at: 0)

            let update = try require(step(tracker, recognizer,
                                          [contact(0, 13, 15), contact(1, 33, 15)], at: 1000))
            expectClose(update.delta.x, 3, 0.001)
            expectClose(update.delta.y, 5, 0.001)
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

// The CGEvent field encoding. Invisible from inside the process that posts it,
// and the two delta fields are in different units, so getting one wrong looks
// like perfectly good scrolling in every app that happens to read the other.
func runScrollEventTests() {
    TestRunner.suite("Scroll event encoding") {

        TestRunner.test("pixel and line deltas are in their own units") {
            let event = try require(ScrollSynthesizer.makeEvent(
                pixels: Point(x: 0, y: 28), lines: Point(x: 0, y: 2.84),
                phase: .changed, momentum: .none))
            expectClose(Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)),
                        28, 0.001, "PointDelta is pixels — NSEvent.scrollingDeltaY")
            expectClose(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
                        2.84, 0.001, "FixedPtDelta is lines — NSEvent.deltaY")
        }

        // The ratio CoreGraphics uses itself, so it is worth pinning: build a
        // pixel-unit event and read back what it chose.
        TestRunner.test("the line ratio matches what CoreGraphics picks") {
            let reference = try require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                                wheelCount: 2, wheel1: 100, wheel2: 0, wheel3: 0))
            expectClose(reference.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
                        100 / ScrollSynthesizer.pixelsPerLine, 0.001,
                        "CoreGraphics converts pixels to lines at our ratio")
        }

        TestRunner.test("horizontal scrolling uses axis 2") {
            let event = try require(ScrollSynthesizer.makeEvent(
                pixels: Point(x: -20, y: 0), lines: Point(x: -2, y: 0),
                phase: .changed, momentum: .none))
            expectClose(Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)),
                        -20, 0.001, "pixels on axis 2")
            expectClose(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
                        -2, 0.001, "lines on axis 2")
        }

        TestRunner.test("a sub-pixel delta still carries a fractional line") {
            let event = try require(ScrollSynthesizer.makeEvent(
                pixels: Point(x: 0, y: 0), lines: Point(x: 0, y: 0.05),
                phase: .changed, momentum: .none))
            check(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 0,
                  "no whole pixel yet")
            check(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) > 0,
                  "but the fraction survives for a line-based reader")
        }

        TestRunner.test("continuous is set, or apps treat it as a notched wheel") {
            let event = try require(ScrollSynthesizer.makeEvent(
                pixels: Point(x: 0, y: 10), lines: Point(x: 0, y: 1),
                phase: .changed, momentum: .none))
            check(event.getIntegerValueField(.scrollWheelEventIsContinuous) == 1,
                  "continuous flag must be set")
        }
    }
}
