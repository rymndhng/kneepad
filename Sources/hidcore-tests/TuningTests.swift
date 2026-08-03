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
            expectClose(tuning.accelReference, pointer.accelerationReference, 1e-9)
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
            tuning.accelReference = 215
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
            tuning.accelReference = 200
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
            expectClose(pointer.accelerationReference, 200, 1e-9)
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
            tuning.accelReference = 210

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
