-- Gauntlet turret projectile — the ballistic AOE shot fired by gauntlet_turret.
--
-- A `complexprojectile` lob (the Winona-catapult model), NOT the eyeturret's
-- straight `projectile`. Chosen deliberately: complexprojectile's Hit calls ONLY
-- our onhitfn (no engine auto-damage), so the projectile's OWN combat resolves
-- the entire AOE in one place — no double-hit, and no risk of routing damage back
-- through the turret (which would relaunch projectiles in a cascade). The arc
-- also lobs over walls — the "shoot-through-wall" turret-pain fix.
--
-- The AOE uses the shared enemy policy (gauntlet_targeting): hostile/monster
-- mobs only, never player-side. The exclusion list is the "target-filter" fix —
-- the blast search can't return players, allies, the objective, or turrets, so
-- friendly fire is impossible even though it now damages any hostile.

local TARGETING = require("gauntlet_targeting")

local assets =
{
    Asset("ANIM", "anim/winona_catapult_projectile.zip"),
}

local AOE_RANGE_PADDING = 0.5

-- All damage runs through the projectile's own combat (no equipped weapon), so
-- DoAttack deals direct damage and never relaunches. Attribution is the
-- projectile itself.
local function DoAOEAttack(inst, x, z)
    inst.components.combat.ignorehitrange = true -- AOE: reach is the blast, gated by CalcHitRangeSq below
    local hit = false
    for _, v in ipairs(TheSim:FindEntities(x, 0, z, inst.AOE_RADIUS + AOE_RANGE_PADDING, TARGETING.ENEMY_MUST_TAGS, TARGETING.ENEMY_CANT_TAGS, TARGETING.ENEMY_ONEOF_TAGS)) do
        if v:IsValid()
            and v.entity:IsVisible()
            and v:GetDistanceSqToPoint(x, 0, z) < inst.components.combat:CalcHitRangeSq(v)
            and TARGETING.IsEnemy(inst, v)
        then
            inst.components.combat:DoAttack(v)
            hit = true
        end
    end
    inst.components.combat.ignorehitrange = false
    inst.SoundEmitter:PlaySound("dontstarve/common/together/catapult/rock_hit", nil, hit and .6 or .3)
end

local function OnHit(inst, attacker, target)
    local x, y, z = inst.Transform:GetWorldPosition()
    inst.Physics:Stop()
    inst.Physics:Teleport(x, 0, z)
    DoAOEAttack(inst, x, z)
    inst.AnimState:PlayAnimation("impact")
    inst:ListenForEvent("animover", inst.Remove)
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddPhysics()
    inst.entity:AddNetwork()

    -- Catapult-projectile physics: a light sphere that collides only with GROUND
    -- (not OBSTACLES), so the lob passes over walls (winona_catapult_projectile.lua:501-507).
    inst.Physics:SetMass(1)
    inst.Physics:SetFriction(0)
    inst.Physics:SetDamping(0)
    inst.Physics:SetRestitution(0)
    inst.Physics:SetCollisionGroup(COLLISION.ITEMS)
    inst.Physics:SetCollisionMask(COLLISION.GROUND)
    inst.Physics:SetSphere(.4)

    inst.Transform:SetSixFaced()

    inst.AnimState:SetBank("winona_catapult_projectile")
    inst.AnimState:SetBuild("winona_catapult_projectile")
    inst.AnimState:PlayAnimation("air_rock", true)
    inst.AnimState:SetMultColour(1, .82, .5, 1) -- amber, matching the turret recolor

    -- projectile tags declared pre-pristine for client-side optimization (mirrors
    -- winona_catapult_projectile).
    inst:AddTag("projectile")
    inst:AddTag("complexprojectile")
    inst:AddTag("NOCLICK")
    inst:AddTag("notarget")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.persists = false
    inst.AOE_RADIUS = TUNING.GAUNTLET_TURRET_AOE_RADIUS

    local complexprojectile = inst:AddComponent("complexprojectile")
    complexprojectile:SetGravity(-100)
    complexprojectile:SetLaunchOffset(Vector3(1.25, 3, 0))
    complexprojectile:SetHorizontalSpeedForDistance(TUNING.GAUNTLET_TURRET_RANGE, 35)
    complexprojectile:SetOnHit(OnHit)

    -- The projectile's own combat carries the AOE damage + the hit-range gate.
    inst:AddComponent("combat")
    inst.components.combat:SetDefaultDamage(TUNING.GAUNTLET_TURRET_DAMAGE)
    inst.components.combat:SetRange(inst.AOE_RADIUS)

    return inst
end

return Prefab("gauntlet_turret_projectile", fn, assets)
