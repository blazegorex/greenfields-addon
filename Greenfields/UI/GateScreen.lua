--[[ Greenfields - UI/GateScreen.lua
     What someone outside the guild gets instead of the main window (see Core/Gate.lua). Opens only
     when they ask: nobody gets a popup for having the addon switched on.

       UI:ShowGate()  UI:ToggleGate() ]]

local _, GF = ...

local UI = GF.UI

local WIDTH, HEIGHT = 560, 304
local SCENE_W, SCENE_H, SCENE_SOLID = 1040, 148, 126   -- what the banner art is painted for
local PAD = 12

-- { heading, what's going on, what to do about it }
local WORDS = {
    checking = {
        "Hang on a sec",
        "Just checking this character's on the guild list.",
        "The game's still working out your guild. Won't be long.",
    },
    noguild = {
        "Residents only",
        "Greenfields only runs for characters in the Greenfields guild, and this one isn't on the list.",
        "Get an invite and the gate opens by itself. No reload, no paperwork.",
    },
    other = {
        "Residents only",
        "Greenfields only runs for characters in the Greenfields guild, and this one's with %s.",
        "Nothing personal. Move onto the street and the gate opens by itself.",
    },
}
local TEST_NOTE = "Test mode: this is what people outside the guild see. /gf gate test opens it back up."

local frame

local function refresh()
    local words = WORDS[GF.Gate:Why()] or WORDS.noguild
    frame.heading:SetText(words[1])
    frame.lead:SetText(words[2]:format(GF.Gate:Guild() or "another mob"))
    frame.note:SetText(GF.Gate:IsTest() and TEST_NOTE or words[3])
end

local function build()
    local f = UI:Window("GreenfieldsGate", { width = WIDTH, height = HEIGHT, band = SCENE_H, closeTip = "Close (Esc)" })
    f:SetPoint("CENTER", 0, 60)
    local head = f.head
    head.leather:Hide()
    head.shade:Hide()
    head.rule:Hide()
    f.close:ClearAllPoints()
    f.close:SetPoint("TOPRIGHT", -8, -8)
    -- the middle of the night scene, dissolving into the window the same way the main window's does
    local path = GF.Art and GF.Art.heroes and (GF.Art.heroes.gate or GF.Art.heroes.home)
    local u0 = (1 - (WIDTH - 8) / SCENE_W) / 2
    local vm = SCENE_SOLID / SCENE_H
    local top = head:CreateTexture(nil, "BACKGROUND", nil, 3)
    top:SetPoint("TOPLEFT")
    top:SetPoint("TOPRIGHT")
    top:SetHeight(SCENE_SOLID)
    top:SetTexture(path)
    top:SetTexCoord(u0, 1 - u0, 0, vm)
    local low = head:CreateTexture(nil, "BACKGROUND", nil, 3)
    low:SetPoint("TOPLEFT", top, "BOTTOMLEFT")
    low:SetPoint("BOTTOMRIGHT")
    low:SetTexture(path)
    low:SetTexCoord(u0, 1 - u0, vm, 1)
    UI:Gradient2(low, "VERTICAL", 1, 1, 1, 0, 1)

    local body = f.body
    f.heading = UI:Text(body, 28, "wowGold", "title")
    f.heading:SetPoint("TOPLEFT", PAD, 2)
    f.lead = UI:Para(body, 14, "text")
    f.lead:SetPoint("TOPLEFT", f.heading, "BOTTOMLEFT", 0, -8)
    f.lead:SetWidth(WIDTH - 2 * (4 + 8 + PAD))
    f.note = UI:Para(body, 12, "dim")
    f.note:SetPoint("TOPLEFT", f.lead, "BOTTOMLEFT", 0, -8)
    f.note:SetWidth(WIDTH - 2 * (4 + 8 + PAD))
    f.ok = UI:Button(body, "Fair enough", { style = "secondary", height = 28, minWidth = 110, onClick = function() f:Hide() end })
    f.ok:SetPoint("BOTTOMRIGHT", -PAD + 4, 0)
    frame = f
end

function UI:ShowGate()
    if not frame then build() end
    refresh()
    frame:Show()
    frame:Raise()
end

function UI:ToggleGate()
    if frame and frame:IsShown() then frame:Hide() else self:ShowGate() end
end

GF:On("GF_GATE_CHANGED", function(shut, was, quiet)
    if shut then
        local wasOpen = UI:IsMainShown() or (frame and frame:IsShown())
        if was == nil then
            -- going from open to shut: whatever was up goes, and the gate takes its place
            UI:HideMain()
            UI:CloseModal()
            UI:CloseMenu()
            for _, w in ipairs(UI.windows) do
                if w ~= frame then w:Hide() end
            end
        end
        if wasOpen then UI:ShowGate() end
        return
    end
    if frame and frame:IsShown() then
        frame:Hide()
        UI:OpenMain()
    end
    if not quiet and (was == "noguild" or was == "other") then
        UI:Toast({ title = "You're in", text = "Welcome to the street. The gate's open.", icon = "home", style = "green",
            duration = 10, force = true, key = "gate-open", onClick = function() UI:OpenMain() end })
    end
end)
