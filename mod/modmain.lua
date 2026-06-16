-- Engineer's Gauntlet — modmain
--
-- Architecture rule (locked): the master sim owns all gameplay truth.
-- Clients render and send intent (RPCs) only. Netvar-bearing prefabs are
-- declared identically on every process, and future RPC handlers (M4)
-- register here unconditionally, so server, clients, and both shard
-- processes later all build identical network tables in the same order.

local _G = GLOBAL
local TUNING = _G.TUNING

PrefabFiles =
{
    "gauntlet_objective",
    "gauntlet_attacker",
}

--------------------------------------------------------------------------
-- Tuning. Every Gauntlet knob lives on TUNING.GAUNTLET_* — no literals in
-- component/prefab code. wave_size is the load dial from the mod config.
--------------------------------------------------------------------------

TUNING.GAUNTLET_WAVE_SIZE = GetModConfigData("wave_size") or 10
TUNING.GAUNTLET_NUM_WAVES = 5
TUNING.GAUNTLET_WAVE_GROWTH = .5            -- fraction of base size added per wave

TUNING.GAUNTLET_FIRST_WAVE_DELAY = 30       -- seconds from c_gauntlet_start() to wave 1
TUNING.GAUNTLET_WAVE_DELAY = 60             -- inter-wave clock (worldsettingstimer maxtime)
TUNING.GAUNTLET_WARN_DURATION = 15          -- growl-warning window before each wave

TUNING.GAUNTLET_SPAWN_DIST = 30             -- spawn ring radius around the objective
TUNING.GAUNTLET_SPAWN_INTERVAL_BASE = 1     -- drip-release: one spawn per interval...
TUNING.GAUNTLET_SPAWN_INTERVAL_VAR = 1      -- ...plus up to this much jitter

TUNING.GAUNTLET_OBJECTIVE_HEALTH = 1000
TUNING.GAUNTLET_OBJECTIVE_WORK = 4          -- hammer hits to dismantle the engine (stand-down)
-- Fraction of player weapon damage ABSORBED by the engine (player deals the
-- rest). 0.5 = halve it: the engine stays destroyable by hand like any DST
-- structure (a hammer-less player can end a siege by tearing it down), but at
-- roughly attacker-tier DPS rather than instantly. Weapon-to-death trips the
-- normal lose condition; the hammer (workable) is the clean *neutral*
-- dismantle. Mob damage is untouched (DoDelta only absorbs player afflicters).
TUNING.GAUNTLET_OBJECTIVE_PLAYER_ABSORB = 0.5

-- Attacker: a retuned hound (baselines: TUNING.HOUND_* / MOONHOUND_*).
TUNING.GAUNTLET_ATTACKER_HEALTH = 150
TUNING.GAUNTLET_ATTACKER_DAMAGE = 20
TUNING.GAUNTLET_ATTACKER_ATTACK_PERIOD = 2
TUNING.GAUNTLET_ATTACKER_ATTACK_RANGE = 3   -- SIEGE_DIST leash below depends on this
TUNING.GAUNTLET_ATTACKER_SPEED = 10
TUNING.GAUNTLET_ATTACKER_SIEGE_DIST = 3     -- leash stop distance at the objective (> physics radii sum)
TUNING.GAUNTLET_ATTACKER_AGGRO_DIST = 15    -- may acquire defenders only while this near the objective
TUNING.GAUNTLET_ATTACKER_RETURN_DIST = 30   -- dragged past this from the objective -> drop the target
TUNING.GAUNTLET_ATTACKER_TARGET_DIST = 10   -- defender acquisition radius
TUNING.GAUNTLET_ATTACKER_TARGET_KEEP = 20   -- drop targets that get further than this
TUNING.GAUNTLET_ATTACKER_MAX_CHASE = 10     -- short chase: kiting can't pull the wave apart
TUNING.GAUNTLET_ATTACKER_LOST_DIST = 60     -- strays this far from the objective self-despawn...
TUNING.GAUNTLET_ATTACKER_LOST_TIME = 5      -- ...after this many seconds

-- Load path (the naive-vs-optimized experiment, toggled by c_naive).
TUNING.GAUNTLET_LOAD_SCAN_RADIUS = 20       -- neighbour-scan radius (the O(N*k) cost; both modes)
TUNING.GAUNTLET_LOAD_SCAN_PERIOD = 0.5      -- optimized: throttle the scan to this cadence (naive = every tick)

-- Hard concurrent-attacker cap. Always on: a safety ceiling that bounds runaway
-- spawning (c_stress, huge waves) so the server can't be DoSed into the floor.
-- Set comfortably above the demo's ~300 so it never distorts the A/B; the drip
-- applies it as back-pressure (waits) and c_stress reports when it bites.
--
-- The cap is the shipped half of the spec's "pooling/caps" item; a true entity
-- pool is deliberately deferred. The A/B scene holds an invincible objective, so
-- attackers never die/recycle and a pool would show nothing here; and recycling
-- DST mobs means short-circuiting the death stategraph + lootdropper + corpse
-- pipeline, which is invasive and reads against "must feel native". The cap
-- delivers the safety benefit at a fraction of the risk.
TUNING.GAUNTLET_MAX_ATTACKERS = 500

--------------------------------------------------------------------------
-- Strings
--------------------------------------------------------------------------

_G.STRINGS.NAMES.GAUNTLET_OBJECTIVE = "Gauntlet Engine"
_G.STRINGS.CHARACTERS.GENERIC.DESCRIBE.GAUNTLET_OBJECTIVE = "If it falls, the gauntlet is lost."
_G.STRINGS.NAMES.GAUNTLET_ATTACKER = "Besieger"
_G.STRINGS.CHARACTERS.GENERIC.DESCRIBE.GAUNTLET_ATTACKER = "It only has eyes for the Engine."

--------------------------------------------------------------------------
-- Mod RPC handlers. Registered unconditionally on every process (server,
-- clients, both shard processes later) in a fixed order — registration order
-- assigns the network ids, so the tables must line up everywhere.
--
-- Two server->client wave RPCs, registered in a FIXED order (registration
-- order assigns the network id, so the tables must line up on every process):
--
--   GauntletAttackerSpawned — the NAIVE strawman: the server fires ONE per
--     attacker spawn. The body is intentionally trivial; the cost on display is
--     the per-spawn send VOLUME, not the work here. It tallies arrivals so the
--     flood is observable client-side via GAUNTLET_CLIENT_SPAWN_RPCS.
--   GauntletWaveIncoming — the OPTIMIZED counterpart: ONE batched RPC per wave
--     (or per c_stress dump) carrying (wave, count, tier). Replaces the flood;
--     drives the M5 wave-incoming banner/FX from a single atomic event.
--------------------------------------------------------------------------

AddClientModRPCHandler("EngineersGauntlet", "GauntletAttackerSpawned", function(x, z)
    _G.GAUNTLET_CLIENT_SPAWN_RPCS = (_G.GAUNTLET_CLIENT_SPAWN_RPCS or 0) + 1
end)

AddClientModRPCHandler("EngineersGauntlet", "GauntletWaveIncoming", function(wave, count, tier)
    _G.GAUNTLET_CLIENT_WAVE_RPCS = (_G.GAUNTLET_CLIENT_WAVE_RPCS or 0) + 1
end)

--------------------------------------------------------------------------
-- World components. Master-sim only (mirrors how forest.lua attaches its
-- spawners); each component also asserts ismastersim on construction.
--------------------------------------------------------------------------

AddPrefabPostInit("world", function(inst)
    if inst.ismastersim then
        inst:AddComponent("siegemanager")
        inst:AddComponent("gauntletmetrics")
    end
end)

--------------------------------------------------------------------------
-- Player-centric console harness (runs server-side via the remote console).
-- Observation/balancing rides the built-ins — c_godmode, c_freecrafting,
-- c_speedmult, c_spawn — those are not rebuilt here.
--   c_gauntlet_place/start/stop — objective + wave control (M1)
--   c_stress(n)          — slam n attackers on the objective now (M2 load dial)
--   c_naive(true/false)  — flip the naive-vs-optimized code path live (M2)
--   c_metrics()          — print the perf readout; c_metrics_reset() zeroes it
--------------------------------------------------------------------------

local function GetSiegeManager()
    if _G.TheWorld == nil or not _G.TheWorld.ismastersim then
        print("[Gauntlet] master-sim command — use the remote console (Ctrl toggles it)")
        return nil
    end
    return _G.TheWorld.components.siegemanager
end

-- Liveness + siege state probe.
_G.c_gauntlet = function()
    print(string.format("[Gauntlet] alive | mastersim=%s wave_size=%d",
        tostring(_G.TheNet:GetIsMasterSimulation()), TUNING.GAUNTLET_WAVE_SIZE))
    local siegemanager = _G.TheWorld ~= nil and _G.TheWorld.components.siegemanager or nil
    if siegemanager ~= nil then
        print("[Gauntlet] " .. siegemanager:GetDebugString())
    end
    local metrics = _G.TheWorld ~= nil and _G.TheWorld.components.gauntletmetrics or nil
    if metrics ~= nil then
        print("[Gauntlet] " .. metrics:GetReadout())
    end
end

-- Place (or replace) the objective at the calling player's position.
_G.c_gauntlet_place = function()
    local siegemanager = GetSiegeManager()
    if siegemanager == nil then
        return
    end
    local player = _G.ConsoleCommandPlayer()
    if player == nil then
        print("[Gauntlet] no player to place the objective at")
        return
    end
    local objective = siegemanager:PlaceObjective(player:GetPosition())
    if objective ~= nil then
        print(string.format("[Gauntlet] objective placed at %s — step aside and c_gauntlet_start()",
            tostring(objective:GetPosition())))
    end
end

_G.c_gauntlet_start = function()
    local siegemanager = GetSiegeManager()
    if siegemanager ~= nil then
        siegemanager:StartSiege()
    end
end

_G.c_gauntlet_stop = function()
    local siegemanager = GetSiegeManager()
    if siegemanager ~= nil then
        siegemanager:StopSiege()
    end
end

--------------------------------------------------------------------------
-- Load harness (M2). c_stress slams attackers on instantly; c_naive flips the
-- deliberately-naive path for the whole arena; c_metrics prints the readout.
--------------------------------------------------------------------------

_G.c_stress = function(n)
    local siegemanager = GetSiegeManager()
    if siegemanager ~= nil then
        return siegemanager:Stress(n or 10)
    end
end

_G.c_naive = function(enable)
    local siegemanager = GetSiegeManager()
    if siegemanager == nil then
        return
    end
    if enable == nil then
        enable = true
    end
    siegemanager:SetNaive(enable)
    print(string.format("[Gauntlet] naive path %s", siegemanager:IsNaive()
        and "ON — strawman (per-spawn RPC, per-tick non-sleeping update, net_float churn)"
        or "off — optimized (batched per-wave RPC, sleep-stop + throttled scan, no churn)"))
end

_G.c_metrics = function()
    if _G.TheWorld == nil or not _G.TheWorld.ismastersim then
        print("[Gauntlet] metrics are master-sim only — use the remote console")
        return
    end
    local metrics = _G.TheWorld.components.gauntletmetrics
    if metrics ~= nil then
        print("[Gauntlet] " .. metrics:GetReadout())
    end
end

_G.c_metrics_reset = function()
    if _G.TheWorld == nil or not _G.TheWorld.ismastersim then
        print("[Gauntlet] metrics are master-sim only — use the remote console")
        return
    end
    local metrics = _G.TheWorld.components.gauntletmetrics
    if metrics ~= nil then
        metrics:ResetCounters()
        print("[Gauntlet] metrics counters reset")
    end
end

print("[Gauntlet] modmain loaded (wave_size=" .. tostring(TUNING.GAUNTLET_WAVE_SIZE) .. ")")
