-- Gauntlet Sentry — the buildable auto-turret, character-agnostic.
--
-- Built on the eyeturret / Houndius-Shootius pattern (the shipped "any character
-- can craft an auto-turret" precedent): health + self-repair regen, a combat
-- component owning targeting + cadence, a StandAndAttack brain, an equipped
-- weapon that launches a projectile. NO power/circuit (the Winona-catapult's
-- battery is character-locked and an economy lever; v1 balances with a build-cap
-- + recipe cost instead — see modmain). Driven by the Winona-catapult ART
-- (recolored amber) for the engineer/mechanical read.
--
-- The three documented turret pains, fixed by construction:
--   * target-filter   — retarget + the projectile AOE use the shared enemy
--                        policy (gauntlet_targeting): hostile/monster mobs only,
--                        excluding all player-side (players, companions,
--                        structures) — so it fights anything hostile yet can
--                        never hit players, allies, the objective or turrets.
--   * shoot-through-wall — the projectile is a `projectile`-component shot that
--                        ignores terrain, so it clears walls (see the projectile).
--   * survive-swarm   — health + regen lets it tank the aggro it draws; the
--                        build-cap keeps it from trivializing a wave.
--
-- Sleep-correct for free: the combat component stops its retarget task on entity
-- sleep and the brain/SG are torn down by the engine (M3 baseline discipline).

require("prefabutil")

local assets =
{
    Asset("ANIM", "anim/winona_catapult.zip"),
    Asset("ANIM", "anim/winona_catapult_placement.zip"), -- the range ring drawn on the placer
}

local prefabs =
{
    "gauntlet_turret_projectile",
    "collapse_small",
}

local brain = require("brains/gauntletturretbrain")
local TARGETING = require("gauntlet_targeting")

--------------------------------------------------------------------------
-- Target acquisition — the shared enemy policy: hostile/monster mobs, never
-- player-side (gauntlet_targeting). The exclusion list is what keeps the turret
-- from ever acquiring a player, ally, or structure.
--------------------------------------------------------------------------

local function RetargetFn(inst)
    return FindEntity(
        inst,
        TUNING.GAUNTLET_TURRET_RANGE,
        function(guy) return TARGETING.IsEnemy(inst, guy) end,
        TARGETING.ENEMY_MUST_TAGS,
        TARGETING.ENEMY_CANT_TAGS,
        TARGETING.ENEMY_ONEOF_TAGS
    )
end

local function KeepTargetFn(inst, target)
    return inst.components.combat:CanTarget(target)
        and inst:IsNear(target, TUNING.GAUNTLET_TURRET_RANGE + 3)
end

-- Don't shoot players (except in PVP); everything else hostile is fair game.
-- The retarget filter already excludes player-side, so this is the PVP guard.
local function ShouldAggroFn(combat, target)
    if target:HasTag("player") then
        return TheNet:GetPVPEnabled()
    end
    return true
end

local function OnAttacked(inst, data)
    local attacker = data ~= nil and data.attacker or nil
    if attacker ~= nil and TARGETING.IsEnemy(inst, attacker) then
        inst.components.combat:SetTarget(attacker)
    end
end

--------------------------------------------------------------------------
-- Firing is handled in the stategraph attack state: it manually spawns and
-- Launches a complexprojectile toward the target (the Winona-catapult model),
-- NOT an equipped ranged weapon. This keeps all damage on the projectile's own
-- combat and avoids relaunch cascades. Cadence is the combat attack-period
-- cooldown (StartAttack in the SG), driven by the StandAndAttack brain.
--------------------------------------------------------------------------

--------------------------------------------------------------------------
-- Health: self-repair regen, started when damaged and stopped at full so no
-- perpetual task lingers off-screen (the Winona-catapult idiom, M3-friendly).
--------------------------------------------------------------------------

local function OnHealthDelta(inst)
    local health = inst.components.health
    if health:IsDead() then
        return
    end
    -- Wear feedback: the catapult art has no damage tiers, so shift the amber
    -- tint smoothly toward red as HP drops (and back as it self-repairs) by
    -- fading the green/blue channels — a continuous gradient (not additive red,
    -- which barely reads at high HP), so the damage level is legible at a glance.
    local hurt = 1 - health:GetPercent()
    inst.AnimState:SetMultColour(1, .82 - .72 * hurt, .5 - .42 * hurt, 1)
    if health:GetPercent() >= 1 then
        health:StopRegen()
    else
        health:StartRegen(TUNING.GAUNTLET_TURRET_REGEN, TUNING.GAUNTLET_TURRET_REGEN_PERIOD)
    end
end

-- Deploy feedback: the shipped catapult plays its "place" sound the moment it's
-- built (SGwinona_catapult onenter of its place state). We build via a placer
-- recipe, so the engine fires an "onbuilt" event on the finished structure — we
-- hang the same catapult place sound off it so the turret doesn't appear silently.
local function OnBuilt(inst)
    inst.SoundEmitter:PlaySound("dontstarve/common/together/catapult/place")
end

-- Hammer = the intentional dismantle + refund (lootdropper drops the recipe
-- ingredients by default). Combat-death drops nothing (handled in the SG).
local function OnHammered(inst)
    local fx = SpawnPrefab("collapse_small")
    fx.Transform:SetPosition(inst.Transform:GetWorldPosition())
    fx:SetMaterial("stone")
    inst.components.lootdropper:DropLoot()
    inst:Remove()
end

-- Examine condition: server-side getstatus by HP% (the describe table keys off
-- it). Full or dead -> nil, so full reads GENERIC and death falls to the
-- inspectable component's own "DEAD" status.
local function GetTurretStatus(inst)
    local pct = inst.components.health:GetPercent()
    if pct <= 0 or pct >= 1 then
        return nil
    elseif pct <= .33 then
        return "CRITICAL"
    end
    return "DAMAGED"
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()
    inst.entity:AddMiniMapEntity()
    inst.MiniMapEntity:SetIcon("winona_catapult.png") -- map parity: reuse the shipped catapult icon (matches the art on screen)

    MakeObstaclePhysics(inst, .5)
    inst.Physics:SetDontRemoveOnSleep(true)

    -- Six-faced: the winona_catapult art is authored for six directional facings
    -- (winona_catapult.lua:1024). SetFourFaced leaves some camera angles with no
    -- frame to draw, so the turret vanishes across half the camera rotations.
    inst.Transform:SetSixFaced()

    inst.AnimState:SetBank("winona_catapult")
    inst.AnimState:SetBuild("winona_catapult")
    inst.AnimState:PlayAnimation("idle", true)
    inst.AnimState:SetMultColour(1, .82, .5, 1) -- amber recolor of the catapult art

    inst:AddTag("structure")
    inst:AddTag("companion")    -- player-side ally for combat ally checks
    inst:AddTag("noauradamage")
    inst:AddTag("gauntlet_turret")
    inst:AddTag("gauntlet_defense") -- what the M5 Breaker attacker hunts

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inspectable")
    inst.components.inspectable.getstatus = GetTurretStatus

    inst:AddComponent("health")
    inst.components.health:SetMaxHealth(TUNING.GAUNTLET_TURRET_HEALTH)
    inst.components.health.nofadeout = true

    inst:AddComponent("combat")
    inst.components.combat:SetRange(TUNING.GAUNTLET_TURRET_RANGE)
    inst.components.combat:SetDefaultDamage(TUNING.GAUNTLET_TURRET_DAMAGE)
    inst.components.combat:SetAttackPeriod(TUNING.GAUNTLET_TURRET_ATTACK_PERIOD)
    inst.components.combat:SetRetargetFunction(1, RetargetFn)
    inst.components.combat:SetKeepTargetFunction(KeepTargetFn)
    inst.components.combat:SetShouldAggroFn(ShouldAggroFn)

    inst:AddComponent("lootdropper") -- droprecipeloot stays true: hammer refunds the recipe

    inst:AddComponent("workable")
    inst.components.workable:SetWorkAction(ACTIONS.HAMMER)
    inst.components.workable:SetWorkLeft(TUNING.GAUNTLET_TURRET_WORK)
    inst.components.workable:SetOnFinishCallback(OnHammered)

    inst:AddComponent("sanityaura")
    inst.components.sanityaura.aura = -TUNING.SANITYAURA_TINY

    inst:ListenForEvent("healthdelta", OnHealthDelta)
    inst:ListenForEvent("attacked", OnAttacked)
    inst:ListenForEvent("onbuilt", OnBuilt) -- play the place sound when a player builds one

    inst:SetStateGraph("SGgauntlet_turret")
    inst:SetBrain(brain)

    return inst
end

-- Range affordance (Klei parity — the Winona-catapult placer ring): a ground
-- circle showing the turret's attack radius while you place it. Reuses the
-- catapult's "idle_15" ring art (10u radius at scale 1, 15u at the catapult's
-- 1.5), rescaled to our range so it adapts if the range is retuned.
local function CreateRangeRing()
    local inst = CreateEntity()
    inst.entity:SetCanSleep(false)
    inst.persists = false

    inst.entity:AddTransform()
    inst.entity:AddAnimState()

    inst:AddTag("CLASSIFIED")
    inst:AddTag("NOCLICK")
    inst:AddTag("placer")

    inst.AnimState:SetBank("winona_catapult_placement")
    inst.AnimState:SetBuild("winona_catapult_placement")
    inst.AnimState:PlayAnimation("idle_15")
    inst.AnimState:SetAddColour(0, .35, .15, 0) -- soft green "coverage" tint
    inst.AnimState:SetLightOverride(1)
    inst.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)
    inst.AnimState:SetLayer(LAYER_BACKGROUND)
    inst.AnimState:SetSortOrder(1)

    local s = TUNING.GAUNTLET_TURRET_RANGE / 10
    inst.AnimState:SetScale(s, s)

    return inst
end

local function PlacerPostInit(inst)
    inst.AnimState:SetMultColour(1, .82, .5, 1) -- ghost matches the amber turret
    CreateRangeRing().entity:SetParent(inst.entity)
end

-- Placer ghost: match the shipped catapult placer — the "idle_placer" anim with
-- two-faced setup (winona_catapult.lua:1198-1202), not the directional "idle".
return Prefab("gauntlet_turret", fn, assets, prefabs),
    MakePlacer("gauntlet_turret_placer", "winona_catapult", "winona_catapult", "idle_placer",
        nil, nil, nil, nil, nil, "two", PlacerPostInit)
