-- Gauntlet attacker — a retuned hound that sieges the Gauntlet objective.
--
-- The wave spawner stamps the objective onto each attacker at spawn time via
-- entitytracker (survives save/load by GUID), and the brain leashes to it.
-- Retarget/keep-target are proximity-gated to the objective so attackers
-- can't be kited away from the siege.

local assets =
{
    Asset("ANIM", "anim/hound_basic.zip"),
    Asset("ANIM", "anim/hound_ocean.zip"),
    Asset("SOUND", "sound/hound.fsb"),
}

local prefabs =
{
    "monstermeat",
    "houndstooth",
}

local brain = require("brains/gauntletattackerbrain")

local sounds =
{
    pant = "dontstarve/creatures/hound/pant",
    attack = "dontstarve/creatures/hound/attack",
    bite = "dontstarve/creatures/hound/bite",
    bark = "dontstarve/creatures/hound/bark",
    death = "dontstarve/creatures/hound/death",
    sleep = "dontstarve/creatures/hound/sleep",
    growl = "dontstarve/creatures/hound/growl",
    howl = "dontstarve/creatures/together/clayhound/howl",
    hurt = "dontstarve/creatures/hound/hurt",
}

SetSharedLootTable('gauntlet_attacker',
{
    {'monstermeat', 1.000},
    {'houndstooth', 0.125},
})

local SHARE_TARGET_DIST = 30

local function IsNearObjective(inst, dist)
    local objective = inst.components.entitytracker:GetEntity("gauntlet_objective")
    return objective == nil or inst:IsNear(objective, dist)
end

-- Anti-kiting: defenders are only acquired while the attacker is near the
-- objective, and only within a short radius.
local RETARGET_CANT_TAGS = { "wall", "hound", "gauntlet_attacker", "structure", "INLIMBO" }
local RETARGET_MUST_TAGS = { "player" }
local function RetargetFn(inst)
    return IsNearObjective(inst, TUNING.GAUNTLET_ATTACKER_AGGRO_DIST)
        and FindEntity(
                inst,
                TUNING.GAUNTLET_ATTACKER_TARGET_DIST,
                function(guy)
                    return inst.components.combat:CanTarget(guy)
                end,
                RETARGET_MUST_TAGS,
                RETARGET_CANT_TAGS
            )
        or nil
end

-- Dragged too far from the objective, or the target ran: drop it and let the
-- brain leash back to the siege.
local function KeepTargetFn(inst, target)
    return IsNearObjective(inst, TUNING.GAUNTLET_ATTACKER_RETURN_DIST)
        and inst.components.combat:CanTarget(target)
        and inst:IsNear(target, TUNING.GAUNTLET_ATTACKER_TARGET_KEEP)
end

local function OnAttacked(inst, data)
    if data.attacker ~= nil then
        inst.components.combat:SetTarget(data.attacker)
        inst.components.combat:ShareTarget(data.attacker, SHARE_TARGET_DIST,
            function(dude)
                return dude:HasTag("gauntlet_attacker")
                    and not (dude.components.health ~= nil and dude.components.health:IsDead())
            end, 5)
    end
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddDynamicShadow()
    inst.entity:AddNetwork()

    MakeCharacterPhysics(inst, 10, .5)

    inst.DynamicShadow:SetSize(2.5, 1.5)
    inst.Transform:SetFourFaced()

    inst:AddTag("scarytoprey")
    inst:AddTag("monster")
    inst:AddTag("hostile")
    inst:AddTag("hound")
    inst:AddTag("gauntlet_attacker")

    inst.AnimState:SetBank("hound")
    inst.AnimState:SetBuild("hound_ocean")
    inst.AnimState:PlayAnimation("idle")
    -- Additive tint (not mult: spawnfader drives the mult colour during the
    -- fade-in) — sickly green recolor of the hound art.
    inst.AnimState:SetAddColour(.04, .16, .02, 0)

    inst:AddComponent("spawnfader")

    -- Naive-path replication strawman (M2): a per-attacker net_float the naive
    -- load component re-set()s every tick. Declared on both sides before
    -- SetPristine (netvar hard rule); it carries no dirty event because no
    -- client reaction is needed -- the cost on display is the raw replication
    -- churn, which happens whether or not a listener is registered.
    inst._naivesync = net_float(inst.GUID, "gauntlet._naivesync")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    -- Arena rule: in-flight waves are not persisted. A reload mid-wave
    -- replans the wave from the siegemanager instead (hounded itself never
    -- saves its in-flight release queue).
    inst.persists = false

    inst.sounds = sounds

    inst:AddComponent("locomotor") -- locomotor must be constructed before the stategraph
    inst.components.locomotor.runspeed = TUNING.GAUNTLET_ATTACKER_SPEED

    inst:SetStateGraph("SGhound")
    inst.sg.mem.nocorpse = true
    inst.sg.mem.nolunarmutate = true

    inst:SetBrain(brain)

    inst:AddComponent("entitytracker")

    inst:AddComponent("health")
    inst.components.health:SetMaxHealth(TUNING.GAUNTLET_ATTACKER_HEALTH)

    inst:AddComponent("combat")
    inst.components.combat:SetDefaultDamage(TUNING.GAUNTLET_ATTACKER_DAMAGE)
    inst.components.combat:SetAttackPeriod(TUNING.GAUNTLET_ATTACKER_ATTACK_PERIOD)
    inst.components.combat:SetRange(TUNING.GAUNTLET_ATTACKER_ATTACK_RANGE)
    inst.components.combat:SetRetargetFunction(3, RetargetFn)
    inst.components.combat:SetKeepTargetFunction(KeepTargetFn)
    inst.components.combat:SetHurtSound(sounds.hurt)
    inst.components.combat.lastwasattackedtime = -math.huge -- brain reads GetLastAttackedTime before any hit

    inst:AddComponent("sanityaura")
    inst.components.sanityaura.aura = -TUNING.SANITYAURA_MED

    inst:AddComponent("lootdropper")
    inst.components.lootdropper:SetChanceLootTable('gauntlet_attacker')

    inst:AddComponent("inspectable")

    MakeMediumFreezableCharacter(inst, "hound_body")
    MakeMediumBurnableCharacter(inst, "hound_body")
    MakeHauntablePanic(inst)

    inst:ListenForEvent("attacked", OnAttacked)

    -- M2 naive-path load. Added always (master-only), but idle unless the naive
    -- flag is on. A freshly spawned attacker inherits the current flag, and a
    -- live c_naive() flip reaches every attacker already in the field through
    -- this TheWorld event.
    inst:AddComponent("gauntletnaiveload")
    local siegemanager = TheWorld.components.siegemanager
    inst.components.gauntletnaiveload:SetNaive(siegemanager ~= nil and siegemanager:IsNaive())
    inst:ListenForEvent("gauntlet_naivechanged", function(world, data)
        inst.components.gauntletnaiveload:SetNaive(data ~= nil and data.naive)
    end, TheWorld)

    return inst
end

return Prefab("gauntlet_attacker", fn, assets, prefabs)
