# Mitts of Mayhem — performance monitoring

Dynalist: [performance monitoring features](https://dynalist.io/d/g5I86fQUbuICU8XHqBP88Z0u#z=o1EeN3kPiVDy265oeebDWtFb)
(under [improve vision tracking implementation](https://dynalist.io/d/g5I86fQUbuICU8XHqBP88Z0u#z=D-unLpYB5uFnQwkspbnHlh5x))

Background: [input latency report](../reports/mitts-input-latency.md).

## Goal

Low latency is the characteristic this game lives or dies on, and nothing about
it has been measured end to end. The report estimates 100–200 ms today and
~35–55 ms for a tuned pipeline, but only the detectors' cost is an actual
measurement.

This task builds the instruments to measure it, runs the experiments, and ends
with an ADR that sets the app's latency budget.

**Capture only.** Nothing here makes the pipeline faster. The fixes — pose off
the puck's path, a low-lag filter, a faster camera, Unity at 60 — are follow-up
tasks, sized by what this one measures. Two of them appear here as *switches*
so their effect can be measured, not as decisions.

## What this rests on

- **Every sample already carries its capture time**, on the host clock
  (`CMSampleBuffer` presentation time from the capture session). Anything that
  reads the host clock — `CACurrentMediaTime()` in native code — can be
  subtracted from it exactly. That is the spine of the whole task.
- **The bridge (ADR-0003):** Swift writes the latest sample into a lock-guarded
  slot in the shim inside UnityFramework; Unity reads it once per frame. The
  struct exists in three hand-maintained copies with a size assert.
- **Unity sets no frame rate.** `Application.targetFrameRate` is never set,
  which on iOS means **30 fps**.
- **Detection runs in series on one queue:** colour (~2 ms), then pose
  (~18 ms), then smoothing, then the push. At 30 fps this fits the 33 ms frame;
  at 60 it would not.
- **Defend does not use pose.** The skeleton is only drawn in the tracking
  sandbox.

## The stages

Stamped per sample, all on the host clock:

| # | Stage | From → to | Where it is stamped |
|---|---|---|---|
| 1 | **Camera** | capture → delivered to the app | start of `TrackingProducer.handle` (the delegate runs on the vision queue) |
| 2 | **Colour** | delivered → colour done | after `ColorKeyDetector` |
| 3 | **Pose** | colour done → pose done | after `PoseDetector`; zero when pose is off |
| 4 | **Smooth + push** | pose done → pushed | just before `MoMTracking_PushSample` |
| 5 | **Wait for Unity** | pushed → first seen by Unity | `VisionTrackingSource.Poll` finds a new frame id |
| 6 | **Added delay** | first seen → handed to the game | the delay buffer (below); zero unless a delay is set |
| 7 | **Render** | handed to the game → frame submitted | end of the first Unity frame that used the sample |

**Code path total** = capture → frame submitted, the sum of 1–7.

Stage 1 is the only one that includes time before the app sees the frame
(exposure midpoint to readout, the ISP). It is measured, not estimated, because
the capture timestamp is the camera's own.

After the frame is submitted come the GPU, iOS compositing, HDMI and the TV.
Code cannot see those. The HUD shows **one separate, labelled estimate line** —
submitted + GPU time (`FrameTimingManager`) + half a refresh interval — and
keeps it **out** of the total. The real number comes from video (see
Experiments).

## Decisions

### Carrying the timestamps

- **The sample struct grows a timing block**: four doubles — `deliveredAt`,
  `colorDoneAt`, `poseDoneAt`, `pushedAt` — appended to the end of
  `MoMTrackingSample` in all three copies. 288 → **320** bytes, and the assert
  changes with it. Appending keeps every existing offset where it is.
- Swift switches its timing from `CFAbsoluteTimeGetCurrent()` to
  `CACurrentMediaTime()` so every stamp is on the same clock as capture.
- Unity reads the host clock through a new shim function, `MoMTracking_Now()`.
  In the editor, where the shim does not exist, a `LatencyClock` falls back to
  `Time.realtimeSinceStartupAsDouble`, and the mock source stamps its samples
  from the same clock so the editor HUD reads sensibly.

### Two more slots in the shim

Same pattern as the sample: plain structs, lock-guarded, a size assert in every
copy and a runtime size check from C#.

- **Controls** — Swift writes, Unity reads every frame. HUD on/off, Unity fps,
  added delay, blind mode, display test. A pull, not `sendMessage`: Unity picks
  up the current state whenever it starts, so there is no startup race and no
  name-addressed GameObject to keep alive.
- **Latency summary** — Unity writes, Swift reads. Per-stage mean / p95 / worst,
  the total, the estimate line, and the measured Unity and camera frame rates.
  This is how the phone shows the full chain.

### The HUD, on the TV

- A corner panel, drawn with IMGUI (`OnGUI`). Built-in font, no scene assets, so
  nothing to strip and nothing to regenerate. Created at runtime by a
  `[RuntimeInitializeOnLoadMethod]` and kept across scenes, so it works in
  Defend, the sandbox and the spike without touching `ProjectBootstrap`.
- One row per stage and the total: **mean, p95 and worst over the last 2 s**.
  The mean is where you usually are; p95 and worst are the hitches you feel.
- The total is coloured against a **provisional 40 ms code-path budget**, a
  serialized field, replaced by the ADR's number. Green under budget, amber
  within 25 % over, red beyond.
- The estimate line sits under the total, greyed, labelled `≈ on HDMI (est.)`.
- Also shown: Unity fps (measured), camera fps (measured), and the added delay.
- **On by default**, toggled from the phone, the toggle persisted.

### The HUD, on the phone

- Replaces the current one-line `fps / pose / colour` readout in Play mode with
  the same table as the TV, read from the latency summary.
- **Without Unity** (simulator, or before it starts) the phone computes the
  Swift stages 1–4 itself with the same 2 s window, and says Unity is absent.
- Stats are computed twice — C# for the TV, Swift for the Swift-only fallback —
  each small and unit-tested. Pushing all stats through one side would need
  either a ring buffer across the bridge or a round trip, and neither is worth
  it for a debug surface.

### Measurement levers

All on the phone, in a **Latency** section of Play mode:

- **Unity fps: 30 / 60.** Sets `Application.targetFrameRate`. Resets to 30 at
  launch.
- **Camera fps: 30 / 60 / 120**, offering only the rates the current 4:3 format
  family supports. Above 30, **pose is switched off**, because colour (~2 ms)
  fits every rate and pose (~18 ms) fits only 30. Defend does not use pose, so
  the game still plays. Resets to 30 at launch. Changing it reselects the
  format with the same rule as today (widest field of view, then fewest pixels,
  within the pixel budget) among formats that reach the rate.
- **Added delay: 0–200 ms** in 10 ms steps. Unity keeps the recent samples and
  hands the game the newest one whose capture time is at least N ms older than
  the newest capture. Keyed on capture time, so it is exact regardless of either
  frame rate, and it never touches detection. Lives in `TrackingSourceProvider`,
  so it applies to the mock source too and is testable in edit mode.
- **Blind mode.** The phone picks a delay at random from
  {0, 20, 40, 60, 80, 100, 150} ms and does not show it; the TV hides the
  added-delay row, and its total excludes it. Play, form an impression, tap
  **Reveal**, note it down by hand, tap **Next**. Nothing is recorded by the app.
- **Display test.** Pauses the game (`Time.timeScale = 0`) and covers the TV
  with a large host-clock readout in ms plus a block that flips between black
  and white every second. The phone shows the same clock, full width, at the
  same time. A photo of both gives **TV minus phone**. The phone's own panel
  adds ~8–17 ms, so the result is display + cable latency relative to the phone,
  not absolute — good for comparing TVs, Game Mode, cables.

### What is deliberately not here

- No CSV or on-device log. Numbers are read off the HUD and recorded by hand.
- No puck-before-obstacles priority. The per-stage split is what would justify
  it; the ADR records it as an option.
- No pipeline restructuring. Switching pose off at high camera rates is a
  measurement lever, not the fix. The fix — pose on its own track — is a
  follow-up.

## Experiments

Run in Release (Debug detectors are 22–30× slower; see `build.sh`).

1. **Formats.** Read the `[Camera]` startup log: the maximum frame rate of each
   4:3 ultra-wide format within the pixel budget. Decides whether 120 is on the
   table at all.
2. **Display.** Display test mode, photographed. TV Game Mode on and off; the
   same with any other screen available. Gives the display + cable share.
3. **End to end.** Film the puck and the TV in one shot at 240 fps from a second
   iPhone. Push the puck from rest; count frames from the puck's first movement
   to the cursor's first movement (~4.2 ms per frame). Ten pushes per
   configuration, report median and spread. Configurations: baseline (30/30),
   Unity 60, camera 60, camera 60 + Unity 60, camera 120 + Unity 60 if offered.
4. **HUD comparison.** For the same configurations, note the HUD's code-path
   mean / p95 / worst. The difference between (3) and the HUD total is the
   display side, and should agree with (2).
5. **Tolerance.** With the best configuration from (3), sweep the added delay
   with the slider to get a feel for the range, then do blind trials — several
   per level — noting impressions.

## The ADR

Written last, from the results. `adr/0012-latency-budget.md`, from the
template.

- **An end-to-end target** (puck motion to light on the TV) — what we design
  for.
- **A "still acceptable" ceiling** from the blind trials — where it stops being
  playable.
- **An allocation per stage** — camera, detection, smoothing, Unity, display —
  that later fix tasks are measured against.
- **Required TV setup** (Game Mode, and any other display conclusion).
- **The architecture it assumes.** Proposed as the hypothesis the experiments
  confirm or overturn: a **60 Hz system** — camera at 60, puck and blade
  detected every frame, pose at 30 on its own track, Unity at 60 in step with
  the display. Camera at 120 recorded as measured-and-adopted or
  measured-and-declined.
- **Options considered**, including puck and blade prioritised over obstacles.
- **The HUD's code-path budget** updated from 40 ms to the ADR's figure.

## Implementation steps

Each a commit or a few, in the mitts-of-mayhem repo on
`feat/performance-monitoring`.

1. **Host clock + timing block.** `MoMTracking_Now`; the four timing doubles in
   all three struct copies; asserts at 320; Swift stamps on
   `CACurrentMediaTime()`.
2. **Controls and summary slots.** Structs in all copies, shim functions,
   simulator stubs in `UnityBridge.m`, runtime size checks in C#.
3. **Unity: `LatencyClock`, delay buffer, stats.** `LatencyStats` (2 s window,
   mean / p95 / worst) and the delay buffer in `TrackingSourceProvider`, both
   covered by edit-mode tests. Mock source stamps from `LatencyClock`.
4. **Unity: `LatencyLab`.** Runtime-created, persistent. Reads controls each
   frame (fps, delay, blind, display test), records per-sample stage times,
   stamps frame submit at the end of rendering, publishes the summary, draws the
   HUD and the display test. `enableFrameTimingStats` on in the iOS player
   settings for GPU time.
5. **Swift: camera frame rate.** `CameraFrameSource` reports supported rates and
   reconfigures on request; `TrackingProducer` skips pose above 30 and stamps
   each stage.
6. **Swift: phone UI.** Latency section — stage table, HUD toggle (persisted),
   Unity fps, camera fps, delay slider, blind mode, display test clock. Swift
   fallback stats for stages 1–4, unit-tested.
7. **Build to device**, check the HUD appears on the TV and phone, and every
   lever changes what it should.
8. **Run the experiments with Ethan; write the ADR; update the HUD budget.**

## Verification

- Swift unit tests (`SpikeTests`) for the rolling stats.
- Unity edit-mode tests for the stats and the delay buffer (ordering, exact
  selection by capture time, delay of zero, delay longer than the buffer).
- Device: the layout check logs agreement at the new sizes for all three
  structs; HUD visible on both screens; Unity fps and camera fps levers move the
  measured rates; the delay row tracks the slider; display test shows the same
  clock on both screens.

## Out of scope

- Pose on its own track, a low-lag filter, prediction, capture-time hit
  judgement — follow-ups, sized by the ADR.
- Locking exposure and white balance after calibration.
- Any recording or export of measurements.
