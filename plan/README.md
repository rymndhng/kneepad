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

**Still unverified:** whether report 1 actually streams contacts. That needs
fingers on the pad, so it can only be confirmed interactively:

```
./.build/debug/hid-stream          # drag two fingers, watch for two # entries
./.build/debug/hid-stream --restore   # panic button if the cursor stays dead
```

Until that passes, Stages 2–5 rest on an unproven assumption.

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

### Stage 2 — Contact tracking
Turn per-report snapshots into persistent finger tracks: birth/death, contact ID
reuse, velocity. Compute velocity from the **Scan Time** field (100 µs units),
not wall-clock — USB batching makes host timestamps jittery.

### Stage 3 — Pointer and click
In PTP mode the device stops sending Report 6, so we inherit the cursor.
Relative motion from the primary contact via `CGEventCreateMouseEvent`, plus
palm/thumb rejection using the Confidence bit and contact ordering. Needs a
pointer acceleration curve — raw deltas feel awful.

### Stage 4 — Scroll
`CGEventCreateScrollWheelEvent2` with `kCGScrollEventUnitPixel`, plus phase
fields (`kCGScrollWheelEventScrollPhase` / `MomentumPhase`) so apps get proper
began/changed/ended and rubber-banding. Then a momentum simulator for post-lift
inertia.

*Probably delivers 80% of the value on its own.*

### Stage 5 — Pinch / rotate / swipe
macOS has **no public API** to synthesize these. The working technique is
constructing `CGEvent`s of type 29 (`NSEventTypeGesture`) and setting
undocumented integer fields for gesture subtype and magnitude.

Prior art: **Mac Mouse Fix** (`TouchSimulator.m`, `GestureScrollSimulator.swift`)
has a battle-tested implementation.

> ⚠️ Mac Mouse Fix is GPL-3. Read it to learn the field constants, but
> reimplement from the constants rather than copying code, unless we're happy
> for teach-touch to be GPL.

### Stage 6 — Packaging
LaunchAgent plist, Input Monitoring (TCC) grant, config file, signed +
notarized build if this is ever shared.

---

## Risks

| Risk | Detail | Mitigation |
|---|---|---|
| **Two contacts only** | Descriptor declares exactly 2 Finger collections. 3- and 4-finger gestures are unavailable. | Firmware is QMK-based and open; raising contact count is plausible if the sensor supports it — separate project. |
| **Private API fragility** | Stage 5's gesture fields are undocumented; can break across macOS releases. | Stages 0–4 use only public API and are stable. Degrade gracefully if Stage 5 breaks. |
| **Reclaiming the interface** | macOS may grab digitizer reports once they start flowing. | `kIOHIDOptionsTypeSeizeDevice`. Stage 1 will tell us. |
| **Mode persistence** | Input Mode likely resets on unplug/replug or firmware flash. | Re-arm on IOHIDManager device-matching callbacks. |
| **Cursor regression** | Flipping to PTP mode kills the working mouse path before Stage 3 lands. | Keep a kill switch that restores Input Mode 0; don't run the daemon at login until Stage 3 is solid. |

---

## Reference material

- Microsoft — *Windows Precision Touchpad* device requirements (report formats,
  Input Mode semantics, PTPHQA blob)
- Linux `drivers/hid/hid-multitouch.c` — reference PTP report parsing
- Apple — `IOHIDManager` / `IOKit/hid` headers; `CGEvent` / `CGEventSource`
- Mac Mouse Fix (GPL-3) — undocumented gesture CGEvent constants
- QMK — pointing device / digitizer feature, for any firmware-side changes
