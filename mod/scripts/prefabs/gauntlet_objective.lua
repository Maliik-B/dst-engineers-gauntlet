-- Gauntlet Engine — the defended objective.
--
-- Walls + catapult hybrid: a structure with health that mob combat can
-- target (needs a combat component to pass IsValidTarget) but that never
-- fights back. Reuses the moonbase art (the shipped siege objective) with a
-- recolor. Deliberately NOT registered as a pathfinder wall: attackers must
-- path TO it, not around it.

local GAUNTLET = require("gauntlet_constants")

local assets =
{
    Asset("ANIM", "anim/moonbase.zip"),
}

-- Damage-tier anims shipped in the moonbase bank: full / med / medlow / low.
local function GetDamageState(inst)
    local pct = inst.components.health:GetPercent()
    return (pct > .66 and "full")
        or (pct > .33 and "med")
        or (pct > 0 and "medlow")
        or "low"
end

local function OnHealthDelta(inst, data)
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

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddMiniMapEntity()
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

    -- Replicated siege state. Declared on both sides, before SetPristine:
    -- wave counter quantized to a smallbyte, phase enum to a tinybyte; set()
    -- fires the dirty event only on real change.
    inst._wave = net_smallbyte(inst.GUID, "gauntlet._wave", "gauntlet_wavedirty")
    inst._phase = net_tinybyte(inst.GUID, "gauntlet._phase", "gauntlet_phasedirty")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        inst:ListenForEvent("gauntlet_wavedirty", OnWaveDirty)
        inst:ListenForEvent("gauntlet_phasedirty", OnPhaseDirty)
        return inst
    end

    inst:AddComponent("inspectable")

    inst:AddComponent("health")
    inst.components.health:SetMaxHealth(TUNING.GAUNTLET_OBJECTIVE_HEALTH)
    inst.components.health.nofadeout = true -- "death" leaves the broken engine, no erode
    inst.components.health.canheal = false

    -- Combat exists purely so attackers can target it; KeepTargetFn = false
    -- means it never holds a target of its own.
    inst:AddComponent("combat")
    inst.components.combat:SetKeepTargetFunction(KeepTargetFn)

    inst:ListenForEvent("healthdelta", OnHealthDelta)
    inst:ListenForEvent("death", OnDeath)

    inst.SetSiegeWave = SetSiegeWave
    inst.SetSiegePhase = SetSiegePhase
    inst.PlayWarningGrowl = PlayWarningGrowl

    -- Self-registration with the siege manager; runs on fresh placement AND
    -- on save-load, so the manager's objective reference is self-healing.
    TheWorld:PushEvent("ms_gauntletobjective_placed", inst)

    return inst
end

return Prefab("gauntlet_objective", fn, assets)
