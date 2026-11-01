--[[ Greenfields - Modules/Residents.lua
     The Residents page ("roster"): the whole guild as one street.

     A single summary plate (headcount, who's home, who's on Greenfields, a clickable
     class-mix bar) sits above a virtual list of everyone on the roster. Each row is a line
     in a ledger: class portrait with one presence pip, name, level, rank, whereabouts, their
     top Hall of Fame title, roll-call percentage and their two main trades; alts can fold in
     underneath their main. Left-click opens the resident's profile (Modules/Profile.lua),
     right-click offers whisper, invite and copy-name. Everything other modules supply
     (titles, attendance, professions) is optional and fetched behind guards, lazily, only
     for the rows on screen.

     Per-account view preferences live in GF.db.settings.residents = { filter, sort, groupAlts }. ]]

local _, GF = ...
local API, U, UI, T = GF.API, GF.Util, GF.UI, GF.Theme
local C = T.c

local type, pairs, ipairs, tostring, tonumber = type, pairs, ipairs, tostring, tonumber
local floor, max, min = math.floor, math.max, math.min
local sort, concat = table.sort, table.concat

local ROW_H = 38
local INDENT = 18
local TILE_W = 116
local GROUP_ALTS = "_groupAlts"     -- pseudo-value in the filter menu: toggles alt grouping
local SORT_PICK = "sort:"           -- pseudo-value prefix in the filter menu: picks the sort order
-- small gold caption text (the game's own "label" gold, a shade down so values lead)
local GOLD_DIM = { C.wowGold[1] * 0.82, C.wowGold[2] * 0.82, C.wowGold[3], 1 }
-- data colours, a shade down from the theme's neon so a roster of them doesn't shout
local GOOD = { 0.46, 0.80, 0.56, 1 }
local WARN = { 0.93, 0.76, 0.28, 1 }
local BAD = { 0.92, 0.44, 0.42, 1 }
local REFRESH_COOLDOWN = 10         -- seconds between roster requests from the refresh button
local DOT = "  " .. T:Wrap("dim", "\194\183") .. "  "

local LINES = {
    noGuild = "Not in a guild, mate. Hard to have neighbours without a street.",
    noMatch = "Nobody by that name on this street. Check the spelling, or check the servo.",
    noneHome = "Lights on, nobody home. Typical.",
    noAddon = "Nobody's running Greenfields yet. Spread the word at the servo.",
    noOfficers = "No officers on the books. Anarchy on the street.",
    noMains = "Every single one of them is an alt. Bold strategy.",
    noClass = "Nobody of that persuasion lives here any more.",
    wake = "If this sticks around, open the guild window (J) to give it a nudge.",
    knocking = "Knocking on doors...",
}

local FILTERS = {
    { value = "all", text = "Everyone", icon = "roster" },
    { value = "online", text = "Home now", icon = "dot" },
    { value = "officers", text = "Officers", icon = "shield" },
    { value = "addon", text = "On Greenfields", icon = "bolt" },   -- "Running Greenfields" truncated in the 142px dropdown
    { value = "mains", text = "Mains only", icon = "star" },
}
local SORTS = {
    { value = "online", text = "Online first" },
    { value = "name", text = "By name" },
    { value = "rank", text = "By rank" },
    { value = "level", text = "By level" },
    { value = "class", text = "By class" },
}
local FILTER_BY, SORT_BY = {}, {}
for _, f in ipairs(FILTERS) do FILTER_BY[f.value] = f end
for _, s in ipairs(SORTS) do SORT_BY[s.value] = s end

-------------------------------------------------------------------------------
-- Small guarded helpers
-------------------------------------------------------------------------------
-- Readable() comes before any comparison: comparing a secret value raises on Forever.
local function str(v)
    if type(v) == "string" and API.Readable(v) and v ~= "" then return v end
    return nil
end

local function num(v)
    if type(v) == "number" and API.Readable(v) then return v end
    return nil
end

--- Player keys that came from someone else's doc (profile.main): no escape codes, sane length.
local function cleanName(v)
    v = str(v)
    if v and #v <= 48 and not v:find("|", 1, true) then return v end
    return nil
end

--- Peer versions are whatever the other client sent; only show tidy ones.
local function cleanVersion(v)
    v = str(v)
    if not v then return nil end
    if #v <= 16 and v:match("^[%w%.%-]+$") then return v end
    return "?"
end

--- U.Truncate counts bytes; this never cuts a UTF-8 character in half (accented rank names).
local function shorten(s, n)
    if #s <= n then return s end
    local cut = n - 1
    while cut > 1 do
        local b = s:byte(cut + 1)
        if not b or b < 128 or b >= 192 then break end
        cut = cut - 1
    end
    return s:sub(1, cut) .. "\226\128\166"
end

--- Calls mod:method(...) only if it exists, protected; returns up to two results.
local function call(mod, method, ...)
    if type(mod) ~= "table" or type(mod[method]) ~= "function" then return nil end
    local ok, a, b = GF:Safe("residents:" .. method, mod[method], mod, ...)
    if not ok then return nil end
    return a, b
end

local function classRGB(class)
    local c = API.ClassColor(class)
    if c then return c.r, c.g, c.b end
    return C.dim[1], C.dim[2], C.dim[3]
end

local function pctColor(p)
    if p >= 75 then return GOOD end
    if p >= 45 then return WARN end
    return BAD
end

local function rankColor(key, rankIndex)
    if rankIndex == 0 then return C.wowGold end
    if GF.Roster:IsOfficer(key) then return GOOD end
    return C.dim
end

--- Sizes a FontString to its text, capped at maxW (truncates beyond). Returns the width used.
local function fitText(fs, maxW)
    fs:SetWidth(0)
    local w = (fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth()) or fs:GetStringWidth() or 0
    local use = min(maxW, w + 2)
    fs:SetWidth(max(1, use))
    return use
end

local function openProfile(key)
    if UI.OpenProfile then UI:OpenProfile(key) end
end

local DEFAULTS = { filter = "all", sort = "online", groupAlts = false }
local FALLBACK = { filter = "all", sort = "online", groupAlts = false }

local function prefs()
    local s = GF.db and GF.db.settings
    if type(s) ~= "table" then return FALLBACK end
    if type(s.residents) ~= "table" then s.residents = {} end
    local p = U.Defaults(s.residents, DEFAULTS)
    if not FILTER_BY[p.filter] then p.filter = "all" end
    if not SORT_BY[p.sort] then p.sort = "online" end
    return p
end

-------------------------------------------------------------------------------
-- Data
-------------------------------------------------------------------------------
--- Up to n primary professions from a player's profile doc, best skill first.
local function topProfs(key, n)
    local out = {}
    local doc = GF.Profile and GF.Profile.Get and GF.Profile:Get(key)
    local profs = type(doc) == "table" and type(doc.profs) == "table" and doc.profs
    if not profs then return out end
    local BD = GF.BuffData or {}
    local data, child = BD.professions or {}, BD.childSkillLines or {}
    local best = {}
    for line, rank in pairs(profs) do
        line = tonumber(line)
        line = line and (child[line] or line)
        local d = line and data[line]
        rank = num(rank)
        if d and not d.secondary and rank and rank > (best[line] or 0) then best[line] = rank end
    end
    for line, rank in pairs(best) do
        out[#out + 1] = { line = line, rank = rank, name = data[line].name, icon = data[line].icon }
    end
    sort(out, function(a, b)
        if a.rank ~= b.rank then return a.rank > b.rank end
        return a.line < b.line
    end)
    for i = #out, n + 1, -1 do out[i] = nil end
    return out
end

--- One entry per roster member, with mains/alts resolved once per refresh.
local function buildEntries()
    local R = GF.Roster
    local me = API.MyKey()
    local list, byKey, n = {}, {}, 0
    for key, m in pairs(R:All()) do
        if type(key) == "string" and type(m) == "table" then
            local e = {
                key = key,
                -- R:Class can fall back to a remote profile doc, which may hold anything
                class = str(m.class) or str(R:Class(key)),
                level = num(m.level) or 0,
                rankName = str(m.rankName) or "",
                rankIndex = num(m.rankIndex) or 99,
                zone = str(m.zone),
                note = str(m.note),
                officerNote = str(m.officerNote),
                online = (m.online and true or false) or key == me,
                mobile = m.mobile and true or false,
                version = cleanVersion(call(GF.Comm, "HasAddon", key)),
            }
            local main = cleanName(R:MainOf(key))
            if main and main ~= key then e.main = main end
            n = n + 1
            list[n] = e
            byKey[key] = e
        end
    end
    for i = 1, n do
        local mainE = list[i].main and byKey[list[i].main]
        if mainE then mainE.alts = (mainE.alts or 0) + 1 end
    end
    return list
end

--- Titles, roll call and trades are only looked up for rows actually drawn.
local function extras(e)
    if e.extras then return e.extras end
    local x = {}
    local titles = call(GF.Stats, "TitlesOf", e.key)
    if type(titles) == "table" and type(titles[1]) == "table" then
        x.title = str(titles[1].title)
        x.shame = titles[1].group == "shame"
    end
    local pct = num(call(GF.Attendance, "Percent", e.key, 8))
    if pct then x.att = U.Clamp(floor(pct + 0.5), 0, 100) end
    x.profs = topProfs(e.key, 2)
    e.extras = x
    return x
end

local function passes(e, p, search, classFilter)
    if classFilter and e.class ~= classFilter then return false end
    local f = p.filter
    if f == "online" and not e.online then return false end
    if f == "officers" and not GF.Roster:IsOfficer(e.key) then return false end
    if f == "addon" and not e.version then return false end
    if f == "mains" and e.main then return false end
    if search ~= "" then
        -- a main's name also finds their alts
        return U.Matches(e.key, search) or U.Matches(e.main, search) or U.Matches(e.note, search) or U.Matches(e.zone, search)
            or U.Matches(e.rankName, search) or U.Matches(e.officerNote, search)
            or (e.class ~= nil and U.Matches(API.ClassName(e.class), search))
    end
    return true
end

local function comparator(mode)
    return function(a, b)
        if mode == "online" then
            if a.online ~= b.online then return a.online end
        elseif mode == "rank" then
            if a.rankIndex ~= b.rankIndex then return a.rankIndex < b.rankIndex end
        elseif mode == "level" then
            if a.level ~= b.level then return a.level > b.level end
        elseif mode == "class" then
            local ca, cb = a.class or "~", b.class or "~"
            if ca ~= cb then return ca < cb end
        end
        return a.key < b.key
    end
end

--- Re-orders a sorted list so alts sit directly under their main (when the main is
-- listed too). Chains and cycles in declared mains degrade to top-level rows.
local function groupAlts(sorted)
    local inSet, kids, top = {}, {}, {}
    for _, e in ipairs(sorted) do inSet[e.key] = e end
    for _, e in ipairs(sorted) do
        if e.main and inSet[e.main] then
            kids[e.main] = kids[e.main] or {}
            kids[e.main][#kids[e.main] + 1] = e
        else
            top[#top + 1] = e
        end
    end
    local out, emitted = {}, {}
    local function emit(e, depth)
        if emitted[e.key] then return end
        emitted[e.key] = true
        e.indent = depth > 0
        out[#out + 1] = e
        for _, k in ipairs(kids[e.key] or {}) do emit(k, depth + 1) end
    end
    for _, e in ipairs(top) do emit(e, 0) end
    for _, e in ipairs(sorted) do if not emitted[e.key] then emit(e, 0) end end
    return out
end

-------------------------------------------------------------------------------
-- Row geometry, shared by the column header and every row
-------------------------------------------------------------------------------
local AVATAR_X, NAME_X = 10, 46
local COL_LVL, COL_RANK, COL_ATT, COL_TRADES = 30, 92, 56, 100
local COL_GAP = 12

--- Names get a steady column and whereabouts takes what's left up to a cap, so a row's values
-- don't drift apart on a big window: spare width becomes air between the columns. A narrow
-- window drops roll call (it's still in the tooltip) before anything truncates.
local function columns(w)
    w = w or 0
    local narrow = w < 680
    local nameW = narrow and 160 or 190
    local attW = narrow and 0 or COL_ATT
    local gaps = narrow and 4 or 5
    local free = w - (NAME_X + nameW + COL_LVL + COL_RANK + attW + COL_TRADES) - gaps * COL_GAP
    local zoneW = U.Clamp(free, 50, 240)
    local spare = max(0, free - zoneW)
    local grow = min(70, spare)
    nameW = nameW + grow
    local gap = COL_GAP + floor((spare - grow) / gaps)
    local c = { narrow = narrow, name = NAME_X, nameW = nameW, zoneW = zoneW }
    c.level = c.name + nameW + gap
    c.rank = c.level + COL_LVL + gap
    c.zone = c.rank + COL_RANK + gap
    c.att = c.zone + zoneW + gap
    c.trades = w - COL_TRADES
    return c
end

-------------------------------------------------------------------------------
-- Rows
-------------------------------------------------------------------------------
local function createRow(row)
    -- tree connector for alts folded under their main
    row.elbowV = row:CreateTexture(nil, "ARTWORK")
    row.elbowV:SetColorTexture(C.bronze[1], C.bronze[2], C.bronze[3], 0.55)
    row.elbowV:SetWidth(1)
    row.elbowV:SetPoint("TOPLEFT", row, "TOPLEFT", AVATAR_X + 10, 0)
    row.elbowV:SetPoint("BOTTOMLEFT", row, "LEFT", AVATAR_X + 10, 0)
    row.elbowH = row:CreateTexture(nil, "ARTWORK")
    row.elbowH:SetColorTexture(C.bronze[1], C.bronze[2], C.bronze[3], 0.55)
    row.elbowH:SetSize(7, 1)
    row.elbowH:SetPoint("LEFT", row, "LEFT", AVATAR_X + 10, 0)
    row.avatar = UI:Avatar(row, 28)
    -- the row's one marker: a pip on the portrait's shoulder. A child frame, so it draws over the ring.
    row.pip = CreateFrame("Frame", nil, row.avatar)
    row.pip:SetSize(11, 11)
    row.pip:SetPoint("CENTER", row.avatar, "BOTTOMRIGHT", -4, 4)
    row.pip.back = row.pip:CreateTexture(nil, "ARTWORK")
    row.pip.back:SetTexture(T.tex.circle)
    row.pip.back:SetAllPoints()
    row.pip.back:SetVertexColor(0.02, 0.025, 0.04, 1)
    row.pip.dot = row.pip:CreateTexture(nil, "ARTWORK", nil, 1)
    row.pip.dot:SetTexture(T.tex.circle)
    row.pip.dot:SetSize(8, 8)
    row.pip.dot:SetPoint("CENTER")
    row.name = UI:Text(row, 13, "text", "ui")
    row.gf = UI:Icon(row, 10, "bolt", "ARTWORK", { GOLD_DIM[1], GOLD_DIM[2], GOLD_DIM[3], 0.75 })
    row.gf:SetPoint("LEFT", row.name, "RIGHT", 2, 0)
    row.sub = UI:Text(row, 11, "dim")
    row.sub:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)
    row.level = UI:Text(row, 12, "text", "num")
    row.level:SetJustifyH("RIGHT")
    row.level:SetWidth(COL_LVL)
    row.rankIcon = UI:Icon(row, 10, "shield")
    row.rank = UI:Text(row, 11, "dim")
    row.zone = UI:Text(row, 11, "dim")
    row.att = UI:Text(row, 12, "text", "num")
    row.att:SetJustifyH("RIGHT")
    row.att:SetWidth(COL_ATT)
    row.profs = {}
    for i = 1, 2 do
        local art = UI:IconChip(row, 18)
        local skill = UI:Text(row, 11, "dim", "num")
        skill:SetPoint("LEFT", art, "RIGHT", 3, 0)
        row.profs[i] = { art = art, skill = skill }
    end
    row:SetScript("OnSizeChanged", function(self, w)
        self.cols = columns(w or self:GetWidth())
        if self.entry then GF:Safe("residents:place", self.Place, self) end
    end)

    function row:Place()
        local e, c = self.entry, self.cols
        if not e or not c then return end
        local indent = e.indent and INDENT or 0
        self.avatar:ClearAllPoints()
        self.avatar:SetPoint("LEFT", AVATAR_X + indent, 0)
        local nameX, nameW = c.name + indent, max(40, c.nameW - indent)
        self.name:ClearAllPoints()
        self.name:SetPoint("LEFT", self, "LEFT", nameX, self.hasSub and 7 or 0)
        fitText(self.name, max(20, nameW - (self.gf:IsShown() and 14 or 0)))
        self.sub:SetWidth(nameW)
        self.level:ClearAllPoints()
        self.level:SetPoint("LEFT", self, "LEFT", c.level, 0)
        local rx = c.rank
        self.rankIcon:ClearAllPoints()
        if self.rankIcon:IsShown() then
            self.rankIcon:SetPoint("LEFT", self, "LEFT", rx, 0)
            rx = rx + 14
        end
        self.rank:ClearAllPoints()
        self.rank:SetPoint("LEFT", self, "LEFT", rx, 0)
        self.rank:SetWidth(COL_RANK - (rx - c.rank))
        self.zone:ClearAllPoints()
        self.zone:SetPoint("LEFT", self, "LEFT", c.zone, 0)
        self.zone:SetWidth(c.zoneW)
        self.att:ClearAllPoints()
        self.att:SetPoint("LEFT", self, "LEFT", c.att, 0)
        self.att:SetShown(self.hasAtt and not c.narrow)
        for i, p in ipairs(self.profs) do
            p.art:ClearAllPoints()
            p.art:SetPoint("LEFT", self, "LEFT", c.trades + (i - 1) * 50, 0)
        end
    end
end

local function updateRow(row, e)
    row.entry = e
    if not row.cols then row.cols = columns(row:GetWidth()) end
    local x = extras(e)
    local away = not e.online

    row.pip:SetShown(e.online or e.mobile)
    if e.online then
        row.pip.dot:SetVertexColor(C.green[1], C.green[2], C.green[3], 1)
    else
        row.pip.dot:SetVertexColor(C.blue[1], C.blue[2], C.blue[3], 1)
    end
    row.elbowV:SetShown(e.indent and true or false)
    row.elbowH:SetShown(e.indent and true or false)

    -- away shows once, on the portrait; most of a roster is offline most of the time and still has to read
    row.avatar:SetClass(e.class)
    row.avatar.icon:SetDesaturated(away)
    row.avatar:SetAlpha(away and 0.7 or 1)
    row.name:SetText(U.ClassName(e.key, e.class))
    row.gf:SetShown(e.version ~= nil)

    local parts = {}
    if e.main then parts[#parts + 1] = "alt of " .. U.ClassName(e.main, str(GF.Roster:Class(e.main))) end
    if x.title then
        -- a secondary line colours rather than shouts
        if x.shame then
            parts[#parts + 1] = U.Color(x.title, BAD[1], BAD[2], BAD[3])
        else
            parts[#parts + 1] = U.Color(x.title, GOLD_DIM[1], GOLD_DIM[2], GOLD_DIM[3])
        end
    end
    if e.alts and not e.indent then parts[#parts + 1] = e.alts .. " " .. U.Plural(e.alts, "alt") end
    row.hasSub = #parts > 0
    row.sub:SetText(concat(parts, DOT))
    row.sub:SetShown(row.hasSub)

    row.level:SetText(e.level > 0 and e.level or "")
    UI:SetTextColor(row.level, e.level >= 60 and "text" or "dim")
    row.rank:SetText(shorten(e.rankName, 16))
    UI:SetTextColor(row.rank, rankColor(e.key, e.rankIndex))
    -- only the ranks that run the place earn a mark; 25 identical badges say nothing
    local officer = e.rankIndex ~= 0 and GF.Roster:IsOfficer(e.key)
    row.rankIcon:SetShown(e.rankName ~= "" and (e.rankIndex == 0 or officer))
    if e.rankIndex == 0 then
        UI:SetIcon(row.rankIcon, "crown")
        row.rankIcon:SetVertexColor(C.wowGold[1], C.wowGold[2], C.wowGold[3], 1)
    elseif officer then
        UI:SetIcon(row.rankIcon, "shield")
        row.rankIcon:SetVertexColor(GOOD[1], GOOD[2], GOOD[3], 1)
    end
    row.zone:SetText(e.zone or (e.mobile and "On the app") or "")

    row.hasAtt = x.att ~= nil
    if x.att then
        row.att:SetText(x.att .. "%")
        UI:SetTextColor(row.att, pctColor(x.att))
    end
    for i, slot in ipairs(row.profs) do
        local p = x.profs[i]
        if p then
            slot.art:SetIcon(p.icon)
            slot.art:SetAlpha(away and 0.75 or 1)
            slot.skill:SetText(p.rank)
            UI:SetTextColor(slot.skill, p.rank >= 300 and "wowGold" or "dim")
            slot.art:Show()
            slot.skill:Show()
        else
            slot.art:Hide()
            slot.skill:Hide()
        end
    end
    row:Place()
end

local function rowTooltip(row, e)
    local x = extras(e)
    local lines = {}
    local cls = e.class and API.ClassName(e.class) or "Mystery class"
    lines[#lines + 1] = { (e.level > 0 and ("Level " .. e.level .. " ") or "") .. cls, e.rankName }
    if e.online then
        lines[#lines + 1] = { "Whereabouts", e.zone or "Somewhere out there" }
    elseif e.mobile then
        lines[#lines + 1] = { "Status", "On the mobile app" }
    else
        lines[#lines + 1] = { "Last seen in", e.zone or "Parts unknown" }
    end
    if e.main then lines[#lines + 1] = { "Main", U.ClassName(e.main, str(GF.Roster:Class(e.main))) } end
    if e.alts then lines[#lines + 1] = { "Alts", tostring(e.alts) } end
    lines[#lines + 1] = { "Greenfields", e.version and T:Wrap("green", e.version == "?" and "Installed" or e.version)
        or T:Wrap("faint", "Not installed") }
    if x.title then lines[#lines + 1] = { "Title", T:Wrap(x.shame and "red" or "gold", x.title) } end
    if x.att then lines[#lines + 1] = { "Roll call (8 weeks)", x.att .. "%" } end
    for _, p in ipairs(x.profs) do lines[#lines + 1] = { p.name, tostring(p.rank) } end
    if e.note or e.officerNote then lines[#lines + 1] = " " end
    if e.note then lines[#lines + 1] = T:Wrap("dim", "Note: ") .. e.note end
    if e.officerNote then lines[#lines + 1] = T:Wrap("yellow", "Officer note: ") .. e.officerNote end
    lines[#lines + 1] = " "
    lines[#lines + 1] = T:Wrap("dim", "Click for their profile" .. "  \194\183  " .. "Right-click for options")
    UI:Tip(row, U.ClassName(e.key, e.class), lines, "ANCHOR_CURSOR")
end

local function invite(key)
    local ok, why = API.Invite(key)
    if not ok then
        local text = why == "clash" and "Two residents answer to that name and the addon won't guess. /invite the full name yourself."
            or "Couldn't send that invite right now. Try again in a sec."
        UI:Toast({ title = "No dice", text = text, icon = "warning", style = "red", key = "gf-invite-fail" })
    end
end

--- The right-click menu for a resident; `e` is a roster member or a row made from one.
function UI:ResidentMenu(e)
    local isMe = e.key == API.MyKey()
    local reachable = e.online or e.mobile
    UI:OpenMenu(nil, {
        { text = U.ClassName(e.key, e.class), title = true },
        { text = "View profile", icon = "eye", func = function() openProfile(e.key) end },
        { text = "Whisper", icon = "bubble", disabled = isMe or not reachable, func = function() UI:Whisper(e.key) end },
        { text = "Invite to group", icon = "plus", disabled = isMe or not e.online, func = function() invite(e.key) end },
        { text = "Copy name", icon = "clipboard", func = function() UI:CopyBox("Copy name", e.key) end },
    }, { width = 170 })
end

-------------------------------------------------------------------------------
-- Summary strip
-------------------------------------------------------------------------------
local render -- forward: (page, resetScroll)

--- Cell state: a warm wash on hover; the active quick filter gets the gold "selected"
-- treatment the sidebar and tabs use (gold underline over a gold glow).
local function tileBorder(t)
    t.hl:SetShown((t.hover and not t.active) and true or false)
    t.selWash:SetShown(t.active and true or false)
    t.selLine:SetShown(t.active and true or false)
end

--- Tooltip (and optional left-click) for a plain frame; tiles also get their hover state.
local function hoverTip(f, fn, onClick)
    f:EnableMouse(true)
    f:SetScript("OnEnter", function(self)
        self.hover = true
        if self.isTile then tileBorder(self) end
        local title, lines = fn(self)
        if title then UI:Tip(self, title, lines) end
    end)
    f:SetScript("OnLeave", function(self)
        self.hover = false
        if self.isTile then tileBorder(self) end
        UI:HideTip()
    end)
    if onClick then
        f:SetScript("OnMouseUp", function(self, button)
            if button ~= "LeftButton" or not self:IsMouseOver() then return end
            UI.Sound(856)
            GF:Safe("residents:tile", onClick, self)
        end)
    end
end

--- One cell of the summary plate: a number and what it counts, split from its neighbour by a
-- fine rule. They share one plate so the strip reads as a single fact line, not a row of KPI boxes.
local function statTile(parent, label)
    local t = CreateFrame("Frame", nil, parent)
    t:SetWidth(TILE_W)
    t.isTile = true
    t.hl = t:CreateTexture(nil, "BACKGROUND", nil, 2)
    t.hl:SetAllPoints()
    t.hl:SetColorTexture(1, 0.86, 0.55, 0.05)
    t.hl:SetBlendMode("ADD")
    t.hl:Hide()
    t.selWash = t:CreateTexture(nil, "BACKGROUND", nil, 3)
    t.selWash:SetPoint("BOTTOMLEFT")
    t.selWash:SetPoint("BOTTOMRIGHT")
    t.selWash:SetHeight(30)
    UI:Gradient(t.selWash, "VERTICAL", 1, 0.78, 0.25, 0.10, 0)
    t.selWash:Hide()
    t.selLine = t:CreateTexture(nil, "ARTWORK")
    t.selLine:SetPoint("BOTTOMLEFT", 8, 1)
    t.selLine:SetPoint("BOTTOMRIGHT", -8, 1)
    t.selLine:SetHeight(2)
    t.selLine:SetColorTexture(C.wowGold[1], C.wowGold[2], C.wowGold[3], 1)
    t.selLine:Hide()
    t.sep = t:CreateTexture(nil, "ARTWORK")
    t.sep:SetColorTexture(C.bronze[1], C.bronze[2], C.bronze[3], 0.30)
    t.sep:SetWidth(1)
    t.sep:SetPoint("TOPRIGHT", 0, -10)
    t.sep:SetPoint("BOTTOMRIGHT", 0, 10)
    t.value = UI:Text(t, 20, "text", "ui")
    t.value:SetPoint("TOPLEFT", 14, -11)
    t.extra = UI:Text(t, 11, "dim")
    t.extra:SetPoint("BOTTOMLEFT", t.value, "BOTTOMRIGHT", 6, 2)
    t.label = UI:Text(t, 11, "dim")
    t.label:SetPoint("TOPLEFT", 14, -37)
    t.label:SetText(label)
    return t
end

local function toggleClass(page, class)
    page.classFilter = (page.classFilter ~= class) and class or nil
    render(page, true)
end

local function layoutMix(tile)
    local bar = tile.bar
    -- segments sit inside the groove's lit edge
    local w, h = (bar:GetWidth() or 0) - 2, (bar:GetHeight() or 12) - 2
    for _, seg in pairs(tile.segs) do seg:Hide() end
    local data, total = tile.data or {}, tile.total or 0
    if w <= 0 or total <= 0 then return end
    -- cumulative rounding: segments always add up to the bar, and the smallest class at the
    -- end can't be squeezed out by its neighbours rounding up
    local x, n, cum = 0, #data, 0
    for i, d in ipairs(data) do
        cum = cum + d.n
        local sw = ((i == n) and w or floor(w * cum / total + 0.5)) - x
        local seg = tile.segs[d.class]
        if seg and sw >= 1 then
            seg:ClearAllPoints()
            seg:SetPoint("TOPLEFT", bar, "TOPLEFT", x + 1, -1)
            seg:SetSize(max(1, sw - ((i < n and sw > 2) and 1 or 0)), h)
            seg:SetAlpha((tile.page.classFilter and tile.page.classFilter ~= d.class) and 0.25 or 1)
            seg:Show()
        end
        x = x + sw
    end
end

--- As many classes as fit on one line, biggest first; the bar's segments name the rest on hover.
local function fitLegend(tile)
    local data = tile.data or {}
    if (tile.total or 0) == 0 then
        tile.legend:SetText("Nobody to count yet.")
        return
    end
    local room = (tile.legend:GetWidth() or 0)
    local text = ""
    for i = 1, #data do
        local bit = U.Color(API.ClassName(data[i].class) .. " " .. data[i].n, U.ClassColorHex(data[i].class))
        local try = i == 1 and bit or (text .. "   " .. bit)
        tile.legend:SetText(try)
        local tw = (tile.legend.GetUnboundedStringWidth and tile.legend:GetUnboundedStringWidth()) or tile.legend:GetStringWidth() or 0
        if i > 1 and room > 0 and tw > room then break end
        text = try
    end
    tile.legend:SetText(text)
end

local function mixSegment(tile, class)
    local s = CreateFrame("Button", nil, tile.bar)
    s.class = class
    s.tex = s:CreateTexture(nil, "ARTWORK")
    s.tex:SetAllPoints()
    local r, g, b = classRGB(class)
    -- shaded status-bar fill, tinted to the class
    s.tex:SetTexture(T.tex.barFill)
    s.tex:SetVertexColor(r, g, b, 1)
    s.hl = s:CreateTexture(nil, "OVERLAY")
    s.hl:SetAllPoints()
    s.hl:SetColorTexture(1, 1, 1, 0.25)
    s.hl:Hide()
    s:RegisterForClicks("LeftButtonUp")
    s:SetScript("OnEnter", function(self)
        self.hl:Show()
        local d = tile.byClass and tile.byClass[self.class]
        if not d then return end
        local filtering = tile.page.classFilter == self.class
        UI:Tip(self, U.Color(U.Plural(d.n, API.ClassName(self.class)), U.ClassColorHex(self.class)), {
            { "On the street", tostring(d.n) },
            { "Home now", tostring(d.online) },
            { "Share", U.Pct(d.n, tile.total) .. "%" },
            " ",
            T:Wrap("dim", filtering and "Click to show everyone again" or ("Click to show only " .. U.Plural(2, API.ClassName(self.class)))),
        })
    end)
    s:SetScript("OnLeave", function(self) self.hl:Hide(); UI:HideTip() end)
    s:SetScript("OnClick", function(self)
        UI.Sound(856)
        GF:Safe("residents:mix", toggleClass, tile.page, self.class)
    end)
    s:Hide()
    tile.segs[class] = s
    return s
end

local function mixTile(parent, page)
    local t = CreateFrame("Frame", nil, parent)
    t.page = page
    t.segs = {}
    t.title = UI:Text(t, 12, "wowGold", "ui")
    t.title:SetPoint("TOPLEFT", 14, -10)
    t.title:SetText("Street mix")
    t.count = UI:Text(t, 11, "dim")
    t.count:SetPoint("TOPRIGHT", -14, -11)
    t.count:SetJustifyH("RIGHT")
    t.bar = CreateFrame("Frame", nil, t)
    t.bar:SetPoint("TOPLEFT", 14, -27)
    t.bar:SetPoint("TOPRIGHT", -14, -27)
    t.bar:SetHeight(10)
    t.track = UI:Nine(t.bar, "groove", "BACKGROUND")
    t.bar:SetScript("OnSizeChanged", function()
        GF:Safe("residents:mix", layoutMix, t)
        GF:Safe("residents:mix", fitLegend, t)
    end)
    t.legend = UI:Text(t, 11, "dim")
    t.legend:SetPoint("TOPLEFT", 14, -42)
    t.legend:SetPoint("TOPRIGHT", -14, -42)
    for _, class in ipairs(API.CLASSES) do mixSegment(t, class) end
    return t
end

local function updateMix(tile, entries)
    local byClass, total = {}, 0
    for _, e in ipairs(entries) do
        if e.class then
            local d = byClass[e.class]
            if not d then d = { class = e.class, n = 0, online = 0 }; byClass[e.class] = d end
            d.n = d.n + 1
            if e.online then d.online = d.online + 1 end
            total = total + 1
        end
    end
    local data = {}
    for class, d in pairs(byClass) do
        if not tile.segs[class] then mixSegment(tile, class) end
        data[#data + 1] = d
    end
    sort(data, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return a.class < b.class
    end)
    tile.data, tile.byClass, tile.total = data, byClass, total
    tile.count:SetText(total == 0 and "" or (#data .. " " .. U.Plural(#data, "class", "classes")))
    fitLegend(tile)
    layoutMix(tile)
end

local function updateSummary(page, entries)
    local total, online, gf, gfHome, alts = #entries, 0, 0, 0, 0
    for _, e in ipairs(entries) do
        if e.online then online = online + 1 end
        if e.version then
            gf = gf + 1
            if e.online then gfHome = gfHome + 1 end
        end
        if e.main then alts = alts + 1 end
    end
    local tiles = page.tiles
    tiles.total.value:SetText(total)
    tiles.total.extra:SetText(alts > 0 and (alts .. " " .. U.Plural(alts, "alt")) or "")
    tiles.online.value:SetText(online)
    tiles.online.extra:SetText(total > 0 and ("of " .. total) or "")
    tiles.addon.value:SetText(gf)
    -- "3  3 home" just stutters: only worth saying when it's not all of them
    tiles.addon.extra:SetText((gfHome > 0 and gfHome < gf) and (gfHome .. " home") or "")
    page.counts = { total = total, online = online, gf = gf, gfHome = gfHome, alts = alts }
    updateMix(page.mix, entries)
end

-------------------------------------------------------------------------------
-- Column header (the sortable labels double as sort buttons)
-------------------------------------------------------------------------------
local function setSort(page, mode)
    prefs().sort = mode
    render(page, true)
end

local function colLabel(parent, page, text, sortKey, alignRight)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(22)
    b.label = UI:Text(b, 11, GOLD_DIM, "ui")
    b.label:SetPoint(alignRight and "RIGHT" or "LEFT", 0, 0)
    b.label:SetText(text)
    b.sortKey = sortKey
    b:SetWidth((b.label:GetStringWidth() or 30) + (sortKey and 16 or 4))
    if sortKey then
        b.chev = UI:Icon(b, 9, "chevron_down", "OVERLAY", "wowGold")
        if alignRight then
            b.chev:SetPoint("RIGHT", b.label, "LEFT", -3, 0)
        else
            b.chev:SetPoint("LEFT", b.label, "RIGHT", 3, 0)
        end
        b.chev:Hide()
        b:SetScript("OnEnter", function(self)
            UI:SetTextColor(self.label, "text")
            UI:Tip(self, nil, { "Sort " .. string.lower(SORT_BY[self.sortKey].text) })
        end)
        b:SetScript("OnLeave", function(self)
            UI:SetTextColor(self.label, prefs().sort == self.sortKey and "wowGold" or GOLD_DIM)
            UI:HideTip()
        end)
        b:SetScript("OnClick", function(self)
            UI.Sound(841)
            GF:Safe("residents:sort", setSort, page, self.sortKey)
        end)
    else
        b:EnableMouse(false)
    end
    return b
end

local function buildColumns(panel, page)
    local cols = CreateFrame("Frame", nil, panel)
    -- lines up with the list's rows, which stop short of its scrollbar
    cols:SetPoint("TOPLEFT", 8, -3)
    cols:SetPoint("TOPRIGHT", -18, -3)
    cols:SetHeight(24)
    cols.labels = {
        online = colLabel(cols, page, "", "online"),
        name = colLabel(cols, page, "Resident", "name"),
        level = colLabel(cols, page, "Lvl", "level", true),
        rank = colLabel(cols, page, "Rank", "rank"),
        zone = colLabel(cols, page, "Whereabouts"),
        att = colLabel(cols, page, "Roll call", nil, true),
        trades = colLabel(cols, page, "Trades"),
    }
    -- online-first is headed by a tiny pip over the portraits instead of a word
    local on = cols.labels.online
    on.dot = on:CreateTexture(nil, "ARTWORK")
    on.dot:SetTexture(T.tex.circle)
    on.dot:SetSize(8, 8)
    on.dot:SetVertexColor(C.green[1], C.green[2], C.green[3], 0.8)
    on.dot:SetPoint("LEFT", 0, 0)
    on.chev:ClearAllPoints()
    on.chev:SetPoint("LEFT", on.dot, "RIGHT", 3, 0)
    on:SetWidth(22)
    local function place(self, w)
        local c = columns(w or self:GetWidth())
        local L = self.labels
        for _, b in pairs(L) do b:ClearAllPoints() end
        L.online:SetPoint("LEFT", self, "LEFT", AVATAR_X + 6, 0)
        L.name:SetPoint("LEFT", self, "LEFT", c.name, 0)
        L.level:SetPoint("RIGHT", self, "LEFT", c.level + COL_LVL, 0)
        L.rank:SetPoint("LEFT", self, "LEFT", c.rank, 0)
        L.zone:SetPoint("LEFT", self, "LEFT", c.zone, 0)
        L.att:SetPoint("RIGHT", self, "LEFT", c.att + COL_ATT, 0)
        L.att:SetShown(not c.narrow)
        L.trades:SetPoint("LEFT", self, "LEFT", c.trades, 0)
    end
    cols:SetScript("OnSizeChanged", place)
    -- anchor the labels now too: they have no points at all until the first layout otherwise
    place(cols, cols:GetWidth())
    function cols:Highlight(mode)
        for _, b in pairs(self.labels) do
            if b.sortKey then
                local active = b.sortKey == mode
                UI:SetTextColor(b.label, active and "wowGold" or GOLD_DIM)
                b.chev:SetShown(active)
            end
        end
    end
    return cols
end

-------------------------------------------------------------------------------
-- Page
-------------------------------------------------------------------------------
local rosterPage
local lastRequest = -REFRESH_COOLDOWN

local function setSpinning(page, on)
    local spin = page.refresh and page.refresh.spin
    if not spin then return end
    if on then spin:Play() else spin:Stop() end
end

local function requestRefresh(page)
    local now = API.Time()
    if now - lastRequest >= REFRESH_COOLDOWN then
        lastRequest = now
        page.pending = true
        setSpinning(page, true)
        GF.Roster:Refresh()
        GF:After(5, function()
            if page.pending then
                page.pending = false
                setSpinning(page, false)
                UI:RefreshPage("roster")
            end
        end)
    end
    render(page, false)
end

local function emptyText(page, p)
    if not API.InGuild() then return LINES.noGuild end
    if (page.counts and page.counts.total or 0) == 0 then
        local fl = GF.Flavor and GF.Flavor.emptyStates and GF.Flavor.emptyStates.roster or "No one's home. Suspicious."
        return fl .. "\n" .. LINES.wake
    end
    if (page.search or "") ~= "" then return LINES.noMatch end
    if page.classFilter then return LINES.noClass end
    if p.filter == "online" then return LINES.noneHome end
    if p.filter == "addon" then return LINES.noAddon end
    if p.filter == "officers" then return LINES.noOfficers end
    if p.filter == "mains" then return LINES.noMains end
    return LINES.noMatch
end

local function subtitle(page, p, shown)
    if page.pending then return LINES.knocking end
    local cnt = page.counts or {}
    local total = cnt.total or 0
    if total == 0 then return "Nobody on the books yet." end
    local filtered = (page.search or "") ~= "" or p.filter ~= "all" or page.classFilter
    if filtered then
        local s = "Showing " .. shown .. " of " .. total .. " " .. U.Plural(total, "resident")
        if page.classFilter then s = s .. DOT .. U.Plural(2, API.ClassName(page.classFilter)) .. " only" end
        return s .. "."
    end
    return total .. " on the books, " .. (cnt.online or 0) .. " home right now."
end

--- rebuild: re-read the roster (data changed). Search, sort and filter changes reuse the
-- entries, so typing in the search box doesn't redo every MainOf/HasAddon lookup and the
-- per-row extras (titles, roll call, trades) stay cached.
render = function(page, resetScroll, rebuild)
    local p = prefs()
    if rebuild or not page.entries then
        page.entries = buildEntries()
        updateSummary(page, page.entries)
    else
        layoutMix(page.mix)   -- class-filter dimming
    end
    local entries = page.entries
    local search = page.search or ""
    local shown = {}
    for _, e in ipairs(entries) do
        e.indent = nil        -- set again by groupAlts below; entries outlive one render now
        if passes(e, p, search, page.classFilter) then shown[#shown + 1] = e end
    end
    for _, t in pairs(page.tiles) do
        t.active = t.filter ~= "all" and t.filter == p.filter
        tileBorder(t)
    end
    sort(shown, comparator(p.sort))
    if p.groupAlts and p.filter ~= "mains" then shown = groupAlts(shown) end
    page.list:SetItems(shown, not resetScroll)
    if #shown == 0 then
        page.empty:SetText(emptyText(page, p))
        page.empty:Show()
    else
        page.empty:Hide()
    end
    page.header:SetSubtitle(subtitle(page, p, #shown))
    page.cols:Highlight(p.sort)
    page.filterDD:Refresh()
end

--- Who to show, then how to order them: the column headers cover most sorts, this covers them all.
local function filterItems()
    local p = prefs()
    local items = { { text = "Show", title = true } }
    for _, f in ipairs(FILTERS) do items[#items + 1] = f end
    items[#items + 1] = { separator = true }
    items[#items + 1] = { text = "Group alts under mains", value = GROUP_ALTS, icon = "minus", checked = p.groupAlts and true or false }
    items[#items + 1] = { separator = true }
    items[#items + 1] = { text = "Sort", title = true }
    for _, s in ipairs(SORTS) do
        items[#items + 1] = { text = s.text, value = SORT_PICK .. s.value, checked = p.sort == s.value }
    end
    return items
end

local function build(page)
    rosterPage = page
    page.search = ""
    local header = UI:PageHeader(page, "Residents", "")
    page.header = header

    -- header actions, added right to left
    local refresh = UI:IconButton(header, "sync", 26, "Ask the server for a fresh roster", function() requestRefresh(page) end)
    if refresh.icon.CreateAnimationGroup then
        local ag = refresh.icon:CreateAnimationGroup()
        local rot = ag:CreateAnimation("Rotation")
        rot:SetDegrees(-360)
        rot:SetDuration(0.9)
        ag:SetLooping("REPEAT")
        refresh.spin = ag
    end
    page.refresh = refresh
    header:AddAction(refresh)

    page.filterDD = UI:Dropdown(header, {
        width = 142, items = filterItems, tooltip = "Who to show, and in what order",
        get = function() return prefs().filter end,
        set = function(v)
            local p = prefs()
            if v == GROUP_ALTS then
                p.groupAlts = not p.groupAlts
            elseif FILTER_BY[v] then
                p.filter = v
            elseif type(v) == "string" and v:sub(1, #SORT_PICK) == SORT_PICK and SORT_BY[v:sub(#SORT_PICK + 1)] then
                p.sort = v:sub(#SORT_PICK + 1)
            end
            render(page, true)
        end,
    })
    header:AddAction(page.filterDD)

    page.searchBox = UI:Search(header, {
        width = 180, placeholder = "Search the street...",
        onChange = function(text)
            page.search = U.Trim(text or "")
            render(page, true)
        end,
    })
    header:AddAction(page.searchBox)
    -- the well art is see-through, and the street's lit windows were showing through the box
    local solid = page.searchBox:CreateTexture(nil, "BACKGROUND", nil, -7)
    solid:SetPoint("TOPLEFT", 2, -2)
    solid:SetPoint("BOTTOMRIGHT", -2, 2)
    solid:SetColorTexture(0.03, 0.035, 0.05, 1)

    -- the summary plate: three counts plus the class mix, which takes the rest of the width
    local strip = UI:Card(page)
    strip:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -14)
    strip:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -14)
    strip:SetHeight(64)
    local tiles = {
        total = statTile(strip, "Residents"),
        online = statTile(strip, "Home now"),
        addon = statTile(strip, "On Greenfields"),
    }
    tiles.total:SetPoint("TOPLEFT", 0, 0)
    tiles.total:SetPoint("BOTTOMLEFT", 0, 0)
    tiles.online:SetPoint("TOPLEFT", tiles.total, "TOPRIGHT", 0, 0)
    tiles.online:SetPoint("BOTTOMLEFT", tiles.total, "BOTTOMRIGHT", 0, 0)
    tiles.addon:SetPoint("TOPLEFT", tiles.online, "TOPRIGHT", 0, 0)
    tiles.addon:SetPoint("BOTTOMLEFT", tiles.online, "BOTTOMRIGHT", 0, 0)
    -- the cells double as quick filters (click again to show everyone)
    tiles.total.filter, tiles.online.filter, tiles.addon.filter = "all", "online", "addon"
    local function quickFilter(t)
        local p = prefs()
        p.filter = (p.filter == t.filter) and "all" or t.filter
        if t.filter == "all" then page.classFilter = nil end
        render(page, true)
    end
    hoverTip(tiles.total, function()
        local c = page.counts or {}
        return "Residents", { "Everyone on the guild roster, mains and alts.", { "Alts", tostring(c.alts or 0) },
            " ", T:Wrap("dim", "Click to show everyone, every class") }
    end, quickFilter)
    hoverTip(tiles.online, function(t)
        local c = page.counts or {}
        return "Home now", { "Logged in right this minute.", { "Share of the street", U.Pct(c.online or 0, c.total or 0) .. "%" },
            " ", T:Wrap("dim", t.active and "Click to show everyone again" or "Click to show only who's home") }
    end, quickFilter)
    hoverTip(tiles.addon, function(t)
        local c = page.counts or {}
        return "On Greenfields", { "Residents running the addon. Titles, roll call and trades only show up for them.",
            { "Home right now", tostring(c.gfHome or 0) },
            " ", T:Wrap("dim", t.active and "Click to show everyone again" or "Click to show only Greenfields users") }
    end, quickFilter)
    page.tiles = tiles
    page.mix = mixTile(strip, page)
    page.mix:SetPoint("TOPLEFT", tiles.addon, "TOPRIGHT", 0, 0)
    page.mix:SetPoint("BOTTOMRIGHT", strip, "BOTTOMRIGHT", 0, 0)

    -- the list itself: a card whose top edge is a darker column band, like the game's roster frames
    local panel = UI:Card(page)
    panel:SetPoint("TOPLEFT", strip, "BOTTOMLEFT", 0, -16)
    panel:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
    panel.band = panel:CreateTexture(nil, "BACKGROUND", nil, 3)
    panel.band:SetPoint("TOPLEFT", 1, -1)
    panel.band:SetPoint("TOPRIGHT", -1, -1)
    panel.band:SetHeight(27)
    panel.band:SetColorTexture(0, 0, 0, 0.28)
    page.cols = buildColumns(panel, page)
    local div = UI:Hairline(panel, "bronze", 0.5, "none")
    div:SetPoint("TOPLEFT", 1, -28)
    div:SetPoint("TOPRIGHT", -1, -28)
    page.list = UI:List(panel, {
        rowHeight = ROW_H, spacing = 0,
        createRow = createRow, updateRow = updateRow,
        onEnter = rowTooltip,
        onClick = function(e, row, button)
            UI:HideTip()
            if button == "RightButton" then UI:ResidentMenu(e) else openProfile(e.key) end
        end,
    })
    page.list:SetPoint("TOPLEFT", 8, -29)
    page.list:SetPoint("BOTTOMRIGHT", -8, 8)
    page.empty = UI:Empty(panel, "", "roster", { width = 500 })
    page.empty:Hide()
end

local function onShow(page)
    -- shown, or data changed (RefreshPage): re-read the roster
    render(page, false, true)
end

UI:RegisterPage({
    key = "roster", title = "Residents",
    subtitle = "Everyone on the street. Mains, alts, and who's actually home.",
    icon = "roster", group = "community", order = 10,
    build = build, onShow = onShow,
    onHide = function(page)
        UI:CloseMenu()
        if page then setSpinning(page, false) end
    end,
})

-------------------------------------------------------------------------------
-- Live updates (debounced; RefreshPage is a no-op unless the page is on screen)
-------------------------------------------------------------------------------
-- config: the officer rank threshold lives there (rank colours, Officers filter);
-- loot: some titles (SR rolls won) are computed from the loot ledger
local WATCH = { profile = true, stats = true, attendance = true, config = true, loot = true }

local function queueRefresh()
    GF:Debounce("residents:refresh", 0.4, function() UI:RefreshPage("roster") end)
end

GF:On("GF_ROSTER_UPDATED", function()
    if rosterPage and rosterPage.pending then
        rosterPage.pending = false
        setSpinning(rosterPage, false)
    end
    queueRefresh()
end)
GF:On("GF_PEER_SEEN", queueRefresh)
GF:On("GF_STORE_CHANGED", function(name)
    if WATCH[name] then queueRefresh() end
end)
