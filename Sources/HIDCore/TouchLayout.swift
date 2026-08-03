import Foundation

/// A point on the trackpad surface, in millimetres from the origin corner.
/// Physical units keep gesture thresholds device-independent.
public struct Point: Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }

    public static func - (a: Point, b: Point) -> Point { Point(x: a.x - b.x, y: a.y - b.y) }
    public static func + (a: Point, b: Point) -> Point { Point(x: a.x + b.x, y: a.y + b.y) }
    public var magnitude: Double { (x * x + y * y).squareRoot() }
}

/// One finger as reported in a single frame. Only contacts with Tip Switch set
/// ever become a `Contact` — a cleared tip means the slot's other fields are stale.
public struct Contact {
    public let hardwareID: Int
    public let rawX: Int
    public let rawY: Int
    public let position: Point
    public let confident: Bool

    public init(hardwareID: Int, rawX: Int, rawY: Int, position: Point, confident: Bool = true) {
        self.hardwareID = hardwareID
        self.rawX = rawX
        self.rawY = rawY
        self.position = position
        self.confident = confident
    }
}

/// One decoded input report: a complete snapshot of the pad at an instant.
public struct Frame {
    public let contacts: [Contact]
    public let declaredCount: Int?
    public let buttons: [Bool]
    /// Raw Scan Time counter, if the device reports one.
    public let scanTime: Int?

    public init(contacts: [Contact], declaredCount: Int? = nil,
                buttons: [Bool] = [], scanTime: Int? = nil) {
        self.contacts = contacts
        self.declaredCount = declaredCount
        self.buttons = buttons
        self.scanTime = scanTime
    }

    public var buttonDown: Bool { buttons.contains(true) }
}

/// The fields making up one finger slot within an input report.
public struct ContactLayout {
    public var confidence: HIDField?
    public var tipSwitch: HIDField?
    public var contactID: HIDField?
    public var x: HIDField?
    public var y: HIDField?

    public var isComplete: Bool { tipSwitch != nil && x != nil && y != nil }
}

/// Everything needed to turn a raw touch report into a `Frame`, discovered from
/// the descriptor rather than hardcoded per device.
public struct TouchLayout {
    public let reportID: UInt8
    public let bodyLength: Int
    public var contacts: [ContactLayout] = []
    public var contactCount: HIDField?
    public var scanTime: HIDField?
    public var buttons: [HIDField] = []

    /// Seconds represented by one Scan Time count, from the descriptor's unit
    /// exponent. 100 µs on a conforming PTP device.
    public var secondsPerCount: Double? {
        guard let scanTime, scanTime.unit != 0 else { return nil }
        return pow(10.0, Double(scanTime.unitExponent))
    }

    /// The Scan Time counter wraps at its logical maximum.
    public var scanTimeModulus: Int? {
        scanTime.map { $0.logicalMax + 1 }
    }

    public var maxContacts: Int { contacts.count }

    /// Correction for a descriptor that misreports the sensor's physical size.
    ///
    /// The physical range in a report descriptor is a claim, not a measurement,
    /// and PTP descriptors are widely copied between projects — so the value
    /// can be inherited boilerplate rather than the pad in front of you. When
    /// it is wrong every millimetre downstream is wrong by the same factor:
    /// speeds, gains, tap travel limits, the lot. They stay self-consistent,
    /// which is why tuning by feel still converges — on numbers whose units
    /// are a lie.
    ///
    /// 1.0 trusts the descriptor. See `declaredSurfaceSize` for what it said.
    public var positionScale: Double = 1.0

    /// Surface extent in millimetres after `positionScale`, i.e. what the rest
    /// of the pipeline will actually measure against.
    public var surfaceSize: Point? {
        declaredSurfaceSize.map { Point(x: $0.x * positionScale, y: $0.y * positionScale) }
    }

    /// Surface extent exactly as the descriptor claims it.
    public var declaredSurfaceSize: Point? {
        guard let x = contacts.first?.x, let y = contacts.first?.y,
              let w = millimetres(x, x.logicalMax), let h = millimetres(y, y.logicalMax)
        else { return nil }
        return Point(x: w, y: h)
    }

    /// Decode one report body (report-ID byte already stripped).
    public func decode(_ body: [UInt8]) -> Frame {
        var found: [Contact] = []
        for slot in contacts {
            guard let tip = slot.tipSwitch, extract(tip, from: body) != 0 else { continue }
            let rawX = slot.x.map { extract($0, from: body) } ?? 0
            let rawY = slot.y.map { extract($0, from: body) } ?? 0
            let position = Point(
                x: (slot.x.flatMap { millimetres($0, rawX) } ?? Double(rawX)) * positionScale,
                y: (slot.y.flatMap { millimetres($0, rawY) } ?? Double(rawY)) * positionScale)
            found.append(Contact(
                hardwareID: slot.contactID.map { extract($0, from: body) } ?? found.count,
                rawX: rawX, rawY: rawY,
                position: position,
                confident: slot.confidence.map { extract($0, from: body) != 0 } ?? true))
        }
        return Frame(
            contacts: found,
            declaredCount: contactCount.map { extract($0, from: body) },
            buttons: buttons.map { extract($0, from: body) != 0 },
            scanTime: scanTime.map { extract($0, from: body) })
    }
}

/// Convert a logical axis value to millimetres using the descriptor's own
/// physical range and unit exponent, so nothing is hardcoded per device.
public func millimetres(_ field: HIDField, _ value: Int) -> Double? {
    guard field.logicalMax > field.logicalMin, field.physicalMax != field.physicalMin
    else { return nil }
    let fraction = Double(value - field.logicalMin)
        / Double(field.logicalMax - field.logicalMin)
    let span = Double(field.physicalMax - field.physicalMin) * pow(10.0, Double(field.unitExponent))
    return fraction * span * 10.0  // SI linear length is centimetres
}

/// Walk an input report's fields in descriptor order, starting a new finger slot
/// whenever we meet a usage the current slot has already filled.
public func discoverTouchLayout(_ parsed: ParsedDescriptor) -> TouchLayout? {
    let dig = UInt16(ZSA.digitizerUsagePage)
    guard let anchor = parsed.fields(page: dig,
                                     usage: DigitizerUsage.tipSwitch.rawValue,
                                     kind: .input).first,
          let report = parsed.report(id: anchor.reportID, kind: .input)
    else { return nil }

    var layout = TouchLayout(reportID: report.id, bodyLength: report.byteLength)
    var current = ContactLayout()

    func flush() {
        if current.tipSwitch != nil || current.x != nil { layout.contacts.append(current) }
        current = ContactLayout()
    }

    for f in report.fields where !f.flags.isConstant {
        switch (f.usagePage, f.usage) {
        case (dig, DigitizerUsage.confidence.rawValue):
            if current.confidence != nil { flush() }
            current.confidence = f
        case (dig, DigitizerUsage.tipSwitch.rawValue):
            if current.tipSwitch != nil { flush() }
            current.tipSwitch = f
        case (dig, DigitizerUsage.contactIdentifier.rawValue):
            if current.contactID != nil { flush() }
            current.contactID = f
        case (0x01, 0x30) where !f.flags.isRelative:
            if current.x != nil { flush() }
            current.x = f
        case (0x01, 0x31) where !f.flags.isRelative:
            if current.y != nil { flush() }
            current.y = f
            flush()  // Y closes a finger collection in every PTP layout
        case (dig, DigitizerUsage.contactCount.rawValue):
            flush(); layout.contactCount = f
        case (dig, DigitizerUsage.scanTime.rawValue):
            flush(); layout.scanTime = f
        case (0x09, _):
            flush(); layout.buttons.append(f)
        default:
            break
        }
    }
    flush()
    layout.contacts = layout.contacts.filter(\.isComplete)
    return layout.contacts.isEmpty ? nil : layout
}
