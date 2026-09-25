# Mitts of Mayhem — latency fixes, measured

**Date:** 2026-09-25
**Dynalist:** [performance monitoring features](https://dynalist.io/d/g5I86fQUbuICU8XHqBP88Z0u#z=o1EeN3kPiVDy265oeebDWtFb)
**Follows:** [first latency measurements](mitts-latency-sweep.md), which set out the stages and the method
**Code:** mitts-of-mayhem `feat/performance-monitoring` at `3f028783` ([PR #4](https://github.com/ethangodt/mitts-of-mayhem/pull/4))
**Raw data:** [`data/mitts-latency-fixes-2026-09-25/`](data/mitts-latency-fixes-2026-09-25/)

## Short answer

What code can see, capture → frame submitted, went from **66 ms** as shipped to
**~35 ms**. With the display link now reporting when each frame is scheduled to
reach the display, capture → scheduled scan-out is **~50 ms**. As shipped, that
figure was about **97 ms** (66 plus the ~31 ms the Metal display link was found
to add).

Counting the parts no code can see (the wait for the next camera frame, the
exposure itself, and the smoothing's lag), the estimated end to end, before
HDMI and the TV, went from **~155 ms to ~65 ms**.

| Fix | Saved | How it was established |
|---|---|---|
| Unity rendered at the phone's 3× scale on a 1× TV | Unity 40 → 60 fps at 4K | measured |
| Camera 30 → 60 fps | ~8 ms on average, before capture | frame interval; invisible to the HUD |
| Unity 30 → 60 fps | caps the wait at 17 ms, down from 33 | measured |
| Pose off the puck's path | ~15 ms | measured |
| **Classic display link instead of CAMetalDisplayLink** | **~15 ms** (submit → scan-out 30 → 15) | measured |
| **Fresh-sample wait, bounded by the frame deadline** | **~5–9 ms** (wait 8–12.5 → 3.5–4) | measured |
| Exposure capped at 4 ms (was 16.3 auto) | ~6 ms, plus less motion blur | inferred; see finding 3 |
| One Euro smoothing instead of an EMA of 0.5 | ~one sample of lag when moving (17 ms at 60 fps) | unit-tested; invisible to the HUD |

All of these are now the app's defaults: camera 60, Unity 60, TV 4K, pose off,
lens correction on, One Euro smoothing, exposure cap 4 ms, fresh wait 14 ms
(deadline-bounded), classic display link.

## Method

As in the first report. Each lever was driven from the Mac while Ethan played,
and the app logged per-second `[Metrics]`. Each figure is the median of
per-second summaries after a 6 s settle. New in these runs:

- **present:** frame submitted → the time the display link says the frame
  will reach the display (`targetPresentationTimestamp` on CAMetalDisplayLink,
  `targetTimestamp` on CADisplayLink), recorded by `MoMAppController`.
- **to HDMI:** capture → that same scheduled time. It replaces the old
  estimate. It still stops at the phone's output: HDMI and the TV are not in it.
- Exposure time and ISO from the camera.
- `[FreshWait]` diagnostics, once a second: how often the fresh-sample wait
  engaged and caught a sample, and where samples landed relative to the start
  of Unity's frame.

## Findings

### 1. Frame latency 1 did nothing; the classic display link saves ~15 ms

The first report assumed Unity's `preferredFrameLatency = 2` was costing a
refresh. Setting it to 1 changed nothing: **present was 31.5 ms at both 1 and
2** (sweep 2). Unity's classic `CADisplayLink` path presents as soon as a frame
is rendered, and measured **~15 ms** (sweep 3, same settings):

| Display link | present | capture → scan-out |
|---|---|---|
| CAMetalDisplayLink, fresh wait off | 30.4 | 73.6 |
| CADisplayLink, fresh wait off | 15.6 | 50.9 |

Unity held 60 fps on both. Classic is now the default, and Metal is available
for comparison with `MOM_METAL_DISPLAY_LINK=1`.

Caveat: `targetTimestamp` is the refresh the frame is *aimed at*. A frame that
misses it lands one refresh later. Unity's frame is 1–2 ms of CPU, so misses
should be rare, but only the video test confirms it.

### 2. The wait for Unity is set by clock drift; a deadline-bounded wait fixes it

The camera and the display run on independent clocks. The `[FreshWait]` log
shows where samples land drifting through the whole frame within about 90 s
(e.g. 13 ms before the frame starts, then 2 ms after). So:

- **Any fixed setting is lucky or unlucky** depending on when it is measured.
  This is why the first report's 60/30 row looked best: it was a lucky moment,
  not a better configuration.
- **A short fixed budget (6 ms) only helped at some alignments.** At the others
  the next sample was further away than the budget.
- **The first implementation starved its own sample.** It polled the sample
  slot in a loop, and `os_unfair_lock` let the main thread keep re-taking the
  lock ahead of the camera thread's push. It now peeks at an atomic frame id,
  and once engaged it catches the sample essentially every time (engaged =
  caught in `sweep4-freshwait.log` and `sweep5-freshwait.log`).
- **The fix:** wait until the next sample lands, or until 5 ms before the frame
  is due on the display (from the display link), whichever comes first.

Sweep 5 alternated off and on, 45 s each:

| | wait | capture → submitted | capture → scan-out | Unity fps |
|---|---|---|---|---|
| off (1) | 12.5 | 43.0 | 58.3 | 60 |
| **on (1)** | **3.5** | **34.6** | **49.9** | 60 |
| off (2) | 8.1 | 41.1 | 56.0 | 60 |
| **on (2)** | **4.1** | **35.6** | **51.1** | 60 |

Present stayed at ~15 ms with the wait on, so it never cost a refresh. When it
doesn't engage, the sample had already landed ~2 ms before the frame started,
so there was nothing to wait for.

### 3. The capture timestamp is the end of exposure

Capping exposure barely moved the camera stage (capture → app) (sweep 2):

| Max exposure | actual | ISO | camera stage | puck seen |
|---|---|---|---|---|
| auto | 16.3 ms | ~1190 | 27.9–29.2 | 90–100% |
| 8 ms | 8.3 | 2294 | 28.7 | 92% |
| 4 ms | 4.0 | 3072 (max) | 27.8 | 100% |
| 2 ms | 2.0 | 3072 (max) | 27.1 | 98% |

A 14 ms shorter exposure moved the stage by ~2 ms, so the timestamp is at or
near the end of exposure, and the exposure happens *before* it, where no stage
can see it. The image's effective moment is mid-exposure, so capping at 4 ms
should move it ~6 ms closer to the timestamp, and reduce motion blur on a fast
puck. Colour detection held even with ISO at its maximum in this dim room
(`[Detect]` lines in `sweep2-events.log`). With more light the image will be
cleaner, and 2 ms becomes an option.

The ~28 ms camera stage itself (readout plus ISP) remains the largest single
piece, and neither frame rate, lens correction nor exposure changes it.

### 4. Smoothing lag is real and invisible to the HUD

The stabilizer's EMA at 0.5 trails a moving puck by about one sample. That lag
is in *where the puck is drawn*, not in *when*, so no timestamp shows it. The
One Euro filter (heavy smoothing when still, almost none when fast) is now the
default. In the unit tests, a puck moving at 2 widths/s trails by under a third
of the EMA's lag, and still-jitter is at least halved. On device this can only
be judged by feel, or by the video test. The EMA is one tap away for comparison.

## Where it stands

60 / 60 / 4K, all fixes on:

| Piece | ms | Source |
|---|---|---|
| Mid-exposure → capture timestamp | ~2 | half of 4 ms, inferred |
| Wait for the next camera frame | ~8 | half of 16.7, not measured |
| Camera stage (readout, ISP) | ~28 | measured |
| Colour + push | ~2–3 | measured |
| Wait for Unity | ~3.5–4 | measured |
| Unity frame | ~1 | measured |
| Submit → scheduled scan-out | ~15 | measured (display link) |
| Smoothing lag while moving | ~2–4 | unit tests |
| **Subtotal, before HDMI and TV** | **~62–66** | |
| HDMI + TV | ? | the video test |

## What's left

1. **The video test** (240 fps, puck and TV in one shot) is now the most useful
   measurement. It is the only way to get HDMI and the TV, to confirm that
   frames make their scheduled refresh, and to see the smoothing lag.
2. **The camera stage, ~28 ms.** The next place to look. Possibly a lower-level
   capture path, or a format the ISP handles with less processing.
3. **More light on the mat** would allow 2 ms exposures at a lower ISO.
4. **Pose on its own track**, if a future game needs the skeleton.
5. **The TV:** Game Mode on, which the display test can confirm.

## Re-examining this data

[`data/mitts-latency-fixes-2026-09-25/`](data/mitts-latency-fixes-2026-09-25/):

| Files | What |
|---|---|
| `sweep2-*` + `configs2.txt` | Each fix toggled against the new defaults: frame latency, fresh wait, exposure caps. `events.log` includes `[Detect]` lines for detection quality |
| `sweep3-metal-*`, `sweep3-classic-*` + `configs3*.txt` | The same fresh-wait settings on each display link, one launch each |
| `sweep4-*` + `configs4.txt` | Fresh wait off / 6 / 10 with `[FreshWait]` diagnostics |
| `sweep5-*` + `configs5.txt` | Final: deadline-bounded fresh wait, off and on, twice |
| `sweep2.sh`, `sweep3.sh` | Drive the levers from the Mac (`<label> <json>` per line) |
| `analyze.py` | As before, plus present, to-HDMI, exposure and ISO columns; skips corrupt lines |
| `summary.txt` | Every sweep's table as printed |

```
python3 analyze.py sweep5-metrics.log configs5.txt
```

Rerun a sweep: start the console capture as in the first report, then
`HOLD=45 ./sweep2.sh configs5.txt`. For the Metal display link, add
`"MOM_METAL_DISPLAY_LINK":"1"` to the launch environment.
