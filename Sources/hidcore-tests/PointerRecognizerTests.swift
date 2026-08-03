import Foundation
import HIDCore

// Pointer recognition is mostly about timing and about staying out of the way
// of two-finger gestures, so these drive synthetic frames at a realistic rate.

private let modulus = 65536
private let tick = 0.0001
/// 100 counts = 10ms, roughly the real report interval.
private let frameCounts = 100

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

/// Drives tracker + recognizer one frame at a time, advancing scan time.
private final class Harness {
    let tracker = makeTracker()
    let recognizer = PointerRecognizer()
    private var scanTime = 0

    func step(_ contacts: [Contact], buttons: [Bool] = []) -> [PointerEvent] {
        tracker.update(Frame(contacts: contacts, declaredCount: contacts.count,
                             buttons: buttons, scanTime: scanTime))
        scanTime += frameCounts
        return recognizer.update(tracks: tracker.active, buttons: buttons,
                                 dt: tracker.lastDelta)
    }

    /// Hold the given contacts still for a number of frames.
    func hold(_ contacts: [Contact], frames: Int) {
        for _ in 0..<frames { _ = step(contacts) }
    }
}

private func moves(_ events: [PointerEvent]) -> [Point] {
    events.compactMap { if case .move(let d) = $0 { return d } else { return nil } }
}

private func taps(_ events: [PointerEvent]) -> [(MouseButton, Int)] {
    events.compactMap { if case .tap(let b, let c) = $0 { return (b, c) } else { return nil } }
}

func runPointerRecognizerTests() {
    TestRunner.suite("Pointer recognition") {

        TestRunner.test("one finger moving emits cursor motion") {
            let h = Harness()
            _ = h.step([contact(0, 10, 10)])
            let events = h.step([contact(0, 14, 13)])

            let deltas = moves(events)
            expectEqual(deltas.count, 1)
            expectClose(deltas[0].x, 4, 0.001)
            expectClose(deltas[0].y, 3, 0.001)
        }

        TestRunner.test("the first frame of a touch does not jump the cursor") {
            let h = Harness()
            // No previous position to diff against, so nothing should move.
            expectEqual(moves(h.step([contact(0, 40, 40)])).count, 0)
        }

        TestRunner.test("two fingers do not move the cursor") {
            let h = Harness()
            _ = h.step([contact(0, 10, 10), contact(1, 30, 10)])
            let events = h.step([contact(0, 14, 13), contact(1, 34, 13)])
            expectEqual(moves(events).count, 0, "two fingers belong to scrolling")
        }

        // The straggler problem again: a scroll ends one finger at a time, and
        // the remaining finger must not become a pointer drag.
        TestRunner.test("a straggler after a two-finger gesture does not move the cursor") {
            let h = Harness()
            _ = h.step([contact(0, 10, 10), contact(1, 30, 10)])
            _ = h.step([contact(0, 14, 13), contact(1, 34, 13)])
            // Second finger lifts, first lingers and drifts.
            let events = h.step([contact(0, 20, 20)])
            expectEqual(moves(events).count, 0,
                        "sequence had two fingers, so it stays suppressed")
        }

        TestRunner.test("the cursor works again after every finger lifts") {
            let h = Harness()
            _ = h.step([contact(0, 10, 10), contact(1, 30, 10)])
            _ = h.step([contact(0, 20, 20)])
            _ = h.step([])                       // all lifted, sequence resets

            _ = h.step([contact(0, 10, 10)])
            expectEqual(moves(h.step([contact(0, 15, 10)])).count, 1)
        }

        // MARK: Taps

        TestRunner.test("a quick touch produces a left click") {
            let h = Harness()
            _ = h.step([contact(0, 20, 20)])
            _ = h.step([contact(0, 20.2, 20.1)])   // negligible drift
            let result = taps(h.step([]))

            expectEqual(result.count, 1)
            check(result.first?.0 == .left, "expected a left tap")
            expectEqual(result.first?.1, 1, "single click")
        }

        TestRunner.test("a long press is not a tap") {
            let h = Harness()
            _ = h.step([contact(0, 20, 20)])
            h.hold([contact(0, 20, 20)], frames: 80)   // 0.8s, past tapMaxDuration
            expectEqual(taps(h.step([])).count, 0)
        }

        TestRunner.test("a drag is not a tap") {
            let h = Harness()
            _ = h.step([contact(0, 20, 20)])
            _ = h.step([contact(0, 30, 20)])           // 10mm, past tapMaxTravel
            expectEqual(taps(h.step([])).count, 0)
        }

        TestRunner.test("two-finger tap produces a right click") {
            let h = Harness()
            _ = h.step([contact(0, 20, 20), contact(1, 30, 20)])
            _ = h.step([contact(0, 20, 20), contact(1, 30, 20)])
            let result = taps(h.step([]))

            expectEqual(result.count, 1)
            check(result.first?.0 == .right, "two fingers means right click")
        }

        // Real fingers do not land or lift on the same frame. At ~154Hz a
        // perfectly ordinary two-finger tap can have the second finger arrive
        // as the first leaves, so the two never appear in one report — which
        // used to produce a LEFT click, and a double one if you tapped twice.
        TestRunner.test("two fingers offset by a frame is still a right click") {
            let h = Harness()
            _ = h.step([contact(0, 20, 20)])                       // first alone
            _ = h.step([contact(1, 32, 20)])                       // second alone
            let result = taps(h.step([]))

            expectEqual(result.count, 1)
            check(result.first?.0 == .right,
                  "two distinct fingers means right click even without overlap")
        }

        TestRunner.test("a two-finger tap is given a looser time budget") {
            let h = Harness()
            let contacts = [contact(0, 20, 20), contact(1, 32, 20)]
            _ = h.step(contacts)
            // 0.5s — well past the one-finger limit, inside the two-finger one.
            h.hold(contacts, frames: 49)
            let result = taps(h.step([]))

            expectEqual(result.count, 1, "two fingers land and lift less crisply")
            check(result.first?.0 == .right, "expected a right tap")
        }

        TestRunner.test("a two-finger tap held too long is still rejected") {
            let h = Harness()
            let contacts = [contact(0, 20, 20), contact(1, 32, 20)]
            _ = h.step(contacts)
            h.hold(contacts, frames: 100)         // 1.0s, well past the 0.6s limit
            expectEqual(taps(h.step([])).count, 0, "a rest is not a tap")
            check(h.recognizer.lastTapRejection != nil, "the reason must be reported")
        }

        TestRunner.test("a two-finger drag is not a right click") {
            let h = Harness()
            _ = h.step([contact(0, 20, 20), contact(1, 32, 20)])
            _ = h.step([contact(0, 20, 32), contact(1, 32, 32)])   // 12mm scroll
            expectEqual(taps(h.step([])).count, 0, "that was a scroll")
        }

        TestRunner.test("two-finger tap can be disabled on its own") {
            let h = Harness()
            h.recognizer.twoFingerTapEnabled = false
            _ = h.step([contact(0, 20, 20), contact(1, 32, 20)])
            expectEqual(taps(h.step([])).count, 0, "no right click, and no left one either")
        }

        TestRunner.test("a right tap does not pair into a double click") {
            let h = Harness()
            _ = h.step([contact(0, 20, 20), contact(1, 32, 20)])
            _ = taps(h.step([]))
            _ = h.step([contact(0, 20, 20), contact(1, 32, 20)])
            let result = taps(h.step([]))
            expectEqual(result.first?.1, 1, "double right clicks are not a gesture")
        }

        TestRunner.test("two taps in quick succession make a double click") {
            let h = Harness()
            _ = h.step([contact(0, 20, 20)])
            _ = taps(h.step([]))                       // first tap
            _ = h.step([contact(0, 20.5, 20.5)])
            let result = taps(h.step([]))

            expectEqual(result.count, 1)
            expectEqual(result.first?.1, 2, "second tap pairs into a double")
        }

        TestRunner.test("taps far apart do not pair") {
            let h = Harness()
            _ = h.step([contact(0, 20, 20)])
            _ = taps(h.step([]))
            _ = h.step([contact(0, 45, 45)])           // well past doubleTapMaxDistance
            let result = taps(h.step([]))
            expectEqual(result.first?.1, 1, "distant tap starts a fresh count")
        }

        TestRunner.test("taps far apart in time do not pair") {
            let h = Harness()
            _ = h.step([contact(0, 20, 20)])
            _ = taps(h.step([]))
            h.hold([], frames: 60)                     // 0.6s of nothing
            _ = h.step([contact(0, 20, 20)])
            let result = taps(h.step([]))
            expectEqual(result.first?.1, 1, "stale tap must not pair")
        }

        TestRunner.test("a non-confident contact is ignored") {
            let h = Harness()
            _ = h.step([contact(0, 20, 20, confident: false)])
            let events = h.step([contact(0, 30, 20, confident: false)])
            expectEqual(moves(events).count, 0, "a palm must not drive the cursor")
        }

        // MARK: Physical buttons

        TestRunner.test("a physical button press and release is reported") {
            let h = Harness()
            var events = h.step([contact(0, 20, 20)], buttons: [true, false, false])
            var changes = events.compactMap {
                if case .buttonChanged(let b, let d) = $0 { return (b, d) } else { return nil }
            }
            expectEqual(changes.count, 1)
            check(changes.first?.0 == .left && changes.first?.1 == true, "left down")

            events = h.step([contact(0, 20, 20)], buttons: [false, false, false])
            changes = events.compactMap {
                if case .buttonChanged(let b, let d) = $0 { return (b, d) } else { return nil }
            }
            expectEqual(changes.count, 1)
            check(changes.first?.1 == false, "left up")
        }

        TestRunner.test("a held button reports only once") {
            let h = Harness()
            _ = h.step([contact(0, 20, 20)], buttons: [true, false, false])
            let events = h.step([contact(0, 21, 20)], buttons: [true, false, false])
            let changes = events.filter {
                if case .buttonChanged = $0 { return true } else { return false }
            }
            expectEqual(changes.count, 0, "only edges are events")
        }
    }
}
