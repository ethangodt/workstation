# Mitts of Mayhem — first latency measurements

**Date:** 2026-09-25
**Dynalist:** [performance monitoring features](https://dynalist.io/d/g5I86fQUbuICU8XHqBP88Z0u#z=o1EeN3kPiVDy265oeebDWtFb)
**Builds on:** [input latency: targets and a budget](mitts-input-latency.md) · [plan](../plans/performance-monitoring.md)
**Code:** mitts-of-mayhem `feat/performance-monitoring` at `cdaed257` ([PR #4](https://github.com/ethangodt/mitts-of-mayhem/pull/4))
**Raw data:** [`data/mitts-latency-sweep-2026-09-25/`](data/mitts-latency-sweep-2026-09-25/)

> **Update:** the fixes recommended here were applied and measured, and one assumption here was wrong: display frame latency 2 → 1 made no difference; the classic display link was the fix. See [latency fixes, measured](mitts-latency-fixes.md).

## Question

With the latency instrumentation in place, where does the time actually go
between the camera and the TV, and which settings make it shortest?

## Short answer

- The earlier estimate of 100–200 ms was pessimistic about the code. From camera
  capture to Unity finishing the frame measured **66 ms** in the configuration
  the app shipped with, and **~51 ms** in the best stable one.
- Best stable configuration: **camera 60 fps, Unity 60 fps, TV 4K, lens
  correction on, pose off.**
- The biggest single fix found was a bug: Unity rendered at the **phone's 3×
  scale on a 1× TV**, i.e. 11520×6480 for a 4K TV, nine times the pixels. It could
  not hold 60 fps. Fixed, it holds 60 at 4K.
- Three large pieces remain, none of them settings:
  1. **Camera, ~32 ms** from the capture timestamp to the frame reaching the app.
     It does not change with frame rate or lens correction.
  2. **Wait for Unity, 2–29 ms**, set by how the camera's and the display's clocks
     happen to line up rather than by anything configured.
  3. **Display frame latency.** Unity's `CAMetalDisplayLink` is created with
     `preferredFrameLatency = 2`: each frame is scheduled two refreshes after it
     starts. That time falls after "frame submitted" and is in none of the numbers
     below.

## Setup

- iPhone 15 Pro Max, ultra-wide lens, 4:3 1024×768, 101° FOV. That lens offers
  30 and 60 fps in 4:3; no 120.
- TV over USB-C → HDMI, reported by iOS as 3840×2160 at **60 Hz**. It offers
  modes from 640×480 up to 4096×2160.
- Release build. Ethan stickhandling on the mat throughout; the Defend game running.
- Levers driven from the Mac (`RemoteLevers`: a `control.json` copied into the
  app's Documents with `devicectl`). The app logged one `[Metrics]` line a second.

## What the numbers are

Every stage is on the host clock and measured per sample. See the plan for exact
definitions.

| Stage | From → to |
|---|---|
| camera | capture timestamp → frame reaches the app |
| colour | colour detection (puck, blade, obstacles) |
| pose | body pose; 0 when off |
| wait | sample pushed → Unity first sees it |
| render | Unity has it → end of that Unity frame (CPU) |
| **total** | capture → end of Unity frame. **The code path.** |
| est | total + GPU time + half a 60 Hz refresh. An estimate, not a measurement |

**Not in total:** the wait *before* capture (the next camera frame: on average
half a frame, so ~17 ms at 30 fps and ~8 ms at 60), the GPU, the display-link
frame latency, HDMI and the TV. Those need the video test from the plan.

Each figure below is the median of per-second summaries over ~24 s, after
dropping the first 6 s of each configuration. Mean over each 2 s window, except
the p95 column.

## Results

| Configuration (camera / Unity / TV / notes) | Unity fps | camera | colour | pose | wait | render | **total** | total p95 |
|---|---|---|---|---|---|---|---|---|
| 30 / 30 / 4K (as shipped) | 30.0 | 31.2 | 3.9 | — | **28.9** | 1.8 | **65.8** | 66.2 |
| 30 / 60 / 4K | 60.0 | 31.3 | 3.8 | — | 13.7 | 1.5 | 50.3 | 51.4 |
| 60 / 30 / 4K | 30.0 | 32.7 | 2.7 | — | 2.2 | 1.3 | 39.0 | 41.2 |
| **60 / 60 / 4K** | **60.0** | 32.7 | 2.8 | — | 13.6 | 1.2 | **51.0** | 52.2 |
| 60 / 60 / 4K, lens correction off | 60.0 | 33.3 | 2.5 | — | 11.9 | 1.5 | 49.3 | 49.8 |
| 60 / 60 / 1080p, lens correction off | 58.5 | 34.4 | 2.2 | — | 2.9 | 1.1 | 40.8 | 45.8 |
| 60 / 60 / 1080p | 54.9 | 33.7 | 2.6 | — | 5.7 | 1.3 | 42.3 | 53.9 |
| 30 / 60 / 1080p | 55.5 | 33.2 | 3.5 | — | 5.3 | 1.3 | 43.5 | 52.0 |
| 30 / 60 / 1080p, **pose on** | 60.0 | 30.0 | 2.4 | **14.8** | 5.8 | 1.1 | 54.0 | 54.3 |
| 30 / 30 / 4K (repeat, end of sweep) | 30.0 | 31.4 | 3.9 | — | 29.9 | 1.6 | 66.3 | 66.7 |

The repeat at the end matches the start within 1 ms: the method is reproducible
over at least five minutes of play.

Before the scale fix, the same phone at Unity 60 / 4K measured **40 fps**
(asked for 60). Camera 60 fps was confirmed delivered (`[Timing] 60.0 fps`) in
an earlier manual session, `manual-session-1434.log`.

## Findings

### 1. Unity was rendering 9× the TV's pixels

Unity creates its view with the phone's content scale (3.0) and nothing changes
it when the host app moves the view onto the TV, a 1× screen. For a 3840×2160 TV
that is an 11520×6480 HDR render, downsampled by the compositor. At Unity 60 it
ran at 40 fps. Matching the view's scale to the TV (`[External] Unity view scale
3.0 -> 1.0`) gives a steady 60 at 4K.

### 2. 1080p output does not help once the scale is right

At 1080p Unity measured 55–58 fps, against a steady 60 at 4K, with a worse p95.
The lower totals in the 1080p rows come from the wait stage (finding 3), not
from rendering: render is ~1.2 ms either way. **Stay at 4K.** The TV's own
upscaler would be one more stage with unknown latency.

### 3. "Wait for Unity" is timing alignment, not configuration

The camera and the display run on independent clocks. Each new sample lands at
a fixed but arbitrary point in Unity's frame, and waits for the next frame to be
picked up. That is why:

- 30/30 waited **29 ms**: samples landed just after Unity read, almost a whole
  frame early.
- 60/30 waited **2 ms**: a fresh sample happened to land just before each read.
- 60/60 waited **14 ms**, while 60/60 at 1080p waited 3–6 ms, because the mode
  change shifted the alignment.

The alignment is set anew each launch and each mode change, so no single row is
the lasting value of a configuration. What a configuration does fix is the
**ceiling**: up to 33 ms at Unity 30, up to 17 ms at Unity 60. That is the
reason to run Unity at 60, even though 60/30 happened to measure lowest.

**Fix (code):** have Unity pick the sample up as late as it can rather than at
the start of its frame, or wait briefly at the start of the frame for a sample
that is about to arrive.

### 4. The camera stage is a fixed ~32 ms

- 30 fps: 31 ms. 60 fps: 33 ms. Lens correction off: +0.5 ms, i.e. no effect.
- So this is neither the frame interval nor distortion correction. The likeliest
  contents are **exposure** (if the timestamp marks the start of exposure) plus
  sensor readout and the ISP.
- Camera 60 still pays off, just before the timestamp, where this stage cannot
  see it: the wait for the next frame halves, from ~17 ms to ~8 ms on average.

**Next measurement:** cap the exposure time (e.g. 4 ms, which needs good light)
and see whether this stage falls by the difference.

### 5. Pose costs ~15 ms on the puck's path

With pose on, the pose stage measured 14.8 ms and the total rose by ~10 ms at
30 fps. Pose runs in series before the sample is pushed. Defend does not use it.
**Keep it off** until pose runs on its own track.

### 6. Colour detection is cheap

2.2–3.9 ms at 1024×768, a little less at 60 fps. Not worth optimising, and no
reason to prioritise puck and blade over obstacles.

### 7. Display frame latency is 2 (not yet measured)

The log shows `CAMetalDisplayLink created`, and the Unity export creates it with
`preferredFrameLatency = 2`. Each frame is therefore presented about two
refreshes after its callback, ~33 ms at 60 Hz. This happens after "frame
submitted", so it is in none of the numbers above. Setting it to 1 should save
about one refresh (~17 ms) at the cost of less slack for the GPU. Unity's CPU
frame is ~1–2 ms here, so there is plenty.

## Where that leaves the end-to-end estimate

For 60 / 60 / 4K, pose off:

| Piece | ms | Source |
|---|---|---|
| Wait for the next camera frame | ~8 | half of 16.7 ms, not measured |
| Capture → app | ~33 | measured |
| Colour + push | ~3 | measured |
| Wait for Unity | 2–14 | measured; alignment-dependent |
| Unity frame | ~1–2 | measured |
| Display link, frame latency 2 | ~17–33 | from config, not measured |
| HDMI + TV | ? | needs the video test |
| **Total, excluding the TV** | **~65–95** | |

## Recommendations

Settings, applied now:
**camera 60, Unity 60, TV 4K, lens correction on, pose off.**

Code fixes, in order of expected gain:

1. **Display frame latency 2 → 1.** ~17 ms.
2. **Pick up the freshest sample** at the start of Unity's frame, waiting a few
   ms for one that is about to land. Up to ~14 ms at 60/60.
3. **A low-lag filter instead of the EMA.** The stabilizer's EMA (0.5) trails a
   moving puck by about one sample. That lag does not appear in any stage timing
   above but is felt.
4. **Cap exposure** if the measurement in finding 4 shows exposure is in the
   camera stage.
5. **Make the fast configuration the default.** The app still starts at 30/30.

## Re-examining this data

Everything needed is in [`data/mitts-latency-sweep-2026-09-25/`](data/mitts-latency-sweep-2026-09-25/):

| File | What |
|---|---|
| `metrics.log` | Every `[Metrics]` line from the sweep session: one per second, JSON after the tag, with the label, lever state, TV Hz, Unity's per-stage `[mean, p95, worst]`, and the phone's own stats |
| `events.log` | Lever changes as applied: camera format, output mode, Unity target fps, lens correction, render size |
| `manual-session-1434.log` | The earlier manual session: camera 30 → 60, Unity at 40 fps before the scale fix |
| `configs.txt` | The sweep, one configuration per line |
| `sweep.sh` | Applies each configuration to the phone and holds it |
| `analyze.py` | Produces `summary.txt` from `metrics.log` |
| `summary.txt` | The table above, as printed |

To recompute the summary:

```
python3 analyze.py metrics.log configs.txt
```

To rerun the sweep (phone on USB, app built from the commit above, TV connected):

```
xcrun devicectl device process launch --device <id> --terminate-existing --console \
  -e '{"OS_ACTIVITY_DT_MODE":"enable"}' com.ethangodt.mittsspike > sweep.log &
./sweep.sh configs.txt
grep '^20.*\[Metrics\]' sweep.log > metrics.log
python3 analyze.py metrics.log configs.txt
```
