import AppKit
import TouchDriver
import TouchEvents

// Teach Touch — the trackpad driver and its tuning panel, in one app.
//
// The driver runs for as long as this app is open: launching it makes the pad
// work, quitting it puts the pad back in mouse mode. Shipping the panel apart
// from the driver meant every session started by remembering to launch a
// second thing in a terminal, and every permission problem had to be diagnosed
// twice, against two binaries with separate TCC grants.
//
// So the loop is now: open the app, move a slider, move your finger, feel the
// difference. Settings still go to
// ~/Library/Application Support/teach-touch/tuning.json, so a headless
// `touchd` LaunchAgent picks up the same values — but they are applied to the
// in-process driver directly, without waiting on a file watcher.
//
// AppKit rather than SwiftUI because this toolchain has no macro plugins, so
// @State does not resolve — the same gap that rules out XCTest here.

// MARK: - Plot

/// px/mm against finger speed, log-x, with the flat zone shaded.
///
/// Reads `Tuning.pixelsPerMillimetre`, the same arithmetic the driver uses, so
/// the picture cannot drift from the behaviour.
final class CurveView: NSView {
    var tuning = Tuning() { didSet { needsDisplay = true } }

    /// Current finger speed in mm/s, or nil when nothing is touching the pad.
    var liveSpeed: Double? { didSet { needsDisplay = true } }

    /// Recent speeds, newest last, for a fading trail. A single dot at 154 Hz
    /// is a blur; the trail is what makes the shape of a gesture readable —
    /// how far up the curve it reached and how long it spent there.
    var trail: [Double] = []

    private let sMin = 3.0, sMax = 1000.0
    private let inset = NSEdgeInsets(top: 10, left: 40, bottom: 36, right: 26)

    /// Colour for the live position and its trail.
    ///
    /// The curve is drawn in the system accent, and the two mean different
    /// things — the curve is the setting, the dot is your finger — so they must
    /// not look like one object. Rather than picking a fixed hue that could
    /// collide with whatever accent the user has chosen, this rotates the
    /// accent's own hue halfway round the wheel, which stays distinct from any
    /// of them. Graphite has no hue to rotate, so it falls back to orange.
    /// Cached, because resolving it is not cheap and it is asked for on every
    /// motion tick as well as every draw. `controlAccentColor` is a dynamic
    /// colour: resolving it goes through the appearance and into CoreUI's
    /// theme store, which showed up in a profile at 60 Hz. It changes only
    /// when the user picks a different accent or the appearance flips, and
    /// both post a notification.
    var indicatorColor: NSColor {
        if let cachedLiveColor { return cachedLiveColor }
        let colour = liveColor
        cachedLiveColor = colour
        return colour
    }

    private var cachedLiveColor: NSColor?

    private func forgetCachedColors() {
        cachedLiveColor = nil
        needsDisplay = true
    }

    /// Light ⇄ dark, or anything else that changes how a dynamic colour
    /// resolves.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        forgetCachedColors()
    }

    private var observingSystemColors = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The accent colour itself, changed in System Settings. Registered
        // here rather than in init because this runs more than once.
        guard !observingSystemColors else { return }
        observingSystemColors = true
        NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.forgetCachedColors() }
    }

    private var liveColor: NSColor {
        guard let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) else {
            return .systemOrange
        }
        var hue: CGFloat = 0, saturation: CGFloat = 0
        var brightness: CGFloat = 0, alpha: CGFloat = 0
        accent.getHue(&hue, saturation: &saturation,
                      brightness: &brightness, alpha: &alpha)
        guard saturation > 0.15 else { return .systemOrange }
        return NSColor(hue: (hue + 0.5).truncatingRemainder(dividingBy: 1),
                       saturation: min(1, saturation * 1.1),
                       brightness: min(1, brightness * 1.05),
                       alpha: 1)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width - inset.left - inset.right
        let h = bounds.height - inset.top - inset.bottom
        guard w > 20, h > 20 else { return }

        let yMax = max(tuning.pointerGain * tuning.accelMax, tuning.pointerGain) * 1.15
        func x(_ v: Double) -> Double {
            inset.left + (log10(v) - log10(sMin)) / (log10(sMax) - log10(sMin)) * w
        }
        func y(_ v: Double) -> Double { inset.top + h - (v / yMax) * h }

        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        let label: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        // Flat zone — the thing being adjusted most often.
        let knee = tuning.accelerationKnee
        if tuning.accelEnabled, knee.isFinite, knee > sMin {
            NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
            NSRect(x: inset.left, y: inset.top,
                   width: x(min(knee, sMax)) - inset.left, height: h).fill()
        }

        NSColor.separatorColor.setStroke()
        for v in [10.0, 30, 100, 300, 1000] where v <= sMax {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x(v), y: inset.top))
            path.line(to: NSPoint(x: x(v), y: inset.top + h))
            path.lineWidth = 1
            path.stroke()
            let text = NSAttributedString(string: "\(Int(v))", attributes: label)
            text.draw(at: NSPoint(x: x(v) - text.size().width / 2, y: inset.top + h + 4))
        }
        var gy = 0.0
        let step = niceStep(yMax)
        while gy <= yMax {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: inset.left, y: y(gy)))
            path.line(to: NSPoint(x: inset.left + w, y: y(gy)))
            path.lineWidth = 1
            path.stroke()
            let text = NSAttributedString(string: "\(Int(gy))", attributes: label)
            text.draw(at: NSPoint(x: inset.left - text.size().width - 6,
                                  y: y(gy) - text.size().height / 2))
            gy += step
        }

        // Pivot, knee and gain as dotted rules across the plot, each labelled
        // along its own length. Text beside an axis has to be tied back to the
        // line it names; text lying on the line needs no tying at all.
        let guideLabel: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]

        /// Text reading bottom-to-top, anchored at its lower end.
        ///
        /// The view is flipped, so this rotation composes with the flip AppKit
        /// already applies to draw glyphs upright. Rotating by -90 and drawing
        /// at negative height is what comes out the right way round — verified
        /// by rendering a glyph both ways and comparing against a pixel
        /// rotation, not by reasoning about it.
        func drawUpward(_ text: NSAttributedString, x: CGFloat, bottom: CGFloat) {
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: x, yBy: bottom)
            transform.rotate(byDegrees: -90)
            transform.concat()
            text.draw(at: NSPoint(x: 0, y: -text.size().height))
            NSGraphicsContext.restoreGraphicsState()
        }

        func dotted(_ path: NSBezierPath) {
            NSColor.secondaryLabelColor.setStroke()
            path.lineWidth = 1
            path.setLineDash([1.5, 3], count: 2, phase: 0)
            path.stroke()
        }

        if tuning.accelEnabled {
            // Each rule runs from its axis to the curve and stops there. Past
            // the intersection it would be describing a point the curve does
            // not occupy, and the three meeting the curve is the whole content
            // of the picture: the gain line and the pivot line cross exactly on
            // it, which is what "the multiplier is 1 here" means.
            let pivotX = x(min(max(tuning.accelPivot, sMin), sMax))
            let gainY = y(tuning.pointerGain)

            if tuning.accelPivot > sMin {
                let gainLine = NSBezierPath()
                gainLine.move(to: NSPoint(x: inset.left, y: gainY))
                gainLine.line(to: NSPoint(x: pivotX, y: gainY))
                dotted(gainLine)

                let text = NSAttributedString(
                    string: String(format: "gain %.0f", tuning.pointerGain),
                    attributes: guideLabel)
                if text.size().width + 10 < pivotX - inset.left {
                    text.draw(at: NSPoint(x: inset.left + 4, y: gainY - 12))
                }
            }

            let crowded = abs(x(knee) - pivotX) < 14
            for (speed, caption) in [(knee, crowded ? "" : "knee \(Int(knee))"),
                                     (tuning.accelPivot, "pivot \(Int(tuning.accelPivot))")]
                where speed > sMin && speed < sMax {

                let px = x(speed)
                let meets = y(tuning.pixelsPerMillimetre(atSpeed: speed))
                let line = NSBezierPath()
                line.move(to: NSPoint(x: px, y: inset.top + h))
                line.line(to: NSPoint(x: px, y: meets))
                dotted(line)

                guard !caption.isEmpty else { continue }
                let text = NSAttributedString(string: caption, attributes: guideLabel)
                // A label may overrun the top of its rule a little — it still
                // reads as belonging to it — but not by so much that it looks
                // detached, and never past the top of the plot. At the shipped
                // settings the knee rule is 49px against a 43px label, so a
                // rule-length guard would drop exactly the label most wanted.
                let ruleLength = inset.top + h - meets
                guard text.size().width < ruleLength + 24,
                      text.size().width + 8 < h else { continue }
                // The rotated strip ends at `x`, so this sits it immediately
                // left of the rule rather than floating away from it.
                drawUpward(text, x: px - 2, bottom: inset.top + h - 4)
            }
        }

        let curve = NSBezierPath()
        for px in 0...Int(w) {
            let t = Double(px) / w
            let speed = pow(10, log10(sMin) + t * (log10(sMax) - log10(sMin)))
            let point = NSPoint(x: inset.left + Double(px),
                                y: min(inset.top + h,
                                       max(inset.top, y(tuning.pixelsPerMillimetre(atSpeed: speed)))))
            px == 0 ? curve.move(to: point) : curve.line(to: point)
        }
        curve.lineWidth = 2.5
        curve.lineJoinStyle = .round
        NSColor.controlAccentColor.setStroke()
        curve.stroke()

        // Trail, oldest faintest.
        let live = indicatorColor
        for (index, speed) in trail.enumerated() where speed > sMin {
            let age = Double(index + 1) / Double(max(trail.count, 1))
            live.withAlphaComponent(0.10 + 0.45 * age).setFill()
            let px = tuning.pixelsPerMillimetre(atSpeed: speed)
            let point = NSPoint(x: x(min(speed, sMax)),
                                y: min(inset.top + h, max(inset.top, y(px))))
            NSBezierPath(ovalIn: NSRect(x: point.x - 2.5, y: point.y - 2.5,
                                        width: 5, height: 5)).fill()
        }

        // The live position.
        if let speed = liveSpeed, speed > sMin {
            let px = tuning.pixelsPerMillimetre(atSpeed: speed)
            let point = NSPoint(x: x(min(speed, sMax)),
                                y: min(inset.top + h, max(inset.top, y(px))))

            live.withAlphaComponent(0.55).setStroke()
            let drop = NSBezierPath()
            drop.move(to: NSPoint(x: point.x, y: inset.top + h))
            drop.line(to: point)
            drop.lineWidth = 1
            drop.setLineDash([3, 3], count: 2, phase: 0)
            drop.stroke()

            // A ring of background colour so the dot stays legible where it
            // crosses the curve, which is most of the time.
            NSColor.textBackgroundColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - 6, y: point.y - 6,
                                        width: 12, height: 12)).fill()
            live.setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - 4.5, y: point.y - 4.5,
                                        width: 9, height: 9)).fill()

            // The numbers live in a fixed readout below the chart. A label
            // pinned to the dot moves with it, which at 60Hz is unreadable
            // however it is positioned.
        }

        let axis = NSAttributedString(string: "finger speed — mm/s, log scale", attributes: label)
        axis.draw(at: NSPoint(x: inset.left + (w - axis.size().width) / 2,
                              y: inset.top + h + 19))

        // The vertical axis, named down the right-hand edge.
        //
        // This view is flipped, so a rotation composes with the flip AppKit
        // already applies when drawing text upright. Rotating by -90 and
        // drawing at negative height is what puts the glyphs the right way up
        // reading bottom to top — checked by rendering a glyph both ways and
        // comparing against a pixel rotation, not by reading the code.
        let vertical = NSAttributedString(string: "screen px per mm", attributes: label)
        let verticalSize = vertical.size()
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: bounds.width - 6,
                             yBy: inset.top + (h + verticalSize.width) / 2)
        transform.rotate(byDegrees: -90)
        transform.concat()
        vertical.draw(at: NSPoint(x: 0, y: -verticalSize.height))
        NSGraphicsContext.restoreGraphicsState()
    }

    private func niceStep(_ max: Double) -> Double {
        let raw = max / 5
        let mag = pow(10, floor(log10(raw)))
        let n = raw / mag
        return (n <= 1 ? 1 : n <= 2 ? 2 : n <= 5 ? 5 : 10) * mag
    }
}

// MARK: - Controls

/// Reference marks above a slider: where the shipped default sits, and where
/// the value stood when the panel opened.
///
/// Tuning by feel drifts. Without these there is no way to answer "is this
/// actually better than where I started, or have I just been moving things",
/// which is the question that matters after ten minutes of adjustment.
final class SliderMarkers: NSView {
    weak var slider: NSSlider?
    var defaultValue = 0.0
    var launchValue = 0.0

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 7) }

    override func draw(_ dirtyRect: NSRect) {
        guard let slider, slider.maxValue > slider.minValue else { return }

        // Match the track's geometry: a slider reserves half a knob at each end,
        // so a naive 0…width mapping puts every mark slightly off.
        let knob = (slider.cell as? NSSliderCell)?.knobRect(flipped: false).width ?? 18
        let usable = bounds.width - knob
        func x(_ value: Double) -> CGFloat {
            let fraction = (value - slider.minValue) / (slider.maxValue - slider.minValue)
            return knob / 2 + CGFloat(min(max(fraction, 0), 1)) * usable
        }

        func triangle(at centre: CGFloat) -> NSBezierPath {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: centre, y: 0))
            path.line(to: NSPoint(x: centre - 3.5, y: 6))
            path.line(to: NSPoint(x: centre + 3.5, y: 6))
            path.close()
            return path
        }

        let sameSpot = abs(defaultValue - launchValue) < 1e-9

        // Default: hollow, so it reads as a reference rather than a value.
        let defaultMark = triangle(at: x(defaultValue))
        NSColor.tertiaryLabelColor.setStroke()
        defaultMark.lineWidth = 1
        defaultMark.stroke()

        // Launch: filled. Drawn second so it wins where the two coincide.
        if !sameSpot {
            NSColor.secondaryLabelColor.withAlphaComponent(0.75).setFill()
            triangle(at: x(launchValue)).fill()
        }
    }
}

/// Explains the marks once, rather than every slider carrying a caption.
final class MarkerLegend: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 220, height: 12) }

    override func draw(_ dirtyRect: NSRect) {
        func triangle(at centre: CGFloat) -> NSBezierPath {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: centre, y: 2))
            path.line(to: NSPoint(x: centre - 3.5, y: 8))
            path.line(to: NSPoint(x: centre + 3.5, y: 8))
            path.close()
            return path
        }
        let text: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]

        let hollow = triangle(at: 4)
        NSColor.tertiaryLabelColor.setStroke()
        hollow.lineWidth = 1
        hollow.stroke()
        NSAttributedString(string: "default", attributes: text)
            .draw(at: NSPoint(x: 12, y: 0))

        NSColor.secondaryLabelColor.withAlphaComponent(0.75).setFill()
        triangle(at: 66).fill()
        NSAttributedString(string: "at launch", attributes: text)
            .draw(at: NSPoint(x: 74, y: 0))
    }
}

final class SliderRow: NSStackView {
    private let slider = NSSlider()
    private let readout = NSTextField(labelWithString: "")
    private let decimals: Int
    /// `committed` is false while the knob is still under the mouse.
    private let onChange: (Double, Bool) -> Void

    private let markers = SliderMarkers()

    init(_ title: String, _ help: String, range: ClosedRange<Double>,
         value: Double, defaultValue: Double, decimals: Int,
         onChange: @escaping (Double, Bool) -> Void) {
        self.decimals = decimals
        self.onChange = onChange
        super.init(frame: .zero)

        orientation = .vertical
        alignment = .leading
        spacing = 1

        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 12)
        readout.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        readout.textColor = .controlAccentColor
        readout.alignment = .right

        let header = NSStackView(views: [name, NSView(), readout])
        header.orientation = .horizontal
        header.distribution = .fill
        header.setHuggingPriority(.defaultLow, for: .horizontal)

        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.target = self
        slider.action = #selector(changed)
        slider.isContinuous = true

        let caption = NSTextField(wrappingLabelWithString: help)
        caption.font = .systemFont(ofSize: 10)
        caption.textColor = .secondaryLabelColor
        caption.isHidden = help.isEmpty

        markers.slider = slider
        markers.defaultValue = defaultValue
        markers.launchValue = value
        markers.toolTip = String(format: "default %.2f · at launch %.2f",
                                 defaultValue, value)

        addArrangedSubview(header)
        addArrangedSubview(markers)
        addArrangedSubview(slider)
        addArrangedSubview(caption)
        header.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        markers.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        markers.heightAnchor.constraint(equalToConstant: 7).isActive = true
        slider.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        caption.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    var value: Double {
        get { slider.doubleValue }
        set { slider.doubleValue = newValue; refresh() }
    }

    @objc private func changed() {
        refresh()
        // A continuous slider fires on every tick of travel. Writing the file
        // each time floods touchd's watcher with reloads for values passed
        // through on the way to the one that was meant, so only the final
        // event commits.
        //
        // Anything that is not a drag is already final: keyboard arrows,
        // accessibility, a click on the track. Treating "not a drag" as
        // committed rather than testing for .leftMouseUp keeps those working.
        let event = NSApp.currentEvent?.type
        let dragging = event == .leftMouseDragged || event == .leftMouseDown
        onChange(slider.doubleValue, !dragging)
    }

    private func refresh() {
        readout.stringValue = String(format: "%.\(decimals)f", slider.doubleValue)
    }
}

/// Fixed readout of what the pointer is doing, below the chart.
///
/// Two things make live numbers legible. They sit still, and they include a
/// peak that holds after the gesture — an instantaneous value sampled at 60 Hz
/// cannot be read at all, but the fastest point of a flick can.
final class LiveReadout: NSStackView {
    private let speed = LiveReadout.value()
    private let rate = LiveReadout.value()
    private let peak = LiveReadout.value()
    private let zone = LiveReadout.value()

    private var peakSpeed = 0.0
    private var peakAt = 0.0
    /// How long the peak stays on screen before it starts following the input
    /// down again. Long enough to look at, short enough not to mislead.
    private let peakHold = 2.0

    /// The instantaneous figures update at 12 Hz rather than 60. Faster is not
    /// more informative — the digits just blur.
    private var tick = 0

    private static func value() -> NSTextField {
        let field = NSTextField(labelWithString: "—")
        field.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        field.alignment = .left
        return field
    }

    private static func caption(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
        field.textColor = .tertiaryLabelColor
        return field
    }

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        distribution = .fillEqually
        alignment = .top
        spacing = 12

        for (caption, field) in [("SPEED", speed), ("RATE", rate),
                                 ("PEAK", peak), ("ZONE", zone)] {
            let column = NSStackView(views: [LiveReadout.caption(caption), field])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 0
            addArrangedSubview(column)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Assigning to `stringValue` invalidates the field whether or not the
    /// text changed, so an idle panel showing four dashes would still redraw
    /// them twelve times a second forever. Only write on a real change.
    private static func set(_ field: NSTextField, _ text: String, _ color: NSColor) {
        if field.stringValue != text { field.stringValue = text }
        if field.textColor != color { field.textColor = color }
    }

    func update(speed value: Double, tuning: Tuning, touching: Bool, accent: NSColor) {
        let now = TouchDriver.now
        if touching, value > peakSpeed || now - peakAt > peakHold {
            peakSpeed = value
            peakAt = now
        }

        tick += 1
        guard tick % 5 == 0 else { return }

        let set = LiveReadout.set

        guard touching else {
            set(speed, "—", .tertiaryLabelColor)
            set(rate, "—", .labelColor)
            set(zone, "—", .tertiaryLabelColor)
            if now - peakAt > peakHold { set(peak, "—", .labelColor) }
            return
        }

        let px = tuning.pixelsPerMillimetre(atSpeed: value)
        set(speed, String(format: "%.0f mm/s", value), accent)
        set(rate, String(format: "%.1f px/mm", px), .labelColor)
        set(peak, String(format: "%.0f mm/s", peakSpeed), .labelColor)

        // The question the knee is set to answer: is this gesture being
        // amplified, or is it inside the flat zone?
        if value < tuning.accelerationKnee {
            set(zone, "flat", .secondaryLabelColor)
        } else {
            set(zone, String(format: "×%.2f", px / tuning.pointerGain), accent)
        }
    }
}

/// A clip view that puts the origin at the top left.
///
/// AppKit's default is bottom-left, so a document view shorter than the scroll
/// view sits at the bottom of it — which is why the Taps and Scroll columns
/// hung off the bottom of their tab. The Pointer tab hid the same bug simply
/// by having more content than fits.
final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

// MARK: - Window

final class TunerController: NSObject, NSWindowDelegate {
    private var tuning = Tuning.load() ?? Tuning()
    private let curve = CurveView()
    private let status = NSTextField(labelWithString: "")
    private let driverStatus = NSTextField(labelWithString: "")
    private let readout = LiveReadout()
    let window: NSWindow

    override init() {
        // Tall enough that neither tab scrolls. The Pointer tab measures 612pt
        // of controls and the tab bar and footer take about 78 more, so 730 leaves
        // a little slack past the point where the scrollers stop — clamped to the
        // screen, since a display shorter than that has the last word.
        let wanted = min(730, (NSScreen.main?.visibleFrame.height ?? 730) - 60)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: wanted),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.minSize = NSSize(width: 720, height: 420)
        super.init()

        window.title = "teach-touch tuning"
        window.delegate = self
        window.center()

        // Two tabs. Pointer motion is what gets tuned repeatedly, in a tight
        // loop against the plot; taps and scrolling are set once and left. One
        // column holding all of it meant scrolling past the settled half to
        // reach the half being worked on.
        func makeStack() -> NSStackView {
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 14
            stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
            return stack
        }
        let pointerControls = makeStack()
        let scrollControls = makeStack()
        let tapControls = makeStack()
        var controls = pointerControls

        func heading(_ text: String) {
            let label = NSTextField(labelWithString: text.uppercased())
            label.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
            label.textColor = .secondaryLabelColor
            controls.addArrangedSubview(label)
        }

        func slider(_ title: String, _ help: String,
                    _ range: ClosedRange<Double>, _ decimals: Int,
                    _ get: @escaping (Tuning) -> Double,
                    _ set: @escaping (inout Tuning, Double) -> Void) {
            let row = SliderRow(title, help, range: range, value: get(tuning),
                                defaultValue: get(Tuning()),
                                decimals: decimals) { [weak self] v, committed in
                guard let self else { return }
                set(&self.tuning, v)
                self.apply(save: committed)
            }
            controls.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: controls.widthAnchor, constant: -36).isActive = true
        }

        func toggle(_ title: String,
                    _ get: @escaping (Tuning) -> Bool,
                    _ set: @escaping (inout Tuning, Bool) -> Void) {
            let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            button.state = get(tuning) ? .on : .off
            button.setAction { [weak self] in
                guard let self else { return }
                set(&self.tuning, button.state == .on)
                self.apply()
            }
            controls.addArrangedSubview(button)
        }

        heading("Pointer")
        toggle("Acceleration", { $0.accelEnabled }, { $0.accelEnabled = $1 })
        slider("Gain", "screen px per mm of finger travel, at the pivot speed", 4...40, 0,
               { $0.pointerGain }, { $0.pointerGain = $1 })
        slider("Floor", "slow-movement multiplier — precision", 0.1...1.5, 2,
               { $0.accelMin }, { $0.accelMin = $1 })
        slider("Ceiling", "fast-movement multiplier — reach", 1...6, 1,
               { $0.accelMax }, { $0.accelMax = $1 })
        slider("Pivot", "",
               60...400, 0, { $0.accelPivot }, { $0.accelPivot = $1 })
        slider("Curve", "", 0.4...2.5, 2,
               { $0.accelCurve }, { $0.accelCurve = $1 })

        heading("Stopping")
        toggle("Cut the deceleration tail",
               { $0.stopGateEnabled }, { $0.stopGateEnabled = $1 })
        slider("Arm above", "mm/s the finger must reach before a tail is possible",
               20...250, 0, { $0.armSpeed }, { $0.armSpeed = $1 })
        slider("Cut below", "mm/s under which decaying motion is treated as tail",
               20...250, 0, { $0.stopSpeed }, { $0.stopSpeed = $1 })

        controls = scrollControls

        heading("Scroll")
        slider("Gain", "screen px per mm of finger travel", 8...80, 0,
               { $0.scrollGain }, { $0.scrollGain = $1 })
        slider("Momentum decay", "seconds for a flick to slow to a third",
               0.05...0.8, 2, { $0.scrollDecay }, { $0.scrollDecay = $1 })
        toggle("Inertia", { $0.momentumEnabled }, { $0.momentumEnabled = $1 })
        toggle("Natural direction", { $0.naturalScroll }, { $0.naturalScroll = $1 })

        controls = tapControls

        heading("Taps")
        toggle("Tap to click", { $0.tapEnabled }, { $0.tapEnabled = $1 })
        toggle("Two-finger tap right-clicks",
               { $0.rightTapEnabled }, { $0.rightTapEnabled = $1 })
        // Every one of these is a limit, and a bare "Tap time 0.50" reads
        // just as easily as a minimum. The name says which way it cuts and the
        // caption says what happens when you cross it.
        slider("Tap held at most", "seconds — longer is a press, not a tap",
               0.1...1.0, 2, { $0.tapTime }, { $0.tapTime = $1 })
        slider("Tap moves at most", "mm — further is a drag, not a tap",
               0.5...8, 1, { $0.tapTravel }, { $0.tapTravel = $1 })
        slider("Two fingers held at most", "seconds — longer is a rest, not a tap",
               0.1...1.2, 2, { $0.twoTapTime }, { $0.twoTapTime = $1 })
        slider("Two fingers move at most", "mm — further is a scroll, not a tap",
               0.5...12, 1, { $0.twoTapTravel }, { $0.twoTapTravel = $1 })
        slider("Double-tap gap at most",
               "seconds from one tap lifting to the next landing — longer and "
               + "they stay two single clicks",
               0.1...1.0, 2, { $0.doubleTapTime }, { $0.doubleTapTime = $1 })
        slider("Double-tap spread at most",
               "mm apart — further and they stay two single clicks",
               1...20, 1, { $0.doubleTapDistance }, { $0.doubleTapDistance = $1 })

        func scrolling(_ stack: NSStackView) -> NSScrollView {
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            scroll.contentView = FlippedClipView()
            scroll.documentView = stack
            stack.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
                stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            ])
            return scroll
        }

        startMotionPolling()

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.stringValue = "Changes apply as you move a slider"
        driverStatus.font = .systemFont(ofSize: 11)
        driverStatus.textColor = .secondaryLabelColor

        // The plot belongs to the Pointer tab, not to the window. Taps and
        // scrolling are not read off the acceleration curve, and leaving it on
        // screen there implies a relationship that does not exist.
        let plotPanel = NSStackView(views: [curve, readout])
        plotPanel.orientation = .vertical
        plotPanel.alignment = .leading
        plotPanel.spacing = 8
        plotPanel.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)
        curve.translatesAutoresizingMaskIntoConstraints = false
        curve.widthAnchor.constraint(equalTo: plotPanel.widthAnchor, constant: -28).isActive = true
        readout.widthAnchor.constraint(equalTo: plotPanel.widthAnchor, constant: -28).isActive = true

        // The divider position is a constraint, not a call. setPosition runs
        // before the split view has been laid out inside its tab, which leaves
        // it with no size to divide and AppKit complaining about ambiguity.
        // A low-priority width does the same job and still drags.
        let pointerPane = scrolling(pointerControls)
        let pointerSplit = NSSplitView()
        pointerSplit.isVertical = true
        pointerSplit.dividerStyle = .thin
        pointerSplit.addArrangedSubview(pointerPane)
        pointerSplit.addArrangedSubview(plotPanel)

        let preferredWidth = pointerPane.widthAnchor.constraint(equalToConstant: 400)
        preferredWidth.priority = NSLayoutConstraint.Priority(250)
        NSLayoutConstraint.activate([
            preferredWidth,
            pointerPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            plotPanel.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])

        // Two equal columns. Neither list is long enough to need the full
        // width, and side by side they fit without scrolling at all.
        //
        // Explicit constraints rather than a horizontal NSStackView: a scroll
        // view has no intrinsic height, so a stack has nothing to align it by
        // and the result depends on which alignment happens to be set.
        let scrollColumn = scrolling(scrollControls)
        let tapColumn = scrolling(tapControls)
        let gesturePanel = NSView()
        for column in [scrollColumn, tapColumn] {
            column.translatesAutoresizingMaskIntoConstraints = false
            gesturePanel.addSubview(column)
            NSLayoutConstraint.activate([
                column.topAnchor.constraint(equalTo: gesturePanel.topAnchor),
                column.bottomAnchor.constraint(equalTo: gesturePanel.bottomAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            scrollColumn.leadingAnchor.constraint(equalTo: gesturePanel.leadingAnchor),
            scrollColumn.trailingAnchor.constraint(equalTo: tapColumn.leadingAnchor),
            tapColumn.trailingAnchor.constraint(equalTo: gesturePanel.trailingAnchor),
            scrollColumn.widthAnchor.constraint(equalTo: tapColumn.widthAnchor),
        ])

        // A tab item resizes its view by autoresizing mask, so an autolayout
        // view dropped straight in has no size to lay out against. Wrapping it
        // in a plain container bridges the two.
        func tabContent(_ view: NSView) -> NSView {
            let container = NSView()
            container.autoresizingMask = [.width, .height]
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            return container
        }

        let tabs = NSTabView()
        for (label, view) in [("Pointer", pointerSplit as NSView),
                              ("Taps & Scroll", gesturePanel as NSView)] {
            let item = NSTabViewItem(identifier: label)
            item.label = label
            item.view = tabContent(view)
            tabs.addTabViewItem(item)
        }

        // Footer at window level: the reset covers both tabs, and the legend
        // explains marks that appear on every slider in both of them.
        let legend = MarkerLegend()
        legend.widthAnchor.constraint(equalToConstant: 150).isActive = true
        legend.heightAnchor.constraint(equalToConstant: 12).isActive = true

        let footer = NSStackView(views: [legend, driverStatus, NSView(), status])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.distribution = .fill
        footer.spacing = 14
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 10, right: 14)
        footer.setHuggingPriority(.defaultLow, for: .horizontal)

        let root = NSStackView(views: [tabs, footer])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 6
        root.translatesAutoresizingMaskIntoConstraints = true
        root.autoresizingMask = [.width, .height]
        tabs.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        footer.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        // The tabs take the slack; the footer keeps its natural height.
        tabs.setContentHuggingPriority(.defaultLow, for: .vertical)
        footer.setContentHuggingPriority(.defaultHigh, for: .vertical)

        window.contentView = root

        refreshDisplay()
        installReleaseMonitor()
        startDriver()
    }

    // MARK: - The embedded driver

    private var driver: TouchDriver?
    private var retryTimer: Timer?
    private var promptedForAccessibility = false

    /// Start driving the trackpad, or explain why we cannot.
    ///
    /// Failures here are all recoverable by the user — plug the board in,
    /// grant a permission, quit the other copy — so nothing is fatal and a
    /// retry timer keeps trying quietly rather than making them relaunch.
    private func startDriver() {
        guard driver == nil else { return }

        var options = TouchDriver.Options()
        tuning.apply(to: &options.pointer)
        tuning.apply(to: &options.scroll)
        options.tapEnabled = tuning.tapEnabled

        let driver = TouchDriver(options: options)
        tuning.apply(to: driver.pointerRecognizer)
        // Console rather than the window: these are per-report diagnostics and
        // a startup transcript, neither of which belongs in a one-line footer.
        driver.onLog = { NSLog("teach-touch: %@", $0) }
        driver.onForeignReport = { [weak self] reportID in
            self?.show("Device fell back to mouse mode (report \(reportID))", .systemOrange)
        }

        do {
            try driver.start()
            self.driver = driver
            retryTimer?.invalidate()
            retryTimer = nil
            show("Trackpad live", .systemGreen)
            startHealthReporting()
        } catch DriverError.accessibilityDenied {
            // Without this, CGEventPost silently does nothing — no error, no
            // events. The grant lands on a running process, so once it is
            // given the retry below picks it up without a relaunch.
            show("Needs Accessibility — System Settings ▸ Privacy & Security", .systemRed)
            if !promptedForAccessibility {
                promptedForAccessibility = true
                _ = ScrollSynthesizer.hasAccessibilityPermission(prompt: true)
            }
            scheduleRetry()
        } catch DriverError.deviceNotFound {
            show("Trackpad not found — is the board plugged in?", .secondaryLabelColor)
            scheduleRetry()
        } catch DriverError.alreadyRunning {
            // Almost always the LaunchAgent. Leave the pad to it — the panel
            // still tunes it through the file, which is what it did before it
            // grew a driver — and pick it up if that copy is quit.
            show("Another touchd is running — tuning that one", .systemOrange)
            scheduleRetry()
        } catch {
            // Most often Input Monitoring, which unlike Accessibility is only
            // consulted when the device is opened, and only takes effect for
            // this app once it is relaunched.
            show("Could not open the trackpad: \(error)", .systemRed)
            NSLog("teach-touch: driver failed to start: %@", "\(error)")
            scheduleRetry()
        }
    }

    /// Keep trying, slowly. Covers plugging the board in, granting a
    /// permission, or quitting the other driver, all without a relaunch.
    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            self?.startDriver()
        }
        // Common modes: a retry that only fires in the default mode stalls for
        // as long as a menu is open or a slider is held.
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    private var healthTimer: Timer?
    private var worstGap = 0.0
    private var worstGapAt = Date.distantPast
    private var worstHandler = 0.0
    private var worstHandlerAt = Date.distantPast

    /// Report the frame rate the driver is actually seeing, once a second.
    ///
    /// Worth a permanent line in a panel about feel: "scrolling lags" has two
    /// completely different causes — frames not arriving, or us not keeping up
    /// with them — and they are indistinguishable by hand.
    private func startHealthReporting() {
        guard healthTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let health = driver?.health() else { return }

            // Hold the worst reading for half a minute. The lag being chased
            // happens while this window is behind something else, so a value
            // that only survives 1.5 seconds is gone before it can be read.
            let now = Date()
            if health.worstGapMs > worstGap || now.timeIntervalSince(worstGapAt) > 30 {
                worstGap = health.worstGapMs
                worstGapAt = now
            }
            if health.worstHandlerMs > worstHandler
                || now.timeIntervalSince(worstHandlerAt) > 30 {
                worstHandler = health.worstHandlerMs
                worstHandlerAt = now
            }

            let rate = String(format: "%.0f Hz", health.reportRateHz)
            let budget = 1000 / max(health.reportRateHz, 1)
            if worstGap > 3 * budget {
                show(String(format: "Trackpad live · %@ · frames late by %.0f ms",
                            rate, worstGap), .systemOrange)
            } else if worstHandler > budget / 2 {
                show(String(format: "Trackpad live · %@ · handler %.1f ms",
                            rate, worstHandler), .systemOrange)
            } else {
                show("Trackpad live · \(rate)", .systemGreen)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    /// Put the pad back in mouse mode. Skipping this leaves it in multitouch
    /// with nothing decoding it, which means no cursor at all.
    func stopDriver() {
        retryTimer?.invalidate()
        retryTimer = nil
        healthTimer?.invalidate()
        healthTimer = nil
        driver?.stop()
        driver = nil
    }

    private func show(_ message: String, _ color: NSColor) {
        guard driverStatus.stringValue != message else { return }
        driverStatus.stringValue = message
        driverStatus.textColor = color
    }

    private var idleWrite: Timer?

    /// Set while a slider has moved but the value has not been written.
    private var pending = false

    /// Commit on the mouse-up that ends a drag.
    ///
    /// Not relying on the slider's own final action: whether a continuous
    /// NSSlider sends one on release is not something to bet the responsiveness
    /// of the whole panel on. Watching the event directly is unambiguous.
    private func installReleaseMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            if self?.pending == true { self?.write() }
            return event
        }
    }

    /// Redraw only. Opening the panel must not rewrite the file — the values
    /// on screen are the ones already in it.
    private func refreshDisplay() {
        // Everything this used to spell out — the knee, the flat rate, the
        // ceiling — is on the chart's axes now.
        curve.tuning = tuning
    }

    private func apply(save: Bool = true) {
        // The plot always tracks the slider; only the file waits.
        refreshDisplay()
        // The embedded driver takes every change immediately. The reason the
        // file write waits for the release — that a continuous slider floods
        // the watcher with values passed through on the way to the intended
        // one — does not apply in process, so the feel changes under your
        // finger while you drag.
        driver?.apply(tuning)
        idleWrite?.invalidate()
        guard save else {
            pending = true
            status.stringValue = "Editing — release to apply"
            status.textColor = .secondaryLabelColor
            idleWrite = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) {
                [weak self] _ in
                guard self?.pending == true else { return }
                self?.write()
            }
            return
        }
        write()
    }

    // MARK: Live position on the curve

    private var motionTimer: Timer?

    /// Polls the driver's latest motion at display rate.
    ///
    /// Polling rather than being pushed: the driver reports ~154 times a second
    /// from inside its frame handler, which has a 6.5 ms budget and must not be
    /// made to repaint a curve. Sixty reads a second is all a plot can show.
    private func startMotionPolling() {
        // Common modes, or the plot freezes for the whole of a slider drag —
        // which is exactly when it is being watched.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.pollMotion()
        }
        RunLoop.main.add(timer, forMode: .common)
        motionTimer = timer
    }

    private func pollMotion() {
        // `at` going stale covers the driver not running yet, or having stopped
        // — the last sample would otherwise read as a finger frozen mid-swipe.
        let motion = driver?.motion ?? TouchDriver.Motion()
        guard motion.at > 0, TouchDriver.now - motion.at < 0.4 else {
            setLiveSpeed(nil)
            if !curve.trail.isEmpty { curve.trail.removeAll(); curve.needsDisplay = true }
            readout.update(speed: 0, tuning: tuning, touching: false,
                           accent: curve.indicatorColor)
            return
        }

        let touching = motion.contacts > 0 && motion.speed > 0
        setLiveSpeed(touching ? motion.speed : nil)
        readout.update(speed: motion.speed, tuning: tuning, touching: touching,
                       accent: curve.indicatorColor)
        if touching {
            curve.trail.append(motion.speed)
            if curve.trail.count > 90 { curve.trail.removeFirst() }   // ~1.5s
        } else if !curve.trail.isEmpty {
            curve.trail.removeFirst()
            curve.needsDisplay = true
        }
    }

    /// Assign only on a change.
    ///
    /// `liveSpeed` redraws the whole plot when set, and the driver publishes
    /// continuously, so a resting hand used to repaint the curve sixty times a
    /// second to show the same nothing.
    private func setLiveSpeed(_ speed: Double?) {
        guard curve.liveSpeed != speed else { return }
        curve.liveSpeed = speed
    }

    // MARK: Drawing only when there is something to see

    /// True when the plot is actually on screen: not minimised, not hidden,
    /// not completely covered by another window.
    private var plotIsVisible: Bool {
        !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    /// Stop polling when nobody can see the result.
    ///
    /// This is display work only — the driver keeps running, because the point
    /// of the app is that the trackpad works while it is open. But the poll
    /// runs at 60 Hz and repaints a curve, a trail and four readouts, and none
    /// of that is worth a single cycle behind another window or in the Dock.
    private func updatePolling() {
        let wanted = plotIsVisible
        guard wanted != (motionTimer != nil) else { return }
        if wanted {
            startMotionPolling()
        } else {
            motionTimer?.invalidate()
            motionTimer = nil
            // Come back showing the present rather than a frozen gesture from
            // whenever the window was last covered.
            curve.liveSpeed = nil
            curve.trail.removeAll()
        }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) { updatePolling() }
    func windowDidMiniaturize(_ notification: Notification) { updatePolling() }
    func windowDidDeminiaturize(_ notification: Notification) { updatePolling() }

    private func write() {
        idleWrite?.invalidate()
        idleWrite = nil
        pending = false
        do {
            try tuning.save()
            status.stringValue = "Applied \(Date().formatted(date: .omitted, time: .standard))"
            status.textColor = .secondaryLabelColor
        } catch {
            status.stringValue = "Could not write \(Tuning.defaultURL.path): \(error.localizedDescription)"
            status.textColor = .systemRed
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}

/// NSButton takes target/action, not closures. This keeps the setup readable.
private extension NSButton {
    private static var handlers = [ObjectIdentifier: () -> Void]()

    func setAction(_ handler: @escaping () -> Void) {
        NSButton.handlers[ObjectIdentifier(self)] = handler
        target = self
        action = #selector(invokeHandler)
    }

    @objc func invokeHandler() {
        NSButton.handlers[ObjectIdentifier(self)]?()
    }
}

// MARK: - Launch

/// The menu bar, in code.
///
/// ⌘Q and ⌘W are not built into AppKit — they are key equivalents on menu
/// items, and an app assembled in code rather than from a nib has no menus for
/// them to be on. Without this the shortcuts do nothing at all, which is worse
/// than it sounds for this app in particular: quitting is how the trackpad is
/// handed back to mouse mode.
func makeMainMenu() -> NSMenu {
    let name = "Teach Touch"
    let mainMenu = NSMenu()

    let appItem = NSMenuItem()
    mainMenu.addItem(appItem)
    let appMenu = NSMenu()
    appItem.submenu = appMenu
    appMenu.addItem(withTitle: "About \(name)",
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                    keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Hide \(name)",
                    action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                     action: #selector(NSApplication.hideOtherApplications(_:)),
                                     keyEquivalent: "h")
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(withTitle: "Show All",
                    action: #selector(NSApplication.unhideAllApplications(_:)),
                    keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit \(name)",
                    action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

    // The item's own title is what `windowsMenu` is looked up by; the submenu's
    // title is what gets drawn.
    let windowItem = NSMenuItem()
    windowItem.title = "Window"
    mainMenu.addItem(windowItem)
    let windowMenu = NSMenu(title: "Window")
    windowItem.submenu = windowMenu
    windowMenu.addItem(withTitle: "Close",
                       action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    windowMenu.addItem(withTitle: "Minimize",
                       action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(withTitle: "Zoom",
                       action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")

    return mainMenu
}

/// Owns shutdown. The driver leaves the pad in multitouch mode while it runs,
/// and nothing else on the system decodes that, so failing to restore mouse
/// mode on the way out costs the user their cursor until they re-run something.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = TunerController()
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // AppKit terminates on SIGTERM without running applicationWillTerminate,
        // so `pkill`, a logout, or anything else being tidy would leave the pad
        // in multitouch mode with nothing decoding it — no cursor. SIGINT is
        // for running the app straight from a terminal with `swift run tuner`.
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                self?.controller.stopDriver()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stopDriver()
    }

    /// Reopening from the Dock brings the panel back rather than doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        controller.window.makeKeyAndOrderFront(nil)
        return true
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.mainMenu = makeMainMenu()
// Names the menu AppKit adds its own window list to.
app.windowsMenu = app.mainMenu?.item(withTitle: "Window")?.submenu
let delegate = AppDelegate()
app.delegate = delegate
delegate.controller.window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
