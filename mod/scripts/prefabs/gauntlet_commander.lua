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
    owner.AnimState:Show("ARM_carry")
    owner.AnimState:Hide("ARM_normal")
end

local function OnUnequip(inst, owner)
    owner.AnimState:Hide("ARM_carry")
    owner.AnimState:Show("ARM_normal")
    owner.AnimState:ClearOverrideSymbol("swap_object")
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

    inst:AddTag("gauntlet_commander")

    MakeInventoryFloatable(inst, "small", 0.14, { 1.1, 1.15, 1 })

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")
    -- Stopgap slot icon: point at the shipped winona_remote inventory image so the
    -- slot isn't blank. A distinct amber recolor atlas is queued for the art pass —
    -- the inventory slot can't be runtime-tinted (itemtile draws straight from the
    -- item's atlas), so distinctness needs a real recolored .tex, not a tint call.
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
