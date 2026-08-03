import Foundation
import HIDCore

// The descriptor's physical range is a claim. On this device it claims 55mm
// across, while the sensor measures 40mm — so uncorrected, every millimetre
// the pipeline reports is inflated 1.375x. These pin the correction.

func runCalibrationTests() {
    TestRunner.suite("Surface calibration") {

        TestRunner.test("the descriptor's own claim is preserved separately") {
            let parsed = try parseDescriptor(voyagerDescriptor)
            var layout = try require(discoverTouchLayout(parsed))
            layout.positionScale = ZSA.measuredSurfaceWidthMM / 55.0

            let declared = try require(layout.declaredSurfaceSize)
            expectClose(declared.x, 55.0, 0.05,
                        "the claim must stay readable after correction")
        }

        TestRunner.test("correcting the scale corrects the reported surface") {
            let parsed = try parseDescriptor(voyagerDescriptor)
            var layout = try require(discoverTouchLayout(parsed))
            layout.positionScale = ZSA.measuredSurfaceWidthMM / 55.0

            let size = try require(layout.surfaceSize)
            expectClose(size.x, 40.0, 0.05, "surface width after correction")
            expectClose(size.y, 40.0, 0.05, "surface height after correction")
        }

        TestRunner.test("a corrected scale carries into decoded positions") {
            let parsed = try parseDescriptor(voyagerDescriptor)
            var layout = try require(discoverTouchLayout(parsed))

            // Contact 1 down, X = 1024 — the middle of the logical range.
            var body = [UInt8](repeating: 0, count: layout.bodyLength)
            body[0] = 0x03                       // bit 0 confidence, bit 1 tip switch
            body[2] = 0x00; body[3] = 0x04       // X = 1024, little endian

            layout.positionScale = 1.0
            expectClose(layout.decode(body).contacts[0].position.x, 27.5, 0.01,
                        "half of the claimed 55mm")

            layout.positionScale = ZSA.measuredSurfaceWidthMM / 55.0
            expectClose(layout.decode(body).contacts[0].position.x, 20.0, 0.01,
                        "half of the measured 40mm")
        }

        TestRunner.test("an uncorrected layout trusts the descriptor") {
            let parsed = try parseDescriptor(voyagerDescriptor)
            let layout = try require(discoverTouchLayout(parsed))
            expectClose(layout.positionScale, 1.0, 1e-12,
                        "correction must be opt-in, not silent")
            expectClose(try require(layout.surfaceSize).x, 55.0, 0.05)
        }
    }
}
