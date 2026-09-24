# Mitts of Mayhem — calibration mode

Dynalist: [new calibration mode](https://dynalist.io/d/g5I86fQUbuICU8XHqBP88Z0u#z=k9QiAuNkRUQPDuZ3RnM6wa9R)
(under [improve vision tracking implementation](https://dynalist.io/d/g5I86fQUbuICU8XHqBP88Z0u#z=D-unLpYB5uFnQwkspbnHlh5x))

## Goal

Replace the two hand-tuned detectors with **one way of finding everything the
game cares about** — puck, stick blade, and obstacles — driven by a calibration
the player makes on the phone, against their own surface and their own objects.

Today every threshold is a property of one basement: `PuckDetector` is a luma
threshold at Y > 185, `StickDetector` is a chroma box at Cb ≥ 145, Cr ≤ 125, and
both only work because the mat is black, the puck is white, and the tape is blue
(ADR-0006, ADR-0007). This plan removes those constants entirely. The player
points a crosshair at each object, and then tunes two tolerances on an XY pad
while watching everything that is *not* the object go black.

Second deliverable: a **`FrameSource` port** so the Xcode simulator can run the
phone UI — calibration included — against recorded footage, without a build to
the phone and a run to the pad for every change.

Out of this task, and belonging to sibling tasks under the same parent: rendering
obstacles in a new Unity game type, latency instrumentation, and lens
distortion / position stability.

## What this rests on

- **Every entity is a distinct colour.** The player chooses objects that differ
  from the surface and from each other. Nothing checks this; it is the player's
  job, and a future fix may make it the app's.
- **There is exactly one calibration.** It is used until it is updated. There
  are no profiles and **no defaults** — every player's colours are assumed to be
  unique, so the app ships knowing nothing about what a puck looks like.
- The phone is still tripod-mounted and still. Moving it invalidates the play
  area, as before; it no longer invalidates any detection constant.

## Decisions

### One colour rule for every entity

A pixel matches an entity if it is

> within **R** of the sampled colour on the colour wheel (CbCr distance), **and**
> within **B** of the sampled brightness (Y distance).

That is one detector, `ColorKeyDetector`, and one mask test, used identically for
puck, blade, and obstacles. It works directly on the capture's native
`420YpCbCr8BiPlanarFullRange` planes, so no per-pixel colour conversion.

Why both terms and not chroma alone: white and black are both near-neutral. The
current puck measured chroma 3–22 against the mat's 1–9 — nearly the same. With a
strongly coloured object, B opens wide and R does the work; with a white or black
one, R opens wide and B does the work. The same rule covers both, which is what
makes "any surface, any puck-like object" true instead of aspirational.

Two parameters are enough. A third would only be needed to separate two objects
of the same colour at different brightness, and the distinct-colour precondition
rules that out.

Rejected: HSV hue/saturation windows — a per-pixel conversion for no gain in
discrimination. Rejected: keeping `PuckDetector` and `StickDetector` with
calibratable configs — that is two ways, and a dark puck on a light mat breaks
the luma-only one outright.

### Colour finds candidates; shape picks the entity

The colour mask yields blobs. Which blob *is* the entity is decided by a fixed
per-entity selection rule, not calibrated and not exposed:

| Entity | Result | Selection |
|---|---|---|
| Puck | one | roundest qualifying blob |
| Blade | one | most elongated qualifying blob; its principal axis is `stickAngle` |
| Obstacles | up to 4 | every blob above a minimum size |

This is where the ADRs found their real wins: the white cutting board passed the
colour test and lost on shape; the bluish shadow passed the colour test and lost
on elongation. Shape is a detection concern, not a Unity one — Unity sees only
the result.

The area windows stop being measurements of one rig and become loose sanity
bounds (reject specks and reject half-the-frame). Circularity and elongation
floors carry over from the current detectors, since those are properties of pucks
and blades rather than of the room.

Confidence stays synthesized per ADR-0006 — a blob-quality score from shape
agreement — and stays not comparable to pose confidence.

### Obstacles

- **One calibration for the class.** Both shoes are the same colour; calibrate
  once.
- **Up to four** per frame, **detected every frame** — they get kicked.
- Each reported as **centre plus bounding box**.
- **No stabilization.** Raw detections each frame, sorted by position so the
  order is stable frame to frame. Obstacles barely move; matching identities
  across frames (so each could get a `SampleStabilizer`) is deferred until the
  game task shows flicker.
- **Slot order is not identity.** Slots are compacted and sorted, so a dropped,
  split, or bumped obstacle shifts the others. Consumers that need identity match
  detections against their own history — the game task does, against its
  baselines (see [improved-unity-game](improved-unity-game.md)).
- **Optional.** A player with no obstacles skips the step and everything else
  works.

### No calibration means no detection

An uncalibrated entity is not detected and reports confidence 0. If the puck or
the blade is uncalibrated, the phone opens straight into Calibrate. Obstacles
being uncalibrated is a normal state.

`PuckDetector.Config` / `StickDetector.Config` and their constants are deleted,
not kept as a fallback.

### Calibration is persisted as one value

A `Calibration: Codable` struct — per entity, the sampled colour (Y, Cb, Cr) and
the two tolerances R and B — saved to `UserDefaults` the same way `PlayArea` is,
held in memory behind the producer's lock, and read by the vision queue each
frame. Writes from the calibration UI take effect **on the next frame**, with no
save step.

Simulator and device are separate installs and so have separate calibrations.
That is correct: footage colours do not match live capture anyway (see below).

## The calibration flow

A separate **Calibrate** mode on the phone, replacing the corner handles
currently on the main screen:

1. **Play area** — the existing draggable quadrilateral, moved here as step one.
   Setting it first means the mask preview only shows pixels that matter.
2. **Puck** → 3. **Blade** → 4. **Obstacles** — each the same three-part step
   below. Each is skippable; puck and blade are required before leaving.
5. **Done** — back to the main phone screen.

### Per-entity step

**Pick.** A crosshair with a 7×7 sample box sits over the preview. Dragging
anywhere on the preview moves it **relative to where it is**, trackpad-style, so
the finger never covers what is being sampled and fine adjustment is easy. A
small magnified loupe in a corner shows the 7×7 patch enlarged, with a swatch of
its **median** colour (median, not a single pixel — compressed camera frames are
noisy). The black-out mask updates live as the crosshair moves. **Set** commits
the sample.

**Tune.** A translucent 2D pad over the preview, Kaoss-pad style. **X is colour
tolerance (R), Y is brightness tolerance (B).** No text labels — no "luma", no
"hue"; icons at most. The pad starts centred. Every movement applies to live
detection immediately.

**See.** Throughout, the preview shows **the detector's own mask**: everything
that does not match goes black. Not a Core Image look-alike — the preview must be
exactly what the detector sees. The blob the selection rule actually chose is
outlined on top, so a colour match rejected on shape is visible rather than
mysterious.

**Always live.** There is no freeze and no set-then-check cycle. The player
tunes against the moving scene, and what they see is what the game will get.

## The `FrameSource` port

`TrackingProducer` currently owns `AVCaptureSession` outright. That is the one
thing standing between the detection pipeline and the simulator.

- **Port** — `FrameSource`, phrased in the app's vocabulary: a stream of
  `420YpCbCr8BiPlanarFullRange` pixel buffers with timestamps, plus start/stop.
  Nothing about cameras, sessions, files, or codecs. If the protocol mentions
  `AVCaptureDevice`, it is not a port.
- **`CameraFrameSource`** — the existing capture code (format selection per
  ADR-0009, ultra-wide, session queue) moved behind the port. Device only.
- **`VideoFileFrameSource`** — `AVAssetReader` decoding to the same pixel
  format, paced at the file's native frame rate, **looping**, with **play/pause**.

`TrackingProducer` takes a `FrameSource` and keeps everything else: detectors,
stabilizers, display state, the bridge push. The camera preview layer becomes a
view that draws the current frame from whichever source is active, since an
`AVCaptureVideoPreviewLayer` has no equivalent for a file.

### Footage

- **Simulator:** a **Source** menu in the phone header lists the video files in a
  host folder named by an environment variable in the scheme, defaulting to
  `mitts-of-mayhem/footage/` — beside the worktrees, not in git, as it is today.
  Pick a clip; it loops; play/pause sits beside the menu.
- **Device:** camera only. No Source menu.

Clips play at their **native size and aspect**. Play area and every coordinate
are normalized, so a 16:9 Camera-app clip works as well as the 4:3 capture. It
is not a perfect stand-in: Camera-app footage is processed differently (HEVC,
possibly HDR tone mapping), so colours will not exactly match live capture. That
is fine for building and exercising the UI, and is another reason the simulator
calibration is not the device's.

Later, not now: a device-side "record clip from the pipeline" button would give
footage that matches live capture exactly.

### The simulator build

The app target links `UnityExport/build/Release-iphoneos/UnityFramework.framework`
unconditionally, and that framework is device-only — so today the app does not
compile for the simulator at all, whatever runs in it.

- In `project.yml`, link and embed UnityFramework **for the `iphoneos` SDK only**.
- Wrap the Unity call sites (`AppDelegate`, `SceneDelegates`, `PhoneView`'s
  `UnityBridge` use, the sample push) in `#if !targetEnvironment(simulator)`.
- In the simulator the external-display scene simply does not start, and
  `TrackingProducer` uses `VideoFileFrameSource`.

Nothing changes on device.

## Contract changes

Obstacles cross the bridge in this task, so the tracking work owns the contract
and the game task only consumes it. One pass across all three copies —
`ios/Spike/Bridge/MoMTracking.h`, `unity/Assets/Plugins/iOS/MoMTracking.mm`,
`unity/Assets/Scripts/Tracking/TrackingSample.cs` — with the `_Static_assert`
size and the C# runtime size check updated together (ADR-0003).

- `MoMObstacle { float x, y, width, height, confidence; }` — centre and box in
  normalized image space (ADR-0004).
- Four obstacle slots declared one per line, after the joints, plus a
  `uint8_t obstacleCount`. Slots past the count are zeroed.

Unity receives obstacles and ignores them until the game task renders them. The
sandbox scene may draw them as primitives if it is trivial; it is not required.

## Architectural decision records

- **ADR-0010 — Colour-key detection for all entities.** The one rule (CbCr
  radius plus Y band), why both terms, the per-entity shape selection and why it
  stays, no defaults, and the distinct-colour precondition. **Supersedes** the
  threshold decisions of ADR-0006 and ADR-0007; both get a status line pointing
  here. ADR-0007's consequence that `stickAngle` is a line and not a ray is
  unchanged and still stands.
- ADR-0003 gets a note that the struct grew by the obstacle slots.

The README's **Demo preconditions** are rewritten: black mat / white puck / blue
tape become "distinctly coloured objects, calibrated per setup."

## Milestones

### Milestone 1 — the port and the simulator

- `FrameSource`, `CameraFrameSource`, `VideoFileFrameSource`.
- `TrackingProducer` takes a source; preview draws frames from it.
- UnityFramework device-only; simulator guards.
- Source menu and play/pause in the simulator.

Verifiable before any detection changes: the existing detectors run on
`03-handling.MOV` in the simulator, with the existing overlay drawing on it.

### Milestone 2 — one detector

- `Calibration` struct, persistence, lock-guarded access from the vision queue.
- `ColorKeyDetector` with the three selection rules; obstacles.
- `PuckDetector` and `StickDetector` deleted, along with their constants.
- Contract change for obstacles, all three copies.
- ADR-0010, ADR-0003 note, ADR-0006/0007 status lines.

### Milestone 3 — calibration mode

- Calibrate mode and its steps; play area moves into it.
- Crosshair with relative drag, loupe, median swatch, Set.
- XY pad, live.
- Mask preview from the detector's own mask, chosen blob outlined.
- Launch routes into Calibrate when puck or blade is uncalibrated.
- Obstacle markers in the phone overlay.

### Milestone 4 — measure and run

- Release build on device: confirm the colour-key pass for three entities stays
  inside the frame budget alongside pose (today: 22.2ms of 33.3ms).
- Calibrate from scratch on the real rig and repeat the 60-second run.
- README updated.

## Bar

- 30fps held on an iPhone 15 Pro Max in **Release** — never judge from Debug.
- Prefer zero confidence over a wrong position, unchanged.
- Calibrating all three entities from nothing takes about a minute, with no
  word on screen that a player would need explained.
- The phone UI, calibration included, runs in the Xcode simulator on footage.

## What Ethan has to do

1. **Choose the objects.** A puck, a blade marker, and obstacles that are
   distinct from the mat and from each other.
2. **Run builds on the device** for Milestone 4 — the budget check and the
   calibrate-from-scratch run go through the phone.
3. **Drop any extra clips** into `mitts-of-mayhem/footage/` for the simulator.

## Out of scope

- **Tests.** Deliberately deferred. The existing still-image `DetectorTests`
  exercise `PuckDetector` and `StickDetector`, which this deletes; those tests
  and their fixtures go with them. `SampleStabilizerTests` and
  `PlayAreaRobustnessTests` stay. Consequence, accepted knowingly: the colour-key
  detector lands without automated coverage.
- A warning when two entities' colours overlap.
- Calibration profiles, and any default calibration.
- Freeze-frame during calibration.
- Obstacle identity tracking and stabilization. Identity is matched in Unity by
  the game task instead.
- Auto-seeding tolerances from the tapped blob.
- Scrubbing in the file source.
- Recording footage from the pipeline on device.
- A simulator build of Unity.
- Obstacle rendering or any new game type (sibling task).
- Latency instrumentation (sibling task).
- Lens distortion and position stability (sibling task).

## Open questions

- Is a circular CbCr radius good enough, or will real objects want an elliptical
  one? The pad has two axes by design; if a third ever earns its place, this is
  where it comes from.
- Does the colour-key pass cost more than the two detectors it replaces? It
  reads both planes for three entities where today the blade reads only chroma.
  Milestone 4 measures; the fallback is one shared pass that labels each pixel
  with its entity rather than three passes.
- How well does a calibration made under one light hold as the room's light
  shifts? The B tolerance absorbs some of it; the first session in daylight
  settles how much.
