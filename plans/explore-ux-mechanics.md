# Out the door — 0.0: explore UX mechanics

Dynalist: [0.0: explore ux mechanics](https://dynalist.io/d/g5I86fQUbuICU8XHqBP88Z0u#z=Y7jUaw4OeFc7FMudXFAqSeg_)
Repo: [ethangodt/planner-for-parents](https://github.com/ethangodt/planner-for-parents)

## Goal

Get started on the parent planner by building the two things everything else will
be iterated on top of:

1. **A single-day timeline** for iPhone portrait: pinch-zoomable, scrollable,
   rendering events as dominoes with a convincing but subtle sense of depth.
2. **A draw mechanic**: sloppy "L" strokes on the timeline are interpreted into
   crisp, grid-snapped events that rise up out of the timeline.

The product bet is that UX execution *is* the product — a collaborative planner
for worn-out parents has to feel frictionless and almost fun. So this task is not
"make it work"; it is "make it feel right, and make it cheap to keep tuning the
feel." Every look-and-feel number is a live parameter on the phone, not a
constant in code.

Timeline first, then draw. The draw mechanic is meaningless without a surface to
draw on, and the timeline is where the rendering and gesture foundations get
settled.

## Decisions at a glance

| Area | Decision |
|---|---|
| Platform | Native SwiftUI, iOS 18+, iPhone portrait only |
| Timeline surface | Truly flat. Depth lives in the tiles, via a *virtual angle* derived from screen position |
| Rendering | SwiftUI views + `.visualEffect`; UIKit scroll container; `Canvas` for strokes; small Metal `[[stitchable]]` shaders where they earn it. No 3D engine |
| Scrolling | Two-finger pan anywhere; one-finger pan in the left ~10% hour strip. Native momentum + rubber-band |
| Zoom | Pinch stretches the time axis around the focal point. Min: whole day fits. Max: ~1 hour fills the screen |
| Drawing | Always on: one finger on the timeline (outside the strip) draws |
| L semantics | Vertical run = time range; horizontal foot (either direction) = commit. Vertical may go up or down — L, ⅃, Γ, and mirrored Γ all count |
| Snapping | Zoom-dependent (matches the finest visible gridline: 5/15/30/60 min); edges magnetise to adjacent events; 5 min minimum |
| Recognition | Live ghost preview once the foot starts; commit on lift; retract foot to cancel |
| Overlap | Clip to the free gap overlapping the drawn range most, if ≥ 5 min; otherwise reject with a shake |
| Emergence | Slot-rise: a recessed slot opens, the stroke is absorbed into its outline, the tile rises out with a spring. Simple-rise fallback behind a switch |
| Failure | Stroke fizzles out in ~250 ms, no haptic |
| Haptics | Light tick per snap change during preview; firm tap when a tile lands |
| Tiles | Auto-named ("Event 3"), colour from a small palette, duration label ("3h 45m") |
| State | In memory only. 3–4 sample events on launch; undo and reset |
| Look | Light, warm off-white surface |
| Tuning | Hidden on-device tuning panel exposing every look/feel parameter, with named presets |

## Background: how we got to "flat"

The first plan was a genuinely tilted 3D plane rendered with a custom Metal
engine. Prototyping a curved variant (surface angle blending linearly from +θ at
the top of the screen to −θ at the bottom, flat in the middle) turned up the
settings that actually felt good: **±15° with a very distant camera (perspective
≈ 2000) and 5 pt tiles.**

Those settings look flat because they essentially are. At ±15° over half the
screen (~272 pt) the "drum" has a radius of ~1,040 pt, so its edges curve only
~35 pt away; at a camera distance of 2000 that's a ~1.7% shrink — invisible. What
the eye picks up instead is the *surface normals* rotating 30° top to bottom:
tile brightness shifts a few percent, a 1–2 pt edge sliver fades in and out, and
the gap between a tile and its shadow shifts as it scrolls. Moving a tile through
that gradient reads as "a solid object moving under a fixed light."

None of that needs a 3D scene. It reduces to one rule — **each tile gets a
virtual angle from its screen position, and that angle drives its lighting, edge
sliver, and shadow** — which runs fine on a flat SwiftUI layout. A flat-timeline
prototype built on that rule felt as good as the curved one, so the 3D engine is
parked. See ADR-0002.

## Architecture

### Layers

```
PlannerCore (local Swift package — pure logic, no UIKit/SwiftUI)
  TimeAxis        minutes ↔ content points, zoom (hour height), gridline levels
  Snapper         grid snap for current zoom, edge magnetism, min duration
  LRecognizer     stroke → .none / .preview(range) / .commit(range) / .reject
  OverlapResolver drawn range + existing events → clipped range or rejection
  DepthModel      screen y + params → angle, brightness, sliver, shadow geometry
  Tuning          Codable parameter struct + presets

App (SwiftUI + UIKit where needed)
  Model           @Observable DayStore: events, undo stack, sample seed
  Timeline        scroll container, hour strip, gridlines, now line, tile views
  Draw            stroke capture, stroke/ghost rendering, emergence animation
  TuningPanel     SwiftUI sheet bound to Tuning, preset management
  Shaders         .metal files for stroke glow and tile sheen
```

Everything that decides *what happens* lives in `PlannerCore` and is unit-tested
with `swift test` — no simulator needed. The app layer only decides *how it
looks*. This is also the hedge on rendering: if the flat illusion stops being
enough and the real curve comes back, only the app layer's drawing changes.

### Coordinate model

- Time is **minutes since midnight**, `0...1440`, as `Double`.
- Content y = `minutes / 60 × hourHeight`. `hourHeight` *is* zoom.
- Screen y = content y − scroll offset.
- Tile thickness, text size, and shadow sizes are in screen points and never
  scale with zoom — zoom stretches time, not the dominoes.
- Zoom range: min `hourHeight` = visible height / 24 (whole day on screen), max =
  visible height (one hour fills it). Both tunable.

### Rendering

- **Tiles** are SwiftUI views. `.visualEffect { content, proxy in … }` reads each
  tile's frame in the scroll container's coordinate space and applies the
  virtual-angle model — so each tile restyles itself from its own screen position
  every frame of a scroll, with no global redraw.
- **Scroll container** is a `UIScrollView` subclass wrapped in
  `UIViewRepresentable`, chosen for native momentum and rubber-banding. Its pan
  recogniser requires two touches, *except* when the touch begins inside the
  hour strip, where one touch is accepted. That gives one-finger strip scrolling
  with the same physics, instead of a hand-rolled momentum model.
- **Pinch** is a custom recogniser that changes `hourHeight` and adjusts the
  content offset so the minute under the focal point stays put. Not
  `UIScrollView` zooming — that scales content, which would scale the tiles.
- **Stroke, ghost, and slot** are drawn in a SwiftUI `Canvas` overlay in content
  coordinates (so they scroll with the timeline during auto-scroll).
- **Shaders** (`[[stitchable]]`, applied via `.layerEffect` / `.colorEffect`):
  stroke glow and optionally a tile sheen. Everything else is plain SwiftUI
  shapes and gradients.
- **Render on demand.** SwiftUI only re-renders what changes: nothing happens at
  idle except a once-a-minute now-line tick. Continuous work happens only during
  scroll, pinch, draw, and emergence springs.

### Virtual-angle depth model

These are the formulas from the prototype that felt right; `DepthModel`
implements them. `y` is screen y with `0` at the top, `H` the visible height.

**Angle**

```
θ(y) = θtop + (θbottom − θtop) · (y / H)        // linear by default; eased curve optional
```

**Top-face brightness** — the tile's top face gets a vertical gradient from
`b(θ(y_top))` to `b(θ(y_bottom))`. At θ = 0 a tile shows its true colour.

```
b(θ) = 1 + strength · (cos(θ − φ) − cos φ)      // φ = light angle from overhead
```

**Face shift and edge sliver** — the top face is displaced by the tile's depth
along the virtual normal:

```
Δ(y) = −depth · sin θ(y)
topFace = [y0 + Δ(y0), y1 + Δ(y1)]
```

- Near the top of the screen (θ > 0) the face shifts up and the **bottom edge**
  is exposed between `y1 + Δ(y1)` and `y1`. It is the unlit side:
  `edgeColor × (0.78 + 0.30 · max(0, sin(θ − φ)))`.
- Near the bottom (θ < 0) the face shifts down and the **top edge** is exposed
  between `y0` and `y0 + Δ(y0)`. It faces the light:
  `edgeColor × (0.95 + 0.25 · max(0, sin(φ − θ)))`.
- `edgeColor` is the palette's darker stop for that tile colour.

**Shadow** — cast from the tile's base, following the virtual angle at the tile's
centre:

```
shadowOffsetY = shadowHeight · tan(clamp(φ − θ_centre, ±1.3 rad))
shadowOffsetX = 0.45 · shadowHeight
```

with tunable blur and opacity.

**Motion response** — a smoothed scroll velocity `v` (exponential smoothing,
factor ≈ 0.18 per 60 Hz frame; normalise to pts/s in implementation) stretches the
shadow on the trailing side and softens it, then settles as momentum dies:

```
ext = min(40, motion · |v| · 2)      // prototype units: pts per 60 Hz frame
shadow extends by ext on the side opposite the direction of travel
blur += 0.3 · ext
```

**Default preset ("Screenshot")** — the values that felt right:

| Param | Value |
|---|---|
| Top angle θtop | 15° |
| Bottom angle θbottom | −15° |
| Light angle φ | 30° |
| Light strength | 0.5 |
| Tile depth | 5 pt |
| Shadow height | 5 pt |
| Shadow blur | 6 pt |
| Shadow opacity | 0.14 |
| Motion response | 0.8 |
| Hour height (initial zoom) | 62 pt |

Also ship "Subtle" (±3°, else the same), "Dramatic" (±30°, strength 1.2, depth
10, shadow 10/10/0.22, motion 1.6), and "No effect".

**Performance watch:** per-tile blurred shadows re-rendered at 120 Hz are the one
likely hot spot. If Instruments shows it, pre-render the shadow once per size as a
blurred image and stretch it, rather than blurring live.

**Tilt-shift light (toggle):** device pitch (CoreMotion) nudges φ by a tunable
amount. Off by default. When on: sample at a low rate, re-render only when the
change is perceptible, and stop sampling after a few seconds without touches.
This is the one feature that inherently keeps rendering, so it stays opt-in.

### Gestures

| Input | Where | Action |
|---|---|---|
| One-finger drag | Hour strip (left ~10%) | Scroll, with momentum |
| One-finger tap | Hour strip | Scroll to now |
| One-finger drag | Timeline, outside the strip | Draw (PR 2; no-op in PR 1) |
| Two-finger pan | Anywhere | Scroll, with momentum |
| Pinch | Anywhere | Zoom around the focal point |
| Three-finger tap | Anywhere | Open the tuning panel |

The hour strip is a slightly darker, slightly recessed tone so it reads as a
rail. Labels are compact (`7a`, `10p`) to fit it. Scrolling rubber-bands at
midnight on both ends.

### Timeline chrome

- Hour gridlines always; 30/15/5-minute lines fade in as zoom increases. The
  finest *visible* level is the snap interval.
- Now line: thin red line from the strip edge with a dot, from the real clock,
  updated once a minute.
- A small floating pill at the bottom: **undo** and **reset**, plus a gear that
  also opens the tuning panel (three-finger taps are awkward in the Simulator).
- Launch state: 3–4 sample events (e.g. school drop-off, work block, lunch,
  pickup + snacks), scrolled so the morning is in view.

### Draw mechanic

**Capture.** One-finger touches that begin on the timeline outside the strip are
captured as a stroke: timestamped points in content coordinates.

**Stroke look.** Tapered like the iOS keyboard swipe-to-type trail — thickest at
the fingertip, thinning toward the tail — with a soft glow via shader. It lies on
the timeline surface. Tunable: max/min width, taper curve, glow radius and
intensity, colour.

**Recognition** (`LRecognizer`, all in content coordinates, so zoom and scroll
don't distort the shape):

1. Resample to even spacing and simplify (Ramer–Douglas–Peucker).
2. Find the corner as the point of maximum deviation from the start→end chord.
3. **Vertical run** (start → corner): within ±25° of vertical, length ≥ a
   minimum. Up or down both valid.
4. **Foot** (corner → end): within ±30° of horizontal, length ≥ ~24 pt. Left or
   right both valid.
5. Time range = min/max y of the vertical run → minutes → snapped.

All thresholds are tunable. The recogniser runs continuously during the stroke:

- Once the foot passes its threshold → `.preview(range)`: a **ghost outline** of
  the snapped tile appears, and each change of snapped start/end fires a light
  haptic tick.
- If the foot retracts below the threshold → preview hides (cancel by pulling
  back).
- On lift: valid preview → `.commit`; anything else → `.reject` (fizzle).

**Snapping** (`Snapper`):

- Grid: snap interval = finest visible gridline at the current zoom (5/15/30/60).
- Edge magnetism: a start or end within the snap distance (tunable, ~12 pt) of an
  existing event's edge snaps exactly to it, so back-to-back events stack cleanly
  (the second L in the reference sketch).
- Minimum duration 5 minutes. Clamped to the day.

**Overlap** (`OverlapResolver`): if the snapped range intersects existing events,
take the free gap that overlaps the drawn range the most. Clip to it if it's
≥ 5 minutes; otherwise reject — the ghost shakes and the stroke fizzles.

**Auto-scroll.** While drawing, a finger within an edge zone (tunable, ~60 pt) of
the top or bottom scrolls the timeline, faster the closer it is. The stroke keeps
extending in content coordinates. Stops at midnight.

**Emergence — slot-rise** (on commit):

1. A recessed slot (dark inset rounded rect, inner-shadowed) opens at the snapped
   range.
2. The stroke is absorbed: its points contract onto the slot's outline (~180 ms).
3. The tile rises out of the slot: depth 0 → full, shadow 0 → full, brightness
   from slightly dark → normal, on a spring with a little overshoot.
4. The slot closes beneath it. Firm haptic as it lands.

**Simple-rise fallback** (switch in the tuning panel): no slot; the tile scales
up slightly while depth and shadow grow from zero. Built first, since slot-rise
extends it.

**Fizzle** (on reject): stroke dissipates in ~250 ms — shrink toward the tail and
fade. No haptic.

**Undo** removes the last created event (reverse animation: sink and fade).
**Reset** restores the sample events.

### Tuning panel

A SwiftUI sheet (three-finger tap or the gear), grouped into sections. Every
parameter is live — the timeline updates while the slider moves.

- **Depth:** top angle, bottom angle, angle curve (linear/eased), light angle,
  light strength, tile depth, corner radius, tilt-shift light (toggle + amount).
- **Shadow:** height, blur, opacity, x-offset factor, motion response, motion
  settle speed.
- **Timeline:** min/max zoom, strip width, strip tint, surface colour, gridline
  opacity, dark mode (toggle, for cheap experimentation only).
- **Stroke:** max/min width, taper, glow radius/intensity.
- **Recogniser:** vertical tolerance, foot tolerance, minimum foot length,
  minimum vertical length, snap distance, auto-scroll zone and max speed.
- **Emergence:** mode (slot/simple), spring response and damping, absorb
  duration, slot darkness, fizzle duration.
- **Presets:** built-ins above; save current as a named preset; load; delete;
  reset to defaults; **copy as JSON** (so tuned values can be pasted back and
  baked in as new defaults).

The current values and saved presets persist across launches (`UserDefaults`,
`Codable`). Events do not.

## Repository

`ethangodt/planner-for-parents` is empty — `main` has no commits. Local layout is
`~/_Projects/Software/planner-for-parents/` with the `planner-for-parents-main`
worktree and a `designs/` folder beside it (outside git) holding the reference
images.

**Bootstrap:** an initial commit on `main` (README, `.gitignore`) must be pushed
before feature branches can be opened as PRs against it. This is a direct push to
`main`; confirm with Ethan at implementation time.

```
planner-for-parents/
  project.yml                 XcodeGen spec; .xcodeproj is generated, not committed
  App/                        @main, root view
  Sources/
    Model/  Timeline/  Draw/  TuningPanel/  Shaders/
  Packages/PlannerCore/       local Swift package: logic + Tuning
    Sources/PlannerCore/
    Tests/PlannerCoreTests/   Swift Testing
  adr/
  README.md                   how to generate the project, run tests, set signing
```

XcodeGen keeps the project definition as reviewable text and lets it be edited
reliably without Xcode. Ethan sets a signing team once for device builds.

### Architectural decision records

As with other projects, record the decisions made here as ADRs in `adr/`,
written during setup — the reasoning in this plan is the raw material. Numbered
sequentially, never renumbered; reversals supersede rather than edit.

```
adr/
  0000-template.md
  0001-native-swiftui-ios-only.md
  0002-flat-timeline-virtual-angle-depth.md
  0003-always-on-drawing-gesture-model.md
  0004-in-memory-state-for-exploration.md
```

ADR-0002 should record the curved/3D exploration, why the flat illusion won, and
the signal that would reopen it: the illusion no longer being enough for an
effect we want (e.g. true occlusion or perspective), at which point a custom
Metal renderer is the path (not RealityKit — see the alternatives section).

## Milestones

### PR 1 — Foundation + timeline

- Bootstrap commit on `main` (after confirmation).
- XcodeGen project, `PlannerCore` package, ADRs, README.
- `TimeAxis`, `DepthModel`, `Tuning` + tests.
- Flat timeline: surface, hour strip with labels, fading sub-hour gridlines, now
  line, tap-strip-to-now.
- Scroll container: two-finger pan anywhere, one-finger pan in the strip,
  momentum, rubber-band.
- Pinch zoom around the focal point within the zoom range.
- Tile views with the full virtual-angle model: brightness gradient, edge
  slivers, angle-following shadows, motion response.
- Sample events, undo/reset pill (undo inert until PR 2 creates events).
- Tuning panel with the Depth, Shadow, and Timeline sections, presets, and JSON
  copy. Tilt-shift light toggle.

**Done when:** on a device, the timeline scrolls and zooms smoothly at 120 Hz,
the "Screenshot" preset reproduces the feel of the prototype, and every
parameter can be changed live from the panel.

### PR 2 — Draw mechanic

- `LRecognizer`, `Snapper`, `OverlapResolver` + tests (including all four L
  variants, sloppy strokes, retracted feet, overlaps, edge magnetism, clamping).
- Stroke capture and tapered, glowing stroke rendering.
- Live ghost preview with snap haptics.
- Auto-scroll while drawing.
- Commit → simple-rise, then slot-rise with absorption; mode switch.
- Fizzle on reject; shake on overlap rejection.
- Undo/reset wired to created events.
- Tuning panel: Stroke, Recogniser, and Emergence sections.

**Done when:** a sloppy L drawn anywhere on the timeline reliably produces a
crisp, snapped tile that rises out of the surface, back-to-back Ls stack exactly,
and non-Ls fizzle.

## Verification

- **Logic:** `swift test` in `PlannerCore` for everything that decides outcomes.
  Recogniser tests use recorded and synthetic strokes, including deliberately
  sloppy ones.
- **Correctness in the Simulator** (by Claude): build, launch, screenshot, and
  drive scripted touches — one-finger strip scroll, two-finger pan and pinch,
  drawn L paths — to confirm layout, snapping, and state.
- **Feel on device** (by Ethan): haptics, ProMotion, and real pinch don't exist
  in the Simulator. Feel is judged on the phone and tuned via the panel;
  preferred values come back as JSON and become new defaults.

## Alternatives considered

- **Tilted 3D plane / curved drum with a custom Metal renderer.** Prototyped.
  Genuinely nice, but the settings that felt best were visually flat, and the
  effect they produced is reproducible in 2D. Parked, not rejected.
- **RealityKit.** Works without AR on iOS 18, but its PBR look is fixed,
  stylised lighting has to be injected through `CustomMaterial`, and it doesn't
  offer clean render-only-when-dirty control — a battery problem for an app that
  is idle most of the time.
- **Expo / React Native + Skia.** Cross-platform, but a layer between us and the
  platform on the exact axis (gesture feel, haptics, lighting) this task is about.
- **Explicit draw mode or long-press to draw.** Both viable; always-on was chosen
  to test the most frictionless version first. The recogniser doesn't care what
  started the stroke, so these remain cheap variants.
- **Fixed 15-minute snapping.** Rejected for zoom-dependent snapping that matches
  what's visible.

## Out of scope

- Persisting events (everything resets on relaunch).
- Dates, multiple days, week views.
- Landscape, iPad, Android.
- Dark mode beyond the tuning toggle.
- Editing events: move, resize, delete (beyond undo/reset). That's its own
  mechanic — see 0.1, the tool wheel.
- Titles or any text entry.
- Collaboration, swim lanes, comments.
- Accessibility (VoiceOver, Dynamic Type) — a real obligation later; the
  `PlannerCore` / view split keeps it feasible.
- The true 3D curve.

## Open questions

- Does per-tile live shadow blur hold 120 Hz on older devices, or do we need the
  pre-rendered shadow path? (PR 1 answers with Instruments.)
- Is always-on drawing too eager in practice — do accidental one-finger touches
  create strokes? If so, try the long-press variant behind a tuning switch.
- Do tile titles need a minimum on-screen height before showing at small zoom?
  Decide on device.
