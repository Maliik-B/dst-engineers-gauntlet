-- Gauntlet attacker brain — moonbeastbrain structure, retargeted at the
-- Gauntlet objective. Priority order: panic > lost-objective cleanup >
-- chew blocking walls > fight engaging defenders (short chase) > leash to
-- the objective and attack it > regroup near it.
--
-- Damage to the objective goes through the combat channel (TryAttack ->
-- "doattack" -> SGhound attack state) so walls, defenders and the objective
-- all share one damage pipeline.

require "behaviours/chaseandattack"
require "behaviours/attackwall"
require "behaviours/leash"
require "behaviours/standstill"
local BrainCommon = require("brains/braincommon")

local AGGRO_TIME = 6   -- recently-hit attackers stay combat-minded this long
local RETURN_DIST = 15 -- idle regroup leash band around the objective
local BASE_DIST = 6

local GauntletAttackerBrain = Class(Brain, function(self, inst)
    Brain._ctor(self, inst)
    self._losttime = nil
end)

local function GetObjective(inst)
    return inst.components.entitytracker:GetEntity("gauntlet_objective")
end

local function GetObjectivePos(inst)
    local objective = GetObjective(inst)
    return objective ~= nil and objective:GetPosition() or nil
end

-- Teleported away, or the objective got removed: clean ourselves up rather
-- than haunting the world as a stray.
local function LostObjective(self)
    local objective = GetObjective(self.inst)
    if objective ~= nil and self.inst:IsNear(objective, TUNING.GAUNTLET_ATTACKER_LOST_DIST) then
        self._losttime = nil
        return false
    elseif self._losttime == nil then
        self._losttime = GetTime()
        return false
    end
    return GetTime() - self._losttime > TUNING.GAUNTLET_ATTACKER_LOST_TIME
end

local function ShouldSiege(inst)
    local objective = GetObjective(inst)
    return objective ~= nil
        and objective.components.health ~= nil
        and not objective.components.health:IsDead()
        and GetTime() - inst.components.combat:GetLastAttackedTime() > AGGRO_TIME
end

local function AttackObjective(inst)
    local objective = GetObjective(inst)
    if objective ~= nil then
        inst.components.combat:TryAttack(objective)
    end
end

function GauntletAttackerBrain:OnStart()
    local root = PriorityNode(
    {
        BrainCommon.PanicTrigger(self.inst),
        BrainCommon.ElectricFencePanicTrigger(self.inst),

        WhileNode(function() return LostObjective(self) end, "Lost Objective",
            ActionNode(function() self.inst.components.health:Kill() end)),

        -- Player walls in the way get chewed through instead of stalling
        -- pathing; cooldown reset keeps the siege swing from being gated.
        SequenceNode{
            AttackWall(self.inst),
            ActionNode(function() self.inst.components.combat:ResetCooldown() end),
        },

        -- Defenders who engage (set as combat target by the proximity-gated
        -- retarget or by retaliation): short chase so kiting can't pull the
        -- wave off the objective.
        ChaseAndAttack(self.inst, TUNING.GAUNTLET_ATTACKER_MAX_CHASE),

        WhileNode(function() return ShouldSiege(self.inst) end, "Siege",
            PriorityNode({
                Leash(self.inst, GetObjectivePos, TUNING.GAUNTLET_ATTACKER_SIEGE_DIST, TUNING.GAUNTLET_ATTACKER_SIEGE_DIST),
                ActionNode(function() AttackObjective(self.inst) end),
                StandStill(self.inst),
            })),

        Leash(self.inst, GetObjectivePos, RETURN_DIST, BASE_DIST),
        StandStill(self.inst),
    }, .25)

    self.bt = BT(self.inst, root)
end

return GauntletAttackerBrain
