--[[ Greenfields - Modules/HallOfFame.lua
     The Hall of Fame page: who wears which crown, who's carrying which shame, the full
     standings for every stat, and your own badge collection.

     Tabs: Hall of Fame / Hall of Shame (a grid of title cards), Leaderboards (one stat,
     every main ranked), My Badges (earned chips + progress toward the next milestone).
     The scope toggle in the header switches between all-time and this week. Wealth is a
     rank stat: the page only ever shows positions, never amounts.

     The look is the achievement panel: each title card is a slate plate with a leather
     header band, the title's art in a gold action-button frame, the title in Morpheus
     (gold for fame, pink-red for shame) and a gold rule above the holder. Crowns you hold
     get the gold rim, the guild's green gem and a light sweep; every card shines on hover.

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
local CARD_H = 206
local INTRO_H = 22          -- the "you wear N crowns" line above the grid
local INTRO_ART = 20
local INTRO_MAX = 6
local ROW_H = 40
local HERO_H = 84           -- leaderboard banner
local HERO_ART = 52
local DD_W = 210
local CHIP_H = 32
local NEXT_H = 52
local NEXT_ART = 34
local VALUE_W = 120
local TITLE_WIDE = { 18, 16, 15 }       -- card title sizes, largest first
local TITLE_NARROW = { 15, 14, 13 }
local SILVER = { 0.78, 0.80, 0.84, 1 }
local BRONZE = { 0.82, 0.56, 0.34, 1 }
local SHAME = { 1.00, 0.36, 0.40, 1 }     -- pink-red: the Hall of Shame's ink
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
    badges = "No badges yet. Even the bin chickens have one.",
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

local function tint(tex, c, a)
    if tex and not tex.isGameIcon then tex:SetVertexColor(c[1], c[2], c[3], a or c[4] or 1) end
end

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

--- UI:Empty is a fixed 360px block; shrink it (and its wrapping text) to fit a narrow card.
local function fitEmpty(e, w)
    w = tonumber(w) or 0
    if not e or w < 40 then return end
    local ew = min(360, floor(w - 8))
    e:SetWidth(ew)
    if e.text then e.text:SetWidth(ew) end
end

-------------------------------------------------------------------------------
-- Warcraft chrome helpers (all built from the kit's Media textures)
-------------------------------------------------------------------------------
--- A tileable texture (stone / leather / parchment) filling `f` inside `inset` px.
local function tiled(f, sub, path, inset, r, g, b, a)
    local t = f:CreateTexture(nil, "BACKGROUND", nil, sub)
    inset = inset or 2
    t:SetPoint("TOPLEFT", inset, -inset)
    t:SetPoint("BOTTOMRIGHT", -inset, inset)
    t:SetTexture(path, "REPEAT", "REPEAT")
    t:SetHorizTile(true)
    t:SetVertTile(true)
    t:SetVertexColor(r or 1, g or 1, b or 1, a or 1)
    return t
end

--- A 9-sliced rim over the whole frame (bronze margins 8, gold margins 16).
local function rim(f, path, margin, sub)
    local t = f:CreateTexture(nil, "BORDER", nil, sub)
    t:SetAllPoints()
    UI.Sliced(t, path, margin)
    return t
end

--- Soft horizontal wash: colour at the left fading out to the right.
local function setWash(t, c, a)
    if t.SetGradient and CreateColor then
        t:SetGradient("HORIZONTAL", CreateColor(c[1], c[2], c[3], a), CreateColor(c[1], c[2], c[3], 0))
    else
        t:SetColorTexture(c[1], c[2], c[3], a * 0.5)
    end
end

local function titleShadow(fs)
    if fs.SetShadowOffset then
        fs:SetShadowOffset(1.5, -1.5)
        fs:SetShadowColor(0, 0, 0, 0.95)
    end
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

--- Gold rim + gem for a crown you hold; the plain bronze plate otherwise.
local function styleRim(c)
    c.goldRim:SetShown(c.held and true or false)
    c.gem:SetShown(c.held and true or false)
    c.rim:SetShown(not c.held)
end

local function makeCard(parent, page)
    local c = CreateFrame("Button", nil, parent, "BackdropTemplate")
    UI:SetBackdrop(c, C.bg2, false)
    c:SetHeight(CARD_H)
    -- slate plate, a darker leather band behind the art + title, an accent glow behind the art
    c.stone = tiled(c, 1, T.tex.stone, 2, 0.62, 0.66, 0.64, 0.34)
    c.band = c:CreateTexture(nil, "BACKGROUND", nil, 2)
    c.band:SetPoint("TOPLEFT", 3, -3)
    c.band:SetPoint("TOPRIGHT", -3, -3)
    c.band:SetHeight(70)
    c.band:SetTexture(T.tex.leather, "REPEAT", "REPEAT")
    c.band:SetHorizTile(true)
    c.band:SetVertTile(true)
    c.band:SetVertexColor(0.70, 0.62, 0.55, 0.50)
    c.glow = c:CreateTexture(nil, "BACKGROUND", nil, 3)
    c.glow:SetTexture(T.tex.glow)
    c.glow:SetPoint("TOPLEFT", 3, -3)       -- kept inside the plate (no bleed into the gutter)
    c.glow:SetSize(150, 70)
    c.hl = c:CreateTexture(nil, "BACKGROUND", nil, 4)
    c.hl:SetPoint("TOPLEFT", 2, -2)
    c.hl:SetPoint("BOTTOMRIGHT", -2, 2)
    c.hl:SetColorTexture(1, 0.9, 0.6, 0.045)
    c.hl:SetBlendMode("ADD")
    c.hl:Hide()
    c.rim = rim(c, T.tex.frameBronze, 8)
    c.goldRim = rim(c, T.tex.frameGold, 16, 1)
    c.goldRim:Hide()
    c.gem = c:CreateTexture(nil, "OVERLAY", nil, 2)
    c.gem:SetTexture(T.tex.gemGreen)
    c.gem:SetSize(16, 16)
    c.gem:SetPoint("CENTER", c, "TOP", 0, -1)
    c.gem:Hide()

    -- header: the art in a gold frame, title + label beside it (positions in layoutCard)
    c.art = UI:FramedIcon(c, 50)
    c.title = UI:Text(c, 18, "wowGold", "title")
    c.title:SetWordWrap(true)
    c.title:SetJustifyV("TOP")
    if c.title.SetMaxLines then c.title:SetMaxLines(2) end
    titleShadow(c.title)
    c.label = UI:Text(c, 11, "dim")
    c.label:SetPoint("TOPLEFT", c.title, "BOTTOMLEFT", 0, -3)
    c.div = c:CreateTexture(nil, "ARTWORK")
    c.div:SetTexture(T.tex.dividerGold)
    c.div:SetHeight(12)
    c.div:SetAlpha(0.9)

    -- holder line
    c.avatar = UI:Avatar(c, 30)
    c.name = UI:Text(c, 14, "text", "head")
    c.value = UI:Text(c, 12, "text", "num")
    c.value:SetPoint("TOPLEFT", c.name, "BOTTOMLEFT", 0, -3)
    c.you = UI:Pill(c, "YOU", "green", { height = 16, size = 10 })
    c.allTime = UI:Pill(c, "ALL TIME", "dim", { height = 15, size = 9 })

    c.blurb = UI:Text(c, 11, FLAVOR)
    c.blurb:SetWordWrap(true)
    c.blurb:SetJustifyV("TOP")
    if c.blurb.SetMaxLines then c.blurb:SetMaxLines(2) end

    -- footer: runners-up under a faint rule
    c.foot = UI:Divider(c, "lineSoft")
    c.foot:SetPoint("BOTTOMLEFT", PAD, 30)
    c.foot:SetPoint("BOTTOMRIGHT", -PAD, 30)
    c.runners = UI:Text(c, 10, "dim")
    c.runners:SetPoint("BOTTOMLEFT", PAD, 11)
    c.runners:SetPoint("BOTTOMRIGHT", -PAD, 11)

    c:RegisterForClicks("LeftButtonUp")
    c:SetScript("OnEnter", function(self)
        self.hl:Show()
        UI:Shine(self, 0.85)
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

--- Sets the largest Morpheus size (from `sizes`, largest first) at which the text wraps to
-- at most two lines in `w` px; the last size is the floor (it truncates past that).
local function fitTitle(fs, w, sizes)
    fs:SetWidth(w)
    local canMeasure = fs.SetMaxLines and fs.GetNumLines
    for i = 1, #sizes do
        T:Font(fs, "title", sizes[i])
        if i == #sizes or not canMeasure then break end
        fs:SetMaxLines(0)
        local lines = tonumber(fs:GetNumLines()) or 1
        fs:SetMaxLines(2)
        if lines <= 2 then break end
    end
    titleShadow(fs)
end

--- Sizes and places everything for a card `cw` px wide: a narrow card (minimum window)
-- gets a smaller frame and title so long titles still fit on two lines.
local function layoutCard(c, cw)
    local wide = cw >= 230
    local icon = wide and 50 or 40
    local band = PAD * 2 + icon + (wide and 0 or 6)
    if c.iconSize ~= icon then
        c.iconSize = icon
        c.art:SetSize(icon, icon)
    end
    c.art:ClearAllPoints()
    c.art:SetPoint("TOPLEFT", c, "TOPLEFT", PAD, -PAD)
    c.band:SetHeight(band - 3)
    c.glow:SetSize(min(160, floor(cw * 0.6)), band - 3)

    -- title + label, centred against the frame
    local tx = PAD + icon + 10
    local tw = max(40, floor(cw - tx - PAD))
    fitTitle(c.title, tw, wide and TITLE_WIDE or TITLE_NARROW)
    c.label:SetWidth(tw)
    local th = (c.title:GetStringHeight() or 18) + 3 + (c.label:GetStringHeight() or 12)
    local ty = PAD + max(0, floor((icon - th) / 2 + 0.5))
    c.title:ClearAllPoints()
    c.title:SetPoint("TOPLEFT", c, "TOPLEFT", tx, -ty)

    c.div:ClearAllPoints()
    c.div:SetPoint("TOPLEFT", c, "TOPLEFT", 4, -(band - 6))
    c.div:SetPoint("TOPRIGHT", c, "TOPRIGHT", -4, -(band - 6))

    -- holder line: avatar, name/value, then the pills right-aligned on the avatar's centre
    local y = band + 10
    c.avatar:ClearAllPoints()
    c.avatar:SetPoint("TOPLEFT", c, "TOPLEFT", PAD, -y)
    local right = PAD
    c.you:ClearAllPoints()
    if c.you:IsShown() then
        c.you:SetPoint("RIGHT", c, "TOPRIGHT", -right, -(y + 15))
        right = right + (c.you:GetWidth() or 30) + 6
    end
    c.allTime:ClearAllPoints()
    if c.allTime:IsShown() then
        c.allTime:SetPoint("RIGHT", c, "TOPRIGHT", -right, -(y + 15))
        right = right + (c.allTime:GetWidth() or 50) + 6
    end
    local nx = PAD + 30 + 10
    local nw = max(30, floor(cw - nx - right))
    c.name:ClearAllPoints()
    c.name:SetPoint("TOPLEFT", c, "TOPLEFT", nx, -(y - 1))
    c.name:SetWidth(nw)
    c.value:SetWidth(nw)

    c.blurb:ClearAllPoints()
    c.blurb:SetPoint("TOPLEFT", c, "TOPLEFT", PAD, -(y + 30 + 10))
    c.blurb:SetWidth(max(40, floor(cw - PAD * 2)))
end

local function runnersText(def, list)
    local parts = {}
    for i = 2, 3 do
        local e = list[i]
        if e then
            local s = T:Wrap("faint", "#" .. i) .. " " .. colored(e.key)
            if def.kind ~= "rank" then s = s .. "  " .. T:Wrap("dim", fmt(def.key, e.value)) end
            parts[#parts + 1] = s
        end
    end
    if #parts == 0 then return T:Wrap("faint", "No runners-up yet.") end
    return table.concat(parts, "     ")
end

local function updateCard(c, def, scope, mine)
    local list = board(def.key, scope)
    local top = list[1]
    local accent = accentOf(def)
    c.def, c.accent = def, accent
    c.held = (mine ~= nil and top ~= nil and top.key == mine) and true or false
    styleRim(c)
    -- an unclaimed title reads like an unearned achievement: greyed art
    c.art:SetIcon(artOf(def))
    c.art:SetDesaturated(top == nil)
    c.art:SetAlpha(top and 1 or 0.65)
    c.glow:SetVertexColor(accent[1], accent[2], accent[3], c.held and 0.24 or (top and 0.11 or 0.05))
    c.title:SetText(tostring(def.title))
    c.title:SetTextColor(accent[1], accent[2], accent[3], 1)
    c.label:SetText(def.label or "")
    c.allTime:SetShown(scope == "week" and stat("HasWeekly", def.key) == false)
    c.you:SetShown(c.held)
    if top then
        c.avatar:SetClass(classOf(top.key))
        c.name:SetText(colored(top.key))
        c.value:SetText(fmt(def.key, top.value, top.rank))
    else
        c.avatar:SetClass(nil)
        c.name:SetText(T:Wrap("dim", "Up for grabs"))
        c.value:SetText(T:Wrap("faint", def.group == "fame" and "Nobody's claimed it. Yet." or "Clean slate. Enjoy it while it lasts."))
    end
    c.blurb:SetText('"' .. (def.blurb or "") .. '"')
    c.runners:SetText(runnersText(def, list))
end

local function buildGrid(page)
    local v = CreateFrame("Frame", nil, page.body)
    v:SetAllPoints(page.body)
    local scroll, content = UI:Scroll(v)
    scroll:SetPoint("TOPLEFT")
    scroll:SetPoint("BOTTOMRIGHT")
    v.scroll, v.content = scroll, content
    v.intro = UI:Text(content, 12, "dim")
    v.introArt = {}
    v.cards, v.defs = {}, {}
    onWidthChanged(content, "fame:layout", function() Fame:LayoutGrid(page) end)
    return v
end

--- Full intro when it fits beside the art, the short one otherwise.
local function fitIntro(v, w)
    v.intro:SetText(v.introFull or "")
    local uw = v.intro.GetUnboundedStringWidth and v.intro:GetUnboundedStringWidth() or 0
    if v.introShort and (tonumber(uw) or 0) > w - (v.introX or 0) - 4 then v.intro:SetText(v.introShort) end
end

function Fame:LayoutGrid(page)
    local v = page.views.grid
    if not v then return end
    local w = v.content:GetWidth() or 0
    if w < 50 then return end
    local cols = (w >= 1000 and 4) or (w >= 700 and 3) or (w >= 400 and 2) or 1
    local cw = floor((w - (cols - 1) * GUTTER) / cols)
    local top = INTRO_H + 12
    for i = 1, #v.defs do
        local c = v.cards[i]
        local col, row = (i - 1) % cols, floor((i - 1) / cols)
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", v.content, "TOPLEFT", col * (cw + GUTTER), -(top + row * (CARD_H + GUTTER)))
        c:SetWidth(cw)
        layoutCard(c, cw)
    end
    local rows = ceil(#v.defs / cols)
    v.scroll:SetContentHeight(top + rows * (CARD_H + GUTTER))
    fitIntro(v, w)
end

--- The line above the grid -> full text, short text (no names: the framed art says it)
-- for when the full one won't fit beside the art.
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

--- The intro line, led by the framed art of every title you hold on this side.
local function layoutIntro(v, held)
    local x = 0
    for i = 1, min(#held, INTRO_MAX) do
        local a = v.introArt[i]
        if not a then
            a = UI:FramedIcon(v.content, INTRO_ART)
            v.introArt[i] = a
        end
        a:SetIcon(artOf(held[i]))
        a:ClearAllPoints()
        a:SetPoint("TOPLEFT", v.content, "TOPLEFT", x, 0)
        a:Show()
        x = x + INTRO_ART + 4
    end
    for i = min(#held, INTRO_MAX) + 1, #v.introArt do v.introArt[i]:Hide() end
    v.introX = x > 0 and x + 4 or 0
    v.intro:ClearAllPoints()
    v.intro:SetPoint("TOPLEFT", v.content, "TOPLEFT", v.introX, -4)
    v.intro:SetPoint("TOPRIGHT", v.content, "TOPRIGHT", 0, -4)
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
        local top = board(def.key, page.scope)[1]
        if top then
            anyHolder = true
            if top.key == mine then held[#held + 1] = def end
        end
    end
    for i = #defs + 1, #v.cards do v.cards[i]:Hide() end
    if not S() then
        layoutIntro(v, {})
        v.introFull, v.introShort = LINES.noStats, nil
    else
        layoutIntro(v, held)
        v.introFull, v.introShort = introLine(group, held, anyHolder)
    end
    v.intro:SetText(v.introFull)
    Fame:LayoutGrid(page)
    shineHeld(page, v)
end

-------------------------------------------------------------------------------
-- Leaderboards
-------------------------------------------------------------------------------
local function statItems()
    local out = { { text = "HALL OF FAME", title = true } }
    for _, def in ipairs(GF.Titles) do
        if def.group == "fame" then out[#out + 1] = { text = def.title, value = def.key, icon = artOf(def), color = "wowGold" } end
    end
    out[#out + 1] = { text = "HALL OF SHAME", title = true }
    for _, def in ipairs(GF.Titles) do
        if def.group == "shame" then out[#out + 1] = { text = def.title, value = def.key, icon = artOf(def), color = SHAME } end
    end
    return out
end

local function createBoardRow(row)
    -- the leader's row gets an accent wash and wears the title's art instead of "#1"
    row.lead = row:CreateTexture(nil, "BACKGROUND", nil, 3)
    row.lead:SetPoint("TOPLEFT")
    row.lead:SetPoint("BOTTOMLEFT")
    row.lead:SetWidth(260)
    row.lead:SetTexture(T.tex.white)
    row.lead:Hide()
    row.rank = UI:Text(row, 16, "dim", "title")
    row.rank:SetPoint("LEFT", 6, 0)
    row.rank:SetWidth(36)
    row.rank:SetJustifyH("CENTER")
    row.art = UI:FramedIcon(row, 30)
    row.art:SetPoint("LEFT", 9, 0)
    row.art:Hide()
    row.avatar = UI:Avatar(row, 28)
    row.avatar:SetPoint("LEFT", 48, 0)
    row.value = UI:Text(row, 13, "text", "num")
    row.value:SetPoint("RIGHT", -12, 0)
    row.value:SetWidth(VALUE_W)
    row.value:SetJustifyH("RIGHT")
    row.name = UI:Text(row, 13, "text", "head")
    row.name:SetPoint("TOPLEFT", row.avatar, "TOPRIGHT", 10, -1)
    row.you = UI:Pill(row, "YOU", "green", { height = 14, size = 9 })
    row.you:SetPoint("LEFT", row.name, "RIGHT", 6, 0)
    -- bottom-aligned with the avatar, stopping short of the (fixed-width) value column
    row.bar = UI:Bar(row, { height = 5 })
    row.bar:SetPoint("BOTTOMLEFT", row.avatar, "BOTTOMRIGHT", 10, 2)
    row.bar:SetPoint("BOTTOMRIGHT", row, "RIGHT", -(12 + VALUE_W + 18), -12)
end

local function updateBoardRow(row, item, page)
    local def = GF.TitlesByKey[page.stat]
    if not def then return end
    local accent = accentOf(def)
    local lead = item.rank == 1
    local rc = (item.rank == 2 and SILVER) or (item.rank == 3 and BRONZE) or C.faint
    row.rank:SetText("#" .. tostring(item.rank))
    row.rank:SetTextColor(rc[1], rc[2], rc[3], 1)
    row.rank:SetShown(not lead)
    row.art:SetShown(lead)
    row.lead:SetShown(lead)
    if lead then
        row.art:SetIcon(artOf(def))
        setWash(row.lead, accent, 0.16)
    end
    row.avatar:SetClass(classOf(item.key))
    row.name:SetText(colored(item.key))
    row.you:SetShown(item.key == page.mine)
    if def.kind == "rank" then
        row.value:SetText(T:Wrap("faint", "amount classified"))
        row.bar:Hide()
    else
        row.value:SetText(fmt(def.key, item.value))
        local top = page.boardLead or 0
        row.bar:SetColor({ accent[1], accent[2], accent[3], item.rank <= 3 and 0.95 or 0.5 })
        row.bar:Show()
        row.bar:SetValue(top > 0 and (item.value or 0) / top or 0)
    end
end

--- The banner over the standings: the chosen title's art, name and roast on a leather
-- plate in a gold rim, with the stat picker on its right.
local function buildHero(v, page)
    local h = CreateFrame("Frame", nil, v, "BackdropTemplate")
    UI:SetBackdrop(h, C.bg1, false)
    h:SetPoint("TOPLEFT")
    h:SetPoint("TOPRIGHT")
    h:SetHeight(HERO_H)
    h.leather = tiled(h, 1, T.tex.leather, 3, 0.85, 0.78, 0.70, 0.75)
    h.wash = h:CreateTexture(nil, "BACKGROUND", nil, 2)
    h.wash:SetPoint("TOPLEFT", 3, -3)
    h.wash:SetPoint("BOTTOMLEFT", 3, 3)
    h.wash:SetWidth(320)
    h.wash:SetTexture(T.tex.white)
    h.glow = h:CreateTexture(nil, "BACKGROUND", nil, 3)
    h.glow:SetTexture(T.tex.glow)
    h.glow:SetPoint("TOPLEFT", 3, -3)
    h.glow:SetPoint("BOTTOMLEFT", 3, 3)
    h.glow:SetWidth(170)
    h.rim = rim(h, T.tex.frameGold, 16)
    h.art = UI:FramedIcon(h, HERO_ART)
    h.art:SetPoint("LEFT", 18, 0)

    v.dd = UI:Dropdown(h, {
        width = DD_W, items = statItems,
        get = function() return page.stat end,
        set = function(value) page.stat = value; Fame:RenderBoards(page) end,
        tooltip = "Pick a stat to see everyone's standing.",
    })
    v.dd:SetPoint("RIGHT", -18, 0)

    local tx = 18 + HERO_ART + 14
    h.title = UI:Text(h, 21, "wowGold", "title")
    h.title:SetPoint("TOPLEFT", h, "TOPLEFT", tx, -13)
    h.title:SetPoint("TOPRIGHT", h, "TOPRIGHT", -(18 + DD_W + 16), -13)
    titleShadow(h.title)
    h.label = UI:Text(h, 12, "text")
    h.label:SetPoint("TOPLEFT", h.title, "BOTTOMLEFT", 0, -4)
    h.label:SetPoint("TOPRIGHT", h.title, "BOTTOMRIGHT", 0, -4)
    h.blurb = UI:Text(h, 11, FLAVOR)
    h.blurb:SetPoint("TOPLEFT", h.label, "BOTTOMLEFT", 0, -3)
    h.blurb:SetPoint("TOPRIGHT", h.label, "BOTTOMRIGHT", 0, -3)
    return h
end

local function buildBoards(page)
    local v = CreateFrame("Frame", nil, page.body)
    v:SetAllPoints(page.body)
    v.hero = buildHero(v, page)

    v.card = UI:Card(v, { title = "Standings", icon = "trophy", accent = "gold", subtitle = " " })
    v.card:SetPoint("TOPLEFT", v.hero, "BOTTOMLEFT", 0, -14)
    v.card:SetPoint("BOTTOMRIGHT", v, "BOTTOMRIGHT", 0, 0)
    v.note = UI:Text(v.card, 10, "faint")
    v.note:SetPoint("TOPRIGHT", -12, -15)
    v.note:SetText("Self-reported by Greenfields users. Alts roll up to their mains.")

    v.list = UI:List(v.card.body, {
        rowHeight = ROW_H, spacing = 2,
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
    v.list:SetAllPoints(v.card.body)
    v.empty = UI:Empty(v.card.body, LINES.board, "trophy")
    v.empty:Hide()
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
    h.glow:SetVertexColor(accent[1], accent[2], accent[3], 0.20)
    setWash(h.wash, accent, 0.10)
    tint(v.card.icon, accent)
    v.card.accent:SetColorTexture(accent[1], accent[2], accent[3], 1)
    local sub = scopeLabel(page.scope)
    if page.scope == "week" and stat("HasWeekly", def.key) == false then sub = "All time (no weekly split for this one)" end
    if v.card.subtitle then v.card.subtitle:SetText(sub) end
    local list = board(def.key, page.scope)
    page.boardLead = list[1] and list[1].value or 0
    -- data refreshes (GF_STATS_CHANGED) keep the scroll position; a new stat/scope starts at the top
    local shown = def.key .. ":" .. tostring(page.scope)
    v.list:SetItems(list, v.shown == shown)
    v.shown = shown
    v.empty:SetShown(#list == 0)
    v.empty:SetText(S() and LINES.board or LINES.noStats)
    -- your own crown gets the sweep when its board comes up (once per stat/scope)
    local held = list[1] and page.mine and list[1].key == page.mine
    if held and (page.shineDue or v.shined ~= shown) then
        GF:After(0.3, function() if h:IsVisible() then UI:Shine(h, 1.1) end end)
    end
    v.shined = held and shown or v.shined
    page.shineDue = false
end

-------------------------------------------------------------------------------
-- My Badges: earned chips + "next up" progress
-------------------------------------------------------------------------------
local CHIP_ART = CHIP_H - 6
local CHIP_FIXED = 3 + CHIP_ART + 8 + 12   -- everything in a chip but the name

local function chipTip(self)
    return { self.tipTitle, self.tipLines }
end

--- A badge: its title's art in a gold frame and the badge name, on a dark bronze-rimmed plate.
local function makeChip(parent)
    local p = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    UI:SetBackdrop(p, { 0.035, 0.04, 0.037, 0.9 }, false)
    p:SetHeight(CHIP_H)
    p.wash = p:CreateTexture(nil, "BACKGROUND", nil, 1)
    p.wash:SetPoint("TOPLEFT", 2, -2)
    p.wash:SetPoint("BOTTOMLEFT", 2, 2)
    p.wash:SetWidth(90)
    p.wash:SetTexture(T.tex.white)
    p.rim = rim(p, T.tex.frameBronze, 8)
    p.art = UI:FramedIcon(p, CHIP_ART)
    p.art:SetPoint("LEFT", 3, 0)
    p.name = UI:Text(p, 12, "wowGold", "ui")
    p.name:SetPoint("LEFT", p.art, "RIGHT", 8, 0)
    p:EnableMouse(true)
    UI.AttachTip(p, chipTip)
    p:HookScript("OnEnter", function(self) UI:Shine(self, 0.6) end)
    return p
end

local function makeNextRow(parent)
    local r = CreateFrame("Frame", nil, parent)
    r:SetHeight(NEXT_H - 8)
    r.art = UI:FramedIcon(r, NEXT_ART)
    r.art:SetPoint("TOPLEFT", 0, -2)
    r.count = UI:Text(r, 12, "dim", "num")
    r.count:SetPoint("TOPRIGHT", 0, -3)
    r.count:SetJustifyH("RIGHT")
    r.name = UI:Text(r, 13, "wowGold", "ui")
    r.name:SetPoint("TOPLEFT", r.art, "TOPRIGHT", 10, 1)
    r.name:SetPoint("TOPRIGHT", r.count, "TOPLEFT", -8, 1)
    r.label = UI:Text(r, 11, "faint")
    r.label:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 0, -3)
    r.label:SetPoint("TOPRIGHT", r.name, "BOTTOMRIGHT", 0, -3)
    r.bar = UI:Bar(r, { height = 6 })
    r.bar:SetPoint("BOTTOMLEFT", NEXT_ART + 10, 3)
    r.bar:SetPoint("BOTTOMRIGHT", 0, 3)
    return r
end

local function buildBadges(page)
    local v = CreateFrame("Frame", nil, page.body)
    v:SetAllPoints(page.body)
    v.left = UI:Card(v, { title = "Earned", icon = "star", accent = "gold" })
    v.left:SetPoint("TOPLEFT")
    v.left:SetPoint("BOTTOMRIGHT", v, "BOTTOM", -GUTTER / 2, 0)
    v.right = UI:Card(v, { title = "Next up", icon = "chevron_right", accent = "green", subtitle = "closest first" })
    v.right:SetPoint("TOPLEFT", v, "TOP", GUTTER / 2, 0)
    v.right:SetPoint("BOTTOMRIGHT")

    v.count = UI:Text(v.left, 11, "dim", "head")
    v.count:SetPoint("TOPRIGHT", -12, -15)
    v.total = UI:Bar(v.left.body, { height = 6, color = "wowGold" })
    v.total:SetPoint("TOPLEFT")
    v.total:SetPoint("TOPRIGHT")
    v.lscroll, v.lcontent = UI:Scroll(v.left.body)
    v.lscroll:SetPoint("TOPLEFT", 0, -18)
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
            y = y + CHIP_H + 6
        end
        p:ClearAllPoints()
        p:SetPoint("TOPLEFT", v.lcontent, "TOPLEFT", x, -y)
        x = x + pw + 6
    end
    v.lscroll:SetContentHeight(v.chipCount > 0 and (y + CHIP_H + 4) or 0)
    fitEmpty(v.lempty, w)
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
    fitEmpty(v.rempty, v.rcontent:GetWidth())
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
        setWash(p.wash, accent, 0.14)
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
        r.count:SetText(fmt(e.def.key, e.value) .. T:Wrap("faint", " / " .. fmt(e.def.key, e.m[1])))
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
    local onBadges = page.tab == "badges"
    page.allBtn:SetShown(not onBadges)
    page.weekBtn:SetShown(not onBadges)
    page.allBtn:SetStyle(page.scope == "all" and "primary" or "secondary")
    page.weekBtn:SetStyle(page.scope == "week" and "primary" or "secondary")
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

local function build(page)
    page.tab, page.scope = "fame", "all"
    page.stat = GF.Titles[1] and GF.Titles[1].key
    page.views = {}
    page.shineDue = true
    local header = UI:PageHeader(page, "Hall of Fame", "Legends and liabilities of Greenfields.")
    page.weekBtn = header:AddAction(UI:Button(header, "This week", {
        icon = "calendar", onClick = function() setScope(page, "week") end,
        tooltip = "Only what's happened since the Wednesday reset.",
    }))
    page.allBtn = header:AddAction(UI:Button(header, "All time", {
        icon = "clock", onClick = function() setScope(page, "all") end,
        tooltip = "Every stat since each resident started tracking.",
    }))
    page.tabs = UI:Tabs(page, TABS, function(key)
        if page.tab ~= key then page.shineDue = true end
        page.tab = key
        Fame:Render(page)
    end)
    -- TOPRIGHT, not RIGHT: a RIGHT point would pin the tab strip's centre to the page's and
    -- stretch it down the page, squashing page.body underneath to nothing
    page.tabs:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -6)
    page.tabs:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -6)
    page.body = CreateFrame("Frame", nil, page)
    page.body:SetPoint("TOPLEFT", page.tabs, "BOTTOMLEFT", 0, -14)
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
end

UI:RegisterPage({
    key = "fame", title = "Hall of Fame", subtitle = "Legends and liabilities of Greenfields.",
    icon = "trophy", group = "community", order = 20,
    build = build, onShow = onShow, onHide = onHide,
})

GF:On("GF_STATS_CHANGED", function()
    GF:Debounce("fame-refresh", 0.5, function() UI:RefreshPage("fame") end)
end)
