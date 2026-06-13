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

return {
    PHASE = PHASE,
    PHASE_NAMES = PHASE_NAMES,
}
