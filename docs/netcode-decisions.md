# Engineer's Gauntlet — netcode decisions

Three defensible networking decisions, each with `file:line` evidence in this repo and the shipped
DST pattern it follows. Paths are relative to the repo root; `scripts/...` paths refer to Klei's
shipped source (the reference for the idiom, not included in this repo). Shipped-source line numbers
were verified against the DST `scripts.zip` dated 2026-06-25 (the build current at the time of
writing); the cited files were unchanged by the intervening *From Beyond* carnival update.

> The three decisions map to the three classes of network traffic in the mod: **who may write
> state** (authority + the client→server command channel — Decision 1), **which primitive carries
> server→client data** (persistent state vs transient events — Decision 2), and **what that
> discipline buys under load** (the measured common-case win — Decision 3).

## 1. Server-authoritative simulation; clients send validated intent

DST's cardinal multiplayer rule is that **the server owns gameplay truth.** Client-authoritative
game logic is an exploit surface and a desync risk — a client that can write state can cheat it or
drift from its peers — so every piece of gameplay truth in this mod (wave scheduling, spawning,
attacker and minion AI, damage, win/lose) runs on the master sim. Clients render that truth and
*propose* actions; they never assert state.

**The authority guard is uniform.** Every networked prefab declares its netvars, calls
`SetPristine()`, then returns early on the client before any server-only component is added — the
shipped `burntground` idiom (`scripts/prefabs/burntground.lua:69`). The objective
(`mod/scripts/prefabs/gauntlet_objective.lua:182`), the minion
(`mod/scripts/prefabs/gauntlet_minion.lua:286`), and the attacker
(`mod/scripts/prefabs/gauntlet_attacker.lua:128`) all do exactly this. World-side logic is
master-gated the same way: the siege manager and metrics components attach only `if inst.ismastersim`
(`mod/modmain.lua:553-558`) and each re-asserts it on construction
(`mod/scripts/components/siegemanager.lua:22`, `mod/scripts/components/gauntletmetrics.lua:44`), so a
client build can never instantiate server logic.

**The client→server channel is the richer surface — and the one to read closely.** Minion commands
are intent, not action: the held *Sentinel Commander* reads the cursor to pick a verb (enemy → FOCUS,
self → FOLLOW, ground → DEFEND; `mod/modmain.lua:401-411`) and sends three scalars —
`(command_enum, x, z)` — over a client→server mod RPC (`mod/modmain.lua:502-503`). It never sends an
entity reference and never touches command state. The server handler (`mod/modmain.lua:359-394`) then
validates in the exact layered idiom shipped DST handlers use (`LeftClick`,
`scripts/networkclientrpc.lua:77-104`):

1. **Type-check every argument up front**, using the engine's own global validator (`checknumber`,
   `scripts/networkclientrpc.lua:5`) with a local fallback so the handler is robust even if the
   global moves (`mod/modmain.lua:357`, checked at `:361`).
2. **Range-check the enum** — only DEFEND/FOLLOW/FOCUS pass (`mod/modmain.lua:365-370`).
3. **Existence/ownership** — the sender must be a player that can own minions
   (`mod/modmain.lua:372-374`).
4. **Anti-cheat range clamp** — the commanded point must be near the sender, mirroring the shipped
   `IsPointInRange` distance gate (`distsq <= 4096`, `scripts/networkclientrpc.lua:43-45`); ours uses
   `GAUNTLET_COMMAND_MAX_DIST` (`mod/modmain.lua:377-380`) so a client can't direct minions to
   arbitrary world coordinates.
5. **Apply to the sender's own followers only** (`mod/modmain.lua:383-387`).

A malformed or hostile RPC falls through every guard and changes nothing — the same posture as
`printinvalid` in shipped handlers (`scripts/networkclientrpc.lua:18`). UI-consumed clicks never
reach the in-world handler at all (the control handler registers at `mod/modmain.lua:522-524`, and
the engine drops clicks the HUD already consumed), so there are no spurious commands.

**The AI the command drives is itself server-authoritative.** The command mode is server-owned state
with exactly one writer — `SetMinionCommand` on the master
(`mod/scripts/prefabs/gauntlet_minion.lua:144-174`) — which mirrors it into a replicated
`net_tinybyte` for display (Decision 2). The minion's brain runs only on the master and the engine
tears it down on sleep (`mod/scripts/brains/gauntletminionbrain.lua:7-8`); it branches its movement
on the current command (`:44-55`), while combat target acquisition and the anti-kite leash are
server-side retarget/keep-target functions (`mod/scripts/prefabs/gauntlet_minion.lua:54-84`, wired at
`:342-343`). The client proposes; the server decides and simulates.

**Two RPC surfaces, registered shard-safe.** The command RPC is a client→server handler in its own
id space (`AddModRPCHandler`, `scripts/networkclientrpc.lua:1834`), kept separate from the two
server→client wave RPCs (`AddClientModRPCHandler`). All three register unconditionally in `modmain`
in a fixed order, because the engine assigns RPC ids by registration order within a namespace
(`scripts/networkclientrpc.lua:1844`) and every process — server, every client, and both shard
processes in the v2 plan — must build identical tables. v1 is single-shard, but registering in
`modmain` (not behind an `ismastersim` branch) is what makes the Master+Caves expansion a growth
rather than a rewrite.

## 2. netvar vs RPC — the right primitive for each traffic shape

DST gives two ways to move data from server to client, and they are not interchangeable. The mod
uses each for what it's good at: **persistent replicated state → quantized netvars, diffed on real
change; transient events → one batched RPC.**

**Persistent state rides netvars.** The siege's durable, public state lives on the objective as four
netvars, each declared on both server and client before `SetPristine()` — the hard rule that a
netvar must exist identically on every process or deserialization fails (`scripts/netvars.lua:29`):

- **wave number** → `net_smallbyte` (`[0..63]`), following the shipped `burntground._fade` counter
  (`scripts/prefabs/burntground.lua:63`) — `mod/scripts/prefabs/gauntlet_objective.lua:172`
- **siege phase** → `net_tinybyte` (`[0..7]` enum: idle/prep/active/victory/defeat), following the
  world clock's phase (`scripts/components/clock.lua:90`) — `:173`
- **objective HP** → `net_byte` bucket — `:174`
- **wave total** → `net_smallbyte`, so the HUD reads the server's run length, not the client's local
  config — `:178`

Two disciplines make this cheap. **Sizing:** each variable is the smallest type that fits its range —
a wave counter doesn't need 32 bits. **Diff-on-change:** the server calls `set()` only when the value
actually moved, and the engine fires the dirty event only on a real change anyway
(`scripts/netvars.lua:47`). Wave and phase change a handful of times per run
(`mod/scripts/components/siegemanager.lua:62-84` → `mod/scripts/prefabs/gauntlet_objective.lua:92-104`).
HP is the interesting one: it's a *continuous* value, so replicating it raw would churn every damage
tick. Instead it's quantized into the byte as `floor(frac*200+.5)` — the exact shipped
health-penalty quantization (`scripts/components/health_replica.lua:66`, decoded `/200` at `:42`) —
and `set()` only when the bucket changes (`mod/scripts/prefabs/gauntlet_objective.lua:40-49`, decoded
client-side at `:129`). A 1000-HP engine chipped to death produces at most ~200 replication events
over its entire life. Per-entity command state uses the same playbook: the minion's command mode is
one `net_tinybyte` (`mod/scripts/prefabs/gauntlet_minion.lua:282`) written only on change (`:112-115`).

**Transient events ride RPCs.** A wave starting is not durable state — it's a one-shot event with a
payload. So it's a single batched `GauntletWaveIncoming(wave, count, tier)` sent once per wave
(`mod/scripts/components/siegemanager.lua:190`, fired from `StartWave` at `:357` and from a `c_stress`
dump at `:556`), registered client-side in `modmain` (`:343`). An RPC is the right tool here
*precisely because* a netvar is the wrong one: a netvar carries no atomic multi-field payload, and
re-entering the same wave value wouldn't re-fire without a force-dirty hack. Server→client RPCs are
also trusted and unrated (`scripts/networkclientrpc.lua:1406`), so the only thing that matters is
send *volume* — which is the whole point of batching.

**The split, stated as a rule:** if a late-joining client needs to know it on sync, it's state →
netvar (the joiner reads current wave/phase/HP immediately). If it's a momentary "this just
happened," it's an event → RPC (a joiner simply missed the banner; no harm). The naive strawman in
Decision 3 violates both halves at once — it puts transient per-attacker proximity on a churning
`net_float` (`mod/scripts/prefabs/gauntlet_attacker.lua:124`) *and* fires a per-spawn RPC flood —
which is exactly what makes it a useful thing to measure against.

---

## 3. The common-case performance win

**The claim.** Under identical load — 300 attackers, the same scene, one `c_naive` flag — the
optimized path keeps every netcode-relevant cost near zero by *doing nothing when nothing is
changing*. The dial (`c_naive`, `mod/modmain.lua:679`, flipping `siegemanager:SetNaive`,
`mod/scripts/components/siegemanager.lua:571`) flips a deliberately naive strawman against the
shipped path so the before/after is measured on one machine, one scene.

It rests on three mechanisms, each grounded in a shipped DST pattern.

### 3a. Sleep-aware per-entity work

DST does **not** auto-stop a component's `OnUpdate` when its entity goes to sleep — the engine's
update loop has no asleep filter (`scripts/update.lua:256-268`), so a component must stop *itself*,
exactly as `Combat` does (`scripts/components/combat.lua:289-323`). The naive load component never
does: it stays in the update set even when the whole horde is off-screen and asleep. The optimized
component self-stops on `OnEntitySleep` and re-registers on `OnEntityWake`
(`mod/scripts/components/gauntletload.lua:128`, `:136`), and while awake it runs only a throttled
scan — a period with a random phase, the cadence `Combat:SetRetargetFunction` gives its retarget
task (`mod/scripts/components/gauntletload.lua:140-167`, period
`TUNING.GAUNTLET_LOAD_SCAN_PERIOD` at `mod/modmain.lua:96`).

> **Measured:** off-screen `updating_ents` **326 → 29**; awake scan-ops **450 K/s → 66 K/s**.

### 3b. Replicate only what clients need — quantized and diffed

The naive path re-`set()`s a per-attacker `net_float` every tick
(`mod/scripts/components/gauntletload.lua:158`): continuous replication churn for a value clients can
already derive from the transforms the engine replicates for free. The optimized path recognizes it
as redundant and simply never writes it — the declaration stays (a netvar can't be conditionally
declared without breaking deserialization, `mod/scripts/prefabs/gauntlet_attacker.lua:124`), but
zero `set()` calls means zero churn.

The value clients *do* need — objective HP for a health bar — is replicated the correct way: a
continuous fraction quantized into a `net_byte` bucket as `floor(frac*200+.5)` (the shipped
health-penalty quantization, `scripts/components/health_replica.lua:66`) and `set()` **only when
the bucket actually changes** (`mod/scripts/prefabs/gauntlet_objective.lua:40-49`, declared
`:174`, decoded client-side `:129`). `set()` dirties on real change only
(`scripts/netvars.lua:47`), so chipping a 1000-HP engine to death produces at most ~200 replication
events over its entire life rather than one per damage tick.

> **Measured:** netvar churn **1,500/s → 0/s**.

### 3c. One batched event, not a per-spawn flood

The naive path fires one `SendModRPCToClient` per attacker as it spawns
(`mod/scripts/components/siegemanager.lua:286`). The optimized path sends one batched
`GauntletWaveIncoming(wave, count, tier)` per wave — or per `c_stress` dump —
(`mod/scripts/components/siegemanager.lua:190`, sent at `:357`). Server→client RPCs are trusted and
unrated (`scripts/networkclientrpc.lua:1406`), so the cost on display is purely send *volume*. Both
handlers register in a fixed order in `modmain` so the registration-order-assigned ids line up on
every process (`mod/modmain.lua:339`, `:343`).

A hard concurrent-attacker cap (`TUNING.GAUNTLET_MAX_ATTACKERS`, `mod/modmain.lua:109`, enforced as
back-pressure at `mod/scripts/components/siegemanager.lua:302`) bounds runaway spawning so the server
can't be driven into the floor. A true entity pool was considered and deferred: the demonstration's
objective is invincible, so attackers never die/recycle and a pool shows nothing here, and recycling
DST mobs means short-circuiting the death stategraph + lootdropper + corpse pipeline — invasive, and
against the "feels native" bar. The cap delivers the safety benefit at a fraction of the risk.

> **Measured:** spawn RPCs per 300 attackers **300 → 2** (one batched send per `c_stress` call).

### How it was measured — and the honest caveats

A master-sim metrics component samples once per tick
(`mod/scripts/components/gauntletmetrics.lua`). It reports, with the trustworthy integer counters
first:

| axis | optimized (`c_naive` off) | naive (`c_naive` on) | scene |
|---|---|---|---|
| `updating_ents` | **29** | 326 | off-screen / asleep |
| load compute | **11 ms/tick** | 109 ms/tick | on-screen, awake |
| scan-ops | **66 K/s** | 450 K/s | on-screen, awake |
| netvar churn | **0/s** | 1,500/s | on-screen, moving |
| spawn RPCs (per 300) | **2** | 300 | at spawn |
| server frame *(obs)* | ~107 ms (9 fps) | ~185 ms (5 fps) | on-screen, awake |

**Measurement integrity.** An earlier version derived "MSPT" from the wall-clock interval *between*
ticks, which the dedicated server's variable frame pacing confounds (idle it throttles to ~30 fps;
lightly loaded it free-runs uncapped at 80–200 fps), so the fps swung on pacing, not work. The
compute figure now **brackets the actual per-entity work**: each load `OnUpdate` wraps itself in
`os.clock()` and reports the elapsed (`mod/scripts/components/gauntletload.lua:141`, `:173`), which
the metrics component accumulates over a one-second window and divides by the ticks in that window
(`mod/scripts/components/gauntletmetrics.lua:72`, `:122`). `os.clock()` is ~1 ms resolution, so a
single sub-ms scan often brackets to zero — but the quantization is *unbiased* (a scan straddles a
clock edge with probability proportional to its true length), so the windowed sum over thousands of
calls converges to the true total. The `scan-ops` count is an exact integer cross-check that needs
no clock at all. The `frame` figure is retained but explicitly observational: it answers only
"is the server below 30 fps," not "how much compute."

**Honest scope of the win.** The `compute` metric measures *only* the load component, so the naive
strawman's own cost is the headline 109 ms/tick. The whole-server *frame* (107 / 185 ms) is dominated
by something the flag doesn't touch: ~300 **awake** DST mob brains and stategraphs cost ~80–100
ms/tick on one screen regardless. The naive load roughly doubles that on top, but neither path holds
30 fps with 300 awake mobs rendered at once — and that is a gameplay-scaling reality, not a netcode
one. It is precisely *why* DST leans on sleep/offscreen, and why this optimization's designed win is
the **common case**: a horde you are not looking at costs ~0 (`updating_ents` and `compute` collapse
when it sleeps), and the bandwidth axes (churn, RPC volume) stay flat whether or not anyone is
watching. The integer axes — `updating_ents`, churn, RPC, scan-ops — are the clean story; `frame`
is context.

### Failure modes / where this would need more

- **Quantized HP is lossy by design** — 0.5% steps. Fine for a bar; a mod reading exact HP off the
  netvar would be wrong. Server-side logic reads the real `health` component, never the bucket.
- **The dropped `net_float` assumes clients can derive proximity from replicated transforms** — true
  for relevance-range entities; a feature needing exact off-relevance proximity would have to
  replicate it deliberately (quantized + diffed, like the HP bucket).
- **Batched-RPC delivery is fire-and-forget** — a client that joins mid-wave misses the announce;
  durable wave/phase state is carried by netvars (Decision 2), which late-joiners read on sync.
- **The cap is a ceiling, not flow control** — sustained over-spawn waits at the cap rather than
  shedding; a production build would pair it with pooling (deferred, above).

---

## Beyond v1: the boundaries this slice doesn't cross

v1 is a single-shard arena, so several real netcode hazards sit outside its scope by construction.
Naming them is part of the decision:

- **Shard boundaries & migration (v2).** Wave/siege state is master-authoritative and the RPC
  handlers already register on every shard process, so the Master+Caves expansion syncs via
  `AddShardModRPCHandler` / `SendModRPCToShard` rather than a rewrite. A known Klei quirk —
  `SendModRPCToShard` broadcasting to all shards instead of the target — means shard handlers must be
  idempotent and `IsMaster()`-guarded, and per-player siege data must survive the player entity being
  destroyed on shard A and recreated on B.
- **Host migration.** All state lives on the master sim; on a dedicated server that's stable, but a
  listen-server host leaving would drop it. v1 targets the dedicated-server case.
- **High latency.** Commands are server-validated intent with optimistic client-side cast FX
  (`mod/modmain.lua:505-517`); there is no client-side prediction or rollback, so under heavy latency
  the command-to-action gap is visible. That's an acceptable trade for co-op PvE — prediction is
  worth it for player locomotion, not for issuing an order.

## Extending for production

The same decisions point at the production path: keep all tuning on `TUNING.GAUNTLET_*` read live
(already the case) so balance is data, not code; pair the concurrent cap with a real entity pool once
a recycle-friendly attacker (a mortal objective) makes one observable; and move any *per-player
private* state onto a classified entity (`Network:SetClassifiedTarget`) rather than the public
netvars used here, which replicate to everyone in relevance range. None of these change the
architecture — they extend it, which is the point of building it server-authoritative and
shard-aware from day one.
