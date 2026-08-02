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

    public func setFeature(reportID: UInt8, bytes: [UInt8]) throws {
        var payload = bytes
        let result = IOHIDDeviceSetReport(
            ref, kIOHIDReportTypeFeature, CFIndex(reportID), &payload, payload.count)
        guard result == kIOReturnSuccess else { throw HIDError.setReportFailed(result) }
    }

    public func getFeature(reportID: UInt8, length: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: length)
        var size = CFIndex(length)
        let result = IOHIDDeviceGetReport(
            ref, kIOHIDReportTypeFeature, CFIndex(reportID), &buffer, &size)
        guard result == kIOReturnSuccess else { throw HIDError.getReportFailed(result) }
        return Array(buffer.prefix(max(0, Int(size))))
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

    public func schedule(on runLoop: CFRunLoop = CFRunLoopGetCurrent()) {
        IOHIDDeviceScheduleWithRunLoop(ref, runLoop, CFRunLoopMode.defaultMode.rawValue)
    }

    public func unschedule(from runLoop: CFRunLoop = CFRunLoopGetCurrent()) {
        IOHIDDeviceUnscheduleFromRunLoop(ref, runLoop, CFRunLoopMode.defaultMode.rawValue)
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
    /// Enumerate HID devices, optionally filtered by vendor/usage.
    public static func devices(vendorID: Int? = nil,
                               usagePage: Int? = nil,
                               usage: Int? = nil) -> [HIDDevice] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault,
                                         IOOptionBits(kIOHIDOptionsTypeNone))
        var criteria: [String: Any] = [:]
        if let vendorID { criteria[kIOHIDVendorIDKey] = vendorID }
        if let usagePage { criteria[kIOHIDPrimaryUsagePageKey] = usagePage }
        if let usage { criteria[kIOHIDPrimaryUsageKey] = usage }

        if criteria.isEmpty {
            IOHIDManagerSetDeviceMatching(manager, nil)
        } else {
            IOHIDManagerSetDeviceMatching(manager, criteria as CFDictionary)
        }
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return set.map(HIDDevice.init).sorted { $0.info.usagePage < $1.info.usagePage }
    }
}

public func hexDump(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}
