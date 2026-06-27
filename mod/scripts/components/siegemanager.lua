--------------------------------------------------------------------------
-- SiegeManager — master-sim world component that drives the Gauntlet wave
-- loop. Modeled on hounded.lua (phase state machine + drip-release in
-- OnUpdate, LongUpdate = OnUpdate) with the inter-wave clock delegated to
-- worldsettingstimer (deerclopsspawner pattern) for free save/load,
-- pause/resume and config rescaling.
--
-- All gameplay truth lives here, on the master sim. The objective prefab
-- carries the replicated wave/phase netvars; this component only mirrors
-- state into them.
--------------------------------------------------------------------------

local GAUNTLET = require("gauntlet_constants")
local PHASE = GAUNTLET.PHASE
local PHASE_NAMES = GAUNTLET.PHASE_NAMES

-- worldsettingstimer names live in one flat table; keep ours prefixed.
local WAVE_TIMER = "siegemanager_nextwave"

return Class(function(self, inst)

assert(TheWorld.ismastersim, "SiegeManager should not exist on client")

--------------------------------------------------------------------------
--[[ Member variables ]]
--------------------------------------------------------------------------

self.inst = inst

local _worldsettingstimer = TheWorld.components.worldsettingstimer
local _objective = nil
local _phase = PHASE.IDLE
local _wavenum = 0
local _breakersthiswave = 0 -- bounded by GAUNTLET_BREAKER_CAP; reset each wave start
local _spawnsleft = 0
local _timetonextspawn = 0
local _activeattackers = {}
local _numactive = 0
local _warning = false
local _timetonextwarnsound = 0
local _updating = false
local _naive = false -- M2 load dial: deliberately-naive code path (c_naive)
local _resulttask = nil -- pending VICTORY/DEFEAT -> IDLE return (the results window)

--------------------------------------------------------------------------
--[[ Private: state plumbing ]]
--------------------------------------------------------------------------

-- The component only ticks while a run is live (PREP warning cadence,
-- ACTIVE drip-release); idle/terminal phases cost zero update time.
local function SetUpdating(enable)
    if enable ~= _updating then
        _updating = enable
        if enable then
            inst:StartUpdatingComponent(self)
        else
            inst:StopUpdatingComponent(self)
        end
    end
end

local function SetPhase(phase)
    -- Leaving a terminal phase (a new run, a stop, or the results window expiring)
    -- cancels the pending auto-return to IDLE.
    if phase ~= PHASE.VICTORY and phase ~= PHASE.DEFEAT and _resulttask ~= nil then
        _resulttask:Cancel()
        _resulttask = nil
    end
    _phase = phase
    if _objective ~= nil and _objective:IsValid() then
        _objective:SetSiegePhase(phase)
    end
end

local function SetWave(wave)
    _wavenum = wave
    if _objective ~= nil and _objective:IsValid() then
        _objective:SetSiegeWave(wave)
        -- Re-assert the replicated total here too (set-on-change, no churn) so a
        -- server-side NUM_WAVES change reflects on the next siege without a
        -- re-place — SetWave(0) runs at every fresh-run start.
        _objective:SetSiegeMaxWave(TUNING.GAUNTLET_NUM_WAVES)
    end
end

-- Clamped per-wave table lookup: the row for `wave` clamped to [1, #t], or nil if the
-- table is missing/empty. Shared by every per-wave tuning table (counts, cadence,
-- warning, breaker floor/cap) so the clamp logic lives in exactly one place.
local function ClampedRow(t, wave)
    if t ~= nil and #t > 0 then
        return t[math.max(1, math.min(wave, #t))]
    end
    return nil
end

local function CalcWaveSize(wave)
    -- The explicit per-wave counts are the tuned shape at the DEFAULT wave_size; the
    -- wave_size config scales them (a difficulty/load multiplier — "Stress 80" drives
    -- the perf A/Bs). The WAVE_SIZE*growth formula is the fallback beyond the table.
    local base = ClampedRow(TUNING.GAUNTLET_WAVE_COUNTS, wave)
    if base ~= nil then
        return math.max(1, math.floor(base * TUNING.GAUNTLET_WAVE_SIZE / TUNING.GAUNTLET_WAVE_SIZE_BASE + .5))
    end
    return math.max(1, math.floor(TUNING.GAUNTLET_WAVE_SIZE * (1 + TUNING.GAUNTLET_WAVE_GROWTH * (wave - 1)) + .5))
end

--------------------------------------------------------------------------
--[[ Private: attacker bookkeeping ]]
--------------------------------------------------------------------------

local OnAttackerGone = nil

local function UntrackAttacker(attacker)
    if _activeattackers[attacker] then
        _activeattackers[attacker] = nil
        _numactive = _numactive - 1
        inst:RemoveEventCallback("death", OnAttackerGone, attacker)
        inst:RemoveEventCallback("onremove", OnAttackerGone, attacker)
    end
end

-- Watch both "death" and "onremove": death is the normal wave-clear path,
-- and onremove is the safety net so a despawn that skips death can't leave
-- _numactive stuck positive (which would softlock wave-clear detection).
-- UntrackAttacker is idempotent, so death-then-corpse-removal is harmless.
OnAttackerGone = function(attacker)
    UntrackAttacker(attacker)
end

local function TrackAttacker(attacker)
    _activeattackers[attacker] = true
    _numactive = _numactive + 1
    inst:ListenForEvent("death", OnAttackerGone, attacker)
    inst:ListenForEvent("onremove", OnAttackerGone, attacker)
end

local function RemoveAllAttackers(kill)
    local attackers = {}
    for attacker in pairs(_activeattackers) do
        table.insert(attackers, attacker)
    end
    for _, attacker in ipairs(attackers) do
        -- Untrack first: detaches the onremove listener so the Remove/Kill
        -- below isn't re-entrantly processed as wave attrition.
        UntrackAttacker(attacker)
        if kill then
            if attacker.components.health ~= nil and not attacker.components.health:IsDead() then
                attacker.components.health:Kill()
            end
        else
            attacker:Remove()
        end
    end
end

--------------------------------------------------------------------------
--[[ Private: spawning ]]
--------------------------------------------------------------------------

local function NoHoles(pt)
    return not TheWorld.Map:IsPointNearHole(pt)
end

-- Fan of candidate angles on a ring around the objective, walkable and no-hole
-- checked (hounded's GetSpawnPoint geometry, inverted onto the objective instead
-- of a target player). Tries progressively CLOSER rings so a cramped placement
-- (water/holes eating the outer ring) still finds ground instead of stalling the
-- whole siege with zero spawns. Last resort: the objective's own tile (it was
-- placeable, so it's walkable) — this never returns nil while an objective exists,
-- so the drip can't dead-loop on a bad placement.
-- Progressively closer rings (multipliers of SPAWN_DIST) tried in order; hoisted so
-- the drip hot path doesn't rebuild the list on every spawn.
local SPAWN_RING_RATIOS = { 1, .66, .4, .25 }
local function GetSpawnPoint(pt)
    local dist = TUNING.GAUNTLET_SPAWN_DIST
    for _, ratio in ipairs(SPAWN_RING_RATIOS) do
        local offset = FindWalkableOffset(pt, math.random() * TWOPI, dist * ratio, 12, true, true, NoHoles)
        if offset ~= nil then
            return pt + offset
        end
    end
    return pt -- boxed in by water/holes: spawn at the objective rather than not at all
end

-- Optimized server->client wave announcement: ONE batched RPC carrying the
-- whole wave (wave, count, tier), versus the naive per-spawn flood in
-- SpawnOneAt. Server->client is trusted/unrated, so the cost on display is the
-- send VOLUME -- one here vs one-per-attacker there. Counted into the same
-- spawn-RPC metric so the A/B reads directly (e.g. 150 -> 1).
local function SendWaveBatchRPC(wave, count, tier)
    SendModRPCToClient(GetClientModRPC("EngineersGauntlet", "GauntletWaveIncoming"), nil, wave, count, tier or 1)
    local metrics = TheWorld.components.gauntletmetrics
    if metrics ~= nil then
        metrics:CountSpawnRPC()
    end
end

-- Wave roster: which attacker types are eligible per wave, weighted. Early waves
-- are pure Besiegers; the Swarmer joins at wave 2 and the Breaker at wave 3, so
-- difficulty + variety ramp together. Extensible — v2's ranged type is one row.
local WAVE_ROSTER =
{
    { prefab = "gauntlet_attacker", weight = 1.0, minwave = 1 }, -- Besieger (baseline)
    { prefab = "gauntlet_swarmer",  weight = 0.7, minwave = 2 }, -- fast chaff
    -- Breaker weight RAMPS per wave (the Varglet-analog concentration spike grows late).
    { prefab = "gauntlet_breaker",  weight = 0.4, minwave = 3, rampkey = "GAUNTLET_BREAKER_WEIGHT_RAMP" },
}

-- Effective roster weight at a wave: base + ramp*(waves past minwave). Ramp reads live
-- from TUNING (rampkey) so breaker prevalence stays tunable mid-playtest.
local function EffWeight(e, wave)
    local ramp = e.rampkey and (TUNING[e.rampkey] or 0) or 0
    return e.weight + ramp * math.max(0, wave - e.minwave)
end

local function PickAttackerPrefab(wave)
    local total, eligible = 0, {}
    for _, e in ipairs(WAVE_ROSTER) do
        if wave >= e.minwave then
            local w = EffWeight(e, wave)
            total = total + w
            eligible[#eligible + 1] = { prefab = e.prefab, w = w }
        end
    end
    if total <= 0 then
        return "gauntlet_attacker"
    end
    local roll = math.random() * total
    for _, e in ipairs(eligible) do
        roll = roll - e.w
        if roll <= 0 then
            return e.prefab
        end
    end
    return "gauntlet_attacker"
end

-- Per-wave spawn cadence (rolling -> burst). Returns base, var for delay = base+rand*var,
-- from GAUNTLET_SPAWN_CADENCE clamped to its last row; falls back to the flat pair.
local function WaveCadence(wave)
    local row = ClampedRow(TUNING.GAUNTLET_SPAWN_CADENCE, wave)
    if row ~= nil then
        return row[1], row[2]
    end
    return TUNING.GAUNTLET_SPAWN_INTERVAL_BASE, TUNING.GAUNTLET_SPAWN_INTERVAL_VAR
end

-- Per-wave warning window (shrinks late); falls back to the flat WARN_DURATION.
local function WaveWarnDuration(wave)
    return ClampedRow(TUNING.GAUNTLET_WARN_BY_WAVE, wave) or TUNING.GAUNTLET_WARN_DURATION
end

-- Per-wave hard cap on Breakers (the variance ceiling); no cap table -> 0.
local function BreakerCap(wave)
    return ClampedRow(TUNING.GAUNTLET_BREAKER_CAP, wave) or 0
end

-- Per-wave guaranteed minimum Breakers (the variance floor); none -> 0.
local function BreakerFloor(wave)
    return ClampedRow(TUNING.GAUNTLET_BREAKER_FLOOR, wave) or 0
end

-- Spawn one attacker (prefab `prefab`, default the Besieger) at pt, hand off the
-- objective, track it, and (naive only) fire the per-spawn RPC tax. All attacker
-- types share entitytracker + the brain, so the handoff is uniform. Callers
-- guarantee _objective is valid.
local function SpawnOneAt(pt, prefab)
    local attacker = SpawnPrefab(prefab or "gauntlet_attacker")
    -- Objective handoff: stamped per-spawn so the brain's leash/siege nodes
    -- and the anti-kiting gates all read the same tracked entity.
    attacker.components.entitytracker:TrackEntity("gauntlet_objective", _objective)
    if attacker.Physics ~= nil then
        attacker.Physics:Teleport(pt:Get())
    else
        attacker.Transform:SetPosition(pt:Get())
    end
    attacker:FacePoint(_objective:GetPosition())
    attacker.components.spawnfader:FadeIn()
    TrackAttacker(attacker)

    if _naive then
        -- Naive tax: ONE server->client RPC per spawn (M3 batches this into one
        -- per-wave RPC). Server->client is trusted/unrated, so the whole burst
        -- goes out -- that's the bandwidth strawman. GetClientModRPC/Send are
        -- file-scope globals, callable straight from a component.
        SendModRPCToClient(GetClientModRPC("EngineersGauntlet", "GauntletAttackerSpawned"), nil, pt.x, pt.z)
        local metrics = TheWorld.components.gauntletmetrics
        if metrics ~= nil then
            metrics:CountSpawnRPC()
        end
    end
    return attacker
end

local function SpawnAttacker()
    if _objective == nil or not _objective:IsValid() then
        return false
    end
    -- Hard concurrent cap (back-pressure, not loss): the drip just retries next
    -- tick, so a wave can't push live attackers past the ceiling -- it waits for
    -- the field to thin. Bounds runaway spawning regardless of wave config.
    if _numactive >= TUNING.GAUNTLET_MAX_ATTACKERS then
        return false
    end
    local pt = GetSpawnPoint(_objective:GetPosition())
    if pt == nil then
        return false
    end
    -- Wave attackers are a roster mix that ramps by wave; c_stress stays pure
    -- Besieger for a clean uniform load A/B (see Stress). The Breaker count is bounded
    -- to [floor, cap]: force Breakers if the rolls fall short of the floor and we're
    -- about to run out of spawns (GetSpawnPoint never fails now, so _spawnsleft maps
    -- 1:1 to remaining spawns and the count is exact); the cap stops an over-spike.
    local prefab = PickAttackerPrefab(_wavenum)
    local floor = math.min(BreakerFloor(_wavenum), BreakerCap(_wavenum)) -- floor can't exceed cap
    if _breakersthiswave < floor and _spawnsleft <= floor - _breakersthiswave then
        prefab = "gauntlet_breaker"
    end
    if prefab == "gauntlet_breaker" then
        if _breakersthiswave >= BreakerCap(_wavenum) then
            prefab = "gauntlet_attacker"
        else
            _breakersthiswave = _breakersthiswave + 1
        end
    end
    SpawnOneAt(pt, prefab)
    return true
end

--------------------------------------------------------------------------
--[[ Private: wave flow ]]
--------------------------------------------------------------------------

local function ScheduleWave(delay)
    if _worldsettingstimer:ActiveTimerExists(WAVE_TIMER) then
        _worldsettingstimer:StopTimer(WAVE_TIMER)
    end
    _worldsettingstimer:StartTimer(WAVE_TIMER, delay)
    _warning = false
    SetPhase(PHASE.PREP)
    SetUpdating(true)
end

local function StartWave()
    if _phase ~= PHASE.PREP then
        return
    end
    SetWave(_wavenum + 1)
    _spawnsleft = CalcWaveSize(_wavenum)
    _breakersthiswave = 0 -- reset the per-wave Breaker cap counter
    _timetonextspawn = 0
    _warning = false
    SetPhase(PHASE.ACTIVE)
    if not _naive then
        -- Optimized: announce the whole wave to clients in ONE batched RPC up
        -- front. The naive path instead emits one RPC per attacker as it drips.
        SendWaveBatchRPC(_wavenum, _spawnsleft, 1)
    end
    TheNet:Announce(string.format("Wave %d of %d! %d attackers seek the Engine.",
        _wavenum, TUNING.GAUNTLET_NUM_WAVES, _spawnsleft))
end

local function OnWaveTimerDone()
    StartWave()
end

-- After a win/loss, hold the result for a window, then return to IDLE on its own
-- (the HUD clears, state resets; the objective stays for a rematch). SetPhase
-- cancels this if a new run starts first.
local function ScheduleResultsWindow()
    if _resulttask ~= nil then
        _resulttask:Cancel()
    end
    _resulttask = inst:DoTaskInTime(TUNING.GAUNTLET_RESULT_DISPLAY, function()
        _resulttask = nil
        SetWave(0)
        SetPhase(PHASE.IDLE)
    end)
end

-- Engine HP as an integer percent — shown in chat + logged so the toll per wave
-- (and the final margin) is captured for tuning. 0 if the objective is gone.
local function EngineHPPct()
    return (_objective ~= nil and _objective:IsValid() and _objective.components.health ~= nil)
        and math.floor(_objective.components.health:GetPercent() * 100 + .5) or 0
end

local function Victory()
    SetPhase(PHASE.VICTORY)
    SetUpdating(false)
    ScheduleResultsWindow()
    local hp = EngineHPPct()
    print(string.format("[Gauntlet] VICTORY — Engine at %d%%", hp))
    TheNet:Announce(string.format("Victory! The Engine survived all %d waves at %d%%.", _wavenum, hp))
end

local function Defeat()
    SetPhase(PHASE.DEFEAT)
    _spawnsleft = 0
    if _worldsettingstimer:ActiveTimerExists(WAVE_TIMER) then
        _worldsettingstimer:StopTimer(WAVE_TIMER)
    end
    SetUpdating(false)
    RemoveAllAttackers(true)
    ScheduleResultsWindow()
    TheNet:Announce("The Engine has fallen. The gauntlet is lost.")
end

local function OnWaveCleared()
    if _wavenum >= TUNING.GAUNTLET_NUM_WAVES then
        Victory()
    else
        -- Fires when the wave's last attacker dies (the user-requested "wave done"
        -- cue). Victory() covers the final wave, so this is non-final only. The HP
        -- read shows the wave's toll — player-facing in chat + logged for tuning.
        local hp = EngineHPPct()
        print(string.format("[Gauntlet] Wave %d cleared — Engine at %d%%", _wavenum, hp))
        TheNet:Announce(string.format("Wave %d repelled! Engine at %d%%.", _wavenum, hp))
        ScheduleWave(TUNING.GAUNTLET_WAVE_DELAY)
    end
end

--------------------------------------------------------------------------
--[[ Private: objective registration ]]
--------------------------------------------------------------------------

local function OnObjectiveDeath()
    if _phase == PHASE.PREP or _phase == PHASE.ACTIVE then
        Defeat()
    end
end

local OnObjectiveRemoved = nil

local function UnregisterObjective()
    if _objective ~= nil and _objective:IsValid() then
        inst:RemoveEventCallback("death", OnObjectiveDeath, _objective)
        inst:RemoveEventCallback("onremove", OnObjectiveRemoved, _objective)
    end
    _objective = nil
end

local function RegisterObjective(objective)
    if _objective == objective then
        return
    end
    UnregisterObjective()
    _objective = objective
    inst:ListenForEvent("death", OnObjectiveDeath, objective)
    inst:ListenForEvent("onremove", OnObjectiveRemoved, objective)
    -- A newly placed (or just-loaded) objective renders current siege state.
    objective:SetSiegeWave(_wavenum)
    objective:SetSiegeMaxWave(TUNING.GAUNTLET_NUM_WAVES)
    objective:SetSiegePhase(_phase)
end

OnObjectiveRemoved = function()
    _objective = nil
    if _phase ~= PHASE.IDLE then
        -- Objective vanished outside the place/stop flow (console
        -- shenanigans): reset to a clean slate rather than limping on.
        self:StopSiege(true)
    end
end

--------------------------------------------------------------------------
--[[ Public API (console harness calls these directly) ]]
--------------------------------------------------------------------------

function self:GetObjective()
    return _objective
end

-- Place (or replace) the objective. pt is a Vector3, typically the calling
-- player's position.
function self:PlaceObjective(pt)
    if _phase == PHASE.PREP or _phase == PHASE.ACTIVE then
        print("[Gauntlet] Can't move the objective mid-siege — c_gauntlet_stop() first")
        return nil
    end
    if _objective ~= nil and _objective:IsValid() then
        -- Deliberate replacement: detach listeners first so this Remove
        -- doesn't read as an external removal.
        local old = _objective
        UnregisterObjective()
        old:Remove()
    end
    -- Fresh slate (clears stale VICTORY/DEFEAT from a previous run) before
    -- the new objective registers and mirrors it.
    SetWave(0)
    SetPhase(PHASE.IDLE)
    local objective = SpawnPrefab("gauntlet_objective")
    objective.Transform:SetPosition(pt:Get())
    -- Registration already happened via "ms_gauntletobjective_placed"
    -- during SpawnPrefab.
    return objective
end

function self:StartSiege()
    if _objective == nil or not _objective:IsValid() then
        print("[Gauntlet] No objective placed — run c_gauntlet_place() first")
        return
    elseif _objective.components.health:IsDead() then
        print("[Gauntlet] The Engine is destroyed — place a fresh one with c_gauntlet_place()")
        return
    elseif _phase == PHASE.ACTIVE then
        print("[Gauntlet] A wave is already active")
        return
    elseif _phase == PHASE.PREP then
        -- Impatient start during the countdown: skip straight to the wave.
        _worldsettingstimer:SetTimeLeft(WAVE_TIMER, 0)
        print("[Gauntlet] Skipping the countdown")
        return
    end

    -- Fresh run (IDLE, or restart after VICTORY).
    _objective.components.health:SetPercent(1)
    SetWave(0)
    ScheduleWave(TUNING.GAUNTLET_FIRST_WAVE_DELAY)
    TheNet:Announce(string.format("The gauntlet begins! First wave in %d seconds.",
        TUNING.GAUNTLET_FIRST_WAVE_DELAY))
end

-- c_stress(n): slam n attackers onto the objective immediately (no drip), for
-- load measurement. Tracked like wave attackers, so c_gauntlet_stop() clears
-- them; intended for raw-load tests in IDLE, but valid in any non-terminal
-- phase (during a wave it simply adds to the live count).
function self:Stress(n, prefab)
    if _objective == nil or not _objective:IsValid() then
        print("[Gauntlet] no objective placed — run c_gauntlet_place() first")
        return 0
    elseif _objective.components.health:IsDead() then
        print("[Gauntlet] the Engine is destroyed — place a fresh one first")
        return 0
    end
    prefab = prefab or "gauntlet_attacker"
    n = math.max(0, math.floor(tonumber(n) or 0))
    local objectivepos = _objective:GetPosition()
    local spawned = 0
    local capped = false
    for _ = 1, n do
        if _numactive >= TUNING.GAUNTLET_MAX_ATTACKERS then
            capped = true
            break
        end
        local pt = GetSpawnPoint(objectivepos)
        if pt ~= nil then
            -- Default (c_stress) = Besieger: uniform load for the c_naive A/B.
            SpawnOneAt(pt, prefab)
            spawned = spawned + 1
        end
    end
    if not _naive and spawned > 0 then
        -- Optimized: one batched RPC for the whole stress dump (wave 0 = not a
        -- real wave). Naive already fired one per spawn inside SpawnOneAt.
        SendWaveBatchRPC(_wavenum, spawned, 1)
    end
    print(string.format("[Gauntlet] c_stress: +%d/%d %s (active=%d/%d, naive=%s)%s",
        spawned, n, prefab, _numactive, TUNING.GAUNTLET_MAX_ATTACKERS, tostring(_naive),
        capped and " — hit the concurrent cap" or ""))
    return spawned
end

function self:IsNaive()
    return _naive
end

-- c_naive(bool): flip the deliberately-naive code path for the whole arena.
-- Live -- pushes to every attacker already in the field via TheWorld, and new
-- spawns inherit the flag.
function self:SetNaive(enable)
    enable = enable and true or false
    if enable ~= _naive then
        _naive = enable
        TheWorld:PushEvent("gauntlet_naivechanged", { naive = _naive })
    end
end

function self:StopSiege(silent)
    if _worldsettingstimer:ActiveTimerExists(WAVE_TIMER) then
        _worldsettingstimer:StopTimer(WAVE_TIMER)
    end
    RemoveAllAttackers(false)
    _spawnsleft = 0
    _warning = false
    SetUpdating(false)
    SetWave(0)
    SetPhase(PHASE.IDLE)
    if not silent then
        TheNet:Announce("The gauntlet stands down.")
    end
end

--------------------------------------------------------------------------
--[[ Update loop: warning cadence (PREP) + drip-release (ACTIVE) ]]
--------------------------------------------------------------------------

function self:OnUpdate(dt)
    if _phase == PHASE.PREP then
        local timeleft = _worldsettingstimer:GetTimeLeft(WAVE_TIMER)
        if timeleft == nil then
            -- Timer fired this frame; StartWave runs from the scheduler.
            return
        end
        if not _warning and timeleft <= WaveWarnDuration(_wavenum + 1) then
            _warning = true
            _timetonextwarnsound = 0
            TheNet:Announce(string.format("Wave %d approaches the Engine...", _wavenum + 1))
        end
        if _warning then
            _timetonextwarnsound = _timetonextwarnsound - dt
            if _timetonextwarnsound <= 0 then
                -- Growl cadence accelerates as the wave nears (hounded's
                -- warning brackets, rescaled to our shorter warning).
                _timetonextwarnsound =
                    (timeleft < 5 and .3 + math.random() * .7) or
                    (timeleft < 10 and 1 + math.random()) or
                    2 + math.random() * 2
                if _objective ~= nil and _objective:IsValid() then
                    _objective:PlayWarningGrowl()
                end
            end
        end
    elseif _phase == PHASE.ACTIVE then
        if _spawnsleft > 0 then
            -- Drip-release: one spawn per interval, never a burst.
            _timetonextspawn = _timetonextspawn - dt
            if _timetonextspawn <= 0 then
                if SpawnAttacker() then
                    _spawnsleft = _spawnsleft - 1
                    -- Per-wave cadence: rolling early, burst late (the current wave).
                    local base, var = WaveCadence(_wavenum)
                    _timetonextspawn = base + math.random() * var
                else
                    _timetonextspawn = 1 -- no walkable spawn point this attempt; retry shortly
                end
            end
        elseif _numactive <= 0 then
            -- Whole wave spawned and all attackers dead: clear it. OnLoad
            -- never leaves _phase == ACTIVE (it converts a mid-wave save to a
            -- PREP re-run), so a load-time LongUpdate can't reach this branch
            -- with an empty just-restored wave and miscredit it as cleared.
            OnWaveCleared()
        end
    else
        -- Terminal/idle phases don't tick.
        SetUpdating(false)
    end
end

-- Time-skips (c_skip, sleeping, load catch-up) advance the warning/release
-- state too. NOTE: the engine calls LongUpdate on every component that
-- defines it, even one not in the update set — so this also fires once on
-- world load. OnLoad is written to leave a consistent phase for that call.
self.LongUpdate = self.OnUpdate

--------------------------------------------------------------------------
--[[ Save/Load ]]
--------------------------------------------------------------------------

function self:OnSave()
    -- Only the durable wave/phase is persisted. The in-flight wave (spawnsleft
    -- + live attackers) is intentionally dropped: attackers are persists=false
    -- and gone on reload, so OnLoad re-runs an interrupted wave instead.
    return {
        wave = _wavenum,
        phase = _phase,
    }
end

function self:OnLoad(data)
    data = data or {}
    _wavenum = data.wave or 0
    local loadedphase = data.phase or PHASE.IDLE
    -- A finished run's end-screen shouldn't return on reload; resume at IDLE
    -- (the objective re-registers and renders IDLE, so the HUD stays hidden).
    if loadedphase == PHASE.VICTORY or loadedphase == PHASE.DEFEAT then
        loadedphase = PHASE.IDLE
    end
    _phase = loadedphase

    if loadedphase == PHASE.ACTIVE then
        -- Mid-wave save: the wave's attackers were persists=false and are
        -- gone. A load-time LongUpdate would otherwise see this empty wave and
        -- miscredit it as cleared (advancing the counter). Convert it
        -- synchronously — before any LongUpdate can run — into a fair re-run
        -- of the interrupted wave (hounded's "give players a fighting chance").
        SetWave(math.max(0, _wavenum - 1))
        _spawnsleft = 0
        ScheduleWave(TUNING.GAUNTLET_WARN_DURATION + 5) -- -> PHASE.PREP, fresh countdown
    elseif loadedphase == PHASE.PREP then
        -- worldsettingstimer restores the WAVE_TIMER from its own save; just
        -- resume ticking. The reload-into-teeth clamp is deferred so it runs
        -- after every world component's OnLoad (the timer restore included).
        SetUpdating(true)
    end
    -- IDLE / VICTORY / DEFEAT: stable, nothing to schedule.

    if loadedphase == PHASE.PREP or loadedphase == PHASE.ACTIVE then
        inst:DoTaskInTime(0, function()
            -- Mid-run save but no live objective came back: clean slate.
            if _objective == nil or not _objective:IsValid()
                or (_objective.components.health ~= nil and _objective.components.health:IsDead()) then
                self:StopSiege(true)
                return
            end
            -- Only a genuinely-resumed countdown needs the reload clamp; the
            -- ACTIVE re-run above already scheduled a full fair warning.
            if loadedphase == PHASE.PREP then
                local timeleft = _worldsettingstimer:GetTimeLeft(WAVE_TIMER)
                if timeleft == nil then
                    ScheduleWave(TUNING.GAUNTLET_WAVE_DELAY)
                elseif timeleft < TUNING.GAUNTLET_WARN_DURATION + 5 then
                    -- Don't reload straight into the wave (hounded's load clamp).
                    _worldsettingstimer:SetTimeLeft(WAVE_TIMER, TUNING.GAUNTLET_WARN_DURATION + 5)
                end
            end
        end)
    end
end

--------------------------------------------------------------------------
--[[ Debug ]]
--------------------------------------------------------------------------

function self:GetDebugString()
    local timeleft = _worldsettingstimer:GetTimeLeft(WAVE_TIMER)
    local objectivestr = "none"
    if _objective ~= nil and _objective:IsValid() then
        local health = _objective.components.health
        objectivestr = string.format("%d/%d hp",
            math.floor(health.currenthealth + .5), math.floor(health.maxhealth + .5))
    end
    return string.format("phase=%s wave=%d/%d nextwave=%s warning=%s spawnsleft=%d active=%d naive=%s objective=%s",
        PHASE_NAMES[_phase] or tostring(_phase),
        _wavenum, TUNING.GAUNTLET_NUM_WAVES,
        timeleft ~= nil and string.format("%.1fs", timeleft) or "-",
        tostring(_warning),
        _spawnsleft,
        _numactive,
        tostring(_naive),
        objectivestr)
end

--------------------------------------------------------------------------
--[[ Initialization ]]
--------------------------------------------------------------------------

-- Inter-wave clock. maxtime doubles as the save-rescale base: a saved
-- fraction of the old delay maps onto a changed config cleanly.
-- Note: the clock keeps running with zero players online (unlike hounded's
-- empty-server freeze) — an arena run is started by hand and short; revisit
-- if dedicated public servers ever matter.
_worldsettingstimer:AddTimer(WAVE_TIMER, TUNING.GAUNTLET_WAVE_DELAY, true, OnWaveTimerDone)

inst:ListenForEvent("ms_gauntletobjective_placed", function(src, objective)
    RegisterObjective(objective)
end)

end)
