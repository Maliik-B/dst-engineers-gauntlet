-- Gauntlet Sentinel — the commandable minion, character-agnostic.
--
-- A recolored Damaged Clockwork Knight (reuses the knight art/SG/locomotion),
-- retuned into a player-owned defender with a 3-verb command vocabulary:
-- defend-point / follow / focus-target. Ownership is the stock Leader/Follower
-- binding (the From Beyond compass→pulse idiom): the deploying player becomes
-- the leader, capped per-player via leader:CountFollowers (Klei caps at 4).
--
-- Server-authoritative: all command state + AI live on the master sim. The
-- command mode replicates to clients as ONE quantized net_tinybyte, set() only on
-- change (M3 netvar discipline — no churn). Clients send command INTENT via a
-- validated RPC (Phase 4c); they never set command state directly.
--
-- Combat is filtered to hostile/monster mobs only (the shared enemy policy), so
-- it fights any threat yet can't hit players, allies, the objective, or turrets
-- — and they can't hit it. Deployed via a placer recipe; ownership is structure-
-- like (stamped owner-id, persists across disconnect/reload).

require("prefabutil") -- MakePlacer

local GAUNTLET = require("gauntlet_constants")
local CMD = GAUNTLET.MINION_COMMAND
local CMD_NAMES = GAUNTLET.MINION_COMMAND_NAMES

local assets =
{
    Asset("ANIM", "anim/knight.zip"),
    Asset("ANIM", "anim/knight_build.zip"),
    Asset("SOUND", "sound/chess.fsb"),
}

local prefabs = {}

local brain = require("brains/gauntletminionbrain")
local TARGETING = require("gauntlet_targeting")

--------------------------------------------------------------------------
-- Targeting — the shared enemy policy (hostile/monster mobs, never player-side).
-- The active "anchor" (defend point / leader / self) gates keep-target so the
-- minion can't be kited off its post; FOCUS holds its forced target regardless.
--------------------------------------------------------------------------

local function GetAnchorPos(inst)
    local cmd = inst:GetMinionCommand()
    if cmd == CMD.FOLLOW then
        local leader = inst.components.follower:GetLeader()
        return (leader ~= nil and leader:IsValid()) and leader:GetPosition() or inst:GetPosition()
    elseif cmd == CMD.DEFEND then
        return inst:GetMinionDefendPos() or inst:GetPosition()
    end
    return inst:GetPosition() -- FOCUS: free chase, anchored on self
end

local function RetargetFn(inst)
    if inst:GetMinionCommand() == CMD.FOCUS then
        local focus = inst:GetMinionFocusTarget()
        return (focus ~= nil and focus:IsValid()
            and not (focus.components.health ~= nil and focus.components.health:IsDead())
            and inst.components.combat:CanTarget(focus))
            and focus or nil
    end
    -- DEFEND / FOLLOW: acquire the nearest hostile near the minion.
    return FindEntity(
        inst,
        TUNING.GAUNTLET_MINION_TARGET_DIST,
        function(guy) return TARGETING.IsEnemy(inst, guy) end,
        TARGETING.ENEMY_MUST_TAGS,
        TARGETING.ENEMY_CANT_TAGS,
        TARGETING.ENEMY_ONEOF_TAGS
    )
end

local function KeepTargetFn(inst, target)
    -- Only ever hold a valid enemy (defense in depth: nothing player-side can
    -- slip into the target slot).
    if not TARGETING.IsEnemy(inst, target) then
        return false
    elseif inst:GetMinionCommand() == CMD.FOCUS then
        return true -- chase the focused target wherever it goes
    end
    local anchor = GetAnchorPos(inst)
    return target:GetDistanceSqToPoint(anchor:Get())
        < TUNING.GAUNTLET_MINION_KEEP_DIST * TUNING.GAUNTLET_MINION_KEEP_DIST
end

--------------------------------------------------------------------------
-- Self-repair regen (turret-consistent): regen while hurt, stop at full so no
-- task lingers off-screen.
--------------------------------------------------------------------------

local function OnHealthDelta(inst)
    local health = inst.components.health
    if health:IsDead() then
        return
    end
    -- Wear feedback: the knight art has no damage tiers, so shift the cyan tint
    -- smoothly toward red as HP drops (and back as it self-repairs) — a continuous
    -- gradient so the damage level is legible at a glance.
    local hurt = 1 - health:GetPercent()
    inst.AnimState:SetMultColour(.5 + .5 * hurt, .78 - .58 * hurt, 1 - .8 * hurt, 1)
    if health:GetPercent() >= 1 then
        health:StopRegen()
    else
        health:StartRegen(TUNING.GAUNTLET_MINION_REGEN, TUNING.GAUNTLET_MINION_REGEN_PERIOD)
    end
end

--------------------------------------------------------------------------
-- Command state. Stored server-side; the mode mirrors into the net_tinybyte.
--------------------------------------------------------------------------

local function PublishCommand(inst)
    -- set() dirties only on real change, so re-issuing the same mode is free.
    inst._commandnet:set(inst._command)
end

local function ClearFocusWatch(inst)
    if inst._focuswatch ~= nil and inst._focuswatch:IsValid() then
        inst:RemoveEventCallback("death", inst._onfocusended, inst._focuswatch)
        inst:RemoveEventCallback("onremove", inst._onfocusended, inst._focuswatch)
    end
    inst._focuswatch = nil
    inst._focustarget = nil
end

-- Resolve the FOCUS target server-side from the clicked point (scalars-only
-- RPC: the client never sends an entity id). Nearest attacker within radius.
local function ResolveFocusTarget(inst, x, z)
    local best, bestdsq = nil, math.huge
    for _, v in ipairs(TheSim:FindEntities(x, 0, z, TUNING.GAUNTLET_MINION_FOCUS_RESOLVE_RADIUS, TARGETING.ENEMY_MUST_TAGS, TARGETING.ENEMY_CANT_TAGS, TARGETING.ENEMY_ONEOF_TAGS)) do
        if v:IsValid() and TARGETING.IsEnemy(inst, v) then
            local dsq = v:GetDistanceSqToPoint(x, 0, z)
            if dsq < bestdsq then
                best, bestdsq = v, dsq
            end
        end
    end
    return best
end

-- The single command entry point (called by the console harness AND, in 4c, the
-- validated command RPC). mode is a CMD enum; (x,z) is the world point for
-- DEFEND/FOCUS, ignored for FOLLOW. Returns true if applied.
local function SetMinionCommand(inst, mode, x, z)
    if mode ~= CMD.DEFEND and mode ~= CMD.FOLLOW and mode ~= CMD.FOCUS then
        return false
    end

    ClearFocusWatch(inst)

    if mode == CMD.FOCUS then
        local focus = (x ~= nil and z ~= nil) and ResolveFocusTarget(inst, x, z) or nil
        if focus == nil then
            return false -- no enemy near the clicked point; command ignored
        end
        -- Remember the post/stance to return to once the sortie ends — but don't
        -- overwrite it if we're already focusing and just switching targets.
        if inst._command ~= CMD.FOCUS then
            inst._prevcommand = inst._command
            inst._prevdefendpos = inst._defendpos
        end
        inst._focustarget = focus
        inst._focuswatch = focus
        inst:ListenForEvent("death", inst._onfocusended, focus)
        inst:ListenForEvent("onremove", inst._onfocusended, focus)
        inst.components.combat:SetTarget(focus)
    elseif mode == CMD.DEFEND then
        inst._defendpos = (x ~= nil and z ~= nil) and Vector3(x, 0, z) or inst:GetPosition()
    end

    inst._command = mode
    PublishCommand(inst)
    return true
end

-- Bind the minion to a deploying player (the leader), enforcing the per-player
-- cap. Stamps the owner's user-id so ownership is STRUCTURE-like: it persists
-- across disconnect/reload and is restored distance-independently (see
-- RebindToOwner), unlike the stock pet re-follow which only re-attaches if you
-- respawn right next to the follower. Returns false if the player is at cap.
local function SetMinionOwner(inst, player)
    if player == nil or player.components.leader == nil then
        return false
    end
    if player.components.leader:CountFollowers("gauntlet_minion") >= TUNING.GAUNTLET_MINION_MAX
        and not player.components.leader:IsFollower(inst) then
        return false
    end
    inst._owneruserid = player.userid
    player.components.leader:AddFollower(inst) -- -> follower:SetLeader(player)
    return true
end

-- Restore ownership to the stamped owner whenever they are present — no cap
-- check (it's already ours) and no distance gate (the stock pet re-follow needs
-- you nearby; a deployed defender shouldn't lapse just because you respawned at
-- the portal). Called on player-join and once after load.
local function RebindToOwner(inst, player)
    if player ~= nil and player:IsValid()
        and inst._owneruserid ~= nil and player.userid == inst._owneruserid
        and player.components.leader ~= nil
        and inst.components.follower:GetLeader() ~= player then
        player.components.leader:AddFollower(inst)
    end
end

--------------------------------------------------------------------------
-- Save / load. Persists the durable command (DEFEND/FOLLOW + defend point) and
-- the owner's user-id; a transient FOCUS collapses to DEFEND on reload (its
-- target is long gone). The owner is re-bound after load via RebindToOwner.
--------------------------------------------------------------------------

local function OnSave(inst, data)
    data.command = (inst._command == CMD.FOCUS) and CMD.DEFEND or inst._command
    local pos = inst:GetMinionDefendPos()
    if pos ~= nil then
        data.defx, data.defz = pos.x, pos.z
    end
    data.owner = inst._owneruserid
end

local function OnLoad(inst, data)
    if data == nil then
        return
    end
    if data.defx ~= nil and data.defz ~= nil then
        inst._defendpos = Vector3(data.defx, 0, data.defz)
    end
    inst._command = data.command or CMD.DEFEND
    inst._owneruserid = data.owner
    PublishCommand(inst)
end

--------------------------------------------------------------------------
-- Client-side reaction to the replicated command (HUD hook later; print now,
-- mirroring the objective's netvar listeners).
--------------------------------------------------------------------------

local function OnCommandDirty(inst)
    print(string.format("[Gauntlet] client: minion command -> %s",
        CMD_NAMES[inst._commandnet:value()] or tostring(inst._commandnet:value())))
end

local function PlacerPostInit(inst)
    inst.AnimState:SetMultColour(.5, .78, 1, 1) -- ghost matches the cyan minion
end

-- Examine reflects the current command. Server-side (getstatus runs where the
-- command state lives); keyed into the DESCRIBE table.
local CMD_STATUS = { [CMD.DEFEND] = "DEFEND", [CMD.FOLLOW] = "FOLLOW", [CMD.FOCUS] = "FOCUS" }
local function GetMinionStatus(inst)
    return CMD_STATUS[inst._command]
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddDynamicShadow()
    inst.entity:AddNetwork()

    inst:SetPhysicsRadiusOverride(0.5)
    MakeCharacterPhysics(inst, 50, inst.physicsradiusoverride)

    inst.DynamicShadow:SetSize(1.5, .75)
    inst.Transform:SetFourFaced() -- knight art is four-faced (knight.lua:100)

    inst.AnimState:SetBank("knight")
    inst.AnimState:SetBuild("knight_build")
    inst.AnimState:PlayAnimation("idle_loop", true)
    inst.AnimState:SetMultColour(.5, .78, 1, 1) -- cyan recolor: reads as "yours", not a hostile knight

    inst:AddTag("companion")        -- player-side ally (combat ally checks)
    inst:AddTag("character")
    inst:AddTag("gauntlet_minion")
    inst:AddTag("gauntlet_defense") -- what the M5 Breaker attacker hunts

    -- Replicated command mode: ONE net_tinybyte, declared both sides pre-pristine,
    -- set() only on change (no churn). Drives the HUD command readout later.
    inst._commandnet = net_tinybyte(inst.GUID, "gauntlet_minion._command", "gauntlet_minion_commanddirty")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        inst:ListenForEvent("gauntlet_minion_commanddirty", OnCommandDirty)
        return inst
    end

    inst.kind = "" -- SGknight builds sound paths as "...knight"..inst.kind.."/..."

    -- Command state (server-authoritative).
    inst._command = CMD.DEFEND
    inst._defendpos = nil       -- set on first DEFEND / deploy; nil -> current pos
    inst._focustarget = nil
    inst._focuswatch = nil
    inst._prevcommand = CMD.DEFEND  -- the stance to restore when a FOCUS sortie ends
    inst._prevdefendpos = nil
    inst._owneruserid = nil     -- stamped on deploy; persists ownership across disconnect/reload
    inst._onfocusended = function()
        if inst._command ~= CMD.FOCUS then
            return
        end
        -- Sortie over: return to the prior post/stance, not "hold where the
        -- chase ended". Resume FOLLOW, or DEFEND back at the original point.
        if inst._prevcommand == CMD.FOLLOW then
            SetMinionCommand(inst, CMD.FOLLOW)
        else
            local p = inst._prevdefendpos
            SetMinionCommand(inst, CMD.DEFEND, p and p.x or nil, p and p.z or nil)
        end
    end

    inst:AddComponent("locomotor") -- locomotor before the stategraph
    inst.components.locomotor.walkspeed = TUNING.GAUNTLET_MINION_SPEED
    inst.components.locomotor.runspeed = TUNING.GAUNTLET_MINION_SPEED

    inst:SetStateGraph("SGknight")
    inst:SetBrain(brain)

    inst:AddComponent("follower")
    inst.components.follower.neverexpire = true      -- no loyalty decay; permanent owned defender
    inst.components.follower.keepdeadleader = true   -- survives the owner's death/respawn
    -- Hitting your own minion must NOT un-own it: the stock Follower drops the
    -- leader when the leader is the attacker (follower.lua:1-7). KeepLeaderOnAttacked
    -- removes that (the shipped YOTH-knight does the same).
    inst.components.follower:KeepLeaderOnAttacked()
    -- Ignore the owner's click-targets: Leader:OnNewTarget/OnAttacked broadcast
    -- whatever the player targets to followers (leader.lua:152) — that made the
    -- minion attack the Engine (and would make minions attack each other). The
    -- minion picks foes ONLY through its own attacker-only retarget + FOCUS.
    inst.components.follower.canaccepttarget = false

    inst:AddComponent("health")
    inst.components.health:SetMaxHealth(TUNING.GAUNTLET_MINION_HEALTH)

    inst:AddComponent("combat")
    inst.components.combat:SetDefaultDamage(TUNING.GAUNTLET_MINION_DAMAGE)
    inst.components.combat:SetAttackPeriod(TUNING.GAUNTLET_MINION_ATTACK_PERIOD)
    inst.components.combat:SetRange(TUNING.GAUNTLET_MINION_ATTACK_RANGE, TUNING.GAUNTLET_MINION_HIT_RANGE)
    inst.components.combat:SetRetargetFunction(3, RetargetFn)
    inst.components.combat:SetKeepTargetFunction(KeepTargetFn)
    inst.components.combat.hiteffectsymbol = "spring"

    inst:AddComponent("lootdropper")

    inst:AddComponent("inspectable")
    inst.components.inspectable.getstatus = GetMinionStatus
    inst:AddComponent("knownlocations")

    MakeMediumBurnableCharacter(inst, "spring")
    MakeMediumFreezableCharacter(inst, "spring")
    MakeHauntablePanic(inst)

    inst:ListenForEvent("healthdelta", OnHealthDelta)

    -- Deployed via the placer recipe -> bind to the builder (owner) and hold the
    -- deploy spot. Then re-bind to that owner whenever they (re)join the world,
    -- distance-independent, so the minion stays yours across disconnects/respawns.
    inst:ListenForEvent("onbuilt", function(minion, data)
        -- Deploy feedback: the minion is a clockwork construct, so a metallic robotic
        -- turn-on reads better than a stone-place thud — the Wagdrone's beep+whir
        -- "powering on" (rifts5), so the unit sounds like it's coming online.
        if minion.SoundEmitter ~= nil then
            minion.SoundEmitter:PlaySound("rifts5/wagdrone_rolling/beep_turnon")
        end
        if data ~= nil and data.builder ~= nil then
            SetMinionOwner(minion, data.builder)
        end
        local pos = minion:GetPosition()
        SetMinionCommand(minion, CMD.DEFEND, pos.x, pos.z)
    end)
    inst:ListenForEvent("ms_playerjoined", function(world, player) RebindToOwner(inst, player) end, TheWorld)
    inst:DoTaskInTime(0, function()
        -- After load (or c_minion_spawn), re-bind if the owner is already here.
        if inst._owneruserid ~= nil and inst.components.follower:GetLeader() == nil then
            for _, p in ipairs(AllPlayers) do
                if p.userid == inst._owneruserid then
                    RebindToOwner(inst, p)
                    return
                end
            end
        end
    end)

    inst.GetMinionCommand = function() return inst._command end
    inst.GetMinionDefendPos = function() return inst._defendpos end
    inst.GetMinionFocusTarget = function() return inst._focustarget end
    inst.SetMinionCommand = SetMinionCommand
    inst.SetMinionOwner = SetMinionOwner

    inst.OnSave = OnSave
    inst.OnLoad = OnLoad

    return inst
end

return Prefab("gauntlet_minion", fn, assets, prefabs),
    MakePlacer("gauntlet_minion_placer", "knight", "knight_build", "idle_loop",
        nil, nil, nil, nil, nil, "four", PlacerPostInit)
