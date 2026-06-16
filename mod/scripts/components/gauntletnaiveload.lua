--------------------------------------------------------------------------
-- gauntletnaiveload — the M2 strawman, one instance per attacker.
--
-- This is the DELIBERATELY-NAIVE per-entity cost the M3 optimization pass
-- exists to remove. While the global naive flag is on (c_naive(true)), every
-- attacker runs this component every tick and:
--
--   (1) never self-stops when the entity sleeps -- there is intentionally no
--       OnEntitySleep/OnEntityWake handling -- so num_updating_ents stays
--       pegged at the full swarm size even when the horde is far off-screen.
--       (Optimized: stop updating on sleep, resume on wake -> an off-screen
--       horde costs ~0; components do NOT auto-stop on sleep, so this is a
--       real and common mistake -- combat.lua self-stops for exactly this.)
--   (2) runs an unthrottled all-neighbours proximity scan every tick -- O(k)
--       per attacker, O(N*k) across a dense swarm -- standing in for the naive
--       "re-decide everything each frame" AI. (Optimized: the engine throttles
--       retargeting via SetRetargetFunction's period, and only while awake.)
--   (3) re-set()s a net_float every tick (here: distance to the nearest
--       neighbour), continuous replication churn out to every client.
--       (Optimized: drop it -- the engine already replicates transforms -- or
--       quantize and diff a net_byte so set() only dirties on a real change.)
--
-- The per-spawn RPC tax (one SendModRPCToClient per attacker) lives in the
-- spawn path (siegemanager), not here. Off by default: when naive is off the
-- component is simply not in the update set, so the optimized baseline is
-- exactly the M1 attacker.
--------------------------------------------------------------------------

local SCAN_MUST = { "gauntlet_attacker" }
local SCAN_CANT = { "INLIMBO" }

return Class(function(self, inst)
    self.inst = inst

    local _naive = false
    local _lastsync = nil
    local _metrics = nil

    function self:IsNaive()
        return _naive
    end

    function self:SetNaive(enable)
        enable = enable and true or false
        if enable == _naive then
            return
        end
        _naive = enable
        if enable then
            _metrics = TheWorld.components.gauntletmetrics
            inst:StartUpdatingComponent(self)
        else
            inst:StopUpdatingComponent(self)
            _lastsync = nil
        end
    end

    function self:OnUpdate(dt)
        -- NB: deliberately no inst:IsAsleep() guard -- see file header (tax #1).
        local x, y, z = inst.Transform:GetWorldPosition()

        -- Tax #2: unthrottled per-tick neighbour scan.
        local nearestsq = nil
        local ents = TheSim:FindEntities(x, y, z, TUNING.GAUNTLET_NAIVE_SCAN_RADIUS, SCAN_MUST, SCAN_CANT)
        for _, ent in ipairs(ents) do
            if ent ~= inst then
                local ex, ey, ez = ent.Transform:GetWorldPosition()
                local dx, dz = ex - x, ez - z
                local dsq = dx * dx + dz * dz
                if nearestsq == nil or dsq < nearestsq then
                    nearestsq = dsq
                end
            end
        end

        -- Tax #3: re-set() a net_float every tick. We mirror the engine's
        -- "only replicates on real change" rule (netvars.lua) to count honest
        -- replication events, then set() unconditionally -- the naive sin.
        local sync = (nearestsq ~= nil) and math.sqrt(nearestsq) or TUNING.GAUNTLET_NAIVE_SCAN_RADIUS
        if _lastsync ~= sync then
            _lastsync = sync
            if _metrics ~= nil then
                _metrics:CountNetvarDirty()
            end
        end
        inst._naivesync:set(sync)
    end
end)
