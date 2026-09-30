# Up together (Nightglow) — 0.2: backend architecture

Dynalist: [0.2 design simple backend architecture](https://dynalist.io/d/g5I86fQUbuICU8XHqBP88Z0u#z=rADL8IVLk15h-gAYcOnlhgjm)
Repo: [ethangodt/night-feed-app](https://github.com/ethangodt/night-feed-app) (local: `~/_Projects/Software/nightglow-ios/nightglow-ios-main`)
Prototype: the sky lab on `main` (commits `4b0fd4e`…`8751b11`) — pods, the everyone view and emotes, simulated at ~100k awake.

## Goal

Today every other parent in Nightglow is simulated on the phone (`NightSky`).
0.2 designs the real thing for a **public App Store launch**: parents awake
right now appear as lights on the globe, grouped into **pods** of up to 100
who can send each other light and share how they're feeling, with a view-only
**everyone** globe and a true live count — for as little money and as little
server code as possible.

Explicitly not a goal: accounts, push notifications, chat or free text,
history beyond a few hours, or anything that works while the app is in the
background.

## Decisions at a glance

| Area | Decision |
|---|---|
| Audience | Public App Store launch. Paid Apple Developer Program ($99/yr) required anyway (TestFlight, App Attest) |
| Scale target | 100k monthly parents ≈ **5k online at peak**, no rewrite. Known path to 1M ≈ 50k online |
| Budget | ~$5–15/mo preferred, $20–30 fine at 100k monthly parents |
| Platform | **Cloudflare Workers + Durable Objects** (TypeScript), hibernating WebSockets, R2 for the everyone snapshot |
| Transport | One WebSocket per open app. Two-way isn't the reason — sleeping connections are (see below) |
| Presence | Online while the app is open (Light or Map); 60 s grace after backgrounding. The socket *is* the presence |
| Pods | Up to 100 people, drawn from **anywhere awake**; **per visit**; newcomers fill the pod that needs people most; nobody moved mid-visit |
| Pod view | Your pod's live lights (send light, see emotes) + dim **embers** of pod-mates who left in the last 6 h filling empty seats |
| Everyone view | Up to **15k** lights, a fair-share sample across ~100 km cells, refreshed every 30 s. **View only**; the pulsing there is simulated on the phone |
| Count | "N parents awake with you" is the **true** total, updated every ~5 s, in both views |
| Nudges | Real time (< 2 s), pod only, only while the recipient has the app open, never a push. Shows the sender's city. No meteor: the sender's light flares, yours brightens |
| Nudge limits | Send budget 10 lights, +1 per minute (the app's existing budget), **enforced on the server**. Recipient brightens at most every ~20 s, extras merged. "Don't brighten" setting |
| Emotes | Fixed set of 8, shown beside your light **to your pod only**; lasts until changed, cleared, or the visit ends; appears quietly |
| Location | "Place your light": search a city or postal code on-device, pick a spot inside a ~15–20 km circle. Rounded to ~500 m **on the phone** before it's sent |
| Identity | Anonymous. **App Attest** gates creating an install identity and getting session tokens. Dev bypass for the Simulator |
| Stored | Install registry only (durable). Presence, pods, embers, nudges: memory / per-object storage, gone within hours. Hourly totals in Workers Analytics Engine |
| Code | `server/` in `night-feed-app` (same PR can change app + server). Environments `dev` and `prod` |

## Scale model

Numbers everything below is sized against (the sky lab uses the same model):

- A visit lasts ~**24 min**; a parent sends ~**10 lights** per visit (their budget).
- Peak concurrency ≈ **5 % of monthly parents** (60 % open it on a given night,
  ~50 min each, concentrated in each time zone's 10pm–6am).
- Arrivals ≈ online ÷ 1,440 per second: ~3.5/s at 5k online, ~35/s at 50k.
- **Per pod of 100:** ~0.14 joins+leaves/s, ~0.7 nudges/s → about one change a
  second, fanned out to ≤ 100 phones. **Per phone: ~1 update/s, well under
  1 KB/s**, regardless of how big the app gets.
- **Incoming nudges:** if everyone spends their budget, each parent receives
  about one every 2½ minutes, whatever the pod size.
- **Everyone snapshot:** 15k lights × ~7 bytes ≈ 105 KB, rebuilt every 30 s,
  served from the CDN.

Pods are what make this cheap: real-time traffic only ever fans out to ≤ 100
phones, so total work grows linearly with the number of parents online instead
of with its square.

## Is two-way WebSocket communication really required?

Not for its two-way-ness. Phones send almost nothing (a brush, an emote). What
*is* required is the server **pushing** to a phone that's just sitting there —
a nudge must land in under two seconds. The options were polling, server-sent
events, or WebSockets. On Cloudflare, WebSockets win anyway:

- A **hibernating WebSocket costs nothing while idle** — the Durable Object
  sleeps between messages, protocol pings are answered without waking it, and
  outgoing messages aren't billed. Server-sent events keep the object awake.
- Polling fast enough for "real time" would cost a request per phone every
  couple of seconds and still feel laggy.
- **The open socket is the presence**: no heartbeats, no sweeping stale rows.
- iOS has it built in (`URLSessionWebSocketTask`) — no SDK.

The everyone view, by contrast, doesn't need a socket at all: it's a snapshot
fetched from the CDN.

## Why Cloudflare Workers + Durable Objects

Researched 2026-09-30 (sources at the end):

| Option | Why not / why |
|---|---|
| **Cloudflare DO** | Free plan has SQLite-backed DOs; paid plan $5/mo. Opening a socket = 1 request; incoming messages billed 20:1; **outgoing messages and pings free**; up to 32,768 hibernatable sockets per object. Fan-out cost is CPU, not per-message fees |
| Supabase Realtime | Bills every delivery (1 send + 1 per receiver); free tier 200 connections, 20 presence msgs/s, pauses after a week idle; Pro $25/mo |
| Firebase RTDB | Spark caps at 100 simultaneous connections; Blaze bills download per GB |
| Firestore | A listener pays a read per changed doc per watcher — presence fan-out burns the free quota at ~100 users |
| Ably / Pusher | Per-delivery billing; Pusher caps presence channels at 100 members; next tiers $29–49/mo |
| CloudKit | No real-time presence |

## Architecture

```
iPhone ──WebSocket──▶ Worker (edge, stateless)
                        │  verifies session token, asks the Lobby for a seat,
                        │  then hands the socket to that pod's host
                        ▼
                     Lobby DO (one)          pods and free seats; assigns newcomers
                        │
                        ▼
                     PodHost DOs (a few)     each hosts many pods (~2k sockets to start);
                        │                    presence, nudges, emotes, embers, budgets
                        │ roster deltas / 10 s, counts / 5 s
                        ▼
                     Sky DO (one)            true total; every 30 s builds the everyone
                        │                    snapshot (fair-share 15k) and writes it to R2
                        ▼
                     R2 bucket + CDN         GET /everyone.bin, cached 30 s at the edge

Worker ──▶ D1                                install registry (App Attest keys, bans)
Worker/DOs ──▶ Workers Analytics Engine      hourly totals
```

**Pods are logical, not one object each.** Cloudflare bills per *awake object*,
so many pods share a PodHost. v1 deploys **one** PodHost; adding hosts is a
config change the Lobby understands from day one. A busy host doesn't
hibernate, which is fine — its cost is what we budget for.

All object state that must survive hibernation lives in **socket attachments**
(`serializeAttachment`: member id, pod id, rounded position, tint, emote,
budget) and the object's **SQLite storage** (pod rosters, embers, lobby seat
table). Timers (grace expiry, merged-nudge delivery, ember pruning) use DO
**alarms**.

### Pods

- **Assignment** (Lobby): a newcomer joins the pod with the **fewest members**
  among pods with room; a new pod opens only when every pod is full. Pods are
  drawn from everyone awake — the day side of the planet isn't using a night
  light, so pods end up night-side neighbours anyway.
- **Per visit.** A visit survives drops shorter than the 60 s grace (network
  blip, quick app switch): the app reconnects with its signed **visit token**
  and goes straight back to its pod host. After that, the next open is a new
  visit and a new seat.
- **Never moved mid-visit.** As a night thins out, newcomers top up the
  emptiest pods instead.
- **Embers:** when a member's grace expires, the pod keeps
  `{rounded position, tint, left at}` for 6 h. Pod view shows the newest ones
  in the pod's **empty seats** (live + embers ≤ 100), so a pod of 10 at launch
  still shows a lit sky, and full pods show none. An empty pod is deleted with
  its embers.
- **Member ids** are small per-visit numbers inside the pod. No install id is
  ever sent to another phone.

### Everyone view

- Each PodHost sends the Sky DO roster deltas (placed members' rounded
  position + tint) every 10 s and its counts every 5 s.
- Every 30 s the Sky DO runs the **fair-share (water-filling) rule** over ~1°
  (~100 km) cells: find the one per-cell limit L where Σ min(count, L) = 15k.
  Quiet places keep everyone, only crowded cells are trimmed, and if the app is
  only popular in one country, L rises until the 15k budget is used.
- Encodes it compactly (24-bit lat, 24-bit lon, tint byte ≈ 7 bytes/light,
  ~105 KB) and writes `everyone.bin` to R2 behind the custom domain with
  `Cache-Control: max-age=30`. Phones in the everyone view fetch it every 30 s;
  edge cache hits don't touch the Worker or R2.
- No emotes, no sending, no real brightening. The phone simulates gentle
  pulsing across the dots at the modelled rate.

### Count

The Sky DO sums every host's connected sockets (placed or not) and pushes the
total to each PodHost every ~5 s; hosts broadcast it to their sockets. The
phone animates the number.

## Protocol (v1)

JSON text frames over `wss://api.<domain>/sky?v=1`. Positions are always the
already-rounded ones.

Phone → server

| Message | Meaning |
|---|---|
| `hello {token, visit?, place?: {lat, lon, label}, tint}` | First frame. `visit` present = resuming within grace. No `place` = hasn't placed their light |
| `light {to: [memberId]}` | Brushed these pod-mates. Server checks pod membership and the 10 + 1/min budget; over-budget ids are dropped |
| `feel {emote \| null}` | Set or clear emote (≤ 1 per 5 s) |
| `bye` | Leaving now (skip the grace) |

Server → phone

| Message | Meaning |
|---|---|
| `welcome {visit, you: memberId, pod: [member], embers: [ember], count, budget}` | Seat granted. `member = {id, lat, lon, tint, emote?, label}` (no position if unplaced → no dot) |
| `joined [member]`, `left [id]` | Batched once a second |
| `glow [id]` | Pod-mates who were just sent light (by anyone in the pod) — brighten them. Batched once a second |
| `lit {from: [memberId], labels: [city]}` | Light sent **to you**. First one immediately; more within 20 s are held and delivered merged |
| `felt {id, emote \| null}` | A pod-mate changed how they feel |
| `count n` | True total, every ~5 s |
| `budget {left, next}` | After spending, so the button stays honest |
| `upgrade` / `denied {reason}` | Unsupported version / bad or banned token |

Everyone snapshot: `GET https://sky.<domain>/everyone.bin` (binary, above).

## Identity and abuse

- **First launch:** the app creates an App Attest key, gets a challenge from
  `POST /register`, and sends the attestation. The Worker verifies Apple's
  certificate chain, the challenge and the App ID, and stores
  `{install id, key id, public key, counter, created, banned}` in **D1**.
- **Session tokens:** `POST /session` with a fresh App Attest **assertion**
  over a server challenge returns an HMAC-signed token valid ~12 h. Opening a
  socket needs only the token, so a connect costs no database write. (Q7 said
  "at identity creation and each connection" — this keeps the spirit with one
  assertion per token rather than per socket; confirm in refine.)
- **Dev bypass:** in `dev` only, a shared debug secret replaces attestation, so
  the Simulator and `wrangler dev` work. Strict attestation is on in `prod`
  before launch.
- **Limits:** send budget and emote rate enforced per visit in the PodHost;
  the Lobby caps new visits per install (~6/min) so reconnecting can't refill
  a budget. Bans are an install-registry flag checked when minting tokens.
- Nudges carry no content and emotes are a fixed set — nothing to moderate.

## Location: place your light

Client-only; no geocoding backend.

1. First time the Map opens: "Place your light" → search a city or postal code
   with `MKLocalSearch` (works worldwide, free).
2. Show a ~15–20 km circle over the result; the parent drags their light
   anywhere inside it. The circle is there so people who don't read maps well
   can orient themselves.
3. Store the chosen point and the result's city label locally (UserDefaults).
   Before it's ever sent, **round to ~500 m** — smaller than a light at the
   closest zoom (120 km camera), so it's invisible, but a pin dropped on a
   house doesn't leave the phone.
4. Changeable any time. Not placing is fine: you can still send light, you
   count in the total, you just have no dot and can't be sent light or emote
   (open item Q22).

## Costs (rough)

| | 100k monthly (~5k online) | 1M monthly (~50k online) |
|---|---|---|
| Workers Paid base | $5 | $5 |
| DO duration (Lobby + Sky + PodHosts, mostly awake at night) | ~$5–10 | ~$60–70 |
| Requests (connects, incoming frames at 20:1, snapshot misses) | ~$1–2 | ~$15 |
| D1, R2, Analytics Engine | free tiers | ~$0–5 |
| **Total** | **~$10–20/mo** | **~$80–100/mo** |

Plus $99/yr Apple Developer Program and ~$10–15/yr for a domain. The load test
in step 7 replaces these estimates with measured numbers.

## Environments and layout

```
night-feed-app/
  Nightglow/…            iOS app (XcodeGen, as today)
  server/
    wrangler.toml        envs: dev, prod (separate DOs, D1, R2)
    src/worker.ts        routing, /register, /session, /sky upgrade
    src/lobby.ts         Lobby DO
    src/podHost.ts       PodHost DO
    src/sky.ts           Sky DO (count, fair-share snapshot → R2)
    src/protocol.ts      message types shared by tests
    src/fairShare.ts     water-filling, pure and unit-tested
    src/attest.ts        App Attest verification
    test/…               vitest + @cloudflare/vitest-pool-workers
    tools/loadtest.ts    opens N fake phones against dev
```

- Debug builds → `dev` (bypass allowed); Release/TestFlight → `prod`.
- Deploys: `wrangler deploy --env dev|prod` by hand to start; CI later.
- Domain: `api.<domain>` (Worker) and `sky.<domain>` (R2 + CDN). Dev can use
  `*.workers.dev` until then (Q24).

## App changes

- **`SkySource` protocol** between the views and where the sky comes from:
  `LiveSky` (the socket + snapshot) and `SimulatedSky` (today's `NightSky`,
  kept for development, demos and screenshots — it already models pods, the
  everyone view, emotes and the ~100k count). Debug setting picks.
- **`LiveSky`:** connect on foreground, send `bye` on background, resume with
  the visit token inside 60 s; exponential backoff; if the sky can't be
  reached, Light mode is unaffected and the Map says so quietly.
- Pod view / everyone view / emote picker / embers come from the prototype
  (`SkyLayout`, `EmotePicker`); the lab controls and stats line stay debug-only.
- Nudge coalescing, "don't brighten" setting, and brightening on `lit`
  follow Q12.
- Place-your-light onboarding (above).
- App Attest registration + token refresh.
- Privacy label: coarse location (user-chosen, not linked to identity); no
  tracking.

## Implementation steps

Each step is a commit (or a few) on `feat/backend` in night-feed-app.

1. **Server skeleton:** `server/` with wrangler, the three DOs, protocol types,
   dev-bypass tokens; `welcome`/`joined`/`left`/`count` working for one pod.
   Tests: seat assignment (fewest-members, new pod only when all full), grace
   resume, empty pod deletion.
2. **Light and feelings:** `light` with membership + budget checks, `glow`
   batching, `lit` with 20 s merge; `feel`/`felt` with rate limit; embers
   filling empty seats. Tests for budgets, merge window, ember ordering/expiry.
3. **App on the live sky:** `SkySource`, `LiveSky`, pod view on real data
   against `wrangler dev` from the Simulator and both phones.
4. **Everyone view:** roster deltas → Sky DO → fair-share → R2 → CDN; app
   fetch + simulated pulsing. Tests: `fairShare` (sparse keeps all, dense
   trims evenly, budget always met when possible).
5. **Place your light:** search, circle, placement, rounding, label.
6. **App Attest:** `/register`, `/session`, D1 registry, bans; strict in prod.
7. **Load test and cost check:** `tools/loadtest.ts` holding ~2–5k sockets on
   dev with the modelled traffic; measure PodHost CPU, latency and the
   dashboard's projected bill; set sockets-per-host from it.
8. **Prod:** domain, prod env, TestFlight build pointed at prod.

## Verification

- `npm test` in `server/` green (assignment, grace, budgets, merge window,
  embers, fair-share, attestation parsing with Apple's sample vectors).
- Two phones on dev: both in one pod, see each other's lights and emotes,
  light lands in < 2 s, merged when spammed, budget refills.
- Kill the network for 30 s → same pod on return; for 90 s → new visit, the
  old light becomes an ember for the other phone.
- Everyone view shows the fair-share sample and refreshes; count moves.
- Load test at 5k sockets: p95 nudge delivery < 2 s, host CPU headroom,
  projected monthly cost within budget.

## Decisions log

| # | Question | Decision |
|---|---|---|
| Q1 | Audience | Public App Store launch |
| Q2 | Budget | $5–15/mo preferred, $20–30 OK |
| Q3 | Empty sky | Real parents only + "earlier tonight" embers; simulator kept for dev |
| Q4/Q10 | Location | Place your light via city/postal search and a circle; rounded ~500 m on device; city label on nudges; placing only needed to appear |
| Q5 | Nudges | Foreground only, never push, sender's city shown, no nudge-back yet |
| Q6/Q9.1 | Real time | Nudges real time; no meteors — brightening only |
| Q7 | Identity | Anonymous + App Attest |
| Q8 | Scale | 100k monthly ≈ 5k online; path to 1M |
| Q9.2 | Many parents | Pods of ≤ 100 + view-only everyone view of 15k (fair-share), after trying Everyone/Merge/Slice/Near+far/Spread in the lab |
| Q11 | Presence | App open + 60 s grace |
| Q12 | Limits | 10 + 1/min send budget (server), recipient ≤ 1 brighten / 20 s merged, "don't brighten" setting |
| Q13 | Platform | Cloudflare Workers + DOs, hibernating WebSockets |
| Q14 | Code | `server/` monorepo, dev + prod |
| Q15 | Stored | Install registry only; hourly totals |
| Q16 | Pod makeup | Drawn from anywhere awake |
| Q17 | Pod lifetime | Per visit (survives the 60 s grace) |
| Q18 | Thinning pods | Never move people; newcomers top up emptiest pods |
| Q19 | Pod view | Pod + embers; nothing else |
| Q20 | Everyone view | Fair-share 15k, no pod highlight, simulated pulsing, no "warmed recently" data |
| Q21 | Emotes | Fixed 8, until changed/cleared/visit ends, quiet |

## Open items (confirm in refine)

- **Q22 — unplaced parents** *(assumed)*: join a pod and take a seat, can send
  light, no dot, can't be sent light or emote, count in the total.
- **Q23 — embers** *(assumed, as prototyped)*: fill empty seats only, newest
  first, 6 h window.
- **Q24 — domain** *(assumed)*: buy one before launch; dev on `workers.dev`.
- One App Attest assertion per ~12 h session token rather than per socket.
- Sockets per PodHost (start ~2k), set by the load test.
- Emote art: custom glyphs in the glow style (the prototype uses SF Symbols).

## Sources

- Durable Objects pricing — https://developers.cloudflare.com/durable-objects/platform/pricing/
- DO WebSocket hibernation / state — https://developers.cloudflare.com/durable-objects/api/state/
- Workers pricing — https://developers.cloudflare.com/workers/platform/pricing/
- Supabase Realtime limits / message counting — https://supabase.com/docs/guides/realtime/limits, https://supabase.com/docs/guides/platform/manage-your-usage/realtime-messages
- Firebase pricing — https://firebase.google.com/pricing ; Firestore pricing — https://firebase.google.com/docs/firestore/pricing
- Ably message counting — https://ably.com/docs/platform/pricing/message-counting ; Pusher presence limits — https://pusher.com/docs/channels/using_channels/presence-channels/
- Apple capabilities by membership — https://developer.apple.com/help/account/reference/supported-capabilities-ios
