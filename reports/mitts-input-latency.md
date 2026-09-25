# Mitts of Mayhem — input latency: targets and a budget

**Date:** 2026-09-25
**Dynalist:** [performance monitoring features](https://dynalist.io/d/g5I86fQUbuICU8XHqBP88Z0u#z=o1EeN3kPiVDy265oeebDWtFb)
(under [improve vision tracking implementation](https://dynalist.io/d/g5I86fQUbuICU8XHqBP88Z0u#z=D-unLpYB5uFnQwkspbnHlh5x))

## Question

The game puts a real puck on the mat and its cursor on the TV. How fast does the
path from one to the other need to be, what do game developers aim for, and is
something like 15 ms reachable?

## Short answer

- **15 ms end to end is custom VR hardware territory**, and not reachable with a
  camera and a TV: at 30 fps the gap between camera frames is already 33 ms.
- **Tentative target under ~50 ms** motion-to-photon for the cursor to feel attached to the
  puck. 50–80 ms is acceptable; past ~100 ms it feels floaty.
- Today is **estimated at 100–200 ms**. A tuned pipeline should land around
  **35–55 ms**. Almost none of the saving is in detection — it is the camera's
  frame rate, how the pipeline orders its work, smoothing, and the display.

## What the numbers are

Only the processing stage has been measured on the phone. Camera and display
figures are typical ranges for this class of hardware. Industry figures are from
published measurements (Digital Foundry, NVIDIA's latency research), quoted from
memory — approximate, not cited to the millisecond. Nothing end to end has been
measured yet; that is the next step.

## What the industry targets

Input to light on screen, end to end:

| Context | Typical | Notes |
|---|---|---|
| VR head tracking | **< 20 ms** (target) | Dedicated hardware; above this, motion sickness |
| Competitive PC — Valorant, CS on 240 Hz+ monitors with NVIDIA Reflex | **~20–40 ms** | Everything tuned: high frame rate, fast monitor, no queued frames |
| Ordinary PC gaming | ~50–70 ms | |
| Console at 60 fps | ~50–90 ms | Includes the TV; Game Mode matters a lot |
| Console at 30 fps | ~90–150 ms | Many big releases live here and feel fine to most players |
| League of Legends | ~20–40 ms local, **plus 30–60 ms ping** | Players tolerate 60–100 ms before an action registers |

Two things about perception decide where this game belongs:

- **Direct versus indirect.** Dragging something under a finger on glass, people
  notice single-digit milliseconds. Controlling something on another screen — a
  mouse, a controller, a puck driving a cursor on a TV — tolerates much more.
  This game is indirect.
- **Hearing versus seeing.** A musician feels ~10 ms of monitoring latency, but
  hearing is far more timing-sensitive than sight. The visual equivalent of
  "immediate" is roughly 40–60 ms.

## Where the time goes today

Stages in the order a frame travels them:

| Stage | Today | Source |
|---|---|---|
| Exposure, plus waiting for the next frame (30 fps, auto exposure) | 15–35 ms | typical |
| Sensor readout and image processor, handoff to the app | 10–30 ms | typical, ~1 frame |
| Colour detection (puck, blade, obstacles) | 1–2 ms | measured, simulator |
| Body pose | ~18 ms | measured, phone |
| **Puck waits for pose to finish** before the sample is sent | **~18 ms** | pipeline ordering |
| **Smoothing lag** — the position average trails a moving puck | **~33 ms** | ~1 frame at 30 fps |
| Unity picks up the latest sample | 0–1 Unity frame | polling |
| Unity render, iOS compositing, HDMI | 1–2 frames | typical |
| TV processing | 10–100+ ms | depends heavily on the TV and Game Mode |
| **Total** | **~100–200 ms** | estimate |

Two of the biggest items are not hardware at all. Everything in a frame runs in
sequence and is sent once, so the puck — ready after ~2 ms — waits ~18 ms for
pose. And the smoothing that steadies positions lags about a frame behind a
moving puck.

## Why 15 ms is out of reach

- **The camera.** At 30 fps a movement can wait up to 33 ms just to be in a
  frame; even at 120 fps, exposure, readout and the image processor take the
  better part of 15 ms on their own.
- **The display.** A 60 Hz screen takes up to 16.7 ms to draw one frame. TVs add
  10–20 ms in Game Mode and 50–100+ ms outside it. The iPhone's HDMI output is
  probably 60 Hz — worth confirming.

Hitting 15 ms would take what VR headsets do: dedicated capture and display
hardware, not a phone and a TV.

## A realistic fast budget

| Stage | Today | Tuned | How |
|---|---|---|---|
| Frame rate and exposure | 15–35 ms | **~5–8 ms** | 120 fps, short exposure, bright light |
| Readout and image processor | 10–30 ms | **~8 ms** | ~1 frame, but frames are shorter at 120 fps |
| Detection | ~20 ms | **~2 ms** | Send the puck as soon as colour detection finishes; pose on its own track at its own rate |
| Smoothing | ~33 ms | **~0–5 ms** | A low-lag filter instead of a plain average |
| Unity pick-up and render | 1–2 frames | **~10–17 ms** | Read the sample just before drawing, 60 fps, no queued frames |
| TV or monitor | 10–100+ ms | **~5–15 ms** | Game Mode TV or a gaming monitor |
| **Total** | **~100–200 ms** | **~35–55 ms** | |

Colour detection is already negligible and cheap enough to run at 120 fps;
body pose (~18 ms) can stay at 30 fps without holding the puck up. Whether the
ultra-wide lens offers a 4:3 format at 120 fps is open — the app already logs
every format's maximum frame rate at startup, so one device run answers it.

Locking exposure and white balance after calibrating also matters here: it
allows the short exposures, and it stops the camera's automatic adjustments from
shifting colours out from under the colour calibration.

## Game-design tricks for what is left

- **Judge by capture time, not display time.** Every sample carries the time its
  frame was captured. Hits and collisions can be decided on where the puck
  actually was then, so display lag never makes the game unfair — the same idea
  as a rhythm game's offset calibration.
- **Predict, carefully.** Games project fast-moving things slightly ahead to hide
  display lag. Stickhandling is full of sudden direction changes, so prediction
  has to stay short — about one frame — or the cursor overshoots every deke.

## Recommended next steps

In order:

1. **Measure before changing anything.** Timestamp each stage — capture, arrival,
   detection done, sent, read by Unity, presented — and film the puck and the TV
   together at 240 fps for true motion-to-photon. This is the performance
   monitoring task.
2. **Take pose off the puck's path**, so the puck is sent ~18 ms sooner.
3. **Replace the smoothing with a low-lag filter**, or predict to the moment of
   drawing using the capture timestamps: ~30 ms.
4. **Capture at 120 fps for colour detection**, with exposure and white balance
   locked after calibrating.
5. **Tune the display end:** TV Game Mode (often the single biggest win), Unity at
   60 fps, minimal frame queueing.
