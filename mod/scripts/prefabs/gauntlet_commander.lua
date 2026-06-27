-- Gauntlet Commander — the held command tool for the minion (the deploy/command
-- UX, character-agnostic). A simple hand-equippable that reuses Winona's remote-
-- control art (engineer-remote read; no new art). It carries NO command logic
-- itself: while it's equipped, a CLIENT-side right-click handler (in modmain)
-- reads the cursor and fires the validated client->server command RPC. The item
-- is just the "command mode" gate + the thing you craft.

local assets =
{
    Asset("ANIM", "anim/winona_remote.zip"),
}

-- Held-hand visual (M4-deferred, now in scope): show Winona's remote in the
-- commander's hand while equipped. The winona_remote build carries a "swap_remote"
-- symbol (SGwilson.lua uses it for her cast-hold pose); we point the player's
-- generic hand slot ("swap_object") at it, so the tool appears in hand instead of
-- equipping invisibly. Runs master-side; the symbol override replicates to clients.
local function OnEquip(inst, owner)
    owner.AnimState:OverrideSymbol("swap_object", "winona_remote", "swap_remote")
    -- Recolor the held remote with a loud GREEN additive glow (the remote's own LED
    -- colour). Green is the peak of human luminance, so it stays the brightest thing on
    -- screen under any colour-cube grade (it never blends into warm afternoon light like
    -- amber, nor washes into the blue full-moon grade); loud so it survives the night
    -- desaturation. Off the warm<->cool axis the day/night cycle rides.
    owner.AnimState:SetSymbolAddColour("swap_object", .18, .7, .2, 0)
    owner.AnimState:Show("ARM_carry")
    owner.AnimState:Hide("ARM_normal")
end

local function OnUnequip(inst, owner)
    owner.AnimState:Hide("ARM_carry")
    owner.AnimState:Show("ARM_normal")
    owner.AnimState:ClearOverrideSymbol("swap_object")
    owner.AnimState:SetSymbolAddColour("swap_object", 0, 0, 0, 0) -- clear the glow, else the next hand item inherits it
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("winona_remote")
    inst.AnimState:SetBuild("winona_remote")
    inst.AnimState:PlayAnimation("idle")
    -- Loud green additive recolor (the remote's own LED colour) — green's peak luminance
    -- keeps it the brightest thing on screen under any time-of-day grade (world + float;
    -- held tinted the same in OnEquip).
    inst.AnimState:SetAddColour(.18, .7, .2, 0)

    inst:AddTag("gauntlet_commander")

    MakeInventoryFloatable(inst, "small", 0.14, { 1.1, 1.15, 1 })

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")
    -- Slot icon: the world + held visual are runtime-tinted green (above / OnEquip),
    -- but itemtile draws the slot straight from the .tex and can't be tinted — so the
    -- slot falls back to the shipped winona_remote image. A bespoke recolored atlas is
    -- optional future polish, not a gap.
    inst.components.inventoryitem:ChangeImageName("winona_remote")

    inst:AddComponent("equippable")
    inst.components.equippable.equipslot = EQUIPSLOTS.HANDS
    -- Equipping is the "command mode" gate (modmain's client right-click handler
    -- only fires while this is in HANDS); the swap fns above add the held visual.
    inst.components.equippable.onequipfn = OnEquip
    inst.components.equippable.onunequipfn = OnUnequip

    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("gauntlet_commander", fn, assets)
