import Foundation

/// Whole-machine exclusion for "something is driving the trackpad".
///
/// Two drivers both flipping Input Mode and both posting events is the one
/// failure mode that leaves you with no usable cursor, so exactly one process
/// may hold this at a time — LaunchAgent, terminal, or the app, whichever got
/// there first.
///
/// `flock` on a pid file rather than the pid alone: a lock is released by the
/// kernel when the holder exits *however* it exits, including a `kill -9` that
/// never reaches an atexit handler. A bare pid file would be left behind by
/// that crash and read as a live driver forever — which is exactly how the
/// telemetry-freshness check this replaces used to fail, one reboot later. The
/// pid is still written, but only so a refusal can name who has it.
public final class DriverLock {

    public static var defaultURL: URL {
        Tuning.defaultURL.deletingLastPathComponent()
            .appendingPathComponent("driver.pid")
    }

    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    /// Take the lock, or return nil if another process holds it.
    ///
    /// Held for as long as the returned object lives. The caller keeps it
    /// alive for the run; letting it deinit releases the lock.
    public static func acquire(url: URL = DriverLock.defaultURL) -> DriverLock? {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let fd = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return nil }

        // LOCK_NB: refusing is the whole point, so never wait for the holder.
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }

        // Truncate before writing, or a shorter pid leaves the tail of a longer
        // one behind and the file reads as a nonsense number.
        ftruncate(fd, 0)
        let pid = "\(ProcessInfo.processInfo.processIdentifier)\n"
        _ = pid.withCString { write(fd, $0, strlen($0)) }

        return DriverLock(descriptor: fd)
    }

    /// The pid recorded by whoever holds the lock, for an error message.
    ///
    /// Nil when the file is absent, empty, or unheld — this reads the file
    /// without taking the lock, so it says nothing about whether that process
    /// is still alive. Only ever call it after `acquire` has already refused.
    public static func holderPID(url: URL = DriverLock.defaultURL) -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
