# teach-touch — userland multitouch driver for the ZSA trackpad on macOS

Goal: make the ZSA trackpad support multitouch gestures (scroll, pinch, rotate,
swipe) on macOS, entirely from userland — no kext, no DriverKit.

## Status

**Stage 0 complete.** `hid-descriptor` decodes the descriptor and audits it
against the PTP profile. Run against hardware it confirmed every hand-decoded
claim below: Input Mode is feature report 4, touch data is input report 1
(15 bytes, 2 contacts), X/Y are 0–2048 over 55.0 mm, Scan Time is 100 µs/count,
mouse fallback is report 6.

**Stage 1 half-verified.** The Input Mode write is confirmed working:

```
with ID prefix: raw 0403 → body 03  ✓ accepted
```

Learned along the way: **macOS carries the report-ID byte in feature-report
buffers in both directions.** `GET` returns it as byte 0, and `SET` must send
it as byte 0. Getting this wrong made the first attempt fail silently — the
write returned success while the device stayed in mouse mode.

**Stage 1 complete — GO.** Confirmed interactively: report 1 streams live
contacts once Input Mode is 3. The device does real multitouch, and the
remaining stages are ordinary software.

```
./.build/debug/hid-stream             # live contact view
./.build/debug/hid-stream --restore   # panic button if the cursor stays dead
```

---

## Hardware findings

Probed on 2026-08-01 against the attached device via `hidutil list` and
`ioreg -c IOHIDInterface -r -l`.

Device: **ZSA Voyager**, VID `0x3297` (12951), PID `0x1977` (6519), USB.

It publishes four HID interfaces:

| Usage Page          | Usage             | What it is                | macOS driver attached? |
|---------------------|-------------------|---------------------------|------------------------|
| 1 (Generic Desktop) | 6                 | Keyboard                  | yes                    |
| 1                   | 2                 | Mouse                     | yes                    |
| 1                   | 128               | System control / consumer | yes                    |
| **13 (Digitizer)**  | **5 (Touch Pad)** | **the trackpad**          | **no**                 |

The digitizer interface is enumerated but *unclaimed* — macOS attached an
`AppleUserHIDEventService` to the other three and declined this one. That is
the opening we use.

### The digitizer report descriptor

Raw, as read from IORegistry:

```
050d0905a10185010922a100a4150025010947094295027501810275019506810195017503250509
518102750195058101050115002600087510550e6511093035004626029501810226000846260209
318102b4c0050d0922a100a4150025010947094295027501810275019506810195017503250509518
102750195058101050115002600087510550e6511093035004626029501810226000846260209318
102b4c0a4550c660110050d0956341447ffff000027ffff00007510950181020954250595017504
810205090901090209032501750195038102750195018101050d8502095575049501250fb1020959
750395012507b1020957750195012501b10206ff00850309c526ff007508960001b102b4c0050d09
0ea101a485040922a10209521500250a95017508b102c00922a100850509570958250195027501b1
029506b103b4c0c005010902a10185060901a100050919012903150025019503750181029501750
581010501093009311581257f950275088106c0c0
```

Hand-decoded (**to be verified by the Stage 0 tool**):

| Report ID | Type | Contents |
|---|---|---|
| 1 | Input | 2× Finger collection: Confidence, Tip Switch, Contact ID (3 bits), X, Y (logical 0–2048, physical 55.0 mm) — then Scan Time (16-bit, 100 µs units), Contact Count (4 bits), 3 buttons |
| 2 | Feature | Contact Count Maximum, Pad Type |
| 3 | Feature | 256-byte vendor blob at usage `0xC5` — the Microsoft **PTPHQA** certification blob |
| 4 | Feature | **Input Mode** (usage `0x52`, 8-bit) |
| 5 | Feature | Surface Switch / Button Switch |
| 6 | Input | Plain Mouse collection (buttons 1–3, relative X/Y) |

### Why gestures don't work today

The firmware implements a **Windows Precision Touchpad (PTP)**. PTP devices boot
in *mouse mode* and only begin emitting multi-contact Report 1 after the host
writes **3** to the Input Mode feature report (Report ID 4).

Windows does this automatically. macOS has no PTP stack, so it never does — the
device stays in mouse mode emitting Report 6, which is exactly the
"single pointer, no gestures" behavior we observe.

**So the unlock is one `SET_FEATURE` call.** Everything after that is ordinary
software.

---

## Architecture

```
IOHIDManager (userland daemon)
  │
  ├─ open digitizer iface, SET_FEATURE rpt4 = 3       ← unlocks contacts
  ├─ input report callback → PTP report 1 parser
  │
  ├─ Contact tracker: finger lifecycle, ID→slot, velocity from Scan Time
  │
  ├─ Gesture recognizers (state machines)
  │     1 finger  → pointer motion + tap/click
  │     2 finger  → scroll · pinch · rotate · swipe
  │
  └─ Event synthesis (CGEvent)
        pointer/click/scroll  → public CoreGraphics API
        pinch/rotate/swipe    → undocumented CGEvent gesture types
```

**Language: Swift**, for first-class IOKit + CoreGraphics interop. Drop to a
small C shim for the undocumented CGEvent fields if bridging fights us.

### Decided: userland (IOHIDManager), not DriverKit

Evaluated 2026-08-01. **Outcome: no dext.**

DriverKit is also userland (a dext is not a kext), and it would buy three things:
legitimate device claiming, operation before login, and the ability to present a
virtual HID pointing device so the cursor goes through Apple's own input stack.

We don't need any of them:

- **Claiming** — macOS attached no driver to the digitizer interface. It is
  enumerated and unclaimed, so there is no ownership contest to win. If reports
  start flowing and macOS does begin competing, try
  `kIOHIDOptionsTypeSeizeDevice` first; a dext is the last resort, not the first.
- **Login window** — explicitly out of scope. Gestures at the FileVault/login
  screen are the one thing userland genuinely cannot do, and we don't want it.
- **Gestures** — DriverKit does *not* help here. Pinch/swipe/rotate are produced
  by Apple's private `AppleMultitouchDevice`/`MultitouchSupport` family, which a
  third-party dext cannot register with. Stage 5's CGEvent synthesis is required
  either way.

So a dext would replace the easy half of the project and leave the hard half
untouched — in exchange for Apple-approved restricted entitlements
(`com.apple.developer.driverkit.transport.hid`), a paid account, a
SystemExtensions install flow, and a restricted runtime with no Foundation.

Revisit only if Stage 1 shows macOS fighting us for the reports *and* seizing
fails, or if the login-window requirement ever comes back.

---

## Stages

Each stage is a working artifact, not a refactor of the last.

### Stage 0 — Descriptor decoder
Pull `ReportDescriptor` from IORegistry, parse HID items into a tree.
Verifies the hand-decode above and yields exact bit offsets for the parser.

*Learn: HID item encoding, usage pages, logical vs. physical units.*

### Stage 1 — Unlock and stream — **GO/NO-GO GATE**
`IOHIDManagerCreate` → match `{VendorID: 12951, PrimaryUsagePage: 13, PrimaryUsage: 5}`
→ `IOHIDDeviceSetReport(kIOHIDReportTypeFeature, 4, [3])` → register input
callback, print contacts.

If two fingers on the pad produce two moving (x,y) pairs, the rest of this plan
is ordinary application code. If not, the plan needs rethinking.

### Stage 2 — Contact tracking ✅
`HIDCore/ContactTracker.swift`, driven by `hid-track`.

Turns per-report snapshots into persistent finger tracks: birth/death, contact
ID reuse, velocity. Velocity comes from the **Scan Time** field (100 µs units)
rather than wall-clock, because USB batching makes host arrival times jittery.

Design notes:

- Track IDs are monotonic and never reused, unlike the hardware's Contact
  Identifier, which is recycled as fingers lift.
- Everything is in **millimetres**, converted using the descriptor's own
  physical ranges, so gesture thresholds are device-independent.
- Association is by hardware Contact Identifier. `idChurnDetected` flags the
  case where that assumption breaks, which would force nearest-neighbour
  matching instead — not built until proven necessary.
- `TwoFingerState` exposes centroid, spread and angle: the three quantities
  scroll, pinch and rotate are built from.

**Testing:** `swift run hidcore-tests` — 22 tests, no hardware needed. Runs as
a plain executable because this Command Line Tools install ships neither a
usable XCTest nor a working `Testing.framework` (the latter links
`lib_TestingInterop.dylib`, which is absent from the system). Layout discovery
and report decoding are tested against a captured copy of the real Voyager
descriptor in `VoyagerFixture.swift`.

### Stage 3 — Pointer and click ✅ (built, needs feel-testing)
`HIDCore/PointerRecognizer.swift` + `TouchEvents/PointerSynthesizer.swift`,
combined with scrolling in **`touchd`** — the first build that replaces
everything mouse mode did, so the pad stays usable while it runs.

- One finger moves the cursor; the **primary contact is the oldest one down**,
  so a second finger landing doesn't yank the pointer.
- Tap to click (≤0.4 s, ≤2 mm travel), two-finger tap for right click,
  double-tap pairing by time *and* distance.
- **The double-tap window is the gap between taps**, first liftoff to second
  touchdown — not the span between liftoffs. Including the second tap's own
  duration coupled the two settings: once `tapMaxDuration` reached
  `doubleTapInterval`, a tap held for its full budget could never pair, so
  raising `--tap-time` silently made double clicks harder.
- **The descriptor's 55 × 55 mm surface is not true.** The sensor measures
  about 25 mm across, so every millimetre the pipeline reports is inflated
  ~2.2×. The descriptor states Logical Max 2048, Physical Max 550, Unit
  Exponent 0x0E (−2), Unit 0x11 (SI linear, cm) → 5.5 cm; PTP descriptors are
  widely copied between projects, so this is very likely inherited boilerplate
  rather than a measurement. `--surface N` corrects it and rescales the
  millimetre-denominated defaults with it. Everything was self-consistent
  before, which is why tuning by feel still converged — on numbers whose units
  were wrong.
- **Two-finger taps are judged on their own, looser budget** (≤0.6 s, ≤4 mm).
  The sequence spans the first touchdown to the last liftoff, so it absorbs
  both fingers' timing slop; the one-finger numbers rejected most real ones.
- **Fingers are counted over the whole sequence, not per frame.** At ~154 Hz
  two fingers tapped together often miss each other by a report — one lands as
  the other leaves — so they never coexist in a single frame. Counting only
  simultaneous contacts turned those into *left* clicks, and into double clicks
  if you tapped twice. Track IDs are monotonic and a sequence ends when every
  finger is up, so counting distinct IDs can't mistake two single taps for one
  two-finger tap.
- Physical buttons are edge-detected; drags post `…MouseDragged` rather than
  `mouseMoved`, or text selection breaks.
- Saturating acceleration curve — raw deltas feel awful.
- `releaseAll()` on shutdown so a crash mid-drag can't leave a button stuck
  down for the rest of the login session.

**Suppression rule that matters:** a touch sequence that *ever* had two fingers
stays suppressed for the pointer until every finger lifts. Without it the
straggler ending a scroll drags the cursor across the screen — the same
one-finger-lifts-first problem that broke momentum.

**Primary changes are discontinuities.** When the oldest finger lifts and
another stays down, the new primary is centimetres away. Diffing across that
measured the *gap between two fingers* as motion: a cursor jump, plus enough
phantom travel to disqualify the tap. The frame re-seeds instead.

### Stage 4 — Scroll ✅ (built, needs feel-testing)
`HIDCore/ScrollRecognizer.swift` + `TouchEvents/ScrollSynthesizer.swift`,
driven by `touch-scroll`.

Recognition is a pure state machine (idle → pending → scrolling) kept free of
CoreGraphics so it stays testable offline. Synthesis uses
`CGEvent(scrollWheelEvent2Source:units:.pixel …)` with
`scrollWheelEventIsContinuous` plus the phase fields, so apps get proper
began/changed/ended and rubber-banding rather than discrete wheel clicks.
Momentum is a decaying-velocity timer emitting the momentum phases.

Design notes:

- **Activation distance** (1 mm default) stops a resting pair from nudging
  the view.
- **Pinch rejection**: if the gap between fingers changes faster than the
  centroid translates, it's a pinch, not a scroll — refuse to engage.
- **Sub-pixel residual** is carried between events so slow drags aren't
  truncated to zero by integer pixel deltas.
- Velocity is carried in the recognizer's `scrolling` state, because by the
  time both fingers lift their tracks are gone. A test caught this — momentum
  was silently seeded with zero.

**Needs two permissions**: Input Monitoring (to read) *and* Accessibility (to
post). Without Accessibility, `CGEventPost` silently does nothing.

**Tuned on hardware:** `gain 32` px/mm and `friction 0.96` are now the
defaults — both hand-tuned on the real pad. The initial guess of gain 8 was
4× too low.

Momentum threshold is expressed in **mm/s**, not px/s, so it stays a statement
about how fast the finger moved rather than silently getting more sensitive
whenever gain goes up.

Two bugs found by using it, both only visible on a fast release:

- **Momentum cancelled by its own gesture.** "A new touch stops coasting" was
  checking "a contact exists and the recognizer is idle", but two fingers never
  lift on the same frame — the `2 → 1 → 0` straggler satisfied it one frame
  after momentum started. Now keyed to the `0 → N` transition.
- **Release velocity measured across liftoff.** Contact area shrinks as fingers
  leave, so the final frames show a fake slowdown and a hard flick seeded almost
  no momentum. Now a finite difference over a 50 ms window ending two frames
  before the lift. The first fix (median of smoothed velocity) overcorrected and
  made a deliberate stop fling — caught by a test, not by hand.

### Stage 5 — Pinch / rotate / swipe 🔬 (recon tool built, not yet implemented)
macOS has **no public API** to synthesize these. The values live in
undocumented `CGEvent` fields, and guessing the field numbers produces events
that are *silently ignored* — the worst possible failure mode, since nothing
errors and nothing happens.

So rather than trust remembered constants, **measure**. `gesture-probe`
installs a listen-only `CGEventTap` over the gesture event types
(18 rotate, 29 gesture, 30 magnify, 31 swipe, …) and dumps every populated
field of whatever Apple's own trackpad emits. A Magic Trackpad is paired on
this machine, so the real encoding can be read straight off the wire.

```
./.build/debug/gesture-probe        # then pinch on the APPLE trackpad
```

Once the field layout is known, the synthesizer is straightforward — the
recognizer side already exists in embryo as `TwoFingerState` (spread → pinch,
angle → rotation).

Prior art if the probe comes up short: **Mac Mouse Fix**
(`TouchSimulator.m`, `GestureScrollSimulator.swift`).

> ⚠️ Mac Mouse Fix is GPL-3. Read it to learn the field constants, but
> reimplement from the constants rather than copying code, unless we're happy
> for teach-touch to be GPL.

Note the 2-contact ceiling from the Risks table: three-finger swipes are not
available from this hardware regardless.

### Stage 6 — Packaging ✅ (written, not yet installed)
`scripts/install-agent.sh` / `scripts/uninstall-agent.sh`.

Builds release binaries, installs to `~/.local/bin`, writes a LaunchAgent
plist to `~/Library/LaunchAgents/dev.rymndhng.teach-touch.plist`, and
bootstraps it. `KeepAlive` with a 5 s `ThrottleInterval` so a crash loop backs
off instead of spinning. Logs to `~/Library/Logs/teach-touch/`.

**The gotcha: TCC is per-binary, not per-user.** The installed copy at
`~/.local/bin/touchd` is a *different binary* from the one run out of
`.build/`, so it needs its own Input Monitoring and Accessibility grants.
Approving your terminal earlier does not carry over.

`hid-stream` is installed alongside `touchd` deliberately: it is the panic
button (`hid-stream --restore`) if the daemon ever dies without putting the
device back in mouse mode, which otherwise leaves you with no cursor.

Note this toolchain puts release output in `.build/out/Products/Release`, not
`.build/release`, so the scripts ask `swift build --show-bin-path` rather than
assuming.

Not done: code signing and notarization. Only needed if this is ever shared.

---

## Risks

| Risk | Detail | Mitigation |
|---|---|---|
| **Two contacts only** | Descriptor declares exactly 2 Finger collections. 3- and 4-finger gestures are unavailable. | Firmware is QMK-based and open; raising contact count is plausible if the sensor supports it — separate project. |
| **Private API fragility** | Stage 5's gesture fields are undocumented; can break across macOS releases. | Stages 0–4 use only public API and are stable. Degrade gracefully if Stage 5 breaks. |
| **Reclaiming the interface** | macOS may grab digitizer reports once they start flowing. | `kIOHIDOptionsTypeSeizeDevice`. Stage 1 will tell us. |
| **Mode persistence** | Input Mode likely resets on unplug/replug or firmware flash. | Re-arm on IOHIDManager device-matching callbacks. |
| **Cursor regression** | Flipping to PTP mode kills the working mouse path before Stage 3 lands. | Keep a kill switch that restores Input Mode 0; don't run the daemon at login until Stage 3 is solid. |
| **Descriptor misreports the surface** | Claims 55 mm across a sensor measuring ~25 mm, so every millimetre downstream is inflated ~2.2×. Undetectable from inside the pipeline — it stays self-consistent, so tuning by feel converges on numbers whose units are wrong. | `--surface N` corrects it and rescales the mm-denominated defaults. Bake in once measured — see Open TODOs. |

---

## Deleted: the 1€ filter and lead compensation

Both once sat between the device and the cursor. Both are gone. **Read this
before adding either back** — each was added for a plausible reason, and each
turned out to be measurably worthless on this hardware.

### The 1€ filter

A speed-adaptive low-pass over contact positions, plus a `settleGain` term of
my own on top of the published design. Three findings, in increasing order of
how much each should have prevented it being written:

1. **There is no jitter to suppress.** The pad reports 2048 steps across its
   width, so one step is 12–27 µm depending on which surface figure you trust.
   At the slow-movement rate of ~7 px/mm that is under 0.2 px. Two steps of
   sensor noise cannot move the cursor a whole pixel. The 1€ filter earns its
   place when raw noise is large relative to output resolution — tracked
   headsets, optical markers. Here it is two orders of magnitude below it.
2. **The signal arrives already filtered.** The firmware low-passes position
   before it reaches USB; that is the entire source of the deceleration tail.
   Filtering a filtered signal removes no noise and adds delay.
3. **The settle term was actively harmful.** It raised the cutoff by
   `settleGain × excess / dt`, and at 154 Hz that `/dt` is enormous — a 0.06 mm
   change in error swung alpha from 0.36 to 0.65. In motion the error crosses
   the deadband constantly, so smoothing flickered on and off many times a
   second. Reported as jerkiness. It had been added to fix the deceleration
   lingering, a job `StopGate` later took over properly, leaving it redundant
   as well as harmful.

### Lead compensation

The exact algebraic inverse of the firmware's IIR:
`x[n] = y[n] + k·(y[n] − y[n−1])` with `k = (1−a)/a`.

The theory is sound and the implementation was correct. It still did nothing,
and the reason is worth keeping:

- Inverting the measured decay (`r ≈ 0.72` → `a ≈ 0.28`) called for `k = 2.57`.
- Every value above ~1 produced visible noise — the compensator is a
  differentiator with gain `1 + 2k` — or overshoot, the cursor darting past a
  stop and snapping back.
- The only setting that felt right was `k = 0.25`, which advances motion by
  **0.25 frames = 1.6 ms**. One frame at 154 Hz is 6.5 ms. It was doing nothing
  perceptible while still amplifying noise 1.5×.

Being off by 10× from an *exact inverse* is the tell: the model does not hold.
The firmware is not a clean single pole, which the second trace already hinted
at by refusing to fit. Recovering `a` from a decay ratio and inverting it looks
rigorous and produces a number that hardware rejects.

### What replaced them

`TouchEvents/StopGate.swift`, which drops the deceleration tail instead of
trying to invert it. It costs no noise amplification and no lag, because it
withholds samples rather than transforming them. The pipeline is now:

```
device → stop gate → acceleration → gain → CGEventPost
```

Contact positions reach the recognizers exactly as reported.

### The general lesson

A filter is not free insurance. Four theories about this pad's feel were wrong
before the right one, and three of the four were *additions* — a filter, a
settle term, a compensator — each defended by arithmetic that was internally
correct and empirically irrelevant. Before adding a stage, measure that the
thing it targets is large enough to see in the output.

---

## Tuning app

`swift run tuner` opens a panel of sliders beside a live plot of the
acceleration curve. It writes
`~/Library/Application Support/teach-touch/tuning.json`; `touchd` watches that
file and applies changes **without restarting**, so the loop is: move a slider,
move your finger, feel the difference.

```
./scripts/build-app.sh          # builds build/Teach Touch Tuner.app
open 'build/Teach Touch Tuner.app'
./.build/debug/touchd           # in a terminal, alongside it
```

`swift run tuner` also works, but a bare SwiftPM executable is a faceless
process to macOS — no Dock icon, no menu bar, and it cannot be focused
properly. The bundle is what makes it a real app; copy it to `/Applications`
to keep it.

Precedence is: built-in defaults, then the tuning file, then command-line flags.
So a flag still wins for a one-off experiment, and `--no-live` ignores the file
entirely.

Two notes on the build:

- **AppKit, not SwiftUI.** This Command Line Tools install has no macro plugins,
  so `@State` fails to resolve — the same gap that makes XCTest unusable here.
- **The curve is defined once**, in `PointerSynthesizer.Configuration`. The
  plot, the driver and the tests all call it rather than restating the formula.
  A previous version of this project had the arithmetic written out in three
  places, and the documentation drifted from the code twice.

---

## Open TODOs

### Bake in the true surface size

**Status:** mechanism built (`--surface N`), correct value not yet established.

The descriptor claims 55 × 55 mm; the sensor measures roughly 25 mm across.
Until this is settled, every millimetre-denominated default in the project is
inflated by ~2.2× and none of the flags mean what they say.

1. **Measure the active area properly** — edge to edge of the sensor, not the
   bezel. Everything else scales off this one number, so an eyeball estimate is
   not good enough to hardcode.
   Better than a ruler: drag one finger corner to corner and read the extremes
   from `hid-stream --trace`. That gives the span the firmware actually reports
   over, in its own units, with no parallax.
2. **Confirm it is square.** X and Y declare identical ranges, which is what
   makes the current numbers symmetric. If the sensor is not square, `--surface`
   needs a second axis rather than one scalar.
3. **Then fold it into the defaults** and delete the flag — a permanent property
   of the hardware does not belong in a runtime option. The constants to move
   are listed in the `--surface` block in `touchd/main.swift`; speeds and
   lengths scale with the surface, gains inversely.
4. **Re-check the stop gate afterwards.** `--arm-speed 120` currently arms at
   ~55 mm/s of real hand movement, so it fires far more readily than designed.
   Correcting the scale without re-tuning will make it noticeably less eager.

Worth reporting upstream to ZSA once confirmed: if the descriptor's Physical
Maximum is boilerplate, every PTP consumer of this firmware inherits the error.

### Also outstanding

- `touchd --stats` jitter lines are wrong — they pool samples across different
  resting positions rather than measuring spread at one spot. See
  `FEEL-DEBUGGING.md`.
- Stage 5 (pinch / rotate) parked by agreement; recon notes below.
- LaunchAgent written and syntax-checked but never installed.

---

## Reference material

- Microsoft — *Windows Precision Touchpad* device requirements (report formats,
  Input Mode semantics, PTPHQA blob)
- Linux `drivers/hid/hid-multitouch.c` — reference PTP report parsing
- Apple — `IOHIDManager` / `IOKit/hid` headers; `CGEvent` / `CGEventSource`
- Mac Mouse Fix (GPL-3) — undocumented gesture CGEvent constants
- QMK — pointing device / digitizer feature, for any firmware-side changes

---

## Stage 5 field notes (in progress)

Captured from a Magic Trackpad via `gesture-probe`. **Partial — do not build on
this yet.**

Confirmed:

| Field | Meaning | Evidence |
|---|---|---|
| 132 | Phase, matching `NSEventPhase` | 128 = `.mayBegin`, 8 = `.ended` observed |
| 110 | Gesture type — likely `IOHIDEventType` | value 6 seen (`Scroll`?) — unconfirmed |
| 115, 117, 164 | Float32 bit pattern of value A | `0x3FD29000` = 1.6446 = double at 113/114/116/118 |
| 123, 165 | Float32 bit pattern of value B | matches double at 119/139 |
| 113, 114, 116, 118 | Value A as double | 1.644775 |
| 119, 139 | Value B as double | −0.132965 |

`0x80000000` (−0.0) is the **"no value" sentinel** — it fills every value field
on a `.mayBegin` event.

Housekeeping, identical on every event, not gesture data:
39, 40, 41, 45, 50, 55, 58, 85, 87, 101, 169.

All five phases have now been captured: `.mayBegin` (128), `.began` (1),
`.stationary` (2), `.changed` (4), `.ended` (8).

### What observation could not settle

Three labelled runs on a Magic Trackpad:

| Run | primary value | secondary value |
|---|---|---|
| pinch out | +0.489 | −4.919 |
| rotate cw | −2.740 | −0.222 |
| swipe left | 4 → 22 → 13 ramp | 2, 5, 2, 1 |

The roles do not hold across gestures. If `primary` were magnification, a
*rotate* would not produce −2.74 of it while showing only −0.22 of rotation.

Two further negatives:

- **Field 110 is 6 on every gesture** — pinch, rotate and swipe alike. It is
  not the gesture discriminator its `IOHIDEventType` reading suggested.
- **Types 30 (Magnify), 18 (Rotate) and 31 (Swipe) never appear**, at
  `.cghidEventTap`, `.cgSessionEventTap` or `.cgAnnotatedSessionEventTap`.

Working hypothesis: type-29 events are a generic gesture *envelope*, and real
pinch/rotate recognition happens in a layer that never surfaces as a CGEvent —
most likely `MultitouchSupport`, which only Apple devices feed. If that is
right, Stage 5 is where the userland approach reaches its ceiling.

### Synthesis test

`gesture-emit` posts candidate type-29 events. Injection is confirmed to work
structurally: `gesture-probe` catches the synthetic events with correct phases
and values (field 164 = `0x3E000000` = 0.125, matching a 0.5 total over 4
steps). **Whether any app responds is still unverified** — that needs a human
watching a window.

```
open -a Preview <some image>
./.build/debug/gesture-emit --delay 3 --pinch 0.5 --verbose
```

If nothing zooms, try `--hid-type 7` (Scale) and `--hid-type 8` (Zoom). If
those also do nothing, the remaining route is Mac Mouse Fix's implementation —
GPL-3, so read it for the constants and reimplement rather than copy.
