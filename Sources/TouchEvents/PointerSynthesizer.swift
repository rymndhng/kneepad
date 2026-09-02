import Foundation
import CoreGraphics
import HIDCore

/// Posts pointer motion and clicks into the macOS input stack.
///
/// In multitouch mode the device stops sending its own mouse reports, so
/// everything the cursor does now comes from here.
public final class PointerSynthesizer {

    public struct Configuration {
        /// Screen pixels per millimetre of finger travel, before acceleration.
        public var gain = 16.0
        /// Peak multiplier for fast movement.
        public var maxAcceleration = 3.2

        /// Multiplier floor for slow movement.
        ///
        /// A curve that only ever multiplies *up* passes slow motion at full
        /// gain — including the deceleration tail in the raw stream, which is
        /// then multiplied by `gain` and shows up as the cursor drifting on
        /// after the finger stops. So the floor sits below 1.
        ///
        /// At 0.2 the attenuation reached far past the tail and into ordinary
        /// fine positioning, which felt sluggish. 0.6 is where it settled by
        /// hand: slow enough to place a cursor precisely, not so slow that
        /// small corrections stop registering.
        public var minAcceleration = 0.6

        /// Finger speed (mm/s) at which the multiplier is exactly 1, i.e. where
        /// `gain` applies literally.
        ///
        /// Together with the floor this sets where the flat region ends —
        /// `reference × floor^(1/curve)`, currently ~149 mm/s. That flat span
        /// is what has to cover ordinary aiming; raising the reference widens
        /// it, lowering it brings acceleration in earlier.
        ///
        /// It moved a long way during tuning — 190, then 124, then here — and
        /// the last move went with the exponent dropping below 1. The pair is
        /// what matters: a wide flat zone with a *gentle* ramp above it feels
        /// different from a narrow zone with a steep one, even where the two
        /// curves cross. Read them together, not separately.
        public var accelerationPivot = 260.0

        /// Curve steepness past the knee. Higher climbs to the ceiling faster.
        ///
        /// Not what keeps the middle of the range flat — an earlier version of
        /// this comment claimed it was, and tuning by hand disproved it. The
        /// flat span comes from the floor and the reference speed; the
        /// exponent only shapes what happens above it. It does move the knee,
        /// though, because the curve pivots about the reference rather than
        /// about the knee.
        ///
        /// Below 1, so amplification arrives gradually: the ceiling is not
        /// reached until ~920 mm/s, which is faster than any deliberate stroke
        /// on a pad 40 mm across.
        public var accelerationCurve = 0.92
        public var accelerationEnabled = true

        /// Suppresses the sensor's deceleration tail after a fast stop.
        public var stopGate = StopGate()

        public init() {}

        /// The speed-dependent multiplier. The single definition of the curve —
        /// `move`, the tuner's plot and the tests all call this, because three
        /// copies of one formula is how a picture ends up disagreeing with the
        /// behaviour it claims to show.
        public func accelerationFactor(atSpeed speed: Double) -> Double {
            guard accelerationEnabled else { return 1 }
            return min(maxAcceleration,
                       max(minAcceleration,
                           pow(speed / accelerationPivot, accelerationCurve)))
        }

        /// Screen pixels per millimetre of finger travel at a given speed.
        public func pixelsPerMillimetre(atSpeed speed: Double) -> Double {
            gain * accelerationFactor(atSpeed: speed)
        }

        /// Where the power law overtakes the floor and amplification begins.
        public var accelerationKnee: Double {
            guard accelerationEnabled, accelerationCurve > 0 else { return .infinity }
            return accelerationPivot * pow(minAcceleration, 1 / accelerationCurve)
        }
    }

    public var configuration: Configuration

    private var buttonState: [MouseButton: Bool] = [:]

    /// Which mouse-down each held button belongs to, so a drag can say which
    /// press it is part of. See `move`.
    private let buttons = ButtonWatch()

    /// Our own cursor position, kept in full precision.
    ///
    /// Reading the system cursor back every frame both costs a round trip and
    /// quantises to whole pixels, so sub-pixel movement was being thrown away
    /// each frame instead of accumulating. Tracking it ourselves is what makes
    /// slow movement smooth rather than steppy.
    private var cursor: CGPoint?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: Entry

    public func handle(_ event: PointerEvent, dt: Double) {
        switch event {
        case .move(let millimetres):
            move(millimetres, dt: dt)
        case .tap(let button, let count):
            click(button, count: count)
        case .buttonChanged(let button, let down):
            setButton(button, down: down)
        }
    }

    /// Release anything still held — used on shutdown so a crash mid-drag
    /// doesn't leave the system with a stuck mouse button.
    public func releaseAll() {
        for (button, isDown) in buttonState where isDown {
            setButton(button, down: false)
        }
    }

    /// Start and stop watching the session's mouse-downs.
    ///
    /// Tied to the driver's lifecycle rather than to this object's: it is a
    /// system-wide event tap, and one has no business outliving the driver
    /// that needed it. A false return means the tap could not be created —
    /// drags still post as drags, they just go back to being stamped 0.
    @discardableResult
    public func startWatchingButtons() -> Bool { buttons.start() }

    public func stopWatchingButtons() { buttons.stop() }

    /// Forget our cursor belief, e.g. when all fingers lift. The next movement
    /// re-reads the true position and display layout.
    public func resync() {
        cursor = nil
        cachedBounds = nil
        // A gate left closed would swallow the start of the next touch.
        configuration.stopGate.reset()
    }

    // MARK: Motion

    /// Which button a drag should be attributed to, whoever is holding it.
    ///
    /// `buttonState` only knows about presses this driver synthesised, and the
    /// click does not have to come from the pad at all — a separate mouse, or a
    /// key mapped to a mouse button, holds the button while the pad still owns
    /// the motion. Judging by our own state alone posted `mouseMoved` for the
    /// whole gesture, and AppKit's drag tracking loops wait on
    /// `…MouseDragged`: a window drag or rubber-band selection never saw the
    /// drag, and only jumped to its final position when the real mouseUp
    /// arrived. The cursor moved the whole time, which is what made this look
    /// like a rendering problem rather than a wrong event type.
    ///
    /// The system query costs ~0.13 µs, measured — nothing against the frame
    /// budget, unlike reading the cursor position back.
    private var anyButtonDown: MouseButton? {
        if let ours = buttonState.first(where: { $0.value })?.key { return ours }
        return MouseButton.allCases.first {
            CGEventSource.buttonState(.combinedSessionState, button: cgButton($0))
        }
    }

    private func move(_ millimetres: Point, dt: Double) {
        // Drop the firmware's deceleration tail before anything else looks at
        // it. Gain would multiply it, and the acceleration curve can only
        // scale motion, never withhold it.
        let speed = dt > 0 ? millimetres.magnitude / dt : 0
        if dt > 0, !configuration.stopGate.allows(speed: speed) { return }

        // A power curve through (1, 1), clamped at both ends. The floor sits
        // BELOW 1, so slow movement is attenuated rather than merely
        // un-amplified.
        var scale = configuration.gain
        if dt > 0 { scale *= configuration.accelerationFactor(atSpeed: speed) }

        // Track the cursor in full precision between frames.
        //
        // Deliberately NOT read back from the system each frame. That is a
        // synchronous round trip to the WindowServer, and running it inside the
        // HID callback at ~154Hz costs more than the 6.5ms frame budget, so
        // report processing falls progressively behind during movement and
        // drains afterwards — felt as lag that persists after the finger stops.
        //
        // The position is only sampled when we have no belief, which happens at
        // the start of a touch (see resync()), so another device moving the
        // cursor is still picked up.
        let origin = cursor ?? (CGEvent(source: nil)?.location ?? .zero)

        let target = clamp(CGPoint(x: origin.x + millimetres.x * scale,
                                   y: origin.y + millimetres.y * scale))
        cursor = target

        // Integer deltas for apps that read relative motion; the position
        // itself stays fractional.
        let dx = (target.x - origin.x).rounded()
        let dy = (target.y - origin.y).rounded()

        // Dragging is a distinct event type; sending mouseMoved while a button
        // is held would break text selection and window dragging.
        let held = anyButtonDown
        let type: CGEventType
        switch held {
        case .left: type = .leftMouseDragged
        case .right: type = .rightMouseDragged
        case .middle: type = .otherMouseDragged
        case nil: type = .mouseMoved
        }

        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: target,
                                  mouseButton: cgButton(held ?? .left)) else { return }
        // A drag also has to say which press it belongs to. AppKit's tracking
        // loops pair the two by event number, and drop a drag whose number is
        // not the one the mouseDown carried — measured: a window follows a
        // synthetic drag when the numbers match and does not move at all when
        // they differ by one. Ours were all 0 while the press that opened the
        // drag was numbered by the window server, so every drag driven by a
        // button held on another device was thrown away. Same shape of bug as
        // posting `mouseMoved` instead of `…MouseDragged`, one layer down, and
        // with the same signature: the cursor moves, the window does not, and
        // apps that track buttons themselves are unaffected.
        if let held {
            event.setIntegerValueField(.mouseEventNumber,
                                       value: buttons.number(for: held))
        }
        // Apps that read relative motion need these, not just the position.
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        event.post(tap: .cghidEventTap)
    }

    /// Union of active display bounds, cached.
    ///
    /// Enumerating displays is another per-frame syscall we cannot afford in
    /// the HID callback. Recomputed only when the cursor belief is dropped,
    /// which is often enough to notice a display being attached.
    private var cachedBounds: CGRect?

    private func displayBounds() -> CGRect {
        if let cachedBounds { return cachedBounds }
        var bounds = CGRect.null
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        if count > 0 {
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
            CGGetActiveDisplayList(count, &ids, &count)
            for id in ids.prefix(Int(count)) {
                bounds = bounds.union(CGDisplayBounds(id))
            }
        }
        cachedBounds = bounds
        return bounds
    }

    /// Keep the cursor inside the union of active displays.
    private func clamp(_ point: CGPoint) -> CGPoint {
        let bounds = displayBounds()
        guard !bounds.isNull else { return point }
        return CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX - 1),
                       y: min(max(point.y, bounds.minY), bounds.maxY - 1))
    }

    // MARK: Buttons

    private func cgButton(_ button: MouseButton) -> CGMouseButton {
        switch button {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        }
    }

    private func eventTypes(_ button: MouseButton) -> (down: CGEventType, up: CGEventType) {
        switch button {
        case .left: return (.leftMouseDown, .leftMouseUp)
        case .right: return (.rightMouseDown, .rightMouseUp)
        case .middle: return (.otherMouseDown, .otherMouseUp)
        }
    }

    private func post(_ type: CGEventType, _ button: MouseButton, clickState: Int) {
        let position = CGEvent(source: nil)?.location ?? .zero
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: position,
                                  mouseButton: cgButton(button)) else { return }
        // Without this, a rapid second click is two singles, not a double.
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        event.post(tap: .cghidEventTap)
    }

    private func setButton(_ button: MouseButton, down: Bool) {
        guard buttonState[button] != down else { return }
        buttonState[button] = down
        let types = eventTypes(button)
        post(down ? types.down : types.up, button, clickState: 1)
    }

    private func click(_ button: MouseButton, count: Int) {
        let types = eventTypes(button)
        post(types.down, button, clickState: count)
        post(types.up, button, clickState: count)
    }
}
