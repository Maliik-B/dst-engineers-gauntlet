-- Shared Gauntlet constants. Required by both the siegemanager component
-- (server) and the objective prefab (server + client), so it must stay free
-- of any ismastersim-dependent code.

-- Siege phase enum. Replicated in a net_tinybyte ([0..7]) on the objective,
-- so this table must never exceed 8 values.
local PHASE =
{
    IDLE    = 0, -- no run in progress
    PREP    = 1, -- inter-wave countdown (includes the warning window)
    ACTIVE  = 2, -- wave spawning / fighting
    VICTORY = 3, -- objective survived all waves
    DEFEAT  = 4, -- objective destroyed
}

local PHASE_NAMES = {}
for k, v in pairs(PHASE) do
    PHASE_NAMES[v] = k
end

-- Minion command enum (the 3-verb vocabulary). Replicated in a net_tinybyte
-- ([0..7]) on the minion, set() only on change, so this table must never exceed
-- 8 values. DEFEND is the spawn default (hold the deploy spot).
local MINION_COMMAND =
{
    DEFEND = 0, -- hold a fixed point; engage attackers that come within range
    FOLLOW = 1, -- follow the owning player; engage attackers along the way
    FOCUS  = 2, -- attack one chosen attacker, then revert to DEFEND when it dies
}

local MINION_COMMAND_NAMES = {}
for k, v in pairs(MINION_COMMAND) do
    MINION_COMMAND_NAMES[v] = k
end

return {
    PHASE = PHASE,
    PHASE_NAMES = PHASE_NAMES,
    MINION_COMMAND = MINION_COMMAND,
    MINION_COMMAND_NAMES = MINION_COMMAND_NAMES,
}
