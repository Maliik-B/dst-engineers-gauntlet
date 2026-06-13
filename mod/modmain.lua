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

--------------------------------------------------------------------------
-- Strings
--------------------------------------------------------------------------

_G.STRINGS.NAMES.GAUNTLET_OBJECTIVE = "Gauntlet Engine"
_G.STRINGS.CHARACTERS.GENERIC.DESCRIBE.GAUNTLET_OBJECTIVE = "If it falls, the gauntlet is lost."
_G.STRINGS.NAMES.GAUNTLET_ATTACKER = "Besieger"
_G.STRINGS.CHARACTERS.GENERIC.DESCRIBE.GAUNTLET_ATTACKER = "It only has eyes for the Engine."

--------------------------------------------------------------------------
-- World component. Master-sim only (mirrors how forest.lua attaches its
-- spawners); the component itself also asserts ismastersim on construction.
--------------------------------------------------------------------------

AddPrefabPostInit("world", function(inst)
    if inst.ismastersim then
        inst:AddComponent("siegemanager")
    end
end)

--------------------------------------------------------------------------
-- Player-centric console harness (runs server-side via the remote console).
-- Observation/balancing rides the built-ins — c_godmode, c_freecrafting,
-- c_speedmult, c_spawn — those are not rebuilt here.
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

print("[Gauntlet] modmain loaded (wave_size=" .. tostring(TUNING.GAUNTLET_WAVE_SIZE) .. ")")
