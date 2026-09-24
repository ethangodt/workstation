# Mitts of Mayhem — improved Unity game ("Defend")

Dynalist: [improved unity game](https://dynalist.io/d/g5I86fQUbuICU8XHqBP88Z0u#z=kLXtdCAqD_4Btw7BYx_vsgMe)
(under [improve vision tracking implementation](https://dynalist.io/d/g5I86fQUbuICU8XHqBP88Z0u#z=D-unLpYB5uFnQwkspbnHlh5x))

## Goal

The first real mini-game, and the first thing on the TV that is a game rather
than a debug view.

Two physical obstacles sit on the mat — shoes, cones, whatever the player
calibrated. On screen they are **points of interest**, and triangle enemies march
in from off-screen toward them. The player defends them by moving the puck over
the enemies, which clears them. Enemies that reach a point of interest cost it a
life; the run ends when both are out of lives.

Knocking a physical obstacle while stick-handling is also noticed: the obstacles
should never move, so a detected move is a bump, and a bump costs a life too.

Working title and mini-game id: **Defend** / `defend`.

## What this rests on

- **The calibration plan** ([calibration-mode](calibration-mode.md)) owns the
  tracking contract. It adds up to four `MoMObstacle { x, y, width, height,
  confidence }` slots plus an `obstacleCount`, sorted by position, compacted, and
  **not identities**. This task consumes that contract and changes nothing on the
  Swift side.
- **Unity only.** No Swift changes, no cold-path `StartRun` from the phone. The
  game starts itself.
- **Sample space is the full 4:3 camera frame** (ADR-0004, ADR-0009). The play
  area quad is not sent to Unity and this task does not send it.
- **The puck is a cursor.** The player looks up at the TV and steers the on-screen
  puck; the real puck is only a way to control a position. Its physical size is
  irrelevant, and a future game may not draw a puck at all.

## Decisions

### Arena

- **4:3, pillarboxed, black.** The playfield takes the camera frame's aspect, so
  a circle in the arena is a circle on the mat and distances are plain Euclidean
  in world units. The bars either side on a 16:9 TV are black, like the
  background, and so invisible.
- The full camera frame maps to the arena, via `SampleSpace.ToWorld` with a 4:3
  playfield. Fitting the mat to the screen is a follow-up (see Out of scope).
- Black background, entities on top. Nothing else: no camera feed, no stick, no
  skeleton.

Gameplay math is in arena world units, which are sample space scaled by a
constant per axis. That keeps ADR-0004's rule — nothing assumes what the units
mean physically — and makes the floor-plane migration a change to the mapping,
not to the rules.

### Points of interest

- **Exactly two.** The contract carries up to four; the game uses two.
- **Hit circle radius** = the larger half-extent of the obstacle's box, in world
  units. Generous for a shoe, which is the right way to be wrong.
- **5 lives each.** Shown as a segmented ring around the obstacle.
- A point of interest at zero goes dark and is no longer targeted.
- **The run ends when both are dead.**

### Obstacle identity is matched in Unity

Swift reports detections, not identities: slots are compacted and sorted, so a
dropped, split, or bumped obstacle shifts every slot after it. Unity is the side
that knows it wants exactly two and holds the history to match against.

- **Binding.** At run start, the two largest confident detections become the two
  **baselines**. Fewer than two for ~1s → a "place two obstacles" prompt, and the
  run waits.
- **Matching, every frame.** Each baseline takes the nearest confident, unclaimed
  detection within a gate of ~3 × its radius. Greedy, nearest pair first. No
  match is an unconfident frame for that obstacle — it is not a move.
- **Rebinding.** A baseline unmatched for > ~1s while an unclaimed confident
  detection exists rebinds to it, and that counts as a bump. This covers a kick
  that sends an obstacle outside the gate.

### Bumps

The obstacle's **baseline** is what renders and what enemies aim at. The live
position is only an input to the bump rule, so detection jitter never reaches the
screen.

- **Bump:** the matched detection sits more than ~0.5 × radius from the baseline
  for ~6 consecutive confident frames. Frames below the obstacle confidence floor
  do not count and do not reset the streak — occlusion by the blade or puck dips
  confidence, and that is not movement.
- **Cost:** one life, a flash, and a ~1s cooldown so one bump is not counted many
  times.
- **Settling:** after a bump, the baseline moves to the live position once the
  obstacle has held still (moves < ~0.1 × radius) for ~0.5s. The player never has
  to put it back. No pause, however far it moved.

Every number above is a serialized tunable.

### Enemies

- Triangles. They spawn **just off-screen** — just outside the arena edge — at a
  random point on a random edge.
- Each heads for the **nearest living** point of interest, re-evaluated every
  frame, so a dead target or a settled baseline redirects them for free.
- Straight line, constant speed, tip pointing at the target. No steering or
  dodging.
- **Reaching** a point of interest (tip inside its hit circle): the enemy
  vanishes and the point of interest loses a life.

### The puck

- A fixed, tunable hit radius in world units. Not from the contract.
- **Clears** an enemy when the puck circle overlaps the enemy's: +10 points, the
  enemy vanishes.
- **Below the puck confidence floor** the puck clears nothing and its glyph fades,
  so the player can see why nothing is happening. No clearing from a stale
  position.

### Waves

- Discrete waves with a ~3s breather and a "Wave N" banner between them.
- `Difficulty` scales enemy count, speed, and spawn interval per wave.
- `DurationSeconds = 0` plays until both points of interest are dead. `> 0` caps
  the run; surviving to the cap is `Completed = true`.
- Score is a flat 10 per enemy cleared. No combos.

### Run lifecycle

- `DefendGame` implements `IMiniGame` properly, so Swift can drive it later.
- Nothing drives it yet, so it **auto-starts** on scene load with default
  `MiniGameParams`.
- **Game over** shows final score and wave, and a "hold the puck here to play
  again" circle in the centre. Puck inside it for 1.5s restarts. Hands never
  leave the stick.
- `RunFinished` fires with a `MiniGameResult` (score, cleared → `TargetsHit`,
  hits taken → `TargetsMissed`, elapsed, completed) and is logged.

### HUD and palette

Score top-left, wave top-centre, lives as the ring around each point of interest.
White puck, red triangles, the two points of interest in two distinct colours.
Dead points of interest dark grey.

## Structure

Rules in plain C#; MonoBehaviours only translate and draw.

- `MiniGames/Defend/DefendRules` — the whole game state and a
  `Step(float dt, DefendInput input)`. Waves, enemies, collisions, lives, score,
  run end. No `MonoBehaviour`, no scene, no `Time`.
- `MiniGames/Defend/ObstacleTracker` — binding, matching, rebinding, bump,
  cooldown, settling. The part most likely to need tuning, so it stands alone.
- `MiniGames/Defend/DefendConfig` — every tunable, serializable.
- `MiniGames/Defend/DefendGame : MonoBehaviour, IMiniGame` — reads
  `TrackingSourceProvider`, maps sample → arena, builds a `DefendInput`, steps the
  rules, raises `RunFinished`.
- `MiniGames/Defend/DefendView` — draws whatever the rules say exists: circles,
  life rings, triangles, puck, HUD, banners, the restart circle.
- `SampleSpace` gains the 4:3 arena mapping, shared with the sandbox so the two
  cannot disagree.

### Tests

An EditMode test assembly covering `DefendRules` and `ObstacleTracker`:
matching through a compacted slot shift, occlusion frames not counting, the bump
streak, cooldown, settling, rebinding after a kick, enemy retargeting on a death,
puck dropout clearing nothing, wave scaling, both end conditions.

The scripts live in `Assembly-CSharp` today, which a test assembly cannot
reference. So this adds a runtime `MittsOfMayhem` asmdef over `Assets/Scripts`
and an editor asmdef over `Assets/Editor` referencing it. `Plugins/iOS` is
untouched.

### Mock

`MockTrackingSource` mouse mode gains two fixed obstacles. Right-drag moves the
nearest one, to exercise bumps, settling, and a kick past the gate. The mouse maps
through the 4:3 arena rather than the whole window. Replay clips without obstacle
data simply report none, and the game shows its "place two obstacles" prompt.

### Scene and build

`Defend.unity`, generated by `ProjectBootstrap` like the sandbox. It goes
**first** in `SpikeBuild`'s scene list, so it is what the TV shows; the sandbox
and spike scenes stay in the build and the editor.

## Architectural decision records

- **ADR-0011 — Defend: obstacle identity, bumps, and the arena.** Identity
  matched in Unity against baselines rather than trusted from slot order; the
  bump, cooldown, and settle rule and why the baseline and not the live position
  is what renders; the 4:3 pillarboxed arena; the puck as a cursor with a fixed
  radius rather than a measured one.

(ADR-0010 belongs to the calibration plan.)

## Milestones

### Milestone 1 — rules, no contract needed

- Runtime and editor asmdefs; EditMode test assembly.
- `DefendConfig`, `ObstacleTracker`, `DefendRules`, with tests.

Independent of the calibration work: the rules take plain inputs, not a
`TrackingSample`. Can start immediately.

### Milestone 2 — the game on screen

Starts once the calibration plan's Milestone 2 contract commit is on mitts
`main`. If it has not merged by then, branch from it or cherry-pick that commit
alone, so the three copies of the struct never drift.

- 4:3 arena mapping in `SampleSpace`; pillarboxed camera.
- `DefendGame`, `DefendView`, HUD.
- Mock obstacles and right-drag.
- `Defend.unity` via `ProjectBootstrap`; first in the build.
- ADR-0011.

Verifiable in the editor with the mouse: a full run to game over, a restart by
holding the puck, a bump, a settle, a kick past the gate.

### Milestone 3 — on the mat

- Release build on device, calibrated with two obstacles.
- Tune the bump threshold, streak, gate, and settle against real stick-handling
  near the obstacles.

## Bar

- 60 seconds of ordinary stick-handling around the obstacles, never touching
  them, produces **no** bumps.
- A deliberate nudge produces **exactly one**, and the obstacle then settles where
  it landed without the player doing anything.
- A full run and a restart without anyone touching the phone.
- Holds frame rate on the TV alongside tracking, in **Release**.

## What Ethan has to do

1. **Calibrate two obstacles** once the calibration mode exists.
2. **Run builds on the device** for Milestone 3, and play.

## Out of scope

- Swift changes of any kind, including a start button and a result screen.
- Fitting the mat to the screen (sending the play area, or a homography). Belongs
  with lens distortion and position stability.
- More than two points of interest.
- Pausing on a large obstacle move.
- Enemy variants (fast, zig-zag), power-ups, combos.
- Drawing the stick or skeleton in this game.
- Puck size from the contract.
- Audio.

## Open questions

- Is max half-extent a fair hit circle for an elongated obstacle, or does a shoe
  want an ellipse? Milestone 3 settles it by feel.
- The 4:3 arena bakes in ADR-0009's capture aspect. If the capture format ever
  changes, the aspect should arrive over the contract rather than be edited here.
- Does the blade merging with an obstacle's blob pull the centroid far enough,
  for long enough, to beat the streak? If so, the fix is on the detection side,
  not a longer streak.
