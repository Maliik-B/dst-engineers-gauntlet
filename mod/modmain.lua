-- Engineer's Gauntlet — modmain
--
-- Architecture rule (locked): the master sim owns all gameplay truth.
-- Clients render and send intent (RPCs) only. Netvar-bearing prefabs are
-- declared identically on every process, and future RPC handlers (M4)
-- register here unconditionally, so server, clients, and both shard
-- processes later all build identical network tables in the same order.

local _G = GLOBAL
local TUNING = _G.TUNING
local Ingredient = _G.Ingredient
local GAUNTLET = require("gauntlet_constants")
local MINION_COMMAND = GAUNTLET.MINION_COMMAND
local TARGETING = require("gauntlet_targeting")

PrefabFiles =
{
    "gauntlet_objective",
    "gauntlet_attacker",
    "gauntlet_spiderattackers",   -- M5 Breaker + Swarmer (one file returns both)
    "gauntlet_turret",            -- M4 auto-turret (returns the placer too)
    "gauntlet_turret_projectile",
    "gauntlet_minion",            -- M4 commandable minion
    "gauntlet_commander",         -- M4 held command tool (drives the command RPC)
}

--------------------------------------------------------------------------
-- Tuning. Every Gauntlet knob lives on TUNING.GAUNTLET_* — no literals in
-- component/prefab code. wave_size is the load dial from the mod config.
--------------------------------------------------------------------------

TUNING.GAUNTLET_WAVE_SIZE = GetModConfigData("wave_size") or 6 -- fallback == WAVE_SIZE_BASE (scale 1 = tuned counts)
TUNING.GAUNTLET_NUM_WAVES = GetModConfigData("num_waves") or 5
TUNING.GAUNTLET_WAVE_GROWTH = .5            -- fraction of base size added per wave (formula fallback)
-- The wave_size the count table is tuned at; CalcWaveSize scales the table by
-- wave_size/this, so the config dial still works (default 6 == the tuned counts).
TUNING.GAUNTLET_WAVE_SIZE_BASE = 6
-- Explicit per-wave attacker counts (the tuned shape; scaled by wave_size). Beefed
-- early so the opener is a real wave; the counts then climb modestly (10->18), but most
-- of the late escalation is carried by the tightening cadence + Breakers, not the count
-- alone. Indexed by wave; clamped; falls back to the growth formula beyond the table.
TUNING.GAUNTLET_WAVE_COUNTS = { 10, 11, 13, 15, 18 }

TUNING.GAUNTLET_FIRST_WAVE_DELAY = 30       -- seconds from c_gauntlet_start() to wave 1
TUNING.GAUNTLET_WAVE_DELAY = GetModConfigData("wave_interval") or 60 -- inter-wave clock (worldsettingstimer maxtime)
TUNING.GAUNTLET_WARN_DURATION = 15          -- growl-warning window before each wave
TUNING.GAUNTLET_RESULT_DISPLAY = 15         -- seconds a VICTORY/DEFEAT shows before the run returns to IDLE

TUNING.GAUNTLET_SPAWN_DIST = 30             -- spawn ring radius around the objective
TUNING.GAUNTLET_SPAWN_INTERVAL_BASE = 1     -- drip-release fallback: one spawn per interval...
TUNING.GAUNTLET_SPAWN_INTERVAL_VAR = 1      -- ...plus up to this much jitter (per-wave table below overrides)

-- Per-wave spawn cadence — the "rolling -> burst" lever. Anchored to DST's own
-- per-spawn hound delay bands (3-8s early ... 0.5-1.5s late): early waves trickle
-- in (a long rolling grind, low concurrency), late waves arrive in a sharp burst
-- (high concurrency piling on the Engine). {base, var} -> delay = base + rand*var.
-- Indexed by wave; clamped to the last row beyond the table. Pacing carries much of
-- the late escalation, alongside the modestly-climbing counts.
TUNING.GAUNTLET_SPAWN_CADENCE = { {2, 3}, {1.5, 2.5}, {1.5, 2.5}, {0.5, 3}, {0.5, 1} }
-- Per-wave warning window (shrinks as waves harden, like DST's 120->30s). Short
-- late warning + the burst cadence = the sharp climax. Indexed by wave; clamped.
TUNING.GAUNTLET_WARN_BY_WAVE = { 20, 16, 13, 10, 8 }

TUNING.GAUNTLET_OBJECTIVE_HEALTH = 1000
TUNING.GAUNTLET_OBJECTIVE_WORK = 4          -- hammer hits to dismantle the engine (stand-down)
-- Fraction of player weapon damage ABSORBED by the engine (player deals the
-- rest). 0.5 = halve it: the engine stays destroyable by hand like any DST
-- structure (a hammer-less player can end a siege by tearing it down), but at
-- roughly attacker-tier DPS rather than instantly. Weapon-to-death trips the
-- normal lose condition; the hammer (workable) is the clean *neutral*
-- dismantle. Mob damage is untouched (DoDelta only absorbs player afflicters).
TUNING.GAUNTLET_OBJECTIVE_PLAYER_ABSORB = 0.5
-- The Engine glows: a lit defensive zone so night isn't an uncontrolled difficulty
-- spike landing on one wave. Covers the fight area (attackers siege ~3u, defenses
-- spread ~6u) so you can see to command + minions aren't fighting blind. Keeps night
-- atmosphere, removes the scramble-for-light confound.
TUNING.GAUNTLET_OBJECTIVE_LIGHT_RADIUS = 6

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
-- M5 attacker roster — 2 new types. They reuse the GAUNTLET_ATTACKER_* brain
-- gating (aggro/target/return/keep distances); only per-type stats differ.
--------------------------------------------------------------------------

-- Breaker: tanky, slow, big hits; hunts the defense layer (the survive-swarm demo).
-- Damage buffed 40->60 (balance pass): at 40 a lone minion/turret out-traded it, so
-- it never earned "defense-smasher"; at 60 it beats a lone minion and a Breaker pack
-- melts a clustered turret stack — the pressure that makes spreading turrets matter.
TUNING.GAUNTLET_BREAKER_HEALTH = 400
TUNING.GAUNTLET_BREAKER_DAMAGE = 60
TUNING.GAUNTLET_BREAKER_ATTACK_PERIOD = 3
TUNING.GAUNTLET_BREAKER_ATTACK_RANGE = 3
TUNING.GAUNTLET_BREAKER_SPEED = 5
-- The Breaker IS our Varglet (DST merges 5 hounds into one after day 25). Its roster
-- weight RAMPS per wave past its minwave, so the "concentration spike" grows late —
-- more focus-target heavies as the siege climaxes. effweight = weight + ramp*(wave-minwave).
TUNING.GAUNTLET_BREAKER_WEIGHT_RAMP = 0.2
-- Per-wave Breaker band — the "tasteful variance" done right: a guaranteed FLOOR
-- (no 0-Breaker fluke makes a wave trivial) and a hard CAP (no RNG over-spike). The
-- actual count lands anywhere in [floor, cap], so each wave reliably bites while
-- still varying run to run. Both indexed by wave; clamped. (Floor <= cap by design.)
TUNING.GAUNTLET_BREAKER_FLOOR = { 0, 0, 1, 2, 3 }
TUNING.GAUNTLET_BREAKER_CAP   = { 0, 0, 2, 3, 5 }

-- Swarmer: fast, fragile chaff; chases the defending player like the Besieger.
TUNING.GAUNTLET_SWARMER_HEALTH = 60
TUNING.GAUNTLET_SWARMER_DAMAGE = 10
TUNING.GAUNTLET_SWARMER_ATTACK_PERIOD = 1.5
TUNING.GAUNTLET_SWARMER_ATTACK_RANGE = 2.5
TUNING.GAUNTLET_SWARMER_SPEED = 14

--------------------------------------------------------------------------
-- Defense layer (M4). Auto-turret — the buildable "mech to manage", built on
-- the eyeturret/Houndius-Shootius pattern (no power/circuit). The Winona
-- catapult's battery is dropped (character-locked + an economy lever, out of
-- v1 scope); its balance role is carried by the build-cap + recipe cost below.
--------------------------------------------------------------------------

TUNING.GAUNTLET_TURRET_HEALTH = 800
TUNING.GAUNTLET_TURRET_REGEN = 8            -- HP healed per regen tick (self-repair)...
TUNING.GAUNTLET_TURRET_REGEN_PERIOD = 1     -- ...every this many seconds; stops at full
TUNING.GAUNTLET_TURRET_RANGE = 12           -- target-acquisition + firing radius
TUNING.GAUNTLET_TURRET_DAMAGE = 40          -- per-hit AOE damage (attacker HP = 150)
TUNING.GAUNTLET_TURRET_ATTACK_PERIOD = 2    -- seconds between shots (combat cooldown)
TUNING.GAUNTLET_TURRET_AOE_RADIUS = 3       -- projectile blast radius
TUNING.GAUNTLET_TURRET_WORK = 4             -- hammer hits to dismantle (refunds the recipe)
-- The balance lever (stands in for the catapult battery): total turrets the
-- arena allows. Raise/lower to tune firepower; one-line change.
TUNING.GAUNTLET_TURRET_MAX = 4
-- Turret-to-turret placement spacing. The recipe's generic min_spacing (2) only
-- stops literal overlap; this larger gate (= the AOE diameter, 2x the radius) stops
-- STACKING for overlapping AOE, so 4 turrets must cover a footprint instead of a
-- death-ball — the reason to place them uniquely. (Read at placement; a knob.)
TUNING.GAUNTLET_TURRET_SPACING = 6

--------------------------------------------------------------------------
-- Commandable minion (M4) — a recolored clockwork knight, owned per-player and
-- commanded via a 3-verb vocabulary (defend / follow / focus). The 2nd, richer
-- RPC surface (the command channel) lands in Phase 4c; the AI here is driven by
-- the per-minion command state.
--------------------------------------------------------------------------

TUNING.GAUNTLET_MINION_HEALTH = 300
TUNING.GAUNTLET_MINION_DAMAGE = 30
TUNING.GAUNTLET_MINION_ATTACK_PERIOD = 2
TUNING.GAUNTLET_MINION_ATTACK_RANGE = 2.5
TUNING.GAUNTLET_MINION_HIT_RANGE = 3
TUNING.GAUNTLET_MINION_SPEED = 6            -- walk = run (SGknight only walks); a touch faster than a player

TUNING.GAUNTLET_MINION_TARGET_DIST = 10     -- auto-acquire attackers within this of the minion
TUNING.GAUNTLET_MINION_KEEP_DIST = 16       -- drop targets beyond this from the anchor (anti-kite)
TUNING.GAUNTLET_MINION_MAX_CHASE = 8        -- finite chase so a runner can't pull it off post

TUNING.GAUNTLET_MINION_DEFEND_LEASH = 4     -- DEFEND: stray this far from the point -> walk back...
TUNING.GAUNTLET_MINION_DEFEND_RETURN = 1    -- ...until within this of it
TUNING.GAUNTLET_MINION_FOLLOW_MIN = 2       -- FOLLOW band around the owner: back off inside this...
TUNING.GAUNTLET_MINION_FOLLOW_TARGET = 4    -- ...settle around this...
TUNING.GAUNTLET_MINION_FOLLOW_MAX = 8       -- ...approach when beyond this
TUNING.GAUNTLET_MINION_FOCUS_RESOLVE_RADIUS = 6 -- FOCUS picks the nearest attacker within this of the clicked point

TUNING.GAUNTLET_MINION_REGEN = 5            -- self-repair HP per period...
TUNING.GAUNTLET_MINION_REGEN_PERIOD = 1     -- ...every this many seconds; stops at full
-- Per-player follower cap (the From Beyond compass→pulse precedent caps at 4).
TUNING.GAUNTLET_MINION_MAX = 4
-- Command-RPC anti-cheat: a commanded point must be within this of the sender
-- (the server rejects out-of-range points so a client can't command at will).
TUNING.GAUNTLET_COMMAND_MAX_DIST = 40

--------------------------------------------------------------------------
-- Strings
--------------------------------------------------------------------------

_G.STRINGS.NAMES.GAUNTLET_OBJECTIVE = "Gauntlet Engine"
_G.STRINGS.CHARACTERS.GENERIC.DESCRIBE.GAUNTLET_OBJECTIVE = "If it falls, the gauntlet is lost."
_G.STRINGS.NAMES.GAUNTLET_ATTACKER = "Besieger"
_G.STRINGS.CHARACTERS.GENERIC.DESCRIBE.GAUNTLET_ATTACKER = "It only has eyes for the Engine."
_G.STRINGS.NAMES.GAUNTLET_BREAKER = "Breaker"
_G.STRINGS.CHARACTERS.GENERIC.DESCRIBE.GAUNTLET_BREAKER = "It goes for the machines first."
_G.STRINGS.NAMES.GAUNTLET_SWARMER = "Swarmling"
_G.STRINGS.CHARACTERS.GENERIC.DESCRIBE.GAUNTLET_SWARMER = "Alone, nothing. In a tide, a problem."
_G.STRINGS.NAMES.GAUNTLET_TURRET = "Gauntlet Sentry"
-- DESCRIBE is a table so examine reflects condition (getstatus by HP%); the
-- describe system indexes it by the status key with a GENERIC fallback.
_G.STRINGS.CHARACTERS.GENERIC.DESCRIBE.GAUNTLET_TURRET =
{
    GENERIC = "It holds the line so I don't have to.",
    DAMAGED = "It's taken a beating, but it's still firing.",
    CRITICAL = "It won't hold much longer!",
    DEAD = "So much for that one.",
}
_G.STRINGS.NAMES.GAUNTLET_MINION = "Gauntlet Sentinel"
-- Examine reflects the minion's current command (getstatus by command mode).
_G.STRINGS.CHARACTERS.GENERIC.DESCRIBE.GAUNTLET_MINION =
{
    GENERIC = "It follows my orders. Mostly.",
    DEFEND = "It's holding the position I gave it.",
    FOLLOW = "It's keeping pace with me.",
    FOCUS = "It's hunting down a target.",
}
_G.STRINGS.NAMES.GAUNTLET_COMMANDER = "Sentinel Commander"
_G.STRINGS.CHARACTERS.GENERIC.DESCRIBE.GAUNTLET_COMMANDER = "Right-click to give the order: ground to hold, an enemy to focus, myself to follow."

--------------------------------------------------------------------------
-- Crafting (M4 defense layer). Character-agnostic: no builder_tag, so ANY
-- character can build these. The turret is intentionally EARLY-game (Science
-- Machine tier + cheap day-1 mats) because an arena run needs defenses from the
-- start; the Houndius Shootius' boss/Ruins-gated Ancient recipe would arrive far
-- too late to base ours on. Balance rides the build-cap (testfn) + cost, not a
-- power/fuel economy (deferred to v2).
--------------------------------------------------------------------------

local TURRET_CAP_SCAN_RADIUS = 64 -- arena-scoped count for the build-cap

local function TurretCapTestFn(pt, rot)
    -- Placement gate (client ghost AND server build validation, like the shipped
    -- IsMarshLand testfns): counts the networked "gauntlet_turret" tag, visible on
    -- both sides. Returns (can_build, mouse_blocked).
    -- (1) build-cap: refuse once the arena holds GAUNTLET_TURRET_MAX turrets.
    local capents = _G.TheSim:FindEntities(pt.x, 0, pt.z, TURRET_CAP_SCAN_RADIUS, { "gauntlet_turret" })
    if #capents >= TUNING.GAUNTLET_TURRET_MAX then
        return false, false
    end
    -- (2) anti-stacking: refuse within SPACING of another turret, so 4 turrets must
    -- spread to a footprint rather than death-ball one tile for overlapping AOE.
    local nearents = _G.TheSim:FindEntities(pt.x, 0, pt.z, TUNING.GAUNTLET_TURRET_SPACING, { "gauntlet_turret" })
    if #nearents > 0 then
        return false, false
    end
    return true, false
end

AddRecipe2(
    "gauntlet_turret",
    { Ingredient("boards", 3), Ingredient("goldnugget", 2), Ingredient("cutstone", 2) },
    _G.TECH.SCIENCE_ONE,
    {
        placer = "gauntlet_turret_placer",
        min_spacing = 2,
        testfn = TurretCapTestFn,
        image = "winona_catapult.tex",
    },
    { "STRUCTURES" }
)

-- The command tool — an inventory item (any character), Science Machine tier.
AddRecipe2(
    "gauntlet_commander",
    { Ingredient("goldnugget", 2), Ingredient("cutstone", 1), Ingredient("twigs", 2) },
    _G.TECH.SCIENCE_ONE,
    { image = "winona_remote.tex" },
    { "TOOLS" }
)

-- Deploy the minion via a placer (same pattern as the turret). The per-player
-- cap is enforced with canbuild (which has the builder), NOT testfn (which only
-- gets the point) — canbuild runs server-side before spawning/charging, so at
-- cap nothing is built. The minion binds its owner from the onbuilt event.
local function MinionCapCanBuild(recipe, builder)
    -- builder.components.leader is nil on clients (server-only component), so the
    -- guard also keeps this safe wherever it may be evaluated client-side.
    if builder ~= nil and builder.components.leader ~= nil
        and builder.components.leader:CountFollowers("gauntlet_minion") >= TUNING.GAUNTLET_MINION_MAX then
        return false
    end
    return true
end

AddRecipe2(
    "gauntlet_minion",
    { Ingredient("goldnugget", 3), Ingredient("cutstone", 2), Ingredient("twigs", 3) },
    _G.TECH.SCIENCE_ONE,
    {
        placer = "gauntlet_minion_placer",
        min_spacing = 1.5,
        canbuild = MinionCapCanBuild,
        image = "gears.tex",
    },
    { "STRUCTURES" }
)

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

-- Pre-declare the client-side RPC tallies HERE, at modmain's main chunk. DST
-- runs a strict-global guard (strict.lua:21-24): reading an undeclared global
-- from inside a function — which is exactly what these client RPC handlers do —
-- raises "variable '...' is not declared" and crashes the client the moment the
-- first RPC arrives. Main-chunk assignment is allowed (same as the c_ console
-- globals below), so initializing them here declares them; the handlers then
-- only read/increment already-declared names.
_G.GAUNTLET_CLIENT_SPAWN_RPCS = 0
_G.GAUNTLET_CLIENT_WAVE_RPCS = 0

AddClientModRPCHandler("EngineersGauntlet", "GauntletAttackerSpawned", function(x, z)
    _G.GAUNTLET_CLIENT_SPAWN_RPCS = _G.GAUNTLET_CLIENT_SPAWN_RPCS + 1
end)

AddClientModRPCHandler("EngineersGauntlet", "GauntletWaveIncoming", function(wave, count, tier)
    _G.GAUNTLET_CLIENT_WAVE_RPCS = _G.GAUNTLET_CLIENT_WAVE_RPCS + 1
end)

--------------------------------------------------------------------------
-- Minion command RPC (M4) — the 2nd RPC surface, and the only CLIENT->SERVER
-- one. It lives in its own id space (AddModRPCHandler), separate from the two
-- server->client handlers above (AddClientModRPCHandler), so registering it does
-- NOT shift their ids. Clients send INTENT only — (command_enum, x, z) scalars;
-- the server validates and applies. The held commander's right-click sends it.
--------------------------------------------------------------------------

-- Prefer the engine's shipped validator (networkclientrpc.lua, "global so Mods
-- can use them"); fall back to a plain type check so the handler is robust.
local checknumber = _G.checknumber or function(v) return type(v) == "number" end

AddModRPCHandler("EngineersGauntlet", "GauntletMinionCommand", function(player, command, x, z)
    -- 1. type-validate every arg up front (the shipped RPC-handler idiom)
    if not (checknumber(command) and checknumber(x) and checknumber(z)) then
        return
    end
    -- 2. enum range-check
    command = math.floor(command + 0.5)
    if command ~= MINION_COMMAND.DEFEND
        and command ~= MINION_COMMAND.FOLLOW
        and command ~= MINION_COMMAND.FOCUS then
        return
    end
    -- 3. component existence: only a player that can own minions
    if player == nil or player.components.leader == nil then
        return
    end
    -- 4. range clamp: the commanded point must be near the sender (anti-cheat —
    --    a client can't direct minions to arbitrary world coordinates)
    if player:GetDistanceSqToPoint(x, 0, z)
        > TUNING.GAUNTLET_COMMAND_MAX_DIST * TUNING.GAUNTLET_COMMAND_MAX_DIST then
        return
    end
    -- 5. apply to the SENDER's own minions only (ownership)
    local applied = 0
    for _, minion in ipairs(player.components.leader:GetFollowersByTag("gauntlet_minion")) do
        if minion:SetMinionCommand(command, x, z) then
            applied = applied + 1
        end
    end
    -- Cast feedback: an engineer-UI confirm so the order reads as registered. Only
    -- when something actually took (e.g. FOCUS with no enemy near stays silent),
    -- so the sound itself signals success vs no-op.
    if applied > 0 and player.SoundEmitter ~= nil then
        player.SoundEmitter:PlaySound("meta4/winona_UI/select")
    end
end)

-- CLIENT command trigger: while the commander is equipped, an in-world right-
-- click reads the cursor and fires the command RPC. Cursor context picks the
-- verb (enemy -> FOCUS, self -> FOLLOW, ground -> DEFEND) — the 2-states + 1-
-- order model. UI-consumed clicks never reach oncontrol (input.lua:166), and the
-- server re-validates everything, so this client code only proposes intent.
local function GetMinionCommandForCursor(player)
    local target = _G.TheInput:GetWorldEntityUnderMouse()
    if target == player then
        return MINION_COMMAND.FOLLOW
    elseif target ~= nil
        and (target:HasTag("monster") or target:HasTag("hostile"))
        and not (target:HasTag("player") or target:HasTag("companion") or target:HasTag("structure")) then
        return MINION_COMMAND.FOCUS
    end
    return MINION_COMMAND.DEFEND
end

-- Targeting preview (client-only, Klei parity): while the commander is equipped a
-- ground reticule follows the cursor and recolours to the verb the right-click
-- WOULD send — reusing GetMinionCommandForCursor, so the preview can never disagree
-- with what actually fires. Green = defend at the point, red = focus snapped onto
-- the hovered enemy, amber = follow on you. Reuses the shipped reticuleaoe art (the
-- same family Klei builds the catapult's own reticules from). No server/RPC change.
local RETICULE_COLOUR =
{
    [MINION_COMMAND.DEFEND] = { 0, 1, .25 },  -- green: the order lands here
    [MINION_COMMAND.FOCUS]  = { 1, .25, 0 },  -- red: hunt this enemy (the shipped hostile-target tone)
    [MINION_COMMAND.FOLLOW] = { 1, .82, .3 }, -- amber: keep pace with me (the commander tone)
}

-- Where the order visually anchors: the hovered enemy for FOCUS, you for FOLLOW,
-- else the cursor ground point. (The RPC still sends the cursor point regardless;
-- the server resolves FOCUS to the nearest attacker there, which is the hovered
-- enemy — so anchor and effect agree.)
local function GetCommandAnchor(player, command)
    if command == MINION_COMMAND.FOCUS then
        local target = _G.TheInput:GetWorldEntityUnderMouse()
        if target ~= nil and target:IsValid() then
            local x, _, z = target.Transform:GetWorldPosition()
            return x, z
        end
    elseif command == MINION_COMMAND.FOLLOW then
        local x, _, z = player.Transform:GetWorldPosition()
        return x, z
    end
    local pos = _G.TheInput:GetWorldPosition()
    if pos ~= nil then
        return pos.x, pos.z
    end
end

-- Per-frame, local player only. Hides the reticule unless the commander is equipped
-- and the cursor resolves to a valid anchor; otherwise repositions + recolours it.
local function UpdateCommanderReticule(player)
    if player ~= _G.ThePlayer then
        return
    end
    local inventory = player.replica.inventory
    local equipped = inventory ~= nil and inventory:GetEquippedItem(_G.EQUIPSLOTS.HANDS) or nil
    local reticule = player._gauntlet_reticule

    -- Resolve the verb + anchor only when the commander is equipped. Kept as an
    -- explicit branch (not an `and/or` chain) so GetCommandAnchor's two return
    -- values survive — the idiom would collapse them and drop the z coordinate.
    local command, ax, az
    if equipped ~= nil and equipped.prefab == "gauntlet_commander" then
        command = GetMinionCommandForCursor(player)
        ax, az = GetCommandAnchor(player, command)
    end

    if ax == nil then
        if reticule ~= nil and reticule:IsValid() then
            reticule:Hide()
        end
        return
    end

    if reticule == nil or not reticule:IsValid() then
        reticule = _G.SpawnPrefab("reticuleaoe")
        player._gauntlet_reticule = reticule
    end

    local c = RETICULE_COLOUR[command]
    reticule.Transform:SetPosition(ax, 0, az)
    reticule.AnimState:SetMultColour(c[1], c[2], c[3], 1)
    reticule:Show()
end

local function OnCommanderRightClick(down)
    if not down then
        return -- digitalvalue is false on release; fire on press only
    end
    local player = _G.ThePlayer
    if player == nil then
        return
    end
    local inventory = player.replica.inventory
    local equipped = inventory ~= nil and inventory:GetEquippedItem(_G.EQUIPSLOTS.HANDS) or nil
    if equipped == nil or equipped.prefab ~= "gauntlet_commander" then
        return
    end
    local pos = _G.TheInput:GetWorldPosition()
    if pos == nil then
        return
    end
    local command = GetMinionCommandForCursor(player)
    SendModRPCToServer(GetModRPC("EngineersGauntlet", "GauntletMinionCommand"),
        command, pos.x, pos.z)

    -- Cast feedback: a one-shot ping at the order's anchor, tinted to the verb —
    -- the visual partner to the server's confirm sound. Client-side and optimistic
    -- (the server still validates); the sound only plays on a real apply, so a
    -- no-op FOCUS pings without the confirm chime.
    local ax, az = GetCommandAnchor(player, command)
    if ax ~= nil then
        local ping = _G.SpawnPrefab("reticuleaoeping")
        if ping ~= nil then
            local c = RETICULE_COLOUR[command]
            ping.Transform:SetPosition(ax, 0, az)
            ping.AnimState:SetMultColour(c[1], c[2], c[3], 1)
        end
    end
end

-- Register once. Clients (and the host) have TheInput; a dedicated server does
-- not drive input, so the gate inside is moot there.
if _G.TheInput ~= nil then
    _G.TheInput:AddControlHandler(_G.CONTROL_SECONDARY, OnCommanderRightClick)
end

-- Drive the targeting preview per-frame for the LOCAL player. The controls widget
-- is built only where a player HUD exists (clients + host), never on the dedicated
-- server, and controls.owner IS that local player — the same gate the siege HUD
-- uses. Clean the reticule FX up when the player goes (it has no self-removal).
AddClassPostConstruct("widgets/controls", function(controls)
    local player = controls.owner
    -- Guard against driving the same player twice if the controls widget rebuilds
    -- (skin/character change) — otherwise a duplicate per-frame task would stack.
    if player == nil or player._gauntlet_reticule_driver then
        return
    end
    player._gauntlet_reticule_driver = true
    player:DoPeriodicTask(0, function()
        UpdateCommanderReticule(player)
    end)
    player:ListenForEvent("onremove", function()
        if player._gauntlet_reticule ~= nil and player._gauntlet_reticule:IsValid() then
            player._gauntlet_reticule:Remove()
        end
    end)
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
-- Client HUD (M5). A top-center siege-status readout (wave + Engine HP), drawn
-- from the objective's replicated netvars. AddClassPostConstruct only fires
-- where the player HUD is actually built (clients + host), so there's nothing to
-- guard for the dedicated server — it never constructs the controls widget.
--------------------------------------------------------------------------

local GauntletHUD = require("widgets/gauntlethud")

AddClassPostConstruct("widgets/controls", function(controls)
    controls.gauntlethud = controls.top_root:AddChild(GauntletHUD(controls.owner))
end)

--------------------------------------------------------------------------
-- Player-centric console harness (runs server-side via the remote console).
-- Observation/balancing rides the built-ins — c_godmode, c_freecrafting,
-- c_speedmult, c_spawn — those are not rebuilt here.
--   c_gauntlet_place/start/stop — objective + wave control (M1)
--   c_stress(n)          — slam n attackers on the objective now (M2 load dial)
--   c_naive(true/false)  — flip the naive-vs-optimized code path live (M2)
--   c_metrics()          — announce the perf readout to chat; c_metrics_reset() zeroes it
--------------------------------------------------------------------------

local function GetSiegeManager()
    if _G.TheWorld == nil or not _G.TheWorld.ismastersim then
        print("[Gauntlet] master-sim command — use the remote console (Ctrl toggles it)")
        return nil
    end
    return _G.TheWorld.components.siegemanager
end

-- Surface a line BOTH to the server log (print) and into in-game chat
-- (TheNet:Announce). A command typed in the remote console runs on the server,
-- so its print() lands only in the server log — invisible to the player driving
-- it. Announcing mirrors it into chat so the readout is actually readable
-- client-side during a live A/B. Announce is master-sim authoritative (guarded);
-- on a client this just prints locally. The on-screen metrics HUD is M5 — this
-- is the dev-harness stopgap.
local function GauntletReport(msg)
    print(msg)
    if _G.TheWorld ~= nil and _G.TheWorld.ismastersim and _G.TheNet ~= nil then
        _G.TheNet:Announce(msg)
    end
end

-- Liveness + siege state probe.
_G.c_gauntlet = function()
    GauntletReport(string.format("[Gauntlet] alive | mastersim=%s wave_size=%d",
        tostring(_G.TheNet:GetIsMasterSimulation()), TUNING.GAUNTLET_WAVE_SIZE))
    local siegemanager = _G.TheWorld ~= nil and _G.TheWorld.components.siegemanager or nil
    if siegemanager ~= nil then
        GauntletReport("[Gauntlet] " .. siegemanager:GetDebugString())
    end
    local metrics = _G.TheWorld ~= nil and _G.TheWorld.components.gauntletmetrics or nil
    if metrics ~= nil then
        GauntletReport("[Gauntlet] " .. metrics:GetReadout())
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

-- Spawn a specific M5 roster type on the objective (with the objective handoff),
-- to test the new attackers without grinding to their wave.
_G.c_breaker = function(n)
    local siegemanager = GetSiegeManager()
    if siegemanager ~= nil then
        return siegemanager:Stress(n or 5, "gauntlet_breaker")
    end
end

_G.c_swarmer = function(n)
    local siegemanager = GetSiegeManager()
    if siegemanager ~= nil then
        return siegemanager:Stress(n or 20, "gauntlet_swarmer")
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
    GauntletReport(string.format("[Gauntlet] naive path %s", siegemanager:IsNaive()
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
        GauntletReport("[Gauntlet] " .. metrics:GetReadout())
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
        GauntletReport("[Gauntlet] metrics counters reset")
    end
end

--------------------------------------------------------------------------
-- Minion harness (M4 Phase 4b). Drives the server-side command apply directly
-- for fast iteration; the real client->server command RPC + held tool land in
-- Phase 4c. All commands operate on the CALLING player's owned minions, so they
-- must be run from a connected client's remote console (ConsoleCommandPlayer is
-- nil with no players).
--   c_minion_spawn()  — deploy a minion at you, owned by you (DEFEND here)
--   c_minion_defend() — your minions hold your current position
--   c_minion_follow() — your minions follow you
--   c_minion_focus()  — your minions focus the nearest attacker to you
--------------------------------------------------------------------------

local function GetConsoleMinions()
    local player = _G.ConsoleCommandPlayer()
    if player == nil or player.components.leader == nil then
        print("[Gauntlet] minion commands need a connected player — run from the client remote console")
        return nil, nil
    end
    return player, player.components.leader:GetFollowersByTag("gauntlet_minion")
end

_G.c_minion_spawn = function()
    if _G.TheWorld == nil or not _G.TheWorld.ismastersim then
        print("[Gauntlet] master-sim only — use the remote console")
        return
    end
    local player = _G.ConsoleCommandPlayer()
    if player == nil then
        print("[Gauntlet] no player to deploy at")
        return
    end
    local pos = player:GetPosition()
    local minion = _G.SpawnPrefab("gauntlet_minion")
    minion.Transform:SetPosition(pos:Get())
    if not minion:SetMinionOwner(player) then
        print(string.format("[Gauntlet] at the minion cap (%d) — dismiss one first", TUNING.GAUNTLET_MINION_MAX))
        minion:Remove()
        return
    end
    minion:SetMinionCommand(MINION_COMMAND.DEFEND, pos.x, pos.z)
    print("[Gauntlet] Sentinel deployed and bound to you (DEFEND here)")
end

local function CommandConsoleMinions(mode, label, usepos)
    local player, minions = GetConsoleMinions()
    if minions == nil then
        return
    end
    local pos = usepos and player:GetPosition() or nil
    local n = 0
    for _, m in ipairs(minions) do
        if m:SetMinionCommand(mode, pos and pos.x or nil, pos and pos.z or nil) then
            n = n + 1
        end
    end
    print(string.format("[Gauntlet] %d/%d Sentinel(s) -> %s", n, #minions, label))
end

_G.c_minion_defend = function() CommandConsoleMinions(MINION_COMMAND.DEFEND, "DEFEND here", true) end
_G.c_minion_follow = function() CommandConsoleMinions(MINION_COMMAND.FOLLOW, "FOLLOW you", false) end

-- FOCUS picks the nearest attacker to YOU within a wide radius and sends that
-- attacker's position (so you needn't stand on the swarm). The 4c command tool
-- will instead pass the exact right-clicked attacker's position.
_G.c_minion_focus = function()
    local player, minions = GetConsoleMinions()
    if minions == nil then
        return
    end
    local pos = player:GetPosition()
    local nearest, ndsq = nil, math.huge
    for _, v in ipairs(_G.TheSim:FindEntities(pos.x, 0, pos.z, 40, TARGETING.ENEMY_MUST_TAGS, TARGETING.ENEMY_CANT_TAGS, TARGETING.ENEMY_ONEOF_TAGS)) do
        local dsq = v:GetDistanceSqToPoint(pos.x, 0, pos.z)
        if dsq < ndsq then
            nearest, ndsq = v, dsq
        end
    end
    if nearest == nil then
        print("[Gauntlet] c_minion_focus: no enemy nearby to focus (c_stress first)")
        return
    end
    local fp = nearest:GetPosition()
    local n = 0
    for _, m in ipairs(minions) do
        if m:SetMinionCommand(MINION_COMMAND.FOCUS, fp.x, fp.z) then
            n = n + 1
        end
    end
    print(string.format("[Gauntlet] %d/%d Sentinel(s) -> FOCUS attacker at (%.1f, %.1f)", n, #minions, fp.x, fp.z))
end

print("[Gauntlet] modmain loaded (wave_size=" .. tostring(TUNING.GAUNTLET_WAVE_SIZE) .. ")")
