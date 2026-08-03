# Pointer feel: how it was settled

Closed. Kept because the wrong turns are more useful than the answer, and
because several of them look correct enough to be tried again.

## The symptom

The cursor kept moving after the finger stopped, while the finger was **still
on the pad** — "lingering deceleration; it should just stop." Later refined to
jerkiness during movement, which turned out to be a separate, self-inflicted
problem.

## The cause

The trackpad firmware low-passes position before reporting it. When a finger
stops, reports keep arriving for another 35–85 ms, decaying geometrically —
roughly 1 mm of travel the finger never made, which `gain` then multiplies.

Mouse mode escapes it because the firmware computes its own relative deltas
there and the absolute stream is never exposed.

## Ruled out, with measurements

| Suspect | Evidence |
|---|---|
| Our 1€ filter | disabling it changed nothing |
| Scroll momentum | finger never lifts |
| Frame handler too slow | `--stats`: 0.17 ms mean, 0.48 ms p99 vs a 6.5 ms budget |
| WindowServer backlog | `pointer-latency`: 154 Hz posted, cursor settled in 0 ms |
| Low report rate | scan time advances 65 counts = 6.5 ms → ~154 Hz, better than Apple |
| Every transform stacked | `--minimal` still wrong |

## What fixed it

`TouchEvents/StopGate.swift`. It drops the tail instead of trying to transform
it, keyed to three things that separate a tail from a finger: it only follows
fast movement, it only decelerates, and it never recovers.

Cost: the tail carries real displacement (the firmware's filter catching up), so
dropping it lands the cursor slightly short of where the finger pointed. That
proved imperceptible in use; the alternative — lead compensation, which moves
the displacement earlier instead of discarding it — did not.

## Four wrong theories, and what each was worth

1. **Our own filtering.** Disabling it changed nothing. Cheap to test, tested
   first, correct order.
2. **Downstream backlog** — that we were posting faster than the WindowServer
   could consume. Measured at 0 ms. `pointer-latency` was built for this and is
   still the right tool if the question ever returns.
3. **The acceleration curve never attenuating slow movement.** Led to adding a
   `minAcceleration` floor of 0.2, which did suppress the tail — by attenuating
   the entire aiming range. Reported as "too slow at low speeds, too fast at
   high". The floor survives at 0.6; the reasoning behind 0.2 did not.
4. **A sub-1 curve exponent being required for a flat mid-range.** Stated in a
   comment and a test, and false. The flat span is `reference × floor^(1/curve)`
   — set by the floor and the reference, not the exponent. The shipped curve is
   1.1 and its flat span is *wider* than 0.6's was.

## Two mechanisms deleted after being built

Full write-up in `README.md`. Briefly:

- **The 1€ filter** targeted noise that does not exist here — one sensor step is
  under 0.2 px at working gain — on a signal the firmware had already filtered.
  My `settleGain` addition made it worse, flickering smoothing on and off as
  the error crossed a deadband.
- **Lead compensation** is the exact algebraic inverse of the firmware's IIR and
  should have been the principled fix. Every value the arithmetic supported
  (≥1) produced visible noise or overshoot; the only comfortable value, 0.25,
  advances motion by 1.6 ms against a 6.5 ms frame. Being off by 10× from an
  exact inverse means the model does not hold.

## The pattern worth remembering

Three of the four wrong theories were *additions* — a filter, a settle term, a
compensator — each defended by arithmetic that was internally correct and
empirically irrelevant. Every correction came from someone using the device.

Measure that the thing a stage targets is large enough to see in the output
before adding the stage.

## Settled values

```
--pointer-gain 12 --accel-ref 170 --accel-min 0.6 --accel-max 3.2 --accel-curve 1.1
```

All found by hand. Note they are denominated in the descriptor's inflated
millimetre — see the surface-calibration TODO in `README.md`.

The reference moved 260 → 170 to shrink the flat zone from 163 to 107 mm/s.
A wide flat zone means a stroke must be genuinely fast before it is amplified
at all, and **vertical strokes rarely are**: a finger flexes over far less
distance than it sweeps sideways, so up-and-down movement sat inside the flat
zone almost always and the pad felt like hard work in that axis. The pad is
square, the screen is not, which makes it worse — 2560 px across 25 mm needs
102 px/mm to cross in one stroke, against Apple's 20, where the pad's aspect
ratio nearly matches the screen's and uniform gain simply works.

Shrinking the zone helps every direction and vertical most. An anisotropic
vertical gain would target it more precisely, but it bends diagonals — a 45°
finger movement stops producing 45° cursor movement — so it was not added.

## Pipeline

```
device (~154 Hz, absolute, 0–2048 over a claimed 55 mm)
  → stop gate              drops the deceleration tail (--no-stop-gate)
  → acceleration           speed-dependent multiplier  (--no-accel)
  → gain                   px per mm                   (--pointer-gain)
  → CGEventPost
```

Contact positions reach the recognizers exactly as the device reports them.

## Tools

```
hid-stream --trace          raw CSV from the device, no processing
touchd --stats              report rate, handler time vs frame budget
touchd --minimal            strip every transform; prints the pipeline
pointer-latency             post→cursor backlog, no trackpad needed
pointer-latency --observe   CSV of cursor deltas from ANY device
```

`pointer-latency --observe` was never used and is still the best idea here:
record the same fast-stop gesture on a Magic Trackpad and on this pad, and
compare deceleration profiles directly. Ground truth beats another hypothesis.

## Known broken

`touchd --stats` jitter lines pool samples across different resting positions
rather than measuring spread at one spot, so they report nonsense. Ignore them.
