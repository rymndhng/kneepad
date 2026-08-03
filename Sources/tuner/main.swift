import AppKit
import TouchEvents

// A tuning panel for touchd.
//
// Writes ~/Library/Application Support/teach-touch/tuning.json; touchd watches
// that file and applies changes without restarting. So the loop is: move a
// slider, move your finger, feel the difference. Every constant in this project
// was arrived at by hand, and until now that loop was edit, rebuild, restart.
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

    private let sMin = 3.0, sMax = 1000.0
    private let inset = NSEdgeInsets(top: 10, left: 40, bottom: 34, right: 12)

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
            NSAttributedString(string: "flat to \(Int(knee)) mm/s", attributes: label)
                .draw(at: NSPoint(x: inset.left + 5, y: inset.top + 4))
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

        let axis = NSAttributedString(string: "finger speed — mm/s, log scale", attributes: label)
        axis.draw(at: NSPoint(x: inset.left + (w - axis.size().width) / 2,
                              y: inset.top + h + 17))
    }

    private func niceStep(_ max: Double) -> Double {
        let raw = max / 5
        let mag = pow(10, floor(log10(raw)))
        let n = raw / mag
        return (n <= 1 ? 1 : n <= 2 ? 2 : n <= 5 ? 5 : 10) * mag
    }
}

// MARK: - Controls

final class SliderRow: NSStackView {
    private let slider = NSSlider()
    private let readout = NSTextField(labelWithString: "")
    private let decimals: Int
    /// `committed` is false while the knob is still under the mouse.
    private let onChange: (Double, Bool) -> Void

    init(_ title: String, _ help: String, range: ClosedRange<Double>,
         value: Double, decimals: Int, onChange: @escaping (Double, Bool) -> Void) {
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

        addArrangedSubview(header)
        addArrangedSubview(slider)
        addArrangedSubview(caption)
        header.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
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

// MARK: - Window

final class TunerController: NSObject, NSWindowDelegate {
    private var tuning = Tuning.load() ?? Tuning()
    private let curve = CurveView()
    private let status = NSTextField(labelWithString: "")
    private let knee = NSTextField(labelWithString: "")
    private var sliders: [String: SliderRow] = [:]
    private var toggles: [String: NSButton] = [:]
    let window: NSWindow

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()

        window.title = "teach-touch tuning"
        window.delegate = self
        window.center()

        let controls = NSStackView()
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 14
        controls.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)

        func heading(_ text: String) {
            let label = NSTextField(labelWithString: text.uppercased())
            label.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
            label.textColor = .secondaryLabelColor
            controls.addArrangedSubview(label)
        }

        func slider(_ key: String, _ title: String, _ help: String,
                    _ range: ClosedRange<Double>, _ decimals: Int,
                    _ get: @escaping (Tuning) -> Double,
                    _ set: @escaping (inout Tuning, Double) -> Void) {
            let row = SliderRow(title, help, range: range, value: get(tuning),
                                decimals: decimals) { [weak self] v, committed in
                guard let self else { return }
                set(&self.tuning, v)
                self.apply(save: committed)
            }
            sliders[key] = row
            controls.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: controls.widthAnchor, constant: -36).isActive = true
        }

        func toggle(_ key: String, _ title: String,
                    _ get: @escaping (Tuning) -> Bool,
                    _ set: @escaping (inout Tuning, Bool) -> Void) {
            let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            button.state = get(tuning) ? .on : .off
            button.setAction { [weak self] in
                guard let self else { return }
                set(&self.tuning, button.state == .on)
                self.apply()
            }
            toggles[key] = button
            controls.addArrangedSubview(button)
        }

        heading("Pointer")
        toggle("accel", "Acceleration", { $0.accelEnabled }, { $0.accelEnabled = $1 })
        slider("gain", "Gain", "px per mm at the reference speed", 4...40, 0,
               { $0.pointerGain }, { $0.pointerGain = $1 })
        slider("min", "Floor", "slow-movement multiplier — precision", 0.1...1.5, 2,
               { $0.accelMin }, { $0.accelMin = $1 })
        slider("max", "Ceiling", "fast-movement multiplier — reach", 1...6, 1,
               { $0.accelMax }, { $0.accelMax = $1 })
        slider("ref", "Reference", "mm/s where the multiplier is 1; lower shrinks the flat zone",
               60...400, 0, { $0.accelReference }, { $0.accelReference = $1 })
        slider("curve", "Curve", "steepness above the knee", 0.4...2.5, 2,
               { $0.accelCurve }, { $0.accelCurve = $1 })

        knee.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        knee.textColor = .secondaryLabelColor
        controls.addArrangedSubview(knee)

        heading("Stopping")
        toggle("gate", "Cut the deceleration tail",
               { $0.stopGateEnabled }, { $0.stopGateEnabled = $1 })
        slider("arm", "Arm above", "mm/s the finger must reach before a tail is possible",
               20...250, 0, { $0.armSpeed }, { $0.armSpeed = $1 })
        slider("stop", "Cut below", "mm/s under which decaying motion is treated as tail",
               20...250, 0, { $0.stopSpeed }, { $0.stopSpeed = $1 })

        heading("Scroll")
        slider("scroll", "Gain", "px per mm", 8...80, 0,
               { $0.scrollGain }, { $0.scrollGain = $1 })
        slider("decay", "Momentum decay", "seconds", 0.05...0.8, 2,
               { $0.scrollDecay }, { $0.scrollDecay = $1 })
        toggle("inertia", "Inertia", { $0.momentumEnabled }, { $0.momentumEnabled = $1 })
        toggle("natural", "Natural direction", { $0.naturalScroll }, { $0.naturalScroll = $1 })

        heading("Taps")
        toggle("tap", "Tap to click", { $0.tapEnabled }, { $0.tapEnabled = $1 })
        toggle("righttap", "Two-finger tap right-clicks",
               { $0.rightTapEnabled }, { $0.rightTapEnabled = $1 })
        slider("taptime", "Tap time", "seconds", 0.1...1.0, 2,
               { $0.tapTime }, { $0.tapTime = $1 })
        slider("taptravel", "Tap travel", "mm", 0.5...8, 1,
               { $0.tapTravel }, { $0.tapTravel = $1 })
        slider("twotaptime", "Two-finger time", "seconds", 0.1...1.2, 2,
               { $0.twoTapTime }, { $0.twoTapTime = $1 })
        slider("twotaptravel", "Two-finger travel", "mm", 0.5...12, 1,
               { $0.twoTapTravel }, { $0.twoTapTravel = $1 })
        slider("dbltime", "Double-tap gap", "seconds between taps, not counting the taps",
               0.1...1.0, 2, { $0.doubleTapTime }, { $0.doubleTapTime = $1 })
        slider("dbldist", "Double-tap distance", "mm", 1...20, 1,
               { $0.doubleTapDistance }, { $0.doubleTapDistance = $1 })

        let reset = NSButton(title: "Reset to defaults", target: nil, action: nil)
        reset.setAction { [weak self] in
            self?.tuning = Tuning()
            self?.reloadControls()
            self?.apply()
        }
        controls.addArrangedSubview(reset)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = controls
        controls.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            controls.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.stringValue = "touchd applies changes as you move a slider"

        let right = NSStackView(views: [curve, status])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 8
        right.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)
        curve.translatesAutoresizingMaskIntoConstraints = false
        curve.widthAnchor.constraint(equalTo: right.widthAnchor, constant: -28).isActive = true

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(scroll)
        split.addArrangedSubview(right)

        window.contentView = split
        DispatchQueue.main.async { split.setPosition(400, ofDividerAt: 0) }

        refreshDisplay()
        installReleaseMonitor()
    }

    private func reloadControls() {
        sliders["gain"]?.value = tuning.pointerGain
        sliders["min"]?.value = tuning.accelMin
        sliders["max"]?.value = tuning.accelMax
        sliders["ref"]?.value = tuning.accelReference
        sliders["curve"]?.value = tuning.accelCurve
        sliders["arm"]?.value = tuning.armSpeed
        sliders["stop"]?.value = tuning.stopSpeed
        sliders["scroll"]?.value = tuning.scrollGain
        sliders["decay"]?.value = tuning.scrollDecay
        sliders["taptime"]?.value = tuning.tapTime
        sliders["taptravel"]?.value = tuning.tapTravel
        sliders["twotaptime"]?.value = tuning.twoTapTime
        sliders["twotaptravel"]?.value = tuning.twoTapTravel
        sliders["dbltime"]?.value = tuning.doubleTapTime
        sliders["dbldist"]?.value = tuning.doubleTapDistance
        toggles["accel"]?.state = tuning.accelEnabled ? .on : .off
        toggles["gate"]?.state = tuning.stopGateEnabled ? .on : .off
        toggles["inertia"]?.state = tuning.momentumEnabled ? .on : .off
        toggles["natural"]?.state = tuning.naturalScroll ? .on : .off
        toggles["tap"]?.state = tuning.tapEnabled ? .on : .off
        toggles["righttap"]?.state = tuning.rightTapEnabled ? .on : .off
    }

    /// Safety net for a drag that never delivers a final event — released
    /// outside the window, or interrupted. Long enough that pausing mid-drag
    /// does not itself cause a write.
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
        curve.tuning = tuning
        knee.stringValue = String(
            format: "flat to %.0f mm/s at %.1f px/mm, ceiling %.1f px/mm",
            tuning.accelerationKnee,
            tuning.pixelsPerMillimetre(atSpeed: 1),
            tuning.pixelsPerMillimetre(atSpeed: 10_000))
    }

    private func apply(save: Bool = true) {
        // The plot always tracks the slider; only the file waits.
        refreshDisplay()
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

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = TunerController()
controller.window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
