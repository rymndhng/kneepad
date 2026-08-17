import Foundation
import HIDCore
import TouchEvents

// Tuning is the contract between the tuner app and the daemon. A mistake here
// is silent — a slider that moves nothing, or a field that quietly resets to
// its default on every reload.

private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("teach-touch-tests-\(UUID().uuidString)")
        .appendingPathComponent("tuning.json")
}

func runTuningTests() {
    TestRunner.suite("Tuning") {

        TestRunner.test("defaults match the code they configure") {
            // If these drift, the tuner shows values the driver is not using
            // until the file is written once.
            let tuning = Tuning()
            let pointer = PointerSynthesizer.Configuration()
            expectClose(tuning.pointerGain, pointer.gain, 1e-9)
            expectClose(tuning.accelMin, pointer.minAcceleration, 1e-9)
            expectClose(tuning.accelMax, pointer.maxAcceleration, 1e-9)
            expectClose(tuning.accelCurve, pointer.accelerationCurve, 1e-9)
            expectClose(tuning.accelPivot, pointer.accelerationPivot, 1e-9)
            expectClose(tuning.armSpeed, pointer.stopGate.armSpeed, 1e-9)
            expectClose(tuning.stopSpeed, pointer.stopGate.stopSpeed, 1e-9)

            let recognizer = PointerRecognizer()
            expectClose(tuning.tapTime, recognizer.tapMaxDuration, 1e-9)
            expectClose(tuning.tapTravel, recognizer.tapMaxTravel, 1e-9)
            expectClose(tuning.twoTapTime, recognizer.twoFingerTapMaxDuration, 1e-9)
            expectClose(tuning.twoTapTravel, recognizer.twoFingerTapMaxTravel, 1e-9)
            expectClose(tuning.doubleTapTime, recognizer.doubleTapInterval, 1e-9)
            expectClose(tuning.doubleTapDistance, recognizer.doubleTapMaxDistance, 1e-9)

            let scroll = ScrollSynthesizer.Configuration()
            expectClose(tuning.scrollGain, scroll.gain, 1e-9)
            expectClose(tuning.scrollDecay, scroll.momentumDecayTime, 1e-9)
        }

        TestRunner.test("every field survives a round trip") {
            var tuning = Tuning()
            tuning.pointerGain = 17.5
            tuning.accelMin = 0.42
            tuning.accelMax = 4.25
            tuning.accelCurve = 0.85
            tuning.accelPivot = 215
            tuning.accelEnabled = false
            tuning.stopGateEnabled = false
            tuning.armSpeed = 77
            tuning.stopSpeed = 33
            tuning.scrollGain = 44
            tuning.scrollDecay = 0.19
            tuning.naturalScroll = false
            tuning.momentumEnabled = false
            tuning.tapEnabled = false
            tuning.rightTapEnabled = false
            tuning.tapTime = 0.31
            tuning.tapTravel = 3.3
            tuning.twoTapTime = 0.77
            tuning.twoTapTravel = 5.5
            tuning.doubleTapTime = 0.29
            tuning.doubleTapDistance = 11
            tuning.surfaceWidth = 25

            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            try tuning.save(to: url)

            let loaded = try require(Tuning.load(from: url))
            check(loaded == tuning, "a field was dropped in encode or decode")
        }

        TestRunner.test("a missing file loads as nil, not as defaults") {
            // touchd must be able to tell "never tuned" from "tuned to the
            // defaults", or --no-live and a fresh install behave differently.
            expectNil(Tuning.load(from: temporaryURL()))
        }

        TestRunner.test("applying reaches every configuration") {
            var tuning = Tuning()
            tuning.pointerGain = 9
            tuning.accelPivot = 200
            tuning.stopSpeed = 45
            tuning.scrollGain = 50
            tuning.tapTravel = 1.5

            var pointer = PointerSynthesizer.Configuration()
            var scroll = ScrollSynthesizer.Configuration()
            let recognizer = PointerRecognizer()
            tuning.apply(to: &pointer)
            tuning.apply(to: &scroll)
            tuning.apply(to: recognizer)

            expectClose(pointer.gain, 9, 1e-9)
            expectClose(pointer.accelerationPivot, 200, 1e-9)
            expectClose(pointer.stopGate.stopSpeed, 45, 1e-9)
            expectClose(scroll.gain, 50, 1e-9)
            expectClose(recognizer.tapMaxTravel, 1.5, 1e-9)
        }

        // The tuner plots this. If it were a second copy of the formula the
        // picture could disagree with the behaviour, which is the exact failure
        // this project already hit between its docs and its code.
        TestRunner.test("the plotted curve is the driver's own curve") {
            var tuning = Tuning()
            tuning.pointerGain = 15
            tuning.accelCurve = 0.9
            tuning.accelPivot = 210

            var config = PointerSynthesizer.Configuration()
            tuning.apply(to: &config)

            for speed in [5.0, 40, 120, 300, 900] {
                expectClose(tuning.pixelsPerMillimetre(atSpeed: speed),
                            config.pixelsPerMillimetre(atSpeed: speed), 1e-12,
                            "tuner and driver disagree at \(speed) mm/s")
            }
            expectClose(tuning.accelerationKnee, config.accelerationKnee, 1e-12)
        }

        TestRunner.test("disabling acceleration flattens the curve to plain gain") {
            var tuning = Tuning()
            tuning.accelEnabled = false
            tuning.pointerGain = 14
            for speed in [5.0, 100, 800] {
                expectClose(tuning.pixelsPerMillimetre(atSpeed: speed), 14, 1e-12,
                            "no acceleration means one flat rate")
            }
        }

        TestRunner.test("the watcher reports a write") {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            try Tuning().save(to: url)

            let queue = DispatchQueue(label: "tuning-test")
            let received = DispatchSemaphore(value: 0)
            var seen: Tuning?

            let watcher = TuningWatcher(url: url, queue: queue) { tuning in
                seen = tuning
                received.signal()
            }
            watcher.start()
            defer { watcher.stop() }

            var edited = Tuning()
            edited.pointerGain = 31
            try edited.save(to: url)

            let arrived = received.wait(timeout: .now() + 3)
            check(arrived == .success, "no change reported within 3s")
            expectClose(seen?.pointerGain ?? 0, 31, 1e-9, "wrong value delivered")
        }
    }
}

// The lock is what stops two drivers from fighting over Input Mode, and the
// failure is expensive — no usable cursor — so the exclusion is pinned here.

func runDriverLockTests() {
    TestRunner.suite("Driver lock") {

        func scratchURL() -> URL {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("teach-touch-lock-\(UUID().uuidString)")
                .appendingPathComponent("driver.pid")
        }

        TestRunner.test("a second acquire is refused while the first is held") {
            let url = scratchURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            let first = try require(DriverLock.acquire(url: url))
            expectNil(DriverLock.acquire(url: url), "two drivers must never both run")
            _ = first   // held until here, or the check above proves nothing
        }

        TestRunner.test("releasing lets the next driver in") {
            let url = scratchURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            var first: DriverLock? = DriverLock.acquire(url: url)
            check(first != nil, "the first acquire must succeed")
            first = nil

            let second = DriverLock.acquire(url: url)
            check(second != nil, "quitting one driver must let the next start")
            _ = second
        }

        TestRunner.test("the holder is named so a refusal can say who") {
            let url = scratchURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            let held = try require(DriverLock.acquire(url: url))
            expectEqual(DriverLock.holderPID(url: url),
                        ProcessInfo.processInfo.processIdentifier)
            _ = held
        }

        // The file outliving its holder is the whole reason this is a lock and
        // not a pid comparison: a crashed driver leaves the pid behind, and
        // reading it as live is how the machine ends up with no working driver.
        TestRunner.test("a file left behind by a dead holder does not block") {
            let url = scratchURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // A pid that is not us and is not running.
            try "999999\n".write(to: url, atomically: true, encoding: .utf8)

            check(DriverLock.acquire(url: url) != nil,
                  "a stale pid file must not lock the trackpad out forever")
        }
    }
}

// Scroll direction was inverted in shipped code: what the configuration called
// "natural" produced the opposite of macOS's natural scrolling, and --reverse
// produced the right thing. Pinned here so it cannot silently flip back.

func runScrollDirectionTests() {
    TestRunner.suite("Scroll direction") {

        /// Fingers moving down the pad. Pad Y grows downward, so this is +y.
        let downward = Point(x: 0, y: 10)
        /// Fingers moving right.
        let rightward = Point(x: 10, y: 0)

        TestRunner.test("natural scrolling sends the content after the fingers") {
            var config = ScrollSynthesizer.Configuration()
            config.naturalDirection = true
            check(config.pixels(downward).y > 0,
                  "dragging down must produce a positive scroll delta")
        }

        TestRunner.test("reversing flips only the vertical axis") {
            var natural = ScrollSynthesizer.Configuration()
            natural.naturalDirection = true
            var reversed = ScrollSynthesizer.Configuration()
            reversed.naturalDirection = false

            expectClose(reversed.pixels(downward).y, -natural.pixels(downward).y, 1e-9)
            expectClose(reversed.pixels(rightward).x, natural.pixels(rightward).x, 1e-9,
                        "--reverse is about vertical scrolling only")
        }

        TestRunner.test("horizontal inversion is independent") {
            var config = ScrollSynthesizer.Configuration()
            config.invertHorizontal = true
            check(config.pixels(rightward).x < 0, "inverted horizontal must flip x")
            check(config.pixels(downward).y > 0, "and must leave vertical alone")
        }

        TestRunner.test("gain scales both axes equally") {
            var config = ScrollSynthesizer.Configuration()
            config.gain = 10
            expectClose(config.pixels(Point(x: 3, y: 4)).x, 30, 1e-9)
            expectClose(abs(config.pixels(Point(x: 3, y: 4)).y), 40, 1e-9)
        }
    }
}

// Momentum phases. An app that has seen momentum begin animates on its own
// until it sees momentum end, so every begin must be matched — including when
// the user interrupts a glide by putting fingers back down.

func runMomentumPhaseTests() {
    TestRunner.suite("Scroll momentum phases") {

        /// A synthesiser that records phases instead of posting events.
        final class Log {
            var momentum: [ScrollSynthesizer.MomentumPhase] = []
            var scroll: [ScrollSynthesizer.Phase] = []
        }
        func recorder() -> (ScrollSynthesizer, Log) {
            let synth = ScrollSynthesizer()
            let log = Log()
            synth.postsEvents = false
            synth.onPost = { _, phase, momentum in
                log.momentum.append(momentum)
                if let phase { log.scroll.append(phase) }
            }
            return (synth, log)
        }

        /// A release fast enough to coast.
        func flick() -> ScrollUpdate {
            ScrollUpdate(phase: .ended, delta: Point(x: 0, y: 0),
                         velocity: Point(x: 0, y: 400))
        }

        TestRunner.test("a flick begins momentum") {
            let (synth, log) = recorder()
            synth.handle(flick())
            check(log.momentum.contains(.begin),
                  "expected a momentum begin, got \(log.momentum)")
        }

        // The reported symptom: coasting in Maps, two fingers back down, and
        // the map carried on. Cancelling our timer is not enough — the app is
        // running its own animation and only stops when told momentum ended.
        TestRunner.test("interrupting a glide ends the momentum sequence") {
            let (synth, log) = recorder()
            synth.handle(flick())
            synth.cancelMomentum()
            check(log.momentum.contains(.end),
                  "expected a momentum end, got \(log.momentum)")
        }

        // Ending the momentum phase satisfies AppKit scroll views but did not
        // stop Maps, which animates its own inertia. mayBegin is what a real
        // trackpad emits when fingers land, and what an app watches to abandon
        // that animation.
        TestRunner.test("interrupting a glide also says fingers have landed") {
            let (synth, log) = recorder()
            synth.handle(flick())
            synth.cancelMomentum()
            check(log.scroll.contains(.mayBegin),
                  "expected a mayBegin, got \(log.scroll)")
        }

        TestRunner.test("every begin is matched by exactly one end") {
            let (synth, log) = recorder()
            synth.handle(flick())
            synth.cancelMomentum()
            synth.cancelMomentum()      // idle cancels must stay silent
            synth.cancelMomentum()
            let begins = log.momentum.filter { $0 == .begin }.count
            let ends = log.momentum.filter { $0 == .end }.count
            expectEqual(begins, 1, "one flick, one begin")
            expectEqual(ends, 1, "a repeated cancel must not repeat the end")
        }

        TestRunner.test("cancelling when nothing is coasting posts nothing") {
            let (synth, log) = recorder()
            synth.cancelMomentum()
            expectEqual(log.momentum.count, 0,
                        "a new touch with no glide in flight must be silent")
        }

        TestRunner.test("a slow release does not begin momentum") {
            let (synth, log) = recorder()
            synth.handle(ScrollUpdate(phase: .ended, delta: Point(x: 0, y: 0),
                                      velocity: Point(x: 0, y: 0.2)))
            check(!log.momentum.contains(.begin), "a deliberate stop must not coast")
            let before = log.momentum.count
            synth.cancelMomentum()
            expectEqual(log.momentum.count, before,
                        "cancelling afterwards must not invent a sequence")
        }
    }
}
