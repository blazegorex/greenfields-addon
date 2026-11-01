--[[ Greenfields - Modules/HallOfFame.lua
     The Hall of Fame page: who wears which crown, who's carrying which shame, the full
     standings for every stat, and your own badge collection.

     Tabs: Hall of Fame / Hall of Shame (a grid of title cards), Leaderboards (one stat,
     every main ranked), My Badges (earned chips + progress toward the next milestone).
     The All time / This week control on the tab row switches the scope. Wealth is a rank
     stat: the page only ever shows positions, never amounts.

     The look is the trophy cabinet: each title card is a quiet panel with the title's art,
     its name in Morpheus (gold for fame, red for shame) and the holder engraved on a carved
     plate below. Unclaimed titles sit greyed out like an unearned achievement. Gold is
     rationed: only a crown you hold gets the gold frame and the light sweep.

     All data comes from GF.Stats (Modules/Stats.lua); every call is guarded so the page
     degrades to its empty states if stats are missing. ]]

local _, GF = ...
local API, U, UI, T = GF.API, GF.Util, GF.UI, GF.Theme
local C = T.c

local Fame = GF:NewModule("HallOfFame")

local type, pairs, ipairs, tostring = type, pairs, ipairs, tostring
local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min

local GUTTER = 16
local PAD = 12              -- card padding
local ART = 52              -- the trophy on a title card
local ART_NARROW = 44
local PLATE_H = 44          -- the holder's engraved plate
local FOOT_H = 30           -- room under the plate for the runners-up
local INTRO_H = 22          -- the "you wear N crowns" line above the grid
local ROW_H = 44
local HERO_H = 84           -- leaderboard banner
local HERO_ART = 52
local DD_W = 210
local CHIP_H = 32
local CHIP_ART = 24
local NEXT_H = 56
local NEXT_ART = 32
local VALUE_W = 120
local BAR_END = 12 + 56 + 12   -- where a standings bar stops: short of a number, not of "amount classified"
local STANDINGS_CHROME = 48    -- the Standings card's header and bottom padding around its body
local NOTE_H = 22              -- the footnote under the standings
local PICK_W, PICK_ROW = 244, 22
-- Morpheus only reads at 18 and up, so a title too long for that drops to Friz instead of shrinking
local TITLE_SIZES = { 20, 18 }
local HERO_SIZES = { 22, 20, 18 }
local SILVER = { 0.78, 0.80, 0.84, 1 }
local BRONZE = { 0.82, 0.56, 0.34, 1 }
local SHAME = { 0.96, 0.42, 0.42, 1 }     -- the Hall of Shame's ink
local FLAVOR = { 0.80, 0.74, 0.58, 1 }    -- quest-text tan for the roast/brag lines

local TABS = {
    { key = "fame", text = "Hall of Fame", icon = "crown" },
    { key = "shame", text = "Hall of Shame", icon = "skull" },
    { key = "boards", text = "Leaderboards", icon = "trophy" },
    { key = "badges", text = "My Badges", icon = "star" },
}
local TAB_KEYS = { fame = true, shame = true, boards = true, badges = true }

local LINES = {
    fameNone = "Nobody's earned a crown yet. The bar's on the floor, legends. Step over it.",
    shameNone = "No shame on record. Either we're all angels or nobody's running the addon.",
    board = "Nobody's on this board yet. Someone get out there and embarrass themselves.",
    badges = "No badges yet. Even the staffy's got one.",
    next = "Every badge collected. Go touch grass, you absolute weapon.",
    noStats = "The stats tracker isn't loaded. Something's cooked - try /gf errors.",
}

-------------------------------------------------------------------------------
-- Guarded data access
-------------------------------------------------------------------------------
local function S()
    local s = GF.Stats
    if s and s.Board and s.Format then return s end
    return nil
end

local function stat(method, ...)
    local s = S()
    if not s or type(s[method]) ~= "function" then return nil end
    local ok, a, b, c, d = GF:Safe("fame:" .. method, s[method], s, ...)
    if ok then return a, b, c, d end
    return nil
end

local function board(key, scope) return stat("Board", key, scope) or {} end
local function fmt(key, value, rank) return stat("Format", key, value, rank) or "" end

local function rosterCall(method, key)
    local R = GF.Roster
    if not (R and type(R[method]) == "function") then return nil end
    local ok, res = pcall(R[method], R, key)
    if ok then return res end
    return nil
end

local function colored(key)
    local s = rosterCall("Colored", key)
    return type(s) == "string" and s or U.ShortName(key)
end

local function classOf(key) return rosterCall("Class", key) end

local function myMain()
    local me = API.MyKey()
    if not me then return nil end
    local m = rosterCall("MainOf", me)
    return type(m) == "string" and m or me
end

local function accentOf(def)
    return def.group == "fame" and C.wowGold or SHAME
end

--- The title's painted/game art, falling back to its line icon.
local function artOf(def)
    if not def then return "trophy" end
    return def.art or def.icon or "trophy"
end

local function paint(c, s) return U.Color(s, c[1], c[2], c[3]) end

local function scopeLabel(scope) return scope == "week" and "This week" or "All time" end

--- Re-lays out a scroll child only when its width changes (our own SetContentHeight calls
-- resize its height, which must not loop back into the layout).
local function onWidthChanged(frame, label, fn)
    frame:SetScript("OnSizeChanged", function(self, w)
        w = floor((w or self:GetWidth() or 0) + 0.5)
        if w == self.gfLastWidth then return end
        self.gfLastWidth = w
        GF:Safe(label, fn)
    end)
end

--- Soft horizontal wash: colour at the left fading out to the right.
local function setWash(t, c, a) UI:Gradient(t, "HORIZONTAL", c[1], c[2], c[3], a, 0) end

local function titleShadow(fs)
    if fs.SetShadowOffset then
        fs:SetShadowOffset(1.5, -1.5)
        fs:SetShadowColor(0, 0, 0, 0.95)
    end
end

--- Sets the largest Morpheus size at which the text takes at most `lines` lines in `w`; past
-- the last size it falls back to Friz, which stays readable small.
local function fitTitle(fs, w, sizes, lines, fallback)
    fs:SetWidth(w)
    local canMeasure = fs.SetMaxLines and fs.GetNumLines
    local fitted = false
    for i = 1, #sizes do
        T:Font(fs, "title", sizes[i])
        if not canMeasure then
            fitted = true
            break
        end
        fs:SetMaxLines(0)
        local n = tonumber(fs:GetNumLines()) or 1
        fs:SetMaxLines(lines)
        if n <= lines then
            fitted = true
            break
        end
    end
    if not fitted then T:Font(fs, "ui", fallback or 14) end
    titleShadow(fs)
end

-------------------------------------------------------------------------------
-- Title cards (Hall of Fame / Hall of Shame)
-------------------------------------------------------------------------------
local function openBoard(page, statKey)
    page.stat = statKey
    page.tab = "boards"
    page.shineDue = true
    page.tabs:Select("boards")
end

local function makeCard(parent, page)
    local c = CreateFrame("Button", nil, parent)
    c.skin = UI:Nine(c, "card", "BACKGROUND", -6)
    -- a pool of light behind the trophy, kept inside the panel
    c.glow = c:CreateTexture(nil, "BACKGROUND", nil, 1)
    c.glow:SetTexture(T.tex.glow)
    c.glow:SetBlendMode("ADD")
    -- a crown you hold: warm light falling from a fine gold edge along the top
    c.heldWash = c:CreateTexture(nil, "BACKGROUND", nil, 0)
    c.heldWash:SetPoint("TOPLEFT", 1, -1)
    c.heldWash:SetPoint("TOPRIGHT", -1, -1)
    c.heldWash:SetHeight(64)
    UI:Gradient(c.heldWash, "VERTICAL", C.wowGold[1], C.wowGold[2], 0.3, 0, 0.09)
    c.heldLine = UI:Hairline(c, "wowGold", 0.85, "none")
    c.heldLine:SetPoint("TOPLEFT", 4, -1)
    c.heldLine:SetPoint("TOPRIGHT", -4, -1)
    c.hl = c:CreateTexture(nil, "BACKGROUND", nil, 2)
    c.hl:SetPoint("TOPLEFT", 1, -1)
    c.hl:SetPoint("BOTTOMRIGHT", -1, 1)
    c.hl:SetColorTexture(1, 0.9, 0.6, 0.04)
    c.hl:SetBlendMode("ADD")
    c.hl:Hide()

    -- header: the art, with the title and what it's for beside it (positions in layoutCard)
    c.art = UI:FramedIcon(c, ART)
    c.title = UI:Text(c, 18, "wowGold", "title")
    c.title:SetWordWrap(true)
    c.title:SetJustifyV("TOP")
    c.label = UI:Para(c, 11, "dim")
    c.label:SetPoint("TOPLEFT", c.title, "BOTTOMLEFT", 0, -3)
    c.blurb = UI:Para(c, 11, FLAVOR)

    -- the engraved plate: who holds it
    c.plate = UI:Well(c)
    c.plate:SetHeight(PLATE_H)
    c.plate:SetPoint("BOTTOMLEFT", PAD, FOOT_H)
    c.plate:SetPoint("BOTTOMRIGHT", -PAD, FOOT_H)
    c.avatar = UI:Avatar(c.plate, 28)
    c.avatar:SetPoint("LEFT", 8, 0)
    c.vacant = UI:Icon(c.plate, 16, "crown", "ARTWORK", { C.bronze[1], C.bronze[2], C.bronze[3], 0.6 })
    c.vacant:SetPoint("LEFT", 14, 0)
    c.name = UI:Text(c.plate, 13, "text", "ui")
    c.value = UI:Text(c.plate, 12, "text", "num")
    c.value:SetPoint("TOPLEFT", c.name, "BOTTOMLEFT", 0, -3)
    c.you = UI:Pill(c.plate, "YOU", "gold", { height = 16, size = 10 })
    c.you:SetPoint("RIGHT", -8, 0)

    c.runners = UI:Text(c, 11, "dim")
    c.runners:SetPoint("BOTTOMLEFT", PAD, 10)
    c.allTime = UI:Pill(c, "ALL TIME", "dim", { height = 16, size = 10 })
    c.allTime:SetPoint("BOTTOMRIGHT", -PAD, 8)

    c:RegisterForClicks("LeftButtonUp")
    c:SetScript("OnEnter", function(self)
        self.hl:Show()
        if self.def then UI:Tip(self, self.def.title, { self.def.label, T:Wrap("dim", "Click for the full leaderboard.") }) end
    end)
    c:SetScript("OnLeave", function(self)
        self.hl:Hide()
        UI:HideTip()
    end)
    c:SetScript("OnClick", function(self)
        UI.Sound(841)
        if self.def then GF:Safe("fame:card", openBoard, page, self.def.key) end
    end)
    return c
end

--- Sizes the art and the title block for a card `cw` wide and returns the height they need.
-- The art stays pinned to the top so it lines up across a grid row, whatever the title does.
local function layoutCardHead(c, cw)
    local icon = cw >= 230 and ART or ART_NARROW
    if c.iconSize ~= icon then
        c.iconSize = icon
        c.art:SetSize(icon, icon)
    end
    local tx = PAD + icon + 10
    local tw = max(40, floor(cw - tx - PAD))
    fitTitle(c.title, tw, TITLE_SIZES, 2)
    c.label:SetWidth(tw)
    local titleH = c.title:GetStringHeight() or 20
    local labelH = c.label:GetStringHeight() or 13
    local textH = titleH + 3 + labelH
    c.art:ClearAllPoints()
    c.art:SetPoint("TOPLEFT", c, "TOPLEFT", PAD, -PAD)
    c.glow:ClearAllPoints()
    c.glow:SetPoint("CENTER", c.art, "CENTER", 0, 0)
    c.glow:SetSize(icon * 1.5, icon * 1.5)
    c.title:ClearAllPoints()
    c.title:SetPoint("TOPLEFT", c, "TOPLEFT", tx, -(PAD + floor(max(0, icon - textH) / 2 + 0.5)))
    return max(icon, textH)
end

--- Places the rest of a card under a header `headH` tall (the tallest in its row, so the roasts
-- start level) and returns the height it needs: nothing on a card truncates, so a row of the
-- grid is as tall as its wordiest card.
local function layoutCard(c, cw, headH)
    c.blurb:ClearAllPoints()
    c.blurb:SetPoint("TOPLEFT", c, "TOPLEFT", PAD, -(PAD + headH + 8))
    c.blurb:SetWidth(max(40, floor(cw - PAD * 2)))
    local blurbH = c.blurb:GetStringHeight() or 13

    -- the plate: name and value stacked, or one line when it's up for grabs
    local plateW = cw - PAD * 2
    local nx = c.claimed and 44 or 38
    local nw = max(30, floor(plateW - nx - 8 - (c.you:IsShown() and (c.you:GetWidth() + 8) or 0)))
    c.name:ClearAllPoints()
    if c.claimed then
        c.name:SetPoint("TOPLEFT", c.plate, "TOPLEFT", nx, -7)
    else
        c.name:SetPoint("LEFT", c.plate, "LEFT", nx, 0)
    end
    c.name:SetWidth(nw)
    c.value:SetWidth(nw)
    c.runners:SetWidth(max(30, floor(cw - PAD * 2 - (c.allTime:IsShown() and (c.allTime:GetWidth() + 8) or 0))))

    return ceil(PAD + headH + 8 + blurbH + 10 + PLATE_H + FOOT_H)
end

local function runnersText(def, list)
    local parts = {}
    for i = 2, 3 do
        local e = list[i]
        if e then
            local s = T:Wrap("dim", "#" .. i) .. " " .. colored(e.key)
            if def.kind ~= "rank" then s = s .. " " .. T:Wrap("dim", fmt(def.key, e.value)) end
            parts[#parts + 1] = s
        end
    end
    if #parts == 0 then return "No runners-up yet." end
    return table.concat(parts, "    ")
end

local function updateCard(c, def, scope, mine)
    local list = board(def.key, scope)
    local top = stat("Crown", def.key, scope)
    local accent = accentOf(def)
    c.def, c.accent = def, accent
    c.claimed = top ~= nil
    c.held = (mine ~= nil and top ~= nil and top.key == mine) and true or false
    -- an unclaimed title reads like an unearned achievement: greyed art. Gold is for yours alone.
    c.art:SetIcon(artOf(def))
    c.art:SetTone(c.held and "gold" or nil)
    c.art:SetDesaturated(top == nil)
    c.art:SetAlpha(top and 1 or 0.65)
    c.glow:SetVertexColor(accent[1], accent[2], accent[3], c.held and 0.42 or (top and 0.16 or 0.05))
    c.heldWash:SetShown(c.held)
    c.heldLine:SetShown(c.held)
    c.title:SetText(tostring(def.title))
    c.title:SetTextColor(accent[1], accent[2], accent[3], 1)
    c.label:SetText(def.label or "")
    c.allTime:SetShown(scope == "week" and stat("HasWeekly", def.key) == false)
    c.you:SetShown(c.held)
    c.avatar:SetShown(top ~= nil)
    c.vacant:SetShown(top == nil)
    c.value:SetShown(top ~= nil)
    if top then
        c.avatar:SetClass(classOf(top.key))
        c.name:SetText(colored(top.key))
        c.value:SetText(fmt(def.key, top.value, top.rank))
        c.runners:SetText(runnersText(def, list))
    else
        c.name:SetText(T:Wrap("dim", "Up for grabs"))
        -- no holder means no runners-up to name, so the cheeky line gets their spot
        c.runners:SetText(def.group == "fame" and "Nobody's claimed it. Yet." or "Clean slate. Enjoy it while it lasts.")
    end
    c.blurb:SetText('"' .. (def.blurb or "") .. '"')
end

local function buildGrid(page)
    local v = CreateFrame("Frame", nil, page.body)
    v:SetAllPoints(page.body)
    local scroll, content = UI:Scroll(v, { outside = true })
    scroll:SetPoint("TOPLEFT")
    scroll:SetPoint("BOTTOMRIGHT")
    v.scroll, v.content = scroll, content
    v.intro = UI:Text(content, 12, "dim")
    v.intro:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -3)
    v.intro:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -3)
    v.cards, v.defs = {}, {}
    onWidthChanged(content, "fame:layout", function() Fame:LayoutGrid(page) end)
    return v
end

--- Full intro when it fits, the short one otherwise.
local function fitIntro(v, w)
    v.intro:SetText(v.introFull or "")
    local uw = v.intro.GetUnboundedStringWidth and v.intro:GetUnboundedStringWidth() or 0
    if v.introShort and (tonumber(uw) or 0) > w - 4 then v.intro:SetText(v.introShort) end
end

function Fame:LayoutGrid(page)
    local v = page.views.grid
    if not v then return end
    local w = v.content:GetWidth() or 0
    if w < 50 then return end
    local cols = (w >= 1000 and 4) or (w >= 700 and 3) or (w >= 400 and 2) or 1
    local cw = floor((w - (cols - 1) * GUTTER) / cols)
    -- whole units leave a sliver over: the last column takes it, so its edge lands on the page's
    local spare = floor(w - cols * cw - (cols - 1) * GUTTER)
    local y = INTRO_H + 8
    local n = #v.defs
    local i = 1
    while i <= n do
        local headH, rowH = 0, 0
        local last = min(n, i + cols - 1)
        for k = i, last do headH = max(headH, layoutCardHead(v.cards[k], cw)) end
        for k = i, last do rowH = max(rowH, layoutCard(v.cards[k], cw, headH)) end
        for k = i, last do
            local c = v.cards[k]
            c:ClearAllPoints()
            c:SetPoint("TOPLEFT", v.content, "TOPLEFT", (k - i) * (cw + GUTTER), -y)
            c:SetSize(k - i == cols - 1 and cw + spare or cw, rowH)
        end
        y = y + rowH + GUTTER
        i = i + cols
    end
    v.scroll:SetContentHeight(y)
    fitIntro(v, w)
end

--- The line above the grid -> full text, short text (no names) for when the full one won't fit.
local function introLine(group, held, anyHolder)
    if not anyHolder then
        local s = group == "fame" and LINES.fameNone or LINES.shameNone
        return s, s
    end
    local n = #held
    local shown = {}
    for i = 1, min(n, 2) do shown[i] = held[i].title end
    local names = table.concat(shown, ", ") .. (n > 2 and (" +" .. (n - 2) .. " more") or "")
    if group == "fame" then
        if n == 0 then
            local s = "No crowns for you on this side. Yet. Have a crack."
            return s, s
        end
        local plural = n == 1 and "" or "s"
        return ("You wear %d crown%s here: %s. Absolute royalty."):format(n, plural, paint(C.wowGold, names)),
            ("You wear %d crown%s here. Absolute royalty."):format(n, plural)
    end
    if n == 0 then
        local s = "Your record's clean. For now. We're watching."
        return s, s
    end
    return ("You're the proud owner of %d: %s. Nobody tell your mum."):format(n, paint(SHAME, names)),
        ("You're the proud owner of %d. Nobody tell your mum."):format(n)
end

--- A light sweep across each crown you hold: when the grid is opened (page shown, tab or
-- scope switched) and whenever a crown newly lands on you. Plain data refreshes stay calm.
local function shineHeld(page, v)
    local due = page.shineDue
    page.shineDue = false
    local n = 0
    for i = 1, #v.defs do
        local c = v.cards[i]
        if c.held and (due or not c.wasHeld) and n < 6 then
            n = n + 1
            GF:After(0.25 + n * 0.2, function()
                if c.held and c:IsVisible() then UI:Shine(c, 1.0) end
            end)
        end
        c.wasHeld = c.held
    end
end

local function renderGrid(page, group)
    local v = page.views.grid
    local defs = {}
    for _, def in ipairs(GF.Titles) do
        if def.group == group then defs[#defs + 1] = def end
    end
    v.defs = defs
    local mine = myMain()
    local held, anyHolder = {}, false
    for i, def in ipairs(defs) do
        local c = v.cards[i]
        if not c then
            c = makeCard(v.content, page)
            v.cards[i] = c
        end
        updateCard(c, def, page.scope, mine)
        c:Show()
        local top = stat("Crown", def.key, page.scope)
        if top then
            anyHolder = true
            if top.key == mine then held[#held + 1] = def end
        end
    end
    for i = #defs + 1, #v.cards do v.cards[i]:Hide() end
    if not S() then
        v.introFull, v.introShort = LINES.noStats, nil
    else
        v.introFull, v.introShort = introLine(group, held, anyHolder)
    end
    v.intro:SetText(v.introFull)
    Fame:LayoutGrid(page)
    shineHeld(page, v)
end

-------------------------------------------------------------------------------
-- Leaderboards
-------------------------------------------------------------------------------
--- Every stat for the picker's selected line. The picker itself is laid out by hand below.
local function statItems()
    local out = {}
    for _, def in ipairs(GF.Titles) do
        out[#out + 1] = { text = def.title, value = def.key, icon = artOf(def), color = accentOf(def) }
    end
    return out
end

-- The picker. 32-odd titles overflow the kit's 16-row menu, which hid most of the Hall of Shame
-- below a wheel nobody knew to spin. Fame and shame side by side all fit at once.
local picker, pickerCatcher

local function pickerRow(col)
    local b = CreateFrame("Button", nil, col)
    b:SetHeight(PICK_ROW)
    b.hl = b:CreateTexture(nil, "BACKGROUND")
    b.hl:SetAllPoints()
    b.hl:SetColorTexture(1, 0.82, 0.42, 0.10)
    b.hl:Hide()
    b.art = UI:IconChip(b, 16)
    b.art:SetPoint("LEFT", 6, 0)
    b.text = UI:Text(b, 12, "text")
    b.text:SetPoint("LEFT", 28, 0)
    b.text:SetPoint("RIGHT", -22, 0)
    b.check = UI:Icon(b, 12, "check", "OVERLAY", "gold")
    b.check:SetPoint("RIGHT", -6, 0)
    b:SetScript("OnEnter", function(self) self.hl:Show() end)
    b:SetScript("OnLeave", function(self) self.hl:Hide() end)
    b:SetScript("OnClick", function(self)
        picker:Hide()
        UI.Sound(856)
        if picker.onPick and self.value then GF:Safe("fame:pick", picker.onPick, self.value) end
    end)
    return b
end

local function pickerColumn(x, heading)
    local col = CreateFrame("Frame", nil, picker)
    col:SetPoint("TOPLEFT", x, -8)
    col:SetWidth(PICK_W)
    col.head = UI:SectionLabel(col, heading)
    col.head:SetPoint("TOPLEFT", 6, 0)
    col.head:SetPoint("TOPRIGHT", -6, 0)
    col.rows = {}
    return col
end

local function buildPicker()
    pickerCatcher = CreateFrame("Button", nil, UIParent)
    pickerCatcher:SetFrameStrata("FULLSCREEN")
    pickerCatcher:SetAllPoints(UIParent)
    pickerCatcher:RegisterForClicks("AnyUp")
    pickerCatcher:SetScript("OnClick", function() picker:Hide() end)
    pickerCatcher:Hide()
    picker = CreateFrame("Frame", "GreenfieldsStatPicker", UIParent)
    picker:SetFrameStrata("FULLSCREEN_DIALOG")
    picker:SetClampedToScreen(true)
    UI:Shadow(picker, 10)
    picker.rim = UI:Nine(picker, "card", "BACKGROUND", -6)
    -- the card art is see-through; a menu over a table can't be, or the numbers ghost through it
    picker.fill = picker:CreateTexture(nil, "BACKGROUND", nil, -7)
    picker.fill:SetPoint("TOPLEFT", 2, -2)
    picker.fill:SetPoint("BOTTOMRIGHT", -2, 2)
    picker.fill:SetColorTexture(0.055, 0.075, 0.11, 1)
    picker:Hide()
    tinsert(UISpecialFrames, "GreenfieldsStatPicker")
    picker:SetScript("OnHide", function() pickerCatcher:Hide() end)
    picker.fame = pickerColumn(8, "Hall of Fame")
    picker.shame = pickerColumn(8 + PICK_W + 8, "Hall of Shame")
end

local function fillPickerColumn(col, group, selected)
    local n = 0
    for _, def in ipairs(GF.Titles) do
        if def.group == group then
            n = n + 1
            local b = col.rows[n]
            if not b then
                b = pickerRow(col)
                b:SetPoint("TOPLEFT", 0, -(20 + (n - 1) * PICK_ROW))
                b:SetPoint("TOPRIGHT", 0, -(20 + (n - 1) * PICK_ROW))
                col.rows[n] = b
            end
            local accent = accentOf(def)
            b.value = def.key
            b.art:SetIcon(artOf(def))
            b.text:SetText(tostring(def.title))
            b.text:SetTextColor(accent[1], accent[2], accent[3], 1)
            b.check:SetShown(def.key == selected)
            b:Show()
        end
    end
    for i = n + 1, #col.rows do col.rows[i]:Hide() end
    return n
end

--- `within` is the frame it has to stay inside: it hangs off the dropdown, and rides up over it
-- rather than running out the bottom of the window.
local function togglePicker(anchor, within, selected, onPick)
    if not picker then buildPicker() end
    if picker:IsShown() then
        picker:Hide()
        return
    end
    picker.onPick = onPick
    local rows = max(fillPickerColumn(picker.fame, "fame", selected), fillPickerColumn(picker.shame, "shame", selected))
    local h = 8 + 20 + rows * PICK_ROW + 8
    picker.fame:SetHeight(h - 16)
    picker.shame:SetHeight(h - 16)
    picker:SetSize(8 + PICK_W * 2 + 8 + 8, h)
    picker:ClearAllPoints()
    local room = ((anchor:GetBottom() or 0) - (within:GetBottom() or 0)) * anchor:GetEffectiveScale() / picker:GetEffectiveScale()
    picker:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -4 + max(0, h + 4 - room))
    pickerCatcher:Show()
    picker:Show()
    picker:Raise()
end

local function createBoardRow(row)
    -- the leader's row gets an accent wash and wears the title's art instead of "#1"
    row.lead = row:CreateTexture(nil, "BACKGROUND", nil, 3)
    row.lead:SetPoint("TOPLEFT")
    row.lead:SetPoint("BOTTOMLEFT")
    row.lead:SetWidth(260)
    row.lead:SetTexture(T.tex.white)
    row.lead:Hide()
    row.rank = UI:Text(row, 18, "dim", "title")
    row.rank:SetPoint("LEFT", 6, 0)
    row.rank:SetWidth(36)
    row.rank:SetJustifyH("CENTER")
    row.art = UI:FramedIcon(row, 32)
    row.art:SetPoint("LEFT", 8, 0)
    row.art:Hide()
    row.avatar = UI:Avatar(row, 28)
    row.avatar:SetPoint("LEFT", 50, 0)
    row.value = UI:Text(row, 13, "text", "num")
    row.value:SetPoint("RIGHT", -12, 0)
    row.value:SetWidth(VALUE_W)
    row.value:SetJustifyH("RIGHT")
    row.name = UI:Text(row, 13, "text", "ui")
    row.you = UI:Pill(row, "YOU", "gold", { height = 16, size = 10 })
    row.you:SetPoint("LEFT", row.name, "RIGHT", 6, 0)
    -- bottom-aligned with the avatar, stopping just short of the number
    row.bar = UI:Bar(row, { height = 6 })
    row.bar:SetPoint("BOTTOMLEFT", row.avatar, "BOTTOMRIGHT", 10, 1)
    row.bar:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -BAR_END, 9)
end

local function updateBoardRow(row, item, page)
    local def = GF.TitlesByKey[page.stat]
    if not def then return end
    local accent = accentOf(def)
    -- top of the board without the crown yet is just #1
    local lead = item.key == page.crownKey
    local podium = item.rank == 2 or item.rank == 3
    local rc = (item.rank == 2 and SILVER) or (item.rank == 3 and BRONZE) or C.dim
    -- the podium in Morpheus; everyone below it is just a number in a ledger
    if podium then T:Font(row.rank, "title", 18) else T:Font(row.rank, "num", 14) end
    row.rank:SetText("#" .. tostring(item.rank))
    row.rank:SetTextColor(rc[1], rc[2], rc[3], 1)
    row.rank:SetShown(not lead)
    row.art:SetShown(lead)
    -- your own row already wears the list's gold selection; a second wash on top is too much
    row.lead:SetShown(lead and item.key ~= page.mine)
    if lead then
        row.art:SetIcon(artOf(def))
        row.art:SetTone(item.key == page.mine and "gold" or nil)
        setWash(row.lead, accent, 0.09)
    end
    row.avatar:SetClass(classOf(item.key))
    row.name:SetText(colored(item.key))
    row.you:SetShown(item.key == page.mine)
    -- the name rides above the bar; a rank stat has no bar, so it centres on the avatar instead
    row.name:ClearAllPoints()
    if def.kind == "rank" then
        row.name:SetPoint("LEFT", row.avatar, "RIGHT", 10, 0)
    else
        row.name:SetPoint("TOPLEFT", row.avatar, "TOPRIGHT", 10, 0)
    end
    if def.kind == "rank" then
        row.value:SetText(T:Wrap("dim", "amount classified"))
        row.bar:Hide()
    else
        row.value:SetText(fmt(def.key, item.value))
        local top = page.boardLead or 0
        row.bar:SetColor({ accent[1], accent[2], accent[3], item.rank <= 3 and 0.9 or 0.5 })
        row.bar:Show()
        row.bar:SetValue(top > 0 and (item.value or 0) / top or 0)
    end
end

--- The banner over the standings: the chosen title on show in the page's one gold rim.
local function buildHero(v)
    local h = UI:Card(v, { tier = "hero" })
    h:SetPoint("TOPLEFT")
    h:SetPoint("TOPRIGHT")
    h:SetHeight(HERO_H)
    h.wash = h:CreateTexture(nil, "BACKGROUND", nil, 2)
    h.wash:SetPoint("TOPLEFT", 3, -3)
    h.wash:SetPoint("BOTTOMLEFT", 3, 3)
    h.wash:SetWidth(320)
    h.glow = h:CreateTexture(nil, "BACKGROUND", nil, 3)
    h.glow:SetTexture(T.tex.glow)
    h.glow:SetBlendMode("ADD")
    h.art = UI:FramedIcon(h, HERO_ART)
    h.art:SetPoint("LEFT", 16, 0)
    h.glow:SetPoint("CENTER", h.art, "CENTER", 0, 0)
    h.glow:SetSize(HERO_H - 6, HERO_H - 6)

    local tx = 16 + HERO_ART + 14
    h.title = UI:Text(h, 22, "wowGold", "title")
    h.title:SetWordWrap(true)     -- fitTitle measures its wrapped lines, then holds it to one
    h.title:SetPoint("TOPLEFT", h, "TOPLEFT", tx, -13)
    titleShadow(h.title)
    h.label = UI:Text(h, 12, "dim")
    h.label:SetPoint("TOPLEFT", h.title, "BOTTOMLEFT", 0, -4)
    h.blurb = UI:Text(h, 12, FLAVOR)
    h.blurb:SetPoint("TOPLEFT", h.label, "BOTTOMLEFT", 0, -4)
    function h:Fit()
        local w = max(60, floor((self:GetWidth() or 0) - tx - 16))
        fitTitle(self.title, w, HERO_SIZES, 1, 17)
        self.label:SetWidth(w)
        self.blurb:SetWidth(w)
    end
    h:SetScript("OnSizeChanged", function(self) GF:Safe("fame:hero", self.Fit, self) end)
    return h
end

--- The card ends where the standings do, so one name on a board isn't a name in an empty hall.
-- Empty boards keep the full height: the empty block is centred in it.
local function fitStandings(v)
    local avail = (v:GetHeight() or 0) - HERO_H - GUTTER
    if avail < 100 then return end
    local n = #v.list.items
    local need = STANDINGS_CHROME + n * ROW_H + NOTE_H + 1
    v.card:SetHeight(n > 0 and min(avail, need) or avail)
end

local function buildBoards(page)
    local v = CreateFrame("Frame", nil, page.body)
    v:SetAllPoints(page.body)
    v.hero = buildHero(v)

    v.card = UI:Card(v, { title = "Standings", icon = "trophy", subtitle = " " })
    v.card:SetPoint("TOPLEFT", v.hero, "BOTTOMLEFT", 0, -GUTTER)
    v.card:SetPoint("TOPRIGHT", v.hero, "BOTTOMRIGHT", 0, -GUTTER)
    if v.card.subtitle then UI:SetTextColor(v.card.subtitle, "dim") end
    -- the picker belongs to the table it drives, not to the plate showing what it picked
    v.dd = UI:Dropdown(v.card, {
        width = DD_W, height = 24, items = statItems,
        get = function() return page.stat end,
        tooltip = "Pick a stat to see everyone's standing.",
    })
    v.dd:SetPoint("TOPRIGHT", v.card, "TOPRIGHT", -12, -4)
    v.dd:SetScript("OnClick", function(self)
        UI.Sound(856)
        togglePicker(self, page, page.stat, function(value)
            page.stat = value
            Fame:RenderBoards(page)
        end)
    end)
    v.note = UI:Text(v.card.body, 11, "dim")
    v.note:SetPoint("BOTTOMLEFT", 0, 2)
    v.note:SetPoint("BOTTOMRIGHT", 0, 2)
    v.note:SetText("Self-reported by Greenfields users. Alts roll up to their mains.")

    v.list = UI:List(v.card.body, {
        rowHeight = ROW_H, spacing = 0,
        createRow = createBoardRow,
        updateRow = function(row, item) updateBoardRow(row, item, page) end,
        isSelected = function(item) return item.key == page.mine end,
        onClick = function(item)
            if UI.OpenProfile then GF:Safe("fame:profile", UI.OpenProfile, UI, item.key) end
        end,
        onEnter = function(row, item)
            local lines = { T:Wrap("dim", "Rank #" .. tostring(item.rank)) }
            if UI.OpenProfile then lines[2] = T:Wrap("dim", "Click to open their file.") end
            UI:Tip(row, colored(item.key), lines)
        end,
    })
    v.list:SetPoint("TOPLEFT", v.card.body, "TOPLEFT", 0, 0)
    -- hung past the body by the 10 the kit's rows leave for a scrollbar: rows finish under the
    -- dropdown, and the bar sits in the card's padding
    v.list:SetPoint("BOTTOMRIGHT", v.card.body, "BOTTOMRIGHT", 10, NOTE_H)
    v.list.bar:ClearAllPoints()
    v.list.bar:SetPoint("TOPRIGHT", -1, 0)
    v.list.bar:SetPoint("BOTTOMRIGHT", -1, 0)
    v.empty = UI:Empty(v.card.body, LINES.board, "trophy", { width = 500 })
    v.empty:Hide()
    v:SetScript("OnSizeChanged", function() GF:Safe("fame:standings", fitStandings, v) end)
    return v
end

function Fame:RenderBoards(page)
    local v = page.views.boards
    local def = GF.TitlesByKey[page.stat]
    if not def then
        def = GF.Titles[1]
        page.stat = def and def.key
    end
    if not def then return end
    v.dd:Refresh()
    local accent = accentOf(def)
    local h = v.hero
    h.art:SetIcon(artOf(def))
    h.title:SetText(tostring(def.title))
    h.title:SetTextColor(accent[1], accent[2], accent[3], 1)
    h.label:SetText(def.label or "")
    h.blurb:SetText('"' .. (def.blurb or "") .. '"')
    h.glow:SetVertexColor(accent[1], accent[2], accent[3], 0.26)
    setWash(h.wash, accent, 0.08)
    h:Fit()
    local sub = scopeLabel(page.scope)
    if page.scope == "week" and stat("HasWeekly", def.key) == false then sub = "All time (no weekly split for this one)" end
    if v.card.subtitle then v.card.subtitle:SetText(sub) end
    local list = board(def.key, page.scope)
    page.boardLead = list[1] and list[1].value or 0
    local crown = stat("Crown", def.key, page.scope)
    page.crownKey = crown and crown.key or nil
    -- data refreshes (GF_STATS_CHANGED) keep the scroll position; a new stat/scope starts at the top
    local shown = def.key .. ":" .. tostring(page.scope)
    v.list:SetItems(list, v.shown == shown)
    v.shown = shown
    fitStandings(v)
    v.empty:SetShown(#list == 0)
    v.empty:SetText(S() and LINES.board or LINES.noStats)
    -- your own crown gets the gold frame, and the sweep when its board comes up (once per stat/scope)
    local held = crown and page.mine and crown.key == page.mine
    h.art:SetTone(held and "gold" or nil)
    if held and (page.shineDue or v.shined ~= shown) then
        GF:After(0.3, function() if h:IsVisible() then UI:Shine(h, 1.1) end end)
    end
    v.shined = held and shown or v.shined
    page.shineDue = false
end

-------------------------------------------------------------------------------
-- My Badges: earned chips + "next up" progress
-------------------------------------------------------------------------------
local CHIP_FIXED = 4 + CHIP_ART + 8 + 12   -- everything in a chip but the name

local function chipTip(self)
    return { self.tipTitle, self.tipLines }
end

--- A badge: its title's art and the badge name, carved into the card.
local function makeChip(parent)
    local p = UI:Well(parent)
    p:SetHeight(CHIP_H)
    p.art = UI:FramedIcon(p, CHIP_ART)
    p.art:SetPoint("LEFT", 4, 0)
    p.name = UI:Text(p, 12, "wowGold", "ui")
    p.name:SetPoint("LEFT", p.art, "RIGHT", 8, 0)
    p:EnableMouse(true)
    UI.AttachTip(p, chipTip)
    return p
end

local function makeNextRow(parent)
    local r = CreateFrame("Frame", nil, parent)
    r:SetHeight(NEXT_H)
    r.art = UI:FramedIcon(r, NEXT_ART)
    r.art:SetPoint("LEFT", 0, 0)
    r.count = UI:Text(r, 12, "text", "num")
    r.count:SetPoint("TOPRIGHT", 0, -8)
    r.count:SetJustifyH("RIGHT")
    r.name = UI:Text(r, 13, "wowGold", "ui")
    r.name:SetPoint("TOPLEFT", r.art, "TOPRIGHT", 10, 4)
    r.name:SetPoint("TOPRIGHT", r.count, "TOPLEFT", -8, 0)
    r.label = UI:Text(r, 11, "dim")
    r.label:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 0, -3)
    r.label:SetPoint("TOPRIGHT", r.name, "BOTTOMRIGHT", 0, -3)
    r.bar = UI:Bar(r, { height = 6 })
    r.bar:SetPoint("BOTTOMLEFT", NEXT_ART + 10, 8)
    r.bar:SetPoint("BOTTOMRIGHT", 0, 8)
    r.rule = UI:Hairline(r, "bronze", 0.25)
    r.rule:SetPoint("BOTTOMLEFT")
    r.rule:SetPoint("BOTTOMRIGHT")
    return r
end

local function buildBadges(page)
    local v = CreateFrame("Frame", nil, page.body)
    v:SetAllPoints(page.body)
    v.left = UI:Card(v, { title = "Earned", icon = "star" })
    v.left:SetPoint("TOPLEFT")
    v.left:SetPoint("BOTTOMRIGHT", v, "BOTTOM", -GUTTER / 2, 0)
    v.right = UI:Card(v, { title = "Next up", icon = "chevron_right", subtitle = "closest first" })
    v.right:SetPoint("TOPLEFT", v, "TOP", GUTTER / 2, 0)
    v.right:SetPoint("BOTTOMRIGHT")
    if v.right.subtitle then UI:SetTextColor(v.right.subtitle, "dim") end

    v.count = UI:Text(v.left, 12, "dim", "num")
    v.count:SetPoint("TOPRIGHT", -12, -12)
    v.total = UI:Bar(v.left.body, { height = 6, color = "wowGold" })
    v.total:SetPoint("TOPLEFT")
    v.total:SetPoint("TOPRIGHT")
    v.lscroll, v.lcontent = UI:Scroll(v.left.body)
    v.lscroll:SetPoint("TOPLEFT", 0, -16)
    v.lscroll:SetPoint("BOTTOMRIGHT")
    v.chips, v.chipCount = {}, 0
    v.lempty = UI:Empty(v.left.body, LINES.badges, "star")
    v.lempty:Hide()

    v.rscroll, v.rcontent = UI:Scroll(v.right.body)
    v.rscroll:SetPoint("TOPLEFT")
    v.rscroll:SetPoint("BOTTOMRIGHT")
    v.rows, v.rowCount = {}, 0
    v.rempty = UI:Empty(v.right.body, LINES.next, "check")
    v.rempty:Hide()

    onWidthChanged(v.lcontent, "fame:chips", function() Fame:LayoutChips(page) end)
    onWidthChanged(v.rcontent, "fame:next", function() Fame:LayoutNext(page) end)
    return v
end

function Fame:LayoutChips(page)
    local v = page.views.badges
    local w = v.lcontent:GetWidth() or 0
    if w < 20 then return end
    local x, y = 0, 0
    for i = 1, v.chipCount do
        local p = v.chips[i]
        -- a chip never runs wider than the card: its name truncates instead
        local pw = min(floor(w), p.natural or 80)
        p:SetWidth(pw)
        -- width 0 = sized to its text; only a capped chip bounds (and so truncates) the name
        p.name:SetWidth(pw < (p.natural or 80) and max(10, pw - CHIP_FIXED) or 0)
        if x > 0 and x + pw > w then
            x = 0
            y = y + CHIP_H + 8
        end
        p:ClearAllPoints()
        p:SetPoint("TOPLEFT", v.lcontent, "TOPLEFT", x, -y)
        x = x + pw + 8
    end
    v.lscroll:SetContentHeight(v.chipCount > 0 and (y + CHIP_H + 4) or 0)
end

function Fame:LayoutNext(page)
    local v = page.views.badges
    for i = 1, v.rowCount do
        local r = v.rows[i]
        local y = -(i - 1) * NEXT_H
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", v.rcontent, "TOPLEFT", 0, y)
        r:SetPoint("TOPRIGHT", v.rcontent, "TOPRIGHT", 0, y)
    end
    v.rscroll:SetContentHeight(v.rowCount * NEXT_H)
end

--- Earned badges, fame first (brag), then shame (confess).
local function earnedList(me)
    local list = (me and stat("Badges", me)) or {}
    local fame, shame = {}, {}
    for _, b in ipairs(list) do
        if type(b) == "table" and b.name then
            if b.group == "shame" then shame[#shame + 1] = b else fame[#fame + 1] = b end
        end
    end
    for _, b in ipairs(shame) do fame[#fame + 1] = b end
    return fame
end

local function nextList()
    local out = {}
    for _, def in ipairs(GF.Titles) do
        if def.milestones then
            local m, v, prev = stat("NextMilestone", def.key)
            if type(m) == "table" then
                v, prev = tonumber(v) or 0, tonumber(prev) or 0
                local span = max(1, m[1] - prev)
                out[#out + 1] = { def = def, m = m, value = v, frac = min(1, max(0, (v - prev) / span)) }
            end
        end
    end
    table.sort(out, function(a, b)
        if a.frac ~= b.frac then return a.frac > b.frac end
        return a.def.order < b.def.order
    end)
    return out
end

local function totalMilestones()
    local n = 0
    for _, def in ipairs(GF.Titles) do
        if def.milestones then n = n + #def.milestones end
    end
    return n
end

function Fame:RenderBadges(page)
    local v = page.views.badges
    local earned = earnedList(API.MyKey())
    local total = totalMilestones()
    v.count:SetText(("%d / %d"):format(#earned, total))
    v.total:SetValue(total > 0 and #earned / total or 0)
    for i, b in ipairs(earned) do
        local p = v.chips[i]
        if not p then
            p = makeChip(v.lcontent)
            v.chips[i] = p
        end
        local def = GF.TitlesByKey[b.stat]
        local accent = b.group == "shame" and SHAME or C.wowGold
        p.art:SetIcon(def and artOf(def) or (b.icon or "star"))
        p.name:SetText(b.name)
        p.name:SetTextColor(accent[1], accent[2], accent[3], 1)
        local nw = p.name.GetUnboundedStringWidth and p.name:GetUnboundedStringWidth() or p.name:GetStringWidth()
        p.natural = CHIP_FIXED + ceil(tonumber(nw) or 60)
        p.tipTitle = b.name
        p.tipLines = {
            def and def.label or "",
            T:Wrap("dim", "Reached " .. fmt(b.stat, b.n) .. (def and def.title and (" on the road to " .. def.title) or "") .. "."),
        }
        p:Show()
    end
    for i = #earned + 1, #v.chips do v.chips[i]:Hide() end
    v.chipCount = #earned
    v.lempty:SetShown(#earned == 0)
    v.lempty:SetText(S() and LINES.badges or LINES.noStats)
    self:LayoutChips(page)

    local nexts = nextList()
    for i, e in ipairs(nexts) do
        local r = v.rows[i]
        if not r then
            r = makeNextRow(v.rcontent)
            v.rows[i] = r
        end
        local accent = accentOf(e.def)
        r.art:SetIcon(artOf(e.def))
        r.name:SetText(e.m[2])
        r.name:SetTextColor(accent[1], accent[2], accent[3], 1)
        r.label:SetText(e.def.label or "")
        r.count:SetText(fmt(e.def.key, e.value) .. T:Wrap("dim", " / " .. fmt(e.def.key, e.m[1])))
        r.bar:SetColor({ accent[1], accent[2], accent[3], 0.9 })
        r.bar:SetValue(e.frac)
        r:Show()
    end
    for i = #nexts + 1, #v.rows do v.rows[i]:Hide() end
    v.rowCount = #nexts
    v.rempty:SetShown(#nexts == 0 and S() ~= nil)
    self:LayoutNext(page)
end

-------------------------------------------------------------------------------
-- Page
-------------------------------------------------------------------------------
local function styleScope(page)
    page.scopeCtl:SetShown(page.tab ~= "badges")
    page.scopeCtl:Select(page.scope, true)
end

function Fame:Render(page)
    page.mine = myMain()
    for _, view in pairs(page.views) do view:Hide() end
    local tab = page.tab
    if tab == "fame" or tab == "shame" then
        page.views.grid = page.views.grid or buildGrid(page)
        page.views.grid:Show()
        renderGrid(page, tab)
    elseif tab == "boards" then
        page.views.boards = page.views.boards or buildBoards(page)
        page.views.boards:Show()
        self:RenderBoards(page)
    else
        page.views.badges = page.views.badges or buildBadges(page)
        page.views.badges:Show()
        self:RenderBadges(page)
    end
    styleScope(page)
end

local function setScope(page, scope)
    if page.scope == scope then return end
    page.scope = scope
    page.shineDue = true
    Fame:Render(page)
end

local SCOPES = { { key = "all", text = "All time" }, { key = "week", text = "This week" } }
local SCOPE_TIPS = {
    all = "Every stat since each resident started tracking.",
    week = "Only what's happened since the Wednesday reset.",
}

local function build(page)
    page.tab, page.scope = "fame", "all"
    page.stat = GF.Titles[1] and GF.Titles[1].key
    page.views = {}
    page.shineDue = true
    local header = UI:PageHeader(page, "Hall of Fame", "Legends and liabilities of Greenfields.")
    page.tabs = UI:Tabs(page, TABS, function(key)
        if page.tab ~= key then page.shineDue = true end
        page.tab = key
        Fame:Render(page)
    end)
    -- TOPRIGHT, not RIGHT: a RIGHT point would pin the tab strip's centre to the page's and
    -- stretch it down the page, squashing page.body underneath to nothing.
    -- 14 below the header puts the strip under the night scene, not on it.
    page.tabs:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -14)
    page.tabs:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -14)
    -- one row holds every view control
    page.scopeCtl = UI:Segmented(page.tabs, SCOPES, function(key) setScope(page, key) end, { height = 24 })
    page.scopeCtl:SetPoint("RIGHT", page.tabs, "RIGHT", 0, 1)
    for _, b in ipairs(page.scopeCtl.buttons) do UI.AttachTip(b, SCOPE_TIPS[b.key]) end
    page.body = CreateFrame("Frame", nil, page)
    page.body:SetPoint("TOPLEFT", page.tabs, "BOTTOMLEFT", 0, -12)
    page.body:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
    page.tabs:Select(page.tab, true)
end

--- onShow(page, arg): arg may be a stat key (opens its leaderboard) or a tab key.
local function onShow(page, arg)
    if type(arg) == "string" then
        if GF.TitlesByKey[arg] then
            page.stat, page.tab = arg, "boards"
            page.shineDue = true
        elseif TAB_KEYS[arg] then
            if page.tab ~= arg then page.shineDue = true end
            page.tab = arg
        end
    end
    page.tabs:Select(page.tab, true)
    Fame:Render(page)
end

--- Leaving the page re-arms the sweep for the crowns you hold.
local function onHide(page)
    page.shineDue = true
    if picker then picker:Hide() end
end

UI:RegisterPage({
    key = "fame", title = "Hall of Fame", subtitle = "Legends and liabilities of Greenfields.",
    icon = "trophy", group = "community", order = 20,
    build = build, onShow = onShow, onHide = onHide,
})

GF:On("GF_STATS_CHANGED", function()
    GF:Debounce("fame-refresh", 0.5, function() UI:RefreshPage("fame") end)
end)
