-- Engineer's Gauntlet — modmain (M0 skeleton)
--
-- Architecture rule (locked): the master sim owns all gameplay truth.
-- Clients render and send intent (RPCs) only. Everything added here must
-- keep that split. RPC handlers will be registered in this file so every
-- shard process loads them (shard-aware from day one, per spec).

local _G = GLOBAL

local WAVE_SIZE = GetModConfigData("wave_size") or 10

print("[Gauntlet] modmain loaded (wave_size=" .. tostring(WAVE_SIZE) .. ")")

-- M0 sanity probe: confirm which side of the sim we're on when the world
-- entity initializes. On a dedicated server this prints on the server; a
-- connected client prints the client branch in its own log.
AddPrefabPostInit("world", function(inst)
    if inst.ismastersim then
        print("[Gauntlet] world init: MASTER SIM — authoritative side active")
    else
        print("[Gauntlet] world init: client — render + intent only")
    end
end)

-- Console probe, and the seed of the M5 stress harness (c_stress / c_naive
-- will live alongside this). Run from the remote console to prove the
-- client->server console path works end to end.
_G.c_gauntlet = function()
    local mastersim = _G.TheNet:GetIsMasterSimulation()
    local mastershard = _G.TheShard ~= nil and _G.TheShard:IsMaster() or false
    print(string.format(
        "[Gauntlet] alive | mastersim=%s mastershard=%s wave_size=%d",
        tostring(mastersim), tostring(mastershard), WAVE_SIZE))
end
