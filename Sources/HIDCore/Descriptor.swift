import Foundation

// MARK: - Raw items

/// A HID report descriptor is a flat byte stream of "items". Each short item is
/// a one-byte prefix (bTag<<4 | bType<<2 | bSize) followed by 0/1/2/4 data bytes.
/// See Device Class Definition for HID 1.11 §6.2.2.
public enum ItemType: UInt8 {
    case main = 0, global = 1, local = 2, reserved = 3
}

public struct RawItem {
    public let type: ItemType
    public let tag: UInt8
    public let data: UInt32
    public let dataSize: Int

    /// Two's-complement reading of the payload, for items defined as signed.
    public var signed: Int {
        switch dataSize {
        case 1: return Int(Int8(bitPattern: UInt8(truncatingIfNeeded: data)))
        case 2: return Int(Int16(bitPattern: UInt16(truncatingIfNeeded: data)))
        case 4: return Int(Int32(bitPattern: data))
        default: return Int(data)
        }
    }
}

public enum MainTag: UInt8 {
    case input = 0x8, output = 0x9, feature = 0xB
    case collection = 0xA, endCollection = 0xC
}

public enum GlobalTag: UInt8 {
    case usagePage = 0x0, logicalMin = 0x1, logicalMax = 0x2
    case physicalMin = 0x3, physicalMax = 0x4
    case unitExponent = 0x5, unit = 0x6
    case reportSize = 0x7, reportID = 0x8, reportCount = 0x9
    case push = 0xA, pop = 0xB
}

public enum LocalTag: UInt8 {
    case usage = 0x0, usageMin = 0x1, usageMax = 0x2
}

/// Split the byte stream into items. Long items (prefix 0xFE) are skipped —
/// no real device uses them.
public func tokenize(_ bytes: [UInt8]) throws -> [RawItem] {
    var items: [RawItem] = []
    var i = 0
    while i < bytes.count {
        let prefix = bytes[i]
        i += 1
        if prefix == 0xFE {  // long item: [prefix][dataSize][tag][data...]
            guard i + 1 < bytes.count else { throw HIDError.truncatedDescriptor }
            let size = Int(bytes[i])
            i += 2 + size
            continue
        }
        let sizeCode = prefix & 0x03
        let size = sizeCode == 3 ? 4 : Int(sizeCode)
        let type = ItemType(rawValue: (prefix >> 2) & 0x03)!
        let tag = prefix >> 4

        guard i + size <= bytes.count else { throw HIDError.truncatedDescriptor }
        var data: UInt32 = 0
        for b in 0..<size {  // little-endian payload
            data |= UInt32(bytes[i + b]) << (8 * UInt32(b))
        }
        i += size
        items.append(RawItem(type: type, tag: tag, data: data, dataSize: size))
    }
    return items
}

public enum HIDError: Error, CustomStringConvertible {
    case truncatedDescriptor
    case noDescriptor
    case deviceNotFound
    case openFailed(Int32)
    case setReportFailed(Int32)
    case getReportFailed(Int32)

    public var description: String {
        switch self {
        case .truncatedDescriptor: return "report descriptor ended mid-item"
        case .noDescriptor: return "device exposes no ReportDescriptor property"
        case .deviceNotFound: return "no matching HID device found"
        case .openFailed(let r): return String(format: "IOHIDDeviceOpen failed: 0x%08X", r)
        case .setReportFailed(let r): return String(format: "IOHIDDeviceSetReport failed: 0x%08X", r)
        case .getReportFailed(let r): return String(format: "IOHIDDeviceGetReport failed: 0x%08X", r)
        }
    }
}

// MARK: - Parsed model

public enum ReportKind: String {
    case input = "Input", output = "Output", feature = "Feature"
}

public struct MainFlags {
    public let raw: UInt32
    public var isConstant: Bool { raw & 0x01 != 0 }
    public var isVariable: Bool { raw & 0x02 != 0 }
    public var isRelative: Bool { raw & 0x04 != 0 }

    public var summary: String {
        var parts: [String] = [isConstant ? "Const" : "Data",
                               isVariable ? "Var" : "Array",
                               isRelative ? "Rel" : "Abs"]
        if raw & 0x08 != 0 { parts.append("Wrap") }
        if raw & 0x10 != 0 { parts.append("NonLinear") }
        if raw & 0x40 != 0 { parts.append("NullState") }
        return parts.joined(separator: ",")
    }
}

/// One addressable value inside a report, with its exact bit position.
public struct HIDField {
    public let reportID: UInt8
    public let kind: ReportKind
    public let bitOffset: Int
    public let bitSize: Int
    public let usagePage: UInt16
    public let usage: UInt16
    public let logicalMin: Int
    public let logicalMax: Int
    public let physicalMin: Int
    public let physicalMax: Int
    public let unit: UInt32
    public let unitExponent: Int
    public let flags: MainFlags
    public let path: [String]

    public var isSigned: Bool { logicalMin < 0 }
    public var name: String { usageName(page: usagePage, usage: usage) }

    /// Physical extent implied by the unit/exponent globals, if expressible.
    public var physicalDescription: String? {
        guard unit != 0, physicalMax != physicalMin else { return nil }
        let scale = pow(10.0, Double(unitExponent))
        let span = Double(physicalMax - physicalMin) * scale
        // Unit nibble 0 = measurement system, nibble 1 = length exponent.
        let system = unit & 0x0F
        let lengthExp = (unit >> 4) & 0x0F
        let timeExp = (unit >> 12) & 0x0F
        if system == 0x1 && lengthExp == 0x1 {
            return String(format: "%.1f mm", span * 10)  // SI linear → cm
        }
        if system == 0x1 && timeExp == 0x1 {
            return String(format: "%.6g s per count", scale)
        }
        return String(format: "%.4g (unit 0x%04X)", span, unit)
    }
}

public struct HIDReport {
    public let id: UInt8
    public let kind: ReportKind
    public var fields: [HIDField]
    /// Payload length excluding the report-ID prefix byte.
    public var byteLength: Int {
        let bits = fields.map { $0.bitOffset + $0.bitSize }.max() ?? 0
        return (bits + 7) / 8
    }
}

public struct ParsedDescriptor {
    public let reports: [HIDReport]
    public let tree: [String]
    public let usesReportIDs: Bool

    public func report(id: UInt8, kind: ReportKind) -> HIDReport? {
        reports.first { $0.id == id && $0.kind == kind }
    }

    /// All fields matching a usage, across every report of a kind.
    public func fields(page: UInt16, usage: UInt16, kind: ReportKind? = nil) -> [HIDField] {
        reports
            .filter { kind == nil || $0.kind == kind! }
            .flatMap { $0.fields }
            .filter { $0.usagePage == page && $0.usage == usage }
    }
}

// MARK: - Parser

private struct GlobalState {
    var usagePage: UInt16 = 0
    var logicalMin = 0, logicalMax = 0
    var physicalMin = 0, physicalMax = 0
    var unitExponent = 0
    var unit: UInt32 = 0
    var reportSize = 0, reportCount = 0
    var reportID: UInt8 = 0
}

/// Walks the item stream, maintaining the global/local state machine, and emits
/// per-report field layouts with running bit offsets.
public func parseDescriptor(_ bytes: [UInt8]) throws -> ParsedDescriptor {
    let items = try tokenize(bytes)

    var global = GlobalState()
    var globalStack: [GlobalState] = []
    var usages: [UInt32] = []          // local Usage items, in order
    var usageMin: UInt32? = nil
    var usageMax: UInt32? = nil

    var collectionPath: [String] = []
    var tree: [String] = []
    var indent = 0

    // (reportID, kind) → accumulated bit offset
    var cursors: [String: Int] = [:]
    var reports: [String: HIDReport] = [:]
    var order: [String] = []
    var sawReportID = false

    func line(_ s: String) { tree.append(String(repeating: "  ", count: indent) + s) }

    /// A 32-bit Usage item carries the page in its upper 16 bits.
    func split(_ u: UInt32, size: Int) -> (UInt16, UInt16) {
        if size == 4 { return (UInt16(u >> 16), UInt16(truncatingIfNeeded: u)) }
        return (global.usagePage, UInt16(truncatingIfNeeded: u))
    }

    func emitMain(kind: ReportKind, flags: UInt32) {
        let key = "\(global.reportID)-\(kind.rawValue)"
        if reports[key] == nil {
            reports[key] = HIDReport(id: global.reportID, kind: kind, fields: [])
            order.append(key)
        }
        var offset = cursors[key] ?? 0
        let f = MainFlags(raw: flags)

        // Build the usage list this main item consumes.
        var resolved: [(UInt16, UInt16)] = usages.map { split($0, size: 4) }
        // Heuristic: usages recorded with 1/2-byte payloads inherit the page.
        resolved = usages.map { u in
            u > 0xFFFF ? (UInt16(u >> 16), UInt16(truncatingIfNeeded: u))
                       : (global.usagePage, UInt16(truncatingIfNeeded: u))
        }

        if f.isVariable {
            for i in 0..<global.reportCount {
                var page = global.usagePage
                var usage: UInt16 = 0
                if i < resolved.count {
                    (page, usage) = resolved[i]
                } else if let lo = usageMin, let hi = usageMax {
                    let v = lo + UInt32(i)
                    if v <= hi { usage = UInt16(truncatingIfNeeded: v) }
                } else if let last = resolved.last {
                    (page, usage) = last  // usage repeats for the remainder
                }
                reports[key]!.fields.append(HIDField(
                    reportID: global.reportID, kind: kind,
                    bitOffset: offset, bitSize: global.reportSize,
                    usagePage: page, usage: usage,
                    logicalMin: global.logicalMin, logicalMax: global.logicalMax,
                    physicalMin: global.physicalMin, physicalMax: global.physicalMax,
                    unit: global.unit, unitExponent: global.unitExponent,
                    flags: f, path: collectionPath))
                offset += global.reportSize
            }
        } else {
            // Array item: reportCount slots each holding an index into usageMin...usageMax.
            for _ in 0..<global.reportCount {
                reports[key]!.fields.append(HIDField(
                    reportID: global.reportID, kind: kind,
                    bitOffset: offset, bitSize: global.reportSize,
                    usagePage: global.usagePage,
                    usage: UInt16(truncatingIfNeeded: usageMin ?? 0),
                    logicalMin: global.logicalMin, logicalMax: global.logicalMax,
                    physicalMin: global.physicalMin, physicalMax: global.physicalMax,
                    unit: global.unit, unitExponent: global.unitExponent,
                    flags: f, path: collectionPath))
                offset += global.reportSize
            }
        }
        cursors[key] = offset

        let names: String
        if f.isConstant {
            names = "padding"
        } else if let lo = usageMin, let hi = usageMax, usages.isEmpty {
            names = "\(usageName(page: global.usagePage, usage: UInt16(truncatingIfNeeded: lo)))…\(usageName(page: global.usagePage, usage: UInt16(truncatingIfNeeded: hi)))"
        } else {
            names = resolved.map { usageName(page: $0.0, usage: $0.1) }.joined(separator: ", ")
        }
        line("\(kind.rawValue) (\(f.summary))  \(global.reportCount)×\(global.reportSize) bits  [\(names)]")
    }

    for item in items {
        switch item.type {
        case .main:
            guard let tag = MainTag(rawValue: item.tag) else { break }
            switch tag {
            case .collection:
                let kindName: String
                switch item.data {
                case 0x00: kindName = "Physical"
                case 0x01: kindName = "Application"
                case 0x02: kindName = "Logical"
                default: kindName = String(format: "0x%02X", item.data)
                }
                let label = usages.first.map {
                    let (p, u) = split($0, size: $0 > 0xFFFF ? 4 : 1)
                    return usageName(page: p, usage: u)
                } ?? "?"
                line("Collection (\(kindName)) — \(label)")
                collectionPath.append(label)
                indent += 1
            case .endCollection:
                indent = max(0, indent - 1)
                if !collectionPath.isEmpty { collectionPath.removeLast() }
                line("End Collection")
            case .input: emitMain(kind: .input, flags: item.data)
            case .output: emitMain(kind: .output, flags: item.data)
            case .feature: emitMain(kind: .feature, flags: item.data)
            }
            // Local state is cleared after every main item.
            usages.removeAll(); usageMin = nil; usageMax = nil

        case .global:
            guard let tag = GlobalTag(rawValue: item.tag) else { break }
            switch tag {
            case .usagePage: global.usagePage = UInt16(truncatingIfNeeded: item.data)
            case .logicalMin: global.logicalMin = item.signed
            case .logicalMax:
                // Logical Maximum is signed, but a 1-byte 0xFF almost always means
                // 255 in practice; only trust the sign when a negative minimum exists.
                global.logicalMax = global.logicalMin < 0 ? item.signed : Int(item.data)
            case .physicalMin: global.physicalMin = item.signed
            case .physicalMax: global.physicalMax = Int(item.data)
            case .unitExponent:
                // Nibble-encoded two's complement: 0x0E → -2.
                let v = Int(item.data & 0x0F)
                global.unitExponent = v >= 8 ? v - 16 : v
            case .unit: global.unit = item.data
            case .reportSize: global.reportSize = Int(item.data)
            case .reportCount: global.reportCount = Int(item.data)
            case .reportID:
                global.reportID = UInt8(truncatingIfNeeded: item.data)
                sawReportID = true
            case .push: globalStack.append(global)
            case .pop: if let g = globalStack.popLast() { global = g }
            }

        case .local:
            guard let tag = LocalTag(rawValue: item.tag) else { break }
            switch tag {
            case .usage:
                // Preserve the page for 4-byte usages by packing it in.
                usages.append(item.dataSize == 4
                    ? item.data
                    : (UInt32(global.usagePage) << 16) | item.data)
            case .usageMin: usageMin = item.data
            case .usageMax: usageMax = item.data
            }

        case .reserved:
            break
        }
    }

    return ParsedDescriptor(
        reports: order.compactMap { reports[$0] },
        tree: tree,
        usesReportIDs: sawReportID)
}

// MARK: - Value extraction

/// Pull a field out of a report body (report-ID byte already stripped).
/// HID packs values little-endian, LSB-first within each byte.
public func extract(_ field: HIDField, from body: [UInt8]) -> Int {
    var raw: UInt64 = 0
    for i in 0..<field.bitSize {
        let bit = field.bitOffset + i
        let byteIndex = bit >> 3
        guard byteIndex < body.count else { break }
        let value = (body[byteIndex] >> UInt8(bit & 7)) & 1
        raw |= UInt64(value) << UInt64(i)
    }
    if field.isSigned && field.bitSize < 64 {
        let signBit: UInt64 = 1 << UInt64(field.bitSize - 1)
        if raw & signBit != 0 {
            return Int(Int64(bitPattern: raw | ~((1 << UInt64(field.bitSize)) - 1)))
        }
    }
    return Int(raw)
}
