# Mitts of Mayhem — Unity project setup

Dynalist: [set up basic unity game project](https://dynalist.io/d/g5I86fQUbuICU8XHqBP88Z0u#z=lsgE40MEkE1WGQEecTfZ6pJY)

## Goal

Stand up the Unity half of the Mitts of Mayhem prototype: a project that consumes
iPhone vision tracking data and renders gameplay to a TV, good enough to demo the
core mechanic in a meeting. Unpolished is fine and expected. Not a production
architecture — but the seams that are expensive to move later are chosen
deliberately.

Sibling tasks cover the iOS app scaffold and the actual person/puck/stick
detection. This plan owns the Unity project and the bridge contract between the
two; it necessarily touches the iOS side at that seam.

## Architecture

### Unity as a Library (UaaL)

A native Swift app owns the process. It owns the camera session, Vision, and the
phone screen. Unity is embedded as a framework and renders gameplay into the
**external display's window scene** — the TV over USB-C/HDMI — while SwiftUI
renders controls, score, and coach content on the device screen.

The forcing function is the dual-screen requirement. Unity's
[multi-display support](https://docs.unity3d.com/Manual/MultiDisplay.html) is
documented for Mac, Windows, and Linux only; driving two different views from
Unity alone on iOS is unsupported territory. Natively it is a solved problem —
Apple documents
[presenting distinct content on a connected display](https://developer.apple.com/documentation/uikit/presenting-content-on-a-connected-display).
Putting the native app in charge of both screens follows the platform instead of
fighting the engine.

The secondary benefit: the product is half training content from Instagram
trainers — video, feeds, accounts — which is materially nicer in SwiftUI than in
Unity UI.

**Known UaaL constraints, accepted:**

- One Unity runtime instance per process; `quitApplication` is terminal (cannot
  reinitialize in the same session), so only `unloadApplication` is ever used.
- An unloaded runtime still holds roughly 80–180 MB. Real budget alongside a
  camera session and Vision models on older devices.
- Officially full-screen rendering only. Hosting Unity's view in a non-primary
  window scene is undocumented — see Milestone 0.
- Host Xcode project must be Objective-C, so there is an ObjC bridging layer
  between SwiftUI and `UnityFramework`.
- Two build systems permanently: Unity exports an Xcode project, the Swift app
  consumes it as a framework.

### Ownership split

**Swift owns the meta-game. Unity owns the moment.**

Unity runs the active mini-game loop — moment-to-moment gameplay, feel, scoring
within a run. Swift owns progression, run structure, accounts, trainer content,
and persistence.

The reasoning: gameplay feel has to be iterated in the Unity editor against a
mock feed with no device attached, which argues for Unity owning the loop.
Progression and trainer video are native concerns that would be miserable to
rebuild in Unity UI later.

The protocol at the mini-game boundary stays deliberately thin — start, stop,
result — and everything else stays inside Unity until it proves it must cross.

### Bridge

Two channels, different traffic profiles.

**Hot path (Swift → Unity, 30–60 Hz):** tracking samples. C# registers a
function pointer with the native plugin at startup via
`[DllImport("__Internal")]`; the native side invokes it with a flat, blittable C
struct. No JSON, no per-frame managed allocation, no GC pressure.

**Cold path (bidirectional, a handful per session):** start mini-game with
params, run result. Uses `sendMessageToGOWithName:functionName:message:` with
JSON — legible, loggable, and speed is irrelevant at this frequency.

**Threading:** Vision callbacks arrive on their own queue at the camera's
cadence, which is not Unity's frame cadence. The native side writes each sample
into a double-buffered slot; Unity reads whatever is current during `Update`.
Unity treats tracking as "latest known sample with a timestamp," never as a
stream it must consume frame-for-frame. Coupling the two threads directly yields
either blocking or torn reads, and is far harder to untangle later than to do
correctly now.

### Tracking sample contract

Coordinate space is **normalized image space (0–1)** for the prototype, behind an
`ITrackingSource` interface, with the struct laid out so a later projection onto
a real-world ground plane changes only what is written into the fields — not the
fields themselves.

```
struct TrackingSample {
    uint32 frame_id;
    double timestamp;
    uint8  space;           // 0 = normalized image, 1 = floor plane (meters)

    float  puck_x, puck_y, puck_conf;
    float  stick_tip_x, stick_tip_y, stick_angle, stick_conf;
    float  player_x, player_y, player_conf;
}
```

Skeleton joints are deliberately omitted until a mini-game needs them.

Image space is a picture of the scene, not the scene: move or tilt the phone and
the same physical position maps elsewhere; a puck near the camera appears to move
faster than one far away. For a target-hitting demo this is invisible, and
committing to ARKit plane detection now would add a calibration UX and a fresh
failure mode to the thing being demoed.

**Watch for:** the first mini-game requirement phrased in real-world units ("move
the puck 12 inches left") is the signal that the plane projection is now
required. To keep that migration cheap, gameplay math is expressed in
sample-space units and must not bake in assumptions about what those units mean.

## Repository

New repo `mitts-of-mayhem`:

```
mitts-of-mayhem/
  unity/        Unity project (6000.2.6f2)
  ios/          Swift host app + Xcode workspace
  build.sh      Unity batch-mode export, then Xcode build
```

One repo, because the bridge has a foot in each project and will change
constantly — splitting it makes every bridge change a two-repo dance with
version pinning. Unity lives under `unity/` rather than at the root so the iOS
side and export artifacts have a clean home beside it. Git LFS for binary
assets; Unity-standard `.gitignore`.

## Architectural decision records

Create an `adr/` directory in the `mitts-of-mayhem` repo. Every architectural
decision in this plan gets its own record, written as part of the repo setup
rather than retroactively — the reasoning above is the raw material and should be
moved into these files, not duplicated by hand later.

```
mitts-of-mayhem/
  adr/
    0000-template.md
    0001-unity-as-a-library.md
    0002-swift-owns-meta-game-unity-owns-the-moment.md
    0003-bridge-transport.md
    0004-tracking-coordinate-space.md
    0005-single-repo-layout.md
```

Numbered sequentially, never renumbered, never deleted. A decision that gets
reversed is superseded by a new record that links back to it, and the original is
marked `Superseded by ADR-NNNN` — the record of having believed something is the
point.

Each record follows the same shape (`0000-template.md`):

- **Title** — the decision, stated as a claim.
- **Status** — Proposed / Accepted / Superseded by ADR-NNNN.
- **Date**.
- **Context** — the forces in play. What made this a decision rather than a
  default, and what was true at the time.
- **Decision** — what was chosen.
- **Consequences** — what this buys, what it costs, and what it forecloses.
  Explicitly including the constraints accepted (the UaaL limitations, image
  space not being real space) and the signal that would reopen the decision.
- **Alternatives considered** — the options rejected and why, with enough detail
  that a future reader does not have to re-derive the argument.

ADR-0001 in particular should record that Milestone 0 is its gate: the decision
is Proposed until the dual-screen spike passes, and a failed spike supersedes it
rather than quietly revising it.

## Milestones

### Milestone 0 — dual-screen spike (hard gate)

Throwaway build. No gameplay, no Vision, no art.

- SwiftUI app hosts `UnityFramework`'s view in the external display's window
  scene.
- A spinning cube renders on the TV over USB-C/HDMI.
- A button on the phone changes the cube's color through the bridge.

Days, not weeks. **Everything above rests on an assumption that is documented
nowhere**: Unity states full-screen-only and one-instance, and says nothing about
which screen that is. If Unity's view cannot live in a secondary window scene,
the options are a Unity-side multi-display hack on a platform that does not
support it, or falling back to Unity-owns-the-app with a mirrored display. That
answer must arrive before a mini-game is built on top of the assumption.

Do not proceed past this gate on a partial result.

### Milestone 1 — Unity project skeleton

- Unity 6000.2.6f2 project at `unity/`, URP, iOS build target.
- `adr/` populated with the records listed above.
- `ITrackingSource` interface and the `TrackingSample` struct above.
- `MockTrackingSource`: replay from a recorded JSON file, plus mouse-driven puck
  position for live fiddling.
- A tracking sandbox scene — puck, stick, and player drawn as primitives at their
  sample positions.
- Mini-game protocol surface: start(params), stop, result.

Mock-first is deliberate. Without it every gameplay iteration costs a device
build, and this whole task blocks on the detection sibling task landing.

### Milestone 2 — bridge wired end to end

- `VisionTrackingSource` behind the same interface.
- Registered-callback hot path, double-buffered.
- Cold path over `sendMessageToGOWithName`.
- Sandbox scene runs on real tracking data on the TV.

### Milestone 3 — one mini-game

A single target-hitting mini-game: targets appear, the player moves the real puck
through them, score and a fail state. BALL x PIT–style target animations as the
cheap polish layer.

One mini-game rather than a sandbox or a roguelike shell — a sandbox does not
demo a *game*, and a shell demos structure that has not been validated. A real
puck moving a real on-screen thing is what makes a room lean forward.

## Out of scope

- Roguelike meta-progression and run structure (Swift side, later).
- Accounts, trainer video content, onboarding.
- Floor-plane projection and calibration UX.
- Skeleton tracking.
- The remaining two mini-games.
- Any polish beyond what reads on a TV from across a room.

## Open questions

- Does the external-display window scene actually accept Unity's view?
  (Milestone 0 answers this; everything else is contingent.)
- Device floor for the demo — which iPhone, and does the memory budget hold with
  Vision plus an unloaded-capable Unity runtime?
- Recorded mock data has to come from somewhere. Hand-authored JSON is enough to
  start; real recordings depend on the detection sibling task.
