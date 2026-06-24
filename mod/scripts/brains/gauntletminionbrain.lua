-- Gauntlet minion brain — the commandable defender. A single ChaseAndAttack
-- drives combat in every mode (the combat retarget/keep-target decides WHAT is a
-- valid target per command; see the prefab), and the mode selects the idle
-- movement node: Follow the owner, or Leash to a defend point. FOCUS just forces
-- a combat target, so it falls through to the same ChaseAndAttack.
--
-- Server-authoritative: this brain only runs on the master sim (engine tears it
-- down on entity sleep — the M3 baseline discipline, no manual sleep handling).

require("behaviours/chaseandattack")
require("behaviours/leash")
require("behaviours/follow")
require("behaviours/standstill")
local BrainCommon = require("brains/braincommon")

local CMD = require("gauntlet_constants").MINION_COMMAND

local GauntletMinionBrain = Class(Brain, function(self, inst)
    Brain._ctor(self, inst)
end)

local function GetDefendPos(inst)
    return inst:GetMinionDefendPos()
end

local function GetLeader(inst)
    return inst.components.follower:GetLeader()
end

function GauntletMinionBrain:OnStart()
    local inst = self.inst

    local root = PriorityNode(
    {
        BrainCommon.PanicTrigger(inst),

        -- Combat in every mode. The combat component's retarget acquires nearby
        -- attackers (or holds the FOCUS target); keep-target enforces the
        -- anti-kiting leash back to the active anchor. Finite chase so a fleeing
        -- attacker can't drag the minion off its post.
        ChaseAndAttack(inst, TUNING.GAUNTLET_MINION_MAX_CHASE),

        -- FOLLOW: stay in a loose band around the owning player.
        WhileNode(function() return inst:GetMinionCommand() == CMD.FOLLOW end, "Follow",
            Follow(inst, function() return GetLeader(inst) end,
                TUNING.GAUNTLET_MINION_FOLLOW_MIN,
                TUNING.GAUNTLET_MINION_FOLLOW_TARGET,
                TUNING.GAUNTLET_MINION_FOLLOW_MAX)),

        -- DEFEND: hold the assigned point (FOCUS also falls here once its target
        -- dies and the prefab reverts the mode to DEFEND).
        WhileNode(function() return inst:GetMinionCommand() ~= CMD.FOLLOW end, "Defend",
            Leash(inst, function() return GetDefendPos(inst) end,
                TUNING.GAUNTLET_MINION_DEFEND_LEASH,
                TUNING.GAUNTLET_MINION_DEFEND_RETURN)),

        StandStill(inst),
    }, .25)

    self.bt = BT(inst, root)
end

return GauntletMinionBrain
