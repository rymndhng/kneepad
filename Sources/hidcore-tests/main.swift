import Foundation

// Unit tests for HIDCore. No hardware required — every test runs against
// hand-written descriptors, a captured copy of the real Voyager descriptor,
// and synthetic report bodies.
//
//   swift run hidcore-tests

runDescriptorTests()
runContactTrackerTests()
runScrollRecognizerTests()
runScrollEventTests()
runPointerRecognizerTests()
runAccelerationTests()
runStopGateTests()
runCalibrationTests()
runTuningTests()
runDriverLockTests()
runScrollDirectionTests()
runMomentumPhaseTests()

exit(TestRunner.summarize())
