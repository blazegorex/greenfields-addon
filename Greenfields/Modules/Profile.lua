--[[ Greenfields - Modules/Profile.lua
     The hidden "profile" page: one resident's full file, opened from the Residents list,
     the sidebar me-card, or anywhere else through GF.UI:OpenProfile(key).

     Their name is the page's headline, written across the night scene in their class colour,
     so it stays put while the file scrolls. Below it a character-sheet hero (gold-ringed class
     portrait with a level medallion, level/race/class, rank, presence, mains and alts,
     whisper/invite) sits over a masonry of quiet cards: Roll Call, Titles, Stats, Badges,
     Tradie licences, Brings to the raid and Loot. Inside a card things are flat rows on fine
     rules, never a rim inside a rim. Crowns held and soft-res wins get the achievement glint
     when a file opens. Each card pulls from another module behind a guard; a card with nothing
     to show folds into one compact "Not on file yet" ledger, keeping its cheeky line, so a
     resident with no data doesn't get a stack of empty boxes. Data is gathered once per show;
     resizing only re-lays out.

     Also adds /gf profile [name]. ]]

local _, GF = ...
local API, U, UI, T = GF.API, GF.Util, GF.UI, GF.Theme
local C = T.c

local type, pairs, ipairs, tostring, tonumber = type, pairs, ipairs, tostring, tonumber
local floor, ceil, max, min, abs = math.floor, math.ceil, math.max, math.min, math.abs
local sort, concat = table.sort, table.concat

local GAP = 16
local HERO_H = 124
local PORTRAIT = 92         -- the hero's gold-ringed portrait
local TEXT_X = 124          -- where the hero's text column starts
local FAM_Y = -74           -- vertical centre of the hero's mains/alts line
local LOOT_SHOWN = 8
local LOOT_SCAN = 250
local MAX_SKILL = 300
local DOT = "  " .. T:Wrap("dim", "\194\183") .. "  "
-- small gold caption text (the game's own "label" gold, a shade down so values lead)
local GOLD_DIM = { C.wowGold[1] * 0.82, C.wowGold[2] * 0.82, C.wowGold[3], 1 }
local MAXED = { 0.86, 0.64, 0.08, 1 }   -- burnished gold for a maxed-out skill bar
-- data colours, a shade down from the theme's neon: a number shouldn't outshine the resident
local GOOD = { 0.42, 0.76, 0.50, 1 }
local WARN = { 0.93, 0.76, 0.28, 1 }
local BAD = { 0.92, 0.44, 0.42, 1 }
local SECONDARY = { 0.44, 0.60, 0.82, 1 }

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
    lootNone = "Hasn't won a thing. Even the fiends feel bad.",
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
    if p >= 75 then return GOOD end
    if p >= 45 then return WARN end
    return BAD
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

--- Tooltip on a plain frame. hl = true adds a soft hover wash inside the frame.
local function tipOn(f, hl)
    f:EnableMouse(true)
    if hl then
        f.hl = f:CreateTexture(nil, "BACKGROUND", nil, 2)
        f.hl:SetAllPoints()
        f.hl:SetColorTexture(1, 0.86, 0.55, 0.05)
        f.hl:SetBlendMode("ADD")
        f.hl:Hide()
    end
    f:SetScript("OnEnter", function(self)
        if self.hl then self.hl:Show() end
        if self.tipTitle then UI:Tip(self, self.tipTitle, self.tipLines) end
    end)
    f:SetScript("OnLeave", function(self)
        if self.hl then self.hl:Hide() end
        UI:HideTip()
    end)
end

--- The fine rule under a row; rows are lines on the page, not boxes.
local function rowRule(f)
    f.rule = UI:Hairline(f, "bronze", 0.25)
    f.rule:SetPoint("BOTTOMLEFT")
    f.rule:SetPoint("BOTTOMRIGHT")
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
            out[#out + 1] = { title = t.title, key = str(t.key), label = str(t.label), blurb = str(t.blurb), shame = t.group == "shame",
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
    card.emptyLine = nil
    card.skip = nil
    if card.note then card.note:Hide() end
    card.count:SetText("")
end

local function finish(card, h)
    for _, p in pairs(card.pools) do
        for i = p.n + 1, #p do p[i]:Hide() end
    end
    return h
end

--- Nothing to show: this card folds into the "Not on file yet" ledger, cheeky line and all.
local function emptyLine(card, text)
    card.emptyLine = text
    return finish(card, 0)
end

local TITLE_ROW_H = 44

--- A held title, achievement style: its art in the gold frame (it's a crown they wear),
-- gold Friz name, what it's for, and their number at the end of the line.
local function newTitleRow(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(TITLE_ROW_H)
    rowRule(f)
    f.art = UI:FramedIcon(f, 32, nil, "gold")
    f.art:SetPoint("LEFT", 0, 0)
    f.value = UI:Text(f, 14, "text", "num")
    f.value:SetPoint("RIGHT", -2, 0)
    f.value:SetJustifyH("RIGHT")
    f.title = UI:Text(f, 13, "wowGold", "ui")
    f.title:SetPoint("TOPLEFT", 42, -8)
    f.label = UI:Text(f, 11, "dim")
    f.label:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -3)
    tipOn(f, true)
    return f
end

local CHIP_H, CHIP_ICON = 26, 18

--- Badge / buff chip: a small game icon and its name, carved into the card.
local function newChip(parent)
    local f = UI:Well(parent)
    f:SetHeight(CHIP_H)
    f.art = UI:IconChip(f, CHIP_ICON)
    f.art:SetPoint("LEFT", 4, 0)
    f.label = UI:Text(f, 11, "text", "ui")
    f.label:SetPoint("LEFT", f.art, "RIGHT", 6, 0)
    tipOn(f, true)
    return f
end

local function setChip(f, text, color, icon, maxW)
    local c = UI.col(color)
    f.art:SetIcon(icon)
    f.label:SetText(text)
    f.label:SetTextColor(c[1], c[2], c[3], 1)
    local labelW = fitText(f.label, max(20, maxW - (4 + CHIP_ICON + 6 + 9)))
    f:SetWidth(4 + CHIP_ICON + 6 + labelW + 9)
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

local STAT_H = 34

--- One line of the stats ledger: art, what's being counted, and the number right-aligned.
local function newStatCell(parent)
    local f = CreateFrame("Frame", nil, parent)
    rowRule(f)
    f.art = UI:FramedIcon(f, 24)
    f.art:SetPoint("LEFT", 0, 0)
    f.value = UI:Text(f, 14, "text", "num")
    f.value:SetPoint("RIGHT", -2, 0)
    f.value:SetJustifyH("RIGHT")
    f.label = UI:Para(f, 11, "dim")
    f.label:SetPoint("LEFT", 32, 0)
    tipOn(f, true)
    return f
end

local function newProfRow(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(34)
    f.art = UI:FramedIcon(f, 32)
    f.art:SetPoint("LEFT", 0, 0)
    f.name = UI:Text(f, 12, "text", "ui")
    f.name:SetPoint("TOPLEFT", 42, -2)
    f.value = UI:Text(f, 12, "dim", "num")
    f.value:SetPoint("TOPRIGHT", 0, -3)
    f.value:SetJustifyH("RIGHT")
    f.bar = UI:Bar(f, { height = 8 })
    f.bar:SetPoint("TOPLEFT", 42, -20)
    f.bar:SetPoint("TOPRIGHT", 0, -20)
    return f
end

local LOOT_ROW_H = 42

local function newLootRow(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(LOOT_ROW_H)
    rowRule(f)
    f.item = UI:ItemButton(f, 32)
    f.item:SetPoint("LEFT", 0, 0)
    f.name = UI:Text(f, 12, "text")
    f.name:SetPoint("TOPLEFT", 42, -7)
    f.meta = UI:Text(f, 11, "dim")
    f.meta:SetPoint("TOPLEFT", f.name, "BOTTOMLEFT", 0, -3)
    f.how = UI:Pill(f, "", "dim", { height = 16, size = 10 })
    f.how:SetPoint("RIGHT", -2, 0)
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
        g.pct = UI:Text(g, 26, "text", "ui")
        g.pct:SetPoint("TOPLEFT", 0, 0)
        g.sub = UI:Text(g, 12, "dim")
        g.sub:SetPoint("BOTTOMLEFT", g.pct, "BOTTOMRIGHT", 8, 3)
        g.bar = UI:Bar(g, { height = 8 })
        g.bar:SetPoint("TOPLEFT", 0, -34)
        g.bar:SetPoint("TOPRIGHT", 0, -34)
        g.minis = {}
        for i, label in ipairs({ "Streak", "Late", "Flakes" }) do
            g.minis[i] = UI:Stat(g, { label = label, size = 18 })
        end
        g.last = UI:Text(g, 11, "dim")
        g.last:SetPoint("TOPLEFT", 0, -92)
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
        return emptyLine(card, d.has.roll and LINES.rollNone or LINES.rollOff)
    end
    g:Show()
    local tone = pctColor(s.pct)
    g.pct:SetText(s.pct .. "%")
    UI:SetTextColor(g.pct, tone)
    g.sub:SetText("Turned up to " .. s.attended .. " of " .. s.total .. " " .. U.Plural(s.total, "raid"))
    g.bar:SetColor(tone)
    g.bar:SetValue(s.pct / 100)
    local vals = {
        { s.streak, s.streak > 0 and GOOD or "dim" },
        { s.late, s.late > 0 and WARN or "dim" },
        { s.flakes, s.flakes > 0 and BAD or "dim" },
    }
    local third = floor(w / 3)
    for i, m in ipairs(g.minis) do
        m:ClearAllPoints()
        m:SetPoint("TOPLEFT", g, "TOPLEFT", (i - 1) * third, -50)
        m:Set(vals[i][1], nil, vals[i][2])
        m:SetHeight(38)
    end
    if s.lastSeen then
        g.last:SetText("Last raid: " .. U.Ago(s.lastSeen))
        g.last:Show()
    else
        g.last:Hide()
    end
    card.count:SetText(s.total .. " " .. U.Plural(s.total, "raid"))
    return finish(card, s.lastSeen and 106 or 88)
end

local function statValue(s)
    if s.rank then return "#" .. s.rank end
    local unit, v = s.def.unit, U.Commas(s.value)
    if unit == "%" or unit == "g" then return v .. unit end
    if unit then return v .. " " .. unit end
    return v
end

--- The stat behind a title, so its number sits on the title's row and Stats needn't repeat it.
local function statFor(d, key)
    for _, s in ipairs(d.stats) do
        if s.def.key == key then return s end
    end
    return nil
end

local function fillTitles(card, w, d)
    begin(card)
    if not d.has.titles then return emptyLine(card, LINES.titlesOff) end
    if #d.titles == 0 then return emptyLine(card, d.version and LINES.titlesNone or LINES.noAddon) end
    local y = 0
    for i, t in ipairs(d.titles) do
        local row = take(card, "title", newTitleRow)
        local c = t.shame and BAD or C.wowGold
        local s = t.key and statFor(d, t.key)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -y)
        row:SetPoint("TOPRIGHT", 0, -y)
        row.art:SetIcon(t.art or "crown")
        row.art:SetTone((not t.shame) and "gold" or nil)
        row.shame = t.shame
        row.title:SetText(t.title)
        row.title:SetTextColor(c[1], c[2], c[3], 1)
        row.value:SetText(s and statValue(s) or "")
        local tw = max(40, w - 42 - (s and 8 + (row.value:GetStringWidth() or 30) or 0))
        row.title:SetWidth(tw)
        row.label:SetText(t.label or "")
        row.label:SetWidth(tw)
        row.rule:SetShown(i < #d.titles)
        row.tipTitle = T:Wrap(t.shame and "red" or "gold", t.title)
        row.tipLines = tipLines(t.label, t.blurb and T:Wrap("dim", t.blurb))
        y = y + TITLE_ROW_H
    end
    card.count:SetText(#d.titles)
    return finish(card, y)
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

local function fillStats(card, w, d)
    begin(card)
    if not d.has.stats then return emptyLine(card, LINES.statsOff) end
    if #d.stats == 0 then return emptyLine(card, d.version and LINES.statsNone or LINES.noAddon) end
    -- what a title's row already shows isn't worth saying twice
    local titled = {}
    for _, t in ipairs(d.titles) do
        if t.key then titled[t.key] = true end
    end
    local list = {}
    for _, s in ipairs(d.stats) do
        if not titled[s.def.key] then list[#list + 1] = s end
    end
    if #list == 0 then
        -- every number they've got is on the Titles card; there's nothing to fold, so just step aside
        card.skip = true
        return finish(card, 0)
    end
    local cols = w >= 520 and 2 or 1
    local gap = 20
    local cw = floor((w - (cols - 1) * gap) / cols)
    local rows = ceil(#list / cols)
    for i, s in ipairs(list) do
        local cell = take(card, "stat", newStatCell)
        local def = s.def
        local col, row = (i - 1) % cols, floor((i - 1) / cols)
        cell:ClearAllPoints()
        cell:SetPoint("TOPLEFT", col * (cw + gap), -row * STAT_H)
        cell:SetSize(cw, STAT_H)
        local shame = def.group == "shame"
        cell.art:SetIcon(artOf(def, def.icon or "star"))
        cell.value:SetText(statValue(s))
        cell.label:SetText(tostring(def.label or def.key))
        cell.label:SetWidth(max(20, cw - 32 - 8 - (cell.value:GetStringWidth() or 30)))
        cell.rule:SetShown(row < rows - 1)
        -- a #1 is a crown held: give it the game's gold
        UI:SetTextColor(cell.value, s.rank == 1 and "wowGold" or "text")
        cell.tipTitle = T:Wrap(shame and "red" or "gold", def.title or def.label or def.key)
        cell.tipLines = tipLines(def.label,
            s.rank and ("Ranked #" .. s.rank .. " - amount classified.") or nil,
            def.blurb and T:Wrap("dim", def.blurb))
    end
    card.count:SetText(#list)
    return finish(card, rows * STAT_H)
end

local function fillBadges(card, w, d)
    begin(card)
    if not d.has.badges then return emptyLine(card, LINES.badgesOff) end
    if #d.badges == 0 then return emptyLine(card, d.version and LINES.badgesNone or LINES.noAddon) end
    local chips = {}
    for _, b in ipairs(d.badges) do
        local chip = take(card, "chip", newChip)
        setChip(chip, b.name, b.shame and BAD or "wowGold", b.art or "star_fill", w)
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
    if not d.profsKnown then return emptyLine(card, LINES.profsNoDoc) end
    if #d.profs == 0 then return emptyLine(card, LINES.profsNone) end
    local y = 0
    for _, p in ipairs(d.profs) do
        local row = take(card, "prof", newProfRow)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -y)
        row:SetPoint("TOPRIGHT", 0, -y)
        row.art:SetIcon(p.icon)
        row.name:SetText(p.name .. (p.secondary and T:Wrap("dim", "  secondary") or ""))
        row.name:SetWidth(max(40, w - 42 - 70))   -- leave room for "300 / 300" on the right
        local cap = max(MAX_SKILL, p.rank)
        local maxed = p.rank >= MAX_SKILL
        row.value:SetText(p.rank .. " / " .. cap)
        UI:SetTextColor(row.value, maxed and "wowGold" or "dim")
        row.bar:SetColor(maxed and MAXED or (p.secondary and SECONDARY or GOOD))
        row.bar:SetValue(p.rank / cap)
        y = y + 42
    end
    card.count:SetText(#d.profs)
    return finish(card, y - 8)
end

local function fillBuffs(card, w, d)
    begin(card)
    if #d.buffs == 0 then return emptyLine(card, d.class and LINES.buffsNone or LINES.buffsUnknown) end
    local BD = GF.BuffData
    local chips = {}
    for _, cat in ipairs(d.buffs) do
        local chip = take(card, "chip", newChip)
        setChip(chip, cat.label or cat.key, cat.core and "text" or "dim", API.SpellIcon(cat.icon), w)
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
    if not d.has.loot then return emptyLine(card, LINES.lootOff) end
    if d.lootCount and d.lootCount > 0 then card.count:SetText(d.lootCount .. " " .. U.Plural(d.lootCount, "item")) end
    if #d.loot == 0 then return emptyLine(card, LINES.lootNone) end
    local y = 0
    for i, l in ipairs(d.loot) do
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
        row.rule:SetShown(i < #d.loot)
        y = y + LOOT_ROW_H
    end
    return finish(card, y)
end

local CARDS = {
    { id = "roll", title = "Roll Call", icon = "calendar", fill = fillRoll },
    { id = "titles", title = "Titles", icon = "crown", fill = fillTitles },
    { id = "stats", title = "Stats", icon = "trophy", fill = fillStats },
    { id = "badges", title = "Badges", icon = "star", fill = fillBadges },
    { id = "profs", title = "Tradie licences", icon = "hammer", fill = fillProfs },
    { id = "buffs", title = "Brings to the raid", icon = "campfire", fill = fillBuffs },
    { id = "loot", title = "Loot", icon = "bag", fill = fillLoot },
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
    local ok, why = API.Invite(key)
    if not ok then
        local text = why == "clash" and "Two residents answer to that name and the addon won't guess. /invite the full name yourself."
            or "Couldn't send that invite right now. Try again in a sec."
        UI:Toast({ title = "No dice", text = text, icon = "warning", style = "red", key = "gf-invite-fail" })
    end
end

--- Filled-circle layer for the medallion's well.
local function disc(parent, layer, sub, size, r, g, b, a)
    local t = parent:CreateTexture(nil, layer, nil, sub)
    t:SetTexture(T.tex.circle)
    t:SetSize(size, size)
    t:SetPoint("CENTER")
    t:SetVertexColor(r, g, b, a or 1)
    return t
end

--- Character-sheet plate, the page's one gold rim: a gold-ringed class portrait with a level
-- medallion, and the resident's class colour washed in from the left.
local function buildHero(page, content)
    local h = UI:Card(content, { tier = "hero" })
    h:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    h:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
    h:SetHeight(HERO_H)
    -- class-coloured wash gives every file its own tint
    h.wash = h:CreateTexture(nil, "BACKGROUND", nil, 2)
    h.wash:SetPoint("TOPLEFT", 3, -3)
    h.wash:SetPoint("BOTTOMLEFT", 3, 3)
    h.wash:SetWidth(420)

    -- portrait: class glow behind a class avatar wearing a gold ring
    local p = CreateFrame("Frame", nil, h)
    p:SetSize(PORTRAIT, PORTRAIT)
    p:SetPoint("LEFT", 16, 0)
    p.glow = p:CreateTexture(nil, "BACKGROUND")
    p.glow:SetTexture(T.tex.glow)
    -- kept inside the plate so a loud class colour can't spill over the gold rim
    p.glow:SetSize(HERO_H - 4, HERO_H - 4)
    p.glow:SetPoint("CENTER")
    p.glow:SetBlendMode("ADD")
    p.shadow = disc(p, "BACKGROUND", 1, PORTRAIT + 4, 0, 0, 0, 0.6)
    p.avatar = UI:Avatar(p, PORTRAIT)
    p.avatar:SetPoint("CENTER")
    -- level medallion, PlayerFrame style (a child of the avatar, so it always draws on top
    -- of it without pinning a frame level that a window raise wouldn't carry along)
    local lv = CreateFrame("Frame", nil, p.avatar)
    lv:SetSize(28, 28)
    lv:SetPoint("CENTER", p, "BOTTOMLEFT", 14, 14)
    lv.well = disc(lv, "BACKGROUND", 0, 26, 0.06, 0.05, 0.05, 1)
    lv.ring = lv:CreateTexture(nil, "ARTWORK")
    lv.ring:SetTexture(T.tex.ringMetal)
    lv.ring:SetAllPoints()
    lv.ring:SetVertexColor(1, 0.84, 0.42, 1)
    lv.text = UI:Text(lv, 12, "wowGold", "head")
    lv.text:SetPoint("CENTER", 0, 0)
    lv.text:SetJustifyH("CENTER")
    p.level = lv
    h.portrait = p
    h.avatar = p.avatar

    h.line = UI:Text(h, 16, "text", "ui")
    h.line:SetPoint("TOPLEFT", TEXT_X, -18)
    h.status = UI:Text(h, 12, "dim")
    h.status:SetPoint("TOPLEFT", TEXT_X, -44)
    h.famLabel = UI:Text(h, 11, "dim")
    h.famLabel:SetPoint("LEFT", h, "TOPLEFT", TEXT_X, FAM_Y)
    h.famNone = UI:Text(h, 11, "dim")
    h.also = UI:Text(h, 11, "dim")
    h.also:SetText("Also")
    h.more = UI:Text(h, 11, "dim")
    h.links = {}
    h.meta = UI:Text(h, 11, "dim")
    h.meta:SetPoint("TOPLEFT", TEXT_X, -90)
    h.whisper = UI:Button(h, "Whisper", { icon = "bubble", onClick = function() if page.key then UI:Whisper(page.key) end end })
    h.whisper:SetPoint("TOPRIGHT", -16, -16)
    h.invite = UI:Button(h, "Invite", { icon = "plus", style = "primary", onClick = function() if page.key then invite(page.key) end end })
    h.invite:SetPoint("RIGHT", h.whisper, "LEFT", -8, 0)
    h.you = UI:Pill(h, "THAT'S YOU, LEGEND", "gold", { height = 22, size = 11, icon = "star_fill" })
    h.you:SetPoint("TOPRIGHT", -16, -16)
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
    h.famLabel:SetText(d.main and "Alt of" or "Alts")
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

--- A file's headline: class colour, lifted where the class is too dark to read on the night sky.
local function headlineColor(class)
    local r, g, b = classRGB(class)
    local lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
    if lum < 0.75 then
        local t = (0.75 - lum) / (1 - lum)
        r, g, b = r + (1 - r) * t, g + (1 - g) * t, b + (1 - b) * t
    end
    return r, g, b
end

--- Who, in a line: rank, whether they're home, where. Colour goes on the text; no badges.
local function statusLine(d)
    local bits = {}
    if d.rankName then
        local tone = d.rankIndex == 0 and "wowGold" or (GF.Roster:IsOfficer(d.key) and GOOD or "dim")
        local c = UI.col(tone)
        bits[#bits + 1] = U.Color(shorten(d.rankName, 22), c[1], c[2], c[3])
    end
    if d.online then
        bits[#bits + 1] = U.Color("Home now", GOOD[1], GOOD[2], GOOD[3])
    elseif d.mobile then
        bits[#bits + 1] = T:Wrap("blue", "On the app")
    elseif d.member then
        bits[#bits + 1] = "Offline"
    else
        bits[#bits + 1] = U.Color("Not on the roster", WARN[1], WARN[2], WARN[3])
    end
    if d.zone then bits[#bits + 1] = d.online and d.zone or ("Last seen in " .. d.zone) end
    return concat(bits, DOT)
end

local function fillHero(page, d, W)
    local h = page.hero
    local r, g, b = classRGB(d.class)
    UI:Gradient(h.wash, "HORIZONTAL", r, g, b, 0.14, 0)
    h.portrait.glow:SetVertexColor(r, g, b, 0.34)
    h.avatar:SetClass(d.class)
    -- one ring: class colour already has the glow, the wash and the name
    h.avatar.ring:SetVertexColor(1, 0.84, 0.42, 1)
    if d.level > 0 then
        h.portrait.level.text:SetText(d.level)
        h.portrait.level:Show()
    else
        h.portrait.level:Hide()
    end

    -- "Level 60 Dwarf Priest", the way the character sheet puts it, class word in class colour
    local bits = {}
    if d.level > 0 then bits[#bits + 1] = "Level " .. d.level end
    local race = raceName(d.race)
    if race then bits[#bits + 1] = race end
    if d.class then bits[#bits + 1] = U.Color(API.ClassName(d.class), U.ClassColorHex(d.class)) end
    local line = concat(bits, " ")
    if line == "" then line = (d.member or d.doc) and "Details unknown" or LINES.stranger end
    h.line:SetText(line)
    local rightUsed = d.me and ((h.you:GetWidth() or 150) + 32) or 210
    h.line:SetWidth(max(80, W - TEXT_X - rightUsed))
    h.status:SetText(statusLine(d))
    h.status:SetWidth(max(80, W - TEXT_X - 16))

    fillFamily(h, d, W)

    -- plumbing: the quiet last line, so it doesn't compete with who they are
    local meta = {}
    if d.version then
        meta[#meta + 1] = d.version == "?" and "Greenfields" or ("Greenfields " .. d.version)
    else
        meta[#meta + 1] = "No Greenfields"
    end
    if d.synced then
        meta[#meta + 1] = "Profile synced " .. U.Ago(d.synced)
    elseif not d.me then
        meta[#meta + 1] = "No profile synced yet"
    end
    if not d.me and d.heard then meta[#meta + 1] = "Last heard from " .. U.Ago(d.heard) end
    h.meta:SetText(concat(meta, DOT))
    h.meta:SetWidth(max(80, W - TEXT_X - 16))

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
end

-------------------------------------------------------------------------------
-- "Not on file yet": every empty card, folded into one quiet ledger
-------------------------------------------------------------------------------
local FOLD_LABEL = 156
local FOLD_LABEL_NARROW = 104   -- in a column, the jokes need the width more than the labels do

local function newFoldRow(parent)
    local f = CreateFrame("Frame", nil, parent)
    f.icon = UI:Icon(f, 14, nil, "ARTWORK", "bronze")
    f.icon:SetPoint("TOPLEFT", 0, -1)
    f.name = UI:Para(f, 12, GOLD_DIM, "ui")
    f.name:SetPoint("TOPLEFT", 22, 0)
    f.text = UI:Para(f, 12, "dim")
    return f
end

--- Cards saying the same thing share a row ("No Greenfields, no stats" would otherwise run
-- three times over). Returns the body height.
local function fillFold(fold, empties, w)
    begin(fold)
    local rows, byLine = {}, {}
    for _, card in ipairs(empties) do
        local r = byLine[card.emptyLine]
        if r then
            r.names[#r.names + 1] = card.title:GetText()
        else
            r = { names = { card.title:GetText() }, icon = card.def.icon, text = card.emptyLine }
            byLine[card.emptyLine] = r
            rows[#rows + 1] = r
        end
    end
    local y = 0
    local label = w < 500 and FOLD_LABEL_NARROW or FOLD_LABEL
    local tw = max(60, w - label)
    for _, r in ipairs(rows) do
        local row = take(fold, "row", newFoldRow)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -y)
        row:SetPoint("TOPRIGHT", 0, -y)
        UI:SetIcon(row.icon, r.icon)
        row.name:SetWidth(label - 22 - 8)
        row.name:SetText(concat(r.names, ", "))
        row.text:ClearAllPoints()
        row.text:SetPoint("TOPLEFT", label, 0)
        row.text:SetWidth(tw)
        row.text:SetText(r.text)
        local h = max(row.name:GetStringHeight() or 14, row.text:GetStringHeight() or 14)
        row:SetHeight(h)
        y = y + h + 10
    end
    return finish(fold, max(0, y - 10))
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
    -- which cards have anything to say decides the columns, so fill at the narrowest they'd be
    local colW = floor((W - (cols - 1) * GAP) / cols)
    local shown, empties, bodyH = {}, {}, {}
    for _, card in ipairs(page.cards) do
        local ok, h = GF:Safe("profile:card:" .. card.id, card.fill, card, colW - 24, d)
        h = (ok and type(h) == "number") and h or 18
        card:SetShown(not card.emptyLine and not card.skip)
        if card.emptyLine then
            empties[#empties + 1] = card
        elseif not card.skip then
            shown[#shown + 1] = card
            bodyH[card] = h
        end
    end
    -- one lonely card shouldn't sit half-width next to nothing
    if #shown > 0 and #shown < cols then
        cols = #shown
        colW = floor((W - (cols - 1) * GAP) / cols)
        for _, card in ipairs(shown) do
            local ok, h = GF:Safe("profile:card:" .. card.id, card.fill, card, colW - 24, d)
            bodyH[card] = (ok and type(h) == "number") and h or 18
        end
    end
    local heights = {}
    for i = 1, cols do heights[i] = 0 end
    local top = HERO_H + GAP
    -- whole units leave a sliver over: the last column takes it, so its edge lands on the hero's
    local spare = W - cols * colW - (cols - 1) * GAP
    for _, card in ipairs(shown) do
        local h = ceil(bodyH[card]) + 50
        local ci = 1
        for i = 2, cols do if heights[i] < heights[ci] then ci = i end end
        card:ClearAllPoints()
        card:SetPoint("TOPLEFT", page.content, "TOPLEFT", (ci - 1) * (colW + GAP), -(top + heights[ci]))
        card:SetSize(ci == cols and colW + spare or colW, h)
        heights[ci] = heights[ci] + h + GAP
    end
    local tallest = 0
    for i = 1, cols do tallest = max(tallest, heights[i]) end
    local y = top + tallest
    local fold = page.fold
    fold:SetShown(#empties > 0)
    if #empties > 0 then
        -- the masonry's shortest column usually has a hole just the ledger's size, and that keeps it
        -- on screen (launch morning, it's most of the file); otherwise it runs across the bottom
        local ci = 1
        for i = 2, cols do if heights[i] < heights[ci] then ci = i end end
        local h = cols > 1 and tallest > 0 and fillFold(fold, empties, colW - 24) + 50
        fold:ClearAllPoints()
        if h and heights[ci] + h <= tallest then
            fold:SetPoint("TOPLEFT", page.content, "TOPLEFT", (ci - 1) * (colW + GAP), -(top + heights[ci]))
            fold:SetSize(ci == cols and colW + spare or colW, h)
        else
            h = fillFold(fold, empties, W - 24) + 50
            fold:SetPoint("TOPLEFT", page.content, "TOPLEFT", 0, -y)
            fold:SetSize(W, h)
            y = y + h + GAP
        end
    end
    page.scroll:SetContentHeight(max(0, y - GAP) + 4)
end

-------------------------------------------------------------------------------
-- Page
-------------------------------------------------------------------------------
local profilePage

local function newCard(content, def)
    local card = UI:Card(content, { title = def.title, icon = def.icon })
    card.id, card.fill, card.pools, card.def = def.id, def.fill, {}, def
    card.count = UI:Text(card, 12, "dim", "num")
    card.count:SetPoint("TOPRIGHT", -12, -12)
    card.count:SetJustifyH("RIGHT")
    return card
end

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

    local scroll, content = UI:Scroll(page, { outside = true })
    -- 14 below the header leaves the night scene clear above the file
    scroll:SetPoint("TOPLEFT", page.header, "BOTTOMLEFT", 0, -14)
    scroll:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
    page.scroll, page.content = scroll, content
    page.hero = buildHero(page, content)
    page.cards = {}
    for _, def in ipairs(CARDS) do
        local card = newCard(content, def)
        card.note = UI:Para(card.body, 11, "dim")
        card.note:Hide()
        page.cards[#page.cards + 1] = card
    end
    page.fold = newCard(content, { id = "fold", title = "Not on file yet", icon = "clipboard" })
    page.fold:Hide()
    -- reflow whenever the window is resized
    content:SetScript("OnSizeChanged", function(_, w)
        if page.data and abs(floor(w or 0) - (page.lastW or 0)) >= 1 then GF:Safe("profile:layout", layout, page) end
    end)
end

local function onShow(page, key)
    key = cleanKey(key) or page.key or API.MyKey()
    page.scroll:SetShown(key ~= nil)
    if not key then
        page.header.title:SetText("Resident file")
        UI:SetTextColor(page.header.title, "wowGold")
        page.header:SetSubtitle(LINES.noKey)
        return
    end
    local changed = key ~= page.key
    page.key = key
    page.data = gather(key)
    page.header.title:SetText(U.ShortName(key))
    page.header.title:SetTextColor(headlineColor(page.data.class))
    page.header:SetSubtitle("Everything the street knows about " .. U.ShortName(key) .. ".")
    page.mine:SetShown(not page.data.me)
    layout(page)
    if changed then
        page.scroll:SetVerticalScroll(0)
        page.scroll:UpdateBar()
        -- opening a file: the crowns they hold and their soft-res wins catch the light
        for _, card in ipairs(page.cards) do
            if card.id == "titles" then
                -- a glint is for a crown; shame doesn't get the gold treatment
                shinePool(card, "title", function(row) return not row.shame end)
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
