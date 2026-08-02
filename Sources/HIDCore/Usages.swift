import Foundation

/// Usage pages we care about for a Precision Touchpad.
public enum UsagePage: UInt16 {
    case genericDesktop = 0x01
    case simulation = 0x02
    case keyboard = 0x07
    case led = 0x08
    case button = 0x09
    case consumer = 0x0C
    case digitizer = 0x0D

    public var name: String {
        switch self {
        case .genericDesktop: return "Generic Desktop"
        case .simulation: return "Simulation"
        case .keyboard: return "Keyboard"
        case .led: return "LED"
        case .button: return "Button"
        case .consumer: return "Consumer"
        case .digitizer: return "Digitizer"
        }
    }
}

/// Digitizer usages relevant to PTP. Values from HID Usage Tables §16.
public enum DigitizerUsage: UInt16 {
    case digitizer = 0x01
    case pen = 0x02
    case touchScreen = 0x04
    case touchPad = 0x05
    case finger = 0x22
    case tipSwitch = 0x42
    case confidence = 0x47
    case width = 0x48
    case height = 0x49
    case contactIdentifier = 0x51
    case inputMode = 0x52
    case deviceIndex = 0x53
    case contactCount = 0x54
    case contactCountMaximum = 0x55
    case scanTime = 0x56
    case surfaceSwitch = 0x57
    case buttonSwitch = 0x58
    case padType = 0x59
    case deviceConfiguration = 0x0E
}

/// Human-readable name for a (page, usage) pair. Falls back to hex.
public func usageName(page: UInt16, usage: UInt16) -> String {
    switch page {
    case UsagePage.genericDesktop.rawValue:
        switch usage {
        case 0x01: return "Pointer"
        case 0x02: return "Mouse"
        case 0x06: return "Keyboard"
        case 0x30: return "X"
        case 0x31: return "Y"
        case 0x38: return "Wheel"
        case 0x80: return "System Control"
        default: return String(format: "Usage 0x%02X", usage)
        }
    case UsagePage.button.rawValue:
        return usage == 0 ? "No Button" : "Button \(usage)"
    case UsagePage.digitizer.rawValue:
        switch DigitizerUsage(rawValue: usage) {
        case .digitizer: return "Digitizer"
        case .pen: return "Pen"
        case .touchScreen: return "Touch Screen"
        case .touchPad: return "Touch Pad"
        case .finger: return "Finger"
        case .tipSwitch: return "Tip Switch"
        case .confidence: return "Confidence"
        case .width: return "Width"
        case .height: return "Height"
        case .contactIdentifier: return "Contact Identifier"
        case .inputMode: return "Input Mode"
        case .deviceIndex: return "Device Index"
        case .contactCount: return "Contact Count"
        case .contactCountMaximum: return "Contact Count Maximum"
        case .scanTime: return "Scan Time"
        case .surfaceSwitch: return "Surface Switch"
        case .buttonSwitch: return "Button Switch"
        case .padType: return "Pad Type"
        case .deviceConfiguration: return "Device Configuration"
        default: return String(format: "Usage 0x%02X", usage)
        }
    case 0xFF00...0xFFFF:
        return String(format: "Vendor 0x%02X", usage)
    default:
        return String(format: "Usage 0x%02X", usage)
    }
}

public func usagePageName(_ page: UInt16) -> String {
    if let p = UsagePage(rawValue: page) { return p.name }
    if page >= 0xFF00 { return String(format: "Vendor-defined 0x%04X", page) }
    return String(format: "Page 0x%04X", page)
}
