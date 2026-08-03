import Foundation
import HIDCore

/// The tunable surface of the driver, in one serialisable place.
///
/// Exists so `touchd` and the `tuner` app can share one description of what is
/// adjustable. Everything here has been tuned by hand at least once, and the
/// defaults are whatever that landed on — see `plan/FEEL-DEBUGGING.md`.
///
/// Deliberately *not* everything: values that are properties of the hardware
/// rather than of taste (report rate, scan time units) are not here, and
/// neither is anything a user cannot judge by feel.
public struct Tuning: Codable, Equatable {

    // Pointer
    public var pointerGain = 16.5
    public var accelEnabled = true
    public var accelMin = 0.6
    public var accelMax = 3.2
    public var accelCurve = 1.1
    public var accelReference = 124.0

    // Stopping
    public var stopGateEnabled = true
    public var armSpeed = 87.0
    public var stopSpeed = 44.0

    // Scroll
    public var scrollGain = 44.0
    public var scrollDecay = 0.27
    public var naturalScroll = true
    public var momentumEnabled = true

    // Taps
    public var tapEnabled = true
    public var rightTapEnabled = true
    public var tapTime = 0.4
    public var tapTravel = 1.45
    public var twoTapTime = 0.6
    public var twoTapTravel = 2.9
    public var doubleTapTime = 0.4
    public var doubleTapDistance = 5.8

    /// True pad width in mm, if the descriptor's claim is wrong. Nil trusts it.
    public var surfaceWidth: Double?

    public init() {}

    // MARK: Storage

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("teach-touch/tuning.json")
    }

    public static func load(from url: URL = defaultURL) -> Tuning? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Tuning.self, from: data)
    }

    /// Writes atomically, so a reader watching the file never sees half a file.
    public func save(to url: URL = Tuning.defaultURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    // MARK: Applying

    /// The pointer configuration these values describe. Everything about the
    /// curve is answered by asking it, never by a second copy of the formula.
    public var pointerConfiguration: PointerSynthesizer.Configuration {
        var config = PointerSynthesizer.Configuration()
        apply(to: &config)
        return config
    }

    /// Where amplification begins — the tuner shades everything below this.
    public var accelerationKnee: Double { pointerConfiguration.accelerationKnee }

    /// Screen pixels per millimetre of finger travel at a given finger speed.
    public func pixelsPerMillimetre(atSpeed speed: Double) -> Double {
        pointerConfiguration.pixelsPerMillimetre(atSpeed: speed)
    }

    public func apply(to config: inout PointerSynthesizer.Configuration) {
        config.gain = pointerGain
        config.accelerationEnabled = accelEnabled
        config.minAcceleration = accelMin
        config.maxAcceleration = accelMax
        config.accelerationCurve = accelCurve
        config.accelerationReference = accelReference
        config.stopGate.enabled = stopGateEnabled
        config.stopGate.armSpeed = armSpeed
        config.stopGate.stopSpeed = stopSpeed
    }

    public func apply(to config: inout ScrollSynthesizer.Configuration) {
        config.gain = scrollGain
        config.momentumDecayTime = scrollDecay
        config.naturalDirection = naturalScroll
        config.momentumEnabled = momentumEnabled
    }

    public func apply(to recognizer: PointerRecognizer) {
        recognizer.twoFingerTapEnabled = tapEnabled && rightTapEnabled
        recognizer.tapMaxDuration = tapTime
        recognizer.tapMaxTravel = tapTravel
        recognizer.twoFingerTapMaxDuration = twoTapTime
        recognizer.twoFingerTapMaxTravel = twoTapTravel
        recognizer.doubleTapInterval = doubleTapTime
        recognizer.doubleTapMaxDistance = doubleTapDistance
    }
}

/// Calls `onChange` whenever the file at `url` is replaced or rewritten.
///
/// Atomic writes replace the file rather than modifying it in place, so the
/// original descriptor stops receiving events — the watch has to be re-armed
/// on every change, and the containing directory watched as well for the case
/// where the file does not exist yet.
public final class TuningWatcher {
    private let url: URL
    private let queue: DispatchQueue
    private let onChange: (Tuning) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?

    public init(url: URL = Tuning.defaultURL,
                queue: DispatchQueue = .main,
                onChange: @escaping (Tuning) -> Void) {
        self.url = url
        self.queue = queue
        self.onChange = onChange
    }

    public func start() {
        watchDirectory()
        arm()
    }

    private func arm() {
        source?.cancel()
        source = nil

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }   // not created yet; the directory watch covers it

        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend], queue: queue)
        s.setEventHandler { [weak self] in
            guard let self else { return }
            if let tuning = Tuning.load(from: self.url) { self.onChange(tuning) }
            // Re-arm: an atomic write left us holding a descriptor to a file
            // that is no longer at this path.
            self.arm()
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    private func watchDirectory() {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: queue)
        s.setEventHandler { [weak self] in
            guard let self else { return }
            if self.source == nil, let tuning = Tuning.load(from: self.url) {
                self.onChange(tuning)
                self.arm()
            }
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        directorySource = s
    }

    public func stop() {
        source?.cancel(); source = nil
        directorySource?.cancel(); directorySource = nil
    }
}
