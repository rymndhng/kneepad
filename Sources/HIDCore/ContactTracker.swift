import Foundation

/// A finger followed across frames. Reports are snapshots, so births, deaths,
/// motion and velocity all have to be derived by diffing — this is that diff.
public struct Track {
    /// Monotonic identifier assigned by the tracker. Never reused, unlike the
    /// hardware's Contact Identifier, which is recycled as fingers lift.
    public let id: Int
    public let hardwareID: Int

    public let origin: Point
    public private(set) var position: Point
    public private(set) var previous: Point

    /// Millimetres per second, exponentially smoothed.
    public private(set) var velocity: Point = Point(x: 0, y: 0)

    /// Seconds since this track began.
    public private(set) var age: Double = 0
    /// Total path length in millimetres — distinguishes a tap from a wiggle.
    public private(set) var distance: Double = 0

    public private(set) var confident: Bool

    /// Straight-line displacement from where the finger landed.
    public var displacement: Point { position - origin }

    init(id: Int, contact: Contact) {
        self.id = id
        self.hardwareID = contact.hardwareID
        self.origin = contact.position
        self.position = contact.position
        self.previous = contact.position
        self.confident = contact.confident
    }

    /// Velocity smoothing factor. Raw per-frame deltas are noisy at 100+ Hz;
    /// too much smoothing adds lag to momentum hand-off.
    public static let velocitySmoothing = 0.35

    mutating func advance(to contact: Contact, dt: Double) {
        previous = position
        position = contact.position
        confident = contact.confident
        age += dt

        let step = position - previous
        distance += step.magnitude

        guard dt > 0 else { return }
        let instant = Point(x: step.x / dt, y: step.y / dt)
        let a = Track.velocitySmoothing
        velocity = Point(x: a * instant.x + (1 - a) * velocity.x,
                         y: a * instant.y + (1 - a) * velocity.y)
    }
}

public enum TouchEvent {
    case began(Track)
    case moved(Track)
    case ended(Track)

    public var track: Track {
        switch self {
        case .began(let t), .moved(let t), .ended(let t): return t
        }
    }
}

/// Turns a stream of `Frame` snapshots into finger lifecycle events.
///
/// Association is by the hardware's Contact Identifier, which a conforming PTP
/// device keeps stable for the life of a contact. `idChurnDetected` flags the
/// case where that assumption fails, since it would force nearest-neighbour
/// matching instead.
public final class ContactTracker {
    private var tracks: [Int: Track] = [:]   // hardwareID → Track
    private var nextID = 0
    private var lastScanTime: Int?

    /// Position smoothing. Raw capacitive positions jitter by a unit or two
    /// even under a still finger, which reads as a twitchy cursor.
    public var smoothing = SmoothingConfiguration()
    private var filters: [Int: OneEuroPointFilter] = [:]

    private let scanTimeModulus: Int?
    private let secondsPerCount: Double?

    /// Set if a hardware ID vanished and a different one appeared in the same
    /// frame while the contact count held steady — a sign IDs aren't stable.
    public private(set) var idChurnDetected = false

    /// Seconds elapsed between the last two frames, from Scan Time when
    /// available and wall-clock otherwise.
    public private(set) var lastDelta: Double = 0

    public init(layout: TouchLayout) {
        self.scanTimeModulus = layout.scanTimeModulus
        self.secondsPerCount = layout.secondsPerCount
    }

    /// For tests and devices without a Scan Time field.
    public init(scanTimeModulus: Int? = nil, secondsPerCount: Double? = nil) {
        self.scanTimeModulus = scanTimeModulus
        self.secondsPerCount = secondsPerCount
    }

    public var active: [Track] { tracks.values.sorted { $0.id < $1.id } }

    /// Elapsed seconds between frames. Scan Time is preferred over host
    /// timestamps because USB batching makes arrival times jittery.
    private func delta(_ frame: Frame, fallback: Double) -> Double {
        guard let now = frame.scanTime,
              let modulus = scanTimeModulus,
              let scale = secondsPerCount else { return fallback }
        defer { lastScanTime = now }
        guard let previous = lastScanTime else { return 0 }
        var counts = now - previous
        if counts < 0 { counts += modulus }   // counter wrapped
        return Double(counts) * scale
    }

    @discardableResult
    public func update(_ frame: Frame, wallClockDelta: Double = 0) -> [TouchEvent] {
        let dt = delta(frame, fallback: wallClockDelta)
        lastDelta = dt

        var events: [TouchEvent] = []
        var seen = Set<Int>()

        for raw in frame.contacts {
            let contact = smooth(raw, dt: dt)
            seen.insert(contact.hardwareID)
            if var existing = tracks[contact.hardwareID] {
                existing.advance(to: contact, dt: dt)
                tracks[contact.hardwareID] = existing
                events.append(.moved(existing))
            } else {
                let track = Track(id: nextID, contact: contact)
                nextID += 1
                tracks[contact.hardwareID] = track
                events.append(.began(track))
            }
        }

        let vanished = tracks.keys.filter { !seen.contains($0) }
        // Simultaneous birth and death at a steady contact count means the
        // hardware renumbered a finger rather than the user lifting one.
        if !vanished.isEmpty,
           events.contains(where: { if case .began = $0 { return true } else { return false } }) {
            idChurnDetected = true
        }
        for id in vanished {
            if let track = tracks.removeValue(forKey: id) { events.append(.ended(track)) }
            // A recycled contact ID must not inherit the old finger's filter
            // state, or the new touch starts by sliding in from the old spot.
            filters.removeValue(forKey: id)
        }
        return events
    }

    /// Apply per-contact position smoothing. Each contact keeps its own filter
    /// so two fingers don't pollute each other's estimates.
    private func smooth(_ contact: Contact, dt: Double) -> Contact {
        guard smoothing.enabled, dt > 0 else { return contact }

        let filter: OneEuroPointFilter
        if let existing = filters[contact.hardwareID] {
            filter = existing
        } else {
            filter = OneEuroPointFilter(minCutoff: smoothing.minCutoff,
                                        beta: smoothing.beta,
                                        settleGain: smoothing.settleGain,
                                        settleDeadband: smoothing.settleDeadband)
            filters[contact.hardwareID] = filter
        }
        filter.minCutoff = smoothing.minCutoff
        filter.beta = smoothing.beta
        filter.settleGain = smoothing.settleGain
        filter.settleDeadband = smoothing.settleDeadband

        return Contact(hardwareID: contact.hardwareID,
                       rawX: contact.rawX, rawY: contact.rawY,
                       position: filter.filter(contact.position, dt: dt),
                       confident: contact.confident)
    }

    public func reset() {
        tracks.removeAll()
        filters.removeAll()
        lastScanTime = nil
        lastDelta = 0
    }
}

// MARK: - Two-finger geometry
//
// The quantities gesture recognition is built from. Centroid motion drives
// scroll; spread drives pinch; angle drives rotation.

public struct TwoFingerState {
    public let centroid: Point
    public let spread: Double        // millimetres between contacts
    public let angle: Double         // radians, atan2 of the connecting vector

    public init?(_ tracks: [Track]) {
        guard tracks.count == 2 else { return nil }
        let a = tracks[0].position, b = tracks[1].position
        centroid = Point(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        spread = (b - a).magnitude
        angle = atan2(b.y - a.y, b.x - a.x)
    }

    /// Shortest angular difference to another state, in radians.
    public func rotation(from other: TwoFingerState) -> Double {
        var d = angle - other.angle
        while d > .pi { d -= 2 * .pi }
        while d < -.pi { d += 2 * .pi }
        return d
    }
}
