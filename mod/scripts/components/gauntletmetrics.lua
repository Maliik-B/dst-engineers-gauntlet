--------------------------------------------------------------------------
-- gauntletmetrics — master-sim world component, the measurement layer for the
-- naive-vs-optimized demonstration. Console readout for M2 (c_metrics); the
-- same numbers feed the on-screen HUD in M5.
--
-- MSPT: GetTimeReal() is real wall-clock ms (TheSim:GetRealTime). The world
-- never sleeps, so this component's OnUpdate runs once per sim tick and the
-- delta between consecutive calls is the true wall-clock tick interval. A
-- healthy server is pinned at the 30fps cap (~33.3ms); when the sim can't
-- finish a tick in time the interval climbs -- real tick slippage / FPS drop,
-- the honest "naive melts" signal. (It measures the whole frame, not just the
-- Lua update -- that's the number a player actually feels.)
--
-- num_updating_ents is the engine's live updating-entity counter (a Lua
-- global, main.lua:301). netvar churn and spawn-RPC totals are fed by the
-- naive load component and the spawn path respectively.
--------------------------------------------------------------------------

local EMA_K = 0.1          -- MSPT smoothing factor (~0.3s settle at 30fps)
local WINDOW_MS = 1000     -- rate-sampling window for churn/peak

return Class(function(self, inst)
    assert(TheWorld.ismastersim, "gauntletmetrics is master-sim only")
    self.inst = inst

    local _lastreal = nil
    local _msptema = nil
    local _peakwindow = 0   -- worst tick (ms) accumulating in the live window
    local _msptpeak = 0     -- worst tick (ms) over the last completed window

    local _dirtytotal = 0   -- cumulative netvar replication events
    local _spawnrpctotal = 0
    local _dirtypersec = 0

    local _windowstart = nil
    local _windowdirtybase = 0

    -- Fed by the naive load component (one call per real net_float change).
    function self:CountNetvarDirty()
        _dirtytotal = _dirtytotal + 1
    end

    -- Fed by the spawn path (one call per per-spawn RPC sent in naive mode).
    function self:CountSpawnRPC()
        _spawnrpctotal = _spawnrpctotal + 1
    end

    -- c_metrics_reset(): zero the counters for a clean A/B measurement.
    function self:ResetCounters()
        _dirtytotal = 0
        _spawnrpctotal = 0
        _dirtypersec = 0
        _windowdirtybase = 0
        _msptpeak = 0
        _peakwindow = 0
    end

    function self:OnUpdate(dt)
        local now = GetTimeReal()
        if _lastreal ~= nil then
            local interval = now - _lastreal
            _msptema = (_msptema == nil) and interval or (_msptema + EMA_K * (interval - _msptema))
            if interval > _peakwindow then
                _peakwindow = interval
            end
        end
        _lastreal = now

        if _windowstart == nil then
            _windowstart = now
        end
        local elapsed = now - _windowstart
        if elapsed >= WINDOW_MS then
            _dirtypersec = (_dirtytotal - _windowdirtybase) * 1000 / elapsed
            _windowdirtybase = _dirtytotal
            _msptpeak = _peakwindow
            _peakwindow = 0
            _windowstart = now
        end
    end

    function self:GetReadout()
        local siegemanager = TheWorld.components.siegemanager
        local naive = siegemanager ~= nil and siegemanager:IsNaive() or false
        local mspt = _msptema or 0
        local fps = (mspt > 0) and (1000 / mspt) or 0
        return string.format(
            "MSPT %.1fms (%.0f fps | peak %.1fms) | updating_ents=%d | netvar churn=%.0f/s | spawn RPCs=%d | naive=%s",
            mspt, fps, _msptpeak,
            num_updating_ents or 0,
            _dirtypersec,
            _spawnrpctotal,
            naive and "ON" or "off")
    end

    -- One world component sampling once per tick: a diagnostic, not the thing
    -- under test. The world never sleeps, so this gives a stable MSPT clock.
    inst:StartUpdatingComponent(self)
end)
