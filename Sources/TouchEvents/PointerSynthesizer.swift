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
        public var gain = 20.0
        /// Peak acceleration multiplier for fast movement.
        public var maxAcceleration = 3.0
        /// Finger speed (mm/s) at which acceleration reaches its midpoint.
        public var accelerationReference = 150.0
        /// Sharpness of the acceleration knee. 1.0 is a soft, gradual ramp;
        /// higher keeps slow movement near 1:1 for precision and then climbs
        /// quickly, which is the shape Apple's curve has.
        public var accelerationCurve = 1.8
        public var accelerationEnabled = true

        public init() {}
    }

    public var configuration: Configuration

    private var buttonState: [MouseButton: Bool] = [:]

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

    /// Forget our cursor belief, e.g. when all fingers lift. The next movement
    /// re-reads the true position and display layout.
    public func resync() {
        cursor = nil
        cachedBounds = nil
    }

    // MARK: Motion

    private var anyButtonDown: MouseButton? {
        buttonState.first { $0.value }?.key
    }

    private func move(_ millimetres: Point, dt: Double) {
        var scale = configuration.gain
        if configuration.accelerationEnabled, dt > 0 {
            let speed = millimetres.magnitude / dt          // mm/s
            let ratio = speed / configuration.accelerationReference
            // Raising the ratio to a power puts a knee in the curve: slow
            // movement stays near unity gain for precision, then gain climbs
            // steeply. A plain r/(1+r) ramp has no knee and feels mushy.
            let shaped = pow(ratio, configuration.accelerationCurve)
            let factor = 1 + (configuration.maxAcceleration - 1) * (shaped / (1 + shaped))
            scale *= factor
        }

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
