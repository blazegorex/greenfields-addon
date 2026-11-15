--[[ Greenfields - Modules/NemesisNearby.lua
     Most Wanted, the lookout: a small list near the top of the screen of every wanted enemy about,
     plus the ones a guildie's just spotted in your zone. One row each, however many turn up.

     Click a name and you target them and put their mark on them: the skull for the first one about,
     then a cross, a square, a moon. Right-click for their poster. The red header drags the list.

     Raid marks and targeting are Blizzard's alone on this client, so both go through a secure button,
     and secure buttons can't be touched in a fight. So: each row has its own secure button sitting
     over it, a top-level one set up out of fights. In a fight the list never reshuffles (whoever's
     gone stays, greyed out, till it's over), and anyone who turns up mid-fight can be clicked once
     it's over. The data is Modules/Nemesis.lua (N:Nearby, N:Rescan).

       /gf wanted nearby   a preview of the list (made-up names), to see it or drag it somewhere ]]

local _, GF = ...
local API, U, UI, T = GF.API, GF.Util, GF.UI, GF.Theme
local N = GF.Nemesis
local min, max, floor = math.min, math.max, math.floor

local W = 236
local HEAD = 22
local ROW = 24
local MAX_ROWS = 5
local MORE = 16
local START = { point = "TOP", x = 0, y = -150 }   -- under the first road sign
local SOUND, SOUND_GAP = 8959, 10                  -- the raid warning; once every 10 s at most
local MARK_TEX = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_%d"
local MARK_NAMES = { "star", "circle", "diamond", "triangle", "moon", "square", "cross", "skull" }
local PAGE = "wanted"

local f                     -- the list
local render                -- below
local slots = {}            -- the secure buttons, one per row
local shown = {}            -- what each row is showing
local previewUntil = 0
local soundAt = 0

local function settings() return GF.db and GF.db.settings or {} end
local function fight() return API.InCombat() end

-------------------------------------------------------------------------------
-- What's on it
-------------------------------------------------------------------------------
local PREVIEW = {
    { name = "Thrandor", here = true, mark = 8, p = { name = "Thrandor", race = "nightelf", class = "ROGUE", sex = 2, level = 60, bounty = 7 } },
    { name = "Brightblade", here = true, mark = 7, p = { name = "Brightblade", race = "human", class = "PALADIN", sex = 2, level = 58, bounty = 3 } },
    { name = "Fizzlecrank", here = false, by = "Bazza", zone = "The Barrens", p = { name = "Fizzlecrank", race = "gnome", class = "WARLOCK", sex = 3, level = 41, bounty = 2 } },
}

local function previewing() return API.Time() < previewUntil end

local function live()
    if GF.gateShut then return {} end
    if previewing() then
        local now = API.Time()
        for _, e in ipairs(PREVIEW) do e.t, e.first, e.fake = now, now, true end
        return PREVIEW
    end
    return N:Nearby()
end

--- The marks are ours to put on: off in settings, or in a raid without lead or assist, a click just targets.
local function marking()
    if settings().wantedMarks == false then return false end
    if API.InRaid() then
        local function yes(fn)
            local g = rawget(_G, fn)
            if type(g) ~= "function" then return false end
            local ok, r = pcall(g, "player")
            return ok and API.Readable(r) and r and true or false
        end
        return yes("UnitIsGroupLeader") or yes("UnitIsGroupAssistant")
    end
    return true
end

local function macroFor(e)
    local m = "/targetexact " .. e.name
    if e.here and e.mark and marking() then m = m .. "\n/tm [@target,harm,nodead] !" .. e.mark end
    return m
end

-------------------------------------------------------------------------------
-- The tooltip
-------------------------------------------------------------------------------
local function armedFor(i, e)
    local b = slots[i]
    return b and b:IsShown() and b.name == e.name and b.macro == macroFor(e)
end

local function rowTip(row, owner)
    local e = row and row.e
    if not e then return end
    local p = e.p or {}
    local lines = { N:Describe(p), { "On their head", N:PointsText(p.bounty) } }
    if e.gone then
        lines[#lines + 1] = "Out of sight."
    elseif e.here then
        lines[#lines + 1] = "Right here."
    else
        local ago = U.Duration and U.Duration(max(1, floor(API.Time() - (e.t or 0)))) or ""
        lines[#lines + 1] = ("%s spotted them in %s, %s ago."):format(U.StripCodes(GF.Roster and GF.Roster.Colored
            and GF.Roster:Colored(e.by) or tostring(e.by)), tostring(e.zone or "your zone"), ago)
    end
    if e.fake then
        lines[#lines + 1] = "Just a preview. Drag the red bar to move the list."
    elseif armedFor(row.i, e) then
        local m = e.here and e.mark and marking() and (" and put the " .. MARK_NAMES[e.mark] .. " on them") or ""
        lines[#lines + 1] = "Click to target them" .. m .. ". Right-click for their poster."
    elseif fight() then
        lines[#lines + 1] = "Turned up mid-fight: once it's over, a click targets them. Right-click for their poster."
    else
        lines[#lines + 1] = "Right-click for their poster."
    end
    UI:Tip(owner or row, "|cff" .. U.ClassColorHex(p.class) .. e.name .. "|r", lines, "ANCHOR_BOTTOM")
end

local function poster(name)
    if name and UI.OpenMain then UI:OpenMain(PAGE, name) end
end

local function flash(row)
    if row and row.flashAnim then row.flashAnim:Stop() row.flashAnim:Play() end
end

-------------------------------------------------------------------------------
-- The secure buttons: one over each row, set up out of fights only
-------------------------------------------------------------------------------
local function slotFor(i)
    if slots[i] or fight() then return slots[i] end
    local b = CreateFrame("Button", "GreenfieldsWantedTarget" .. i, UIParent, "SecureActionButtonTemplate")
    b:SetFrameStrata("HIGH")
    b:SetFrameLevel(f:GetFrameLevel() + 20)
    -- down and up: the template acts on whichever the ActionButtonUseKeyDown setting says, once
    b:RegisterForClicks("AnyUp", "AnyDown")
    b:SetAttribute("type1", "macro")
    b:SetScript("PostClick", function(self, button, down)
        if down then return end
        if button == "RightButton" then return poster(self.name) end
        N.diag.clicks = (N.diag.clicks or 0) + 1
        flash(f.rows[i])
    end)
    b:SetScript("OnEnter", function(self)
        f.rows[i].hl:SetAlpha(0.7)
        rowTip(f.rows[i], self)
    end)
    b:SetScript("OnLeave", function()
        f.rows[i].hl:SetAlpha(0)
        UI:HideTip()
    end)
    b:Hide()
    slots[i] = b
    return b
end

--- Puts each row's secure button over it, set for whoever the row shows. Out of fights only.
local function arm()
    if not f or fight() then return end
    local us = UIParent:GetEffectiveScale()
    for i = 1, MAX_ROWS do
        local row, e = f.rows[i], shown[i]
        local want = e and not e.fake and not e.gone and f:IsShown() and row:IsShown()
        local b = want and slotFor(i) or slots[i]
        if b then
            local l, t = row:GetLeft(), row:GetTop()
            if want and l and t then
                local s = row:GetEffectiveScale() / us
                local m = macroFor(e)
                local at = ("%.1f,%.1f,%.1f,%.1f"):format(l * s, t * s, row:GetWidth() * s, row:GetHeight() * s)
                if b.at ~= at then
                    b:ClearAllPoints()
                    b:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", l * s, t * s)
                    b:SetSize(row:GetWidth() * s, row:GetHeight() * s)
                    b.at = at
                end
                if b.macro ~= m then b:SetAttribute("macrotext1", m) end
                b.name, b.macro = e.name, m
                b:Show()
            else
                b.name, b.macro = nil, nil
                b:Hide()
            end
        end
    end
end

-------------------------------------------------------------------------------
-- The list
-------------------------------------------------------------------------------
local function savePlace()
    local l, t = f:GetLeft(), f:GetTop()
    if not (l and t) or type(GF.db) ~= "table" then return end
    GF.db.wantedNearbyAt = { x = floor(l + 0.5), y = floor(t + 0.5) }
end

local function place()
    f:ClearAllPoints()
    local at = type(GF.db) == "table" and GF.db.wantedNearbyAt
    if type(at) == "table" and tonumber(at.x) and tonumber(at.y) then
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", at.x, at.y)
    else
        f:SetPoint(START.point, UIParent, START.point, START.x, START.y)
    end
end

local function makeRow(i)
    local row = CreateFrame("Button", nil, f)
    row.i = i
    row:SetSize(W, ROW)
    row:SetPoint("TOPLEFT", 0, -(HEAD + (i - 1) * ROW))
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row.hl = UI:Tex(row, "BACKGROUND", T.c.bg3)
    row.hl:SetAllPoints()
    row.hl:SetAlpha(0)
    row.flash = UI:Tex(row, "BORDER", T.c.red)
    row.flash:SetAllPoints()
    row.flash:SetAlpha(0)
    local ag = row.flash:CreateAnimationGroup()
    local a = ag:CreateAnimation("Alpha")
    a:SetFromAlpha(0.45)
    a:SetToAlpha(0)
    a:SetDuration(0.9)
    a:SetSmoothing("OUT")
    row.flashAnim = ag
    row.mark = row:CreateTexture(nil, "ARTWORK")
    row.mark:SetSize(16, 16)
    row.mark:SetPoint("LEFT", 8, 0)
    row.mugBg = UI:Tex(row, "ARTWORK", { 0.02, 0.02, 0.03, 1 })
    row.mugBg:SetSize(20, 20)
    row.mugBg:SetPoint("LEFT", 30, 0)
    row.mug = row:CreateTexture(nil, "ARTWORK", nil, 1)
    row.mug:SetPoint("TOPLEFT", row.mugBg, "TOPLEFT", 1, -1)
    row.mug:SetPoint("BOTTOMRIGHT", row.mugBg, "BOTTOMRIGHT", -1, 1)
    row.name = UI:Text(row, 12, "text", "ui")
    row.name:SetPoint("LEFT", 58, 0)
    row.name:SetWidth(W - 58 - 64)
    row.right = UI:Text(row, 11, "gold", "num")
    row.right:SetPoint("RIGHT", -8, 0)
    row.right:SetJustifyH("RIGHT")
    row:SetScript("OnEnter", function(self) self.hl:SetAlpha(0.7) rowTip(self) end)
    row:SetScript("OnLeave", function(self) self.hl:SetAlpha(0) UI:HideTip() end)
    -- only reached when the row has no secure button over it (turned up mid-fight, or a preview)
    row:SetScript("OnClick", function(self, button)
        local e = self.e
        if not e then return end
        if button == "RightButton" then return poster(not e.fake and e.name or nil) end
        if e.fake then return GF:Print("Just a preview: on the real thing a click targets them and marks them.") end
        if fight() then GF:Print(("Can't hand you a target mid-fight: once it's over, click %s again."):format(e.name)) end
    end)
    return row
end

local function build()
    f = CreateFrame("Frame", "GreenfieldsWantedNearby", UIParent)
    f:SetSize(W, HEAD)
    f:SetFrameStrata("HIGH")
    f:SetFrameLevel(30)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:Hide()
    place()
    f.bg = UI:Tex(f, "BACKGROUND", { 0.035, 0.047, 0.075, 0.92 })
    f.bg:SetAllPoints()
    UI:Shadow(f, 10)
    f.edge = UI:Nine(f, "inset", "BORDER")
    f.head = CreateFrame("Frame", nil, f)
    f.head:SetPoint("TOPLEFT")
    f.head:SetPoint("TOPRIGHT")
    f.head:SetHeight(HEAD)
    f.head:EnableMouse(true)
    f.head:RegisterForDrag("LeftButton")
    f.head.bg = UI:Tex(f.head, "BACKGROUND", { 0.45, 0.07, 0.06, 0.55 }, 1)
    f.head.bg:SetAllPoints()
    f.head.line = UI:Tex(f.head, "BORDER", T.c.red)
    f.head.line:SetPoint("BOTTOMLEFT")
    f.head.line:SetPoint("BOTTOMRIGHT")
    f.head.line:SetHeight(1)
    f.skull = f.head:CreateTexture(nil, "ARTWORK")
    f.skull:SetSize(13, 13)
    f.skull:SetPoint("LEFT", 9, 0)
    UI:SetIcon(f.skull, "skull")
    f.skull:SetVertexColor(1, 0.45, 0.42, 1)
    f.title = UI:Text(f.head, 10, "text", "ui")
    f.title:SetPoint("LEFT", f.skull, "RIGHT", 6, 0)
    f.title:SetText("WANTED NEARBY")
    f.count = UI:Text(f.head, 10, "dim", "num")
    f.count:SetPoint("RIGHT", -9, 0)
    f.count:SetJustifyH("RIGHT")
    f.head:SetScript("OnDragStart", function()
        if fight() then return end
        f:StartMoving()
    end)
    f.head:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        savePlace()
        place()
        arm()
    end)
    f.head:SetScript("OnEnter", function(self)
        UI:Tip(self, "Wanted nearby", { "Click a name to target them and mark them. Right-click for their poster.",
            "Drag this bar to move the list." }, "ANCHOR_BOTTOM")
    end)
    f.head:SetScript("OnLeave", function() UI:HideTip() end)
    f.rows = {}
    for i = 1, MAX_ROWS do f.rows[i] = makeRow(i) end
    f.more = UI:Text(f, 10, "dim", "ui")
    f.more:SetPoint("BOTTOMLEFT", 10, 3)
    -- every second it's up: look round again (a nameplate that just sits there fires nothing)
    f.tick = 0
    f:SetScript("OnUpdate", function(self, elapsed)
        self.tick = self.tick + elapsed
        if self.tick < 1 then return end
        self.tick = 0
        GF:Safe("wanted:nearby", function()
            if not previewing() then N:Rescan() end
            render()
        end)
    end)
end

local function fill(row, e)
    row.e = e
    local p = e.p or {}
    if e.here and e.mark then
        row.mark:SetTexture(MARK_TEX:format(e.mark))
        row.mark:SetTexCoord(0, 1, 0, 1)
        row.mark:SetVertexColor(1, 1, 1, 1)
        row.mark:SetSize(16, 16)
    else
        UI:SetIcon(row.mark, "eye")
        row.mark:SetVertexColor(0.75, 0.73, 0.69, 0.7)
        row.mark:SetSize(13, 13)
    end
    local path, l, r, t, b = N:Mug(p)
    if path then
        row.mug:SetTexture(path)
        row.mug:SetTexCoord(l, r, t, b)
    else
        row.mug:SetColorTexture(0.2, 0.17, 0.13, 1)
    end
    row.name:SetText("|cff" .. U.ClassColorHex(p.class) .. e.name .. "|r")
    if e.gone then
        row.right:SetText("gone")
        UI:SetTextColor(row.right, "dim")
    else
        row.right:SetText(("%d pt%s"):format(tonumber(p.bounty) or 0, (tonumber(p.bounty) or 0) == 1 and "" or "s"))
        UI:SetTextColor(row.right, "gold")
    end
    row:SetAlpha(e.gone and 0.4 or (e.here and 1 or 0.72))
    row:Show()
end

--- Redraws the list. Out of a fight it's whoever's about, in order; in a fight the rows stay put.
render = function()
    if not f then
        if #live() == 0 then return end
        build()
    end
    local list = live()
    local rows
    if fight() and #shown > 0 then
        local now = {}
        for _, e in ipairs(list) do now[e.name] = e end
        rows = {}
        for i, e in ipairs(shown) do
            rows[i] = now[e.name] or { name = e.name, p = e.p, here = e.here, mark = e.mark, by = e.by,
                zone = e.zone, t = e.t, gone = true }
            now[e.name] = nil
        end
        for _, e in ipairs(list) do
            if now[e.name] then rows[#rows + 1] = e end
        end
    else
        rows = list
    end
    local count = 0
    for _, e in ipairs(rows) do if not e.gone then count = count + 1 end end
    if count == 0 then
        shown = {}
        f:Hide()
        arm()
        return
    end
    shown = {}
    local n = min(#rows, MAX_ROWS)
    for i = 1, MAX_ROWS do
        if i <= n then
            shown[i] = rows[i]
            fill(f.rows[i], rows[i])
        else
            f.rows[i].e = nil
            f.rows[i]:Hide()
        end
    end
    local extra = #rows - n
    f.more:SetText(extra > 0 and ("+%d more"):format(extra) or "")
    f.more:SetShown(extra > 0)
    f:SetHeight(HEAD + n * ROW + (extra > 0 and MORE or 4))
    f.count:SetText(count)
    if not f:IsShown() then
        f:Show()
        UI:FadeIn(f, 0.15)
    end
    arm()
end
local function renderSafe() GF:Safe("wanted:nearby", render) end

-------------------------------------------------------------------------------
-- Wiring
-------------------------------------------------------------------------------
GF:On("GF_WANTED_NEAR", function(e)
    renderSafe()
    if not f or not f:IsShown() then return end
    for i, s in ipairs(shown) do
        if e and s.name == e.name then flash(f.rows[i]) end
    end
    local now = API.Time()
    if now - soundAt >= SOUND_GAP and settings().toastSounds ~= false then
        soundAt = now
        API.PlaySound(SOUND)
    end
end)
GF:On("GF_WANTED_CHANGED", renderSafe)
GF:On("GF_WANTED_SNOOZE", renderSafe)
GF:On("GF_SETTING_CHANGED", renderSafe)
GF:RegisterEvent("PLAYER_REGEN_ENABLED", function()
    if not f then return end
    shown = {}   -- the fight's over: reshuffle, and set up anyone who turned up during it
    renderSafe()
end, "NemesisNearby")
for _, ev in ipairs({ "UI_SCALE_CHANGED", "DISPLAY_SIZE_CHANGED" }) do
    GF:RegisterEvent(ev, function() if f then GF:After(0.2, function() GF:Safe("wanted:nearby", arm) end) end end, "NemesisNearby")
end

--- A preview with made-up names, for 15 seconds: to see it, or to drag it where you want it.
function N:PreviewNearby()
    previewUntil = API.Time() + 15
    renderSafe()
    GF:After(15.2, renderSafe)
end

--- For the tests: the list, its rows and their secure buttons.
function N:NearbyFrames() return f, slots, shown end
