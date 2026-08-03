import Foundation
import HIDCore

// The tracker turns snapshots into events, so every test here is really about
// diffing: what changed between two frames, and what that means.

private let modulus = 65536      // PTP Scan Time is a 16-bit counter
private let tick = 0.0001        // 100 µs per count

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

func runContactTrackerTests() {
    TestRunner.suite("Contact tracking") {

        // MARK: Lifecycle

        TestRunner.test("a finger landing produces began") {
            let tracker = makeTracker()
            let events = tracker.update(frame([contact(0, 10, 20)], at: 0))

            expectEqual(events.count, 1)
            guard case .began(let track) = try require(events.first) else {
                throw TestFailure(description: "expected began")
            }
            expectEqual(track.id, 0)
            expectEqual(track.hardwareID, 0)
            check(track.origin == Point(x: 10, y: 20), "origin recorded")
        }

        TestRunner.test("a finger lifting produces ended") {
            let tracker = makeTracker()
            tracker.update(frame([contact(0, 10, 20)], at: 0))
            let events = tracker.update(frame([], at: 1000))

            expectEqual(events.count, 1)
            guard case .ended(let track) = try require(events.first) else {
                throw TestFailure(description: "expected ended")
            }
            expectEqual(track.id, 0)
        }

        TestRunner.test("track IDs are never reused even when hardware IDs are") {
            let tracker = makeTracker()
            tracker.update(frame([contact(0, 10, 20)], at: 0))
            tracker.update(frame([], at: 1000))
            // Hardware recycles Contact Identifier 0 for the next finger.
            let events = tracker.update(frame([contact(0, 50, 50)], at: 2000))

            guard case .began(let track) = try require(events.first) else {
                throw TestFailure(description: "expected began")
            }
            expectEqual(track.hardwareID, 0, "hardware reused its ID")
            expectEqual(track.id, 1, "tracker must not reuse track IDs")
        }

        TestRunner.test("two fingers track independently") {
            let tracker = makeTracker()
            tracker.update(frame([contact(0, 10, 10), contact(1, 40, 10)], at: 0))
            tracker.update(frame([contact(0, 12, 10), contact(1, 38, 10)], at: 1000))

            let tracks = tracker.active
            expectEqual(tracks.count, 2)
            expectClose(tracks[0].position.x, 12)
            expectClose(tracks[1].position.x, 38)
        }

        // MARK: Motion

        TestRunner.test("distance accumulates path length, not displacement") {
            let tracker = makeTracker()
            tracker.update(frame([contact(0, 0, 0)], at: 0))
            tracker.update(frame([contact(0, 10, 0)], at: 1000))
            tracker.update(frame([contact(0, 0, 0)], at: 2000))   // back to start

            let track = tracker.active[0]
            expectClose(track.distance, 20, 0.001, "path length is 20mm")
            expectClose(track.displacement.magnitude, 0, 0.001, "ended where it began")
        }

        TestRunner.test("velocity derives from scan time and is smoothed") {
            let tracker = makeTracker()
            tracker.update(frame([contact(0, 0, 0)], at: 0))
            // 1000 counts = 0.1s, moved 10mm → 100 mm/s instantaneous.
            tracker.update(frame([contact(0, 10, 0)], at: 1000))

            expectClose(tracker.active[0].velocity.x, Track.velocitySmoothing * 100)
        }

        TestRunner.test("scan time wrap-around does not invert velocity") {
            let tracker = makeTracker()
            tracker.update(frame([contact(0, 0, 0)], at: modulus - 36))
            tracker.update(frame([contact(0, 10, 0)], at: 100))

            // 36 counts to wrap + 100 after = 136 counts = 13.6ms
            expectClose(tracker.lastDelta, 136 * tick, 1e-9)
            check(tracker.active[0].velocity.x > 0, "velocity must not invert on wrap")
        }

        TestRunner.test("the first frame has nothing to diff against") {
            let tracker = makeTracker()
            tracker.update(frame([contact(0, 0, 0)], at: 5000))
            expectEqual(tracker.lastDelta, 0)
        }

        // MARK: Confidence

        TestRunner.test("confidence is carried onto the track") {
            let tracker = makeTracker()
            tracker.update(frame([contact(0, 10, 10, confident: false)], at: 0))
            expectEqual(tracker.active[0].confident, false)
        }

        // MARK: ID stability

        TestRunner.test("hardware renumbering a live finger is detected as churn") {
            let tracker = makeTracker()
            tracker.update(frame([contact(0, 10, 10)], at: 0))
            expectEqual(tracker.idChurnDetected, false)

            // Same finger, renumbered: one dies, one is born, count steady.
            tracker.update(frame([contact(1, 11, 10)], at: 1000))
            expectEqual(tracker.idChurnDetected, true)
        }

        TestRunner.test("lifting then pressing later is not churn") {
            let tracker = makeTracker()
            tracker.update(frame([contact(0, 10, 10)], at: 0))
            tracker.update(frame([], at: 1000))                    // lifted
            tracker.update(frame([contact(1, 40, 40)], at: 2000))  // new finger later
            expectEqual(tracker.idChurnDetected, false)
        }

        // MARK: Two-finger geometry

        TestRunner.test("spread and centroid of two contacts") {
            let tracker = makeTracker()
            tracker.update(frame([contact(0, 0, 0), contact(1, 30, 40)], at: 0))

            let state = try require(TwoFingerState(tracker.active))
            expectClose(state.spread, 50, 0.001, "3-4-5 triangle")
            expectClose(state.centroid.x, 15)
            expectClose(state.centroid.y, 20)
        }

        TestRunner.test("rotation takes the shortest path across ±π") {
            let tracker = makeTracker()
            tracker.update(frame([contact(0, 0, 0), contact(1, -10, 1)], at: 0))
            let a = try require(TwoFingerState(tracker.active))

            tracker.update(frame([contact(0, 0, 0), contact(1, -10, -1)], at: 1000))
            let b = try require(TwoFingerState(tracker.active))

            check(abs(b.rotation(from: a)) < 0.5, "wrap-around must not read as a half turn")
        }

        TestRunner.test("a single finger has no two-finger geometry") {
            let tracker = makeTracker()
            tracker.update(frame([contact(0, 10, 10)], at: 0))
            expectNil(TwoFingerState(tracker.active))
        }
    }
}
