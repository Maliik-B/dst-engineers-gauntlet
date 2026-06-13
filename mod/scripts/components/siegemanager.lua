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
local _spawnsleft = 0
local _timetonextspawn = 0
local _activeattackers = {}
local _numactive = 0
local _warning = false
local _timetonextwarnsound = 0
local _updating = false

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
    _phase = phase
    if _objective ~= nil and _objective:IsValid() then
        _objective:SetSiegePhase(phase)
    end
end

local function SetWave(wave)
    _wavenum = wave
    if _objective ~= nil and _objective:IsValid() then
        _objective:SetSiegeWave(wave)
    end
end

local function CalcWaveSize(wave)
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

-- Fan of candidate angles on a ring around the objective, walkable and
-- no-hole checked (hounded's GetSpawnPoint geometry, inverted onto the
-- objective instead of a target player).
local function GetSpawnPoint(pt)
    local offset = FindWalkableOffset(pt, math.random() * TWOPI, TUNING.GAUNTLET_SPAWN_DIST, 12, true, true, NoHoles)
        or FindWalkableOffset(pt, math.random() * TWOPI, TUNING.GAUNTLET_SPAWN_DIST * .5, 8, true, true, NoHoles)
    return offset ~= nil and pt + offset or nil
end

local function SpawnAttacker()
    if _objective == nil or not _objective:IsValid() then
        return false
    end
    local objectivepos = _objective:GetPosition()
    local pt = GetSpawnPoint(objectivepos)
    if pt == nil then
        return false
    end

    local attacker = SpawnPrefab("gauntlet_attacker")
    -- Objective handoff: stamped per-spawn so the brain's leash/siege nodes
    -- and the anti-kiting gates all read the same tracked entity.
    attacker.components.entitytracker:TrackEntity("gauntlet_objective", _objective)
    if attacker.Physics ~= nil then
        attacker.Physics:Teleport(pt:Get())
    else
        attacker.Transform:SetPosition(pt:Get())
    end
    attacker:FacePoint(objectivepos)
    attacker.components.spawnfader:FadeIn()
    TrackAttacker(attacker)
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
    _timetonextspawn = 0
    _warning = false
    SetPhase(PHASE.ACTIVE)
    TheNet:Announce(string.format("Wave %d of %d! %d attackers seek the Engine.",
        _wavenum, TUNING.GAUNTLET_NUM_WAVES, _spawnsleft))
end

local function OnWaveTimerDone()
    StartWave()
end

local function Victory()
    SetPhase(PHASE.VICTORY)
    SetUpdating(false)
    TheNet:Announce(string.format("Victory! The Engine survived all %d waves.", _wavenum))
end

local function Defeat()
    SetPhase(PHASE.DEFEAT)
    _spawnsleft = 0
    if _worldsettingstimer:ActiveTimerExists(WAVE_TIMER) then
        _worldsettingstimer:StopTimer(WAVE_TIMER)
    end
    SetUpdating(false)
    RemoveAllAttackers(true)
    TheNet:Announce("The Engine has fallen. The gauntlet is lost.")
end

local function OnWaveCleared()
    if _wavenum >= TUNING.GAUNTLET_NUM_WAVES then
        Victory()
    else
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
        if not _warning and timeleft <= TUNING.GAUNTLET_WARN_DURATION then
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
                    _timetonextspawn = TUNING.GAUNTLET_SPAWN_INTERVAL_BASE
                        + math.random() * TUNING.GAUNTLET_SPAWN_INTERVAL_VAR
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
    return string.format("phase=%s wave=%d/%d nextwave=%s warning=%s spawnsleft=%d active=%d objective=%s",
        PHASE_NAMES[_phase] or tostring(_phase),
        _wavenum, TUNING.GAUNTLET_NUM_WAVES,
        timeleft ~= nil and string.format("%.1fs", timeleft) or "-",
        tostring(_warning),
        _spawnsleft,
        _numactive,
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
