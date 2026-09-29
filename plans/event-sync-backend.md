# Out the door — 0.1: simplest backend for shared events

Dynalist: [spin up the simplest backend possible to support persisting events and accessing them across devices](https://dynalist.io/d/g5I86fQUbuICU8XHqBP88Z0u#z=qtJYxEvWIR725pLseRIP9JR0)
Repo: [ethangodt/planner-for-parents](https://github.com/ethangodt/planner-for-parents)

## Goal

0.1 is about getting a dev build onto both parents' phones so we can trial and
collaborate on features as they get built. Today `DayStore` holds events in
memory and everything resets on relaunch. This task makes the day's events
**persist** and **stay live across both phones**, with the least backend
possible.

Explicitly not a goal: real dates, calendar integration, accounts, households,
or anything beyond "one shared, never-ending day".

## Decisions at a glance

| Area | Decision |
|---|---|
| Backend | Firebase Firestore (free Spark plan), SDK via SPM, **app target only** |
| Sync | Live: a snapshot listener pushes the other phone's changes as they land |
| Identity | None modelled. Firebase **anonymous auth** so rules can require a signed-in app |
| Data shape | One flat collection, one document per event keyed by its UUID |
| Dev vs real data | `#if DEBUG` → `dev-events`; Release / TestFlight → `events`. One Firebase project |
| Conflicts | Last write wins, per event document |
| Write timing | On commit only (gesture end / undo), never mid-drag |
| Undo | Stays local. Undoing writes the resulting state; the backend never knows it was an undo |
| First launch | Starts empty. No sample seeding |
| Reset | None. The existing chrome-pill reset (restore samples) is removed |
| Offline | Firestore SDK defaults (local cache + queued writes). Nothing extra |
| Lane names | Stay per-device; existing hardcoded defaults (`["Ethan", "Emilie"]`) already match |
| Firebase config | `GoogleService-Info.plist` committed to the (private) repo — it isn't a secret; rules are the guard |
| Identifiers | Everything under the hood is `planner-for-parents`: bundle ID becomes `com.ethangodt.planner-for-parents` (was `com.ethangodt.planner`), Firebase project likewise. Code names (`Planner` target/scheme, `PlannerApp`, `PlannerCore`, types, vars) stay `Planner`. The user-facing display name is left alone until the naming task |

## Why Firestore

The requirement is "two iPhones see each other's edits, live, with minimal
code". Options considered:

- **Firestore** — live listeners, offline cache, and anonymous auth out of the
  box; a few dozen lines of glue. Heavy SDK, Google account needed.
- **CloudKit public DB** — no third-party SDK, but requires the paid Apple
  Developer Program (currently on free provisioning) and live updates need push
  subscriptions or manual refresh.
- **Supabase** — comparable to Firestore, a bit more setup.
- **Custom (e.g. Cloudflare Worker + KV)** — we'd write and host the API and
  still have no live updates.

Firestore is the least code for "live", and doesn't depend on the paid Apple
membership (TestFlight will, but that's the sibling install task).

## Architecture

### Layers

```
PlannerCore (pure Swift, no Firebase)
  EventSync          protocol: start(onChange:), upsert([PlannerEvent]), delete([ID])
  EventChange        .upserted(PlannerEvent) / .removed(PlannerEvent.ID)
  EventMerge         apply([EventChange]) to [PlannerEvent] → sorted [PlannerEvent]
  InMemoryEventSync  test/preview implementation; can simulate a "remote" peer

App target
  FirestoreEventSync  EventSync backed by Firestore + anonymous auth
  DayStore            unchanged public API; applies locally, pushes via EventSync,
                      merges remote changes from the listener
  PlannerApp          FirebaseApp.configure(), builds DayStore(sync: FirestoreEventSync())
```

Keeping the protocol, merge logic, and in-memory implementation in
`PlannerCore` means the interesting behaviour (merging, undo writes) is unit
tested without Firebase, and previews never touch the network.

### Data model

Collection: `events` (Release) or `dev-events` (Debug). Document ID: the
event's `UUID().uuidString`. Fields map 1:1 onto `PlannerEvent`:

| Field | Type | Notes |
|---|---|---|
| `start` | number | minutes since midnight |
| `end` | number | minutes since midnight |
| `title` | string | |
| `colorIndex` | number | |
| `lane` | number | 0 = left (Ethan), 1 = right (Emilie) |

Encoding is a hand-written dictionary mapping in `FirestoreEventSync` — five
fields don't justify Codable plumbing, and `PlannerEvent` stays untouched.
Documents that fail to decode are skipped and logged.

### Write path (local → backend)

`DayStore` keeps applying every change locally first (so animations and undo
behave exactly as today), then pushes the resulting state:

| DayStore call | Push |
|---|---|
| `add(event)` | `upsert([event])` |
| `edit(updated)` | `upsert(updated)` |
| `split(cuts)` | `upsert(tops + bottoms)` |
| `delete(ids)` | `delete(ids)` |
| `undoEdit()` | `upsert(previous)` |
| `undoSplit()` | `delete(newIDs)` + `upsert(originals)` |
| `undoDelete()` | `upsert(removed)` |
| `remove(id)` (undo of a create, after its sink animation) | `delete([id])` |

Multi-event pushes use a Firestore `WriteBatch` so the other phone sees them
land together. Writes are fire-and-forget; errors are logged.

Drags and resizes already only call `store.edit` at gesture end, so "write on
commit" falls out of the existing structure — no throttling needed.

### Read path (backend → local)

`FirestoreEventSync.start(onChange:)` signs in anonymously (a no-op after the
first launch — the anonymous user persists), then attaches a snapshot listener
to the collection and forwards `documentChanges` as `[EventChange]`
(`added`/`modified` → `.upserted`, `removed` → `.removed`).

`DayStore` applies them via `EventMerge` inside `withAnimation(.snappy)`, so a
tile the other parent moved glides rather than jumps. Our own writes echo back
through the listener; applying them is idempotent, so no echo suppression is
needed.

The listener delivers on the main queue; hop onto the main actor explicitly
(`MainActor.assumeIsolated` or a `@MainActor` closure) to satisfy Swift 6
strict concurrency, since `DayStore` is `@MainActor`.

### Undo meets remote edits

Undo stays a purely local stack. Edge cases, all resolved by last-write-wins
and accepted for a two-person dev build:

- Undoing an edit to an event the other parent has since changed overwrites
  their change.
- Undoing a delete of an event re-creates it for both phones.
- If a remote change removes an event that's referenced by the local undo
  stack, prune those undo entries (reuse the pruning in `DayStore.remove`) so
  undo doesn't resurrect something unexpectedly mid-flow.

### Launch state

`DayStore` starts with `events = []` and fills from the listener's first
snapshot (which comes from the local cache immediately when offline or on
relaunch). `PlannerEvent.samples` stays for previews and tests only.

## Firebase project setup (manual, done by Ethan)

1. [console.firebase.google.com](https://console.firebase.google.com) → Add
   project "planner-for-parents" (if that project ID is taken globally, accept
   Firebase's suffixed ID). Google Analytics: off. Plan: Spark (free).
2. Add an iOS app with bundle ID `com.ethangodt.planner-for-parents`. Download
   `GoogleService-Info.plist` and drop it into `App/` in the repo.
3. Build → Authentication → Get started → Sign-in method → enable
   **Anonymous**.
4. Build → Firestore Database → Create database → production mode, region
   `nam5` (or nearest).
5. Firestore → Rules → paste `firebase/firestore.rules` (below) → Publish.

The rules file is committed in the app repo for reference; there's no Firebase
CLI deploy step.

```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /{collection}/{eventId} {
      allow read, write: if request.auth != null
                         && collection in ['events', 'dev-events'];
    }
  }
}
```

## Implementation steps

Each step is a commit (or a few) on `feat/event-sync-backend` in
planner-for-parents.

1. **Core sync types** (`PlannerCore`): `EventSync` protocol, `EventChange`,
   `EventMerge`, `InMemoryEventSync`. Tests: upsert inserts/replaces and keeps
   start-order; remove drops; merging an echo of a local write is a no-op.
2. **DayStore on EventSync**: `DayStore(sync:)`, start empty, push per the
   write-path table, apply remote changes with animation, prune undo entries
   for remotely removed events. Tests against `InMemoryEventSync` for every
   row of the write-path table (DayStore may need to move its logic into a
   testable spot, or gain a small app test target — pick whichever is less
   churn).
3. **Bundle ID**: change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` to
   `com.ethangodt.planner-for-parents`. Existing free-provisioning installs
   become a separate app; delete the old one from each phone.
4. **Remove reset**: drop the reset control from `ChromePill`,
   `DrawController.reset()`, and `DayStore.reset()`; update the ChromePill doc
   comment.
5. **Firebase wiring**: add `firebase-ios-sdk` (latest major) to
   `project.yml` `packages:`, depend on `FirebaseAuth` + `FirebaseFirestore`
   in the `Planner` target only. `FirebaseApp.configure()` in `PlannerApp`.
   `FirestoreEventSync` with the `#if DEBUG` collection switch.
   The downloaded plist is at
   `~/_Projects/Software/planner-for-parents/GoogleService-Info.plist`; copy it
   into `App/` in the feature worktree and commit it.
6. **Rules + setup docs**: commit `firebase/firestore.rules`; add a short
   "Backend" section to the README pointing at the setup steps above.
7. **ADR-0010: Firestore for shared events** — supersedes
   ADR-0004 (in-memory state for exploration).

## Verification

- `PlannerCore` tests pass.
- Two simulators (each gets its own anonymous user), Debug build: draw on one
  → tile rises on the other within ~1 s; move, resize, split, delete, and each
  undo all mirror across.
- Kill and relaunch → events are still there.
- Airplane mode on one device, edit, reconnect → changes arrive on the other.
- Firebase console shows Debug data under `dev-events` only; an Archive/Release
  run writes to `events`.
- Removing the plist or disabling anonymous auth fails loudly in the console
  log rather than crashing.

## Out of scope

- TestFlight / paid developer account / installing on Emilie's phone (sibling
  task).
- Real dates, multiple days, accounts, households, lane-name sync.
- Live mid-drag updates on the other phone.
- Any sync-status UI.
