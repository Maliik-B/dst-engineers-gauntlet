# Engineer's Gauntlet

A co-op **wave-defense** mode for **Don't Starve Together** — and a netcode portfolio piece.
Escalating, server-authoritative attacker waves path to a defended objective (the *Engine*); players
hold the line with a character-agnostic defense layer of buildable auto-turrets and a commandable
minion. Its centerpiece is a **measured naive-vs-optimized** comparison you can toggle live
(`c_naive`), with a companion document explaining the three core network decisions with `file:line`
evidence.

**Status:** v1 feature-complete, balanced, and playable end-to-end (craft the Engine, run a gauntlet,
repair and retry) — and **[live on the Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3753820770)**.
M0–M5, a Klei-quality parity/balance pass, and M6 (writeup + Workshop release) are all done.

**Naive vs optimized** — the same ~300-attacker scene, one `c_naive` flag, toggling the deliberately-naive strawman off:

https://github.com/user-attachments/assets/f645b4ff-59e8-4dfa-a945-a6090048bd3b

*(Inline player on GitHub. Headline flips: netvar churn **1,500 → 0/s**, and off-screen `updating_ents` **326 → 29** — full breakdown in [the netcode doc](docs/netcode-decisions.md).)*

## The mode

You spawn with a starter kit, so you can set up right away. Craft and place the **Engine** where you
want to make a stand, then activate it (**"Begin the Gauntlet"**) to start a run. Waves of attackers
spawn around it on an escalating timer and path straight to it. Kiting is part of the game — the attackers
just leash to the Engine (they chase a defender only a short way, then return, and let go if you drag
them too far), so you can't walk the whole wave off and cheese it. Past that it's open: normal play
plus the attacker mix and the climbing intensity make for increasingly hectic, fun, and semi-unique fights,
within a run and across runs. You
hold the line with the defense layer (any character — nothing is locked to Winona):

- **Gauntlet Sentry** — a buildable auto-turret. Acquires the nearest threat and lobs an AOE shot,
  self-repairs over time, and is build-capped with anti-stacking spacing so four turrets have to
  cover a footprint instead of death-balling one tile.
- **Gauntlet Sentinel** — a minion you own and command. The held **Sentinel Commander** issues three
  orders by right-click: **defend** a point, **follow** you, or **focus** an enemy.

Three attacker types ramp in as the run hardens: a baseline **Besieger**, a fast fragile
**Swarmling**, and a tanky **Breaker** that hunts your defenses specifically. Hold for the configured
number of waves to win. If the Engine falls you lose the run — but it's left a broken wreck you can
**repair** with cutstone (rather than rebuild from scratch) and run again.

## Engineering highlights

This is built as a work sample, so the interesting parts are under the hood:

- **Server-authoritative by construction.** All gameplay truth — waves, spawning, AI, damage,
  win/lose — runs on the master sim behind `ismastersim` guards. Clients render that truth and send
  validated *intent* only; they never assert state or spawn gameplay entities.
- **Disciplined replication.** Persistent state rides quantized netvars diffed on real change
  (wave → `net_smallbyte`, phase → `net_tinybyte`, objective HP → a `net_byte` bucket); transient
  events ride one batched RPC per wave, never one per spawn.
- **A second, richer RPC surface.** Minion commands are a client→server intent RPC — `(verb, x, z)`
  scalars, server-validated in layers (type → enum → ownership → range clamp) — driving
  server-authoritative follower AI.
- **A measured optimization, not a claimed one.** One `c_naive` flag flips a deliberately-naive
  strawman against the shipped path on an identical scene, and the before/after is measured on one
  machine: updating-entity count, netvar churn, RPC volume, scan-ops, and bracketed compute.

**→ Full writeup: [`docs/netcode-decisions.md`](docs/netcode-decisions.md)** — three network
decisions, each with `file:line` evidence in this repo *and* the shipped DST pattern it follows, plus
the measured A/B table and its caveats.

## Install & run

Requires **Don't Starve Together** (mod API v10; not Don't Starve / RoG). It's a server-side gameplay
mod (`all_clients_require_mod = true`), so the host/server is authoritative and every player in a
session needs it — DST auto-downloads it for clients joining a server that runs it.

- **Steam Workshop:** [Engineer's Gauntlet](https://steamcommunity.com/sharedfiles/filedetails/?id=3753820770)
- **From source:** copy (or symlink) this repo's `mod/` folder into your DST `mods/` directory as
  `engineers-gauntlet`, then enable **Engineer's Gauntlet** in the in-game Mods menu.

  ```
  <Don't Starve Together>/mods/engineers-gauntlet/   ←  this repo's  mod/
  ```

### Running a gauntlet

**In-world (the normal way):** you spawn with a starter kit — equipment plus the materials for the
Engine, two Sentries, and two Sentinels, with the recipes unlocked on first spawn. Craft and place
the **Engine**, then **left-click it → "Begin the Gauntlet"**. Hammer it to relocate; if it's
destroyed, **repair the wreck with cutstone** to run again.

**Console harness (headless / admin / the netcode demo):** open the console with `~`, toggle remote
(server-side) execution with `Ctrl`, then:

| Command | What it does |
|---|---|
| `c_gauntlet_place()` | Drop the Engine at your position (admin / headless shortcut) |
| `c_gauntlet_start()` / `c_gauntlet_stop()` | Begin the countdown / stand down |
| `c_gauntlet_kit()` | Grant the starter kit + unlock recipes on the calling player |
| `c_gauntlet()` | Liveness + siege-state readout |

Demo / stress harness, for reproducing the netcode A/B:

| Command | What it does |
|---|---|
| `c_stress(n)` | Slam *n* attackers on the Engine immediately |
| `c_naive(true/false)` | Flip the naive ↔ optimized path for the whole arena, live |
| `c_metrics()` / `c_metrics_reset()` | Perf readout: compute, scan-ops, updating-ents, churn, RPC volume |
| `c_breaker(n)` / `c_swarmer(n)` | Spawn a specific attacker type |

Balancing rides DST's built-ins (`c_godmode`, `c_freecrafting`, `c_speedmult`) — those aren't rebuilt
here. Every knob lives on `TUNING.GAUNTLET_*` and is read live, so you can retune mid-run.

## Configuration

In-game **Mods → Engineer's Gauntlet → Configure**:

| Option | Default | Choices | Effect |
|---|---|---|---|
| **Wave Size** | 6 | 4 / 6 / 10 / 20 / 80 | Base attackers per wave — the load dial; scales the tuned per-wave counts. "Stress (80)" drives the netcode A/B. |
| **Waves to Survive** | 5 | 3 / 5 / 8 / 12 | How many waves the Engine must hold for victory. |
| **Wave Interval** | 60s | 30 / 60 / 90s | Breathing room between waves, in seconds. |

## Architecture at a glance

The master sim owns all gameplay truth — wave logic, spawning, AI, damage, win/lose — behind
`ismastersim` guards. Clients render that truth and send *intent* only: placing a defense or
commanding a minion is a client→server RPC carrying scalars, which the server validates and acts on.
Persistent replicated state (wave, phase, objective HP) rides quantized netvars diffed on real
change; transient events (a wave starting) ride one batched RPC. All RPC handlers register in
`modmain` so every process builds identical tables in the same order — v1 is single-shard, but the
architecture is shard-aware so the planned Master + Caves expansion is a growth, not a rewrite.
Details with `file:line` evidence are in [`docs/netcode-decisions.md`](docs/netcode-decisions.md).

## Development

The repo's `mod/` folder is junctioned into the DST mods directory, so edits here are live in-game
after a world reload:

```bat
mklink /J "C:\Program Files (x86)\Steam\steamapps\common\Don't Starve Together\mods\engineers-gauntlet" "D:\Applications\dst-engineers-gauntlet\mod"
```

Run the local offline dev server (single shard) with `tools\run-server.bat`, then connect from the
DST client's main-menu console: `c_connect("127.0.0.1", 10999)`. (Same-host LAN-tab discovery is
unreliable — direct connect always works. A headless dedicated server never triggers Windows'
allow-access prompt, so LAN visibility needs `tools\allow-firewall.ps1` run elevated.)

Console: `~` opens it; `Ctrl` toggles **remote** (server-side) execution — requires your id in the
cluster's `adminlist.txt`. Offline servers authenticate clients with offline ids (`OU_<steamid64>`),
not Klei `KU_` ids — use the `OU_` id shown in the server log on connect.

Dev loop: edit Lua → `c_reset()` in the console (reloads world + mod code) → test. Changes to
`modmain`/`modinfo`/new prefab files need a full server restart, not `c_reset`.

## Milestones

| # | Milestone | Status |
|---|---|---|
| M0 | Dev env: local dedicated server, console access, mod skeleton | ✅ done |
| M1 | Core wave loop: siege manager, timed waves, objective HP, win/lose, player-centric harness | ✅ done |
| M2 | Load dial + deliberately-naive baseline, first measurements | ✅ done |
| M3 | Optimization pass: sleep/wake discipline, quantized netvars, batched RPCs | ✅ done |
| M4 | Defense layer: buildable auto-turret + commandable minion (command RPC) | ✅ done |
| M5 | Attacker roster, on-screen siege HUD, examine/feedback polish, config menu | ✅ done |
| — | Klei-quality parity + balance pass (first-party affordances, hound-anchored tuning) | ✅ done |
| M6 | Writeup + Workshop release | ✅ done |

## Known limitations

- **Single-shard (forest only).** A Master + Caves split is the v2 plan; the netcode is built
  shard-aware for it, but v1 does not span shards.
- **No entity pool yet** — a hard concurrent-attacker cap bounds runaway spawning instead. A true
  pool is deferred on purpose (the invincible-objective demo never recycles attackers, so a pool
  would show nothing here; see the netcode doc).
- **Quantized HP is lossy by design** (0.5% steps) — correct for a health bar; server logic always
  reads real `health`, never the replicated bucket.
- **No client-side prediction** on commands — under high latency the order-to-action gap is visible.
  An acceptable trade for co-op PvE.

## Attribution

Built on Klei's shipped DST patterns and assets — **no new art beyond recolors**:

- Wave loop modeled on `hounded.lua` (worldsettings timer + drip-release).
- The sieged objective follows the moonbase siege precedent (moonbeast spawner / brain).
- The auto-turret follows the eyeturret / Houndius-Shootius pattern; its art is a recolored Winona
  catapult.
- The minion reuses the Clockwork Knight art + stategraph; the Sentinel Commander reuses the Winona
  remote art.
- Reverse-engineered pattern citations throughout reference Klei's shipped Lua source, which is not
  redistributed here.

Code and design by **Maliik Bryan**.
