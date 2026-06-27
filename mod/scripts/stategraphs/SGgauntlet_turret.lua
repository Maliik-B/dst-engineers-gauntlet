-- Gauntlet turret stategraph — the eyeturret/SGeyeturret shape (idle / attack /
-- hit / death) driving the Winona-catapult art, stripped of the catapult's
-- power, elemental and volley machinery. The combat component owns cadence; the
-- attack state just plays the throw anim and, at the release frame, calls
-- StartAttack() + DoAttack() so the equipped weapon launches the AOE projectile.

require("stategraphs/commonstates")

-- Catapult "atk" anim releases the rock around frame 21 (SGwinona_catapult);
-- fire on the same beat so the shot reads as leaving the arm.
local FIRE_FRAME = 20

local events =
{
    EventHandler("death", function(inst)
        inst.sg:GoToState("death")
    end),
    EventHandler("doattack", function(inst)
        if not inst.components.health:IsDead()
            and ((inst.sg:HasStateTag("hit") and not inst.sg:HasStateTag("electrocute")) or not inst.sg:HasStateTag("busy")) then
            inst.sg:GoToState("attack")
        end
    end),
    EventHandler("attacked", function(inst)
        if not inst.components.health:IsDead() and not inst.sg:HasAnyStateTag("attack", "busy") then
            inst.sg:GoToState("hit")
        end
    end),
}

local states =
{
    State{
        name = "idle",
        tags = { "idle", "canrotate" },
        onenter = function(inst)
            if not inst.AnimState:IsCurrentAnimation("idle") then
                inst.AnimState:PlayAnimation("idle", true)
            end
        end,
        events =
        {
            EventHandler("animover", function(inst) inst.sg:GoToState("idle") end),
        },
    },

    State{
        name = "attack",
        tags = { "attack", "busy" },
        onenter = function(inst)
            local target = inst.components.combat.target
            if target ~= nil and target:IsValid() then
                inst:ForceFacePoint(target.Transform:GetWorldPosition())
            end
            inst.AnimState:PlayAnimation("atk")
            inst.SoundEmitter:PlaySound("dontstarve/common/together/catapult/ratchet_LP", "attack_pre")
        end,
        timeline =
        {
            TimeEvent(FIRE_FRAME * FRAMES, function(inst)
                inst.components.combat:StartAttack() -- restart the attack-period cooldown
                local target = inst.components.combat.target
                if target ~= nil and target:IsValid() then
                    -- Manually lob the AOE projectile at the target (catapult model);
                    -- the projectile's own combat resolves the blast on impact.
                    local proj = SpawnPrefab("gauntlet_turret_projectile")
                    proj.Transform:SetPosition(inst.Transform:GetWorldPosition())
                    proj.components.complexprojectile:Launch(target:GetPosition(), inst, inst)
                end
                -- Re-voiced off the catapult: the shot uses the clockwork bishop's
                -- energy-bolt "shoot" so the engineer turret has its own signature
                -- (the mechanical ratchet windup above still reads as it aiming).
                inst.SoundEmitter:PlaySound("dontstarve/creatures/bishop/shoot")
            end),
        },
        events =
        {
            EventHandler("animover", function(inst) inst.sg:GoToState("idle") end),
        },
        onexit = function(inst)
            inst.SoundEmitter:KillSound("attack_pre")
        end,
    },

    State{
        name = "hit",
        tags = { "hit", "busy" },
        onenter = function(inst)
            inst.AnimState:PlayAnimation("hit")
            inst.SoundEmitter:PlaySound("dontstarve/common/together/catapult/hit")
        end,
        events =
        {
            EventHandler("animover", function(inst) inst.sg:GoToState("idle") end),
        },
    },

    State{
        name = "death",
        tags = { "death", "busy" },
        onenter = function(inst)
            inst:AddTag("NOCLICK")
            inst:AddTag("notarget")
            inst.AnimState:PlayAnimation("death")
            inst.SoundEmitter:PlaySound("dontstarve/common/together/catapult/destroy")
            RemovePhysicsColliders(inst)
            inst.sg:SetTimeout(2) -- fallback removal if "animover" doesn't fire
            -- No loot on combat-death: the hammer (workable) is the intentional
            -- refund path. A destroyed turret is simply lost — and removes itself
            -- after the death anim so it can't linger as rubble that still counts
            -- against the build cap (it keeps its tag while it exists).
        end,
        ontimeout = function(inst)
            inst:Remove()
        end,
        events =
        {
            EventHandler("animover", function(inst)
                inst:Remove()
            end),
        },
    },
}

return StateGraph("gauntlet_turret", states, events, "idle")
