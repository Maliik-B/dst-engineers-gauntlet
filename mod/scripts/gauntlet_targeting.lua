-- Shared enemy-targeting policy for the whole defense layer: the turret's
-- retarget, the turret projectile's AOE, and the minion's retarget/keep/focus.
-- ONE definition so the three can never drift apart.
--
-- A valid enemy is a combat-capable entity that is an actual threat
-- (monster/hostile) and is NOT player-side. The exclusion list is what makes
-- friendly fire impossible by construction: players, companions (turrets,
-- minions, pets), and structures (the Engine, walls) can never be returned by
-- the search, so a defender literally cannot acquire one. The IsAlly check is
-- belt-and-braces on top (PVP / shared-leader cases).
--
-- Required by gauntlet_turret, gauntlet_turret_projectile and gauntlet_minion
-- (server-side use only — each caller owns a combat component).

local ENEMY_MUST_TAGS = { "_combat" }              -- must be targetable at all
local ENEMY_ONEOF_TAGS = { "monster", "hostile" }  -- ...and an actual threat (not a neutral beefalo)
local ENEMY_CANT_TAGS =
{
    "INLIMBO", "flight", "invisible", "playerghost", "notarget",
    "player",     -- never the players
    "companion",  -- never turrets / minions / pets (all player-side allies carry this)
    "structure",  -- never the Engine, turrets, walls
    "wall",
}

-- Is `guy` a valid enemy for the player-side defender `inst`?
local function IsEnemy(inst, guy)
    return inst.components.combat:CanTarget(guy)
        and not inst.components.combat:IsAlly(guy)
end

return {
    ENEMY_MUST_TAGS = ENEMY_MUST_TAGS,
    ENEMY_ONEOF_TAGS = ENEMY_ONEOF_TAGS,
    ENEMY_CANT_TAGS = ENEMY_CANT_TAGS,
    IsEnemy = IsEnemy,
}
