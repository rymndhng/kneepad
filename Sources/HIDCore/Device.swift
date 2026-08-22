import Foundation
import IOKit
import IOKit.hid

/// Known constants for the ZSA trackpad. Nothing downstream should *depend* on
/// these — report IDs are discovered from the descriptor at runtime — but they
/// make matching and diagnostics concrete.
public enum ZSA {
    public static let vendorID = 0x3297
    public static let digitizerUsagePage = 0x0D
    public static let digitizerUsage = 0x05

    /// Windows Precision Touchpad Input Mode values (Microsoft PTP spec).
    public static let inputModeMouse: UInt8 = 0
    public static let inputModeMultitouch: UInt8 = 3

    /// Measured width of the touch surface, in millimetres.
    ///
    /// The report descriptor claims 55 mm — Logical Max 2048, Physical Max 550,
    /// Unit Exponent 0x0E (−2), Unit 0x11 (SI linear, cm). The sensor measures
    /// 40 mm. PTP descriptors are copied wholesale between projects and the
    /// physical range is the field people forget to update, so this is very
    /// likely inherited boilerplate rather than a measurement.
    ///
    /// It matters because nothing downstream can detect the error: every
    /// millimetre is inflated by the same 1.375×, so the pipeline stays
    /// self-consistent and tuning by feel still converges — on numbers whose
    /// units are wrong. Correcting it here means every threshold in the project
    /// is denominated in real millimetres.
    ///
    /// The pad is square; X and Y declare identical ranges.
    public static let measuredSurfaceWidthMM = 40.0
}

public struct DeviceInfo {
    public let vendorID: Int
    public let productID: Int
    public let product: String
    public let usagePage: Int
    public let usage: Int
    public let transport: String

    public var summary: String {
        String(format: "%@ (VID 0x%04X PID 0x%04X) usagePage %d usage %d [%@]",
               product, vendorID, productID, usagePage, usage, transport)
    }
}

public final class HIDDevice {
    public let ref: IOHIDDevice
    public let info: DeviceInfo
    private var opened = false
    private var inputBuffer: UnsafeMutablePointer<UInt8>?
    private var inputBufferLength = 0
    private var callbackBox: AnyObject?

    public init(_ device: IOHIDDevice) {
        self.ref = device
        func int(_ key: String) -> Int {
            (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0
        }
        func str(_ key: String) -> String {
            (IOHIDDeviceGetProperty(device, key as CFString) as? String) ?? "?"
        }
        self.info = DeviceInfo(
            vendorID: int(kIOHIDVendorIDKey),
            productID: int(kIOHIDProductIDKey),
            product: str(kIOHIDProductKey),
            usagePage: int(kIOHIDPrimaryUsagePageKey),
            usage: int(kIOHIDPrimaryUsageKey),
            transport: str(kIOHIDTransportKey))
    }

    /// The raw report descriptor, as published in the IORegistry.
    public var reportDescriptor: [UInt8]? {
        guard let data = IOHIDDeviceGetProperty(ref, "ReportDescriptor" as CFString) as? Data
        else { return nil }
        return [UInt8](data)
    }

    /// `seize` asks IOKit to stop delivering this device's events to everyone
    /// else. Only needed if macOS starts competing for the reports.
    public func open(seize: Bool = false) throws {
        let options = seize ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
                            : IOOptionBits(kIOHIDOptionsTypeNone)
        let result = IOHIDDeviceOpen(ref, options)
        guard result == kIOReturnSuccess else { throw HIDError.openFailed(result) }
        opened = true
    }

    public func close() {
        guard opened else { return }
        IOHIDDeviceClose(ref, IOOptionBits(kIOHIDOptionsTypeNone))
        opened = false
    }

    // MARK: Feature reports

    /// macOS is inconsistent about whether feature-report buffers carry the
    /// report-ID byte. Empirically IOKit *returns* it on GET, and hidapi's
    /// darwin backend also *sends* it on SET — but firmware varies, so callers
    /// can choose and verify rather than assume.
    public func setFeature(reportID: UInt8, bytes: [UInt8],
                           includeReportID: Bool = true) throws {
        var payload = (includeReportID && reportID != 0) ? [reportID] + bytes : bytes
        let result = IOHIDDeviceSetReport(
            ref, kIOHIDReportTypeFeature, CFIndex(reportID), &payload, payload.count)
        guard result == kIOReturnSuccess else { throw HIDError.setReportFailed(result) }
    }

    /// Returns the report body with any leading report-ID byte stripped, plus
    /// the untouched buffer for diagnostics.
    public func getFeature(reportID: UInt8, bodyLength: Int) throws -> (body: [UInt8], raw: [UInt8]) {
        // Ask for one extra byte so a returned report ID cannot truncate the body.
        var buffer = [UInt8](repeating: 0, count: bodyLength + 1)
        var size = CFIndex(buffer.count)
        let result = IOHIDDeviceGetReport(
            ref, kIOHIDReportTypeFeature, CFIndex(reportID), &buffer, &size)
        guard result == kIOReturnSuccess else { throw HIDError.getReportFailed(result) }

        let raw = Array(buffer.prefix(max(0, Int(size))))
        if reportID != 0, raw.count == bodyLength + 1, raw.first == reportID {
            return (Array(raw.dropFirst()), raw)
        }
        return (Array(raw.prefix(bodyLength)), raw)
    }

    // MARK: Input reports

    private final class CallbackBox {
        let handler: (UInt8, [UInt8]) -> Void
        init(_ handler: @escaping (UInt8, [UInt8]) -> Void) { self.handler = handler }
    }

    /// Registers for input reports. The handler receives the report ID and the
    /// raw buffer exactly as IOKit delivered it — callers decide whether byte 0
    /// is a report-ID prefix (see `ReportFraming`).
    public func onInputReport(maxLength: Int, _ handler: @escaping (UInt8, [UInt8]) -> Void) {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: maxLength)
        buffer.initialize(repeating: 0, count: maxLength)
        inputBuffer = buffer
        inputBufferLength = maxLength

        let box = CallbackBox(handler)
        callbackBox = box
        let context = Unmanaged.passUnretained(box).toOpaque()

        IOHIDDeviceRegisterInputReportCallback(
            ref, buffer, maxLength,
            { context, _, _, _, reportID, report, length in
                guard let context else { return }
                let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
                let bytes = [UInt8](UnsafeBufferPointer(start: report, count: max(0, length)))
                box.handler(UInt8(truncatingIfNeeded: reportID), bytes)
            },
            context)
    }

    /// Common modes, not the default mode.
    ///
    /// This matters as soon as the driver runs inside an app: AppKit switches
    /// the run loop into event-tracking mode for the whole of a menu or a
    /// slider drag, and a source registered only in the default mode stops
    /// firing for that entire time — the trackpad goes dead while you drag the
    /// slider that is tuning it. Common modes covers both.
    public func schedule(on runLoop: CFRunLoop = CFRunLoopGetCurrent(),
                         mode: CFRunLoopMode = .commonModes) {
        IOHIDDeviceScheduleWithRunLoop(ref, runLoop, mode.rawValue)
    }

    public func unschedule(from runLoop: CFRunLoop = CFRunLoopGetCurrent(),
                           mode: CFRunLoopMode = .commonModes) {
        IOHIDDeviceUnscheduleFromRunLoop(ref, runLoop, mode.rawValue)
    }

    deinit {
        inputBuffer?.deallocate()
    }
}

/// IOKit is inconsistent across transports about whether the input-report buffer
/// includes the leading report-ID byte. Rather than guess, we compare the buffer
/// against the length the descriptor predicts and decide once, loudly.
public enum ReportFraming {
    case includesReportID
    case stripped

    public static func detect(bufferLength: Int, reportID: UInt8,
                              firstByte: UInt8?, expectedBodyLength: Int) -> ReportFraming {
        if bufferLength == expectedBodyLength + 1 && firstByte == reportID {
            return .includesReportID
        }
        return .stripped
    }

    public func body(_ buffer: [UInt8]) -> [UInt8] {
        switch self {
        case .includesReportID: return Array(buffer.dropFirst())
        case .stripped: return buffer
        }
    }
}

public enum HIDDiscovery {
    /// One manager for the life of the process, rather than one per call.
    ///
    /// This used to create and open a manager per enumeration and never close
    /// it, which was harmless while enumeration happened once at startup. The
    /// driver's watchdog rediscovers every couple of seconds for as long as the
    /// pad is unplugged, so that would be a manager leaked per probe — tens of
    /// thousands over a night with the board unplugged. Matching can be re-set
    /// on an open manager, so reusing it costs nothing.
    private static let manager: IOHIDManager = {
        let m = IOHIDManagerCreate(kCFAllocatorDefault,
                                   IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        return m
    }()

    /// Enumerate HID devices, optionally filtered by vendor/usage.
    public static func devices(vendorID: Int? = nil,
                               usagePage: Int? = nil,
                               usage: Int? = nil) -> [HIDDevice] {
        let manager = HIDDiscovery.manager
        var criteria: [String: Any] = [:]
        if let vendorID { criteria[kIOHIDVendorIDKey] = vendorID }
        if let usagePage { criteria[kIOHIDPrimaryUsagePageKey] = usagePage }
        if let usage { criteria[kIOHIDPrimaryUsageKey] = usage }

        if criteria.isEmpty {
            IOHIDManagerSetDeviceMatching(manager, nil)
        } else {
            IOHIDManagerSetDeviceMatching(manager, criteria as CFDictionary)
        }

        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return set.map(HIDDevice.init).sorted { $0.info.usagePage < $1.info.usagePage }
    }
}

public func hexDump(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}
