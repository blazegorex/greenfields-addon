--[[ Greenfields - Modules/Home.lua
     The Street: the dashboard everyone lands on when they open Greenfields.

     Hero row: the "Welcome to Greenfields" sign, a greeting with your name in it and pills
     for who's online, who runs Greenfields, your raid attendance and the crowns you wear.
     Under it a responsive grid of cards (two columns when there's room):
       Next raid               live countdown (ticks every second, only while on screen),
                               signup counts, your answer, Yeah / Maybe / Nah buttons
       Crowns on the street    six curated Hall of Fame titles and who wears them
       Latest from the Watch   the six newest Neighbourhood Watch reports
       Who's home              online guildies with their zones (click: profile)
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
local format, upper = string.format, string.upper
local sort, concat = table.sort, table.concat

-------------------------------------------------------------------------------
-- Layout constants
-------------------------------------------------------------------------------
local PAGE = "home"
local GUTTER = 16
local HERO_H = 150
local SIGN_W, SIGN_H = 256, 128           -- the welcome sign art is 512x256: keep it 2:1
local ROW1_H, ROW2_H, CAMP_H = 214, 238, 104
local TWO_COL_MIN = 600
local PILL_H = 22
local TILE_H, TILE_ROW_H = 44, 24         -- crown tiles: roomy two-column / compact one-column
local WATCH_ROWS, WATCH_ROW_H = 6, 30
local PEOPLE_MAX, PERSON_H = 12, 26
local CAMP_SETTLE = 2                     -- the camp card re-grades at most this often while buffs churn
local CAMP_CHIPS = 8
local RAID_ART_SIZE = 40
local WATCH_ICON = 20
local CAMP_ART = "Interface\\Icons\\Spell_Fire_Fire"   -- Basic Campfire

--- Quest-log art for the Next raid card (classic-era icon files). Raids may supply its own.
local RAID_ART = {
    ["Barrow Deeps"] = "Interface\\Icons\\INV_Misc_Bone_ElfSkull_01",
    ["Hyjal Summit"] = "Interface\\Icons\\Spell_Nature_Tranquility",
    ["Onyxia's Lair"] = "Interface\\Icons\\INV_Misc_Head_Dragon_01",
}
local RAID_ART_DEFAULT = "Interface\\Icons\\INV_Misc_Head_Dragon_Black"

-- dark ink for text written on parchment
local INK = { 0.20, 0.12, 0.04, 1 }
local INK_SOFT = { 0.36, 0.25, 0.12, 1 }
local INK_RED = { 0.58, 0.10, 0.04, 1 }
local INK_GREEN = { 0.04, 0.36, 0.14, 1 }

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
    no = { title = "Yeah nah, noted", text = "Out for %s. The bin chickens will miss you.", style = "red" },
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

--- Tiled chrome texture (stone / leather / parchment) filling `f`, inset by `inset`.
local function tiled(f, path, inset, layer, sub)
    local t = f:CreateTexture(nil, layer or "BACKGROUND", nil, sub or 1)
    t:SetPoint("TOPLEFT", inset or 0, -(inset or 0))
    t:SetPoint("BOTTOMRIGHT", -(inset or 0), inset or 0)
    t:SetTexture(path, "REPEAT", "REPEAT")
    t:SetHorizTile(true)
    t:SetVertTile(true)
    return t
end

--- A 9-sliced rim (T.tex.frameGold / frameBronze) drawn over `f`'s own regions.
local function rim(f, path, margin, sub)
    local t = f:CreateTexture(nil, "OVERLAY", nil, sub or 6)
    t:SetAllPoints()
    UI.Sliced(t, path, margin)
    return t
end

--- Line icons in a framed well take the kind's colour; dim kinds keep the frame's gold.
local function tintFramed(fi, color)
    if fi.icon.isGameIcon or not color or color == "dim" or color == "faint" then return end
    local c = UI.col(color)
    fi.icon:SetVertexColor(c[1], c[2], c[3], 1)
end

--- An empty state that stretches with its card (UI:Empty is fixed at 360 wide).
local function cardEmpty(parent, icon)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    f.icon = UI:Icon(f, 32, icon or "eye", "ARTWORK", { 1, 1, 1, 0.12 })
    f.icon:SetPoint("BOTTOM", f, "CENTER", 0, 6)
    f.text = UI:Text(f, 12, "faint")
    f.text:SetPoint("TOPLEFT", f, "LEFT", 12, -4)
    f.text:SetPoint("TOPRIGHT", f, "RIGHT", -12, -4)
    f.text:SetJustifyH("CENTER")
    f.text:SetWordWrap(true)
    f:Hide()
    return f
end

local function headerButton(card, text, onClick)
    local b = UI:Button(card, text, { style = "ghost", icon = "chevron_right", height = 22, size = 11, onClick = onClick })
    b:SetPoint("TOPRIGHT", card.right, "TOPRIGHT", 0, 0)
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
-- Hero
-------------------------------------------------------------------------------
--- A pill that lights up on hover, explains itself, and optionally goes somewhere.
local function heroPill(parent, color, icon, tip, onClick)
    local p = UI:Pill(parent, "", color, { icon = icon, height = PILL_H, size = 11 })
    p:EnableMouse(true)
    p:SetScript("OnEnter", function(self)
        local c = self.color or C.text
        self.bg:SetVertexColor(c[1], c[2], c[3], 0.30)
        local t = tip and tip(self)
        if type(t) == "table" then UI:Tip(self, t[1], t[2]) end
    end)
    p:SetScript("OnLeave", function(self)
        local c = self.color or C.text
        self.bg:SetVertexColor(c[1], c[2], c[3], 0.16)
        UI:HideTip()
    end)
    if onClick then
        p:SetScript("OnMouseUp", function(self, button)
            if button ~= "LeftButton" or not self:IsMouseOver() then return end
            if UI.Sound then UI.Sound(841) end
            GF:Safe("home:pill", onClick, self)
        end)
    end
    return p
end

--- A hero pill led by the title's art in a little gold frame (the crowns you wear).
local function titlePill(parent, tip, onClick)
    local p = heroPill(parent, "gold", nil, tip, onClick)
    p.art = UI:FramedIcon(p, PILL_H, "crown")
    p.art:SetPoint("LEFT", p, "LEFT", 0, 0)
    local setText = p.SetText
    function p:SetText(t, c)
        setText(self, t, c)
        self.label:ClearAllPoints()
        self.label:SetPoint("LEFT", self.art, "RIGHT", 6, 0)
        self:SetWidth(PILL_H + 6 + (self.label:GetStringWidth() or 0) + 10)
    end
    function p:SetArt(icon) self.art:SetIcon(icon or "crown") end
    p:SetText("", "gold")
    return p
end

local function titleColor(def) return (def and def.group == "fame") and "gold" or "pink" end

local function titleTip(def)
    if not def then return nil end
    return { def.title, { def.label or "", T:Wrap("dim", '"' .. (def.blurb or "") .. '"'), T:Wrap("faint", "Click for the leaderboard.") } }
end

--- Lays the pills out left to right; titles collapse into "+N" when the row runs out of room.
local function fitPills(page)
    local h = page.hero
    if not h then return end
    local avail = h.pills:GetWidth() or 0
    if avail < 40 then avail = 400 end
    local titles = page.titles or {}
    local n = #titles
    local base = { h.online, h.peers, h.att }
    if n > 0 then
        -- on a tight row your crowns beat the "N ON GREENFIELDS" head count
        h.more:SetText(upper(n .. U.Plural(n, " crown")), "gold")
        local need = h.more:GetWidth()
        for _, p in ipairs(base) do need = need + p:GetWidth() + 6 end
        if need > avail then
            base = { h.online, h.att }
            h.peers:Hide()
        end
    end
    local used = 0
    for _, p in ipairs(base) do used = used + p:GetWidth() + 6 end
    local shownTitles = 0
    if n == 0 then
        h.more:SetText("UNCROWNED", "faint")
    else
        for k = min(2, n), 0, -1 do
            local w = used
            for i = 1, k do
                local def = titles[i]
                h.titles[i]:SetArt(def.art)
                h.titles[i]:SetText(upper(def.title or "?"), titleColor(def))
                w = w + h.titles[i]:GetWidth() + 6
            end
            local rest = n - k
            if rest > 0 then
                h.more:SetText(k == 0 and upper(n .. U.Plural(n, " crown")) or ("+" .. rest), "gold")
                w = w + h.more:GetWidth() + 6
            end
            shownTitles = k
            if w - 6 <= avail then break end
        end
    end
    local order = {}
    for i, p in ipairs(base) do order[i] = p end
    for i = 1, 2 do
        if i <= shownTitles then order[#order + 1] = h.titles[i] else h.titles[i]:Hide() end
    end
    if n == 0 or n > shownTitles then order[#order + 1] = h.more else h.more:Hide() end
    local x = 0
    for _, p in ipairs(order) do
        p:ClearAllPoints()
        if x + p:GetWidth() <= avail + 1 then
            p:SetPoint("LEFT", h.pills, "LEFT", x, 0)
            p:Show()
            x = x + p:GetWidth() + 6
        else
            p:Hide()
        end
    end
end

local function buildHero(page, parent)
    -- a gold-framed slab of slate: the street's sign hung on a Stormwind wall
    local h = UI:Panel(parent, C.bg2, false)
    h.stone = tiled(h, T.tex.stone, 3, "BACKGROUND", 1)
    h.stone:SetVertexColor(0.55, 0.6, 0.57, 0.5)
    -- warm vignette from the right so the greeting reads off the stone
    h.shade = h:CreateTexture(nil, "BACKGROUND", nil, 2)
    h.shade:SetPoint("TOPLEFT", 3, -3)
    h.shade:SetPoint("BOTTOMRIGHT", -3, 3)
    h.shade:SetTexture(T.tex.white)
    if h.shade.SetGradient and CreateColor then
        h.shade:SetGradient("HORIZONTAL", CreateColor(0, 0, 0, 0), CreateColor(0, 0, 0, 0.35))
    else
        h.shade:SetColorTexture(0, 0, 0, 0.12)
    end
    -- streetlight glow behind the sign
    h.glow = h:CreateTexture(nil, "BACKGROUND", nil, 3)
    h.glow:SetTexture(T.tex.glow)
    h.glow:SetVertexColor(C.green[1], C.green[2], C.green[3], 0.18)
    h.glow:SetSize(380, HERO_H)
    h.glow:SetPoint("CENTER", h, "LEFT", 138, 0)
    h.rim = rim(h, T.tex.frameGold, 16)

    -- the sign sits centred (1px low); text and pills line up with its top and bottom.
    -- Corner pairs only: a bare RIGHT anchor would pin each block to the hero's centre line.
    local signGap = (HERO_H - SIGN_H) / 2 + 1
    h.sign = h:CreateTexture(nil, "ARTWORK")
    h.sign:SetTexture(T.tex.welcome)
    h.sign:SetSize(SIGN_W, SIGN_H)
    h.sign:SetPoint("LEFT", 10, -1)

    h.greet = UI:Text(h, 19, "wowGold", "ui")
    h.greet:SetPoint("TOPLEFT", h.sign, "TOPRIGHT", 16, -8)
    h.greet:SetPoint("TOPRIGHT", h, "TOPRIGHT", -18, -(signGap + 8))
    h.greet:SetWordWrap(true)
    h.greet:SetJustifyV("TOP")
    if h.greet.SetMaxLines then h.greet:SetMaxLines(2) end
    h.sub = UI:Text(h, 12, "dim")
    h.sub:SetPoint("TOPLEFT", h.greet, "BOTTOMLEFT", 0, -6)
    h.sub:SetPoint("TOPRIGHT", h.greet, "BOTTOMRIGHT", 0, -6)

    h.pills = CreateFrame("Frame", nil, h)
    h.pills:SetHeight(PILL_H)
    h.pills:SetPoint("BOTTOMLEFT", h.sign, "BOTTOMRIGHT", 16, 8)
    h.pills:SetPoint("BOTTOMRIGHT", h, "BOTTOMRIGHT", -18, HERO_H - signGap - SIGN_H + 8)

    h.online = heroPill(h.pills, "green", "dot", function()
        local total = call(GF.Roster, "Count") or 0
        return { "Who's home", { format("%d of %d locals online.", call(GF.Roster, "OnlineCount") or 0, total),
            T:Wrap("faint", "Click for the residents list.") } }
    end, function() UI:ShowPage("roster") end)

    h.peers = heroPill(h.pills, "blue", "sync", function()
        return { "Running Greenfields", { format("%d online with Greenfields going (you included).", peerCount()),
            T:Wrap("dim", "Everyone else is missing the gossip.") } }
    end)

    h.att = heroPill(h.pills, "gold", "check", function()
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
        h.titles[i] = titlePill(h.pills, function()
            return titleTip(page.titles and page.titles[i])
        end, function()
            local def = page.titles and page.titles[i]
            UI:ShowPage("fame", def and def.key or nil)
        end)
    end
    h.more = heroPill(h.pills, "gold", nil, function()
        local titles = page.titles or {}
        if #titles == 0 then return { "Uncrowned", { LINES.uncrowned } } end
        local lines = {}
        for _, def in ipairs(titles) do lines[#lines + 1] = T:Wrap(titleColor(def), def.title) .. T:Wrap("faint", "  " .. (def.label or "")) end
        return { "Your crowns", lines }
    end, function() UI:ShowPage("fame") end)

    h:SetScript("OnSizeChanged", function() fitPills(page) end)
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

    h.online:SetText((call(GF.Roster, "OnlineCount") or 0) .. " ONLINE", "green")
    h.peers:SetText(peerCount() .. " ON GREENFIELDS", "blue")
    local pct = tonumber(me and call(GF.Attendance, "Percent", me))
    if pct then
        pct = floor(U.Clamp(pct, 0, 100) + 0.5)
        h.att:SetText(pct .. "% ATTENDANCE", pct >= 75 and "green" or (pct >= 50 and "yellow" or "red"))
    else
        h.att:SetText("NO RAIDS ON FILE", "dim")
    end
    local titles = me and call(GF.Stats, "TitlesOf", me)
    page.titles = {}
    if type(titles) == "table" then
        for _, def in ipairs(titles) do
            if type(def) == "table" and type(def.title) == "string" then page.titles[#page.titles + 1] = def end
        end
    end
    fitPills(page)
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

--- The signup pills under the bar: full labels when they fit the card, bare counts when
-- it's narrow (the icons and the hover tips still say which is which).
local function layoutRaidPills(page)
    local c = page.raid
    local counts = c and c.counts
    if not counts then return end
    local avail = page.raidW or 0
    if avail < 40 then avail = 300 end
    local shown = {}
    for _, s in ipairs(COUNT_ORDER) do
        -- bench is an officer call; only worth showing once someone's on it
        if s == "bench" and (counts[s] or 0) == 0 then c.pills[s]:Hide() else shown[#shown + 1] = s end
    end
    local function label(compact)
        local w = 0
        for i, s in ipairs(shown) do
            local meta, n = T.status[s], counts[s] or 0
            c.pills[s]:SetText(compact and tostring(n) or (upper(meta.label) .. "  " .. n), meta.color)
            w = w + c.pills[s]:GetWidth() + (i > 1 and 6 or 0)
        end
        return w
    end
    if label(false) > avail then label(true) end
    local prev
    for _, s in ipairs(shown) do
        local p = c.pills[s]
        p:ClearAllPoints()
        if prev then p:SetPoint("LEFT", prev, "RIGHT", 6, 0) else p:SetPoint("TOPLEFT", c.content, "TOPLEFT", 0, -80) end
        p:Show()
        prev = p
    end
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
        UI:SetTextColor(c.cd, left < 3600 and INK_RED or INK)
    elseif state == "live" then
        c.cdLabel:SetText("RIGHT NOW")
        c.cd:SetText("LIVE")
        UI:SetTextColor(c.cd, INK_GREEN)
    else
        c.cdLabel:SetText("STATUS")
        c.cd:SetText("WRAPPED")
        UI:SetTextColor(c.cd, INK_SOFT)
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
        if c.accent then c.accent:SetColorTexture(C.green[1], C.green[2], C.green[3], 1) end
        c.empty.text:SetText(emptyText("events", "No raids planned. Go touch grass (it's dead, it's Greenfields)."))
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
    -- quest-log gold for the name; the instance's own colour marks the card's accent
    local accent = UI.col((info and info.color) or "green")
    if c.accent then c.accent:SetColorTexture(accent[1], accent[2], accent[3], 1) end
    local art = info and (info.art or info.icon)
    if type(art) ~= "string" and type(art) ~= "number" then art = RAID_ART[inst] or RAID_ART_DEFAULT end
    c.art:SetIcon(art)
    -- when first: on a narrow card the truncation eats the raid's nickname, not the date
    local bits = { U.DateTime(ev.time) }
    if tonumber(ev.size) then bits[#bits + 1] = tonumber(ev.size) .. "-man" end
    if title and title ~= headline then bits[#bits + 1] = title end
    c.when:SetText(concat(bits, "  \194\183  "))

    local counts = countsFor(ev.id)
    c.counts = counts
    local locked = counts.yes + counts.late
    local size = tonumber(ev.size) or 0
    c.fill:SetText(size > 0 and format("%d / %d LOCKED IN", locked, size) or format("%d LOCKED IN", locked))
    c.bar:SetValue(size > 0 and locked / size or 0)
    c.bar:SetColor((size > 0 and locked >= size) and "green" or "yellow")
    layoutRaidPills(page)

    local mine = call(GF.Raids, "MySignup", ev.id)
    local st = type(mine) == "table" and T.status[mine.status] and mine.status or nil
    if st then
        c.mine:SetText("Your answer: " .. T:Wrap(T.status[st].color, T.status[st].long))
    else
        c.mine:SetText(T:Wrap("yellow", "You haven't answered yet.") .. T:Wrap("dim", " The street is waiting."))
    end
    local over = call(GF.Raids, "IsOver", ev)
    for _, a in ipairs(ANSWERS) do
        local btn = c.answer[a.key]
        btn:SetStyle(st == a.key and a.style or "secondary")
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
    local c = UI:Card(parent, { title = "Next raid", icon = "calendar" })
    c.open = headerButton(c, "Open", function() UI:ShowPage("raids", c.ev and c.ev.id or nil) end)
    c.content = CreateFrame("Frame", nil, c.body)
    c.content:SetAllPoints(c.body)
    local f = c.content

    -- the countdown is a parchment notice pinned to the card, bronze-edged
    c.tag = CreateFrame("Frame", nil, f)
    c.tag:SetSize(84, 42)
    c.tag:SetPoint("TOPRIGHT", 0, 0)
    c.tag.paper = tiled(c.tag, T.tex.parchment, 2, "BACKGROUND", 1)
    c.tag.paper:SetVertexColor(0.95, 0.88, 0.72, 1)
    c.tag.rim = rim(c.tag, T.tex.frameBronze, 8)
    c.cdLabel = UI:Text(c.tag, 9, INK_SOFT, "head")
    c.cdLabel:SetPoint("TOP", 0, -6)
    c.cdLabel:SetJustifyH("CENTER")
    c.cd = UI:Text(c.tag, 18, INK, "num")
    c.cd:SetPoint("TOP", c.cdLabel, "BOTTOM", 0, -2)
    c.cd:SetJustifyH("CENTER")
    for _, fs in ipairs({ c.cdLabel, c.cd }) do
        -- ink doesn't cast a shadow
        if fs.SetShadowColor then fs:SetShadowColor(0, 0, 0, 0) end
    end

    -- quest-log heading: the raid's art in a gold frame, its name in Morpheus gold
    c.art = UI:FramedIcon(f, RAID_ART_SIZE, RAID_ART_DEFAULT)
    c.art:SetPoint("TOPLEFT", 0, 0)
    -- corner pairs only: TOPLEFT + RIGHT would pin each line's centre to the card's
    c.inst = UI:Text(f, 18, "wowGold", "title")
    c.inst:SetPoint("TOPLEFT", c.art, "TOPRIGHT", 10, 0)
    c.inst:SetPoint("TOPRIGHT", f, "TOPRIGHT", -92, 0)
    c.when = UI:Text(f, 11, "dim")
    c.when:SetPoint("TOPLEFT", c.inst, "BOTTOMLEFT", 0, -4)
    c.when:SetPoint("TOPRIGHT", c.inst, "BOTTOMRIGHT", 0, -4)

    c.rule = f:CreateTexture(nil, "ARTWORK")
    c.rule:SetTexture(T.tex.dividerGold)
    c.rule:SetHeight(10)
    c.rule:SetPoint("TOPLEFT", f, "TOPLEFT", -4, -RAID_ART_SIZE - 4)
    c.rule:SetPoint("TOPRIGHT", f, "TOPRIGHT", 4, -RAID_ART_SIZE - 4)
    c.rule:SetAlpha(0.8)

    -- "12 / 40 LOCKED IN" and its bar share one strip, so LEFT + RIGHT agree on the centre
    c.fillRow = CreateFrame("Frame", nil, f)
    c.fillRow:SetPoint("TOPLEFT", 0, -58)
    c.fillRow:SetPoint("TOPRIGHT", 0, -58)
    c.fillRow:SetHeight(14)
    c.fill = UI:Text(c.fillRow, 10, "dim", "head")
    c.fill:SetPoint("LEFT", c.fillRow, "LEFT", 0, 0)
    c.bar = UI:Bar(c.fillRow, { height = 6 })
    c.bar:SetPoint("LEFT", c.fill, "RIGHT", 10, 0)
    c.bar:SetPoint("RIGHT", c.fillRow, "RIGHT", 0, 0)

    c.pills = {}
    for _, s in ipairs(COUNT_ORDER) do
        local meta = T.status[s]
        c.pills[s] = UI:Pill(f, "", meta.color, { icon = meta.icon, height = 18, size = 10, tooltip = function()
            return { meta.long, { format("%d %s", c.counts and c.counts[s] or 0, U.Plural(c.counts and c.counts[s] or 0, "local")) } }
        end })
    end

    c.mine = UI:Text(f, 12, "text")
    c.mine:SetPoint("TOPLEFT", 0, -108)
    c.mine:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, -108)

    c.answer = {}
    local prev
    for _, a in ipairs(ANSWERS) do
        local btn = UI:Button(f, a.text, {
            icon = a.icon, height = 24, minWidth = 70, tooltip = T.status[a.key].long,
            onClick = function() answer(page, a.key) end,
        })
        if prev then btn:SetPoint("LEFT", prev, "RIGHT", 6, 0) else btn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0) end
        c.answer[a.key] = btn
        prev = btn
    end
    c.empty = cardEmpty(c.body, "calendar")
    return c
end

-------------------------------------------------------------------------------
-- Crowns on the street
-------------------------------------------------------------------------------
local TILE_BG, TILE_BG_HOVER = 0.30, 0.16      -- black well alpha (lighter on hover)

local function paintTile(t, hover)
    t.bg:SetVertexColor(0, 0, 0, hover and TILE_BG_HOVER or TILE_BG)
    t.edge:SetAlpha(hover and 1 or (t.mine and 0.9 or 0.55))
end

local function makeTile(parent)
    local t = CreateFrame("Button", nil, parent)
    t:SetHeight(TILE_H)
    -- a dark well with a bronze edge, like a slot in the achievement frame
    t.bg = t:CreateTexture(nil, "BACKGROUND")
    t.bg:SetPoint("TOPLEFT", 1, -1)
    t.bg:SetPoint("BOTTOMRIGHT", -1, 1)
    t.bg:SetTexture(T.tex.white)
    t.edge = t:CreateTexture(nil, "BORDER")
    t.edge:SetAllPoints()
    UI.Sliced(t.edge, T.tex.frameBronze, 8)
    t.art = UI:FramedIcon(t, 32, "crown")
    t.title = UI:Text(t, 11, "wowGold", "ui")
    t.name = UI:Text(t, 13, "text", "head")
    t.you = UI:Pill(t, "YOU", "green", { height = 14, size = 9 })
    t.you:SetPoint("BOTTOMRIGHT", -6, 6)
    t.you:Hide()

    function t:SetCompact(on)
        if self.compact == on then return end
        self.compact = on
        self.art:ClearAllPoints()
        self.title:ClearAllPoints()
        self.name:ClearAllPoints()
        -- Friz runs wide: the two-up tiles take the game's small size
        T:Font(self.title, "ui", on and 11 or 10)
        if on then
            self:SetHeight(TILE_ROW_H)
            self.art:SetSize(20, 20)
            self.art:SetPoint("LEFT", 2, 0)
            self.name:SetPoint("RIGHT", -8, 0)
            self.name:SetJustifyH("RIGHT")
            self.title:SetPoint("LEFT", self.art, "RIGHT", 8, 0)
            self.title:SetPoint("RIGHT", self.name, "LEFT", -8, 0)
        else
            -- title over name, both top-anchored by their corners (a bare RIGHT anchor
            -- would pin both lines to the tile's centre and stack them on each other)
            self:SetHeight(TILE_H)
            self.art:SetSize(32, 32)
            self.art:SetPoint("LEFT", 6, 0)
            self.title:SetPoint("TOPLEFT", self.art, "TOPRIGHT", 9, -2)
            self.title:SetPoint("TOPRIGHT", self, "TOPRIGHT", -8, -((TILE_H - 32) / 2 + 2))
            self.name:SetPoint("TOPLEFT", self.title, "BOTTOMLEFT", 0, -3)
            self.name:SetPoint("TOPRIGHT", self.title, "BOTTOMRIGHT", -34, -3)
            self.name:SetJustifyH("LEFT")
        end
    end

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
    t:SetCompact(false)
    paintTile(t, false)
    return t
end

local function buildCrowns(page, parent)
    local c = UI:Card(parent, { title = "Crowns on the street", icon = "crown", accent = "gold" })
    c.go = headerButton(c, "Hall of Fame", function() UI:ShowPage("fame") end)
    c.grid = CreateFrame("Frame", nil, c.body)
    c.grid:SetAllPoints(c.body)
    c.tiles = {}
    for i = 1, #CROWNS do c.tiles[i] = makeTile(c.grid) end
    c.empty = cardEmpty(c.body, "crown")
    return c
end

local function layoutCrowns(page, bodyW)
    local c = page.crowns
    local roomy = bodyW >= 340
    local cols = roomy and 2 or 1
    local gap = roomy and 8 or 3
    local tw = floor((bodyW - (cols - 1) * 8) / cols)
    for i, tile in ipairs(c.tiles) do
        tile:SetCompact(not roomy)
        local col, row = (i - 1) % cols, floor((i - 1) / cols)
        local th = roomy and TILE_H or TILE_ROW_H
        tile:ClearAllPoints()
        tile:SetPoint("TOPLEFT", c.grid, "TOPLEFT", col * (tw + 8), -row * (th + gap))
        tile:SetWidth(tw)
        if tile.compact then tile.you:Hide() end
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
            -- Hall of Fame gold for glory, pink for the shame board
            local accent = UI.col(def.group == "fame" and "wowGold" or "pink")
            tile.title:SetText(def.title)
            tile.title:SetTextColor(accent[1], accent[2], accent[3], 1)
            tile.art:SetIcon(def.art or def.icon or "crown")
            -- an unclaimed crown sits in its frame greyed out, waiting
            tile.art:SetDesaturated(key == nil)
            tile.art:SetAlpha(key and 1 or 0.6)
            if key then
                any = true
                tile.name:SetText(colored(key))
            else
                tile.name:SetText(T:Wrap("faint", "Up for grabs"))
            end
            tile.mine = key ~= nil and key == mine
            tile.you:SetShown(tile.mine and not tile.compact)
            paintTile(tile, tile:IsMouseOver())
            tile:Show()
            if tile.mine and page.shineCrowns then UI:Shine(tile, 0.9) end
        else
            tile.mine = false
            tile:Hide()
        end
    end
    page.shineCrowns = false
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
    r.hl:SetColorTexture(1, 1, 1, 0.04)
    r.hl:Hide()
    r.line = r:CreateTexture(nil, "ARTWORK")
    r.line:SetColorTexture(C.lineSoft[1], C.lineSoft[2], C.lineSoft[3], C.lineSoft[4])
    r.line:SetHeight(1)
    r.line:SetPoint("BOTTOMLEFT")
    r.line:SetPoint("BOTTOMRIGHT")
    r.art = UI:FramedIcon(r, WATCH_ICON, "dot")
    r.art:SetPoint("LEFT", 2, 0)
    r.ago = UI:Text(r, 10, "faint", "num")
    r.ago:SetPoint("RIGHT", -4, 0)
    r.ago:SetJustifyH("RIGHT")
    r.text = UI:Text(r, 12, "text")
    r.text:SetPoint("LEFT", r.art, "RIGHT", 9, 0)
    r.text:SetPoint("RIGHT", r.ago, "LEFT", -10, 0)
    trackLinkClicks(r)
    r:RegisterForClicks("LeftButtonUp")
    r:SetScript("OnEnter", function(self)
        self.hl:Show()
        local e = self.e
        if not e then return end
        local lines = {}
        if self.text.IsTruncated and self.text:IsTruncated() then lines[#lines + 1] = e.text end
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
    c.all = headerButton(c, "View all", function() UI:ShowPage("feed") end)
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
            r.art:SetIcon(e.icon or meta.icon or "dot")
            tintFramed(r.art, meta.color)
            r.text:SetText(e.text)
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
    UI.Sliced(p.hl, T.tex.round6, 6)
    p.hl:SetVertexColor(1, 1, 1, 0.05)
    p.hl:Hide()
    -- a green gem lights up for locals running Greenfields; the rest stay grey
    p.dot = p:CreateTexture(nil, "ARTWORK")
    p.dot:SetTexture(T.tex.gemGreen)
    p.dot:SetSize(10, 10)
    p.dot:SetPoint("LEFT", 4, 0)
    p.name = UI:Text(p, 12, "text", "head")
    p.name:SetPoint("LEFT", p.dot, "RIGHT", 8, 0)
    p.zone = UI:Text(p, 10, "faint")
    p.zone:SetPoint("LEFT", p.name, "RIGHT", 6, 0)
    p:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    p:SetScript("OnEnter", function(self)
        self.hl:Show()
        local m = self.member
        if not m then return end
        local lines = {}
        local level = tonumber(m.level) or 0
        lines[#lines + 1] = format("Level %d %s", level, m.class and API.ClassName(m.class) or "")
        if type(m.rankName) == "string" and m.rankName ~= "" then lines[#lines + 1] = { "Rank", m.rankName } end
        lines[#lines + 1] = { "Where", m.mobile and "On the app" or (m.zone or "Somewhere in Azeroth") }
        lines[#lines + 1] = self.addon and T:Wrap("green", "Running Greenfields") or T:Wrap("faint", "No Greenfields. Missing out.")
        lines[#lines + 1] = T:Wrap("faint", "Click: profile   Right-click: whisper")
        UI:Tip(self, colored(self.key), lines)
    end)
    p:SetScript("OnLeave", function(self)
        self.hl:Hide()
        UI:HideTip()
    end)
    p:SetScript("OnClick", function(self, button)
        if not self.key then return end
        if button == "RightButton" then
            UI:Whisper(self.key)
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
    c.go = headerButton(c, "Residents", function() UI:ShowPage("roster") end)
    c.cells = {}
    for i = 1, PEOPLE_MAX do c.cells[i] = makePerson(c.body) end
    c.more = UI:Button(c.body, "", { style = "ghost", height = 20, size = 11, onClick = function() UI:ShowPage("roster") end })
    c.more:SetPoint("BOTTOMLEFT", c.body, "BOTTOMLEFT", 0, 0)
    c.more:Hide()
    c.empty = cardEmpty(c.body, "roster")
    return c
end

local function layoutPeople(page, bodyW)
    local c = page.people
    local cols = bodyW >= 480 and 3 or 2
    local colW = floor((bodyW - (cols - 1) * 8) / cols)
    for i, p in ipairs(c.cells) do
        local col, row = (i - 1) % cols, floor((i - 1) / cols)
        p:ClearAllPoints()
        p:SetPoint("TOPLEFT", c.body, "TOPLEFT", col * (colW + 8), -row * PERSON_H)
        p:SetWidth(colW)
        p.cellW = colW
    end
end

--- Fits name + zone into a cell: the name gets what it needs, the zone what's left.
local function sizePerson(p)
    local avail = (p.cellW or 150) - 26
    local fs = p.name
    -- a width set on an earlier render can clamp GetStringWidth; ask for the natural width
    local natural = fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth() or fs:GetStringWidth()
    local nameW = min((tonumber(natural) or 0) + 2, avail)
    p.name:SetWidth(max(1, nameW))
    local zoneW = avail - nameW - 6
    p.zone:SetWidth(max(1, zoneW))
    p.zone:SetShown(zoneW >= 30)
end

--- Online guildies (not me): Greenfields users first, then the highest level, then A-Z.
local function onlineLocals()
    local me = API.MyKey()
    local list = call(GF.Roster, "List", function(m) return m.online and m.key ~= me end, "name")
    if type(list) ~= "table" then list = {} end
    local addon = {}
    for _, m in ipairs(list) do addon[m.key] = hasAddon(m.key) end
    sort(list, function(a, b)
        if addon[a.key] ~= addon[b.key] then return addon[a.key] end
        local la, lb = tonumber(a.level) or 0, tonumber(b.level) or 0
        if la ~= lb then return la > lb end
        return tostring(a.key) < tostring(b.key)
    end)
    return list, addon
end

local function renderPeople(page)
    local c = page.people
    if not API.InGuild() then
        for _, p in ipairs(c.cells) do p:Hide() end
        c.more:Hide()
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
    c.subtitle:SetText(#list > 0 and (#list .. " home") or "")
    c.empty:SetShown(#list == 0)
    if #list == 0 then c.empty.text:SetText(emptyText("roster", "No one's home. Suspicious.")) end
end

-------------------------------------------------------------------------------
-- Camp check
-------------------------------------------------------------------------------
local function campChip(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(20)
    -- the pill sits behind the label; the buff's icon rides on its left end in a gold frame
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetPoint("TOPLEFT", 10, -1)
    f.bg:SetPoint("BOTTOMRIGHT", 0, 1)
    UI.Sliced(f.bg, T.tex.pill, 8)
    f.bg:SetVertexColor(C.red[1], C.red[2], C.red[3], 0.16)
    f.art = UI:FramedIcon(f, 20, "warning")
    f.art:SetPoint("LEFT", 0, 0)
    f.icon = f.art.icon
    f.label = UI:Text(f, 10, "red", "head")
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
    local c = UI:Card(parent, { title = "Camp check", icon = "campfire", accent = "yellow" })
    c.go = headerButton(c, "Buff Check", function() UI:ShowPage("buffs") end)

    c.report = CreateFrame("Frame", nil, c.body)
    c.report:SetAllPoints(c.body)
    -- the grade sits on a little bronze-edged plate, like a slot on the achievement frame
    c.plate = CreateFrame("Frame", nil, c.report)
    c.plate:SetSize(56, 52)
    c.plate:SetPoint("TOPLEFT", 0, 2)
    c.plate.bg = c.plate:CreateTexture(nil, "BACKGROUND")
    c.plate.bg:SetPoint("TOPLEFT", 1, -1)
    c.plate.bg:SetPoint("BOTTOMRIGHT", -1, 1)
    c.plate.bg:SetColorTexture(0, 0, 0, 0.32)
    c.plate.rim = rim(c.plate, T.tex.frameBronze, 8)
    c.score = UI:Text(c.plate, 26, "green", "num")
    c.score:SetPoint("TOP", 0, -5)
    c.score:SetWidth(52)
    c.score:SetJustifyH("CENTER")
    c.scoreLabel = UI:Text(c.plate, 9, "bronze", "head")
    c.scoreLabel:SetPoint("BOTTOM", 0, 6)
    c.scoreLabel:SetJustifyH("CENTER")
    c.scoreLabel:SetText("SCORE")
    c.summary = UI:Text(c.report, 12, "text")
    c.summary:SetPoint("TOPLEFT", 70, -2)
    c.summary:SetPoint("TOPRIGHT", c.report, "TOPRIGHT", 0, -2)
    c.chipRow = CreateFrame("Frame", nil, c.report)
    c.chipRow:SetHeight(20)
    c.chipRow:SetPoint("TOPLEFT", 70, -24)
    c.chipRow:SetPoint("TOPRIGHT", c.report, "TOPRIGHT", 0, -24)
    c.chips = {}
    c.overflow = UI:Text(c.chipRow, 10, "faint", "head")

    c.tipFrame = CreateFrame("Frame", nil, c.body)
    c.tipFrame:SetAllPoints(c.body)
    c.tipIcon = UI:FramedIcon(c.tipFrame, 34, CAMP_ART)
    c.tipIcon:SetPoint("LEFT", 2, 0)
    c.tip = UI:Text(c.tipFrame, 12, "dim")
    c.tip:SetPoint("LEFT", c.tipIcon, "RIGHT", 14, 0)
    c.tip:SetPoint("RIGHT", c.tipFrame, "RIGHT", -4, 0)
    c.tip:SetWordWrap(true)
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
                x = x + chip:GetWidth() + 6
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
    local score = floor(U.Clamp(tonumber(report.score) or 0, 0, 100) + 0.5)
    c.score:SetText(tostring(score))
    UI:SetTextColor(c.score, score >= 80 and "green" or (score >= 50 and "yellow" or "red"))
    local cats, isCore = missingCats(report)
    if not cats[1] then
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
        chip.art:SetIcon(type(cat.icon) == "number" and API.SpellIcon(cat.icon) or "warning")
        tintFramed(chip.art, "red")
        chip.label:SetText(upper(cat.label or "?"))
        chip:SetWidth((chip.label:GetStringWidth() or 30) + 33)
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
    place(page.hero, content, 0, y, w, HERO_H)
    y = y + HERO_H + GUTTER
    local two = w >= TWO_COL_MIN
    local lw = two and floor((w - GUTTER) / 2) or w
    local rw = two and (w - lw - GUTTER) or w
    if two then
        place(page.raid, content, 0, y, lw, ROW1_H)
        place(page.crowns, content, lw + GUTTER, y, rw, ROW1_H)
        y = y + ROW1_H + GUTTER
        place(page.watch, content, 0, y, lw, ROW2_H)
        place(page.people, content, lw + GUTTER, y, rw, ROW2_H)
        y = y + ROW2_H + GUTTER
    else
        for _, spec in ipairs({ { page.raid, ROW1_H }, { page.crowns, ROW1_H }, { page.watch, ROW2_H }, { page.people, ROW2_H } }) do
            place(spec[1], content, 0, y, w, spec[2])
            y = y + spec[2] + GUTTER
        end
    end
    place(page.camp, content, 0, y, w, CAMP_H)
    y = y + CAMP_H + 4
    page.scroll:SetContentHeight(y)
    page.raidW = lw - 24
    layoutRaidPills(page)
    layoutCrowns(page, rw - 24)
    layoutPeople(page, rw - 24)
    for _, p in ipairs(page.people.cells) do
        if p.key then sizePerson(p) end
    end
    fitPills(page)
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
    header:AddAction(UI:IconButton(header, "sync", 26, "Refresh the street", function()
        call(GF.Roster, "Refresh")
        renderAll(page)
    end))

    local scroll, content = UI:Scroll(page)
    scroll:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -12)
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
