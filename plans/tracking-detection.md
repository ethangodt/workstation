# Mitts of Mayhem — person, puck, and stick detection

Dynalist: [set up basic person, puck, and stick detection using the iphone camera](https://dynalist.io/d/g5I86fQUbuICU8XHqBP88Z0u#z=6iU0oLwnQh9S5NeDT_qthneY)

## Goal

Make the three entities in `TrackingSample` carry real values from the camera,
so the sandbox scene on the TV shows a puck, a stick, and a player that track a
real person stick-handling a real puck.

The task's wording covers all three, but person detection already shipped with
Milestone 2 — `VNDetectHumanRectanglesRequest`, verified on device. The actual
work here is puck and stick, which currently push hardcoded zero confidence, plus
a deliberate expansion of person detection from a bounding box to body pose.

Prototype rules still apply: this demos a mechanic in a meeting. It is allowed to
require a specific surface, a specific puck, and tape on a stick.

## What this rests on

The environment is a **demo precondition, not a solved problem**:

- Black playing surface, white puck. High contrast, inverted from a normal rink.
- Phone tripod-mounted, looking down at the pad, fixed for the session.
- Consistent indoor lighting.
- One puck in frame.
- Colored tape on the stick blade (see below).

Each of these deletes a class of detection failure. Each is also a constraint
that the long-term product does not get to keep — see ADR-0006.

## Decisions

### Detection is a seam, not a pile of code in the capture callback

`TrackingProducer` currently owns the camera session, the Vision request, the
coordinate conversion, and the bridge push. Three detectors inline would make it
the file where everything happens.

Instead: an `EntityDetector` protocol — pixel buffer in, position and confidence
out — with `PuckDetector`, `StickDetector`, and `PoseDetector` behind it.
`TrackingProducer` keeps the camera and the push and composes detectors.

This is not tidiness. Two things depend on it:

- The puck approach below is explicitly provisional. "Works anywhere on any
  surface" has to arrive as a swap of one type, not a rewrite of the capture
  path.
- Detectors with no camera and no Unity dependency are testable from a still
  image on the simulator, which is what makes the test story cheap.

### Puck: luma threshold, and it is provisional

A white puck on a black surface is the easiest problem in computer vision. The
capture already produces `420YpCbCr8BiPlanarFullRange`, so the luma plane is
sitting right there with no conversion: binarize, find connected components, keep
the blob whose area and circularity match a puck.

Rejected: `VNDetectTrajectoriesRequest`, which is built for ball sports and would
handle moving-vs-static for free, but needs motion across frames to report at all
— a puck resting on the pad would vanish, and stick-handling is mostly slow
lateral movement rather than clean trajectories. Also rejected: a trained
detector, which is weeks of labeling for a problem a threshold solves.

**This is a bet on the environment, and the environment is temporary.** The
stated long-term goal is detection that works on any surface with any puck. The
reopening signal is explicit: the first time this needs to run somewhere the
surface is not controlled, the threshold is finished and a trained detector is
the answer. ADR-0006 records this as Accepted-but-provisional rather than
pretending the approach generalizes.

### Stick: tape on the blade

Hockey blades are black. The surface is black. There is no contrast to threshold,
and this is the one place where the environment works against us.

A strip of bright tape along the top edge of the blade — green or orange, chosen
as a hue far from both the white puck and the black surface — turns the stick
into the same blob problem as the puck, discriminated by chroma rather than luma.
The strip is elongated, so `stickAngle` falls out of the blob's principal axis
for free.

Rejected: inferring the blade from wrist joints, which is an estimate of an
estimate and worst exactly where it matters — blade near puck. Rejected: deriving
the blade from the puck, which is circular and adds no information.

Tape is visible in the demo. That is the trade, and it is a smaller imposition
than the controlled surface already accepted.

### Person: pose replaces the rectangle

`VNDetectHumanRectanglesRequest` goes away, replaced by
`VNDetectHumanBodyPoseRequest`. Not both — two sources that can disagree about
whether a person is present is a bug waiting for a demo.

**`playerX/Y` changes meaning**, from bounding-box center to mid-hip. That is a
semantic change to an existing field with an existing consumer; mid-hip is the
better centroid, and the sandbox will render the player marker slightly
differently as a result.

Twelve joints cross the bridge: shoulders, elbows, wrists, hips, knees, ankles.
Vision returns nineteen; the seven omitted are facial and will never matter for
stick-handling. The cost of a joint is not bytes — it is a field that three
hand-maintained copies of the struct must agree on forever, where disagreement is
memory corruption rather than a compile error (ADR-0003).

Wrists plus the taped blade give the full shaft as a line, which is more than
either signal alone.

### Confidence is synthesized, and is not Vision's confidence

A threshold detector has no model confidence — it either found a blob or it did
not. But the field exists and the sandbox floors at 0.3, so something goes in it.

Puck and stick report a **quality score** derived from how closely the blob's
area and circularity match expectation, mapped to 0–1. A half-occluded puck
scores lower than a clean one, which is real information from measurements
already computed to find the blob at all.

This number is **not comparable to the person confidence**, which comes from a
Vision model. Someone will eventually compare them; ADR-0006 says not to.

### Dropouts hold for three frames

Policy is *prefer zero confidence over a wrong position* — a teleporting puck is
worse than a missing one. But instantaneous dropout means a puck briefly occluded
by the blade blinks out and back, and across a 60-second run enough blinking
reads as "broken" even when detection is correct.

Last known position is held for ~3 frames at decaying confidence, then drops to
zero. Applies to puck and stick.

Rejected: `VNTrackObjectRequest` tracking through occlusion, which drifts, and
drift produces precisely the confidently-wrong failure the policy rules out.

### Region of interest, set once on the phone

A luma threshold over the full frame finds white shoes, bright socks, lamps, and
windows — false positives that look exactly like a puck.

Detection is constrained to a play-area rectangle, set by dragging over the
camera preview on the phone and persisted, with a sensible default so it works
unset. Hardcoding it was rejected: it breaks silently the moment the tripod
moves.

### The phone screen gets a debug preview

A live camera preview with detected blobs drawn over it, behind a toggle,
defaulting on. It doubles as the aiming aid and as the surface for setting the
ROI.

Being able to see what the detector sees, on the device, in real time, is the
difference between debugging this in an afternoon and debugging it over a week.
It is also a debug affordance with a limited shelf life — flagged in the README
as an obvious candidate for removal.

### Detectors are tested against still images

A test target with roughly a dozen committed PNGs: puck clean, puck half-occluded
by the blade, puck absent, puck with a white shoe in frame, blade at four
hand-measured angles. Assertions on position within tolerance and confidence
above or below the floor.

This is cheap only because of the detector seam — no camera, no `UnityFramework`,
runs on the simulator in about a second. The images come from a capture button on
the debug preview that writes the current frame to a PNG. That is roughly a tenth
of the session-recorder scope, which was considered and declined.

The temporal logic — hold, decay, smoothing — is pure arithmetic over a buffer
and is tested with synthetic sample sequences, no images needed.

Every number in this design is a tuned constant: luma threshold, area window,
circularity tolerance, hue band, confidence mapping, floor. Tuning constants
without tests is how a detector gets quietly worse while being improved.

### One frame rate until measurement says otherwise

All three detectors run at 30fps. Pose is the expensive one and the puck is the
fast one, so running pose at 15 is the obvious optimization — but it makes joints
stale relative to the puck within a single sample, and there is no measurement
yet saying it is necessary.

Build at 30, instrument per-request time, decide from the number. The sample
already carries a timestamp, so decoupling later requires no contract change.
Confirming that is part of the point.

## Contract changes

All of it lands in **one pass**, because each change touches three files that
must agree byte-for-byte — `ios/Spike/Bridge/MoMTracking.h`,
`unity/Assets/Plugins/iOS/MoMTracking.mm`, and
`unity/Assets/Scripts/Tracking/TrackingSample.cs`. Doing it once is meaningfully
safer than doing it twice.

- `stickTipX/stickTipY` → **`stickX/stickY`**. The field holds a blade centroid;
  a field named "tip" holding a centroid is a trap for whoever writes the first
  mini-game.
- `stickAngle` is specified as **blade orientation in the image plane, degrees,
  0 = blade pointing right**.
- **Twelve joints added**, each with x, y, and confidence, in the same normalized
  image space as everything else per ADR-0004.
- `playerX/Y` **redefined** as mid-hip.

No velocity fields. Unity has `frameId` and `timestamp` and can differentiate;
the detector-side smoothing is what makes that differentiation usable. A gameplay
requirement stated in real velocity terms is the signal to revisit.

## Architectural decision records

Following the repo convention — numbered sequentially, never renumbered, written
as part of the work rather than retroactively.

- **ADR-0006 — Luma-threshold puck detection, provisional.** The contrast bet,
  the rejected alternatives, the synthesized confidence score and its
  incomparability to Vision's, and the reopening signal stated plainly: any
  uncontrolled surface ends this approach.
- **ADR-0007 — Blade marker as a demo precondition.** Why the black-on-black
  problem has no cheap vision solution, why tape beats wrist inference, and what
  the tape costs in a demo.
- **ADR-0008 — Body pose replaces person rectangles.** The single-source
  argument, the twelve-joint subset and why facial joints were dropped, and the
  `playerX/Y` semantic change.

ADR-0003 gets a note recording that the struct grew and the stick fields were
renamed, since it is the record that owns the three-copies invariant.

## Milestones

### Milestone 1 — contract and seam

- All contract changes above, across all three files, in one commit.
- `EntityDetector` protocol; `TrackingProducer` composes detectors.
- Shared hold-and-decay and smoothing, with synthetic-sequence tests.
- `PoseDetector` replaces the rectangle request; joints populated.
- ADR-0008.

Verifiable without a puck or a stick: joints arrive in Unity and the sandbox
draws the player from mid-hip.

### Milestone 2 — seeing what the detector sees

- Debug camera preview on the phone with a detection overlay.
- Drag-to-set ROI with a default rectangle, persisted.
- Frame capture button writing PNGs retrievable via Files.

Deliberately before the detectors. Building a blob detector without being able to
watch it work is the expensive way to do it.

### Milestone 3 — puck

- `PuckDetector`: luma threshold, connected components, area and circularity
  filtering, quality score.
- Test target, still-image tests for the puck cases.
- ADR-0006.

### Milestone 4 — stick

- `StickDetector`: chroma-band blob, centroid, principal-axis angle, quality
  score.
- Still-image tests for the blade angle cases.
- ADR-0007.

### Milestone 5 — measure and run

- Per-request timing instrumentation; decide 30fps vs. decoupled pose from the
  measurement.
- The acceptance run: 60 seconds continuous, real person, real puck, real stick,
  three primitives tracking on the TV, no intervention.
- README updated with the demo preconditions and the debug affordances.

## Bar

- 30fps, end-to-end latency under ~100ms.
- Prefer zero confidence over a wrong position.
- Done is the 60-second continuous run on the TV.
- Device floor stays iPhone 15 Pro Max; deployment target stays iOS 16 — every
  Vision API used here is iOS 14+.

## What Ethan has to do

Physical and on-device work that cannot be done from a terminal:

1. **Confirm the surface.** Black pad and white puck were stated; the luma
   threshold's area window needs the approximate puck-to-frame size ratio, which
   comes from the actual pad at the actual tripod height.
2. **Get tape on the blade.** Bright green or orange, a strip along the top edge
   of the blade, full length. Not a dot — a dot makes `stickAngle` meaningless.
3. **Set up the rig once and leave it.** Tripod position, height, angle, and
   lighting. Moving it between capturing test images and running the demo
   invalidates the tuned constants.
4. **Capture the test frames** (during Milestone 2, using the capture button):
   puck clean, puck half-occluded by the blade, puck absent, puck with a white
   shoe in frame, blade at four distinct angles. Roughly a dozen.
5. **Hand-measure the blade angle** in the four angle frames, so the tests have
   ground truth to assert against.
6. **Run builds on the device.** `./build.sh` needs the phone, the display, and
   a cable; the tuning loop for thresholds runs through you.
7. **The acceptance run.** Sixty seconds of real stick-handling in front of the
   camera.

Items 1–3 block Milestone 3. Items 4–5 block the tests in Milestones 3 and 4.

## Out of scope

- Session recording and JSON replay for `MockTrackingSource` — considered and
  declined. Consequence, accepted knowingly: gameplay iteration in the Unity
  editor keeps requiring a device, a pad, and a stick, and `MockTrackingSource`
  stays hand-authored.
- Floor-plane projection and calibration UX (ADR-0004 still holds).
- Velocity or trajectory in the contract.
- Detection that generalizes beyond the controlled setup.
- Facial joints.
- Any mini-game.

## Open questions

- Does the frame budget actually hold with three detectors at 30fps? Milestone 5
  answers it; the fallback is pose at 15fps, which the timestamp already
  supports.
- What hue survives the pad's lighting? Green and orange are the candidates;
  the first captured frames settle it.
- Does the ROI need to be per-session or does one setting survive across runs?
  Persisting it is the assumption; a tripod that gets packed away each time makes
  that wrong.
