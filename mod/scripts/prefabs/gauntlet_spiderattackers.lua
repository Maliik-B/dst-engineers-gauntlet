-- Gauntlet spider attackers — the M5 roster's two new types, built LEAN on the
-- spider art + SGspider, sharing our existing gauntletattackerbrain (objective
-- handoff via entitytracker, anti-kiting, siege the Engine). NOT clones of the
-- heavy befriendable spider prefab — just its art/SG + our siege AI, the same
-- way gauntlet_attacker is a lean retuned hound.
--
--   Breaker  — tanky, slow, hits hard; retargets the "gauntlet_defense" tag, so
--              it makes a beeline for turrets/minions and batters them. This is
--              what finally exercises the defense layer's HP + self-repair (the
--              survive-swarm pain the M4 scene couldn't show).
--   Swarmer  — fast, fragile chaff; retargets the defending player like the
--              Besieger. Numerous + weak: makes the turret AOE shine and gives
--              the minion's focus command a clear use.
--
-- Both still siege the Engine through the shared brain when they have no combat
-- target. The c_naive load A/B stays Besieger-only (via c_stress) for a clean
-- uniform measurement; these are gameplay variety, so they carry no load strawman.

local brain = require("brains/gauntletattackerbrain")

local assets =
{
    Asset("ANIM", "anim/ds_spider_basic.zip"),
    Asset("ANIM", "anim/ds_spider_warrior.zip"),
    Asset("ANIM", "anim/spider_warrior_build.zip"),
    Asset("ANIM", "anim/spider_build.zip"),
    Asset("SOUND", "sound/spider.fsb"),
}

local prefabs =
{
    "monstermeat",
    "silk",
}

SetSharedLootTable('gauntlet_spiderattacker',
{
    { 'monstermeat', 1.000 },
    { 'silk',        0.500 },
})

local SHARE_TARGET_DIST = 30

-- SGspider plays every sound through inst:SoundPath(event); provide it or the
-- core states crash (the same class of gotcha as SGknight's inst.kind).
local function SoundPath(inst, event)
    return "dontstarve/creatures/"
        .. (inst:HasTag("spider_warrior") and "spiderwarrior" or "spider")
        .. "/" .. event
end

local function IsNearObjective(inst, dist)
    local objective = inst.components.entitytracker:GetEntity("gauntlet_objective")
    return objective == nil or inst:IsNear(objective, dist)
end

-- Retarget is parameterized by what the type hunts: the Swarmer chases the
-- defending player (like the Besieger); the Breaker hunts the defense layer
-- (the shared "gauntlet_defense" tag on turret + minion). Both are gated to the
-- objective's vicinity so they can't be kited away from the siege.
local function MakeRetargetFn(must_tags, cant_tags)
    return function(inst)
        return IsNearObjective(inst, TUNING.GAUNTLET_ATTACKER_AGGRO_DIST)
            and FindEntity(
                inst,
                TUNING.GAUNTLET_ATTACKER_TARGET_DIST,
                function(guy) return inst.components.combat:CanTarget(guy) end,
                must_tags,
                cant_tags
            )
            or nil
    end
end

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

-- Per-type config drives the build/sound/stats/tint/target; everything else is
-- the shared lean attacker skeleton.
local function MakeSpiderAttacker(data)
    local function fn()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddSoundEmitter()
        inst.entity:AddDynamicShadow()
        inst.entity:AddNetwork()

        MakeCharacterPhysics(inst, 10, .5)

        inst.DynamicShadow:SetSize(1.5, .5)
        inst.Transform:SetFourFaced()

        inst:AddTag("monster")
        inst:AddTag("hostile")
        inst:AddTag("scarytoprey")
        inst:AddTag("spider")
        inst:AddTag("gauntlet_attacker")
        if data.warrior then
            inst:AddTag("spider_warrior") -- selects warrior sounds via SoundPath
        end

        inst.AnimState:SetBank("spider")
        inst.AnimState:SetBuild(data.build)
        inst.AnimState:PlayAnimation("idle")
        if data.scale ~= nil then
            inst.Transform:SetScale(data.scale, data.scale, data.scale)
        end
        -- Additive (not multiply): the spider art is dark, so a mult tint barely
        -- reads. Additive adds colour on top, so the type colour pops.
        inst.AnimState:SetAddColour(data.tint[1], data.tint[2], data.tint[3], 0)

        inst:AddComponent("spawnfader")

        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            return inst
        end

        inst.persists = false -- in-flight waves are not saved (the M1 arena rule)

        inst.SoundPath = SoundPath

        inst:AddComponent("locomotor") -- locomotor must be constructed before the stategraph
        inst.components.locomotor.runspeed = data.speed
        inst.components.locomotor.walkspeed = data.speed

        inst:SetStateGraph("SGspider")
        inst.sg.mem.nocorpse = true      -- skip the spider corpse pipeline
        inst.sg.mem.nolunarmutate = true -- and the lunar-mutation pipeline

        inst:SetBrain(brain)

        inst:AddComponent("entitytracker") -- holds the objective handoff (set at spawn)

        inst:AddComponent("health")
        inst.components.health:SetMaxHealth(data.health)

        inst:AddComponent("combat")
        inst.components.combat:SetDefaultDamage(data.damage)
        inst.components.combat:SetAttackPeriod(data.attackperiod)
        inst.components.combat:SetRange(data.attackrange)
        inst.components.combat:SetRetargetFunction(3, MakeRetargetFn(data.target_must_tags, data.target_cant_tags))
        inst.components.combat:SetKeepTargetFunction(KeepTargetFn)
        inst.components.combat.lastwasattackedtime = -math.huge -- brain reads GetLastAttackedTime before any hit

        inst:AddComponent("sanityaura")
        inst.components.sanityaura.aura = -TUNING.SANITYAURA_MED

        inst:AddComponent("lootdropper")
        inst.components.lootdropper:SetChanceLootTable('gauntlet_spiderattacker')

        inst:AddComponent("inspectable")

        MakeMediumFreezableCharacter(inst, "body")
        MakeMediumBurnableCharacter(inst, "body")
        MakeHauntablePanic(inst)

        inst:ListenForEvent("attacked", OnAttacked)

        return inst
    end

    return Prefab(data.name, fn, assets, prefabs)
end

-- Breaker: hunts the defense layer (gauntlet_defense = turret + minion). Tanky,
-- slow, big hits. Don't cant-tag "structure" — the turret IS one.
local BREAKER_MUST = { "gauntlet_defense" }
local BREAKER_CANT = { "INLIMBO", "flight", "invisible", "playerghost" }

-- Swarmer: chases the defending player, like the Besieger. Fast, fragile.
local SWARMER_MUST = { "player" }
local SWARMER_CANT = { "wall", "spider", "gauntlet_attacker", "structure", "INLIMBO" }

return MakeSpiderAttacker({
        name = "gauntlet_breaker",
        build = "spider_warrior_build",
        warrior = true,
        scale = 1.2,
        tint = { .45, 0, 0 }, -- additive angry red — the dangerous one
        health = TUNING.GAUNTLET_BREAKER_HEALTH,
        damage = TUNING.GAUNTLET_BREAKER_DAMAGE,
        attackperiod = TUNING.GAUNTLET_BREAKER_ATTACK_PERIOD,
        attackrange = TUNING.GAUNTLET_BREAKER_ATTACK_RANGE,
        speed = TUNING.GAUNTLET_BREAKER_SPEED,
        target_must_tags = BREAKER_MUST,
        target_cant_tags = BREAKER_CANT,
    }),
    MakeSpiderAttacker({
        name = "gauntlet_swarmer",
        build = "spider_build",
        scale = .7,
        tint = { .08, .12, .3 }, -- additive cold pale — distinct from green Besieger / red Breaker
        health = TUNING.GAUNTLET_SWARMER_HEALTH,
        damage = TUNING.GAUNTLET_SWARMER_DAMAGE,
        attackperiod = TUNING.GAUNTLET_SWARMER_ATTACK_PERIOD,
        attackrange = TUNING.GAUNTLET_SWARMER_ATTACK_RANGE,
        speed = TUNING.GAUNTLET_SWARMER_SPEED,
        target_must_tags = SWARMER_MUST,
        target_cant_tags = SWARMER_CANT,
    })
