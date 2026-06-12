# Engineer's Gauntlet

A networked co-op wave-defense mode for **Don't Starve Together**. Escalating, server-authoritative
attacker waves path to a defended objective; players hold the line with a character-agnostic defense
layer — buildable auto-turrets and a commandable minion — while the wave-size dial pushes the
synced-entity count as high as the netcode can hold.

This is a netcode portfolio piece: the centerpiece is a measured naive-vs-optimized comparison
(`c_naive` toggle, `c_stress(n)`, on-screen server MSPT / updating-entity / netvar-diff readout),
with a companion document explaining the three core network decisions with `file:line` evidence.

**Status: M0 — dev environment + mod skeleton.** Not yet playable.

## Milestones

| # | Milestone | Status |
|---|---|---|
| M0 | Dev env: local dedicated server, console access, mod skeleton | 🔨 in progress |
| M1 | Core wave loop: siege manager, timed waves, objective HP, win/lose | — |
| M2 | Load dial + deliberately-naive baseline, first measurements | — |
| M3 | Optimization pass: sleep/wake, quantized netvars, batched RPCs | — |
| M4 | Defense layer: buildable auto-turret + commandable minion (command RPC) | — |
| M5 | Stress harness, on-screen metrics, config menu, polish | — |
| M6 | Writeup + Workshop release | — |

## Development setup (Windows)

The repo's `mod/` folder is junctioned into the DST mods directory, so edits here are live in-game
after a world reload:

```bat
mklink /J "C:\Program Files (x86)\Steam\steamapps\common\Don't Starve Together\mods\engineers-gauntlet" "D:\Applications\dst-engineers-gauntlet\mod"
```

Run the local offline dev server (single shard) with `tools\run-server.bat`, then connect from the
DST client's main-menu console: `c_connect("127.0.0.1", 10999)`. (Same-host LAN-tab discovery is
unreliable even with a firewall rule — direct connect always works. A headless dedicated server
never triggers Windows' allow-access prompt, so LAN visibility needs `tools\allow-firewall.ps1`
run elevated.)

Console: `~` opens it; `Ctrl` toggles **remote** (server-side) execution — requires your id in the
cluster's `adminlist.txt`. Note: offline servers authenticate clients with offline ids
(`OU_<steamid64>`), not Klei `KU_` ids — use the `OU_` id shown in the server log on connect.

Dev loop: edit Lua → `c_reset()` in the console (reloads world + mod code) → test. `c_gauntlet()`
prints mod liveness and which sim you're on.

## Architecture (one paragraph, more in the netcode doc later)

The master sim owns all gameplay truth — wave logic, spawning, AI, damage, win/lose — behind
`ismastersim` guards. Clients render and send intent only (placement and minion commands are
client→server RPCs carrying scalars; the server validates and acts). Persistent replicated state
rides quantized netvars diffed on real change; transient events ride batched per-wave RPCs.
RPC handlers register in `modmain` so every shard process loads them (v1 is single-shard, but the
architecture is shard-aware so the planned Master+Caves expansion is a growth, not a rewrite).
