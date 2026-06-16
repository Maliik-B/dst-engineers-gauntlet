# Engineer's Gauntlet — netcode decisions

Three defensible networking decisions, each with `file:line` evidence in this repo and the shipped
DST pattern it follows. Paths are relative to the repo root; `scripts/...` paths refer to Klei's
shipped source (the reference for the idiom, not included in this repo).

> Decisions 1 and 2 are drafted in M6 from the M1/M2 work. Decision 3 — the centerpiece — is below.

## 1. Server-authoritative wave sim *(M6 — stub)*

All wave logic, spawning, attacker AI, damage, and win/lose run on the master sim behind
`ismastersim` guards; clients render and send intent only. Cite the guards + the RPC-validation path.

## 2. netvar vs RPC split *(M6 — stub)*

Persistent replicated state rides quantized netvars diffed on real change (wave `net_smallbyte`,
phase `net_tinybyte`, objective HP `net_byte`); transient events ride one batched per-wave RPC.

---

## 3. The common-case performance win

**The claim.** Under identical load — 300 attackers, the same scene, one `c_naive` flag — the
optimized path keeps every netcode-relevant cost near zero by *doing nothing when nothing is
changing*. The dial (`c_naive`, `mod/scripts/components/siegemanager.lua:411`) flips a deliberately
naive strawman against the shipped path so the before/after is measured on one machine, one scene.

It rests on three mechanisms, each grounded in a shipped DST pattern.

### 3a. Sleep-aware per-entity work

DST does **not** auto-stop a component's `OnUpdate` when its entity goes to sleep — the engine's
update loop has no asleep filter (`scripts/update.lua:256-268`), so a component must stop *itself*,
exactly as `Combat` does (`scripts/components/combat.lua:289-323`). The naive load component never
does: it stays in the update set even when the whole horde is off-screen and asleep. The optimized
component self-stops on `OnEntitySleep` and re-registers on `OnEntityWake`
(`mod/scripts/components/gauntletload.lua:128`, `:136`), and while awake it runs only a throttled
scan — a period with a random phase, the cadence `Combat:SetRetargetFunction` gives its retarget
task (`mod/scripts/components/gauntletload.lua:140-163`, period
`TUNING.GAUNTLET_LOAD_SCAN_PERIOD` at `mod/modmain.lua:62`).

> **Measured:** off-screen `updating_ents` **345 → 52**; awake scan-ops **0.8–1.35 M/s → 139 K/s**.

### 3b. Replicate only what clients need — quantized and diffed

The naive path re-`set()`s a per-attacker `net_float` every tick
(`mod/scripts/components/gauntletload.lua:158`): continuous replication churn for a value clients can
already derive from the transforms the engine replicates for free. The optimized path recognizes it
as redundant and simply never writes it — the declaration stays (a netvar can't be conditionally
declared without breaking deserialization, `mod/scripts/prefabs/gauntlet_attacker.lua:124`), but
zero `set()` calls means zero churn.

The value clients *do* need — objective HP for a health bar — is replicated the correct way: a
continuous fraction quantized into a `net_byte` bucket as `floor(frac*200+.5)` (the shipped
health-penalty quantization, `scripts/components/health_replica.lua:63-68`) and `set()` **only when
the bucket actually changes** (`mod/scripts/prefabs/gauntlet_objective.lua:40-43`, declared
`:158`, decoded client-side `:120`). `set()` dirties on real change only
(`scripts/netvars.lua:46`), so chipping a 1000-HP engine to death produces at most ~200 replication
events over its entire life rather than one per damage tick.

> **Measured:** netvar churn **2,672/s → 0/s**.

### 3c. One batched event, not a per-spawn flood

The naive path fires one `SendModRPCToClient` per attacker as it spawns
(`mod/scripts/components/siegemanager.lua:178`). The optimized path sends one batched
`GauntletWaveIncoming(wave, count, tier)` per wave — or per `c_stress` dump —
(`mod/scripts/components/siegemanager.lua:149`, sent at `:231`). Server→client RPCs are trusted and
unrated, so the cost on display is purely send *volume*. Both handlers register in a fixed order in
`modmain` so the registration-order-assigned ids line up on every process
(`mod/modmain.lua:113`, `:117`).

A hard concurrent-attacker cap (`TUNING.GAUNTLET_MAX_ATTACKERS`, `mod/modmain.lua:75`, enforced as
back-pressure at `mod/scripts/components/siegemanager.lua:194`) bounds runaway spawning so the server
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
| `updating_ents` | **52** | ~345 | off-screen / asleep |
| load compute | **5.9 ms/tick** | 65 ms/tick | on-screen, awake |
| scan-ops | **139 K/s** | 0.8–1.35 M/s | on-screen, awake |
| netvar churn | **0/s** | 2,672/s | on-screen, moving |
| spawn RPCs (per 300) | **2** | 300 | at spawn |
| server frame *(obs)* | ~89 ms (11 fps) | ~169 ms (6 fps) | on-screen, awake |

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
strawman's own cost is the headline 65 ms/tick. The whole-server *frame* (89 / 169 ms) is dominated
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
