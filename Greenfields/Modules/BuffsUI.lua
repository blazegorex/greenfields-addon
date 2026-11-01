--[[ Greenfields - Modules/BuffsUI.lua
     The Buff Check page (Raid Nights). What's missing is the first thing you should see, so
     everything that's fine stays quiet. Top to bottom:
       Coverage     the nine core buffs as carved tiles. Covered ones are plain; a camp cover
                    says so in blue; a missing one lights up red and is the loudest thing on
                    the page. The buff score sits in the title row. A thin bar shows how many
                    have it right now (live scan, current group only). A buff that goes from
                    missing to covered on the same lineup gets the achievement shine.
       The lineup   up to 8 groups x 5 flat member rows: the class stripe, class, role, small
                    chips for what each person brings, the camp object they can drop and
                    red-edged chips for what they lack. Your own row gets a soft gold wash.
       Camp duty    campfire tier + cook, one row per person with the profession, ready / craft
                    kit / cooldown / acked, Ping per row, Ping all and Post plan
       Notes        the planner's tips for this comp (bottom lines up with the lineup)
       Class buffs  the buffs with no camp version (Shout, Trueshot, totems, Salvation...)
     An empty lineup drops the lot down to the tiles and one centred "what now".
     Presentation only: every verdict comes from GF.Buffs (Modules/Buffs.lua).
     Sources: the current group (auto-scanned every 10 s while open and out of combat), any
     upcoming raid with a lineup, or every online guildie as a "what if".
     UI:ShowPage("buffs", arg) takes "group", "online", "ev:<eventId>" or a bare event id.
     /gf buffs opens it. ]]

local _, GF = ...
local API, U, UI, T = GF.API, GF.Util, GF.UI, GF.Theme
local C = T.c
local D = GF.BuffData
local B = GF.Buffs
if not B then return end

local type, pairs, ipairs, tostring, tonumber = type, pairs, ipairs, tostring, tonumber
local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min
local concat = table.concat

local PAGE = "buffs"
local GAP = 16
local TILE_H, TILE_H_SMALL, TILE_GAP = 64, 46, 4
local TILE_ICON = 20
local TILE_MIN_W = 76          -- narrower than this and the tiles lose their names line
local TILE_MIN_SMALL = 58      -- and narrower than this they go three by three
local GROUP_MIN_W, GROUP_MAX_W, GROUP_GAP, GROUP_HEAD = 124, 240, 8, 20
local LONE_MIN_W = 200         -- a lone group's slots go side by side down to this width
local SLOT_H, SLOT_GAP = 38, 2
local SLOT_TEXT_X = 34
local CHIP, CHIP_GAP = 14, 2
local FIRE_H, FIRE_ICON, FIRE_TEXT_X = 54, 34, 53
local ROW_H = 38
local CLASS_ROW_H, CLASS_GAP = 38, 16
local MAX_GROUPS = 8
local SCAN_EVERY = 10
local DOT = "  \194\183  "
-- light enough to read on the red tile, where the theme's own red would go muddy
local RED_INK = { 1, 0.72, 0.68, 1 }

local STATUS = {
    class = { color = "green", label = "CLASS", long = "Covered by a class buff" },
    camp = { color = "blue", label = "CAMP", long = "Covered from the campfire (the weaker camp version)" },
    missing = { color = "red", label = "MISSING", long = "Nobody's bringing it" },
    na = { color = "faint", label = "N/A", long = "Nobody in this lineup needs it" },
}

local CLASS_TIPS = {
    lotp = "Raid-wide on Forever, crit only now. Feral talent.",
    battleshout = "Raid-wide on Forever, but it only lasts 3 minutes - shout right before the pull.",
    trueshot = "Raid-wide on Forever. Marksmanship talent.",
    grace = "Raid-wide on Forever and it stacks with Windfury now.",
    windfury = "Raid-wide on Forever (players only). Doesn't stack with Flametongue Totem.",
    manaspring = "Probably still party-only - park the shaman with the healers.",
    bloodpact = "The Imp's party buff. Ask the warlock to keep the Imp out.",
    salvation = "Not a blessing any more, so it sits on top of the blessings.",
    light = "Needs a spare paladin - each paladin gives each class one Greater Blessing.",
    shadowprot = "Short buff (10-20 min), so hand it out right before the pull.",
    aura = "Devotion, Retribution, Concentration or a resistance aura.",
    wildres = "Covers the whole raid now.",
}

local state = { source = nil, picked = false }
local page
local events = {}
local refresh, layout

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------
local function col(c) return UI.col(c) end
local function now() return API.ServerTime() end
local function isMe(key) return key ~= nil and key == API.MyKey() end
--- The "online guildies" view is a what-if: nobody in it signed up for camp duty.
local function whatIf() return page ~= nil and page.view ~= nil and page.view.kind == "online" end

local function classOf(key, fallback)
    local rep = page and page.rep
    local p = rep and rep.people and rep.people[key]
    return (p and p.class) or fallback or GF.Roster:Class(key)
end

--- Shaman blue is the one class colour that's hard to read on midnight: lift it for text only
-- (the stripe keeps the true colour).
local function classText(key, class)
    return U.ClassName(key, class)
end

local function nameOf(key, fallback) return classText(key, classOf(key, fallback)) end

local function namesOf(keys, cap)
    local out = {}
    keys = keys or {}
    for i, k in ipairs(keys) do
        if cap and i > cap then
            out[#out + 1] = T:Wrap("faint", "+" .. (#keys - cap))
            break
        end
        out[#out + 1] = nameOf(k)
    end
    return concat(out, ", ")
end

local function labels(catKeys)
    local out = {}
    for _, k in ipairs(catKeys or {}) do out[#out + 1] = B.SHORT[k] or (D.byKey[k] and D.byKey[k].label) or k end
    return concat(out, ", ")
end

local function ago(ts)
    if not ts then return "never" end
    local d = max(0, now() - ts)
    if d < 5 then return "just now" end
    if d < 60 then return floor(d) .. "s ago" end
    return U.Ago(ts)
end

local function profOf(obj)
    return obj and D.professions[obj.prof] or nil
end

local function emptyText(view)
    local E = GF.Flavor and GF.Flavor.emptyStates or {}
    if view.kind == "group" then
        -- grouped but nobody readable: the client is hiding the roster (combat, encounter)
        if API.InGroup() then
            return "The game's keeping the group roster under its hat right now. It'll fill in once things settle down."
        end
        return E.buffs or "Get in a group and this lights up."
    end
    if view.kind == "online" then return E.roster or "No one's home. Suspicious." end
    return "Nobody's in this lineup yet. Sort the groups on the Raids page and come back."
end

-------------------------------------------------------------------------------
-- Sources: current group, an upcoming lineup, or everyone online
-------------------------------------------------------------------------------
local function loadEvents()
    events = {}
    local R = GF.Raids
    if not (R and type(R.Upcoming) == "function" and type(R.Lineup) == "function") then return end
    local ok, list = GF:Safe("buffs:upcoming", R.Upcoming, R, 8)
    if not ok or type(list) ~= "table" then return end
    for _, ev in ipairs(list) do
        if type(ev) == "table" and type(ev.id) == "string" then
            local ok2, lu = GF:Safe("buffs:lineup", R.Lineup, R, ev.id)
            if ok2 and type(lu) == "table" and type(lu.groups) == "table" then
                local n = 0
                for g = 1, MAX_GROUPS do
                    if type(lu.groups[g]) == "table" then n = n + #lu.groups[g] end
                end
                if n > 0 then events[#events + 1] = { ev = ev, lineup = lu, n = n } end
            end
        end
    end
end

local function eventItem(value)
    for _, it in ipairs(events) do
        if "ev:" .. it.ev.id == value then return it end
    end
    return nil
end

local function eventTitle(ev)
    return API.CleanString(ev.title) or API.CleanString(ev.instance) or "Raid"
end

local function sourceItems()
    local items = { { value = "group", text = "Current group", icon = "roster" } }
    for _, it in ipairs(events) do
        items[#items + 1] = { value = "ev:" .. it.ev.id, text = eventTitle(it.ev) .. DOT .. U.DateShort(it.ev.time), icon = "calendar" }
    end
    items[#items + 1] = { value = "online", text = "Online guildies (what if)", icon = "eye" }
    return items
end

local function resolveSource()
    local s = state.source
    local valid = s == "group" or s == "online" or (s ~= nil and eventItem(s) ~= nil)
    if not valid then state.picked = false end
    if not state.picked then
        if API.InGroup() then
            s = "group"
        elseif events[1] then
            s = "ev:" .. events[1].ev.id
        else
            s = "online"
        end
        state.source = s
    end
    return state.source
end

local function signupsByChar(evId)
    local out = {}
    local R = GF.Raids
    if not (evId and R and type(R.SignupsFor) == "function") then return out end
    local ok, list = GF:Safe("buffs:signups", R.SignupsFor, R, evId)
    if ok and type(list) == "table" then
        for _, s in ipairs(list) do
            if type(s) == "table" then
                local k = API.CleanString(s.char) or API.CleanString(s.player)
                if k then out[k] = s end
            end
        end
    end
    return out
end

local function currentEventId()
    local R = GF.Raids
    if not (R and type(R.Current) == "function") then return nil end
    local ok, ev = GF:Safe("buffs:current", R.Current, R)
    return (ok and type(ev) == "table" and type(ev.id) == "string") and ev.id or nil
end

local function collectGroup()
    local view = { kind = "group", label = "Current group", members = {}, at = now(), hidden = 0 }
    if not API.InGroup() then return view end
    local signed = signupsByChar(currentEventId())
    for _, m in ipairs(B:GroupInput()) do
        local s = signed[m.key]
        local g = tonumber(m.group) or 1
        if g < 1 or g > MAX_GROUPS then g = 1 end
        view.members[#view.members + 1] = {
            key = m.key, class = m.class or (s and s.class), level = m.level, group = g,
            role = (s and s.role) or (m.role == "MAINTANK" and "tank" or nil), online = m.online,
        }
    end
    return view
end

local function collectEvent(it)
    local ev, lu = it.ev, it.lineup
    local view = { kind = "event", label = eventTitle(ev) .. DOT .. U.DateTime(ev.time), members = {},
                   at = tonumber(ev.time) or now(), hidden = 0, ev = ev }
    local signed = signupsByChar(ev.id)
    for g = 1, MAX_GROUPS do
        local keys = lu.groups[g]
        if type(keys) == "table" then
            for _, k in ipairs(keys) do
                k = API.CleanString(k)
                if k then
                    local s = signed[k]
                    view.members[#view.members + 1] = {
                        key = k, class = GF.Roster:Class(k) or (s and s.class), level = GF.Roster:Level(k),
                        group = g, role = s and s.role, online = GF.Roster:IsOnline(k),
                    }
                end
            end
        end
    end
    return view
end

local function collectOnline()
    local view = { kind = "online", label = "What if everyone online turned up", members = {}, at = now(), hidden = 0 }
    local me = API.MyKey()
    local seenMe = false
    for _, m in ipairs(GF.Roster:List(function(x) return x.online end, "level")) do
        if m.key then
            view.members[#view.members + 1] = { key = m.key, class = m.class, level = m.level, online = true }
            if m.key == me then seenMe = true end
        end
    end
    if me and not seenMe then
        view.members[#view.members + 1] = { key = me, class = API.UnitClassFile("player"), level = API.UnitLevel("player"), online = true }
    end
    -- class clusters read nicely in a hypothetical raid
    table.sort(view.members, function(a, b)
        if (a.class or "") ~= (b.class or "") then return (a.class or "") < (b.class or "") end
        return a.key < b.key
    end)
    for i, m in ipairs(view.members) do m.group = floor((i - 1) / 5) + 1 end
    view.hidden = max(0, #view.members - MAX_GROUPS * 5)
    return view
end

local function collect()
    local s = resolveSource()
    if s == "online" then return collectOnline() end
    local it = s ~= "group" and eventItem(s)
    if it then return collectEvent(it) end
    return collectGroup()
end

local function bucket(view)
    local groups = {}
    for _, m in ipairs(view.members) do
        local g = m.group or 1
        if g >= 1 and g <= MAX_GROUPS then
            local t = groups[g] or {}
            if #t < 5 then
                t[#t + 1] = m
                groups[g] = t
            end
        end
    end
    local out = {}
    for g = 1, MAX_GROUPS do
        if groups[g] then out[#out + 1] = { index = g, members = groups[g] } end
    end
    return out
end

--- Who is actively covering what in the plan (bright chips) vs merely able to (dim chips).
local function activeMap(rep)
    local out = {}
    for catKey, e in pairs(rep.cats or {}) do
        if e.status == "class" then
            for _, k in ipairs(e.providers or {}) do
                out[k] = out[k] or {}
                out[k][catKey] = true
            end
        end
    end
    return out
end

--- Live scan totals for this view (current group only: nobody else was scanned).
local function liveStats(view, rep)
    local st = { cats = {}, missing = {}, scanned = 0 }
    if view.kind ~= "group" then return st end
    for _, m in ipairs(view.members) do
        local lv = B:LiveFor(m.key)
        if lv and lv.scanned then
            st.scanned = st.scanned + 1
            st.missing[m.key] = B:MissingFor(m.key, rep) or {}
            local person = rep.people and rep.people[m.key]
            local class = (person and person.class) or m.class
            for _, cat in ipairs(D.categories) do
                if B.Benefits(cat, class) then
                    local c = st.cats[cat.key]
                    if not c then
                        c = { have = 0, seen = 0 }
                        st.cats[cat.key] = c
                    end
                    c.seen = c.seen + 1
                    if B:HasBuff(lv, cat.key, rep) then c.have = c.have + 1 end
                end
            end
        end
    end
    return st
end

-------------------------------------------------------------------------------
-- Coverage tiles
-------------------------------------------------------------------------------
local function tileWho(e, cap)
    if e and e.tooLow then return T:Wrap("faint", "not yet") end
    if not e or e.status == "na" then return T:Wrap("faint", "not needed") end
    if e.status == "class" then return namesOf(e.providers, cap) end
    if e.status == "camp" then return nameOf(e.assigned) end
    if e.cooldown then return T:Wrap("dim", "on cooldown") end
    if e.maybe and e.maybe[1] then
        -- "maybe " would eat a narrow tile: the question mark says the same and the tooltip spells it out
        if cap == 1 then return nameOf(e.maybe[1]) .. T:Wrap("yellow", "?") end
        return T:Wrap("yellow", "maybe ") .. nameOf(e.maybe[1])
    end
    -- the whole phrase cuts off in a narrow tile; the tooltip has the rest
    if e.blocked then return T:Wrap("dim", cap == 1 and "no spare" or "nobody spare") end
    return T:Wrap("dim", "nobody")
end

local function tileTip(t)
    local cat, e = t.cat, t.entry
    if not cat then return end
    local st = STATUS[t.status] or STATUS.na
    local obj = cat.camp and D.campByKey[cat.camp]
    local lines = { T:Wrap(st.color, (e and e.tooLow) and "Nobody here's old enough to learn it yet" or st.long) }
    if e then
        if e.status == "class" then
            lines[#lines + 1] = { "From", namesOf(e.providers, 4) }
            -- in a live group, an offline provider buffs nobody
            local off = {}
            local people = page.rep.people or {}
            for _, k in ipairs(e.providers or {}) do
                if page.view.kind == "group" and people[k] and people[k].online == false then off[#off + 1] = k end
            end
            if off[1] then lines[#lines + 1] = T:Wrap("yellow", "Offline right now: ") .. namesOf(off, 3) end
        elseif e.status == "camp" and obj then
            lines[#lines + 1] = { "Camp", obj.name .. " from " .. nameOf(e.assigned) }
        elseif e.status == "missing" then
            if e.cooldown and obj then
                lines[#lines + 1] = { "Camp", obj.name .. " - " .. nameOf(e.assigned) .. " back in " .. U.Duration(max(0, e.cooldown - now())) }
            elseif e.blocked and obj then
                lines[#lines + 1] = "Everyone who can drop a " .. obj.name .. " is already on camp duty."
            elseif obj then
                lines[#lines + 1] = "Nobody here can drop a " .. obj.name .. "."
            end
            if e.maybe and e.maybe[1] then lines[#lines + 1] = { "Maybe", namesOf(e.maybe, 3) .. " (talent)" } end
        end
        if e.need and e.need > 0 then lines[#lines + 1] = { "Who needs it", e.need .. " (" .. (B.WHO[cat.who] or "everyone") .. ")" } end
        if e.status ~= "class" and e.capable and e.capable[1] and cat.blessing then
            lines[#lines + 1] = { "Could cast it", namesOf(e.capable, 3) }
        end
    end
    if t.lc and t.lc.seen > 0 then lines[#lines + 1] = { "Has it now", t.lc.have .. " of " .. t.lc.seen } end
    if obj then
        local prof = profOf(obj)
        lines[#lines + 1] = { "Camp version", obj.name .. (prof and (" (" .. prof.name .. ")") or "") }
        if obj.note then lines[#lines + 1] = T:Wrap("faint", obj.note .. ".") end
        lines[#lines + 1] = T:Wrap("faint", "The camp version is weaker and doesn't stack with " .. cat.long .. ".")
    end
    UI:Tip(t, cat.long, lines)
end

--- Column i of perRow across total: whole units, the remainder shared out so the right edge lands true.
local function spread(i, perRow, total, gap)
    local unit = (total + gap) / perRow
    local x = floor((i - 1) * unit + 0.5)
    return x, floor(i * unit + 0.5) - x - gap
end

local function makeTile(parent, cat)
    local t = CreateFrame("Button", nil, parent)
    t.cat = cat
    t:SetHeight(TILE_H)
    t:SetClipsChildren(true)   -- the shine stays on the tile
    -- a plain carved well: only a missing buff brings colour, so one tile pops out of nine
    t.well = UI:Nine(t, "inset", "BACKGROUND", -6)
    t.alarm = UI:Nine(t, "tag", "BACKGROUND", -4)
    t.alarm:SetVertexColor(C.red[1], C.red[2], C.red[3], 1)
    t.alarm:Hide()
    t.hl = t:CreateTexture(nil, "HIGHLIGHT")
    t.hl:SetAllPoints()
    t.hl:SetColorTexture(1, 0.9, 0.6, 0.06)
    t.art = UI:IconChip(t, TILE_ICON, API.SpellIcon(cat.icon))
    t.icon = t.art.icon
    t.label = UI:Text(t, 11, "text", "ui")
    t.label:SetText(B.SHORT[cat.key] or cat.label)
    t.stat = UI:Text(t, 10, "faint", "head")
    t.who = UI:Text(t, 11, "dim")
    t.liveBar = UI:Bar(t, { height = 4, color = "green" })
    t.liveBar:SetPoint("BOTTOMLEFT", 6, 4)
    t.liveBar:SetPoint("BOTTOMRIGHT", -6, 4)
    t.liveBar:Hide()
    t:SetScript("OnEnter", function(self) GF:Safe("buffs:tile", tileTip, self) end)
    t:SetScript("OnLeave", function() UI:HideTip() end)
    return t
end

--- Roomy tiles sit the icon beside the name, with who's covering it underneath. Small ones stack
-- icon over name and leave the who to the tooltip. A status word only shows when it's news.
local function placeTile(t, tw, small, hasWord)
    t.art:ClearAllPoints()
    t.label:ClearAllPoints()
    t.stat:ClearAllPoints()
    t.who:ClearAllPoints()
    if small then
        t.art:SetPoint("TOP", 0, -6)
        t.label:SetPoint("TOP", t.art, "BOTTOM", 0, -3)
        t.label:SetWidth(max(10, tw - 4))
        t.label:SetJustifyH("CENTER")
        t.stat:Hide()
        t.who:Hide()
        return
    end
    t.art:SetPoint("TOPLEFT", 5, -7)
    t.label:SetWidth(max(10, tw - TILE_ICON - 11))
    t.label:SetJustifyH("LEFT")
    if hasWord then
        t.label:SetPoint("TOPLEFT", t.art, "TOPRIGHT", 4, 1)
        t.stat:SetPoint("TOPLEFT", t.label, "BOTTOMLEFT", 0, -1)
        t.stat:Show()
    else
        t.label:SetPoint("LEFT", t.art, "RIGHT", 4, 0)
        t.stat:Hide()
    end
    t.who:SetPoint("BOTTOMLEFT", 6, 11)
    t.who:SetPoint("BOTTOMRIGHT", -4, 11)
    t.who:Show()
end

local function paintTile(t, e, lc, celebrate, tw, small)
    local status = (e and STATUS[e.status]) and e.status or "na"
    local st = STATUS[status]
    -- a buff that was missing on this lineup and is covered now gets the achievement sweep
    if celebrate and t.status == "missing" and (status == "class" or status == "camp") then UI:Shine(t) end
    t.status, t.entry, t.lc = status, e, lc
    local na, missing = status == "na", status == "missing"
    t.alarm:SetShown(missing)
    t.well:SetShown(not missing)
    t.well:SetAlpha(na and 0.6 or 1)
    if missing then
        t.art.edge:SetColorTexture(C.red[1], C.red[2], C.red[3], 1)
    else
        t.art.edge:SetColorTexture(0, 0, 0, 0.85)
    end
    t.art:SetDesaturated(na)
    t.art:SetAlpha(na and 0.45 or (missing and 1 or 0.85))
    UI:SetTextColor(t.label, missing and "text" or (na and "faint" or "dim"))
    local word = status == "missing" or status == "camp"
    placeTile(t, tw, small, word)
    if word then
        t.stat:SetText(st.label)
        UI:SetTextColor(t.stat, missing and RED_INK or st.color)
    end
    -- a tile under 100 wide holds one name and a "+1"; the tooltip has the lot
    t.who:SetText(tileWho(e, tw >= 100 and 2 or 1))
    if lc and lc.seen > 0 then
        t.liveBar:Show()
        t.liveBar:SetColor(lc.have >= lc.seen and "green" or "yellow")
        t.liveBar:SetValue(lc.have / lc.seen)
    else
        t.liveBar:Hide()
    end
end

--- Lays out and paints the tiles; returns the coverage card's height.
local function paintTiles(bw, people)
    local p = page
    local n = #p.tiles
    local perRow = n
    local tw = (bw - (n - 1) * TILE_GAP) / n
    -- never a 5 + 4 wrap with a hole in it: shrink the tiles first, then go three by three.
    -- With nobody in the lineup there's nothing to say underneath them either.
    local small = tw < TILE_MIN_W or not people
    if tw < TILE_MIN_SMALL then perRow = 3 end
    local h = small and TILE_H_SMALL or TILE_H
    -- only a change on the same lineup is worth celebrating (not flipping the source)
    local celebrate = p.tilesFor ~= nil and p.tilesFor == state.source
    for i, t in ipairs(p.tiles) do
        local cx, cy = (i - 1) % perRow, floor((i - 1) / perRow)
        local x, w = spread(cx + 1, perRow, bw, TILE_GAP)
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", p.cov.body, "TOPLEFT", x, -cy * (h + TILE_GAP))
        t:SetSize(w, h)
        paintTile(t, p.rep.cats[t.cat.key], p.live.cats[t.cat.key], celebrate, w, small)
    end
    p.tilesFor = state.source
    local view = p.view
    local sub = view.label or ""
    if view.members[1] then sub = sub .. DOT .. #view.members .. " " .. U.Plural(#view.members, "person", "people") end
    p.cov.subtitle:SetText(sub)
    local rows = ceil(n / perRow)
    return 38 + rows * h + (rows - 1) * TILE_GAP + 10
end

-------------------------------------------------------------------------------
-- The lineup grid
-------------------------------------------------------------------------------
local function slotTip(s)
    local m = s.member
    if not m or not page or not page.rep then return end
    local person = page.rep.people[m.key] or {}
    local class = person.class or m.class
    local lines = {
        { "Level " .. tostring(person.level or "?") .. " " .. (class and API.ClassName(class) or "unknown class"),
          person.addon and T:Wrap("green", "Greenfields") or T:Wrap("faint", "No addon") },
    }
    if person.guessed then lines[#lines + 1] = T:Wrap("faint", "No profile shared, so this is a guess from class and level.") end
    if person.provides and person.provides[1] then lines[#lines + 1] = { "Brings", labels(person.provides) } end
    if person.maybe and person.maybe[1] then lines[#lines + 1] = { "Maybe", labels(person.maybe) .. " (talent)" } end
    local obj = person.campObj and D.campByKey[person.campObj]
    if obj then
        local kits = person.campKits or 0
        lines[#lines + 1] = { "Camp", obj.name .. (kits > 0 and (" - " .. kits .. " in bags") or " - knows the recipe") }
        if person.campReady == false then
            lines[#lines + 1] = { "Camp cooldown", U.Duration(max(0, (person.campReadyAt or 0) - now())) }
        end
    end
    if person.cook and person.cooking and person.cooking > 0 then lines[#lines + 1] = { "Cooking", tostring(person.cooking) } end
    if person.duty then lines[#lines + 1] = T:Wrap("gold", "On duty: ") .. person.duty end
    local miss = page.live.missing[m.key]
    if miss and miss[1] then lines[#lines + 1] = { "Missing now", T:Wrap("red", labels(miss)) } end
    local lv = B:LiveFor(m.key)
    if lv and lv.cb then lines[#lines + 1] = T:Wrap("blue", "Sitting on Camp Benefits.") end
    if lv and lv.skipped then lines[#lines + 1] = T:Wrap("faint", "Too far away or offline to read their buffs.") end
    lines[#lines + 1] = " "
    lines[#lines + 1] = T:Wrap("faint", isMe(m.key) and "Click for your profile." or "Click for their profile. Right-click to whisper.")
    UI:Tip(s, classText(m.key, class), lines)
end

local function slotClick(s, button)
    local m = s.member
    if not m then return end
    if button == "RightButton" then
        if not isMe(m.key) then UI:Whisper(m.key) end
        return
    end
    if UI.OpenProfile then GF:Safe("buffs:profile", UI.OpenProfile, UI, m.key) end
end

local function makeSlot(parent)
    local s = CreateFrame("Button", nil, parent)
    s:SetHeight(SLOT_H)
    -- a flat row: the class stripe is the only chrome, because it's the only part that says something
    s.bg = s:CreateTexture(nil, "BACKGROUND")
    s.bg:SetAllPoints()
    s.me = s:CreateTexture(nil, "BACKGROUND", nil, 1)
    s.me:SetAllPoints()
    UI:Gradient(s.me, "HORIZONTAL", C.gold[1], C.gold[2], C.gold[3], 0.16, 0)
    s.me:Hide()
    s.hl = s:CreateTexture(nil, "HIGHLIGHT")
    s.hl:SetAllPoints()
    s.hl:SetColorTexture(1, 0.9, 0.6, 0.06)
    s.stripe = s:CreateTexture(nil, "ARTWORK")
    s.stripe:SetPoint("TOPLEFT")
    s.stripe:SetPoint("BOTTOMLEFT")
    s.stripe:SetWidth(3)
    s.cls = UI:ClassIcon(s, 20)
    s.cls:SetPoint("LEFT", 8, 0)
    s.role = UI:Icon(s, 12, nil, "OVERLAY")
    s.role:SetPoint("TOPRIGHT", -5, -5)
    s.name = UI:Text(s, 12, "text")
    s.name:SetPoint("TOPLEFT", SLOT_TEXT_X, -4)
    s.chips = {}
    s:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    s:SetScript("OnEnter", function(self) GF:Safe("buffs:slot", slotTip, self) end)
    s:SetScript("OnLeave", function() UI:HideTip() end)
    s:SetScript("OnClick", function(self, button) GF:Safe("buffs:slot-click", slotClick, self, button) end)
    return s
end

local function slotChip(s, i)
    local c = s.chips[i]
    if not c then
        c = UI:IconChip(s, CHIP)
        c:SetPoint("BOTTOMLEFT", s, "BOTTOMLEFT", SLOT_TEXT_X + (i - 1) * (CHIP + CHIP_GAP), 4)
        s.chips[i] = c
    end
    return c
end

-- what a chip means shows on the picture and, only when it's news, a coloured edge
local RED_TINT = { 0.82, 0.42, 0.42 }

local function setChip(c, icon, edge, alpha, desat, tint)
    c:SetIcon(icon)
    c:SetDesaturated(desat)
    if tint then c.icon:SetVertexColor(tint[1], tint[2], tint[3], 1) end
    if edge then
        local e = col(edge)
        c.edge:SetColorTexture(e[1], e[2], e[3], 1)
    else
        c.edge:SetColorTexture(0, 0, 0, 0.85)
    end
    c:SetAlpha(alpha)
    c:Show()
end

local function paintChips(s, m, person, maxChips)
    local miss = page.live.missing[m.key]
    local nMiss = miss and min(#miss, 3) or 0
    local obj = person.campObj and D.campByKey[person.campObj]
    local room = max(0, maxChips - nMiss - (obj and 1 or 0))
    local active = page.active[m.key] or {}
    local list = {}
    -- buffs they're covering in the plan first, then what else they could cast, then maybes
    for _, k in ipairs(person.provides or {}) do
        if active[k] and #list < room then list[#list + 1] = { kind = "on", cat = k } end
    end
    for _, k in ipairs(person.provides or {}) do
        if not active[k] and #list < room then list[#list + 1] = { kind = "can", cat = k } end
    end
    for _, k in ipairs(person.maybe or {}) do
        if #list < room then list[#list + 1] = { kind = "maybe", cat = k } end
    end
    if obj then list[#list + 1] = { kind = "camp", obj = obj } end
    for i = 1, nMiss do list[#list + 1] = { kind = "miss", cat = miss[i] } end
    for i, it in ipairs(list) do
        local c = slotChip(s, i)
        if it.kind == "camp" then
            local onDuty = person.assigned == it.obj.key
            local cooling = person.campReady == false
            setChip(c, API.ItemIcon(it.obj.items and it.obj.items[1]), cooling and "red" or (onDuty and "blue" or nil),
                onDuty and 1 or 0.7, cooling)
        else
            local cat = D.byKey[it.cat]
            local icon = API.SpellIcon(cat and cat.icon)
            if it.kind == "on" then
                setChip(c, icon, nil, 1, false)
            elseif it.kind == "can" then
                setChip(c, icon, nil, 0.45, false)
            elseif it.kind == "maybe" then
                setChip(c, icon, nil, 0.6, true)
            else
                -- the coverage tiles do the shouting: a row just notes what this one lacks
                setChip(c, icon, "red", 0.8, true, RED_TINT)
            end
        end
    end
    for i = #list + 1, #s.chips do s.chips[i]:Hide() end
end

local function clearSlot(s)
    s.member = nil
    s:EnableMouse(false)
    s:SetAlpha(1)
    s.bg:SetColorTexture(1, 0.96, 0.86, 0.012)
    s.me:Hide()
    s.cls:Hide()
    s.name:Hide()
    s.role:Hide()
    s.stripe:Hide()
    for _, c in ipairs(s.chips) do c:Hide() end
end

local function paintSlot(s, m, gw, maxChips)
    local person = page.rep.people[m.key] or {}
    local class = person.class or m.class
    s.member = m
    s:EnableMouse(true)
    s.bg:SetColorTexture(1, 0.96, 0.86, 0.035)
    s.me:SetShown(isMe(m.key))
    s.cls:SetClass(class)
    s.cls:Show()
    s.name:SetText(classText(m.key, class))
    s.name:SetWidth(max(20, gw - SLOT_TEXT_X - 18))
    s.name:Show()
    local cc = API.ClassColor(class)
    if cc then s.stripe:SetColorTexture(cc.r, cc.g, cc.b, 0.95) else s.stripe:SetColorTexture(C.faint[1], C.faint[2], C.faint[3], 0.6) end
    s.stripe:Show()
    local role = m.role and T.roles[m.role]
    if role then
        UI:SetIcon(s.role, role.icon)
        s.role:SetVertexColor(role.color[1], role.color[2], role.color[3], 1)
        s.role:Show()
    else
        s.role:Hide()
    end
    -- offline people in a live group fade back; lineups are about later, so they don't
    s:SetAlpha((page.view.kind ~= "event" and person.online == false) and 0.5 or 1)
    paintChips(s, m, person, maxChips)
end

local function paintGrid(bw)
    local p = page
    local body = p.raid.body
    local groups = p.groups
    for _, h in ipairs(p.groupHeads) do h:Hide() end
    for _, s in ipairs(p.slots) do s:Hide() end
    local titles = { group = "The group", event = "The lineup", online = "Online guildies" }
    p.raid:SetTitle(titles[p.view.kind] or "The lineup")
    if not groups[1] then
        p.raidEmpty:SetText(emptyText(p.view))
        -- the online view is the what-if itself: nowhere further to send them
        if p.raidEmpty.action then p.raidEmpty.action:SetShown(p.view.kind ~= "online") end
        p.raidEmpty:Show()
        p.raid.subtitle:SetText("")
        return 190
    end
    p.raidEmpty:Hide()
    local nG = #groups
    local cols = max(1, min(4, nG, floor((bw + GROUP_GAP) / (GROUP_MIN_W + GROUP_GAP))))
    local _, spreadW = spread(1, cols, bw, GROUP_GAP)
    -- a 5-man shouldn't stretch into a long bar with the name miles from the role: leave the rest empty
    local capped = spreadW > GROUP_MAX_W
    local blockH = GROUP_HEAD + 5 * (SLOT_H + SLOT_GAP) - SLOT_GAP
    -- one group on its own runs across the card, instead of a stub with a hole beside it
    local lone = nG == 1 and capped and max(1, min(3, floor((bw + GROUP_GAP) / (LONE_MIN_W + GROUP_GAP)))) or 1
    local si = 0
    for gi, g in ipairs(groups) do
        local cx, cy = (gi - 1) % cols, floor((gi - 1) / cols)
        local x, gw = spread(cx + 1, cols, bw, GROUP_GAP)
        if capped then x, gw = cx * (GROUP_MAX_W + GROUP_GAP), GROUP_MAX_W end
        local y = cy * (blockH + 12)
        local headW = gw
        if lone > 1 then
            headW = bw
            x, gw = spread(1, lone, bw, GROUP_GAP)
        end
        local maxChips = max(1, floor((gw - SLOT_TEXT_X - 4 + CHIP_GAP) / (CHIP + CHIP_GAP)))
        local h = p.groupHeads[gi]
        if not h then
            h = UI:SectionLabel(body, "")
            p.groupHeads[gi] = h
        end
        h:ClearAllPoints()
        h:SetPoint("TOPLEFT", body, "TOPLEFT", x, -y)
        h:SetWidth(headW)
        h:SetText("GROUP " .. g.index)
        h:Show()
        for i = 1, 5 do
            si = si + 1
            local s = p.slots[si]
            if not s then
                s = makeSlot(body)
                p.slots[si] = s
            end
            s:ClearAllPoints()
            local col, line = (i - 1) % lone, floor((i - 1) / lone)
            local slotX = x
            if lone > 1 then slotX = spread(col + 1, lone, bw, GROUP_GAP) end
            s:SetPoint("TOPLEFT", body, "TOPLEFT", slotX,
                -(y + GROUP_HEAD + line * (SLOT_H + SLOT_GAP)))
            s:SetWidth(gw)
            local m = g.members[i]
            if m then
                paintSlot(s, m, gw, maxChips)
                s:Show()
            elseif p.view.kind ~= "online" then
                -- a free spot in a real group is worth seeing; the what-if just ran out of people
                clearSlot(s)
                s:Show()
            end
        end
    end
    -- subtitle: size, addon reach, scan freshness
    local view, rep = p.view, p.rep
    local parts = { (rep.addon or 0) .. " on Greenfields" }
    if view.kind == "group" then
        local lv = B:Live()
        if API.InCombat() or API.AurasSecret() then
            -- what's on screen is the last out-of-combat read, so say how old it is
            parts[#parts + 1] = T:Wrap("yellow", "buffs hidden in combat") .. (lv.t and (" - last read " .. ago(lv.t)) or "")
        elseif lv.stale then
            parts[#parts + 1] = T:Wrap("yellow", "buffs hidden right now")
        elseif lv.running then
            parts[#parts + 1] = "scanning..."
        elseif lv.t then
            parts[#parts + 1] = "scanned " .. ago(lv.t)
        else
            parts[#parts + 1] = "not scanned yet"
        end
    elseif view.kind == "online" and view.hidden > 0 then
        parts[#parts + 1] = "+" .. view.hidden .. " more not shown"
    end
    p.raid.subtitle:SetText(concat(parts, DOT))
    local rows = ceil(nG / cols)
    return 38 + rows * blockH + (rows - 1) * 12 + 10
end

-------------------------------------------------------------------------------
-- Camp duty
-------------------------------------------------------------------------------
local function stateOf(a)
    local ps = B:PingState(a.player)
    local mineObj = ps and ps.o == a.object
    if mineObj and ps.ack then
        if ps.off then return "PINGS OFF", "faint" end
        return "ACKED", "blue"
    end
    if a.state == "cooldown" then return ("COOLDOWN " .. U.Duration(max(0, (a.readyAt or 0) - now()))):upper(), "red" end
    if a.state == "craft" then return "CRAFT KIT", "yellow" end
    if mineObj and ps.sent then return ps.how == "whisper" and "WHISPERED" or "PINGED", "blue" end
    return "READY", "green"
end

local function confirmWhisper(list)
    if not list[1] then return end
    local texts, preview = {}, {}
    for i, a in ipairs(list) do
        texts[i] = B:WhisperText(a.player, a.object, a.buff)
        if i <= 4 then preview[#preview + 1] = U.ShortName(a.player) .. ": " .. texts[i] end
    end
    if #list > 4 then preview[#preview + 1] = "...and " .. (#list - 4) .. " more" end
    local single = #list == 1
    local title = single and ("Whisper " .. U.ShortName(list[1].player) .. "?") or ("Whisper " .. #list .. " people?")
    local lead = single and "They're not running Greenfields, so the ping goes out as a whisper:"
        or "These ones aren't running Greenfields, so they get a whisper:"
    UI:Confirm(title, lead .. "\n\n" .. concat(preview, "\n"), function()
        local failed = 0
        for i, a in ipairs(list) do
            if not B:Whisper(a.player, a.object, a.buff, texts[i]) then failed = failed + 1 end
        end
        if failed > 0 then
            UI:Toast({ title = "Chat said nah", text = "Chat messages are restricted right now. Give it another go in a sec.",
                       icon = "warning", style = "yellow" })
        end
    end, "Send it")
end

local function pingRow(r)
    local a = r.assign
    if not a or whatIf() then return end
    if not B:CanPing() then
        UI:Toast({ title = "Not your call", text = "Only the raid leader, assists and officers can send camp pings.", icon = "lock", style = "yellow" })
        return
    end
    local how = B:Ping(a.player, a.object, a.buff)
    if how == "whisper" then
        confirmWhisper({ a })
    elseif not how then
        UI:Toast({ title = "Ping didn't go", text = "Couldn't reach " .. U.ShortName(a.player) .. ". Are they online?", icon = "warning", style = "yellow" })
    end
end

local function pingTip(r)
    local a = r and r.assign
    if not a then return nil end
    local nm = U.ShortName(a.player)
    if whatIf() then return { "Ping " .. nm, { "This lineup's a what-if. Pick the current group or a raid to send camp pings." } } end
    if not B:CanPing() then return { "Ping " .. nm, { "Only the raid leader, assists and officers can send camp pings." } } end
    if not a.online then return { "Ping " .. nm, { nm .. " is offline." } } end
    if B:HasAddon(a.player) then return { "Ping " .. nm, { "Puts a camp-duty sign on their screen with a raid warning." } } end
    return { "Whisper " .. nm, { "No Greenfields, so this offers a whisper instead." } }
end

local function campRowTip(r)
    local a, need = r.assign, r.need
    local item = a or need
    if not item then return end
    local obj, cat = D.campByKey[item.object], D.byKey[item.buff]
    if not obj or not cat then return end
    local prof = profOf(obj)
    local lines = { { "Covers", cat.long }, { "Profession", prof and prof.name or "?" } }
    if a then
        table.insert(lines, 1, { "Who", nameOf(a.player, a.class) })
        if a.state == "ready" then
            lines[#lines + 1] = T:Wrap("green", "Has " .. a.kits .. " " .. U.Plural(a.kits, "kit") .. " in the bags - ready to drop.")
        elseif a.state == "craft" then
            lines[#lines + 1] = T:Wrap("yellow", "Knows the recipe but has no kit on them yet.")
        else
            lines[#lines + 1] = T:Wrap("red", "Camp cooldown: back in " .. U.Duration(max(0, (a.readyAt or 0) - now())) .. ".")
        end
        local e = page.rep.cats[item.buff]
        local backups = {}
        for i, k in ipairs(e and e.camp or {}) do
            if i > 1 then backups[#backups + 1] = k end
        end
        if backups[1] then lines[#lines + 1] = { "Backups", namesOf(backups, 3) } end
        local ps = B:PingState(a.player)
        if ps and ps.o == a.object then
            if ps.ack and ps.off then
                lines[#lines + 1] = T:Wrap("faint", "Has camp pings turned off.")
            elseif ps.ack then
                lines[#lines + 1] = T:Wrap("blue", "Acked " .. ago(ps.ack) .. ".")
            elseif ps.sent then
                lines[#lines + 1] = T:Wrap("blue", (ps.how == "whisper" and "Whispered " or "Pinged ") .. ago(ps.sent) .. ".")
            end
        end
    elseif need.reason == "busy" then
        lines[#lines + 1] = "Everyone who can drop one is already on duty: " .. namesOf(need.cands, 4) .. "."
    else
        lines[#lines + 1] = "Nobody here knows the " .. obj.name .. " or carries a kit. Any " .. (prof and prof.name or "crafter")
            .. " can learn it from the trainer at skill 20."
    end
    if obj.note then lines[#lines + 1] = T:Wrap("faint", obj.note .. ".") end
    UI:Tip(r, obj.name, lines)
end

--- A status tag: news gets the tinted tag, good news is just the coloured word.
local function setTag(pill, text, color, loud)
    pill:SetText(text, color)
    pill.bg:SetShown(loud and true or false)
end

local function makeCampRow(parent)
    local r = CreateFrame("Button", nil, parent)
    r:SetHeight(ROW_H)
    -- a line on the page, not a box: only trouble earns the coloured edge
    r.hl = r:CreateTexture(nil, "HIGHLIGHT")
    r.hl:SetAllPoints()
    r.hl:SetColorTexture(1, 0.9, 0.6, 0.05)
    r.rule = UI:Hairline(r, "line", 0.5, "none")
    r.rule:SetPoint("BOTTOMLEFT")
    r.rule:SetPoint("BOTTOMRIGHT")
    r.accent = r:CreateTexture(nil, "ARTWORK")
    r.accent:SetPoint("TOPLEFT", 0, -3)
    r.accent:SetPoint("BOTTOMLEFT", 0, 4)
    r.accent:SetWidth(2)
    r.art = UI:IconChip(r, 24)
    r.art:SetPoint("LEFT", 8, 0)
    r.icon = r.art.icon
    r.ping = UI:IconButton(r, "bell", 22, function(self) return pingTip(self:GetParent()) end,
        function(self) pingRow(self:GetParent()) end)
    r.ping:SetPoint("RIGHT", 0, 0)
    r.status = UI:Pill(r, "", "green", { height = 16, size = 10 })
    r.status:SetPoint("TOPRIGHT", r, "TOPRIGHT", -26, -3)
    r.name = UI:Text(r, 12, "text")
    r.name:SetPoint("TOPLEFT", r.art, "TOPRIGHT", 8, 1)
    r.name:SetPoint("TOPRIGHT", r.status, "TOPLEFT", -6, 0)
    r.what = UI:Text(r, 11, "dim")
    -- the tag only shares the top line: what they're dropping can run the full width
    r.what:SetPoint("TOPLEFT", r.art, "TOPRIGHT", 8, -14)
    r.what:SetPoint("TOPRIGHT", r, "TOPRIGHT", -26, -21)
    r:SetScript("OnEnter", function(self) GF:Safe("buffs:camp-row", campRowTip, self) end)
    r:SetScript("OnLeave", function() UI:HideTip() end)
    return r
end

local function paintAssign(r, a, canPing)
    r.assign, r.need = a, nil
    local obj, cat = D.campByKey[a.object], D.byKey[a.buff]
    local prof = profOf(obj)
    r.art:SetIcon((prof and prof.icon) or API.ItemIcon(obj.items and obj.items[1]))
    local me = isMe(a.player)
    r.name:SetText(nameOf(a.player, a.class) .. (me and T:Wrap("faint", "  (you)") or ""))
    r.what:SetText(obj.name .. T:Wrap("dim", "  covers  ") .. T:Wrap("text", cat and (B.SHORT[cat.key] or cat.label) or "?"))
    local label, color = stateOf(a)
    setTag(r.status, label, color, color ~= "green")
    local c = col(color)
    r.accent:SetColorTexture(c[1], c[2], c[3], 0.9)
    r.accent:SetShown(color ~= "green")
    if me then
        r.ping:Hide()
    else
        local ps = B:PingState(a.player)
        local acked = ps and ps.ack and ps.o == a.object
        local pinged = ps and ps.sent and ps.o == a.object
        UI:SetIcon(r.ping.icon, acked and "check" or "bell")
        r.ping:SetColor(acked and "green" or (pinged and "blue" or "dim"))
        local usable = canPing and a.online and true or false
        r.ping:SetEnabled(usable)
        r.ping:SetAlpha(usable and 1 or 0.35)
        r.ping:Show()
    end
end

local function paintNeed(r, u)
    r.assign, r.need = nil, u
    local obj, cat = D.campByKey[u.object], D.byKey[u.buff]
    r.art:SetIcon("warning")
    r.icon:SetVertexColor(C.red[1], C.red[2], C.red[3], 1)
    r.name:SetText(T:Wrap("red", u.reason == "busy" and "Nobody spare" or "Nobody can drop it"))
    r.what:SetText((obj and obj.name or "?") .. T:Wrap("dim", "  for  ") .. (cat and (B.SHORT[cat.key] or cat.label) or "?"))
    setTag(r.status, "MISSING", "red", true)
    r.accent:SetColorTexture(C.red[1], C.red[2], C.red[3], 0.9)
    r.accent:Show()
    r.ping:Hide()
end

local function paintFire(plan, nObjects, bw)
    local f = page.fire
    local fire
    for _, x in ipairs(D.campfires) do
        if x.key == plan.fire then fire = x end
    end
    if not fire then
        f:Hide()
        return false
    end
    f.item:SetItem(fire.item)
    f.title:SetText(fire.name)
    local fires = plan.fires or 1
    local slots = (plan.slots or fire.slots or 3) * fires
    f.slots:SetText(nObjects .. " / " .. slots .. (fires > 1 and ("  (" .. fires .. " FIRES)") or ""), nObjects > slots and "red" or "yellow")
    -- "Journeyman Campfire" + "(2 FIRES)" outgrows a narrow card: the title gives way
    local room = bw - FIRE_TEXT_X - 8 - 8 - (f.slots:GetWidth() or 0)
    f.title:SetWidth(max(40, min((f.title:GetStringWidth() or 0) + 2, room)))
    if plan.cook then
        local s = "Lit by " .. nameOf(plan.cook)
        if plan.cookRank and plan.cookRank > 0 then s = s .. T:Wrap("dim", "  (Cooking " .. plan.cookRank .. ")") end
        if plan.extraCook then s = s .. T:Wrap("dim", "  +  second fire: ") .. nameOf(plan.extraCook) end
        f.sub:SetText(s)
    else
        f.sub:SetText(T:Wrap("red", "Nobody's carrying one") .. T:Wrap("dim", " - any cook can make a Basic Campfire Kit"))
    end
    f:Show()
    return true
end

local function paintCamp(bw)
    local p = page
    local view, rep = p.view, p.rep
    local plan = rep.plan or {}
    local as = plan.assignments or {}
    local un = rep.unassigned or {}
    local real = view.kind ~= "online"     -- a what-if lineup has nobody to ping or brief
    local canPing = real and B:CanPing()
    for _, r in ipairs(p.campRows) do r:Hide() end
    p.fire.sub:SetWidth(max(40, bw - FIRE_TEXT_X - 8))

    local anyPing, lines = false, B:PlanLines(rep)
    for _, a in ipairs(as) do
        if not isMe(a.player) and a.online then anyPing = true end
    end
    -- take them away rather than show them dead: a what-if can never ping or post
    p.pingAll:SetShown(real)
    p.postBtn:SetShown(real)
    p.pingAll:SetActive(canPing and anyPing)
    p.postBtn:SetActive(real and API.GroupChannel() ~= nil and lines[1] ~= nil)

    if not as[1] and not un[1] then
        p.fire:Hide()
        p.campEmpty:SetText("No camp needed. The class buffs have it sorted - put the kettle on.")
        p.campEmpty:Show()
        return 168
    end
    p.campEmpty:Hide()
    local y = 0
    if as[1] and paintFire(plan, #as, bw) then
        y = FIRE_H + 6
    else
        p.fire:Hide()
    end
    local i = 0
    local function nextRow()
        i = i + 1
        local r = p.campRows[i]
        if not r then
            r = makeCampRow(p.camp.body)
            p.campRows[i] = r
        end
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", p.camp.body, "TOPLEFT", 0, -y)
        r:SetPoint("TOPRIGHT", p.camp.body, "TOPRIGHT", 0, -y)
        r:Show()
        y = y + ROW_H
        return r
    end
    for _, a in ipairs(as) do paintAssign(nextRow(), a, canPing) end
    for _, u in ipairs(un) do paintNeed(nextRow(), u) end
    return 38 + y + 8
end

--- Already acked this object, or pinged for it in the last 30 s: another sign is just noise.
local function alreadyOnIt(a)
    local ps = B:PingState(a.player)
    if not ps or ps.o ~= a.object then return false end
    return ps.ack ~= nil or (ps.sent ~= nil and now() - ps.sent < 30)
end

local function pingAll()
    local rep = page and page.rep
    if not rep or whatIf() then return end
    if not B:CanPing() then
        UI:Toast({ title = "Not your call", text = "Only the raid leader, assists and officers can send camp pings.", icon = "lock", style = "yellow" })
        return
    end
    local sent, skipped, whisper = 0, 0, {}
    for _, a in ipairs(rep.plan and rep.plan.assignments or {}) do
        if not isMe(a.player) and a.online then
            if alreadyOnIt(a) then
                skipped = skipped + 1
            else
                local how = B:Ping(a.player, a.object, a.buff)
                if how == "addon" then
                    sent = sent + 1
                elseif how == "whisper" then
                    whisper[#whisper + 1] = a
                end
            end
        end
    end
    if sent > 0 then
        UI:Toast({ title = "Camp crew pinged", text = sent .. " " .. U.Plural(sent, "sign") .. " on the way. Watch for the acks.", icon = "bell", style = "green" })
    end
    if whisper[1] then
        confirmWhisper(whisper)
    elseif sent == 0 then
        UI:Toast({ title = "Nobody to ping", text = skipped > 0 and "The camp crew's already been told. Give them a sec."
            or "Everyone on camp duty is you, offline, or out of reach.", icon = "bell", style = "yellow" })
    end
end

local CHANNEL_NAMES = { RAID = "raid", PARTY = "party", INSTANCE_CHAT = "instance" }

local function postPlan()
    local rep = page and page.rep
    if not rep or whatIf() then return end
    local channel = API.GroupChannel()
    if not channel then
        UI:Toast({ title = "No group, no plan", text = "Get in a group first - this posts to group chat.", icon = "megaphone", style = "yellow" })
        return
    end
    local lines = B:PlanLines(rep)
    if not lines[1] then
        UI:Toast({ title = "Nothing to post", text = "No blessings to hand out and no camp needed.", icon = "megaphone", style = "yellow" })
        return
    end
    UI:Confirm("Post the camp plan?", "This goes to " .. (CHANNEL_NAMES[channel] or "group") .. " chat:\n\n" .. concat(lines, "\n"), function()
        for _, l in ipairs(lines) do
            local ok = API.SendChat(l, channel)
            if not ok then
                UI:Toast({ title = "Chat said nah", text = "Chat messages are restricted right now. Try again after the pull.", icon = "warning", style = "yellow" })
                break
            end
        end
    end, "Post it")
end

-------------------------------------------------------------------------------
-- Class buffs and notes
-------------------------------------------------------------------------------
local function classVerdict(e)
    local status = e and e.status or "na"
    if status == "class" then return "PRESENT", "green" end
    if status == "na" then return "N/A", "faint" end
    if e.maybe and e.maybe[1] then return "MAYBE", "yellow" end
    return "MISSING", "red"
end

local function classWho(cat, e)
    if not e or e.status == "na" then return T:Wrap("faint", "Nobody needs it") end
    if e.status == "class" then return namesOf(e.providers, 3) end
    if e.maybe and e.maybe[1] then return T:Wrap("yellow", "maybe ") .. namesOf(e.maybe, 2) .. T:Wrap("dim", " (talent)") end
    if cat.key == "light" and e.capable and e.capable[1] then return T:Wrap("dim", "No spare paladin") end
    return T:Wrap("dim", "Nobody brings it")
end

local function classRowTip(r)
    local cat, e = r.cat, r.entry
    if not cat then return end
    local label, color = classVerdict(e)
    local lines = { T:Wrap(color, label == "PRESENT" and "Someone's bringing it" or label == "MAYBE" and "Maybe - needs a talent we can't see"
        or label == "N/A" and "Nobody in this lineup needs it" or "Nobody's bringing it") }
    if e and e.providers and e.providers[1] then lines[#lines + 1] = { "From", namesOf(e.providers, 4) } end
    if e and e.maybe and e.maybe[1] and e.status ~= "class" then lines[#lines + 1] = { "Maybe", namesOf(e.maybe, 4) } end
    if e and e.need and e.need > 0 then lines[#lines + 1] = { "Who needs it", e.need .. " (" .. (B.WHO[cat.who] or "everyone") .. ")" } end
    if r.lc and r.lc.seen > 0 then lines[#lines + 1] = { "Has it now", r.lc.have .. " of " .. r.lc.seen } end
    if CLASS_TIPS[cat.key] then lines[#lines + 1] = T:Wrap("faint", CLASS_TIPS[cat.key]) end
    UI:Tip(r, cat.long, lines)
end

local function makeClassRow(parent)
    local r = CreateFrame("Frame", nil, parent)
    r:SetHeight(CLASS_ROW_H)
    r:EnableMouse(true)
    r.hl = r:CreateTexture(nil, "BACKGROUND")
    r.hl:SetAllPoints()
    r.hl:SetColorTexture(1, 0.9, 0.6, 0.05)
    r.hl:Hide()
    r.rule = UI:Hairline(r, "line", 0.5, "none")
    r.rule:SetPoint("BOTTOMLEFT")
    r.rule:SetPoint("BOTTOMRIGHT")
    r.art = UI:IconChip(r, 24)
    r.art:SetPoint("LEFT", 2, 0)
    r.icon = r.art.icon
    r.stat = UI:Pill(r, "", "faint", { height = 16, size = 10 })
    r.stat:SetPoint("TOPRIGHT", 0, -3)
    r.count = UI:Text(r, 11, "dim", "num")
    r.count:SetPoint("RIGHT", r.stat, "LEFT", -4, 0)
    r.label = UI:Text(r, 12, "text")
    r.label:SetPoint("TOPLEFT", r.art, "TOPRIGHT", 8, 1)
    r.who = UI:Text(r, 11, "dim")
    r.who:SetPoint("TOPLEFT", r.label, "BOTTOMLEFT", 0, -3)
    r:SetScript("OnEnter", function(self)
        self.hl:Show()
        GF:Safe("buffs:class-row", classRowTip, self)
    end)
    r:SetScript("OnLeave", function(self)
        self.hl:Hide()
        UI:HideTip()
    end)
    return r
end

local function paintClassRow(r, cat, e, lc, cw)
    r.cat, r.entry, r.lc = cat, e, lc
    r.art:SetIcon(API.SpellIcon(cat.icon))
    local status = e and e.status or "na"
    r.art:SetDesaturated(status ~= "class")
    r.art:SetAlpha(status == "na" and 0.5 or 1)
    local label, color = classVerdict(e)
    -- same voice as the tiles: only trouble gets a tag
    setTag(r.stat, label, color, color == "red" or color == "yellow")
    local live = (lc and lc.seen > 0) and (lc.have .. "/" .. lc.seen) or ""
    r.count:SetText(live)
    UI:SetTextColor(r.count, (lc and lc.seen > 0 and lc.have >= lc.seen) and "green" or "dim")
    r.label:SetText(cat.label)
    UI:SetTextColor(r.label, status == "na" and "dim" or "text")
    r.who:SetText(classWho(cat, e))
    local right = (r.stat:GetWidth() or 40) + (live ~= "" and ((r.count:GetStringWidth() or 0) + 4) or 0) + 4
    r.label:SetWidth(max(30, cw - 34 - right))
    r.who:SetWidth(max(30, cw - 34))
end

local function paintClass(bw)
    local p = page
    local list = B:ClassCategories()
    local cols = bw >= 640 and 3 or (bw >= 400 and 2 or 1)
    for i, cat in ipairs(list) do
        local r = p.classRows[i]
        if not r then
            r = makeClassRow(p.classCard.body)
            p.classRows[i] = r
        end
        local cx, cy = (i - 1) % cols, floor((i - 1) / cols)
        local x, cw = spread(cx + 1, cols, bw, CLASS_GAP)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", p.classCard.body, "TOPLEFT", x, -cy * CLASS_ROW_H)
        r:SetWidth(cw)
        paintClassRow(r, cat, p.rep.cats[cat.key], p.live.cats[cat.key], cw)
        r:Show()
    end
    return 38 + ceil(#list / cols) * CLASS_ROW_H + 8
end

local function paintNotes(bw)
    local p = page
    local body = p.notes.body
    local notes = p.rep.notes or {}
    local y = 0
    for i, text in ipairs(notes) do
        local l = p.noteLines[i]
        if not l then
            l = {}
            l.dot = UI:Icon(body, 8, "dot", "ARTWORK", "bronze")
            l.text = UI:Para(body, 12, "dim")
            p.noteLines[i] = l
        end
        l.text:ClearAllPoints()
        l.text:SetPoint("TOPLEFT", body, "TOPLEFT", 14, -y)
        l.text:SetWidth(max(40, bw - 14))
        l.text:SetText(text)
        l.dot:ClearAllPoints()
        l.dot:SetPoint("TOPLEFT", body, "TOPLEFT", 1, -(y + 3))
        l.dot:Show()
        l.text:Show()
        y = y + max(14, l.text:GetStringHeight() or 14) + 8
    end
    for i = #notes + 1, #p.noteLines do
        p.noteLines[i].dot:Hide()
        p.noteLines[i].text:Hide()
    end
    if not notes[1] then
        p.notesEmpty:SetWidth(max(40, bw))
        p.notesEmpty:SetText(p.view.members[1] and "Nothing to add. She'll be right." or "Pick a lineup and the planner chimes in.")
        p.notesEmpty:Show()
        y = 22
    else
        p.notesEmpty:Hide()
    end
    return 38 + y + 4
end

-------------------------------------------------------------------------------
-- Header, layout, refresh
-------------------------------------------------------------------------------
local function paintHeader()
    local p = page
    -- a booked lineup always gets its mark; a party still levelling doesn't
    if not p.view.members[1] or (p.view.kind ~= "event" and B:Ungraded(p.rep)) then
        p.score:Hide()
        p.scoreWas = nil
    else
        local s = tonumber(p.rep.score) or 0
        p.score.value:SetText(tostring(s))
        UI:SetTextColor(p.score.value, s >= 80 and "green" or (s >= 50 and "yellow" or "red"))
        p.score:SetWidth((p.score.value:GetStringWidth() or 20) + 5 + (p.score.caption:GetStringWidth() or 30))
        p.score:Show()
        -- fully buffed: give it the achievement sweep (once, as it gets there on this lineup)
        if s >= 100 and p.scoreWas and p.scoreWas < 100 and p.scoreFor == state.source then UI:Shine(p.score) end
        p.scoreWas, p.scoreFor = s, state.source
    end
    -- nobody to scan: take it away rather than show a dead button over the campfire
    local inGroup = API.InGroup()
    p.scanBtn:SetActive(inGroup)
    p.scanBtn:SetShown(inGroup)
end

--- Right column width for a content width (the left column takes the rest).
local function rightWidth(W) return floor(max(290, min(380, W * 0.4))) end

--- Usable content width. The scroll child only learns its width in the scroll frame's
-- OnSizeChanged, so until then take it from the scroll frame itself.
local function contentWidth(p)
    local W = floor(p.content:GetWidth() or 0)
    if W < 200 and p.scroll then
        local sw = floor(p.scroll:GetWidth() or 0)
        if sw >= 200 then
            p.content:SetWidth(sw)
            W = sw
        end
    end
    return W
end

--- Card subtitles stop short of whatever's on the right of their title row, instead of running under it.
local function fitTitle(card, width, rightW)
    local titleW = card.title and (card.title:GetStringWidth() or 0) or 70
    card.subtitle:SetWidth(max(40, floor(width - 40 - titleW - rightW)))
end

layout = function()
    local p = page
    if not p or not p.rep then return end
    local W = contentWidth(p)
    if W < 200 then return end
    -- the subtitle sits under the header's buttons, not beside them: it can have the full width
    p.header.sub:SetWidth(W)
    -- on a narrow window that runs the line across the campfire, so it gets a little dark behind it
    p.subScrim:SetShown(W < 700)
    local people = p.view.members[1] ~= nil
    local covH = paintTiles(W - 24, people)
    p.cov:SetHeight(covH)
    fitTitle(p.cov, W, p.score:IsShown() and (p.score:GetWidth() + 20) or 8)
    p.raid:ClearAllPoints()
    p.raid:SetPoint("TOPLEFT", p.cov, "BOTTOMLEFT", 0, -GAP)
    p.camp:SetShown(people)
    p.notes:SetShown(people)
    p.classCard:SetShown(people)
    if not people then
        -- launch morning: no wall of "not needed", just the one thing to do, filling the page
        p.raid:SetPoint("TOPRIGHT", p.cov, "BOTTOMRIGHT", 0, -GAP)
        paintGrid(W - 24)
        local raidH = max(190, floor((p.scroll:GetHeight() or 0) - covH - GAP))
        p.raid:SetHeight(raidH)
        p.scroll:SetContentHeight(covH + GAP + raidH)
        return
    end
    -- the left column is anchored to the camp card, so it reflows the moment this changes
    local Rw = rightWidth(W)
    local Lw = W - Rw - GAP
    p.camp:SetWidth(Rw)
    p.raid:SetPoint("TOPRIGHT", p.camp, "TOPLEFT", -GAP, 0)
    local raidH = paintGrid(Lw - 24)
    fitTitle(p.raid, Lw, 8)
    local campH = paintCamp(Rw - 24)
    p.camp:SetHeight(campH)
    local notesH = paintNotes(Rw - 24)
    -- the two columns finish level: whichever falls short takes up the slack
    local rightH = campH + GAP + notesH
    if raidH > rightH then
        notesH = notesH + raidH - rightH
    else
        raidH = rightH
    end
    p.raid:SetHeight(raidH)
    p.notes:SetHeight(notesH)
    local classH = paintClass(W - 24)
    p.classCard:SetHeight(classH)
    p.scroll:SetContentHeight(covH + GAP + raidH + GAP + classH + 2)
end

--- One layout per frame however many size events a drag-resize throws at us.
local layoutQueued = false
local function queueLayout()
    if layoutQueued then return end
    layoutQueued = true
    GF:After(0, function()
        layoutQueued = false
        GF:Safe("buffs:layout", layout)
    end)
end

refresh = function()
    if not page then return end
    loadEvents()
    local view = collect()
    page.sourceDD:Refresh()
    local input = {}
    for i, m in ipairs(view.members) do input[i] = { key = m.key, class = m.class, level = m.level } end
    local rep = B:Analyze(input, { at = view.at })
    -- work everything out first: a half-updated page would trip the next resize layout
    local groups, live, active = bucket(view), liveStats(view, rep), activeMap(rep)
    page.view, page.rep, page.groups, page.live, page.active = view, rep, groups, live, active
    paintHeader()
    layout()
end

local function scanNow()
    if not API.InGroup() then
        UI:Toast({ title = "Nobody to scan", text = emptyText({ kind = "group" }), icon = "eye", style = "yellow" })
        return
    end
    if not B:Scan() then
        UI:Toast({ title = "Buffs are hidden", text = "The game hides buffs in combat. Try again once you're out.", icon = "warning", style = "yellow" })
    end
end

local function build(p)
    page = p
    p.header = UI:PageHeader(p, "Buff Check", "What the raid's got, what it's missing, and who's on camp duty.")
    p.subScrim = p.header:CreateTexture(nil, "BACKGROUND")
    p.subScrim:SetPoint("TOPLEFT", p.header.sub, "TOPLEFT", -4, 2)
    p.subScrim:SetPoint("BOTTOMRIGHT", p.header.sub, "BOTTOMRIGHT", 0, -2)
    UI:Gradient(p.subScrim, "HORIZONTAL", 0.012, 0.018, 0.035, 0.72, 0.1)
    p.subScrim:Hide()
    p.sourceDD = UI:Dropdown(p.header, {
        width = 230, items = sourceItems,
        get = function() return state.source end,
        set = function(v)
            state.source, state.picked = v, true
            refresh()
            if v == "group" and API.InGroup() then B:Scan() end
        end,
        tooltip = { "Whose buffs?", {
            "Current group: who you're grouped with right now, live-scanned.",
            "A raid: the lineup the officers put together.",
            "Online guildies: what if everyone online turned up?",
        } },
    })
    p.header:AddAction(p.sourceDD)
    p.scanBtn = UI:Button(p.header, "Scan", { icon = "eye", onClick = scanNow, tooltip = { "Scan buffs", {
        "Reads everyone's buffs right now (out of combat only).",
        "It also scans every 10 seconds while this page is open.",
    } } })
    p.header:AddAction(p.scanBtn)

    local scroll, content = UI:Scroll(p, { outside = true })
    scroll:SetPoint("TOPLEFT", p.header, "BOTTOMLEFT", 0, -14)
    scroll:SetPoint("BOTTOMRIGHT", 0, 0)
    scroll:HookScript("OnSizeChanged", queueLayout)
    p.scroll, p.content = scroll, content
    local W0 = contentWidth(p)

    -- coverage strip, with the score as its headline number
    p.cov = UI:Card(content, { title = "Coverage", icon = "shield", subtitle = " " })
    p.cov:SetPoint("TOPLEFT", 0, 0)
    p.cov:SetPoint("TOPRIGHT", 0, 0)
    p.cov:SetHeight(112)
    p.score = CreateFrame("Frame", nil, p.cov.right)
    p.score:SetSize(60, 22)
    p.score:SetPoint("RIGHT", p.cov.right, "RIGHT", 0, 0)
    p.score:EnableMouse(true)
    p.score.value = UI:Text(p.score, 18, "green", "ui")
    p.score.value:SetPoint("RIGHT", 0, 0)
    p.score.caption = UI:Text(p.score, 11, "dim")
    p.score.caption:SetPoint("LEFT", 0, 0)
    p.score.caption:SetText("Score")
    UI.AttachTip(p.score, { "Buff score", {
        "How well this lineup is buffed, weighted by who actually benefits.",
        "Class buffs count in full; camp buffs a bit less (they're weaker).",
    } })
    p.score:Hide()
    p.tiles = {}
    for i, cat in ipairs(B:CoreCategories()) do p.tiles[i] = makeTile(p.cov.body, cat) end

    -- camp duty (right, fixed width set by layout) and the lineup (left, takes the rest)
    p.camp = UI:Card(content, { title = "Camp duty", icon = "campfire" })
    p.camp:SetPoint("TOPRIGHT", p.cov, "BOTTOMRIGHT", 0, -GAP)
    p.camp:SetSize(rightWidth(max(W0, 200)), 180)
    p.raid = UI:Card(content, { title = "The lineup", icon = "roster", subtitle = " " })
    p.raid:SetPoint("TOPLEFT", p.cov, "BOTTOMLEFT", 0, -GAP)
    p.raid:SetPoint("TOPRIGHT", p.camp, "TOPLEFT", -GAP, 0)
    p.raid:SetHeight(190)
    p.raidEmpty = UI:Empty(p.raid.body, "", "roster", {
        action = "What if the online mob turned up?", actionStyle = "primary",
        onAction = function()
            state.source, state.picked = "online", true
            refresh()
        end,
    })
    p.raidEmpty:Hide()
    p.groupHeads, p.slots = {}, {}

    p.postBtn = UI:Button(p.camp.right, "Post plan", { icon = "megaphone", height = 22, size = 11, iconSize = 12, style = "ghost", onClick = postPlan,
        tooltip = { "Post plan", { "Posts the blessings and camp plan to group chat in a few short lines." } } })
    p.postBtn:SetPoint("RIGHT", p.camp.right, "RIGHT", 0, 0)
    p.pingAll = UI:Button(p.camp.right, "Ping all", { icon = "bell", height = 22, size = 11, iconSize = 12, onClick = pingAll,
        tooltip = { "Ping all", { "Pings everyone on camp duty who's online.", "No addon? You'll be offered a whisper instead." } } })
    p.pingAll:SetPoint("RIGHT", p.postBtn, "LEFT", -6, 0)
    -- the campfire: a carved well with the kit in it and a little warmth coming off it
    p.fire = CreateFrame("Frame", nil, p.camp.body)
    p.fire:SetHeight(FIRE_H)
    p.fire:SetPoint("TOPLEFT")
    p.fire:SetPoint("TOPRIGHT")
    p.fire:SetClipsChildren(true)   -- keeps the glow inside the well
    p.fire.well = UI:Nine(p.fire, "inset", "BACKGROUND", -6)
    p.fire.glow = p.fire:CreateTexture(nil, "BACKGROUND", nil, 2)
    p.fire.glow:SetTexture(T.tex.glow)
    p.fire.glow:SetBlendMode("ADD")
    p.fire.glow:SetVertexColor(1, 0.5, 0.12, 0.5)
    p.fire.glow:SetSize(96, 72)
    p.fire.item = UI:ItemButton(p.fire, FIRE_ICON)
    p.fire.item:SetPoint("LEFT", 9, 0)
    p.fire.glow:SetPoint("CENTER", p.fire.item, "CENTER", 0, 0)
    p.fire.title = UI:Text(p.fire, 13, "wowGold", "ui")
    p.fire.title:SetPoint("TOPLEFT", p.fire, "TOPLEFT", FIRE_TEXT_X, -11)
    p.fire.slots = UI:Pill(p.fire, "", "yellow", { height = 16, size = 10 })
    p.fire.slots:SetPoint("LEFT", p.fire.title, "RIGHT", 8, 0)
    p.fire.sub = UI:Text(p.fire, 11, "dim")
    p.fire.sub:SetPoint("TOPLEFT", p.fire.title, "BOTTOMLEFT", 0, -6)
    p.fire:Hide()
    p.campEmpty = UI:Empty(p.camp.body, "", "check")
    p.campEmpty:Hide()
    p.campRows = {}

    p.notes = UI:Card(content, { title = "Notes", icon = "bubble" })
    p.notes:SetPoint("TOPLEFT", p.camp, "BOTTOMLEFT", 0, -GAP)
    p.notes:SetPoint("TOPRIGHT", p.camp, "BOTTOMRIGHT", 0, -GAP)
    p.notes:SetHeight(80)
    p.noteLines = {}
    p.notesEmpty = UI:Text(p.notes.body, 12, "dim")
    p.notesEmpty:SetPoint("TOPLEFT", 0, 0)
    p.notesEmpty:SetWordWrap(true)
    p.notesEmpty:Hide()

    -- the class-only buffs get the page's full width, under both columns
    p.classCard = UI:Card(content, { title = "Class buffs", icon = "bolt", subtitle = "no camp version" })
    p.classCard:SetPoint("TOPLEFT", p.raid, "BOTTOMLEFT", 0, -GAP)
    p.classCard:SetPoint("TOPRIGHT", p.notes, "BOTTOMRIGHT", 0, -GAP)
    p.classCard:SetHeight(120)
    p.classRows = {}
end

local function onShow(p, arg)
    if type(arg) == "string" and arg ~= "" then
        if arg == "group" or arg == "online" or arg:find("^ev:") then
            state.source = arg
        else
            state.source = "ev:" .. arg
        end
        state.picked = true
    end
    if not p.ticker then
        p.ticker = GF:Ticker(SCAN_EVERY, function()
            if not (page and page:IsVisible()) then return end
            if state.source == "group" and API.InGroup() and not API.InCombat() then
                B:Scan()
            else
                refresh()
            end
        end)
    end
    local fresh = not p.seen
    p.seen = true
    refresh()
    if fresh then
        queueLayout()
        if state.source == "group" and API.InGroup() then B:Scan() end
    end
end

local function onHide(p)
    p.seen = false
    if p.ticker then
        p.ticker:Cancel()
        p.ticker = nil
    end
end

-- sidebar bubble while raiding: how many core buffs the raid can't cover (cached 15 s)
local badgeAt, badgeVal = -60, nil
local function badge()
    if not API.InRaid() then return nil end
    local t = API.Time()
    if t - badgeAt < 15 then return badgeVal end
    badgeAt = t
    local rep = B:Analyze(B:GroupInput())
    local n = rep.missing and #rep.missing or 0
    badgeVal = n > 0 and tostring(n) or nil
    return badgeVal
end

UI:RegisterPage({
    key = PAGE, title = "Buff Check", subtitle = "What the raid's got, what it's missing, and who's on camp duty.",
    icon = "campfire", group = "raid", order = 50,
    build = build, onShow = onShow, onHide = onHide, badge = badge,
})

-------------------------------------------------------------------------------
-- Data-change hooks
-------------------------------------------------------------------------------
local function visible() return page ~= nil and page:IsVisible() end

-- one live timer each, however chatty the raid gets (scan results, BQ reports, profile sync)
local refreshLater = B.Coalesce(function() UI:RefreshPage(PAGE) end, 2)
local scanLater = B.Coalesce(function()
    if visible() and API.InGroup() then B:Scan() end
end, 4)

local function refreshSoon(sec)
    -- a hidden page catches up in onShow; no point keeping timers alive for it
    if visible() then refreshLater(sec or 0.25) end
end

GF:On("GF_BUFFS_UPDATED", function() refreshSoon(0.2) end)
GF:On("GF_GROUP_UPDATED", function()
    badgeAt = -60
    if not visible() then return end
    refreshSoon(0.4)
    if state.source == "group" then scanLater(2) end
end)
GF:On("GF_STORE_CHANGED", function(name)
    if name == "profile" or name == "events" or name == "signups" then refreshSoon(1) end
end)
GF:On("GF_ROSTER_UPDATED", function()
    if state.source == "online" then refreshSoon(2) end
end)
GF:RegisterEvent("PLAYER_REGEN_ENABLED", function()
    if visible() and state.source == "group" and API.InGroup() then
        GF:After(1.5, function()
            if visible() and not API.InCombat() then B:Scan() end
        end)
    end
end)

GF:RegisterSlash("buffs", function() UI:OpenMain(PAGE) end, "open the Buff Check page")
