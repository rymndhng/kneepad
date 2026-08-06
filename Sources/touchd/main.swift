import Foundation
import HIDCore
import TouchDriver
import TouchEvents

// teach-touch daemon — Stages 3 + 4 together.
//
// One finger moves the cursor and taps click; two fingers scroll. This is the
// headless front end: flags in, driver running, Ctrl-C restores mouse mode.
// The loop itself lives in `TouchDriver`, which the tuning app also runs, so
// there is one implementation rather than two that drift.

func printUsage() {
    print("""
    touchd — pointer and scrolling for the ZSA trackpad

    The tuning app runs this same driver for as long as its window is open, so
    for interactive use you usually want the app instead:

      ./scripts/build-app.sh && open 'build/Teach Touch.app'

    This command is for running it headless, as a LaunchAgent.

    USAGE
      touchd                        run the driver
      touchd --pointer-gain N       cursor px per mm (default 16)
      touchd --scroll-gain N        scroll px per mm (default 44)
      touchd --friction N           per-tick friction (derived from --decay)
      touchd --flick N              mm/s release speed for momentum (default 1.45)
      touchd --accel-max N          multiplier ceiling, fast movement (default 3.2)
      touchd --accel-min N          multiplier floor, slow movement (default 0.6)
      touchd --accel-curve N        steepness above the knee (default 0.92)
      touchd --accel-pivot N        mm/s the curve turns about (default 260)
                                    lower = smaller flat zone, earlier accel
      touchd --no-accel             disable pointer acceleration
      touchd --decay N              momentum decay time constant (default 0.27s)
      touchd --no-momentum          disable inertial scrolling
      touchd --no-tap               disable tap-to-click
      touchd --no-right-tap         two-finger tap does not right click
      touchd --tap-time N           tap max duration (default 0.5s)
      touchd --tap-travel N         tap max travel (default 1.45mm)
      touchd --two-tap-time N       two-finger tap max duration (default 0.6s)
      touchd --two-tap-travel N     two-finger tap max travel (default 2.9mm)
      touchd --double-tap-time N    max gap between paired taps (default 0.4s)
      touchd --double-tap-dist N    how far apart paired taps may land (5.8mm)
      touchd --surface N            override the measured 40mm pad width
      touchd --no-live              ignore the tuning file; use flags only
      touchd --reverse              invert scroll direction

      Two-finger tap not registering? Run --verbose; it prints why each
      touch failed to qualify, then raise whichever limit it names.

    STOPPING (cutting the firmware's deceleration tail)
      touchd --hard-stop            aggressive stop gate preset
      touchd --stop-speed N         mm/s below which a decaying move is tail (44)
      touchd --arm-speed N          mm/s the finger must reach first (87)
      touchd --no-stop-gate         let the tail through

      Cursor glides on after you stop   → --hard-stop, or raise --stop-speed
      Cursor stops while still moving   → lower --stop-speed, or --no-stop-gate

      The gate cannot remove lag *during* movement — it only drops the tail
      after it. That lag is the firmware's own low-pass, and nothing in
      userland removes it: lead compensation was tried and measured to do
      nothing at any setting that did not also add visible noise.

    POSITIONS
      touchd --minimal              strip the stop gate and acceleration too;
                                    raw delta x gain, nothing else

      Contact positions are used exactly as the device reports them.
      A 1€ filter and lead compensation both used to sit here; both were
      measured to do nothing useful on this hardware and deleted. See
      plan/README.md before adding either back.

      touchd --verbose              log recognised gestures
      touchd --stats                report rate and jitter measurements
      touchd --dry-run              recognise but post nothing

    Needs Input Monitoring (to read the pad) and Accessibility (to post
    events). Ctrl-C restores mouse mode.
    """)
}

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--help") || args.contains("-h") { printUsage(); exit(0) }

func value(_ flag: String) -> Double? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return Double(args[i + 1])
}

// Saved tuning underlies every default; command-line flags still override it,
// and the tuning app rewrites this file live.
let live = !args.contains("--no-live")
let liveTuning = live ? Tuning.load() : nil

var options = TouchDriver.Options()
options.verbose = args.contains("--verbose")
options.dryRun = args.contains("--dry-run")
options.collectStats = args.contains("--stats")
options.publishTelemetry = live
options.surfaceWidthMM = value("--surface")

// Separable from tap-to-click: right-clicking by two-finger tap is the part
// people most often want off on its own, because it can fire during scrolls.
options.tapEnabled = liveTuning?.tapEnabled ?? true
if args.contains("--no-tap") {
    options.tapEnabled = false
    options.tapLocked = true
}
let rightTapEnabled = options.tapEnabled && !args.contains("--no-right-tap")
if args.contains("--no-right-tap") { options.tapLocked = true }

liveTuning?.apply(to: &options.scroll)
if let g = value("--scroll-gain") { options.scroll.gain = g }
if let t = value("--flick") { options.scroll.momentumThreshold = t }
if let d = value("--decay") { options.scroll.momentumDecayTime = d }
if let f = value("--friction") { options.scroll.friction = f }   // after momentumHz
if args.contains("--reverse") { options.scroll.naturalDirection = false }
if args.contains("--no-momentum") { options.scroll.momentumEnabled = false }

liveTuning?.apply(to: &options.pointer)
if let g = value("--pointer-gain") { options.pointer.gain = g }
if let a = value("--accel-max") { options.pointer.maxAcceleration = a }
if let a = value("--accel-min") { options.pointer.minAcceleration = a }
if let c = value("--accel-curve") { options.pointer.accelerationCurve = c }
if let r = value("--accel-pivot") { options.pointer.accelerationPivot = r }
if args.contains("--no-accel") { options.pointer.accelerationEnabled = false }
if let s = value("--stop-speed") { options.pointer.stopGate.stopSpeed = s }
if let s = value("--arm-speed") { options.pointer.stopGate.armSpeed = s }
if args.contains("--no-stop-gate") { options.pointer.stopGate.enabled = false }

// Strip the pipeline back to raw delta x gain. Every transform below was
// added to fix a specific symptom, and stacked they are hard to reason about;
// this is the baseline to build back up from, one stage at a time.
let minimal = args.contains("--minimal")
if minimal {
    options.pointer.accelerationEnabled = false
    options.pointer.stopGate.enabled = false
}

// One switch for "make it stop when I stop".
//
// Purely a gate preset. It cannot cut the whole tail — a tail is only
// recognisable once it has begun arriving — so some is always emitted.
//
// It used to also raise lead compensation, on the theory that the two attack
// the same lag from opposite sides. Lead has since been deleted outright: at
// the only setting that felt right it advanced motion by a quarter of a frame,
// 1.6ms, while still amplifying noise. The gate does all of this work.
if args.contains("--hard-stop") {
    options.pointer.stopGate.makeAggressive()
    if let s = value("--stop-speed") { options.pointer.stopGate.stopSpeed = s }
    if let s = value("--arm-speed") { options.pointer.stopGate.armSpeed = s }
}

let driver = TouchDriver(options: options)

// Tap limits live on the recognizer the driver owns. Saved tuning first, then
// flags, matching the precedence everything else uses.
let pointerRecognizer = driver.pointerRecognizer
liveTuning?.apply(to: pointerRecognizer)
if args.contains("--no-tap") || args.contains("--no-right-tap") {
    pointerRecognizer.twoFingerTapEnabled = rightTapEnabled
}
if let t = value("--tap-time") { pointerRecognizer.tapMaxDuration = t }
if let d = value("--tap-travel") { pointerRecognizer.tapMaxTravel = d }
if let t = value("--two-tap-time") { pointerRecognizer.twoFingerTapMaxDuration = t }
if let d = value("--two-tap-travel") { pointerRecognizer.twoFingerTapMaxTravel = d }
if let t = value("--double-tap-time") { pointerRecognizer.doubleTapInterval = t }
if let d = value("--double-tap-dist") { pointerRecognizer.doubleTapMaxDistance = d }

driver.onLog = { print("  \($0)") }

// MARK: - Startup summary

driver.onDeviceReady = { session in
    print("Device        \(session.device.info.summary)")
    if let size = session.layout.surfaceSize {
        print(String(format: "Surface       %.1f × %.1f mm, %d contacts",
                     size.x, size.y, session.layout.maxContacts))
    }
    // Spell out exactly what sits between the hardware and the cursor. Stacked
    // transforms are the main reason the feel became hard to reason about.
    let pointerConfig = driver.pointerConfiguration
    func stage(_ name: String, _ on: Bool, _ detail: String) {
        print("              \(on ? "→" : "·") \(name.padding(toLength: 20, withPad: " ", startingAt: 0))"
            + (on ? detail : "off"))
    }
    print("Pipeline      raw report from device")
    stage("acceleration", pointerConfig.accelerationEnabled,
          String(format: "×%.2f–%.2f, curve %.2f, ref %.0f mm/s",
                 pointerConfig.minAcceleration, pointerConfig.maxAcceleration,
                 pointerConfig.accelerationCurve, pointerConfig.accelerationPivot))
    stage("stop gate", pointerConfig.stopGate.enabled,
          String(format: "cut below %.0f mm/s, armed above %.0f",
                 pointerConfig.stopGate.stopSpeed, pointerConfig.stopGate.armSpeed))
    print(String(format: "              → %@%.0f px/mm",
                 "gain                ", pointerConfig.gain))
    print("              → CGEventPost")
    if minimal && !pointerConfig.stopGate.enabled && !pointerConfig.accelerationEnabled {
        print("              (--minimal: raw delta × gain only)")
    }
    print()
    let scrollConfig = driver.scrollConfiguration
    print(String(format: "Scroll        %.0f px/mm, %@, decay %.2fs",
                 scrollConfig.gain,
                 scrollConfig.naturalDirection ? "natural" : "reversed",
                 scrollConfig.momentumDecayTime))
    // Times in seconds, matching the unit the flags take. Printing ms here once
    // invited passing 500 back in, which parses as a 500-second window.
    if driver.options.tapEnabled {
        print(String(format: "Tap to click  left, max %.2fs and %.1f mm",
                     pointerRecognizer.tapMaxDuration, pointerRecognizer.tapMaxTravel))
        print(String(format: "Two-finger    %@",
                     pointerRecognizer.twoFingerTapEnabled
                         ? String(format: "right click, max %.2fs and %.1f mm",
                                  pointerRecognizer.twoFingerTapMaxDuration,
                                  pointerRecognizer.twoFingerTapMaxTravel)
                         : "right click off"))
        print(String(format: "Double click  within %.2fs of the last tap lifting, %.1f mm",
                     pointerRecognizer.doubleTapInterval,
                     pointerRecognizer.doubleTapMaxDistance))
    } else {
        print("Tap to click  off")
    }
    if driver.options.dryRun { print("Dry run       recognising only, posting nothing") }
    print()
    print("Switching to multitouch (Input Mode = \(ZSA.inputModeMultitouch))…")
}

driver.onReady = {
    print("\nReady. One finger moves, tap clicks, two fingers scroll.")
    print("Ctrl-C to stop and restore mouse mode.\n")
}

driver.onForeignReport = { reportID in
    print("⚠️  report \(reportID) — device fell back to mouse mode")
}

// MARK: - Shutdown

func restoreAndExit(_ code: Int32) -> Never {
    print("\nRestoring mouse mode…")
    driver.stop()
    exit(code)
}

signal(SIGINT, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler { restoreAndExit(0) }
sigintSource.resume()

// SIGTERM matters once this runs as a LaunchAgent.
signal(SIGTERM, SIG_IGN)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler { restoreAndExit(0) }
sigtermSource.resume()

atexit {
    if args.contains("--stats") { print(); driver.stats.report().forEach { print($0) } }
    if driver.tapCount > 0 || driver.scrollCount > 0 {
        print("\(driver.tapCount) taps, \(driver.scrollCount) scrolls")
    }
    if driver.idChurnDetected {
        print("⚠️  hardware contact IDs were unstable during this run")
    }
}

// MARK: - Run

// The tuning app runs a driver too, and two of them both flipping Input Mode
// and both posting events is the one failure mode that costs you the cursor.
if TouchDriver.isAnotherDriverRunning() {
    print("""
    Another teach-touch driver is already running — most likely the tuning app,
    or the LaunchAgent copy. Quit that one first:

      launchctl bootout gui/$UID/dev.rymndhng.teach-touch
    """)
    exit(1)
}

do {
    try driver.start()
} catch DriverError.accessibilityDenied {
    print("""
    Accessibility permission is required to post events.

    Without it CGEventPost silently does nothing. Grant it to your terminal:
      System Settings ▸ Privacy & Security ▸ Accessibility

    Requesting now — approve, then re-run.
    """)
    _ = ScrollSynthesizer.hasAccessibilityPermission(prompt: true)
    exit(1)
} catch let error as DriverError {
    print("\(error)")
    exit(1)
} catch let error as SessionError {
    print("""
    \(error)

    If this is a permissions failure, grant Input Monitoring to your terminal:
      System Settings ▸ Privacy & Security ▸ Input Monitoring
    """)
    exit(1)
} catch {
    print("\(error)")
    driver.stop()
    exit(1)
}

// Live tuning: the tuning app rewrites the file, and the change lands without
// restarting. Handlers run on the main queue, which is where the HID callback
// runs too, so no locking is needed around the synthesiser configs.
var watcher: TuningWatcher?
if live {
    let w = TuningWatcher { updated in
        driver.apply(updated)
        print(String(format: "  tuning reloaded — gain %.0f px/mm, flat to %.0f mm/s",
                     updated.pointerGain, updated.accelerationKnee))
    }
    w.start()
    watcher = w
    _ = watcher
}

CFRunLoopRun()
restoreAndExit(0)
