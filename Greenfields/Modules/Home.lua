--[[ Greenfields - Modules/Home.lua
     The Street: the dashboard everyone lands on when they open Greenfields.

     Top down, in the order a player cares:
       Greeting                your name in a joke, your rank, your attendance and crowns, and the
                               welcome sign, small: the header already says whose street this is
       Next raid               the page's one gold-rimmed card: live countdown (ticks every second,
                               only while on screen), signup counts, Yeah / Maybe / Nah
       Latest from the Watch   the six newest Neighbourhood Watch reports
       Who's home              online guildies with their zones (click: profile)
       Crowns on the street    six curated Hall of Fame titles and who wears them
       Camp check              the Buff Check grade for your current group, or a tip
     Every other module is optional: each card checks its source exists and falls back to
     an empty state with some personality. The tagline and the greeting are re-rolled
     whenever the page goes off screen, so every visit gets fresh ones. ]]

local _, GF = ...
local API, U, UI, T = GF.API, GF.Util, GF.UI, GF.Theme
local C = T.c

local Home = GF:NewModule("Home")

local type, pairs, ipairs, tostring, tonumber, select, unpack = type, pairs, ipairs, tostring, tonumber, select, unpack
local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local format = string.format
local sort, concat = table.sort, table.concat

-------------------------------------------------------------------------------
-- Layout constants
-------------------------------------------------------------------------------
local PAGE = "home"
local GUTTER = 16
local GREET_H = 84
local SIGN_W, SIGN_H = 168, 84            -- the welcome sign art is 512x256: keep it 2:1
local STAT_GAP = 16
local RAID_H, RAID_EMPTY_H = 154, 104
local TWO_COL_MIN = 600
local CARD_CHROME = 48                    -- a titled card's header and bottom padding
local ROW2_MIN = 164                      -- room for a card's empty state
local TILE_H, TILE_GAP = 48, 8
local CROWN_EMPTY_H = 136
local WATCH_ROWS, WATCH_ROW_H = 6, 30
local PEOPLE_MAX, PERSON_H = 12, 26
local MORE_H = 24
local CAMP_SETTLE = 2                     -- the camp card re-grades at most this often while buffs churn
local CAMP_CHIPS = 8
local CAMP_H = 100
local RAID_ART_SIZE = 56
local TAG_W = 108
local ANSWER_W, ANSWER_H, ANSWER_GAP = 92, 28, 6
local WATCH_ICON = 16
local CAMP_ART = "Interface\\Icons\\Spell_Fire_Fire"   -- Basic Campfire

--- Quest-log art for the Next raid card (classic-era icon files). Raids may supply its own.
local RAID_ART = {
    ["Barrow Deeps"] = "Interface\\Icons\\INV_Misc_Bone_ElfSkull_01",
    ["Hyjal Summit"] = "Interface\\Icons\\Spell_Nature_Tranquility",
    ["Onyxia's Lair"] = "Interface\\Icons\\INV_Misc_Head_Dragon_01",
}
local RAID_ART_DEFAULT = "Interface\\Icons\\INV_Misc_Head_Dragon_Black"

-- on parchment: UI.INK has the dark, red and dim inks; LIVE takes this green one
local INK_GREEN = { 0.04, 0.36, 0.14, 1 }

-- crown names: warm paper for glory, a muted rose for the shame board. Neon pink shouts over the
-- whole card, and the gold is for the crown you hold
local CROWN_FAME = { 0.93, 0.85, 0.66, 1 }
local CROWN_SHAME = { 0.93, 0.56, 0.60, 1 }

--- The six crowns the street cares about most (keys in GF.Titles).
local CROWNS = { "deaths_raid", "loot_raid", "wealth", "pvp_kills", "attendance", "afk_minutes" }

local ANSWERS = {
    { key = "yes", text = "Yeah", icon = "check", style = "primary" },
    { key = "maybe", text = "Maybe", icon = "dot", style = "warn" },
    { key = "no", text = "Nah", icon = "close", style = "danger" },
}
local COUNT_ORDER = { "yes", "late", "maybe", "bench", "no" }

local SIGNUP_TOASTS = {
    yes = { title = "Locked in", text = "You're down for %s. Don't be late, legend.", style = "green" },
    maybe = { title = "Pencilled in", text = "Maybe for %s. Make your mind up before the pull.", style = "blue" },
    no = { title = "Yeah nah, noted", text = "Out for %s. The staffy will miss you.", style = "red" },
}

local LINES = {
    crowns = "Nobody's wearing a crown yet. The bar's on the floor, legends. Step over it.",
    noStats = "The Hall of Fame isn't keeping score yet. Someone go embarrass themselves.",
    noGuild = "You're not in a guild. Bit lonely on this street.",
    buffsOff = "The Buff Check is on smoko right now. If it stays that way, try /gf errors.",
    uncrowned = "No crowns yet. Plenty of time to stuff something up.",
}

--- Camping facts worth knowing (FOREVER_FACTS F.3/F.4).
local CAMP_TIPS = {
    "Camp objects stand in for missing class buffs. Weaker, but better than nothing.",
    "Sit by a fire for about a minute to soak up Camp Benefits.",
    "Fires can't go down in instances, so camp up before you zone in.",
    "One object per player per fire, and they all share a one-hour cooldown.",
    "A Fish Bowl covers Kings and a Lodestone covers Might. Tradies, earn your keep.",
}

local pageDef

-------------------------------------------------------------------------------
-- Guarded access to everything outside this file
-------------------------------------------------------------------------------
local function pack(...) return { n = select("#", ...), ... } end

--- call(obj, "Method", ...) -> obj:Method(...) results, or nothing when it's missing or errors.
local function call(obj, method, ...)
    if type(obj) ~= "table" or type(obj[method]) ~= "function" then return nil end
    local r = pack(GF:Safe("home:" .. method, obj[method], obj, ...))
    if not r[1] then return nil end
    return unpack(r, 2, r.n)
end

local function flavorList(name)
    local F = GF.Flavor
    local list = F and F[name]
    return type(list) == "table" and list or nil
end

local function emptyText(key, fallback)
    local F = GF.Flavor
    local e = F and F.emptyStates
    return (type(e) == "table" and type(e[key]) == "string") and e[key] or fallback
end

local function fill(line, vars)
    local F = GF.Flavor
    if F and F.Fill then return F.Fill(line, vars) end
    return line
end

local function colored(key)
    local s = call(GF.Roster, "Colored", key)
    return type(s) == "string" and s or U.ShortName(key)
end

local function classOf(key) return call(GF.Roster, "Class", key) end

local function hasAddon(key)
    if key == API.MyKey() then return true end
    return call(GF.Comm, "HasAddon", key) ~= nil
end

--- Locals online right now with Greenfields running (me included).
local function peerCount()
    local Comm, R, me = GF.Comm, GF.Roster, API.MyKey()
    local n = 1
    if not (Comm and type(Comm.peers) == "table") then return n end
    local now = API.ServerTime()
    for key, p in pairs(Comm.peers) do
        if key ~= me and type(p) == "table" and type(p.seen) == "number" and now - p.seen < 3600
            and call(R, "IsOnline", key) then
            n = n + 1
        end
    end
    return n
end

local function myMain()
    local me = API.MyKey()
    if not me then return nil end
    local m = call(GF.Roster, "MainOf", me)
    return type(m) == "string" and m or me
end

-------------------------------------------------------------------------------
-- Shared bits
-------------------------------------------------------------------------------
local function place(f, parent, x, y, w, h)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
    f:SetSize(w, h)
end

--- A kind marker: a line icon draws bare in the kind's colour, real game art keeps a thin dark edge.
-- :SetKind(icon, color). A gold bevel would say "this is a game item" when it's only a label.
local function kindIcon(parent, size)
    local f = UI:IconChip(parent, size)
    function f:SetKind(icon, color)
        self:SetIcon(icon)
        local game = self.icon.isGameIcon and true or false
        self.edge:SetShown(game)
        if not game then
            local c = UI.col(color or "dim")
            self.icon:SetVertexColor(c[1], c[2], c[3], 1)
        end
    end
    return f
end

--- The kit's empty block, scaled down to sit inside a card.
local function cardEmpty(parent, icon)
    local f = UI:Empty(parent, "", icon or "eye")
    f.icon:SetSize(28, 28)
    f:SetHeight(84)
    f:Hide()
    return f
end

--- "Open >": a go-there link in a card's header, the chevron trailing so it can't read as a
-- disclosure triangle.
local function headerLink(card, text, onClick)
    local b = CreateFrame("Button", nil, card)
    b:SetHeight(20)
    b.label = UI:Text(b, 11, "dim", "ui")
    b.label:SetText(text)
    b.chev = UI:Icon(b, 10, "chevron_right", "ARTWORK", "dim")
    b.chev:SetPoint("RIGHT", 0, 0)
    b.label:SetPoint("RIGHT", b.chev, "LEFT", -4, 0)
    b:SetWidth((b.label:GetStringWidth() or 40) + 14)
    b:SetPoint("TOPRIGHT", card, "TOPRIGHT", -12, -7)
    local function paint(color)
        UI:SetTextColor(b.label, color)
        local c = UI.col(color)
        b.chev:SetVertexColor(c[1], c[2], c[3], 1)
    end
    b:RegisterForClicks("LeftButtonUp")
    b:SetScript("OnEnter", function() paint("gold") end)
    b:SetScript("OnLeave", function() paint("dim") end)
    b:SetScript("OnClick", function(self)
        if UI.Sound then UI.Sound(856) end
        GF:Safe("home:link", onClick, self)
    end)
    return b
end

--- Keeps a click on an item link (tooltip / shift-link) from also triggering the row.
local function trackLinkClicks(f)
    UI:EnableLinks(f)
    if f.GetScript and f:GetScript("OnHyperlinkClick") then
        f:HookScript("OnHyperlinkClick", function(self) self.linkAt = API.Time() end)
    end
end

local function unlessLink(f, fn)
    local at = API.Time()
    GF:After(0, function()
        if f.linkAt and abs(f.linkAt - at) < 0.2 then return end
        fn()
    end)
end

-------------------------------------------------------------------------------
-- Greeting
-------------------------------------------------------------------------------
--- A flat icon-and-words fact under the greeting: lights up on hover, explains itself, goes somewhere.
-- Words instead of pills: four coloured capsules in a row read as traffic lights.
local function heroStat(parent, icon, tip, onClick)
    local s = CreateFrame("Button", nil, parent)
    s:SetHeight(18)
    s.iconName = icon
    s.art = kindIcon(s, 16)
    s.art:SetPoint("LEFT", 0, 0)
    s.label = UI:Text(s, 12, "dim", "ui")
    s.label:SetPoint("LEFT", s.art, "RIGHT", 6, 0)
    function s:SetText(t, color)
        self.color = UI.col(color or "dim")
        self.label:SetText(t or "")
        UI:SetTextColor(self.label, self.color)
        self.art:SetKind(self.iconName, self.color)
        self:SetWidth(26 + (self.label:GetStringWidth() or 0))
    end
    function s:SetArt(ic) self.iconName = ic or "crown" end
    s:RegisterForClicks("LeftButtonUp")
    s:SetScript("OnEnter", function(self)
        UI:SetTextColor(self.label, "text")
        local t = tip and tip(self)
        if type(t) == "table" then UI:Tip(self, t[1], t[2]) end
    end)
    s:SetScript("OnLeave", function(self)
        UI:SetTextColor(self.label, self.color or "dim")
        UI:HideTip()
    end)
    s:SetScript("OnClick", function(self)
        if UI.Sound then UI.Sound(841) end
        GF:Safe("home:stat", onClick, self)
    end)
    return s
end

local function titleColor(def) return (def and def.group == "fame") and "gold" or "pink" end

local function titleTip(def)
    if not def then return nil end
    return { def.title, { def.label or "", T:Wrap("dim", '"' .. (def.blurb or "") .. '"'), T:Wrap("faint", "Click for the leaderboard.") } }
end

--- Lays the facts out left to right; titles collapse into "+N" when the row runs out of room.
local function fitStats(page)
    local h = page.hero
    if not h then return end
    local avail = h.stats:GetWidth() or 0
    if avail < 40 then avail = 300 end
    local titles = page.titles or {}
    local n = #titles
    local used = h.att:GetWidth() + STAT_GAP
    local shownTitles = 0
    if n == 0 then
        h.more:SetArt("crown")
        h.more:SetText("Uncrowned", "dim")
    else
        for k = min(2, n), 0, -1 do
            local w = used
            for i = 1, k do
                local def = titles[i]
                h.titles[i]:SetArt(def.art)
                h.titles[i]:SetText(def.title or "?", def.group == "fame" and "gold" or CROWN_SHAME)
                w = w + h.titles[i]:GetWidth() + STAT_GAP
            end
            local rest = n - k
            if rest > 0 then
                h.more:SetArt("crown")
                h.more:SetText(k == 0 and (n .. U.Plural(n, " crown")) or ("+" .. rest), "gold")
                w = w + h.more:GetWidth() + STAT_GAP
            end
            shownTitles = k
            if w - STAT_GAP <= avail then break end
        end
    end
    local order = { h.att }
    for i = 1, 2 do
        if i <= shownTitles then order[#order + 1] = h.titles[i] else h.titles[i]:Hide() end
    end
    if n == 0 or n > shownTitles then order[#order + 1] = h.more else h.more:Hide() end
    local x = 0
    for _, p in ipairs(order) do
        p:ClearAllPoints()
        if x + p:GetWidth() <= avail + 1 then
            p:SetPoint("LEFT", h.stats, "LEFT", x, 0)
            p:Show()
            x = x + p:GetWidth() + STAT_GAP
        else
            p:Hide()
        end
    end
end

--- The text block sits centred on the sign, whether the joke took one line or two.
local function seatGreeting(page)
    local h = page.hero
    local block = (h.greet:GetStringHeight() or 22) + 4 + 14 + 8 + 18
    local y = max(0, floor((GREET_H - block) / 2))
    h.greet:ClearAllPoints()
    -- corner pairs only: a bare RIGHT anchor would pin the line to the strip's centre
    h.greet:SetPoint("TOPLEFT", h, "TOPLEFT", 0, -y)
    h.greet:SetPoint("TOPRIGHT", h, "TOPRIGHT", -(SIGN_W + GUTTER), -y)
end

local function buildHero(page, parent)
    -- no panel: the greeting is the street talking, and the raid below is the first real object
    local h = CreateFrame("Frame", nil, parent)

    h.sign = h:CreateTexture(nil, "ARTWORK")
    h.sign:SetTexture(T.tex.welcome)
    h.sign:SetSize(SIGN_W, SIGN_H)
    h.sign:SetPoint("TOPRIGHT", 2, 0)     -- past the art's soft edge, so the metal meets the cards' edge
    -- it's night out here, and the header's sign is the one that's lit
    h.sign:SetVertexColor(0.88, 0.88, 0.86, 1)

    h.greet = UI:Text(h, 18, "text", "ui")
    h.greet:SetWordWrap(true)
    h.greet:SetJustifyV("TOP")
    if h.greet.SetMaxLines then h.greet:SetMaxLines(2) end
    h.greet:SetPoint("TOPLEFT", 0, 0)
    h.greet:SetPoint("TOPRIGHT", h, "TOPRIGHT", -(SIGN_W + GUTTER), 0)
    h.sub = UI:Text(h, 12, "dim")
    h.sub:SetPoint("TOPLEFT", h.greet, "BOTTOMLEFT", 0, -4)
    h.sub:SetPoint("TOPRIGHT", h.greet, "BOTTOMRIGHT", 0, -4)

    h.stats = CreateFrame("Frame", nil, h)
    h.stats:SetHeight(18)
    h.stats:SetPoint("TOPLEFT", h.sub, "BOTTOMLEFT", 0, -8)
    h.stats:SetPoint("TOPRIGHT", h.sub, "BOTTOMRIGHT", 0, -8)

    h.att = heroStat(h.stats, "check", function()
        local me = API.MyKey()
        local s = me and call(GF.Attendance, "Summary", me)
        if type(s) ~= "table" then
            return { "Attendance", { emptyText("attendance", "No raids recorded yet. Attendance: theoretical.") } }
        end
        return { "Attendance", {
            { "Raids attended", format("%d of %d", tonumber(s.attended) or 0, tonumber(s.total) or 0) },
            { "Current streak", tostring(tonumber(s.streak) or 0) },
            { "Late / flaked", format("%d / %d", tonumber(s.late) or 0, tonumber(s.flakes) or 0) },
            T:Wrap("faint", "Click for Roll Call."),
        } }
    end, function() UI:ShowPage("attendance") end)

    h.titles = {}
    for i = 1, 2 do
        h.titles[i] = heroStat(h.stats, "crown", function()
            return titleTip(page.titles and page.titles[i])
        end, function()
            local def = page.titles and page.titles[i]
            UI:ShowPage("fame", def and def.key or nil)
        end)
    end
    h.more = heroStat(h.stats, "crown", function()
        local titles = page.titles or {}
        if #titles == 0 then return { "Uncrowned", { LINES.uncrowned } } end
        local lines = {}
        for _, def in ipairs(titles) do lines[#lines + 1] = T:Wrap(titleColor(def), def.title) .. T:Wrap("faint", "  " .. (def.label or "")) end
        return { "Your crowns", lines }
    end, function() UI:ShowPage("fame") end)

    h:SetScript("OnSizeChanged", function() fitStats(page) end)
    return h
end

local function renderHero(page)
    local h = page.hero
    local me = API.MyKey()
    local class = API.UnitClassFile("player")
    local name = me and U.ClassName(me, class) or "legend"
    h.greet:SetText(fill(page.greetLine or "G'day {name}. Welcome back to Greenfields.", { name = name }))

    local parts = {}
    local m = me and call(GF.Roster, "Get", me)
    local gname = API.GuildInfo()
    if type(m) == "table" and type(m.rankName) == "string" and m.rankName ~= "" and gname then
        parts[#parts + 1] = m.rankName .. " of " .. gname
    elseif gname then
        parts[#parts + 1] = gname
    else
        parts[#parts + 1] = "Unaffiliated. Living rough."
    end
    local level = API.UnitLevel("player")
    if level > 0 and class then parts[#parts + 1] = format("Level %d %s", level, API.ClassName(class)) end
    local main = myMain()
    if me and main and main ~= me then parts[#parts + 1] = "Alt of " .. colored(main) end
    h.sub:SetText(concat(parts, T:Wrap("faint", "  \194\183  ")))

    local pct = tonumber(me and call(GF.Attendance, "Percent", me))
    if pct then
        pct = floor(U.Clamp(pct, 0, 100) + 0.5)
        h.att:SetText(pct .. "% attendance", pct >= 75 and "green" or (pct >= 50 and "yellow" or "red"))
    else
        h.att:SetText("No raids on file", "dim")
    end
    local titles = me and call(GF.Stats, "TitlesOf", me)
    page.titles = {}
    if type(titles) == "table" then
        for _, def in ipairs(titles) do
            if type(def) == "table" and type(def.title) == "string" then page.titles[#page.titles + 1] = def end
        end
    end
    fitStats(page)
    seatGreeting(page)
    -- a wrapped string only measures true once it's been laid out, so check again next frame
    GF:After(0, function() seatGreeting(page) end)
end

-------------------------------------------------------------------------------
-- Next raid
-------------------------------------------------------------------------------
local function countsFor(id)
    local c = { yes = 0, late = 0, maybe = 0, bench = 0, no = 0 }
    local got = call(GF.Raids, "Counts", id)
    if type(got) == "table" then
        for s in pairs(c) do c[s] = tonumber(got[s]) or 0 end
        return c
    end
    local list = call(GF.Raids, "SignupsFor", id)
    if type(list) == "table" then
        for _, su in ipairs(list) do
            if type(su) == "table" and c[su.status] then c[su.status] = c[su.status] + 1 end
        end
    end
    return c
end

local function raidState(ev, now)
    if now < ev.time then return "soon" end
    if now <= ev.time + (tonumber(ev.duration) or 10800) then return "live" end
    return "done"
end

--- The signup tallies above the bar, right-aligned: bare numerals, since the same icons label the
-- answer buttons beside them and the hover tips say the rest.
local function layoutRaidCounts(page)
    local c = page.raid
    local counts = c and c.counts
    if not counts then return end
    local x = 0
    for i = #COUNT_ORDER, 1, -1 do
        local s = COUNT_ORDER[i]
        local mark = c.marks[s]
        -- bench is an officer call; only worth showing once someone's on it
        if s == "bench" and (counts[s] or 0) == 0 then
            mark:Hide()
        else
            mark:Set(counts[s] or 0)
            mark:ClearAllPoints()
            mark:SetPoint("TOPRIGHT", c.fillRow, "TOPRIGHT", -x, 0)
            mark:Show()
            x = x + mark:GetWidth() + 10
        end
    end
end

--- The date line drops the raid's nickname whole when it won't fit (it's still on Raid Nights):
-- a two-letter stub of a name looks unfinished.
local function fitWhen(page)
    local c = page.raid
    if not (c and c.whenFull) then return end
    c.when:SetText(c.whenFull)
    local natural = c.when.GetUnboundedStringWidth and c.when:GetUnboundedStringWidth() or c.when:GetStringWidth()
    local avail = (page.raidW or 400) - RAID_ART_SIZE - TAG_W - 24
    if (tonumber(natural) or 0) > avail then c.when:SetText(c.whenShort) end
end

local renderRaid

local function tickRaid(page)
    local c = page.raid
    local ev = c and c.ev
    if not ev then return end
    local now = API.ServerTime()
    local state = raidState(ev, now)
    if state ~= c.state then
        -- crossed the pull (or the finish): the whole card changes
        renderRaid(page)
        return
    end
    -- written on the parchment tag, so dark inks: red when the pull is under an hour out
    if state == "soon" then
        local left = ev.time - now
        c.cdLabel:SetText("PULL IN")
        c.cd:SetText(U.Duration(left))
        UI:SetTextColor(c.cd, left < 3600 and UI.INK.red or UI.INK.dark)
    elseif state == "live" then
        c.cdLabel:SetText("RIGHT NOW")
        c.cd:SetText("LIVE")
        UI:SetTextColor(c.cd, INK_GREEN)
    else
        c.cdLabel:SetText("STATUS")
        c.cd:SetText("WRAPPED")
        UI:SetTextColor(c.cd, UI.INK.dim)
    end
end

renderRaid = function(page)
    local c = page.raid
    local list = call(GF.Raids, "Upcoming", 1)
    local ev = type(list) == "table" and list[1] or nil
    if type(ev) ~= "table" or type(ev.time) ~= "number" or type(ev.id) ~= "string" then ev = nil end
    c.ev = ev
    c.content:SetShown(ev ~= nil)
    c.empty:SetShown(ev == nil)
    if not ev then
        c.state, c.counts = nil, nil
        c.whenFull, c.whenShort = nil, nil
        c.empty.text:SetText(emptyText("events", "No raids planned. Go touch grass (it's dead, it's Greenfields)."))
        -- officers can do something about it, and that's the thing this screen wants pressed
        local officer = call(GF.Raids, "IsOfficer")
        c.empty.action:SetText(officer and "Plan a raid" or "See Raid Nights")
        c.empty.action:SetStyle(officer and "primary" or "secondary")
        return
    end
    local inst = (type(ev.instance) == "string" and ev.instance ~= "") and ev.instance or "Raid night"
    local info
    if GF.Raids and type(GF.Raids.InstanceInfo) == "function" then
        local ok, res = pcall(GF.Raids.InstanceInfo, inst)
        if ok and type(res) == "table" then info = res end
    end
    local title = (type(ev.title) == "string" and ev.title ~= "") and ev.title or nil
    -- "Other" is the Raids catch-all, not a place: headline the raid's own name instead
    local headline = inst
    if inst == "Other" then headline = title or "Raid night" end
    c.inst:SetText(headline)
    local art = info and (info.art or info.icon)
    if type(art) ~= "string" and type(art) ~= "number" then art = RAID_ART[inst] or RAID_ART_DEFAULT end
    c.art:SetIcon(art)
    local bits = { U.DateTime(ev.time) }
    if tonumber(ev.size) then bits[#bits + 1] = tonumber(ev.size) .. "-man" end
    c.whenShort = concat(bits, "  \194\183  ")
    if title and title ~= headline then bits[#bits + 1] = title end
    c.whenFull = concat(bits, "  \194\183  ")
    fitWhen(page)

    local counts = countsFor(ev.id)
    c.counts = counts
    local locked = counts.yes + counts.late
    local size = tonumber(ev.size) or 0
    c.fill:SetText(size > 0 and format("%d / %d locked in", locked, size) or format("%d locked in", locked))
    c.bar:SetValue(size > 0 and locked / size or 0)
    c.bar:SetColor((size > 0 and locked >= size) and "green" or "yellow")
    layoutRaidCounts(page)

    local mine = call(GF.Raids, "MySignup", ev.id)
    local st = type(mine) == "table" and T.status[mine.status] and mine.status or nil
    -- a lit button already says what you answered. No answer needs words, and so do Late and Bench,
    -- which have no button on this card
    local lit = st == "yes" or st == "maybe" or st == "no"
    c.mine:SetShown(not lit)
    if not st then
        c.mine:SetText(T:Wrap("yellow", "You haven't answered yet.") .. T:Wrap("dim", " The street is waiting."))
    elseif not lit then
        c.mine:SetText(T:Wrap("dim", "Your answer: ") .. T.status[st].long)
    end
    -- two lines centre on the art, three fill it
    local y = lit and 6 or 0
    c.inst:ClearAllPoints()
    c.inst:SetPoint("TOPLEFT", c.art, "TOPRIGHT", 12, -y)
    c.inst:SetPoint("TOPRIGHT", c.content, "TOPRIGHT", -(TAG_W + 12), -y)
    local over = call(GF.Raids, "IsOver", ev)
    for _, a in ipairs(ANSWERS) do
        local btn = c.answer[a.key]
        -- before you answer, Yeah is the page's one green button; after, your pick is lit and the rest step back
        if st then
            btn:SetStyle(st == a.key and a.style or "ghost")
        else
            btn:SetStyle(a.key == "yes" and "primary" or "secondary")
        end
        btn:SetActive(not over)
    end
    c.state = raidState(ev, API.ServerTime())
    tickRaid(page)
end

local function answer(page, status)
    local ev = page.raid and page.raid.ev
    if not ev then return end
    local ok, err = call(GF.Raids, "SetSignup", ev.id, status)
    local what = (type(ev.title) == "string" and ev.title ~= "") and ev.title or (ev.instance or "the raid")
    if ok then
        local t = SIGNUP_TOASTS[status]
        UI:Toast({ title = t.title, text = format(t.text, what), icon = T.status[status].icon, style = t.style,
            key = "home:signup:" .. ev.id .. ":" .. status })
    else
        UI:Toast({ title = "Didn't stick", icon = "warning", style = "red",
            text = type(err) == "string" and err or "Couldn't save that. Try the Raid Nights page." })
    end
    renderRaid(page)
end

local function buildRaid(page, parent)
    -- the page's one gold rim: this card is what the street is for
    local c = UI:Card(parent, { title = "Next raid", icon = "calendar", tier = "hero" })
    c.open = headerLink(c, "Open", function() UI:ShowPage("raids", c.ev and c.ev.id or nil) end)
    c.content = CreateFrame("Frame", nil, c.body)
    -- 4 clear of the kit's padding: the gold rim's corner leaves curl in further than a plain card's
    c.content:SetPoint("TOPLEFT", c.body, "TOPLEFT", 0, 0)
    c.content:SetPoint("BOTTOMRIGHT", c.body, "BOTTOMRIGHT", 0, 4)
    local f = c.content

    -- the countdown is a parchment notice pinned to the card: the one light object on the page
    c.tag = CreateFrame("Frame", nil, f)
    c.tag:SetSize(TAG_W, RAID_ART_SIZE)
    c.tag:SetPoint("TOPRIGHT", 0, 0)
    UI:Parchment(c.tag)
    c.cdLabel = UI:Text(c.tag, 10, UI.INK.dim, "head")
    c.cdLabel:SetPoint("TOP", 0, -9)
    c.cdLabel:SetJustifyH("CENTER")
    c.cd = UI:Text(c.tag, 22, UI.INK.dark, "num")
    c.cd:SetPoint("TOP", c.cdLabel, "BOTTOM", 0, -3)
    c.cd:SetJustifyH("CENTER")
    for _, fs in ipairs({ c.cdLabel, c.cd }) do
        -- ink doesn't cast a shadow
        if fs.SetShadowColor then fs:SetShadowColor(0, 0, 0, 0) end
    end

    -- quest-log heading: the raid's art, its name in Morpheus gold
    c.art = UI:FramedIcon(f, RAID_ART_SIZE, RAID_ART_DEFAULT)
    c.art:SetPoint("TOPLEFT", 0, 0)
    -- corner pairs only: TOPLEFT + RIGHT would pin each line's centre to the card's
    c.inst = UI:Text(f, 24, "wowGold", "title")
    c.inst:SetPoint("TOPLEFT", c.art, "TOPRIGHT", 12, 0)
    c.inst:SetPoint("TOPRIGHT", f, "TOPRIGHT", -(TAG_W + 12), 0)
    c.when = UI:Text(f, 12, "dim")
    c.when:SetPoint("TOPLEFT", c.inst, "BOTTOMLEFT", 0, -3)
    c.when:SetPoint("TOPRIGHT", c.inst, "BOTTOMRIGHT", 0, -3)
    c.mine = UI:Text(f, 12, "text")
    c.mine:SetPoint("TOPLEFT", c.when, "BOTTOMLEFT", 0, -3)
    c.mine:SetPoint("TOPRIGHT", c.when, "BOTTOMRIGHT", 0, -3)

    -- bottom row: the turnout on the left, your answer on the right
    local answersW = 3 * ANSWER_W + 2 * ANSWER_GAP
    c.fillRow = CreateFrame("Frame", nil, f)
    c.fillRow:SetHeight(ANSWER_H)
    c.fillRow:SetPoint("BOTTOMLEFT", 0, 0)
    c.fillRow:SetPoint("BOTTOMRIGHT", -(answersW + 20), 0)
    c.fill = UI:Text(c.fillRow, 12, "text", "ui")
    c.fill:SetPoint("TOPLEFT", 0, 0)
    c.bar = UI:Bar(c.fillRow, { height = 8 })
    c.bar:SetPoint("BOTTOMLEFT", 0, 1)
    c.bar:SetPoint("BOTTOMRIGHT", 0, 1)

    c.marks = {}
    for _, s in ipairs(COUNT_ORDER) do
        local meta = T.status[s]
        local m = CreateFrame("Frame", nil, c.fillRow)
        m:SetHeight(14)
        m.icon = UI:Icon(m, 10, meta.icon, "ARTWORK", meta.color)
        m.icon:SetPoint("LEFT", 0, 0)
        m.num = UI:Text(m, 13, meta.color, "num")
        m.num:SetPoint("LEFT", m.icon, "RIGHT", 3, 0)
        function m:Set(n)
            self.num:SetText(tostring(n))
            -- nobody in that column yet: it steps back
            local col = UI.col(n > 0 and meta.color or "faint")
            UI:SetTextColor(self.num, col)
            self.icon:SetVertexColor(col[1], col[2], col[3], 1)
            self:SetWidth(13 + (self.num:GetStringWidth() or 8))
        end
        m:EnableMouse(true)
        UI.AttachTip(m, function()
            local n = c.counts and c.counts[s] or 0
            return { meta.long, { format("%d %s", n, U.Plural(n, "local")) } }
        end)
        c.marks[s] = m
    end

    c.answer = {}
    local prev
    for _, a in ipairs(ANSWERS) do
        local btn = UI:Button(f, a.text, {
            icon = a.icon, height = ANSWER_H, width = ANSWER_W, tooltip = T.status[a.key].long,
            onClick = function() answer(page, a.key) end,
        })
        if prev then
            btn:SetPoint("LEFT", prev, "RIGHT", ANSWER_GAP, 0)
        else
            btn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -(answersW - ANSWER_W), 0)
        end
        c.answer[a.key] = btn
        prev = btn
    end

    -- nothing planned: one line across the card and the way out of it
    local e = CreateFrame("Frame", nil, c.body)
    e:SetAllPoints(c.body)
    e.icon = UI:Icon(e, 28, "calendar", "ARTWORK", { C.bronze[1], C.bronze[2], C.bronze[3], 0.7 })
    e.icon:SetPoint("LEFT", 4, 0)
    e.action = UI:Button(e, "See Raid Nights", { height = ANSWER_H, onClick = function() UI:ShowPage("raids") end })
    e.action:SetPoint("RIGHT", 0, 0)
    e.text = UI:Para(e, 13, "text")
    e.text:SetPoint("LEFT", e.icon, "RIGHT", 12, 0)
    e.text:SetPoint("RIGHT", e.action, "LEFT", -16, 0)
    e:Hide()
    c.empty = e
    return c
end

-------------------------------------------------------------------------------
-- Crowns on the street
-------------------------------------------------------------------------------
local function paintTile(t, hover)
    t.hl:SetShown(hover and true or false)
    t.mineEdge:SetShown(t.mine and true or false)
    t.art:SetTone(t.mine and "gold" or nil)
end

local function makeTile(parent)
    local t = CreateFrame("Button", nil, parent)
    t:SetHeight(TILE_H)
    -- a carved slot, like the achievement frame's: depth instead of another rim
    t.skin = UI:Nine(t, "inset", "BACKGROUND", -6)
    t.hl = t:CreateTexture(nil, "BACKGROUND", nil, 2)
    t.hl:SetPoint("TOPLEFT", 1, -1)
    t.hl:SetPoint("BOTTOMRIGHT", -1, 1)
    t.hl:SetColorTexture(1, 0.90, 0.68, 0.055)
    t.hl:Hide()
    -- the crown you hold: a gold edge and a gold frame, and nothing that needs reading
    t.mineEdge = t:CreateTexture(nil, "ARTWORK")
    t.mineEdge:SetPoint("TOPLEFT", 0, -3)
    t.mineEdge:SetPoint("BOTTOMLEFT", 0, 3)
    t.mineEdge:SetWidth(2)
    t.mineEdge:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 1)
    t.mineEdge:Hide()
    t.art = UI:FramedIcon(t, 34, "crown")
    t.art:SetPoint("LEFT", 8, 0)
    -- title over name, top-anchored by their corners (a bare RIGHT anchor would pin both
    -- lines to the tile's centre and stack them on each other)
    t.title = UI:Text(t, 12, CROWN_FAME, "ui")
    t.title:SetPoint("TOPLEFT", t.art, "TOPRIGHT", 10, -2)
    t.title:SetPoint("TOPRIGHT", t, "TOPRIGHT", -8, -9)
    t.name = UI:Text(t, 12, "text", "ui")
    t.name:SetPoint("TOPLEFT", t.title, "BOTTOMLEFT", 0, -4)
    t.name:SetPoint("TOPRIGHT", t.title, "BOTTOMRIGHT", 0, -4)

    t:RegisterForClicks("LeftButtonUp")
    t:SetScript("OnEnter", function(self)
        paintTile(self, true)
        -- a crown you wear catches the light
        if self.mine then UI:Shine(self, 0.7) end
        local def = self.def
        if not def then return end
        local lines = { def.label or "" }
        if self.key then
            local value = ""
            if def.kind ~= "rank" and self.value ~= nil then value = call(GF.Stats, "Format", def.key, self.value) or "" end
            lines[#lines + 1] = { colored(self.key), value }
        else
            lines[#lines + 1] = T:Wrap("dim", "Up for grabs. Nobody's claimed it. Yet.")
        end
        lines[#lines + 1] = T:Wrap("dim", '"' .. (def.blurb or "") .. '"')
        lines[#lines + 1] = T:Wrap("faint", "Click for the full leaderboard.")
        UI:Tip(self, T:Wrap(titleColor(def), def.title), lines)
    end)
    t:SetScript("OnLeave", function(self)
        paintTile(self, false)
        UI:HideTip()
    end)
    t:SetScript("OnClick", function(self)
        if UI.Sound then UI.Sound(841) end
        UI:ShowPage("fame", self.def and self.def.key or nil)
    end)
    paintTile(t, false)
    return t
end

local function buildCrowns(page, parent)
    local c = UI:Card(parent, { title = "Crowns on the street", icon = "crown" })
    c.go = headerLink(c, "Hall of Fame", function() UI:ShowPage("fame") end)
    c.grid = CreateFrame("Frame", nil, c.body)
    c.grid:SetAllPoints(c.body)
    c.tiles = {}
    for i = 1, #CROWNS do c.tiles[i] = makeTile(c.grid) end
    c.empty = cardEmpty(c.body, "crown")
    return c
end

local function crownCols(bodyW) return bodyW >= 640 and 3 or 2 end

local function layoutCrowns(page, bodyW)
    local c = page.crowns
    local cols = crownCols(bodyW)
    local tw = floor((bodyW - (cols - 1) * TILE_GAP) / cols)
    for i, tile in ipairs(c.tiles) do
        local col, row = (i - 1) % cols, floor((i - 1) / cols)
        tile:ClearAllPoints()
        tile:SetPoint("TOPLEFT", c.grid, "TOPLEFT", col * (tw + TILE_GAP), -row * (TILE_H + TILE_GAP))
        tile:SetWidth(tw)
    end
end

local function renderCrowns(page)
    local c = page.crowns
    local S = GF.Stats
    local mine = myMain()
    local any = false
    for i, statKey in ipairs(CROWNS) do
        local tile = c.tiles[i]
        local def = GF.TitlesByKey and GF.TitlesByKey[statKey]
        tile.def = def
        if def then
            local key, value = call(S, "Leader", statKey)
            key = type(key) == "string" and key or nil
            tile.key, tile.value = key, value
            tile.title:SetText(def.title)
            UI:SetTextColor(tile.title, def.group == "fame" and CROWN_FAME or CROWN_SHAME)
            tile.art:SetIcon(def.art or def.icon or "crown")
            -- an unclaimed crown sits in its frame greyed out, waiting
            tile.art:SetDesaturated(key == nil)
            tile.art:SetAlpha(key and 1 or 0.6)
            if key then
                any = true
                tile.name:SetText(colored(key))
            else
                tile.name:SetText(T:Wrap("dim", "Up for grabs"))
            end
            tile.mine = key ~= nil and key == mine
            paintTile(tile, tile:IsMouseOver())
            tile:Show()
            if tile.mine and page.shineCrowns then UI:Shine(tile, 0.9) end
        else
            tile.mine = false
            tile:Hide()
        end
    end
    page.shineCrowns = false
    page.anyCrowns = any
    c.grid:SetShown(any)
    c.empty:SetShown(not any)
    if not any then c.empty.text:SetText(S and LINES.crowns or LINES.noStats) end
end

-------------------------------------------------------------------------------
-- Latest from the Watch
-------------------------------------------------------------------------------
local function makeWatchRow(parent)
    local r = CreateFrame("Button", nil, parent)
    r:SetHeight(WATCH_ROW_H)
    r.hl = r:CreateTexture(nil, "BACKGROUND")
    r.hl:SetAllPoints()
    r.hl:SetColorTexture(1, 0.90, 0.68, 0.055)
    r.hl:Hide()
    r.line = r:CreateTexture(nil, "ARTWORK")
    r.line:SetColorTexture(C.lineSoft[1], C.lineSoft[2], C.lineSoft[3], C.lineSoft[4])
    r.line:SetHeight(1)
    r.line:SetPoint("BOTTOMLEFT")
    r.line:SetPoint("BOTTOMRIGHT")
    r.art = kindIcon(r, WATCH_ICON)
    r.art:SetPoint("LEFT", 2, 0)
    r.ago = UI:Text(r, 11, "dim", "num")
    r.ago:SetPoint("RIGHT", -2, 0)
    r.ago:SetJustifyH("RIGHT")
    r.text = UI:Text(r, 12, "text")
    r.text:SetPoint("LEFT", r.art, "RIGHT", 8, 0)
    r.text:SetPoint("RIGHT", r.ago, "LEFT", -10, 0)
    trackLinkClicks(r)
    r:RegisterForClicks("LeftButtonUp")
    r:SetScript("OnEnter", function(self)
        self.hl:Show()
        local e = self.e
        if not e then return end
        local lines = {}
        if self.cut or (self.text.IsTruncated and self.text:IsTruncated()) then lines[#lines + 1] = e.text end
        if type(e.from) == "string" then lines[#lines + 1] = { colored(e.from), U.DateTime(e.t) } end
        lines[#lines + 1] = T:Wrap("faint", "Click to open the Watch.")
        UI:Tip(self, "Neighbourhood Watch", lines)
    end)
    r:SetScript("OnLeave", function(self)
        self.hl:Hide()
        UI:HideTip()
    end)
    r:SetScript("OnClick", function(self)
        unlessLink(self, function() UI:ShowPage("feed") end)
    end)
    return r
end

local function buildWatch(page, parent)
    local c = UI:Card(parent, { title = "Latest from the Watch", icon = "eye" })
    c.all = headerLink(c, "View all", function() UI:ShowPage("feed") end)
    c.rows = {}
    for i = 1, WATCH_ROWS do
        local r = makeWatchRow(c.body)
        r:SetPoint("TOPLEFT", c.body, "TOPLEFT", 0, -(i - 1) * WATCH_ROW_H)
        r:SetPoint("TOPRIGHT", c.body, "TOPRIGHT", 0, -(i - 1) * WATCH_ROW_H)
        c.rows[i] = r
    end
    c.empty = cardEmpty(c.body, "eye")
    return c
end

--- A tight row gives up a title's "(what it's for)" before it cuts the sentence; the tip has it all.
-- Measured against the column rather than asking IsTruncated, which lags a resize.
local function fitWatch(page)
    for _, r in ipairs(page.watch.rows) do
        if r.e then
            r.text:SetText(r.e.text)
            r.cut = false
            local natural = r.text.GetUnboundedStringWidth and r.text:GetUnboundedStringWidth() or r.text:GetStringWidth()
            local avail = (page.watchW or 300) - WATCH_ICON - 22 - (r.ago:GetStringWidth() or 40)
            if (tonumber(natural) or 0) > avail then
                local short = (r.e.text:gsub("%s*%b()", ""))
                if short ~= r.e.text then
                    r.text:SetText(short)
                    r.cut = true
                end
            end
        end
    end
end

local function renderWatch(page)
    local c = page.watch
    local items = call(GF.Feed, "Recent", WATCH_ROWS)
    if type(items) ~= "table" then items = {} end
    local kinds = (GF.Feed and type(GF.Feed.KINDS) == "table") and GF.Feed.KINDS or {}
    local shown = 0
    for i = 1, WATCH_ROWS do
        local r, e = c.rows[i], items[i]
        if type(e) == "table" and type(e.text) == "string" then
            shown = shown + 1
            r.e = e
            local meta = kinds[e.kind] or {}
            r.art:SetKind(e.icon or meta.icon or "dot", meta.color)
            r.ago:SetText(U.Ago(e.t))
            -- separators only between reports, never under the last one shown
            local nxt = items[i + 1]
            r.line:SetShown(i < WATCH_ROWS and type(nxt) == "table" and type(nxt.text) == "string")
            r:Show()
        else
            r.e = nil
            r:Hide()
        end
    end
    page.watchShown = shown
    fitWatch(page)
    c.empty:SetShown(shown == 0)
    if shown == 0 then c.empty.text:SetText(emptyText("feed", "Quiet on the street tonight. Too quiet.")) end
end

-------------------------------------------------------------------------------
-- Who's home
-------------------------------------------------------------------------------
local function makePerson(parent)
    local p = CreateFrame("Button", nil, parent)
    p:SetHeight(PERSON_H)
    p.hl = p:CreateTexture(nil, "BACKGROUND")
    p.hl:SetAllPoints()
    p.hl:SetColorTexture(1, 0.90, 0.68, 0.055)
    p.hl:Hide()
    -- a green gem lights up for locals running Greenfields; the rest stay grey
    p.dot = p:CreateTexture(nil, "ARTWORK")
    p.dot:SetTexture(T.tex.gemGreen)
    p.dot:SetSize(10, 10)
    p.dot:SetPoint("LEFT", 4, 0)
    p.name = UI:Text(p, 12, "text", "ui")
    p.name:SetPoint("LEFT", p.dot, "RIGHT", 8, 0)
    -- zones hang off the cell's right edge, so the column has a clean line to read down
    p.zone = UI:Text(p, 11, "dim")
    p.zone:SetPoint("RIGHT", p, "RIGHT", -6, 0)
    p.zone:SetJustifyH("RIGHT")
    p:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    p:SetScript("OnEnter", function(self)
        self.hl:Show()
        local m = self.member
        if not m then return end
        local lines = {}
        local level = tonumber(m.level) or 0
        local class = m.class and API.ClassName(m.class) or ""
        lines[#lines + 1] = level > 0 and format("Level %d %s", level, class) or (class ~= "" and class or "Level unknown")
        if type(m.rankName) == "string" and m.rankName ~= "" then lines[#lines + 1] = { "Rank", m.rankName } end
        lines[#lines + 1] = { "Where", m.mobile and "On the app" or (m.zone or "Somewhere in Azeroth") }
        lines[#lines + 1] = self.addon and T:Wrap("green", "Running Greenfields") or T:Wrap("faint", "No Greenfields. Missing out.")
        lines[#lines + 1] = T:Wrap("faint", "Click: profile   Right-click: invite, whisper")
        UI:Tip(self, colored(self.key), lines)
    end)
    p:SetScript("OnLeave", function(self)
        self.hl:Hide()
        UI:HideTip()
    end)
    p:SetScript("OnClick", function(self, button)
        if not self.key then return end
        if button == "RightButton" then
            UI:HideTip()
            if UI.ResidentMenu and self.member then UI:ResidentMenu(self.member) else UI:Whisper(self.key) end
        elseif UI.OpenProfile then
            UI:OpenProfile(self.key)
        else
            UI:ShowPage("roster")
        end
    end)
    return p
end

local function buildPeople(page, parent)
    local c = UI:Card(parent, { title = "Who's home", icon = "home", subtitle = "" })
    c.go = headerLink(c, "Residents", function() UI:ShowPage("roster") end)
    UI:SetTextColor(c.subtitle, "dim")
    -- what the old head-count pills used to explain lives on the card's title now
    c.titleHit = CreateFrame("Frame", nil, c)
    c.titleHit:SetPoint("TOPLEFT", c.title, "TOPLEFT", 0, 0)
    c.titleHit:SetPoint("BOTTOMRIGHT", c.title, "BOTTOMRIGHT", 0, 0)
    c.titleHit:EnableMouse(true)
    UI.AttachTip(c.titleHit, function()
        return { "Who's home", {
            format("%d of %d locals online.", call(GF.Roster, "OnlineCount") or 0, call(GF.Roster, "Count") or 0),
            format("%d online with Greenfields going (you included).", peerCount()),
            T:Wrap("dim", "Everyone else is missing the gossip."),
        } }
    end)
    c.cells = {}
    for i = 1, PEOPLE_MAX do c.cells[i] = makePerson(c.body) end
    c.more = UI:Button(c.body, "", { style = "ghost", height = 20, size = 11, onClick = function() UI:ShowPage("roster") end })
    c.more:Hide()
    c.empty = cardEmpty(c.body, "roster")
    return c
end

local function peopleCols(bodyW) return bodyW >= 480 and 3 or 2 end

local function layoutPeople(page, bodyW)
    local c = page.people
    local cols = peopleCols(bodyW)
    local colW = floor((bodyW - (cols - 1) * 12) / cols)
    for i, p in ipairs(c.cells) do
        local col, row = (i - 1) % cols, floor((i - 1) / cols)
        p:ClearAllPoints()
        p:SetPoint("TOPLEFT", c.body, "TOPLEFT", col * (colW + 12), -row * PERSON_H)
        p:SetWidth(colW)
        p.cellW = colW
    end
    -- "+N more" sits right under the last row, not stranded at the card's foot
    local shown = min(page.peopleCount or 0, PEOPLE_MAX)
    c.more:ClearAllPoints()
    c.more:SetPoint("TOPLEFT", c.body, "TOPLEFT", 10, -(floor((shown + cols - 1) / cols) * PERSON_H + 2))
end

--- Fits name + zone into a cell: the name gets what it needs, the zone what's left.
local function sizePerson(p)
    local avail = (p.cellW or 150) - 28
    local fs = p.name
    -- a width set on an earlier render can clamp GetStringWidth; ask for the natural width
    local natural = fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth() or fs:GetStringWidth()
    local nameW = min((tonumber(natural) or 0) + 2, avail)
    p.name:SetWidth(max(1, nameW))
    local zoneW = avail - nameW - 6
    p.zone:SetWidth(max(1, zoneW))
    p.zone:SetShown(zoneW >= 30)
    -- "Stormwin..." reads worse than a city without the word City; the tooltip keeps the lot
    local zw = p.zone.GetUnboundedStringWidth and p.zone:GetUnboundedStringWidth() or p.zone:GetStringWidth()
    if (tonumber(zw) or 0) > zoneW then
        local shortZone = (p.zone:GetText() or ""):gsub(" City$", "")
        p.zone:SetText(shortZone)
    end
end

-- The last level and zone the client gave us, since a fight can hide them and that's no reason for the
-- list to reshuffle. Yours too. A level nobody's ever read just goes after the ones we know.
local NEAR_LEVELS = 5
local UNKNOWN_GAP = 1000
local lastKnown = {}

local function known(key, level, zone)
    local k = lastKnown[key]
    if not k then
        k = {}
        lastKnown[key] = k
    end
    level = tonumber(level) or 0
    if level > 0 then k.level = level end
    if zone then k.zone = zone end
    return k
end

--- Online guildies (not me), who you could play with first: near your level, then in your zone, then the
-- closest level. People on the app can't group, so they go last. Then Greenfields users, the highest
-- level and A-Z. It's all off the guild roster, so mates without the addon sort the same.
local function onlineLocals()
    local me = API.MyKey()
    local list = call(GF.Roster, "List", function(m) return m.online and m.key ~= me end, "name")
    if type(list) ~= "table" then list = {} end
    local row = call(GF.Roster, "Get", me)
    local mine = known(tostring(me), API.UnitLevel("player"), API.ZoneName() or (type(row) == "table" and row.zone or nil))
    local addon, gap, here, level = {}, {}, {}, {}
    for _, m in ipairs(list) do
        addon[m.key] = hasAddon(m.key)
        local k = known(m.key, m.level, m.zone)
        gap[m.key] = (k.level and mine.level) and abs(k.level - mine.level) or UNKNOWN_GAP
        here[m.key] = (k.zone ~= nil and k.zone == mine.zone) and true or false
        level[m.key] = k.level or 0
    end
    sort(list, function(a, b)
        local ka, kb = a.key, b.key
        if (a.mobile and true or false) ~= (b.mobile and true or false) then return b.mobile and true or false end
        local na, nb = gap[ka] <= NEAR_LEVELS, gap[kb] <= NEAR_LEVELS
        if na ~= nb then return na end
        if here[ka] ~= here[kb] then return here[ka] end
        if gap[ka] ~= gap[kb] then return gap[ka] < gap[kb] end
        if addon[ka] ~= addon[kb] then return addon[ka] end
        if level[ka] ~= level[kb] then return level[ka] > level[kb] end
        return tostring(ka) < tostring(kb)
    end)
    return list, addon
end

local function renderPeople(page)
    local c = page.people
    if not API.InGuild() then
        for _, p in ipairs(c.cells) do p:Hide() end
        c.more:Hide()
        page.peopleCount = 0
        c.subtitle:SetText("")
        c.empty:Show()
        c.empty.text:SetText(LINES.noGuild)
        return
    end
    local list, addon = onlineLocals()
    for i, p in ipairs(c.cells) do
        local m = list[i]
        if m then
            p.key, p.member, p.addon = m.key, m, addon[m.key]
            p.name:SetText(U.ClassName(m.key, m.class))
            p.zone:SetText(m.mobile and "On the app" or (m.zone or ""))
            p.dot:SetDesaturated(not p.addon)
            if p.addon then p.dot:SetVertexColor(1, 1, 1, 1) else p.dot:SetVertexColor(0.55, 0.55, 0.55, 0.8) end
            sizePerson(p)
            p:Show()
        else
            p.key, p.member = nil, nil
            p:Hide()
        end
    end
    local extra = #list - PEOPLE_MAX
    if extra > 0 then
        c.more:SetText("+" .. extra .. " more on the street")
        c.more:Show()
    else
        c.more:Hide()
    end
    page.peopleCount = #list
    -- "others": the header counts you too, and two numbers a digit apart read as a bug
    local others = #list .. U.Plural(#list, " other")
    if (page.peopleW or 0) >= 340 then
        others = others .. T:Wrap("faint", "  \194\183  ") .. peerCount() .. " on Greenfields"
    end
    c.subtitle:SetText(#list > 0 and others or "")
    c.empty:SetShown(#list == 0)
    if #list == 0 then c.empty.text:SetText(emptyText("roster", "No one's home. Suspicious.")) end
end

-------------------------------------------------------------------------------
-- Camp check
-------------------------------------------------------------------------------
local function campChip(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(18)
    -- flat: an icon and red words. It's the red that says something's missing, not a capsule
    f.art = kindIcon(f, 16)
    f.art:SetPoint("LEFT", 0, 0)
    f.label = UI:Text(f, 11, "red", "ui")
    f.label:SetPoint("LEFT", f.art, "RIGHT", 5, 0)
    f:EnableMouse(true)
    f:SetScript("OnEnter", function(self)
        local cat = self.cat
        if not cat then return end
        local lines = { cat.long or cat.label }
        local D = GF.BuffData
        local obj = cat.camp and D and D.campByKey and D.campByKey[cat.camp]
        if obj and obj.name then lines[#lines + 1] = T:Wrap("yellow", "Camp stand-in: " .. obj.name) end
        lines[#lines + 1] = T:Wrap("faint", "Nobody in the group brings this one.")
        UI:Tip(self, "Missing: " .. (cat.label or "?"), lines)
    end)
    f:SetScript("OnLeave", function() UI:HideTip() end)
    return f
end

local function buildCamp(page, parent)
    local c = UI:Card(parent, { title = "Camp check", icon = "campfire" })
    c.go = headerLink(c, "Buff Check", function() UI:ShowPage("buffs") end)

    c.report = CreateFrame("Frame", nil, c.body)
    c.report:SetAllPoints(c.body)
    -- the grade is a bare numeral: the number is the news, it doesn't need a plate
    c.score = UI:Text(c.report, 26, "green", "num")
    c.score:SetPoint("TOPLEFT", 0, 0)
    c.score:SetWidth(52)
    c.score:SetJustifyH("CENTER")
    c.scoreLabel = UI:Text(c.report, 11, "dim", "ui")
    c.scoreLabel:SetPoint("TOP", c.score, "BOTTOM", 0, -1)
    c.scoreLabel:SetJustifyH("CENTER")
    c.scoreLabel:SetText("score")
    c.summary = UI:Text(c.report, 12, "text")
    c.summary:SetPoint("TOPLEFT", 64, -2)
    c.summary:SetPoint("TOPRIGHT", c.report, "TOPRIGHT", 0, -2)
    c.chipRow = CreateFrame("Frame", nil, c.report)
    c.chipRow:SetHeight(18)
    c.chipRow:SetPoint("TOPLEFT", 64, -22)
    c.chipRow:SetPoint("TOPRIGHT", c.report, "TOPRIGHT", 0, -22)
    c.chips = {}
    c.overflow = UI:Text(c.chipRow, 11, "dim", "ui")

    c.tipFrame = CreateFrame("Frame", nil, c.body)
    c.tipFrame:SetAllPoints(c.body)
    c.tipIcon = UI:FramedIcon(c.tipFrame, 34, CAMP_ART)
    c.tipIcon:SetPoint("LEFT", 2, 0)
    c.tip = UI:Para(c.tipFrame, 12, "dim")
    c.tip:SetPoint("LEFT", c.tipIcon, "RIGHT", 14, 0)
    c.tip:SetPoint("RIGHT", c.tipFrame, "RIGHT", -4, 0)
    return c
end

local function layoutCampChips(page)
    local c = page.camp
    local avail = c.chipRow:GetWidth() or 0
    if avail < 40 then avail = 400 end
    -- missing buffs past the last chip count towards the "+N" too
    local x, hidden = 0, c.extraCats or 0
    for _, chip in ipairs(c.chips) do
        if chip.cat then
            chip:ClearAllPoints()
            if x + chip:GetWidth() <= avail - 30 then
                chip:SetPoint("LEFT", c.chipRow, "LEFT", x, 0)
                chip:Show()
                x = x + chip:GetWidth() + 12
            else
                chip:Hide()
                hidden = hidden + 1
            end
        else
            chip:Hide()
        end
    end
    c.overflow:ClearAllPoints()
    c.overflow:SetPoint("LEFT", c.chipRow, "LEFT", x, 0)
    c.overflow:SetText(hidden > 0 and ("+" .. hidden) or "")
end

--- The Buff Check report for my current group, or nil.
local function analyzeGroup()
    local B = GF.Buffs
    if not (B and type(B.Analyze) == "function") then return nil, 0 end
    local group = call(GF.Roster, "Group")
    if type(group) ~= "table" or not group[1] then group = API.GroupMembers() end
    local members = {}
    for _, g in ipairs(group) do
        if type(g) == "table" and type(g.key) == "string" then
            members[#members + 1] = { key = g.key, class = g.class, level = g.level }
        end
    end
    if not members[1] then return nil, 0 end
    local report = call(B, "Analyze", members)
    if type(report) ~= "table" then return nil, 0 end
    -- an empty report (nobody it could read) is "don't know", not "full house"
    if type(report.count) == "number" and report.count == 0 then return nil, 0 end
    return report, #members
end

--- Missing categories from a report, core buffs only when the data says which are core.
local function missingCats(report)
    local D = GF.BuffData
    local byKey = D and D.byKey or {}
    local core, all = {}, {}
    if type(report.missing) == "table" then
        for _, k in ipairs(report.missing) do
            local cat = byKey[k]
            if type(cat) == "table" then
                all[#all + 1] = cat
                if cat.core then core[#core + 1] = cat end
            end
        end
    end
    if core[1] then return core, true end
    return all, false
end

local function renderCamp(page)
    local c = page.camp
    local inGroup = API.InGroup()
    local report, size
    if inGroup then report, size = analyzeGroup() end
    if not report then
        c.report:Hide()
        c.tipFrame:Show()
        if inGroup and not (GF.Buffs and GF.Buffs.Analyze) then
            c.tip:SetText(LINES.buffsOff)
        else
            c.tip:SetText(emptyText("buffs", "Get in a group and this lights up.") .. "  "
                .. T:Wrap("faint", "Tip: " .. (page.campTip or CAMP_TIPS[1])))
        end
        return
    end
    c.tipFrame:Hide()
    c.report:Show()
    local ungraded = call(GF.Buffs, "Ungraded", report)
    if ungraded then
        -- a party still levelling gets a count, not a mark out of 100
        c.score:SetText(format("%d/%d", report.covered, report.applicable))
        UI:SetTextColor(c.score, "dim")
        c.scoreLabel:SetText("covered")
    else
        local score = floor(U.Clamp(tonumber(report.score) or 0, 0, 100) + 0.5)
        c.score:SetText(tostring(score))
        UI:SetTextColor(c.score, score >= 80 and "green" or (score >= 50 and "yellow" or "red"))
        c.scoreLabel:SetText("score")
    end
    local cats, isCore = missingCats(report)
    if ungraded and cats[1] then
        c.summary:SetText(format("%d of %d core buffs in hand across %d %s. Nobody's marking you till 60.",
            report.covered, report.applicable, size, U.Plural(size, "local")))
    elseif ungraded then
        c.summary:SetText(T:Wrap("green", "Sorted.") .. " Everything this lot can learn is covered. Pull whenever you like.")
    elseif not cats[1] then
        c.summary:SetText(T:Wrap("green", "Full house.") .. " Every core buff is covered across " .. size .. U.Plural(size, " local") .. ". Pull whenever you like.")
    else
        local what = isCore and U.Plural(#cats, "core buff") or U.Plural(#cats, "buff")
        c.summary:SetText(format("%d %s missing across %d %s. Get a fire going or get a %s.",
            #cats, what, size, U.Plural(size, "local"), #cats > 1 and "few tradies" or "tradie"))
    end
    for i = 1, min(#cats, CAMP_CHIPS) do
        local chip = c.chips[i] or campChip(c.chipRow)
        c.chips[i] = chip
        local cat = cats[i]
        chip.cat = cat
        chip.art:SetKind(type(cat.icon) == "number" and API.SpellIcon(cat.icon) or "warning", "red")
        chip.label:SetText(cat.label or "?")
        chip:SetWidth((chip.label:GetStringWidth() or 30) + 25)
    end
    for i = #cats + 1, #c.chips do c.chips[i].cat = nil end
    c.extraCats = max(0, #cats - CAMP_CHIPS)
    layoutCampChips(page)
end

-------------------------------------------------------------------------------
-- Page
-------------------------------------------------------------------------------
local function roll(page)
    page.greetLine = U.Pick(flavorList("greetings") or {}) or "G'day {name}. Welcome back to Greenfields."
    page.campTip = U.Pick(CAMP_TIPS)
    pageDef.subtitle = U.Pick(flavorList("taglines") or {}) or pageDef.subtitle
end

local function arrange(page, w)
    local content = page.content
    local y = 0
    place(page.hero, content, 0, y, w, GREET_H)
    y = y + GREET_H + 12
    local hasRaid = page.raid.ev ~= nil
    local raidH = hasRaid and RAID_H or RAID_EMPTY_H
    place(page.raid, content, 0, y, w, raidH)
    y = y + raidH + GUTTER

    local two = w >= TWO_COL_MIN
    local lw = two and floor((w - GUTTER) / 2) or w
    local rw = two and (w - lw - GUTTER) or w
    page.raidW = w - 24
    page.peopleW = rw - 24
    page.watchW = lw - 24
    -- the row is as tall as what's in it, so a quiet street doesn't leave a hollow card
    local cols = peopleCols(rw - 24)
    local count = page.peopleCount or 0
    local peopleRows = floor((min(count, PEOPLE_MAX) + cols - 1) / cols)
    local peopleH = peopleRows * PERSON_H + (count > PEOPLE_MAX and MORE_H or 0)
    local watchH = (page.watchShown or 0) * WATCH_ROW_H
    local rowH = max(ROW2_MIN, max(peopleH, watchH) + CARD_CHROME)
    if two then
        place(page.watch, content, 0, y, lw, rowH)
        place(page.people, content, lw + GUTTER, y, rw, rowH)
        y = y + rowH + GUTTER
    else
        for _, f in ipairs({ page.watch, page.people }) do
            place(f, content, 0, y, w, rowH)
            y = y + rowH + GUTTER
        end
    end

    local crownW = w - 24
    local crownRows = floor((#CROWNS + crownCols(crownW) - 1) / crownCols(crownW))
    local crownH = page.anyCrowns == false and CROWN_EMPTY_H
        or (CARD_CHROME + crownRows * TILE_H + (crownRows - 1) * TILE_GAP)
    place(page.crowns, content, 0, y, w, crownH)
    y = y + crownH + GUTTER
    place(page.camp, content, 0, y, w, CAMP_H)
    y = y + CAMP_H + 4
    page.scroll:SetContentHeight(y)
    fitWhen(page)
    fitWatch(page)
    layoutRaidCounts(page)
    layoutCrowns(page, crownW)
    layoutPeople(page, rw - 24)
    for _, p in ipairs(page.people.cells) do
        if p.key then sizePerson(p) end
    end
    fitStats(page)
    layoutCampChips(page)
end

--- Lays every card out for the current width. Never re-entered: setting the content
-- height below would otherwise bounce straight back in through OnSizeChanged.
local function layout(page)
    local w = floor(page.content:GetWidth() or 0)
    if w < 100 or page.laying then return end
    page.laying = true
    page.layoutW = w
    local ok, err = pcall(arrange, page, w)
    page.laying = false
    if not ok then error(err, 0) end
end

local function renderAll(page)
    -- a layout failure must not take the cards' contents down with it
    GF:Safe("home:layout", layout, page)
    GF:Safe("home:hero", renderHero, page)
    GF:Safe("home:raid", renderRaid, page)
    GF:Safe("home:crowns", renderCrowns, page)
    GF:Safe("home:watch", renderWatch, page)
    GF:Safe("home:people", renderPeople, page)
    GF:Safe("home:camp", renderCamp, page)
    -- card heights follow their contents, so lay out again now the contents are known
    GF:Safe("home:layout", layout, page)
end

local function stopTicker(page)
    if page.ticker then
        page.ticker:Cancel()
        page.ticker = nil
    end
end

--- One-second clock for the raid countdown; only runs while the page is on screen.
local function startTicker(page)
    if page.ticker then return end
    page.ticker = GF:Ticker(1, function()
        if not page:IsVisible() then
            stopTicker(page)
            return
        end
        tickRaid(page)
    end)
end

local function build(page)
    roll(page)
    local header = UI:PageHeader(page, pageDef.title, pageDef.subtitle)
    page.header = header

    -- the bar hangs in the gutter, so this page's right edge matches every other page's
    local scroll, content = UI:Scroll(page, { outside = true })
    scroll:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -14)
    scroll:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
    page.scroll, page.content = scroll, content

    page.hero = buildHero(page, content)
    page.raid = buildRaid(page, content)
    page.crowns = buildCrowns(page, content)
    page.watch = buildWatch(page, content)
    page.people = buildPeople(page, content)
    page.camp = buildCamp(page, content)

    -- only a new width needs a new layout (the height is ours: SetContentHeight sets it)
    content:SetScript("OnSizeChanged", function(_, w)
        w = floor(tonumber(w) or 0)
        if page.laying or w == page.layoutW then return end
        GF:Safe("home:layout", layout, page)
    end)
    page.shineCrowns = true
    page:HookScript("OnShow", function()
        page.shineCrowns = true
        startTicker(page)
    end)
    page:HookScript("OnHide", function()
        stopTicker(page)
        roll(page)
    end)
end

local function onShow(page)
    page.header:SetSubtitle(pageDef.subtitle)
    renderAll(page)
    startTicker(page)
end

pageDef = {
    key = PAGE, title = "The Street", subtitle = U.Pick(flavorList("taglines") or {}) or "She'll be right.",
    icon = "home", group = "street", order = 1,
    build = build, onShow = onShow,
}
UI:RegisterPage(pageDef)

-------------------------------------------------------------------------------
-- Keeping it fresh (coalesced; only redraws while the page is on screen)
-------------------------------------------------------------------------------
--- Runs fn once, `sec` after the first call of a burst. Unlike GF:Debounce (a new
-- C_Timer per call) a sync flurry of hundreds of store changes holds one live timer
-- (FOREVER_FACTS G18 caps live timers at about 50).
local pending = {}
local function soon(key, sec, fn)
    if pending[key] then return end
    pending[key] = true
    GF:After(sec, function()
        pending[key] = nil
        fn()
    end)
end

local function refreshSoon()
    -- off screen there's nothing to redraw: onShow renders everything fresh anyway
    local page = pageDef.frame
    if not (page and page:IsVisible()) then return end
    soon("refresh", 0.4, function() UI:RefreshPage(PAGE) end)
end

GF:On("GF_FEED", refreshSoon)
GF:On("GF_RAIDS_CHANGED", refreshSoon)
GF:On("GF_STATS_CHANGED", refreshSoon)
GF:On("GF_ROSTER_UPDATED", refreshSoon)
GF:On("GF_GROUP_UPDATED", refreshSoon)
GF:On("GF_PEER_SEEN", refreshSoon)
GF:On("GF_STORE_CHANGED", function(name)
    if name == "attendance" or name == "signups" or name == "events" then refreshSoon() end
end)

-- buff scans fire often in a raid: re-grade just the camp card, and only while it's on screen
GF:On("GF_BUFFS_UPDATED", function()
    local page = pageDef.frame
    if not (page and page:IsVisible()) then return end
    soon("camp", CAMP_SETTLE, function()
        if page:IsVisible() and page.camp then GF:Safe("home:camp", renderCamp, page) end
    end)
end)
