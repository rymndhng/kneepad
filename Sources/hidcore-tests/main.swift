import Foundation

// Unit tests for HIDCore. No hardware required — every test runs against
// hand-written descriptors, a captured copy of the real Voyager descriptor,
// and synthetic report bodies.
//
//   swift run hidcore-tests

runDescriptorTests()
runContactTrackerTests()
runScrollRecognizerTests()
runPointerRecognizerTests()
runSmoothingTests()
runAccelerationTests()
runStopGateTests()
runCalibrationTests()

exit(TestRunner.summarize())
