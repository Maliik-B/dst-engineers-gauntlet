-- Gauntlet HUD — a top-center siege-status readout (wave + Engine HP), drawn
-- entirely from the objective's ALREADY-replicated netvars. Client-side; added
-- to the player HUD via AddClassPostConstruct in modmain. No new replication: it
-- finds the objective by tag and reads _wave/_phase/_objhp directly, and hides
-- itself whenever no siege is running (IDLE / no objective).

local Widget = require("widgets/widget")
local Text = require("widgets/text")
local GAUNTLET = require("gauntlet_constants")
local PHASE = GAUNTLET.PHASE

local HP_QUANTUM = 200 -- matches the objective's net_byte HP encoding

local GauntletHUD = Class(Widget, function(self, owner)
    Widget._ctor(self, "GauntletHUD")
    self.owner = owner

    self.wave = self:AddChild(Text(NEWFONT_OUTLINE, 34))
    self.wave:SetPosition(0, -34, 0)
    self.wave:SetColour(1, .9, .6, 1)

    self.hp = self:AddChild(Text(NEWFONT_OUTLINE, 24))
    self.hp:SetPosition(0, -64, 0)

    self:Hide()
    self:StartUpdating()
end)

function GauntletHUD:OnUpdate(dt)
    local objective = TheSim:FindFirstEntityWithTag("gauntlet_objective")
    if objective == nil or objective._phase == nil then
        self:Hide()
        return
    end

    local phase = objective._phase:value()
    if phase == PHASE.IDLE then
        self:Hide()
        return
    end
    self:Show()

    if phase == PHASE.VICTORY then
        self.wave:SetString("VICTORY")
        self.hp:SetString("The Engine held.")
        return
    elseif phase == PHASE.DEFEAT then
        self.wave:SetString("DEFEAT")
        self.hp:SetString("The Engine has fallen.")
        return
    end

    self.wave:SetString(string.format("Wave %d / %d",
        objective._wave:value(), objective._maxwave:value()))
    self.hp:SetString(string.format("Engine  %d%%",
        math.floor(objective._objhp:value() / HP_QUANTUM * 100 + .5)))
end

return GauntletHUD
