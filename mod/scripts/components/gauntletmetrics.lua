--------------------------------------------------------------------------
-- gauntletmetrics — master-sim world component, the measurement layer for the
-- naive-vs-optimized demonstration. Console readout for M3 (c_metrics); the
-- same numbers feed the on-screen HUD in M5.
--
-- The numbers, leading with the trustworthy ones:
--
--   compute (ms/tick) — the FIX FIRST from M2. The M2 MSPT read the wall-clock
--     interval BETWEEN ticks (GetTimeReal deltas), which the dedicated server's
--     variable frame pacing confounds: idle it throttles to ~30fps, lightly
--     loaded it free-runs uncapped at 80-199fps, so the "fps" swung on pacing,
--     not on work. M3 instead BRACKETS the actual per-entity work: each
--     gauntletload:OnUpdate wraps itself in os.clock() and reports the elapsed
--     to CountCompute. We accumulate that over a 1s window and divide by the
--     ticks in the window -> honest compute-ms/tick. os.clock() on this server
--     is ~1ms-resolution, so a single sub-ms scan often brackets to 0; but the
--     quantization is UNBIASED (a scan straddles a clock edge with probability
--     proportional to its true length), so the windowed sum over thousands of
--     calls converges to the true total. This is the number that actually moves
--     with load, and it isn't confounded by pacing.
--
--   scan-ops (/s) — exact integer count of neighbour candidates examined by the
--     load scans. Resolution-independent, unimpeachable; the cross-check that
--     backs the compute-ms. Leads the writeup alongside updating_ents.
--
--   num_updating_ents — the engine's live updating-entity counter (a Lua
--     global, main.lua:301). The off-screen A/B: a naive horde never self-stops
--     so it stays pegged here; the optimized horde drops out on sleep.
--
--   netvar churn (/s) and spawn RPCs — exact counts fed by the load component
--     (net_float dirties), the objective (HP-bucket dirties) and the spawn path
--     (per-spawn vs batched RPC sends).
--
--   frame (ms / ~fps) — the OLD inter-tick wall-clock interval, kept but demoted
--     to observational. It still answers one honest question: if it climbs over
--     ~33ms the server is genuinely below 30fps (a real melt). Below that it's
--     pacing noise -- don't read fps off it.
--------------------------------------------------------------------------

local EMA_K = 0.1          -- frame-interval smoothing factor (~0.3s settle at 30fps)
local WINDOW_MS = 1000     -- rate-sampling window for churn / scan-ops / compute / peak

return Class(function(self, inst)
    assert(TheWorld.ismastersim, "gauntletmetrics is master-sim only")
    self.inst = inst

    -- Bracketed compute (the trustworthy signal). Cumulative seconds spent in
    -- gauntletload work + the tick count, both sampled at window boundaries.
    local _computetotal = 0    -- cumulative os.clock() seconds bracketed in load updates
    local _ticks = 0           -- cumulative sim ticks this component has seen
    local _windowcomputebase = 0
    local _windowtickbase = 0
    local _computemspertick = 0

    -- Exact operation counts.
    local _scanopstotal = 0
    local _dirtytotal = 0      -- cumulative netvar replication events (load float + objective HP)
    local _spawnrpctotal = 0
    local _scanopspersec = 0
    local _dirtypersec = 0

    -- Observational inter-tick wall clock (pacing-confounded; see header).
    local _lastreal = nil
    local _frameema = nil

    local _windowstart = nil
    local _windowdirtybase = 0
    local _windowscanbase = 0

    -- Fed by the load component, once per attacker per tick: the os.clock()
    -- elapsed bracketed around its work, plus the neighbour candidates examined.
    function self:CountCompute(seconds, ops)
        _computetotal = _computetotal + (seconds or 0)
        _scanopstotal = _scanopstotal + (ops or 0)
    end

    -- Fed by the load component (net_float change) and the objective (HP-bucket
    -- change): one call per genuine replication event.
    function self:CountNetvarDirty()
        _dirtytotal = _dirtytotal + 1
    end

    -- Fed by the spawn path: one per RPC actually sent (naive = per spawn,
    -- optimized = one batched per wave / stress call).
    function self:CountSpawnRPC()
        _spawnrpctotal = _spawnrpctotal + 1
    end

    -- c_metrics_reset(): zero the windowed counters for a clean A/B. Cumulative
    -- bases are re-seeded to the live totals so the next window starts fresh.
    function self:ResetCounters()
        _dirtytotal = 0
        _spawnrpctotal = 0
        _scanopstotal = 0
        _computetotal = 0
        _ticks = 0
        _windowdirtybase = 0
        _windowscanbase = 0
        _windowcomputebase = 0
        _windowtickbase = 0
        _dirtypersec = 0
        _scanopspersec = 0
        _computemspertick = 0
    end

    function self:OnUpdate(dt)
        _ticks = _ticks + 1

        local nowreal = GetTimeReal()
        if _lastreal ~= nil then
            local frame = nowreal - _lastreal
            _frameema = (_frameema == nil) and frame or (_frameema + EMA_K * (frame - _frameema))
        end
        _lastreal = nowreal

        if _windowstart == nil then
            _windowstart = nowreal
        end
        local elapsed = nowreal - _windowstart
        if elapsed >= WINDOW_MS then
            local windowticks = math.max(1, _ticks - _windowtickbase)
            _computemspertick = (_computetotal - _windowcomputebase) * 1000 / windowticks
            _scanopspersec = (_scanopstotal - _windowscanbase) * 1000 / elapsed
            _dirtypersec = (_dirtytotal - _windowdirtybase) * 1000 / elapsed
            _windowcomputebase = _computetotal
            _windowtickbase = _ticks
            _windowscanbase = _scanopstotal
            _windowdirtybase = _dirtytotal
            _windowstart = nowreal
        end
    end

    function self:GetReadout()
        local siegemanager = TheWorld.components.siegemanager
        local naive = siegemanager ~= nil and siegemanager:IsNaive() or false
        local frame = _frameema or 0
        local framefps = (frame > 0) and (1000 / frame) or 0
        return string.format(
            "compute=%.3fms/tick | scan-ops=%.0f/s | updating_ents=%d | netvar churn=%.0f/s | spawn RPCs=%d | frame=%.1fms(~%.0ffps obs) | naive=%s",
            _computemspertick,
            _scanopspersec,
            num_updating_ents or 0,
            _dirtypersec,
            _spawnrpctotal,
            frame, framefps,
            naive and "ON" or "off")
    end

    -- One world component sampling once per tick: a diagnostic, not the thing
    -- under test. The world never sleeps, so this gives a stable tick clock.
    inst:StartUpdatingComponent(self)
end)
