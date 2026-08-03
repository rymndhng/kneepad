import Foundation

public enum SessionError: Error, CustomStringConvertible {
    case noDigitizer
    case noInputMode
    case noTouchLayout
    case modeRejected

    public var description: String {
        switch self {
        case .noDigitizer:
            return "no ZSA digitizer interface found — is the board plugged in?"
        case .noInputMode:
            return "descriptor has no Input Mode feature; this hardware can't be switched"
        case .noTouchLayout:
            return "no usable finger collections in any input report"
        case .modeRejected:
            return "device would not accept the multitouch Input Mode write"
        }
    }
}

/// Owns the full lifecycle of a multitouch session: find the digitizer, parse
/// its descriptor, flip Input Mode, decode frames, and restore mouse mode.
///
/// Restoring matters — the device stops sending mouse reports in multitouch
/// mode, so leaving it switched means leaving the user without a cursor.
public final class TouchSession {
    public let device: HIDDevice
    public let parsed: ParsedDescriptor
    public var layout: TouchLayout
    public let inputModeReportID: UInt8
    public let inputModeBodyLength: Int

    /// Expected body length per input report ID, for framing detection.
    private let inputBodyLengths: [UInt8: Int]
    private var framing: ReportFraming?
    private var restored = false

    /// Called for each decoded touch frame, with the raw body alongside.
    public var onFrame: ((Frame, [UInt8]) -> Void)?
    /// Called for reports that aren't the touch report — normally a sign the
    /// device is still in mouse mode.
    public var onForeignReport: ((UInt8, [UInt8]) -> Void)?
    /// Called once, when framing is first determined.
    public var onFraming: ((ReportFraming, UInt8, Int, Int) -> Void)?

    public init(device: HIDDevice, parsed: ParsedDescriptor, layout: TouchLayout,
                inputModeReportID: UInt8, inputModeBodyLength: Int) {
        self.device = device
        self.parsed = parsed
        self.layout = layout
        self.inputModeReportID = inputModeReportID
        self.inputModeBodyLength = inputModeBodyLength
        self.inputBodyLengths = Dictionary(
            parsed.reports.filter { $0.kind == .input }.map { ($0.id, $0.byteLength) },
            uniquingKeysWith: { first, _ in first })
    }

    public static func discover() throws -> TouchSession {
        guard let device = HIDDiscovery.devices(vendorID: ZSA.vendorID,
                                                usagePage: ZSA.digitizerUsagePage,
                                                usage: ZSA.digitizerUsage).first
        else { throw SessionError.noDigitizer }

        guard let bytes = device.reportDescriptor else { throw HIDError.noDescriptor }
        let parsed = try parseDescriptor(bytes)

        guard let inputMode = parsed.fields(page: UInt16(ZSA.digitizerUsagePage),
                                            usage: DigitizerUsage.inputMode.rawValue,
                                            kind: .feature).first
        else { throw SessionError.noInputMode }

        guard let layout = discoverTouchLayout(parsed) else { throw SessionError.noTouchLayout }

        let bodyLength = parsed.report(id: inputMode.reportID, kind: .feature)?.byteLength ?? 1
        return TouchSession(device: device, parsed: parsed, layout: layout,
                            inputModeReportID: inputMode.reportID,
                            inputModeBodyLength: max(1, bodyLength))
    }

    // MARK: Mode switching

    /// Write Input Mode and confirm by read-back.
    ///
    /// macOS carries the report-ID byte in feature-report buffers in both
    /// directions, but firmware varies, so try with the prefix and fall back.
    /// Returns the style that worked, for diagnostics.
    @discardableResult
    public func setInputMode(_ mode: UInt8,
                             log: ((String) -> Void)? = nil) -> Bool {
        for includeID in [true, false] {
            let style = includeID ? "with ID prefix" : "without ID prefix"
            do {
                try device.setFeature(reportID: inputModeReportID,
                                      bytes: [mode], includeReportID: includeID)
            } catch {
                log?("SET_FEATURE \(style) failed: \(error)")
                continue
            }
            guard let echo = try? device.getFeature(reportID: inputModeReportID,
                                                    bodyLength: inputModeBodyLength) else {
                log?("wrote \(mode) \(style); device declined read-back — assuming it took")
                return true
            }
            let value = echo.body.first
            let ok = value == mode
            log?("\(style): raw \(hexDump(echo.raw)) → body \(hexDump(echo.body))"
                + (ok ? "  ✓ accepted" : "  ✗ reads back as \(value.map(String.init) ?? "?")"))
            if ok { return true }
        }
        return false
    }

    public func open(seize: Bool = false) throws {
        try device.open(seize: seize)
    }

    public func enableMultitouch(log: ((String) -> Void)? = nil) throws {
        guard setInputMode(ZSA.inputModeMultitouch, log: log) else {
            throw SessionError.modeRejected
        }
    }

    /// Idempotent — safe to call from a signal handler and again from cleanup.
    public func restoreMouseMode(log: ((String) -> Void)? = nil) {
        guard !restored else { return }
        restored = true
        setInputMode(ZSA.inputModeMouse, log: log)
    }

    // MARK: Streaming

    public func start() {
        let bufferSize = max(64, (inputBodyLengths.values.max() ?? layout.bodyLength) + 1)
        device.onInputReport(maxLength: bufferSize) { [weak self] reportID, buffer in
            guard let self else { return }

            if self.framing == nil, let expected = self.inputBodyLengths[reportID] {
                let detected = ReportFraming.detect(bufferLength: buffer.count,
                                                    reportID: reportID,
                                                    firstByte: buffer.first,
                                                    expectedBodyLength: expected)
                self.framing = detected
                self.onFraming?(detected, reportID, buffer.count, expected)
            }
            guard reportID == self.layout.reportID else {
                self.onForeignReport?(reportID, buffer)
                return
            }
            let body = (self.framing ?? .stripped).body(buffer)
            self.onFrame?(self.layout.decode(body), body)
        }
        device.schedule()
    }

    public func stop() {
        device.unschedule()
        device.close()
    }
}
