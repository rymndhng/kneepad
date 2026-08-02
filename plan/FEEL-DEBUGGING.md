# Pointer feel: open investigation

Resume notes. Stages 0–4 and 6 are done and working (see `README.md`); this
tracks the one unresolved problem.

## The symptom

The cursor keeps moving after the finger stops, while the finger is **still on
the pad**. Reported as "lingering deceleration — it should just stop."

Two observations that constrain everything:

- **It scales with `--pointer-gain`.** At 4–8 px/mm it is barely noticeable; at
  the default 20 it is obvious.
- **Mouse mode (touchd off) does not do it.** The firmware's own relative
  reports feel fine.

## Ruled out, with measurements

| Suspect | Evidence | Verdict |
|---|---|---|
| Our 1€ filter | `--no-smoothing` changes nothing | not it |
| Scroll momentum | finger never lifts | not it |
| Frame handler too slow | `--stats`: 0.17 ms mean, 0.48 ms p99 vs 6.5 ms budget | not it |
| WindowServer backlog | `pointer-latency`: 154 Hz posted, cursor settled in **0 ms** | not it |
| Low report rate | scan time advances 65 counts = 6.5 ms → **~154 Hz** | not it, better than Apple |
| All four transforms stacked | `--minimal` (everything off) still wrong | not it |

Four successive theories were wrong. Do not add a fifth without a measurement.

## Where the evidence points

The deceleration tail **is** in the raw absolute stream — both
`hid-stream --trace` captures show ~35–85 ms of decay after the finger stops,
roughly 1 mm of travel. Gain multiplies it. Mouse mode escapes it because the
firmware computes its own relative deltas there and we never see the absolute
data.

**Current hypothesis (untested):** the acceleration curve never attenuated slow
movement. The old factor was `1 + (max-1)·shaped/(1+shaped)`, which is bounded
**below by 1**, so slow motion — the tail included — passed at the full 20 px/mm.
macOS's own curve drops well under 1:1 at low speed, which is both why it feels
precise and why the tail is invisible in mouse mode.

### Uncommitted change implementing that

`PointerSynthesizer.Configuration` gained `minAcceleration` (default 0.2) and
the curve became a clamped power law:

```swift
let factor = min(maxAcceleration,
                 max(minAcceleration,
                     pow(speed / accelerationReference, accelerationCurve)))
```

`accelerationCurve` default moved 1.8 → 1.2. **Not yet tried on hardware.**

## Next steps

1. Try the new curve. A slow tail (~10 mm/s) should now be attenuated to
   ~0.2× instead of 1×, i.e. 4 px/mm rather than 20.
2. If that fixes it, retune `--pointer-gain` around the new curve, since gain
   now means "px/mm at `accelerationReference`" rather than a flat multiplier.
3. If it does not, the remaining route is **ZSA's QMK firmware** — turning the
   sensor's smoothing off at the source beats inverting it downstream. Lead
   compensation (`--lead`) is that inversion and is now independently
   controllable, but has not been shown to help.

## Tools built for this

```
hid-stream --trace                  raw CSV from the device, no processing
touchd --stats                      report rate, handler time vs frame budget
touchd --minimal                    strip every transform; prints the pipeline
touchd --minimal --lead 2.5         isolate lead compensation alone
pointer-latency                     post→cursor backlog, no trackpad needed
pointer-latency --observe           CSV of cursor deltas from ANY device
```

`pointer-latency --observe` is the unused one worth trying: record the same
fast-stop gesture on the **Magic Trackpad** and on the ZSA pad, and compare
deceleration profiles directly. That gives a ground truth for what "correct"
looks like instead of another hypothesis.

## Known broken

`touchd --stats` jitter lines are wrong — they pool samples across different
resting positions rather than measuring spread at one spot, hence the
nonsensical "9.16 mm" and "-0% noise removed". Ignore those two lines.

## Pipeline, for reference

```
device (~154 Hz, absolute, 0–2048 over 55 mm)
  → lead compensation      cancels the raw tail        (--lead, independent)
  → 1€ filter              removes sensor noise        (--no-filter)
  → acceleration           speed-dependent multiplier  (--no-accel)
  → gain                   px per mm                   (--pointer-gain)
  → CGEventPost
```

The stages are deliberately separable; `touchd` prints which are active at
startup. They were once bundled, and lead vs filter actively fight each other —
lead sharpens the stop, the filter re-smooths it.
