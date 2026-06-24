-- Gauntlet turret brain — the Winona-catapult / eyeturret idiom: a fixed
-- defender whose entire brain is StandAndAttack. Target acquisition and attack
-- cadence live in the combat component (retarget fn + attack-period cooldown);
-- the brain just validates the target, faces it, and calls TryAttack each visit.
--
-- Sleep discipline (M3 baseline): the combat component cancels its retarget task
-- on entity sleep and the brain/stategraph are torn down by the engine, so the
-- turret costs nothing off-screen with no manual sleep-stop code.

require("behaviours/standandattack")

local GauntletTurretBrain = Class(Brain, function(self, inst)
    Brain._ctor(self, inst)
end)

function GauntletTurretBrain:OnStart()
    local root = PriorityNode(
    {
        StandAndAttack(self.inst),
    }, 0.1)

    self.bt = BT(self.inst, root)
end

return GauntletTurretBrain
