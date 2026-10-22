--[[ Greenfields - UI/Minimap.lua
     Draggable minimap button + Addon Compartment entry.
     Forever's minimap is bigger than Classic's, so the radius is read from the map. ]]

local _, GF = ...

local UI = GF.UI
local T = GF.Theme
local API, U = GF.API, GF.Util

local button

local function radius()
    local w = Minimap and Minimap:GetWidth() or 140
    return w / 2 + 12
end

local function shape()
    local f = rawget(_G, "GetMinimapShape")
    if type(f) == "function" then
        local ok, s = pcall(f)
        if ok and type(s) == "string" then return s end
    end
    return "ROUND"
end

local function place()
    if not button then return end
    local angle = math.rad(GF.db.settings.minimap.angle or 200)
    local x, y = math.cos(angle), math.sin(angle)
    local r = radius()
    if shape() == "SQUARE" then
        x = math.max(-1, math.min(1, x * 1.414))
        y = math.max(-1, math.min(1, y * 1.414))
    end
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x * r, y * r)
end

local function tooltip(owner)
    local lines = {}
    lines[#lines + 1] = { "Online", tostring(GF.Roster:OnlineCount()) }
    lines[#lines + 1] = { "Running Greenfields", tostring(GF.Comm:OnlinePeers()) }
    if GF.Raids and GF.Raids.Upcoming then
        local ok, list = GF:Safe("mm:raids", GF.Raids.Upcoming, GF.Raids, 1)
        local ev = ok and type(list) == "table" and list[1]
        if ev and ev.time then
            lines[#lines + 1] = { "Next raid", (ev.title or "Raid") .. " - " .. U.DateTime(ev.time) }
        end
    end
    lines[#lines + 1] = " "
    lines[#lines + 1] = T:Wrap("dim", "Left-click: open   Right-click: quick menu   Drag: move")
    UI:Tip(owner, T:Wrap("green", "GREENFIELDS"), lines, "ANCHOR_LEFT")
end

local function quickMenu(anchor)
    UI:OpenMenu(anchor, {
        { text = "Greenfields", title = true },
        { text = "The Street", icon = "home", func = function() UI:OpenMain("home") end },
        { text = "Buff Check & Camp", icon = "campfire", func = function() UI:OpenMain("buffs") end },
        { text = "Soft Res", icon = "dice", func = function() UI:OpenMain("softres") end },
        { text = "Raid Nights", icon = "calendar", func = function() UI:OpenMain("raids") end },
        { separator = true },
        { text = "Sync now", icon = "sync", func = function() GF.Store:Flush(); GF.Store:SyncNow() end },
        { text = "Settings", icon = "gear", func = function() UI:OpenMain("settings") end },
    }, { width = 190, point = "TOPRIGHT", relPoint = "BOTTOMLEFT" })
end

function UI:BuildMinimap()
    if button or not Minimap then return end
    local b = CreateFrame("Button", "GreenfieldsMinimapButton", Minimap)
    b:SetSize(32, 32)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    -- dark rim behind the sign-green disc so it reads on any minimap skin
    b.ring = b:CreateTexture(nil, "BACKGROUND")
    b.ring:SetTexture(T.tex.circle)
    b.ring:SetSize(30, 30)
    b.ring:SetPoint("CENTER")
    b.ring:SetVertexColor(0, 0, 0, 0.7)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    if GF.Art and GF.Art.crest then
        b.icon:SetTexture(GF.Art.crest)   -- painted guild crest (Data/Art.lua)
        b.icon:SetSize(30, 30)
    else
        b.icon:SetTexture(T.tex.minimap)
        b.icon:SetSize(26, 26)
    end
    b.icon:SetPoint("CENTER")
    b.hl = b:CreateTexture(nil, "HIGHLIGHT")
    b.hl:SetTexture(T.tex.glow)
    b.hl:SetSize(44, 44)
    b.hl:SetPoint("CENTER")
    b.hl:SetVertexColor(0.24, 0.86, 0.47, 0.6)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetScript("OnClick", function(self, btn)
        if btn == "RightButton" then quickMenu(self) else UI:ToggleMain() end
    end)
    b:SetScript("OnEnter", function(self) tooltip(self) end)
    b:SetScript("OnLeave", function() UI:HideTip() end)
    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local s = Minimap:GetEffectiveScale()
            cx, cy = cx / s, cy / s
            GF.db.settings.minimap.angle = math.deg(math.atan2(cy - my, cx - mx))
            place()
        end)
    end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    button = b
    place()
    b:SetShown(not GF.db.settings.minimap.hide)
end

function UI:SetMinimapShown(on)
    GF.db.settings.minimap.hide = not on
    if button then button:SetShown(on) end
end

GF:On("GF_LOGIN", function() UI:BuildMinimap() end)

-- Addon Compartment (declared in the TOC)
function Greenfields_OnCompartmentClick(_, mouseButton)
    GF:After(0, function()
        if mouseButton == "RightButton" then UI:OpenMain("settings") else UI:ToggleMain() end
    end)
end

function Greenfields_OnCompartmentEnter(_, owner)
    if owner then tooltip(owner) end
end

function Greenfields_OnCompartmentLeave()
    UI:HideTip()
end
