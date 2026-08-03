import Foundation

/// A one-slot shared-memory channel carrying what the pointer is doing right
/// now, so the tuner can show where a gesture lands on the curve.
///
/// Shared memory rather than a socket or a file rewrite: the driver publishes
/// on every HID report, ~154 times a second, from inside the input callback.
/// That callback has a 6.5 ms budget and already caused trouble once by making
/// a synchronous WindowServer round trip. A store into an mmap'd page is a few
/// nanoseconds and involves no syscall at all, so the driver cannot be slowed
/// by the panel watching it — or by nothing watching it.
///
/// Only the newest sample matters; there is no queue, and a reader that misses
/// samples simply sees the newer one.
public final class TelemetryChannel {

    /// What the driver publishes. Fixed layout, written and read as raw bytes.
    public struct Sample {
        /// Finger speed in mm/s, as the acceleration curve sees it.
        public var speed: Double = 0
        /// The multiplier that speed produced.
        public var pixelsPerMillimetre: Double = 0
        /// Seconds since boot, for deciding whether this is stale.
        public var timestamp: Double = 0
        /// Fingers on the pad. Zero means nothing is happening.
        public var contacts: Double = 0

        public init() {}
    }

    private static let slotSize = 64   // a comfortable multiple of the fields

    public static var defaultURL: URL {
        Tuning.defaultURL.deletingLastPathComponent()
            .appendingPathComponent("telemetry.bin")
    }

    private let memory: UnsafeMutableRawPointer
    private let descriptor: Int32

    /// - Parameter writable: the driver opens writable, the panel read-only.
    public init?(url: URL = TelemetryChannel.defaultURL, writable: Bool) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let flags = writable ? (O_RDWR | O_CREAT) : O_RDONLY
        let fd = open(url.path, flags, 0o644)
        guard fd >= 0 else { return nil }

        if writable {
            // Must exist at full size before mapping, or reads fault.
            if ftruncate(fd, off_t(TelemetryChannel.slotSize)) != 0 {
                close(fd); return nil
            }
        } else {
            var info = stat()
            guard fstat(fd, &info) == 0,
                  info.st_size >= off_t(TelemetryChannel.slotSize) else {
                close(fd); return nil     // driver has not published yet
            }
        }

        let protection = writable ? (PROT_READ | PROT_WRITE) : PROT_READ
        let mapped = mmap(nil, TelemetryChannel.slotSize, protection, MAP_SHARED, fd, 0)
        guard let mapped, mapped != MAP_FAILED else { close(fd); return nil }

        self.memory = mapped
        self.descriptor = fd
    }

    deinit {
        munmap(memory, TelemetryChannel.slotSize)
        close(descriptor)
    }

    /// Monotonic seconds, matching `Sample.timestamp`.
    public static var now: Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    public func publish(speed: Double, pixelsPerMillimetre: Double, contacts: Int) {
        // Individually aligned 8-byte stores. A reader can in principle catch a
        // mixed pair, which for two numbers driving a dot on a chart is not
        // worth a seqlock — the next sample is 6.5 ms away.
        memory.storeBytes(of: speed, toByteOffset: 0, as: Double.self)
        memory.storeBytes(of: pixelsPerMillimetre, toByteOffset: 8, as: Double.self)
        memory.storeBytes(of: TelemetryChannel.now, toByteOffset: 16, as: Double.self)
        memory.storeBytes(of: Double(contacts), toByteOffset: 24, as: Double.self)
    }

    public func read() -> Sample {
        var sample = Sample()
        sample.speed = memory.load(fromByteOffset: 0, as: Double.self)
        sample.pixelsPerMillimetre = memory.load(fromByteOffset: 8, as: Double.self)
        sample.timestamp = memory.load(fromByteOffset: 16, as: Double.self)
        sample.contacts = memory.load(fromByteOffset: 24, as: Double.self)
        return sample
    }

    /// True if the driver has published recently enough to believe.
    ///
    /// Also covers the driver having exited: the mapping survives the process
    /// that made it, so a stale page would otherwise read as a live finger.
    public func isLive(within seconds: Double = 0.4) -> Bool {
        let sample = read()
        guard sample.timestamp > 0 else { return false }
        return TelemetryChannel.now - sample.timestamp < seconds
    }
}
