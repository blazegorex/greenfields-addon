--[[ Greenfields - Modules/Profile.lua
     The hidden "profile" page: one resident's full file, opened from the Residents list,
     the sidebar me-card, or anywhere else through GF.UI:OpenProfile(key).

     A character-sheet hero (tooled leather under a gold rim: gold-ringed class portrait
     with a level medallion, class-coloured name, level/race/class, rank, presence, mains
     and alts, Greenfields version, whisper/invite) sits over a masonry of cards: Roll Call,
     Titles, Stats, Badges, Tradie licences, Brings to the raid and Loot. Titles, badges,
     stats, trades and buffs show their game art in gold action-button frames; crowns held
     and soft-res wins get the achievement glint when a file opens. Each card pulls
     from another module behind a guard and has its own cheeky empty line when that module
     or its data is missing. Data is gathered once per show; resizing only re-lays out.

     Also adds /gf profile [name]. ]]

local _, GF = ...
local API, U, UI, T = GF.API, GF.Util, GF.UI, GF.Theme
local C = T.c

local type, pairs, ipairs, tostring, tonumber = type, pairs, ipairs, tostring, tonumber
local floor, ceil, max, min, abs = math.floor, math.ceil, math.max, math.min, math.abs
local sort, concat = table.sort, table.concat

local GAP = 16
local HERO_H = 144
local PORTRAIT = 94         -- the hero's gold-ringed portrait
local TEXT_X = 134          -- where the hero's text column starts
local FAM_Y = -124          -- vertical centre of the hero's mains/alts line
local LOOT_SHOWN = 8
local LOOT_SCAN = 250
local MAX_SKILL = 300
local DOT = "  " .. T:Wrap("faint", "\194\183") .. "  "
-- small gold caption text (the game's own "label" gold, a shade down so values lead)
local GOLD_DIM = { C.wowGold[1] * 0.82, C.wowGold[2] * 0.82, C.wowGold[3], 1 }
local MAXED = { 0.86, 0.64, 0.08, 1 }   -- burnished gold for a maxed-out skill bar

local LINES = {
    titlesNone = "No crowns yet. Give it a raid night or two.",
    titlesOff = "The Hall of Fame isn't open on this client yet.",
    badgesNone = "No badges. Not even a participation ribbon.",
    badgesOff = "Badges aren't being handed out on this client yet.",
    statsNone = "Clean record. Suspiciously clean.",
    statsOff = "Stats aren't being tracked on this client yet.",
    noAddon = "No Greenfields, no stats. Someone tell them it's free.",
    rollOff = "Roll call isn't running on this client yet.",
    rollNone = "No raids recorded yet. Attendance: theoretical.",
    profsNone = "No trade certificates on file. Probably cash-in-hand.",
    profsNoDoc = "No profile synced yet. They need Greenfields for this one.",
    lootOff = "The loot ledger isn't open on this client yet.",
    lootNone = "Hasn't won a thing. The bin chickens are embarrassed for them.",
    buffsNone = "Brings snacks. Probably.",
    buffsUnknown = "Class unknown. Could bring anything. Could bring nothing.",
    buffsGuess = "Going by class alone. Talents and ranks not checked.",
    noAlts = "No alts. One and done.",
    stranger = "Not on the roster and no profile on file. A mystery neighbour.",
    noKey = "Still working out who you are. Give it a sec.",
}

local HOW = {
    SR = { "SR", "yellow" }, MS = { "MS", "green" }, OS = { "OS", "blue" },
    ROLL = { "ROLL", "dim" }, FREE = { "FREE", "dim" },
}

local WHO = { all = "Everyone", mana = "Casters and healers", physical = "Melee and hunters" }

local RACES = { NightElf = "Night Elf", Scourge = "Undead" }

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

--- Positive number or nil (a roster level of 0 means "unknown", not "level 0").
local function pos(v)
    v = num(v)
    if v and v > 0 then return v end
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

local function has(mod, method) return type(mod) == "table" and type(mod[method]) == "function" end

--- Calls mod:method(...) only if it exists, protected; returns up to two results.
local function call(mod, method, ...)
    if not has(mod, method) then return nil end
    local ok, a, b = GF:Safe("profile:" .. method, mod[method], mod, ...)
    if not ok then return nil end
    return a, b
end

local function classRGB(class)
    local c = API.ClassColor(class)
    if c then return c.r, c.g, c.b end
    return C.dim[1], C.dim[2], C.dim[3]
end

local function pctColor(p)
    if p >= 75 then return "green" end
    if p >= 45 then return "yellow" end
    return "red"
end

--- race comes from the player's own (remote) profile doc: letters only, or nothing
local function raceName(file)
    if not file or #file > 24 or not file:match("^%a+$") then return nil end
    return RACES[file] or (file:gsub("(%l)(%u)", "%1 %2"))
end

--- Sizes a FontString to its text, capped at maxW. Returns the width used.
local function fitText(fs, maxW)
    fs:SetWidth(0)
    local w = (fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth()) or fs:GetStringWidth() or 0
    local use = min(maxW, w + 2)
    fs:SetWidth(max(1, use))
    return use
end

local function cleanKey(k)
    if type(k) ~= "string" or not API.Readable(k) or k == "" then return nil end
    return API.Key(k) or k
end

--- Tooltip on a plain frame. hl = true adds a soft hover wash inside the frame's rim;
-- shine = true sweeps an achievement-style glint across it on hover (prized things only).
local function tipOn(f, hl, shine)
    f:EnableMouse(true)
    if hl then
        f.hl = f:CreateTexture(nil, "ARTWORK", nil, -2)
        f.hl:SetPoint("TOPLEFT", 2, -2)
        f.hl:SetPoint("BOTTOMRIGHT", -2, 2)
        f.hl:SetColorTexture(1, 0.86, 0.55, 0.07)
        f.hl:SetBlendMode("ADD")
        f.hl:Hide()
    end
    f:SetScript("OnEnter", function(self)
        if self.hl then self.hl:Show() end
        if shine or self.shine then UI:Shine(self, 0.6) end
        if self.tipTitle then UI:Tip(self, self.tipTitle, self.tipLines) end
    end)
    f:SetScript("OnLeave", function(self)
        if self.hl then self.hl:Hide() end
        UI:HideTip()
    end)
end

--- Inner panel in the kit's card language: a dark inset over the card's stone, bronze rim.
local function slab(f, alpha, rimAlpha)
    f.slab = f:CreateTexture(nil, "BACKGROUND")
    f.slab:SetPoint("TOPLEFT", 1, -1)
    f.slab:SetPoint("BOTTOMRIGHT", -1, 1)
    f.slab:SetColorTexture(0, 0, 0, alpha or 0.3)
    f.rim = f:CreateTexture(nil, "BORDER")
    f.rim:SetAllPoints()
    UI.Sliced(f.rim, T.tex.frameBronze, 8)
    f.rim:SetVertexColor(1, 1, 1, rimAlpha or 0.75)
end

--- Classic status bar: dark well, bronze edge, shaded fill. :SetValue(0..1), :SetColor(c)
local function statusBar(parent, h)
    local b = CreateFrame("Frame", nil, parent)
    b:SetHeight(h or 10)
    b.edge = b:CreateTexture(nil, "BACKGROUND")
    b.edge:SetAllPoints()
    b.edge:SetColorTexture(C.bronze[1], C.bronze[2], C.bronze[3], 0.85)
    b.well = b:CreateTexture(nil, "BACKGROUND", nil, 1)
    b.well:SetPoint("TOPLEFT", 1, -1)
    b.well:SetPoint("BOTTOMRIGHT", -1, 1)
    b.well:SetColorTexture(0.02, 0.025, 0.02, 0.95)
    b.fill = b:CreateTexture(nil, "ARTWORK")
    b.fill:SetTexture(T.tex.bar)
    b.fill:SetPoint("TOPLEFT", 1, -1)
    b.fill:SetPoint("BOTTOMLEFT", 1, 1)
    b.gloss = b:CreateTexture(nil, "ARTWORK", nil, 1)
    b.gloss:SetPoint("TOPLEFT", b.fill, "TOPLEFT", 0, 0)
    b.gloss:SetPoint("TOPRIGHT", b.fill, "TOPRIGHT", 0, 0)
    b.gloss:SetHeight(max(1, floor((h or 10) * 0.35)))
    b.gloss:SetColorTexture(1, 1, 1, 0.12)
    b.value = 0
    function b:SetColor(c)
        c = UI.col(c)
        self.fill:SetVertexColor(c[1], c[2], c[3], 1)
    end
    function b:SetValue(v)
        self.value = U.Clamp(tonumber(v) or 0, 0, 1)
        local w = (self:GetWidth() or 0) - 2
        self.fill:SetWidth(max(0.001, w * self.value))
        local on = self.value > 0 and w > 0
        self.fill:SetShown(on)
        self.gloss:SetShown(on)
    end
    b:SetScript("OnSizeChanged", function(self) self:SetValue(self.value) end)
    b:SetColor("green")
    return b
end

--- Title/badge art: the catalogue's game icon (t.art), else a line icon on a dark well.
local function artOf(def, fallback)
    local a = type(def) == "table" and def.art
    if type(a) == "string" or type(a) == "number" then return a end
    return fallback
end

-------------------------------------------------------------------------------
-- Data: everything a profile shows, gathered once per show
-------------------------------------------------------------------------------
local function gatherTitles(key)
    local out = {}
    local list = call(GF.Stats, "TitlesOf", key)
    if type(list) ~= "table" then return out end
    for _, t in ipairs(list) do
        if type(t) == "table" and str(t.title) then
            local def = str(t.key) and GF.TitlesByKey and GF.TitlesByKey[t.key]
            out[#out + 1] = { title = t.title, label = str(t.label), blurb = str(t.blurb), shame = t.group == "shame",
                              art = artOf(t) or artOf(def) }
        end
    end
    return out
end

local function gatherBadges(key)
    local out = {}
    local list = call(GF.Stats, "Badges", key)
    if type(list) ~= "table" then return out end
    for _, b in ipairs(list) do
        if type(b) == "table" and str(b.name) then
            local def = str(b.stat) and GF.TitlesByKey and GF.TitlesByKey[b.stat]
            out[#out + 1] = { name = b.name, n = num(b.n) or 0, def = def, shame = (b.group or (def and def.group)) == "shame",
                              art = artOf(def) }
        end
    end
    return out
end

--- Non-zero catalogue stats. Rank-kind stats only ever show a position, never an amount.
local function gatherStats(key, main)
    local out = {}
    if not has(GF.Stats, "Value") then return out end
    for _, def in ipairs(GF.Titles or {}) do
        if def.kind == "rank" then
            local pos = num(call(GF.Stats, "Value", key, def.key, "all"))
            local leader = call(GF.Stats, "Leader", def.key, "all")
            if leader == main then pos = 1 elseif pos == 1 then pos = nil end
            if pos and pos >= 1 then out[#out + 1] = { def = def, rank = floor(pos) } end
        else
            local v = num(call(GF.Stats, "Value", key, def.key, "all"))
            if v and v ~= 0 then out[#out + 1] = { def = def, value = v } end
        end
    end
    return out
end

local function gatherSummary(key)
    local s = call(GF.Attendance, "Summary", key)
    if type(s) ~= "table" then return nil end
    local total = num(s.total) or 0
    if total <= 0 then return nil end
    local attended = num(s.attended) or 0
    return {
        attended = attended, total = total,
        pct = U.Clamp(floor((num(s.pct) or U.Pct(attended, total)) + 0.5), 0, 100),
        streak = num(s.streak) or 0, late = num(s.late) or 0, flakes = num(s.flakes) or 0,
        lastSeen = num(s.lastSeen),
    }
end

--- My own trades straight from the client, so my file is right before my profile doc syncs.
local function liveProfs()
    local map = {}
    for _, p in ipairs(API.Professions()) do
        local line, rank = num(p.skillLine), num(p.rank)
        if line and rank then map[line] = max(map[line] or 0, rank) end
    end
    return map
end

--- profs: { [skillLine] = rank } (a profile doc's `profs`, or liveProfs())
local function gatherProfs(profs)
    local out = {}
    if type(profs) ~= "table" then return out end
    local BD = GF.BuffData or {}
    local data, child = BD.professions or {}, BD.childSkillLines or {}
    local best = {}
    for line, rank in pairs(profs) do
        line = tonumber(line)
        line = line and (child[line] or line)   -- child skill lines roll up to their parent
        rank = num(rank)
        if line and data[line] and rank and rank > (best[line] or 0) then best[line] = rank end
    end
    for line, rank in pairs(best) do
        local d = data[line]
        out[#out + 1] = { line = line, rank = rank, name = d.name, icon = d.icon, secondary = d.secondary and true or false }
    end
    sort(out, function(a, b)
        if a.secondary ~= b.secondary then return not a.secondary end
        if a.rank ~= b.rank then return a.rank > b.rank end
        return a.line < b.line
    end)
    return out
end

local function gatherLoot(familySet)
    local out = {}
    local list = call(GF.Loot, "History", LOOT_SCAN)
    if type(list) ~= "table" then return out end
    for _, l in ipairs(list) do
        if #out >= LOOT_SHOWN then break end
        local winner = type(l) == "table" and str(l.winner)
        if winner and familySet[winner] then
            local id = num(l.itemID)
            local link = str(l.link)
            if id or link then
                out[#out + 1] = {
                    itemID = id, link = link, winner = winner, t = num(l.t),
                    boss = str(l.boss), instance = str(l.instance), how = str(l.how),
                }
            end
        end
    end
    return out
end

--- Buff categories a player brings: the Buffs module's verdict, or a class-only guess.
-- proven: the answer rests on real spell checks (me, or a profile doc carrying `caps`);
-- otherwise even the Buffs module can only go by class and level, so say so.
local function gatherBuffs(key, class, level, proven)
    local out, guess = {}, false
    local BD = GF.BuffData
    if not BD or not BD.byKey then return out, guess end
    local list
    if has(GF.Buffs, "Providers") then
        list = call(GF.Buffs, "Providers", key)
    end
    if type(list) == "table" then
        for _, catKey in ipairs(list) do
            local cat = type(catKey) == "string" and BD.byKey[catKey]
            if cat then out[#out + 1] = cat end
        end
        guess = (#out > 0) and not proven
    elseif class then
        guess = true
        for _, cat in ipairs(BD.categories or {}) do
            local tooLow = cat.minLevel and level > 0 and level < cat.minLevel
            if cat.classes and cat.classes[class] and not cat.talent and not tooLow then out[#out + 1] = cat end
        end
    end
    sort(out, function(a, b) return (a.order or 0) < (b.order or 0) end)
    return out, guess
end

local function gather(key)
    local R = GF.Roster
    local d = { key = key, me = key == API.MyKey() }
    d.member = R:Get(key)
    local doc = GF.Profile and GF.Profile.Get and GF.Profile:Get(key)
    d.doc = type(doc) == "table" and doc or nil
    local m = d.member
    -- R:Class / R:Level can fall back to a remote profile doc, which may hold anything
    d.class = (m and str(m.class)) or str(R:Class(key)) or (d.doc and str(d.doc.class))
    if d.me then d.class = d.class or API.UnitClassFile("player") end
    d.level = (m and pos(m.level)) or pos(R:Level(key)) or (d.doc and pos(d.doc.level))
        or (d.me and pos(API.UnitLevel("player"))) or 0
    d.race = d.doc and str(d.doc.race)
    if d.me and not d.race then d.race = str((API.UnitRace("player"))) end
    d.online = R:IsOnline(key) and true or false
    d.mobile = m and m.mobile and not d.online or false
    d.zone = m and str(m.zone)
    d.rankName = m and str(m.rankName)
    d.rankIndex = m and num(m.rankIndex)
    d.version = cleanVersion(call(GF.Comm, "HasAddon", key))
    local peer = GF.Comm and GF.Comm.peers and GF.Comm.peers[key]
    d.heard = type(peer) == "table" and num(peer.seen) or nil
    d.synced = d.doc and num(d.doc.t)

    -- mains and alts: the whole family shares loot history and roll-ups
    local main = cleanName(R:MainOf(key))
    d.main = (main and main ~= key) and main or nil
    local root = d.main or key
    d.family = { [root] = true, [key] = true }
    d.alts = {}
    for _, alt in ipairs(R:AltsOf(root)) do
        d.family[alt] = true
        if alt ~= key then d.alts[#d.alts + 1] = alt end
    end

    d.has = {
        titles = has(GF.Stats, "TitlesOf"), badges = has(GF.Stats, "Badges"), stats = has(GF.Stats, "Value"),
        roll = has(GF.Attendance, "Summary"), loot = has(GF.Loot, "History"),
    }
    d.titles = gatherTitles(key)
    d.badges = gatherBadges(key)
    d.stats = gatherStats(key, root)
    d.summary = gatherSummary(key)
    d.profsKnown = d.me or d.doc ~= nil
    d.profs = gatherProfs(d.me and liveProfs() or (d.doc and d.doc.profs))
    d.loot = gatherLoot(d.family)
    d.lootCount = num(call(GF.Loot, "CountFor", key))
    local proven = d.me or (d.doc ~= nil and type(d.doc.caps) == "table")
    d.buffs, d.buffsGuess = gatherBuffs(key, d.class, d.level, proven)
    return d
end

-------------------------------------------------------------------------------
-- Pooled card contents
-------------------------------------------------------------------------------
local function take(card, kind, create)
    local p = card.pools[kind]
    if not p then p = { n = 0 }; card.pools[kind] = p end
    p.n = p.n + 1
    local w = p[p.n]
    if not w then w = create(card.body); p[p.n] = w end
    w:Show()
    return w
end

local function begin(card)
    for _, p in pairs(card.pools) do p.n = 0 end
    if card.emptyFS then card.emptyFS:Hide() end
    if card.note then card.note:Hide() end
    card.count:SetText("")
end

local function finish(card, h)
    for _, p in pairs(card.pools) do
        for i = p.n + 1, #p do p[i]:Hide() end
    end
    return h
end

local function emptyLine(card, w, text)
    local fs = card.emptyFS
    if not fs then
        fs = UI:Text(card.body, 12, "faint")
        fs:SetPoint("TOPLEFT", 0, -2)
        fs:SetWordWrap(true)
        card.emptyFS = fs
    end
    fs:SetWidth(w)
    fs:SetText(text)
    fs:Show()
    return finish(card, max(18, (fs:GetStringHeight() or 14) + 6))
end

local TITLE_ROW_H, TITLE_ROW_GAP = 42, 6

--- A held title, achievement style: framed title art, gold Friz name, what it's for.
local function newTitleRow(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(TITLE_ROW_H)
    slab(f, 0.32, 0.7)
    f.art = UI:FramedIcon(f, 32)
    f.art:SetPoint("LEFT", 5, 0)
    f.title = UI:Text(f, 13, "wowGold", "ui")
    f.title:SetPoint("TOPLEFT", 46, -7)
    f.label = UI:Text(f, 11, "dim")
    f.label:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -3)
    tipOn(f, true, true)
    return f
end

local CHIP_H, CHIP_ICON = 26, 22

--- Badge / buff chip: a framed game icon on a small bronze-rimmed slab.
local function newChip(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(CHIP_H)
    slab(f, 0.38, 0.7)
    f.art = UI:FramedIcon(f, CHIP_ICON)
    f.art:SetPoint("LEFT", 2, 0)
    f.label = UI:Text(f, 11, "text", "ui")
    f.label:SetPoint("LEFT", f.art, "RIGHT", 6, 0)
    tipOn(f, true, false)
    return f
end

local function setChip(f, text, color, icon, maxW)
    local c = UI.col(color)
    f.art:SetIcon(icon)
    f.label:SetText(text)
    f.label:SetTextColor(c[1], c[2], c[3], 1)
    local labelW = fitText(f.label, max(20, maxW - (2 + CHIP_ICON + 6 + 9)))
    f:SetWidth(2 + CHIP_ICON + 6 + labelW + 9)
end

--- Lays chips out left to right, wrapping at width w. Returns the height used.
local function flowChips(chips, w)
    local x, y = 0, 0
    for _, chip in ipairs(chips) do
        local cw = chip:GetWidth()
        if x > 0 and x + cw > w then x = 0; y = y + CHIP_H + 6 end
        chip:ClearAllPoints()
        chip:SetPoint("TOPLEFT", x, -y)
        x = x + cw + 6
    end
    return y + CHIP_H
end

local STAT_H, STAT_GAP = 50, 6

local function newStatCell(parent)
    local f = CreateFrame("Frame", nil, parent)
    slab(f, 0.32, 0.65)
    f.art = UI:FramedIcon(f, 28)
    f.art:SetPoint("LEFT", 7, 0)
    f.label = UI:Text(f, 9, GOLD_DIM, "head")
    f.label:SetPoint("TOPLEFT", 43, -9)
    f.value = UI:Text(f, 18, "text", "num")
    f.value:SetPoint("BOTTOMLEFT", 43, 6)
    tipOn(f, true, false)
    return f
end

local function newProfRow(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(34)
    f.art = UI:FramedIcon(f, 30)
    f.art:SetPoint("LEFT", 0, 0)
    f.name = UI:Text(f, 12, "text", "ui")
    f.name:SetPoint("TOPLEFT", 40, -2)
    f.value = UI:Text(f, 11, "dim", "num")
    f.value:SetPoint("TOPRIGHT", 0, -3)
    f.value:SetJustifyH("RIGHT")
    f.bar = statusBar(f, 10)
    f.bar:SetPoint("TOPLEFT", 40, -20)
    f.bar:SetPoint("TOPRIGHT", 0, -20)
    return f
end

local LOOT_ROW_H, LOOT_ROW_GAP = 40, 6

local function newLootRow(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(LOOT_ROW_H)
    slab(f, 0.32, 0.7)
    f.item = UI:ItemButton(f, 30)
    f.item:SetPoint("LEFT", 5, 0)
    f.name = UI:Text(f, 12, "text")
    f.name:SetPoint("TOPLEFT", 44, -6)
    f.meta = UI:Text(f, 10, "dim")
    f.meta:SetPoint("TOPLEFT", f.name, "BOTTOMLEFT", 0, -3)
    f.how = UI:Pill(f, "", "dim", { height = 16, size = 10 })
    f.how:SetPoint("RIGHT", -8, 0)
    return f
end

-------------------------------------------------------------------------------
-- Cards. Each fill(card, bodyWidth, data) lays out its body and returns its height.
-------------------------------------------------------------------------------
local function tipLines(...)
    local out = {}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if v ~= nil and v ~= "" then out[#out + 1] = v end
    end
    return out
end

local function fillRoll(card, w, d)
    begin(card)
    local g = card.roll
    if not g then
        g = CreateFrame("Frame", nil, card.body)
        g:SetPoint("TOPLEFT")
        g:SetPoint("TOPRIGHT")
        g:SetHeight(112)
        g.pct = UI:Text(g, 30, "green", "num")
        g.pct:SetPoint("TOPLEFT", 0, 0)
        g.sub = UI:Text(g, 11, "dim")
        g.sub:SetPoint("BOTTOMLEFT", g.pct, "BOTTOMRIGHT", 8, 4)
        g.bar = statusBar(g, 10)
        g.bar:SetPoint("TOPLEFT", 0, -39)
        g.bar:SetPoint("TOPRIGHT", 0, -39)
        g.minis = {}
        for i, label in ipairs({ "STREAK", "LATE", "FLAKES" }) do
            local v = UI:Text(g, 18, "text", "num")
            local l = UI:Text(g, 10, GOLD_DIM, "head")
            l:SetPoint("TOPLEFT", v, "BOTTOMLEFT", 0, -2)
            l:SetText(label)
            g.minis[i] = { value = v, label = l }
        end
        g.last = UI:Text(g, 11, "faint")
        g.last:SetPoint("TOPLEFT", 0, -98)
        tipOn(g)
        g.tipTitle = "Roll call"
        g.tipLines = {
            { "Streak", "Raids in a row without missing one" },
            { "Late", "Rocked up after the pull" },
            { "Flakes", "Said yeah, meant nah" },
        }
        card.roll = g
    end
    local s = d.summary
    if not d.has.roll or not s then
        g:Hide()
        return emptyLine(card, w, d.has.roll and LINES.rollNone or LINES.rollOff)
    end
    g:Show()
    local tone = pctColor(s.pct)
    g.pct:SetText(s.pct .. "%")
    UI:SetTextColor(g.pct, tone)
    g.sub:SetText("Turned up to " .. s.attended .. " of " .. s.total .. " " .. U.Plural(s.total, "raid"))
    g.bar:SetColor(tone)
    g.bar:SetValue(s.pct / 100)
    local vals = {
        { s.streak, s.streak > 0 and "green" or "faint" },
        { s.late, s.late > 0 and "yellow" or "faint" },
        { s.flakes, s.flakes > 0 and "red" or "faint" },
    }
    local third = floor(w / 3)
    for i, m in ipairs(g.minis) do
        m.value:ClearAllPoints()
        m.value:SetPoint("TOPLEFT", g, "TOPLEFT", (i - 1) * third, -58)
        m.value:SetText(vals[i][1])
        UI:SetTextColor(m.value, vals[i][2])
    end
    if s.lastSeen then
        g.last:SetText("Last raid: " .. U.Ago(s.lastSeen))
        g.last:Show()
    else
        g.last:Hide()
    end
    card.count:SetText(s.total .. " " .. U.Plural(s.total, "RAID"))
    return finish(card, s.lastSeen and 112 or 94)
end

local function fillTitles(card, w, d)
    begin(card)
    if not d.has.titles then return emptyLine(card, w, LINES.titlesOff) end
    if #d.titles == 0 then return emptyLine(card, w, d.version and LINES.titlesNone or LINES.noAddon) end
    local y = 0
    for _, t in ipairs(d.titles) do
        local row = take(card, "title", newTitleRow)
        local c = t.shame and C.red or C.wowGold
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -y)
        row:SetPoint("TOPRIGHT", 0, -y)
        row.art:SetIcon(t.art or "crown")
        row.title:SetText(t.title)
        row.title:SetTextColor(c[1], c[2], c[3], 1)
        row.title:SetWidth(max(40, w - 54))
        row.label:SetText(t.label or "")
        row.label:SetWidth(max(40, w - 54))
        row.tipTitle = T:Wrap(t.shame and "red" or "gold", t.title)
        row.tipLines = tipLines(t.label, t.blurb and T:Wrap("dim", t.blurb))
        y = y + TITLE_ROW_H + TITLE_ROW_GAP
    end
    card.count:SetText(#d.titles)
    return finish(card, y - TITLE_ROW_GAP)
end

--- Achievement glint across a card's pooled rows when a file opens (staggered, top to
-- bottom, at most six): crowns held, soft-reserve wins. want(row) picks which rows.
local function shinePool(card, kind, want)
    local p = card.pools and card.pools[kind]
    if not p then return end
    local n = 0
    for i = 1, p.n do
        local row = p[i]
        if n < 6 and (not want or want(row)) then
            n = n + 1
            GF:After(0.25 + (n - 1) * 0.14, function()
                if row:IsVisible() then UI:Shine(row, 0.7) end
            end)
        end
    end
end

local function statValue(s)
    if s.rank then return "#" .. s.rank end
    local unit, v = s.def.unit, U.Commas(s.value)
    if unit == "%" or unit == "g" then return v .. unit end
    if unit then return v .. " " .. unit end
    return v
end

local function fillStats(card, w, d)
    begin(card)
    if not d.has.stats then return emptyLine(card, w, LINES.statsOff) end
    if #d.stats == 0 then return emptyLine(card, w, d.version and LINES.statsNone or LINES.noAddon) end
    local cols = max(1, floor((w + 8) / 138))
    local cw = floor((w - (cols - 1) * 8) / cols)
    for i, s in ipairs(d.stats) do
        local cell = take(card, "stat", newStatCell)
        local def = s.def
        local col, row = (i - 1) % cols, floor((i - 1) / cols)
        cell:ClearAllPoints()
        cell:SetPoint("TOPLEFT", col * (cw + 8), -row * (STAT_H + STAT_GAP))
        cell:SetSize(cw, STAT_H)
        local shame = def.group == "shame"
        cell.art:SetIcon(artOf(def, def.icon or "star"))
        cell.label:SetText(tostring(def.label or def.key):upper())
        cell.label:SetWidth(max(20, cw - 50))
        cell.value:SetText(statValue(s))
        cell.value:SetWidth(max(20, cw - 50))
        -- a #1 is a crown held: give it the game's gold
        UI:SetTextColor(cell.value, s.rank == 1 and "wowGold" or "text")
        cell.tipTitle = T:Wrap(shame and "red" or "gold", def.title or def.label or def.key)
        cell.tipLines = tipLines(def.label,
            s.rank and ("Ranked #" .. s.rank .. " - amount classified.") or nil,
            def.blurb and T:Wrap("dim", def.blurb))
    end
    card.count:SetText(#d.stats)
    return finish(card, ceil(#d.stats / cols) * (STAT_H + STAT_GAP) - STAT_GAP)
end

local function fillBadges(card, w, d)
    begin(card)
    if not d.has.badges then return emptyLine(card, w, LINES.badgesOff) end
    if #d.badges == 0 then return emptyLine(card, w, d.version and LINES.badgesNone or LINES.noAddon) end
    local chips = {}
    for _, b in ipairs(d.badges) do
        local chip = take(card, "chip", newChip)
        setChip(chip, b.name, b.shame and "red" or "wowGold", b.art or "star_fill", w)
        chip.shine = true
        chip.tipTitle = b.name
        chip.tipLines = tipLines(((b.def and b.def.label) or "Milestone") .. ": " .. U.Commas(b.n) .. "+",
            b.def and b.def.title and T:Wrap("dim", "On the road to " .. b.def.title))
        chips[#chips + 1] = chip
    end
    card.count:SetText(#d.badges)
    return finish(card, flowChips(chips, w))
end

local function fillProfs(card, w, d)
    begin(card)
    if not d.profsKnown then return emptyLine(card, w, LINES.profsNoDoc) end
    if #d.profs == 0 then return emptyLine(card, w, LINES.profsNone) end
    local y = 0
    for _, p in ipairs(d.profs) do
        local row = take(card, "prof", newProfRow)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -y)
        row:SetPoint("TOPRIGHT", 0, -y)
        row.art:SetIcon(p.icon)
        row.name:SetText(p.name .. (p.secondary and T:Wrap("faint", "  secondary") or ""))
        row.name:SetWidth(max(40, w - 40 - 70))   -- leave room for "300 / 300" on the right
        local cap = max(MAX_SKILL, p.rank)
        local maxed = p.rank >= MAX_SKILL
        row.value:SetText(p.rank .. " / " .. cap)
        UI:SetTextColor(row.value, maxed and "wowGold" or "dim")
        row.bar:SetColor(maxed and MAXED or (p.secondary and "blue" or "green"))
        row.bar:SetValue(p.rank / cap)
        y = y + 40
    end
    card.count:SetText(#d.profs)
    return finish(card, y - 6)
end

local function fillBuffs(card, w, d)
    begin(card)
    if #d.buffs == 0 then return emptyLine(card, w, d.class and LINES.buffsNone or LINES.buffsUnknown) end
    local BD = GF.BuffData
    local chips = {}
    for _, cat in ipairs(d.buffs) do
        local chip = take(card, "chip", newChip)
        setChip(chip, cat.label or cat.key, cat.core and "green" or "text", API.SpellIcon(cat.icon), w)
        chip.shine = false
        local camp = cat.camp and BD.campByKey and BD.campByKey[cat.camp]
        chip.tipTitle = cat.long or cat.label
        chip.tipLines = tipLines({ "Helps", WHO[cat.who] or "The raid" },
            camp and { "Camp stand-in", camp.name } or nil,
            cat.talent and T:Wrap("faint", "Needs the right talents.") or nil)
        chips[#chips + 1] = chip
    end
    local h = flowChips(chips, w)
    if d.buffsGuess then
        card.note:ClearAllPoints()
        card.note:SetPoint("TOPLEFT", 0, -(h + 8))
        card.note:SetWidth(w)
        card.note:SetText(LINES.buffsGuess)
        card.note:Show()
        h = h + 8 + max(12, card.note:GetStringHeight() or 12)
    end
    card.count:SetText(#d.buffs)
    return finish(card, h)
end

local function fillLoot(card, w, d)
    begin(card)
    if not d.has.loot then return emptyLine(card, w, LINES.lootOff) end
    if d.lootCount and d.lootCount > 0 then card.count:SetText(d.lootCount .. " " .. U.Plural(d.lootCount, "ITEM")) end
    if #d.loot == 0 then return emptyLine(card, w, LINES.lootNone) end
    local y = 0
    for _, l in ipairs(d.loot) do
        local row = take(card, "loot", newLootRow)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -y)
        row:SetPoint("TOPRIGHT", 0, -y)
        row.item:SetItem(l.link or l.itemID)
        row.name:SetText(l.link or str(API.ItemName(l.itemID)) or "Mystery loot")
        row.srWin = l.how == "SR"
        local how = HOW[l.how or ""]
        if how then
            row.how:SetText(how[1], how[2])
            row.how:Show()
        else
            row.how:Hide()
        end
        local textW = max(40, w - 44 - 8 - (how and (row.how:GetWidth() + 8) or 0))
        row.name:SetWidth(textW)
        local meta = {}
        if l.boss or l.instance then meta[#meta + 1] = l.boss or l.instance end
        if l.t then meta[#meta + 1] = U.Ago(l.t) end
        if l.winner ~= d.key then meta[#meta + 1] = "on " .. U.ClassName(l.winner, str(GF.Roster:Class(l.winner))) end
        row.meta:SetText(concat(meta, DOT))
        row.meta:SetWidth(textW)
        y = y + LOOT_ROW_H + LOOT_ROW_GAP
    end
    return finish(card, y - LOOT_ROW_GAP)
end

local CARDS = {
    { id = "roll", title = "Roll Call", icon = "calendar", accent = "green", fill = fillRoll },
    { id = "titles", title = "Titles", icon = "crown", accent = "gold", fill = fillTitles },
    { id = "stats", title = "Stats", icon = "trophy", accent = "blue", fill = fillStats },
    { id = "badges", title = "Badges", icon = "star", accent = "gold", fill = fillBadges },
    { id = "profs", title = "Tradie licences", icon = "hammer", accent = "yellow", fill = fillProfs },
    { id = "buffs", title = "Brings to the raid", icon = "campfire", accent = "green", fill = fillBuffs },
    { id = "loot", title = "Loot", icon = "bag", accent = "purple", fill = fillLoot },
}

-------------------------------------------------------------------------------
-- Hero card
-------------------------------------------------------------------------------
local function newLink(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(16)
    b.text = UI:Text(b, 12, "text", "ui")
    b.text:SetPoint("LEFT", 0, 0)
    b.line = b:CreateTexture(nil, "ARTWORK")
    b.line:SetHeight(1)
    b.line:SetPoint("BOTTOMLEFT", 0, 1)
    b.line:SetPoint("BOTTOMRIGHT", 0, 1)
    b.line:Hide()
    b:SetScript("OnEnter", function(self)
        self.line:Show()
        if self.key then UI:Tip(self, nil, { "Open " .. U.ShortName(self.key) .. "'s file" }) end
    end)
    b:SetScript("OnLeave", function(self) self.line:Hide(); UI:HideTip() end)
    b:SetScript("OnClick", function(self)
        UI.Sound(856)
        if self.key and UI.OpenProfile then GF:Safe("profile:link", UI.OpenProfile, UI, self.key) end
    end)
    return b
end

local function invite(key)
    if not API.Invite(key) then
        UI:Toast({ title = "No dice", text = "Couldn't send that invite right now. Try again in a sec.", icon = "warning", style = "red", key = "gf-invite-fail" })
    end
end

--- Filled-circle layer (stacked circles make the portrait's rings).
local function disc(parent, layer, sub, size, r, g, b, a)
    local t = parent:CreateTexture(nil, layer, nil, sub)
    t:SetTexture(T.tex.circle)
    t:SetSize(size, size)
    t:SetPoint("CENTER")
    t:SetVertexColor(r, g, b, a or 1)
    return t
end

--- Character-sheet header: tooled leather under a gold rim, a gold-ringed class portrait
-- with a level medallion, and the resident's class colour washed in from the left.
local function buildHero(page, content)
    local h = UI:Card(content)
    h:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    h:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
    h:SetHeight(HERO_H)
    h.leather = h:CreateTexture(nil, "BACKGROUND", nil, 3)
    h.leather:SetPoint("TOPLEFT", 3, -3)
    h.leather:SetPoint("BOTTOMRIGHT", -3, 3)
    h.leather:SetTexture(T.tex.leather, "REPEAT", "REPEAT")
    h.leather:SetHorizTile(true)
    h.leather:SetVertTile(true)
    h.leather:SetVertexColor(0.72, 0.66, 0.6, 0.92)
    -- class-coloured wash and edge give every file its own tint
    h.wash = h:CreateTexture(nil, "BACKGROUND", nil, 4)
    h.wash:SetTexture(T.tex.white)
    h.wash:SetPoint("TOPLEFT", 3, -3)
    h.wash:SetPoint("BOTTOMLEFT", 3, 3)
    h.wash:SetWidth(420)
    -- a soft dark floor so the lower lines read over the leather grain
    h.floor = h:CreateTexture(nil, "BACKGROUND", nil, 5)
    h.floor:SetTexture(T.tex.white)
    h.floor:SetPoint("BOTTOMLEFT", 3, 3)
    h.floor:SetPoint("BOTTOMRIGHT", -3, 3)
    h.floor:SetHeight(56)
    local CC = rawget(_G, "CreateColor")
    if not (h.floor.SetGradient and type(CC) == "function"
        and pcall(h.floor.SetGradient, h.floor, "VERTICAL", CC(0, 0, 0, 0.38), CC(0, 0, 0, 0))) then
        h.floor:SetColorTexture(0, 0, 0, 0.16)
    end
    -- gold rim instead of the card's bronze one: this is the file's title plate
    UI.Sliced(h.rim, T.tex.frameGold, 16)

    -- portrait: class glow, gold ring, dark gap, then the class avatar with its own ring
    local p = CreateFrame("Frame", nil, h)
    p:SetSize(PORTRAIT, PORTRAIT)
    p:SetPoint("LEFT", 22, 0)
    p.glow = p:CreateTexture(nil, "BACKGROUND")
    p.glow:SetTexture(T.tex.glow)
    p.glow:SetSize(PORTRAIT * 1.9, PORTRAIT * 1.9)
    p.glow:SetPoint("CENTER")
    p.glow:SetBlendMode("ADD")
    p.shadow = disc(p, "BACKGROUND", 1, PORTRAIT + 4, 0, 0, 0, 0.6)
    p.gold = disc(p, "BORDER", 0, PORTRAIT, 0.86, 0.68, 0.22, 1)
    p.goldHi = disc(p, "BORDER", 1, PORTRAIT - 2, 1, 0.86, 0.42, 1)
    p.bronze = disc(p, "BORDER", 2, PORTRAIT - 5, C.bronze[1] * 0.7, C.bronze[2] * 0.7, C.bronze[3] * 0.7, 1)
    p.well = disc(p, "BORDER", 3, PORTRAIT - 8, 0.04, 0.03, 0.02, 1)
    p.avatar = UI:Avatar(p, PORTRAIT - 12)
    p.avatar:SetPoint("CENTER")
    -- level medallion, PlayerFrame style (a child of the avatar, so it always draws on top
    -- of it without pinning a frame level that a window raise wouldn't carry along)
    local lv = CreateFrame("Frame", nil, p.avatar)
    lv:SetSize(30, 30)
    lv:SetPoint("CENTER", p, "BOTTOMLEFT", 15, 15)
    lv.gold = disc(lv, "BACKGROUND", 0, 30, 0.86, 0.68, 0.22, 1)
    lv.well = disc(lv, "BACKGROUND", 1, 26, 0.10, 0.07, 0.03, 1)
    lv.text = UI:Text(lv, 12, "wowGold", "head")
    lv.text:SetPoint("CENTER", 0, 0)
    lv.text:SetJustifyH("CENTER")
    p.level = lv
    h.portrait = p
    h.avatar = p.avatar

    h.name = UI:Text(h, 24, "text", "ui")
    h.name:SetPoint("TOPLEFT", TEXT_X, -20)
    if h.name.SetShadowOffset then
        h.name:SetShadowOffset(2, -2)
        h.name:SetShadowColor(0, 0, 0, 0.95)
    end
    h.gf = UI:Pill(h, "", "green", { height = 18, size = 10 })
    h.gf:SetPoint("LEFT", h.name, "RIGHT", 10, 0)
    h.line = UI:Text(h, 13, "text", "ui")
    h.line:SetPoint("TOPLEFT", TEXT_X, -54)
    h.rank = UI:Pill(h, "", "dim", { height = 20, size = 11 })
    h.rank:SetPoint("TOPLEFT", TEXT_X, -77)
    h.status = UI:Pill(h, "", "green", { height = 20, size = 11, icon = "dot" })
    h.zone = UI:Text(h, 12, "dim")
    -- ornate gold rule between who they are and who they're related to
    h.rule = h:CreateTexture(nil, "ARTWORK")
    h.rule:SetTexture(T.tex.dividerGold)
    h.rule:SetHeight(10)
    h.rule:SetPoint("TOPLEFT", TEXT_X - 6, -101)
    h.rule:SetPoint("TOPRIGHT", -18, -101)
    h.rule:SetAlpha(0.7)
    h.famLabel = UI:Text(h, 10, GOLD_DIM, "head")
    h.famLabel:SetPoint("LEFT", h, "TOPLEFT", TEXT_X, FAM_Y)
    h.famNone = UI:Text(h, 11, "faint")
    h.also = UI:Text(h, 10, GOLD_DIM, "head")
    h.also:SetText("ALSO")
    h.more = UI:Text(h, 11, "faint")
    h.links = {}
    h.whisper = UI:Button(h, "Whisper", { icon = "bubble", onClick = function() if page.key then UI:Whisper(page.key) end end })
    h.whisper:SetPoint("TOPRIGHT", -18, -18)
    h.invite = UI:Button(h, "Invite", { icon = "plus", style = "primary", onClick = function() if page.key then invite(page.key) end end })
    h.invite:SetPoint("RIGHT", h.whisper, "LEFT", -8, 0)
    h.you = UI:Pill(h, "THAT'S YOU, LEGEND", "gold", { height = 22, size = 11, icon = "star_fill" })
    h.you:SetPoint("TOPRIGHT", -18, -20)
    h.synced = UI:Text(h, 11, "dim")
    h.synced:SetPoint("TOPRIGHT", -18, -56)
    h.synced:SetJustifyH("RIGHT")
    h.heard = UI:Text(h, 11, "dim")
    h.heard:SetPoint("TOPRIGHT", h.synced, "BOTTOMRIGHT", 0, -5)
    h.heard:SetJustifyH("RIGHT")
    return h
end

local function fillFamily(h, d, W)
    for _, l in ipairs(h.links) do l:Hide() end
    h.famNone:Hide()
    h.also:Hide()
    h.more:Hide()
    local items = {}
    if d.main then items[1] = d.main end
    for _, a in ipairs(d.alts) do items[#items + 1] = a end
    h.famLabel:SetText(d.main and "ALT OF" or "ALTS")
    local y = FAM_Y
    local x = TEXT_X + (h.famLabel:GetStringWidth() or 30) + 10
    if #items == 0 then
        h.famNone:ClearAllPoints()
        h.famNone:SetPoint("LEFT", h, "TOPLEFT", x, y)
        h.famNone:SetText(LINES.noAlts)
        h.famNone:Show()
        return
    end
    local limit = W - 16 - 64
    for i, key in ipairs(items) do
        if d.main and i == 2 then
            h.also:ClearAllPoints()
            h.also:SetPoint("LEFT", h, "TOPLEFT", x, y)
            h.also:Show()
            x = x + (h.also:GetStringWidth() or 30) + 10
        end
        local link = h.links[i]
        if not link then link = newLink(h); h.links[i] = link end
        local cls = str(GF.Roster:Class(key))
        link.key = key
        link.text:SetText(U.ClassName(key, cls))
        local lw = (link.text:GetStringWidth() or 40) + 6   -- slack: in-game fonts run a touch wider
        if i > 1 and x + lw > limit then
            h.more:ClearAllPoints()
            h.more:SetPoint("LEFT", h, "TOPLEFT", x, y)
            h.more:SetText("+" .. (#items - i + 1) .. " more")
            h.more:Show()
            return
        end
        local r, g, b = classRGB(cls)
        link.line:SetColorTexture(r, g, b, 0.8)
        link:SetWidth(lw)
        link:ClearAllPoints()
        link:SetPoint("LEFT", h, "TOPLEFT", x, y)
        link:Show()
        x = x + lw + 12
    end
end

local function fillHero(page, d, W)
    local h = page.hero
    local r, g, b = classRGB(d.class)
    local CC = rawget(_G, "CreateColor")
    local washed = false
    if h.wash.SetGradient and type(CC) == "function" then
        washed = pcall(h.wash.SetGradient, h.wash, "HORIZONTAL", CC(r, g, b, 0.26), CC(r, g, b, 0))
    end
    if not washed then h.wash:SetColorTexture(r, g, b, 0.1) end
    h.portrait.glow:SetVertexColor(r, g, b, 0.45)
    h.avatar:SetClass(d.class)
    if d.level > 0 then
        h.portrait.level.text:SetText(d.level)
        h.portrait.level:Show()
    else
        h.portrait.level:Hide()
    end

    if d.version then
        h.gf:SetText(d.version == "?" and "GREENFIELDS" or ("GREENFIELDS " .. d.version), "green")
    else
        h.gf:SetText("NO GREENFIELDS", "dim")
    end
    h.name:SetText(U.ClassName(d.key, d.class))
    fitText(h.name, max(80, W - TEXT_X - h.gf:GetWidth() - 10 - 200))

    -- "Level 60 Dwarf Priest", the way the character sheet puts it, class word in class colour
    local bits = {}
    if d.level > 0 then bits[#bits + 1] = "Level " .. d.level end
    local race = raceName(d.race)
    if race then bits[#bits + 1] = race end
    if d.class then bits[#bits + 1] = U.Color(API.ClassName(d.class), U.ClassColorHex(d.class)) end
    local line = concat(bits, " ")
    if line == "" then line = (d.member or d.doc) and "Details unknown" or LINES.stranger end
    h.line:SetText(line)
    h.line:SetWidth(max(80, W - TEXT_X - 170))

    local x = TEXT_X
    h.status:ClearAllPoints()
    if d.rankName then
        local tone = d.rankIndex == 0 and "gold" or (GF.Roster:IsOfficer(d.key) and "green" or "dim")
        h.rank:SetText(shorten(d.rankName, 22), tone)
        h.rank:Show()
        h.status:SetPoint("LEFT", h.rank, "RIGHT", 6, 0)
        x = x + h.rank:GetWidth() + 6
    else
        h.rank:Hide()
        h.status:SetPoint("TOPLEFT", TEXT_X, -77)
    end
    if d.online then
        h.status:SetText("HOME NOW", "green")
    elseif d.mobile then
        h.status:SetText("ON THE APP", "blue")
    elseif d.member then
        h.status:SetText("OFFLINE", "dim")
    else
        h.status:SetText("NOT ON THE ROSTER", "yellow")
    end
    x = x + h.status:GetWidth() + 10
    h.zone:ClearAllPoints()
    h.zone:SetPoint("LEFT", h.status, "RIGHT", 10, 0)
    h.zone:SetText(d.zone and (d.online and d.zone or ("Last seen in " .. d.zone)) or "")
    UI:SetTextColor(h.zone, d.online and "text" or "dim")
    h.zone:SetWidth(max(40, W - x - 16 - 170))

    fillFamily(h, d, W)

    if d.me then
        h.whisper:Hide()
        h.invite:Hide()
        h.you:Show()
    else
        h.you:Hide()
        h.whisper:Show()
        h.invite:Show()
        h.whisper:SetActive(d.online or d.mobile)
        h.invite:SetActive(d.online)
    end
    h.synced:SetText(d.synced and ("Profile synced " .. U.Ago(d.synced)) or (d.me and "" or "No profile synced yet"))
    h.heard:SetText((not d.me and d.heard) and ("Last heard from " .. U.Ago(d.heard)) or "")
end

-------------------------------------------------------------------------------
-- Layout: hero across the top, cards in a masonry of 1-3 columns that reflows
-------------------------------------------------------------------------------
local function layout(page)
    local d = page.data
    local W = floor(page.content:GetWidth() or 0)
    if not d or W < 120 then return end
    page.lastW = W
    fillHero(page, d, W)
    local cols = W >= 900 and 3 or (W >= 520 and 2 or 1)
    local colW = floor((W - (cols - 1) * GAP) / cols)
    local heights = {}
    for i = 1, cols do heights[i] = 0 end
    local top = HERO_H + GAP
    for _, card in ipairs(page.cards) do
        local ok, bodyH = GF:Safe("profile:card:" .. card.id, card.fill, card, colW - 24, d)
        bodyH = (ok and type(bodyH) == "number") and bodyH or 18
        local h = ceil(bodyH) + 50
        local ci = 1
        for i = 2, cols do if heights[i] < heights[ci] then ci = i end end
        card:ClearAllPoints()
        card:SetPoint("TOPLEFT", page.content, "TOPLEFT", (ci - 1) * (colW + GAP), -(top + heights[ci]))
        card:SetSize(colW, h)
        heights[ci] = heights[ci] + h + GAP
    end
    local tallest = 0
    for i = 1, cols do tallest = max(tallest, heights[i]) end
    page.scroll:SetContentHeight(top + max(0, tallest - GAP) + 4)
end

-------------------------------------------------------------------------------
-- Page
-------------------------------------------------------------------------------
local profilePage

local function build(page)
    profilePage = page
    page.header = UI:PageHeader(page, "Resident file", "")
    local back = UI:Button(page.header, "Residents", {
        icon = "chevron_left", style = "secondary", tooltip = "Back to the street",
        onClick = function() UI:ShowPage("roster") end,
    })
    page.header:AddAction(back)
    page.mine = UI:Button(page.header, "My file", {
        icon = "home", style = "secondary", tooltip = "Have a look at your own file",
        onClick = function() UI:OpenProfile(API.MyKey()) end,
    })
    page.header:AddAction(page.mine)

    local scroll, content = UI:Scroll(page)
    scroll:SetPoint("TOPLEFT", page.header, "BOTTOMLEFT", 0, -8)
    scroll:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
    page.scroll, page.content = scroll, content
    page.hero = buildHero(page, content)
    page.cards = {}
    for _, def in ipairs(CARDS) do
        local card = UI:Card(content, { title = def.title, icon = def.icon, accent = def.accent })
        card.id, card.fill, card.pools = def.id, def.fill, {}
        card.count = UI:Text(card, 11, "faint", "head")
        card.count:SetPoint("TOPRIGHT", -12, -14)
        card.count:SetJustifyH("RIGHT")
        card.note = UI:Text(card.body, 10, "faint")
        card.note:SetWordWrap(true)
        card.note:Hide()
        page.cards[#page.cards + 1] = card
    end
    -- reflow whenever the window is resized
    content:SetScript("OnSizeChanged", function(_, w)
        if page.data and abs(floor(w or 0) - (page.lastW or 0)) >= 1 then GF:Safe("profile:layout", layout, page) end
    end)
end

local function onShow(page, key)
    key = cleanKey(key) or page.key or API.MyKey()
    page.scroll:SetShown(key ~= nil)
    if not key then
        page.header:SetSubtitle(LINES.noKey)
        return
    end
    local changed = key ~= page.key
    page.key = key
    page.data = gather(key)
    page.header:SetSubtitle("Everything the street knows about " .. U.ClassName(key, page.data.class) .. ".")
    page.mine:SetShown(not page.data.me)
    layout(page)
    if changed then
        page.scroll:SetVerticalScroll(0)
        page.scroll:UpdateBar()
        -- opening a file: the crowns they hold and their soft-res wins catch the light
        for _, card in ipairs(page.cards) do
            if card.id == "titles" then
                shinePool(card, "title")
            elseif card.id == "loot" then
                shinePool(card, "loot", function(row) return row.srWin end)
            end
        end
    end
end

UI:RegisterPage({
    key = "profile", title = "Profile",
    subtitle = "The full file on a resident. Nothing's private on this street.",
    icon = "roster", group = "community", order = 11,
    hidden = function() return true end,
    navParent = "roster",   -- sidebar item to highlight while a profile is open (MainFrame honours it)
    build = build, onShow = onShow,
})

--- Public: open the profile view for a player (defaults to me).
function UI:OpenProfile(key)
    key = cleanKey(key) or API.MyKey()
    if not key then return end
    UI:ShowPage("profile", key)
end

-------------------------------------------------------------------------------
-- Live updates (debounced; only redraws while the profile is on screen)
-------------------------------------------------------------------------------
local SHARED = { attendance = true, loot = true, stats = true, config = true }

local function queueRefresh()
    GF:Debounce("profile:refresh", 0.5, function() UI:RefreshPage("profile") end)
end

GF:On("GF_STORE_CHANGED", function(name, id)
    if not (profilePage and profilePage.key and profilePage.data) then return end
    if SHARED[name] then
        queueRefresh()
    elseif name == "profile" and type(id) == "string" and profilePage.data.family[id] then
        queueRefresh()
    end
end)
GF:On("GF_ROSTER_UPDATED", function()
    if profilePage and profilePage.key then queueRefresh() end
end)
GF:On("GF_PEER_SEEN", function(key)
    if profilePage and key == profilePage.key then queueRefresh() end
end)

GF:RegisterSlash("profile", function(arg)
    arg = U.Trim(arg)
    if arg == "" then UI:OpenProfile(API.MyKey()) return end
    local key = API.Key(arg)
    local R = GF.Roster
    if key and not R:IsMember(key) then
        local want = key:lower()
        local found
        for k in pairs(R:All()) do
            if type(k) == "string" and k:lower() == want then found = k break end
        end
        -- not on the roster: WoW names are "Capitalised", which is how profile docs are keyed
        key = found or (not key:find("-", 1, true) and API.Key(U.Capitalize(key))) or key
    end
    UI:OpenProfile(key)
end, "[name] - open a resident's file (blank = yours)")
