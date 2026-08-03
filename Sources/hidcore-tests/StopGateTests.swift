import Foundation
import TouchEvents

// The stop gate drops the firmware's deceleration tail. The danger is not that
// it fails to fire — it is that it fires on movement the user meant, which is
// how every previous attempt at this problem went wrong. Most of these tests
// are about what it must NOT cut.

/// The measured decay: per-frame deltas fall by ~0.72 each frame for 35–85ms
/// after the finger stops. Taken from the two `hid-stream --trace` captures.
private let decayPerFrame = 0.72
private let frame = 1.0 / 154.0     // the device's real report interval

/// Runs a speed profile through the gate, returning which frames got through.
private func run(_ speeds: [Double], _ gate: inout StopGate) -> [Bool] {
    speeds.map { gate.allows(speed: $0) }
}

/// A fast swipe that stops dead, as the device actually reports it.
private func swipeThenStop(peak: Double, tailFrames: Int) -> [Double] {
    var speeds = [Double]()
    for _ in 0..<12 { speeds.append(peak) }
    var v = peak
    for _ in 0..<tailFrames { v *= decayPerFrame; speeds.append(v) }
    return speeds
}

func runStopGateTests() {
    TestRunner.suite("Stop gate") {

        TestRunner.test("an abrupt stop after a fast swipe is cut short") {
            var gate = StopGate()
            let speeds = swipeThenStop(peak: 290, tailFrames: 20)
            let passed = run(speeds, &gate)

            let tail = passed.dropFirst(12)
            let emitted = tail.filter { $0 }.count
            check(emitted <= 6,
                  "\(emitted) of 20 tail frames still reached the cursor")
            check(tail.suffix(10).allSatisfy { !$0 },
                  "the gate must stay shut once the tail is established")
        }

        TestRunner.test("the glide is cut to well under 0.1 seconds") {
            // The reported symptom, in the units it was reported in.
            var gate = StopGate()
            let speeds = swipeThenStop(peak: 290, tailFrames: 25)
            let passed = run(speeds, &gate)

            let emittedAfterStop = passed.dropFirst(12).filter { $0 }.count
            let glide = Double(emittedAfterStop) * frame
            check(glide < 0.05,
                  String(format: "still gliding %.0f ms", glide * 1000))
        }

        // The failure mode that matters most. Fine positioning happens under
        // ~20 mm/s, well below stopSpeed, and a gate that fired there would
        // freeze the cursor exactly when the user is trying to aim.
        TestRunner.test("deliberate slow movement is never gated") {
            var gate = StopGate()
            // Wandering slowly, as when placing a cursor in text.
            let speeds = [6.0, 10, 8, 15, 12, 7, 16, 9, 4, 13, 9, 5]
            check(run(speeds, &gate).allSatisfy { $0 },
                  "slow movement must pass — the gate was never armed")
        }

        TestRunner.test("slowing down without having been fast is not gated") {
            var gate = StopGate()
            // A gentle deceleration from a modest speed: still a finger.
            let speeds = [44.0, 38, 32, 27, 22, 17, 14, 11, 8]
            check(run(speeds, &gate).allSatisfy { $0 },
                  "never crossed armSpeed, so there is no tail to cut")
        }

        TestRunner.test("a finger that slows then moves again is released") {
            var gate = StopGate()
            var speeds = swipeThenStop(peak: 290, tailFrames: 8)
            // The user pushes on rather than lifting.
            speeds.append(contentsOf: [65.0, 131, 189, 218])
            let passed = run(speeds, &gate)

            check(passed.suffix(3).allSatisfy { $0 },
                  "re-acceleration must reopen the gate immediately")
        }

        TestRunner.test("noise cannot creep the gate back open") {
            var gate = StopGate()
            var speeds = swipeThenStop(peak: 290, tailFrames: 10)
            // Resting jitter: small, and not monotonic.
            for i in 0..<20 { speeds.append(i % 2 == 0 ? 2.2 : 3.6) }
            let passed = run(speeds, &gate)

            check(passed.suffix(20).allSatisfy { !$0 },
                  "a still finger must stay still")
        }

        TestRunner.test("a fresh touch starts with the gate open") {
            var gate = StopGate()
            _ = run(swipeThenStop(peak: 290, tailFrames: 10), &gate)
            gate.reset()
            check(gate.allows(speed: 3.6),
                  "lifting and touching again must not inherit a shut gate")
        }

        TestRunner.test("one frame of decrease is not enough to fire") {
            var gate = StopGate()
            // Fast, then a single noisy dip, then fast again — not a stop.
            let passed = run([218.0, 233, 218, 247, 240, 255], &gate)
            check(passed.allSatisfy { $0 },
                  "a tail decreases every frame; noise does not")
        }

        // --hard-stop. The default gate deliberately lets a few frames of tail
        // through so it cannot clip a real deceleration; this trades that away.
        TestRunner.test("the aggressive preset cuts the tail sooner") {
            let speeds = swipeThenStop(peak: 290, tailFrames: 20)

            var normal = StopGate()
            var eager = StopGate()
            eager.makeAggressive()

            let normalFrames = run(speeds, &normal).dropFirst(12).filter { $0 }.count
            let eagerFrames = run(speeds, &eager).dropFirst(12).filter { $0 }.count

            check(eagerFrames < normalFrames,
                  "aggressive let \(eagerFrames) through vs \(normalFrames)")
            check(Double(eagerFrames) * frame < 0.02,
                  String(format: "still %.0f ms of glide", Double(eagerFrames) * frame * 1000))
        }

        TestRunner.test("the aggressive preset arms on ordinary pointing speeds") {
            // The default arms at 87 mm/s, so stopping from a moderate move
            // never triggers it at all — which is why the tail was still
            // visible after ordinary use rather than only after fast swipes.
            var eager = StopGate()
            eager.makeAggressive()
            let passed = run(swipeThenStop(peak: 65, tailFrames: 12), &eager)
            check(passed.suffix(6).allSatisfy { !$0 },
                  "a stop from 65 mm/s must still be cut")
        }

        TestRunner.test("even the aggressive preset cannot cut the first frame") {
            // Worth pinning, because it bounds what gating can ever achieve.
            // The tail is only recognisable once it has started arriving, so
            // some of it is always emitted. Nothing in userland removes the
            // remaining lag — see the deleted lead compensation in README.
            var eager = StopGate()
            eager.makeAggressive()
            let passed = run(swipeThenStop(peak: 290, tailFrames: 10), &eager)
            check(passed[12], "the first tail frame is indistinguishable in the moment")
        }

        TestRunner.test("disabling it passes everything through") {
            var gate = StopGate()
            gate.enabled = false
            check(run(swipeThenStop(peak: 290, tailFrames: 20), &gate).allSatisfy { $0 },
                  "--no-stop-gate must be a true bypass, for A/B testing")
        }

        TestRunner.test("a slow drift after a fast stop stays cut") {
            // The exact symptom: finger stops, cursor keeps creeping.
            var gate = StopGate()
            var speeds = swipeThenStop(peak: 364, tailFrames: 6)
            for _ in 0..<15 { speeds.append(2.9) }   // creep, not quite still
            let passed = run(speeds, &gate)
            check(passed.suffix(15).allSatisfy { !$0 }, "creep must not reach the cursor")
        }
    }
}
