--------------------------------------------------------------------------
-- gauntletload — per-attacker load path, one instance on every attacker. This
-- is the controlled experiment at the heart of the centerpiece: the SAME
-- representative per-entity work (a local neighbour-density scan) run two ways,
-- switched live by the global c_naive flag on identical load -- same scene, one
-- flag.
--
-- The work models the common mistake of doing per-entity AI bookkeeping in a
-- component OnUpdate. Computing a local density server-side is legitimate; the
-- naive sins are HOW it's done. The scan caches its result on the instance
-- (inst._swarmnearest) -- server-side AI bookkeeping a swarm brain could read.
--
-- NAIVE (c_naive true) -- the three deliberately-unoptimized taxes:
--   (1) never self-stops on sleep -- there is intentionally no OnEntitySleep
--       guard while naive -- so the component keeps updating off-screen and
--       num_updating_ents stays pegged at the full swarm size. (Components are
--       NOT auto-stopped by entity sleep; the update loop has no asleep filter
--       -- update.lua:256-268. This is a real, common mistake.)
--   (2) runs the full neighbour scan EVERY tick -- O(k) per attacker, O(N*k)
--       across a dense swarm.
--   (3) re-set()s a per-attacker net_float every tick: continuous replication
--       churn out to every client.
--
-- OPTIMIZED (c_naive false) -- the same work under three shipped disciplines:
--   (1) self-stops on "entitysleep" and resumes on "entitywake"
--       (Combat:OnEntitySleep/OnUpdate self-stop, combat.lua:289-323) -> an
--       off-screen horde drops out of the update set (num_updating_ents
--       collapses ~336 -> ~36).
--   (2) the scan is THROTTLED to a period with a random phase (the cadence
--       Combat:SetRetargetFunction gives its retarget task, combat.lua:275-287)
--       -> a fraction of the per-tick compute.
--   (3) the net_float is recognized as REDUNDANT -- the engine already
--       replicates transforms, so clients can derive proximity -- and is simply
--       never written -> zero swarm replication churn. The one value clients
--       genuinely need (objective HP) is replicated correctly on the objective
--       prefab instead (quantized net_byte, diffed on real change).
--
-- The per-spawn RPC tax lives in the spawn path (siegemanager), not here.
--------------------------------------------------------------------------

local SCAN_MUST = { "gauntlet_attacker" }
local SCAN_CANT = { "INLIMBO" }

return Class(function(self, inst)
    self.inst = inst

    local _naive = false
    local _started = false      -- has the initial lifecycle been applied?
    local _updating = false     -- are we currently in the update set?
    local _lastsync = nil        -- last net_float value (naive churn accounting)
    local _sincescan = 0         -- optimized throttle accumulator
    local _metrics = nil

    local function Metrics()
        if _metrics == nil then
            _metrics = TheWorld.components.gauntletmetrics
        end
        return _metrics
    end

    -- Guarded update-set toggle. Mirrors siegemanager's SetUpdating: keeps the
    -- num_updating_ents bookkeeping honest and avoids redundant engine churn.
    local function SetUpdating(on)
        if on ~= _updating then
            _updating = on
            if on then
                inst:StartUpdatingComponent(self)
            else
                inst:StopUpdatingComponent(self)
            end
        end
    end

    -- Apply the update-set lifecycle for the current mode:
    --   naive     -> always updating (the sin is precisely that it does NOT
    --                stop when the entity sleeps).
    --   optimized -> updating only while awake; OnEntitySleep stops it.
    local function ApplyUpdating()
        if _naive then
            SetUpdating(true)
        else
            SetUpdating(not inst:IsAsleep())
        end
    end

    -- The representative per-entity work both paths share. Returns the number
    -- of candidates examined (the resolution-independent compute proxy).
    local function Scan()
        local x, y, z = inst.Transform:GetWorldPosition()
        local ents = TheSim:FindEntities(x, y, z, TUNING.GAUNTLET_LOAD_SCAN_RADIUS, SCAN_MUST, SCAN_CANT)
        local nearestsq = nil
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
        -- Server-side AI bookkeeping. The naive path's mistake was replicating
        -- this, not computing it.
        inst._swarmnearest = (nearestsq ~= nil) and math.sqrt(nearestsq) or TUNING.GAUNTLET_LOAD_SCAN_RADIUS
        return #ents
    end

    function self:IsNaive()
        return _naive
    end

    function self:SetNaive(enable)
        enable = enable and true or false
        if _started and enable == _naive then
            return
        end
        _naive = enable
        _started = true
        _lastsync = nil
        -- Random phase so a freshly-flipped swarm doesn't scan in lockstep on
        -- the same tick (combat's period*random() retarget phasing).
        _sincescan = math.random() * TUNING.GAUNTLET_LOAD_SCAN_PERIOD
        ApplyUpdating()
    end

    -- Optimized: drop out of the update set when the engine puts us to sleep.
    -- Naive: deliberately do NOT stop -- keep grinding off-screen (tax #1).
    function self:OnEntitySleep()
        if not _naive then
            SetUpdating(false)
        end
    end

    -- Both modes (re)enter the update set on wake; the optimized path was
    -- self-stopped, the naive path never left.
    function self:OnEntityWake()
        ApplyUpdating()
    end

    function self:OnUpdate(dt)
        local t0 = os.clock()
        local examined = 0

        if _naive then
            -- Tax #2: full scan every tick.
            examined = Scan()
            -- Tax #3: re-set() the net_float every tick. We count an honest
            -- replication event only on real change (the engine's set() rule),
            -- then set() unconditionally -- the naive sin.
            local sync = inst._swarmnearest
            if _lastsync ~= sync then
                _lastsync = sync
                local m = Metrics()
                if m ~= nil then
                    m:CountNetvarDirty()
                end
            end
            inst._naivesync:set(sync)
        else
            -- Optimized: throttle the scan to a period (combat retarget cadence).
            _sincescan = _sincescan + dt
            if _sincescan >= TUNING.GAUNTLET_LOAD_SCAN_PERIOD then
                _sincescan = _sincescan - TUNING.GAUNTLET_LOAD_SCAN_PERIOD
                examined = Scan()
                -- No set(): the redundant net_float stays unwritten. Clients
                -- derive proximity from the transforms the engine replicates.
            end
        end

        local m = Metrics()
        if m ~= nil then
            -- Bracket the actual compute (os.clock); examined feeds scan-ops.
            m:CountCompute(os.clock() - t0, examined)
        end
    end
end)
