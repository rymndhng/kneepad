import Foundation
import HIDCore

// Locks down the descriptor state machine against a hand-written toy device,
// so parser changes can't silently shift bit offsets.

/// The canonical 3-button relative mouse.
private let mouseA: [UInt8] = [
    0x05, 0x01,        // Usage Page (Generic Desktop)
    0x09, 0x02,        // Usage (Mouse)
    0xA1, 0x01,        // Collection (Application)
    0x09, 0x01,        //   Usage (Pointer)
    0xA1, 0x00,        //   Collection (Physical)
    0x05, 0x09,        //     Usage Page (Button)
    0x19, 0x01,        //     Usage Minimum (1)
    0x29, 0x03,        //     Usage Maximum (3)
    0x15, 0x00,        //     Logical Minimum (0)
    0x25, 0x01,        //     Logical Maximum (1)
    0x95, 0x03,        //     Report Count (3)
    0x75, 0x01,        //     Report Size (1)
    0x81, 0x02,        //     Input (Data,Var,Abs)
    0x95, 0x01,        //     Report Count (1)
    0x75, 0x05,        //     Report Size (5)
    0x81, 0x03,        //     Input (Const,Var,Abs) — padding
    0x05, 0x01,        //     Usage Page (Generic Desktop)
    0x09, 0x30,        //     Usage (X)
    0x09, 0x31,        //     Usage (Y)
    0x15, 0x81,        //     Logical Minimum (-127)
    0x25, 0x7F,        //     Logical Maximum (127)
    0x75, 0x08,        //     Report Size (8)
    0x95, 0x02,        //     Report Count (2)
    0x81, 0x06,        //     Input (Data,Var,Rel)
    0xC0, 0xC0,
]

/// Same device, globals hoisted and reordered — different bytes, same meaning.
private let mouseB: [UInt8] = [
    0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x09, 0x01, 0xA1, 0x00,
    0x15, 0x00, 0x25, 0x01, 0x75, 0x01,          // hoisted
    0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x95, 0x03, 0x81, 0x02,
    0x75, 0x05, 0x95, 0x01, 0x81, 0x03,          // swapped order
    0x05, 0x01, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08,
    0x09, 0x30, 0x09, 0x31, 0x95, 0x02, 0x81, 0x06,
    0xC0, 0xC0,
]

func runDescriptorTests() {
    TestRunner.suite("Descriptor parsing") {

        TestRunner.test("toy mouse decodes to the expected field layout") {
            let parsed = try parseDescriptor(mouseA)

            expectEqual(parsed.usesReportIDs, false, "no Report ID item present")
            let report = try require(parsed.report(id: 0, kind: .input))
            expectEqual(report.byteLength, 3)

            // Three buttons at bits 0..2, five bits of padding, then X and Y.
            expectEqual(report.fields[0].name, "Button 1")
            expectEqual(report.fields[0].bitOffset, 0)
            expectEqual(report.fields[2].bitOffset, 2)
            check(report.fields[3].flags.isConstant, "field 3 is padding")

            let x = try require(report.fields.first { $0.name == "X" })
            expectEqual(x.bitOffset, 8)
            expectEqual(x.bitSize, 8)
            check(x.flags.isRelative, "mouse axes are relative")
            check(x.isSigned, "signed because logicalMin is negative")
            expectEqual(x.logicalMin, -127)
            expectEqual(x.logicalMax, 127)
        }

        // The no-canonical-encoding property: a descriptor is an instruction
        // stream, so unrelated byte sequences can build identical layouts.
        TestRunner.test("different bytes can produce an identical layout") {
            check(mouseA != mouseB, "the two descriptors differ byte-wise")

            let a = try require(parseDescriptor(mouseA).report(id: 0, kind: .input))
            let b = try require(parseDescriptor(mouseB).report(id: 0, kind: .input))

            expectEqual(a.fields.count, b.fields.count)
            for (x, y) in zip(a.fields, b.fields) {
                expectEqual(x.bitOffset, y.bitOffset)
                expectEqual(x.bitSize, y.bitSize)
                expectEqual(x.usagePage, y.usagePage)
                expectEqual(x.usage, y.usage)
                expectEqual(x.logicalMin, y.logicalMin)
                expectEqual(x.logicalMax, y.logicalMax)
            }
        }

        // MARK: Value extraction

        TestRunner.test("signed relative axes sign-extend correctly") {
            let parsed = try parseDescriptor(mouseA)
            let report = try require(parsed.report(id: 0, kind: .input))
            let x = try require(report.fields.first { $0.name == "X" })
            let y = try require(report.fields.first { $0.name == "Y" })

            // buttons=0b001, X=+5, Y=-3 (0xFD)
            let body: [UInt8] = [0x01, 0x05, 0xFD]
            expectEqual(extract(x, from: body), 5)
            expectEqual(extract(y, from: body), -3, "must sign-extend")
            expectEqual(extract(report.fields[0], from: body), 1, "button 1 down")
            expectEqual(extract(report.fields[1], from: body), 0, "button 2 up")
        }

        TestRunner.test("values straddling byte boundaries are reassembled") {
            // A 12-bit field starting at bit 4 of 0xA0 0xBC → 0xBCA
            let field = HIDField(
                reportID: 0, kind: .input, bitOffset: 4, bitSize: 12,
                usagePage: 0x01, usage: 0x30,
                logicalMin: 0, logicalMax: 4095,
                physicalMin: 0, physicalMax: 0, unit: 0, unitExponent: 0,
                flags: MainFlags(raw: 0x02), path: [])
            expectEqual(extract(field, from: [0xA0, 0xBC]), 0xBCA)
        }

        TestRunner.test("a truncated descriptor is rejected") {
            // A 2-byte item with only one byte of payload present.
            expectThrows("truncated descriptor should throw") {
                _ = try parseDescriptor([0x05, 0x01, 0x26, 0xFF])
            }
        }

        // MARK: PTP layout discovery, against the real Voyager descriptor

        TestRunner.test("PTP touch layout is discovered from the ZSA descriptor") {
            let parsed = try parseDescriptor(voyagerDescriptor)
            let layout = try require(discoverTouchLayout(parsed))

            expectEqual(layout.reportID, 1, "touch data is input report 1")
            expectEqual(layout.bodyLength, 15)
            expectEqual(layout.maxContacts, 2, "descriptor declares two finger slots")
            expectEqual(layout.buttons.count, 3)
            check(layout.scanTime != nil, "scan time present")
            expectClose(try require(layout.secondsPerCount), 0.0001, 1e-9, "100 µs per count")

            let size = try require(layout.surfaceSize)
            expectClose(size.x, 55.0, 0.05, "surface width")
            expectClose(size.y, 55.0, 0.05, "surface height")

            let inputMode = try require(parsed.fields(page: 0x0D, usage: 0x52,
                                                     kind: .feature).first)
            expectEqual(inputMode.reportID, 4, "Input Mode is feature report 4")
        }

        TestRunner.test("a synthetic two-finger report decodes to two contacts") {
            let parsed = try parseDescriptor(voyagerDescriptor)
            let layout = try require(discoverTouchLayout(parsed))

            // f1: confident+tip, id 0, (512, 1024)
            // f2: confident+tip, id 1, (1180, 980)
            // scan time 0x1234, contact count 2
            let body: [UInt8] = [
                0x03, 0x00, 0x00, 0x02, 0x00, 0x04,
                0x03, 0x01, 0x9C, 0x04, 0xD4, 0x03,
                0x34, 0x12, 0x02,
            ]
            let frame = layout.decode(body)

            expectEqual(frame.contacts.count, 2)
            expectEqual(frame.declaredCount, 2)
            expectEqual(frame.scanTime, 0x1234)

            expectEqual(frame.contacts[0].hardwareID, 0)
            expectEqual(frame.contacts[0].rawX, 512)
            expectEqual(frame.contacts[0].rawY, 1024)
            expectClose(frame.contacts[0].position.x, 13.75, 0.01, "512/2048 × 55mm")
            expectClose(frame.contacts[0].position.y, 27.5, 0.01)
            check(frame.contacts[0].confident, "confidence bit set")

            expectEqual(frame.contacts[1].hardwareID, 1)
            expectEqual(frame.contacts[1].rawX, 1180)
            expectEqual(frame.contacts[1].rawY, 980)
        }

        TestRunner.test("a cleared tip switch hides a stale slot") {
            let parsed = try parseDescriptor(voyagerDescriptor)
            let layout = try require(discoverTouchLayout(parsed))

            // Same as above but finger 2's tip switch is clear (0x01 = confidence only).
            let body: [UInt8] = [
                0x03, 0x00, 0x00, 0x02, 0x00, 0x04,
                0x01, 0x01, 0x9C, 0x04, 0xD4, 0x03,
                0x34, 0x12, 0x01,
            ]
            let frame = layout.decode(body)
            expectEqual(frame.contacts.count, 1, "stale slot must not become a phantom finger")
            expectEqual(frame.contacts[0].hardwareID, 0)
        }
    }
}
