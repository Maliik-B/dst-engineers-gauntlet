-- Gauntlet Engine — the defended objective.
--
-- Walls + catapult hybrid: a structure with health that mob combat can
-- target (needs a combat component to pass IsValidTarget) but that never
-- fights back. Reuses the moonbase art (the shipped siege objective) with a
-- recolor. Deliberately NOT registered as a pathfinder wall: attackers must
-- path TO it, not around it.

local GAUNTLET = require("gauntlet_constants")
local PHASE = GAUNTLET.PHASE
require("prefabutil") -- MakePlacer

local assets =
{
    Asset("ANIM", "anim/moonbase.zip"),
}

local prefabs =
{
    "collapse_small",
}

-- Damage-tier anims shipped in the moonbase bank: full / med / medlow / low.
local function GetDamageState(inst)
    local pct = inst.components.health:GetPercent()
    return (pct > .66 and "full")
        or (pct > .33 and "med")
        or (pct > 0 and "medlow")
        or "low"
end

-- Objective HP -> quantized net_byte bucket, the textbook continuous-value
-- replication: encode the 0..1 fraction as floor(frac*200+.5) (0.5% steps, the
-- health-penalty quantization, health_replica.lua:63-68) and set() only when
-- the bucket actually changes. set() dirties on real change only, so chipping
-- the engine to death produces at most ~200 replication events over its whole
-- life -- not one per damage tick. Contrast the dropped per-attacker net_float
-- (churned every tick); this is the value clients genuinely need (the HP bar),
-- replicated the cheap, correct way.
local HP_QUANTUM = 200

local function PublishObjectiveHP(inst)
    local bucket = math.floor(inst.components.health:GetPercent() * HP_QUANTUM + .5)
    if inst._objhp:value() ~= bucket then
        inst._objhp:set(bucket)
        local metrics = TheWorld.components.gauntletmetrics
        if metrics ~= nil then
            metrics:CountNetvarDirty()
        end
    end
end

local function OnHealthDelta(inst, data)
    PublishObjectiveHP(inst)
    -- A broken (0 HP) Engine is repairable back to working order; a living one is
    -- NOT, so there's no mid-run or between-wave healing (see the repairable setup).
    if inst.components.repairable ~= nil then
        inst.components.repairable:SetHealthRepairable(inst.components.health:IsDead())
    end
    local state = GetDamageState(inst)
    if state == "low" then
        inst.AnimState:PlayAnimation("low")
    elseif data ~= nil and data.amount ~= nil and data.amount < 0 then
        inst.AnimState:PlayAnimation("hit_"..state)
        inst.AnimState:PushAnimation(state, false)
    elseif not inst.AnimState:IsCurrentAnimation(state) then
        inst.AnimState:PlayAnimation(state)
    end
end

local function OnDeath(inst)
    -- The broken engine stays standing (health.nofadeout); the siegemanager
    -- listens for this same "death" event to call the loss.
    inst.SoundEmitter:PlaySound("dontstarve/wilson/rock_break")
end

-- Hammer-to-dismantle: the deliberate player removal path (the wall idiom),
-- a separate channel from the combat/health lose bar. Removing the engine
-- fires "onremove", which the siegemanager reads as a voluntary stand-down
-- (NOT a defeat) — the moonbase precedent of interrupting the event by
-- acting on its trigger object. Ungated on purpose: you can dismantle
-- mid-run to call it off.
local function OnHammered(inst)
    local fx = SpawnPrefab("collapse_small")
    fx.Transform:SetPosition(inst.Transform:GetWorldPosition())
    fx:SetMaterial("rock")
    inst:Remove()
end

-- A lost run leaves the Engine a broken wreck (health hits 0, but nofadeout keeps
-- it standing). Rather than forcing a full rebuild, the wreck is repairable back to
-- working order -- the shipped broken-structure-repair pattern (sculptures fix from
-- broken via a material, sculptures.lua:90-94). One repair fully restores it, and
-- it's offered ONLY while broken.
local function OnEngineRepaired(inst, doer, repair_item)
    inst.components.health:SetPercent(1) -- revive the wreck to full
end

-- Defense in depth alongside the healthrepairable tag (managed in OnHealthDelta):
-- the repair only applies to a fully-broken Engine.
local function CanRepairEngine(inst, repair_item)
    return inst.components.health:IsDead()
end

-- The objective is targetable but never retaliates.
local function KeepTargetFn()
    return false
end

--------------------------------------------------------------------------
-- Server-side API used by the siegemanager.
--------------------------------------------------------------------------

local function SetSiegeWave(inst, wave)
    inst._wave:set(math.clamp(wave, 0, 63))
end

local function SetSiegeMaxWave(inst, maxwave)
    -- The run's total wave count, replicated so the HUD reads the server's value
    -- (not the client's local TUNING). Constant per run -> set once, no churn.
    inst._maxwave:set(math.clamp(maxwave, 0, 63))
end

local function SetSiegePhase(inst, phase)
    inst._phase:set(phase)
end

local function PlayWarningGrowl(inst)
    -- World-positioned SoundEmitter: replicates to nearby clients on its
    -- own, no netvar/RPC needed for transient audio.
    inst.SoundEmitter:PlaySound("dontstarve/creatures/hound/distant")
end

--------------------------------------------------------------------------
-- Client-side reactions to replicated siege state. Console prints for M1;
-- these listeners become the HUD hooks later.
--------------------------------------------------------------------------

local function OnWaveDirty(inst)
    print(string.format("[Gauntlet] client: wave -> %d", inst._wave:value()))
end

local function OnPhaseDirty(inst)
    print(string.format("[Gauntlet] client: phase -> %s",
        GAUNTLET.PHASE_NAMES[inst._phase:value()] or tostring(inst._phase:value())))
end

local function OnHPDirty(inst)
    -- Decode the bucket back to a fraction (the HP bar reads this in M5).
    print(string.format("[Gauntlet] client: objective HP -> %d%%",
        math.floor(inst._objhp:value() / 200 * 100 + .5)))
end

--------------------------------------------------------------------------
-- In-world start: craft the Engine, then "Begin the Gauntlet" (activate) to
-- launch the run -- the shipped activatable pattern (yotr_fightring bell). The
-- action is offered only when a run can actually start, gated off the
-- replicated phase + HP so it never shows mid-siege or on a destroyed Engine.
-- Hammering the Engine stays the stand-down (the existing workable channel).
--------------------------------------------------------------------------

local STARTABLE_PHASE =
{
    [PHASE.IDLE] = true,
    [PHASE.VICTORY] = true, -- rematch on the same Engine
    [PHASE.DEFEAT] = true,  -- retry (gated to a still-alive Engine below)
}

-- Client + server gate for offering the ACTIVATE action. Reads the replicated
-- phase + HP netvars, so the option shows only when a fresh run can start and
-- is hidden mid-siege or on a dead Engine (componentactions.lua:142-154 calls
-- this during action collection, client-side).
local function CanBeginGauntlet(inst, doer)
    return STARTABLE_PHASE[inst._phase:value()] == true
        and inst._objhp:value() > 0
end

local function GetEngineActivateVerb(inst, doer)
    return "Begin the Gauntlet"
end

-- Server: activate -> start the siege. StartSiege is phase-aware (it won't
-- double-start an active run). Re-arm 'inactive' so the action returns next run.
local function OnEngineActivated(inst, doer)
    local siegemanager = TheWorld.components.siegemanager
    if siegemanager == nil then
        return false
    end
    siegemanager:StartSiege()
    if inst.components.activatable ~= nil then
        inst.components.activatable.inactive = true
    end
    return true
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddMiniMapEntity()
    inst.entity:AddLight()
    inst.entity:AddNetwork()

    -- Honest obstacle radius: attacker melee reach auto-scales off it
    -- (combat range checks add the target's physics radius).
    MakeObstaclePhysics(inst, 1)
    inst.Physics:SetDontRemoveOnSleep(true)

    inst.MiniMapEntity:SetIcon("moonbase.png")
    inst.MiniMapEntity:SetPriority(5)

    inst:AddTag("structure")
    inst:AddTag("gauntlet_objective")

    inst.AnimState:SetBank("moonbase")
    inst.AnimState:SetBuild("moonbase")
    inst.AnimState:PlayAnimation("full")
    inst.AnimState:SetMultColour(1, .82, .5, 1) -- amber recolor of the moonbase art
    inst.AnimState:SetFinalOffset(1)

    -- The Engine glows: a warm lit defensive zone so night isn't an uncontrolled
    -- difficulty spike (you can see to command + minions aren't fighting blind).
    -- Configured identically on both sides (pre-pristine) — deterministic, no netvar.
    inst.Light:SetRadius(TUNING.GAUNTLET_OBJECTIVE_LIGHT_RADIUS)
    inst.Light:SetIntensity(.65)
    inst.Light:SetFalloff(.7)
    inst.Light:SetColour(255 / 255, 215 / 255, 150 / 255)
    inst.Light:Enable(true)

    -- Replicated siege state. Declared on both sides, before SetPristine:
    -- wave counter quantized to a smallbyte, phase enum to a tinybyte, objective
    -- HP to a 0..200 net_byte bucket; set() fires the dirty event only on real
    -- change.
    inst._wave = net_smallbyte(inst.GUID, "gauntlet._wave", "gauntlet_wavedirty")
    inst._phase = net_tinybyte(inst.GUID, "gauntlet._phase", "gauntlet_phasedirty")
    inst._objhp = net_byte(inst.GUID, "gauntlet._objhp", "gauntlet_hpdirty")
    -- Run's total wave count (constant per run); the HUD reads this instead of the
    -- client's local TUNING, so it's always server-authoritative. No dirty event:
    -- the HUD polls it each frame.
    inst._maxwave = net_smallbyte(inst.GUID, "gauntlet._maxwave")

    inst.entity:SetPristine()

    -- In-world "Begin the Gauntlet" action hooks. Set on BOTH sides: the client
    -- reads them when collecting the right-click action and resolving its verb.
    inst.activatable_CanActivate = CanBeginGauntlet
    inst.GetActivateVerb = GetEngineActivateVerb

    if not TheWorld.ismastersim then
        inst:ListenForEvent("gauntlet_wavedirty", OnWaveDirty)
        inst:ListenForEvent("gauntlet_phasedirty", OnPhaseDirty)
        inst:ListenForEvent("gauntlet_hpdirty", OnHPDirty)
        return inst
    end

    inst:AddComponent("inspectable")

    inst:AddComponent("health")
    inst.components.health:SetMaxHealth(TUNING.GAUNTLET_OBJECTIVE_HEALTH)
    inst.components.health.nofadeout = true -- "death" leaves the broken engine, no erode
    -- canheal lets the REPAIR land (no regen source exists, so nothing auto-heals);
    -- the broken wreck is repaired back via the repairable component below.
    inst.components.health.canheal = true
    -- Halve player weapon damage: the engine stays destroyable by hand like
    -- any DST structure (a hammer-less player can tear it down to end a siege),
    -- just at roughly attacker-tier DPS. The hammer channel below is the clean
    -- *neutral* dismantle; weapon-to-death trips the normal lose condition.
    -- (DoDelta only applies this when the afflicter has the "player" tag, so
    -- mob damage — the lose bar — is untouched.)
    inst.components.health:SetAbsorptionAmountFromPlayer(TUNING.GAUNTLET_OBJECTIVE_PLAYER_ABSORB)
    -- Seed the replicated HP bucket to full (SetMaxHealth doesn't fire
    -- "healthdelta", so the listener below won't until the first hit).
    PublishObjectiveHP(inst)

    -- Combat exists purely so attackers can target it; KeepTargetFn = false
    -- means it never holds a target of its own.
    inst:AddComponent("combat")
    inst.components.combat:SetKeepTargetFunction(KeepTargetFn)

    -- Deconstruct channel, separate from the lose bar (the wall pattern).
    inst:AddComponent("workable")
    inst.components.workable:SetWorkAction(ACTIONS.HAMMER)
    inst.components.workable:SetWorkLeft(TUNING.GAUNTLET_OBJECTIVE_WORK)
    inst.components.workable:SetOnFinishCallback(OnHammered)

    -- The in-world start trigger. inactive=true keeps the action offered; the
    -- phase/HP gate (inst.activatable_CanActivate) hides it during a live run.
    inst:AddComponent("activatable")
    inst.components.activatable.OnActivate = OnEngineActivated
    inst.components.activatable.inactive = true

    -- A lost Engine becomes a broken wreck you REPAIR back with cutstone, rather
    -- than rebuilding from scratch -- you keep your placement and most of the cost.
    -- Gated to the broken state via the healthrepairable tag (set in OnHealthDelta),
    -- so it's never a mid-run or between-wave heal; hammer still removes it to relocate.
    inst:AddComponent("repairable")
    inst.components.repairable.repairmaterial = MATERIALS.STONE
    inst.components.repairable.onrepaired = OnEngineRepaired
    inst.components.repairable.testvalidrepairfn = CanRepairEngine
    inst.components.repairable.noannounce = true
    inst.components.repairable:SetWorkRepairable(false)   -- the hammer-dismantle isn't repairable
    inst.components.repairable:SetHealthRepairable(false) -- becomes true only once broken

    inst:ListenForEvent("healthdelta", OnHealthDelta)
    inst:ListenForEvent("death", OnDeath)

    inst.SetSiegeWave = SetSiegeWave
    inst.SetSiegeMaxWave = SetSiegeMaxWave
    inst.SetSiegePhase = SetSiegePhase
    inst.PlayWarningGrowl = PlayWarningGrowl
    -- Seed the total now so the HUD reads a valid count immediately; the
    -- siegemanager re-asserts it on registration (authoritative).
    SetSiegeMaxWave(inst, TUNING.GAUNTLET_NUM_WAVES)

    -- Self-registration with the siege manager; runs on fresh placement AND
    -- on save-load, so the manager's objective reference is self-healing.
    TheWorld:PushEvent("ms_gauntletobjective_placed", inst)

    return inst
end

local function PlacerPostInit(inst)
    inst.AnimState:SetMultColour(1, .82, .5, 1) -- amber ghost, matches the Engine art
end

return Prefab("gauntlet_objective", fn, assets, prefabs),
    MakePlacer("gauntlet_objective_placer", "moonbase", "moonbase", "full",
        nil, nil, nil, nil, nil, nil, PlacerPostInit)
