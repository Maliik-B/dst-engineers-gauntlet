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

    inst:AddComponent("equippable")
    inst.components.equippable.equipslot = EQUIPSLOTS.HANDS
    -- Equipping it is purely the "command mode" gate; the held-hand visual is a
    -- cosmetic 4d polish item (no swap symbol set yet).

    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("gauntlet_commander", fn, assets)
