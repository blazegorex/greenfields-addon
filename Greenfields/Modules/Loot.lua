--[[ Greenfields - Modules/Loot.lua
     Everything that happens once loot hits the floor:

       * the loot catalogue: Forever's raid loot tables are unpublished, so every rare+
         item seen in a raid or dungeon (loot window, group-loot roll, encounter loot) is
         learned into a shared dataset with its instance and boss
       * the Loot Desk: a floating window for the SR host / master looter / raid leader
         listing each drop with its reservers, plus Announce, Roll SR/MS/OS and Award
       * roll tracking: /roll results parsed from CHAT_MSG_SYSTEM (pattern built from the
         client's RANDOM_ROLL_RESULT), 20 s window, tie rerolls, live roll panel shared
         with every Greenfields user in the group (ops LR / LW / LX)
       * loot history: who got what and how (SR, MS, OS, ROLL, FREE) + the Loot Log page
       * item tooltips: "Soft-reserved by" and "Drops in"

     Datasets
       loot/lt     id unique  {itemID, link, winner, t, instance, boss, how, session, by, class}
       catalog/ct  id = itemID {i = instance, b = boss, q = quality, n = name, t}

     Public: GF.Loot:History(n)  :CountFor(key)  :SRWins(key)
     Internal: CatalogEntry, CatalogItems, Instances, Learn, Record, OpenDesk, StartRoll ]]

local _, GF = ...
local API, U, UI, T = GF.API, GF.Util, GF.UI, GF.Theme
local C = T.c
local Store, Comm = GF.Store, GF.Comm

local Loot = GF:NewModule("Loot")
GF.Loot = Loot

local type, pairs, ipairs, tostring, tonumber, select = type, pairs, ipairs, tostring, tonumber, select
local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil
local sort, concat = table.sort, table.concat

local LOOT, CATALOG = "loot", "catalog"
local MIN_QUALITY = 3           -- rare and up
local BOSS_WINDOW = 600         -- loot within 10 min of a kill belongs to that boss
local ROLL_SECONDS, REROLL_SECONDS = 20, 15
local MERGE_WINDOW = 900        -- a desk award and the loot event for it are the same entry
local DOT = "  \194\183  "

local HOW = {
    SR = { rank = 5, color = "green", label = "SR", tip = "Won off a soft reserve" },
    MS = { rank = 4, color = "blue", label = "MS", tip = "Main-spec roll" },
    OS = { rank = 3, color = "dim", label = "OS", tip = "Off-spec roll" },
    ROLL = { rank = 2, color = "yellow", label = "ROLL", tip = "Group loot Need/Greed roll" },
    FREE = { rank = 1, color = "pink", label = "FREE", tip = "Handed out or picked up without a roll" },
}
local HOW_ORDER = { "SR", "MS", "OS", "ROLL", "FREE" }
Loot.HOW = HOW

local CLASS_SET = {}
for _, c in ipairs(API.CLASSES) do CLASS_SET[c] = true end
local function validClass(c) return (type(c) == "string" and CLASS_SET[c]) and c or nil end

-- forward declarations (UI pieces defined further down)
local refreshDesk, refreshPanel, showPanel

-------------------------------------------------------------------------------
-- Small guarded client helpers (loot APIs not wrapped by GF.API)
-------------------------------------------------------------------------------
local function G(name)
    local f = rawget(_G, name)
    return type(f) == "function" and f or nil
end

local function callClean(name, ...)
    local f = G(name)
    if not f then return nil end
    local ok, v = pcall(f, ...)
    if ok then return API.Clean(v) end
    return nil
end

local function numLootItems()
    local n = callClean("GetNumLootItems")
    return type(n) == "number" and n or 0
end

local function slotHasItem(slot)
    return callClean("LootSlotHasItem", slot) and true or false
end

local function slotLink(slot)
    local l = callClean("GetLootSlotLink", slot)
    return type(l) == "string" and l or nil
end

-- GetLootSlotInfo: icon, name, quantity, currencyID, quality, ... (quality 5th)
local function slotQuality(slot)
    local f = G("GetLootSlotInfo")
    if not f then return nil end
    local ok, _, _, _, _, q = pcall(f, slot)
    if ok then return API.CleanNumber(q) end
    return nil
end

local function settings() return GF.db and GF.db.settings or {} end

local function prefs()
    local s = GF.db.settings
    if type(s.loot) ~= "table" then s.loot = {} end
    return s.loot
end

local function localDB() return GF.DB:Local("Loot") end

local function activeSession()
    if not (GF.SR and GF.SR.ActiveSession) then return nil end
    local ok, s = GF:Safe("loot:session", GF.SR.ActiveSession, GF.SR)
    if ok and type(s) == "table" then return s end
    return nil
end

local function reservesFor(itemID)
    if not (GF.SR and GF.SR.ReservesFor) then return {} end
    local ok, list = GF:Safe("loot:reserves", GF.SR.ReservesFor, GF.SR, itemID)
    if ok and type(list) == "table" then return list end
    return {}
end

local function groupChat()
    return API.GroupChannel()
end

--- say(text, auto): group chat. `auto` lines (not from a click) honour srAutoAnnounce,
-- and only ever go to RAID or PARTY (the automatic channels the contract allows).
local function say(text, auto)
    if auto and settings().srAutoAnnounce == false then return false end
    local ch = groupChat()
    if not ch or type(text) ~= "string" then return false end
    if auto and ch ~= "RAID" and ch ~= "PARTY" then return false end
    local ok, err
    if auto and GF.SR and GF.SR.AutoSend then
        ok, err = GF.SR.AutoSend(text, ch)     -- goes quiet if the client blocks auto sends
    else
        ok, err = API.SendChat(text, ch)
    end
    if not ok and err == "lockdown" and not auto then
        UI:Toast({ title = "Shh", text = "Chat messages are restricted right now.", style = "yellow", icon = "bubble", duration = 4 })
    end
    return ok
end

-------------------------------------------------------------------------------
-- Item link helpers
-------------------------------------------------------------------------------
local HEX_QUALITY = { ["9d9d9d"] = 0, ffffff = 1, ["1eff00"] = 2, ["0070dd"] = 3, a335ee = 4, ff8000 = 5, e6cc80 = 6 }

local function linkQuality(link)
    if type(link) ~= "string" then return nil end
    local q = link:match("|cnIQ(%d):")
    if q then return tonumber(q) end
    local hex = link:match("|c%x%x(%x%x%x%x%x%x)")
    return hex and HEX_QUALITY[hex:lower()] or nil
end

local function linkName(link)
    if type(link) ~= "string" then return nil end
    return link:match("|h%[(.-)%]|h")
end

local function qualityOf(itemID, link)
    local q = API.ItemQuality(link or itemID)
    if type(q) == "number" then return q end
    q = linkQuality(link)
    if q then return q end
    local e = Loot:CatalogEntry(itemID)
    return e and e.q or nil
end

local function linkOf(itemID, link)
    if type(link) == "string" and link ~= "" then return link end
    return API.ItemLink(itemID) or ("[" .. (API.ItemName(itemID) or ("item " .. tostring(itemID))) .. "]")
end

-- itemID -> GetTime() of our last load request (a failed load answers with another
-- GET_ITEM_INFO_RECEIVED, so unthrottled asks turn into a refresh loop)
local asked = {}

local function nameOf(itemID, link)
    local n = API.ItemName(itemID)
    if type(n) == "string" and n ~= "" and API.Readable(n) then return n end
    n = linkName(link)
    if n then return n end
    local e = Loot:CatalogEntry(itemID)
    if e and type(e.n) == "string" then return e.n end
    if type(itemID) == "number" then
        local t = API.Time()
        if not asked[itemID] or t - asked[itemID] > 30 then
            asked[itemID] = t
            API.RequestItem(itemID)
        end
    end
    return nil
end

local function coloredName(itemID, link, q)
    local n = nameOf(itemID, link)
    if not n then return T:Wrap("faint", "Fetching item info...") end
    local r, g, b = API.QualityColor(q or qualityOf(itemID, link) or 1)
    return U.Color(n, r, g, b)
end

local function coloredNames(list, maxShown)
    local parts = {}
    for i, e in ipairs(list) do
        if maxShown and i > maxShown then parts[#parts + 1] = T:Wrap("faint", "+" .. (#list - maxShown)); break end
        parts[#parts + 1] = U.ClassName(e.player, e.class) .. (((e.plus or 0) > 0) and T:Wrap("green", " +" .. e.plus) or "")
    end
    return concat(parts, T:Wrap("faint", ", "))
end

-------------------------------------------------------------------------------
-- Datasets
-------------------------------------------------------------------------------
--- nil, or a short string with no escape codes (names of bosses, raids and items)
local function plainField(v, n)
    return v == nil or (type(v) == "string" and #v <= n and not v:find("|", 1, true))
end

Store:Define({
    name = LOOT, code = "lt", owner = "shared", keepDays = 400,
    canWrite = function(author, id, new, old)
        if GF.Roster:IsOfficer(author) then return true end
        if new then return type(new) == "table" and author == new.by end
        return old ~= nil and author == old.by
    end,
    validate = function(id, d)
        return type(d) == "table" and type(d.itemID) == "number" and type(d.winner) == "string"
            and type(d.t) == "number" and (d.how == nil or HOW[d.how] ~= nil)
            and (d.link == nil or (type(d.link) == "string" and #d.link <= 400 and d.link:find("|Hitem:", 1, true) ~= nil))
            and plainField(d.boss, 96) and plainField(d.instance, 96)
    end,
    onChange = function() Loot:Invalidate() end,
})

Store:Define({
    name = CATALOG, code = "ct", owner = "shared", keepDays = 100000,
    canWrite = function(author) return GF.Roster:IsMember(author) end,
    validate = function(id, d)
        return type(id) == "number" and type(d) == "table" and plainField(d.i, 96) and plainField(d.b, 96)
            and plainField(d.n, 160) and (d.q == nil or type(d.q) == "number")
    end,
    onChange = function() Loot:InvalidateCatalog() end,
})

-------------------------------------------------------------------------------
-- Caches
-------------------------------------------------------------------------------
local histCache, statCache, catCache
local tipCache = {}
-- winner key -> main key. Roster:MainOf pattern-matches two guild notes per call, and the
-- log, leaderboard and filters ask it for every history entry on every refresh.
local mainMemo = {}

local function mainOf(key)
    local m = mainMemo[key]
    if m == nil then
        m = GF.Roster:MainOf(key) or key
        mainMemo[key] = m
    end
    return m
end

function Loot:Invalidate()
    histCache, statCache = nil, nil
    tipCache = {}
    mainMemo = {}
    GF:Debounce("loot-updated", 0.3, function()
        GF:Fire("GF_LOOT_UPDATED")
        UI:RefreshPage("loot")
    end)
end

function Loot:InvalidateCatalog()
    catCache = nil
    tipCache = {}
    GF:Debounce("loot-catalog", 1, function() UI:RefreshPage("softres") end)
end

-------------------------------------------------------------------------------
-- Boss tracking (no combat log: encounter events only)
-------------------------------------------------------------------------------
local lastBoss           -- { name, at = GetTime() }

local function encounterNames()
    local l = localDB()
    if type(l.encounters) ~= "table" then l.encounters = {} end
    return l.encounters
end

local function noteEncounter(id, name)
    id, name = API.CleanNumber(id), API.CleanString(name)
    if id and name and name ~= "" then encounterNames()[id] = name end
    return id, name
end

local function currentBoss()
    if lastBoss and API.Time() - lastBoss.at <= BOSS_WINDOW then return lastBoss.name end
    return nil
end

GF:RegisterEvent("ENCOUNTER_START", function(_, id, name) noteEncounter(id, name) end)

GF:RegisterEvent("ENCOUNTER_END", function(_, id, name, _, _, success)
    local _, n = noteEncounter(id, name)
    success = API.Clean(success)
    if n and (success == 1 or success == true) then lastBoss = { name = n, at = API.Time() } end
end)

GF:RegisterEvent("BOSS_KILL", function(_, id, name)
    local _, n = noteEncounter(id, name)
    if n then lastBoss = { name = n, at = API.Time() } end
end)

local function lootContext()
    local info = API.InstanceInfo()
    local inside = info.type == "raid" or info.type == "party"
    return inside, info
end

-------------------------------------------------------------------------------
-- The learned catalogue
-------------------------------------------------------------------------------
-- Raiders outside the guild can't write the shared catalogue; they keep a local copy.
local function localCatalog()
    local l = localDB()
    if type(l.catalog) ~= "table" then l.catalog = {} end
    return l.catalog
end

function Loot:CatalogEntry(itemID)
    itemID = API.ItemID(itemID)
    if not itemID then return nil end
    local d = Store:Get(CATALOG, itemID)
    if type(d) == "table" then return d end
    d = localCatalog()[itemID]
    return type(d) == "table" and d or nil
end

local function sortedCatalog()
    if catCache then return catCache end
    local list, seen = {}, {}
    local function add(id, d)
        if type(id) == "number" and type(d) == "table" and not seen[id] then
            seen[id] = true
            list[#list + 1] = { itemID = id, i = d.i, b = d.b, q = d.q, n = d.n, t = d.t }
        end
    end
    for id, d in pairs(Store:All(CATALOG)) do add(id, d) end
    for id, d in pairs(localCatalog()) do add(id, d) end
    sort(list, function(a, b)
        local ai, bi = a.i or "~", b.i or "~"
        if ai ~= bi then return ai < bi end
        local ab, bb = a.b or "~", b.b or "~"
        if ab ~= bb then return ab < bb end
        if (a.q or 0) ~= (b.q or 0) then return (a.q or 0) > (b.q or 0) end
        if (a.n or "") ~= (b.n or "") then return (a.n or "") < (b.n or "") end
        return a.itemID < b.itemID
    end)
    catCache = list
    return list
end

--- CatalogItems([instance]) -> array of {itemID, i, b, q, n, t} (treat as read-only)
function Loot:CatalogItems(instance)
    local list = sortedCatalog()
    if type(instance) ~= "string" or instance == "" then return list end
    local out = {}
    for _, e in ipairs(list) do
        if e.i == instance then out[#out + 1] = e end
    end
    return out
end

function Loot:Instances()
    local seen, out = {}, {}
    for _, e in ipairs(sortedCatalog()) do
        if e.i and not seen[e.i] then seen[e.i] = true; out[#out + 1] = e.i end
    end
    sort(out)
    return out
end

--- Every raider's client sees the same drop at the same moment (loot window, roll frame,
-- encounter loot, loot chat). Only one guildie per group writes the shared doc, so a new
-- item costs one broadcast instead of one per raider: the alphabetically first guildie
-- running Greenfields (or me, solo).
local function catalogPublisher()
    if not API.InGroup() then return true end
    local me, pick = API.MyKey(), nil
    for _, g in ipairs(GF.Roster:Group()) do
        local k = g.key
        if k and GF.Roster:IsMember(k) and GF.Comm:HasAddon(k) and (not pick or k < pick) then pick = k end
    end
    return pick == nil or pick == me
end

--- Learn(itemID, link, quality, boss, instance): remembers a rare+ drop.
function Loot:Learn(itemID, link, quality, boss, instance)
    itemID = API.ItemID(itemID)
    if not itemID or type(instance) ~= "string" or instance == "" then return end
    quality = API.CleanNumber(quality)
    if not quality or quality < MIN_QUALITY then return end
    local name = linkName(link)
    local cur = self:CatalogEntry(itemID)
    if cur and cur.i == instance and cur.q == quality and (cur.b or not boss) and (cur.n or not name) then return end
    local doc = {
        i = instance:sub(1, 48),
        b = (type(boss) == "string" and boss:sub(1, 48)) or (cur and cur.i == instance and cur.b) or nil,
        q = quality,
        n = (name and name:sub(1, 80)) or (cur and cur.n) or nil,
        t = API.ServerTime(),
    }
    local me = API.MyKey()
    local member = me and GF.Roster:IsMember(me)
    if member and catalogPublisher() and Store:Put(CATALOG, itemID, doc) then return end
    -- keep it locally straight away; if we're a guildie and the publisher's copy never
    -- turns up (their addon's off, comms lost in the instance), share ours after a while
    localCatalog()[itemID] = doc
    self:InvalidateCatalog()
    if member then
        GF:After(20 + math.random() * 25, function()
            if type(Store:Get(CATALOG, itemID)) ~= "table" and localCatalog()[itemID] == doc then
                Store:Put(CATALOG, itemID, doc)
            end
        end)
    end
end

-------------------------------------------------------------------------------
-- Loot history
-------------------------------------------------------------------------------
local function allHistory()
    if histCache then return histCache end
    local list = {}
    for id, d in pairs(Store:All(LOOT)) do
        if type(d) == "table" and type(d.itemID) == "number" and type(d.winner) == "string" then
            list[#list + 1] = {
                id = id, itemID = d.itemID, link = d.link, winner = d.winner, t = tonumber(d.t) or 0,
                instance = d.instance, boss = d.boss, how = HOW[d.how] and d.how or "FREE",
                session = d.session, by = d.by, class = validClass(d.class),
            }
        end
    end
    sort(list, function(a, b)
        if a.t ~= b.t then return a.t > b.t end
        return tostring(a.id) > tostring(b.id)
    end)
    histCache = list
    return list
end
Loot.AllHistory = allHistory

--- History(n) -> newest first: {id, itemID, link, winner, t, instance, boss, how}
function Loot:History(n)
    local list = allHistory()
    local lim = (type(n) == "number" and n > 0) and min(floor(n), #list) or #list
    local out = {}
    for i = 1, lim do
        local e = list[i]
        out[i] = { id = e.id, itemID = e.itemID, link = e.link, winner = e.winner, t = e.t,
                   instance = e.instance, boss = e.boss, how = e.how }
    end
    return out
end

local function stats()
    if statCache then return statCache end
    local count, sr = {}, {}
    for _, e in ipairs(allHistory()) do
        local m = mainOf(e.winner)
        count[m] = (count[m] or 0) + 1
        if e.how == "SR" then sr[m] = (sr[m] or 0) + 1 end
    end
    statCache = { count = count, sr = sr }
    return statCache
end

function Loot:CountFor(key)
    if type(key) ~= "string" then return 0 end
    return stats().count[mainOf(key)] or 0
end

function Loot:SRWins(key)
    if type(key) ~= "string" then return 0 end
    return stats().sr[mainOf(key)] or 0
end

--- Items per main, sorted: { {key, n}, ... }
function Loot:Leaderboard(entries)
    local count, order = {}, {}
    for _, e in ipairs(type(entries) == "table" and entries or allHistory()) do
        local m = mainOf(e.winner)
        if not count[m] then count[m] = 0; order[#order + 1] = m end
        count[m] = count[m] + 1
    end
    local out = {}
    for _, k in ipairs(order) do out[#out + 1] = { key = k, n = count[k] } end
    sort(out, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return a.key < b.key
    end)
    return out
end

local function findRecent(itemID, winner, window)
    local cutoff = API.ServerTime() - window
    for _, e in ipairs(allHistory()) do
        if e.t < cutoff then break end
        if e.itemID == itemID and e.winner == winner then return e end
    end
    return nil
end

local function postFeed(entry, id)
    if not (GF.Feed and GF.Feed.Post) then return end
    local who = GF.Roster:Colored(entry.winner)
    local link = linkOf(entry.itemID, entry.link)
    local text
    if entry.how == "SR" then
        text = who .. " won " .. link .. " off SR. Rigged? Probably."
    elseif entry.how == "MS" then
        text = who .. " won " .. link .. " on a main-spec roll. The bin chickens are seething."
    elseif entry.how == "OS" then
        text = who .. " scored " .. link .. " on an off-spec roll. Waste not, want not."
    else
        return
    end
    GF:Safe("loot:feed", GF.Feed.Post, GF.Feed, "loot", text, { icon = "dice", key = "loot:" .. tostring(id) })
end

--- Record{itemID, link, winner, how, boss, instance, class, session} -> id, created
-- Desk awards and loot events for the same drop merge into one entry; a better-known
-- "how" (SR beats MS beats FREE...) upgrades the existing one.
function Loot:Record(e)
    local me = API.MyKey()
    if not me or type(e) ~= "table" or type(e.itemID) ~= "number" or type(e.winner) ~= "string" then return nil end
    local how = HOW[e.how] and e.how or "FREE"
    local t = API.ServerTime()
    -- the 2-hour bucket makes two clients logging the same drop land on the same id
    local id = e.itemID .. ":" .. e.winner .. ":" .. floor(t / 7200)
    local existing = findRecent(e.itemID, e.winner, MERGE_WINDOW)
    if existing then
        id = existing.id
    elseif Store:Get(LOOT, id) then
        -- same item, same winner, same bucket but well outside the merge window: that's a
        -- second copy (two of a pattern, a later boss), not the same drop
        id = id .. ":" .. t
    end
    local cur = existing and Store:Get(LOOT, id) or nil
    if cur then
        local curHow = HOW[cur.how] and cur.how or "FREE"
        if HOW[how].rank <= HOW[curHow].rank then return id, false end
        local d = U.Copy(cur)
        d.how, d.by = how, me
        d.session = d.session or e.session
        d.boss = d.boss or (plainField(e.boss, 96) and e.boss or nil)
        local okUp = Store:Put(LOOT, id, d)
        if okUp and e.feed then postFeed(d, id) end
        return id, false
    end
    -- the same shape remote clients validate, so nobody rejects what we keep
    local link = e.link
    if not (type(link) == "string" and #link <= 400 and link:find("|Hitem:", 1, true)) then link = nil end
    local doc = {
        itemID = e.itemID, link = link, winner = e.winner, t = t,
        instance = plainField(e.instance, 96) and e.instance or nil, boss = plainField(e.boss, 96) and e.boss or nil,
        how = how, session = type(e.session) == "string" and e.session or nil, by = me,
        class = validClass(e.class) or validClass(GF.Roster:Class(e.winner)),
    }
    local ok = Store:Put(LOOT, id, doc)
    if ok and e.feed then postFeed(doc, id) end
    return ok and id or nil, ok
end

function Loot:Delete(id)
    return Store:Delete(LOOT, id)
end

function Loot:CanDelete(entry)
    local me = API.MyKey()
    return type(entry) == "table" and me ~= nil and (GF.Roster:IsOfficer(me) or entry.by == me)
end

-------------------------------------------------------------------------------
-- Who does what: desk user, history recorder, master loot
-------------------------------------------------------------------------------
local function myGroupEntry() return GF.Roster:GroupEntry(API.MyKey()) end

local function amLeader()
    local g = myGroupEntry()
    return g ~= nil and (g.rank or 0) >= 2
end

local function amML()
    local g = myGroupEntry()
    return g ~= nil and g.isML and true or false
end

local function lootMethod()
    local CP = rawget(_G, "C_PartyInfo")
    if type(CP) == "table" and type(CP.GetLootMethod) == "function" then
        local ok, m = pcall(CP.GetLootMethod)
        if ok and API.Readable(m) then
            if type(m) == "number" then
                local E = rawget(_G, "Enum")
                local LM = type(E) == "table" and E.LootMethod
                local master = (type(LM) == "table" and LM.Masterlooter) or 2
                return m == master and "master" or "other"
            elseif type(m) == "string" then
                return m
            end
        end
    end
    local f = G("GetLootMethod")
    if f then
        local ok, m = pcall(f)
        if ok and type(m) == "string" and API.Readable(m) then return m end
    end
    return nil
end

--- Master-loot hand-over is offered only when every piece of the API exists.
local function masterLootReady()
    return lootMethod() == "master" and G("GetMasterLootCandidate") ~= nil and G("GiveMasterLoot") ~= nil
end

local function hostingSession()
    local s = activeSession()
    if s and s.host == API.MyKey() then return s end
    return nil
end

local function isDeskUser()
    if hostingSession() then return true end
    if not API.InGroup() then return false end
    if amML() then return true end
    return amLeader() and API.InRaidInstance()
end

-- Exactly one client records automatic history: the SR host, else the leader if they
-- run Greenfields, else the alphabetically first guildie with the addon.
local function isRecorder()
    local me = API.MyKey()
    if not me or not API.InGroup() then return false end
    local s = activeSession()
    if s and s.host == me then return true end
    if s and GF.Roster:InGroup(s.host) then return false end
    local leader, pick
    for _, g in ipairs(GF.Roster:Group()) do
        if g.key then
            if (g.rank or 0) >= 2 then leader = g.key end
            if GF.Roster:IsMember(g.key) and GF.Comm:HasAddon(g.key) and (not pick or g.key < pick) then pick = g.key end
        end
    end
    if leader and GF.Comm:HasAddon(leader) then return leader == me end
    return pick == me
end

local function inGuildGroup()
    local total, guild = 0, 0
    for _, g in ipairs(GF.Roster:Group()) do
        total = total + 1
        if g.key and GF.Roster:IsMember(g.key) then guild = guild + 1 end
    end
    return total >= 2 and guild >= max(2, ceil(total / 2))
end

--- May `sender` drive rolls for my group?
local function trustedRoller(sender)
    if not GF.Roster:InGroup(sender) then return false end
    if GF.Roster:CanManage(sender) then return true end
    local s = activeSession()
    if s and s.host == sender then return true end
    local g = GF.Roster:GroupEntry(sender)
    return g ~= nil and g.isML and true or false
end

--- May I run rolls and awards from the desk? (same rule other clients apply to me)
local function canRunDesk()
    local me = API.MyKey()
    if not me then return false end
    if hostingSession() or amML() then return true end
    return GF.Roster:CanManage(me) and true or false
end
Loot.CanRunDesk = canRunDesk
local DESK_DENIED = "Only the SR host, master looter or raid lead can run the desk."

-------------------------------------------------------------------------------
-- Chat patterns built from the client's own format strings
-------------------------------------------------------------------------------
--- "%s rolls %d (%d-%d)" -> "^(.+) rolls (%d+) %((%d+)%-(%d+)%)$" (positional %1$s too)
local function toPattern(fmt)
    local p = fmt:gsub("%%%d?%$?s", "\001"):gsub("%%%d?%$?d", "\002")
    p = p:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    p = p:gsub("\001", "(.+)"):gsub("\002", "(%%d+)")
    return "^" .. p .. "$"
end

local rollPattern
local function getRollPattern()
    if not rollPattern then
        local fmt = rawget(_G, "RANDOM_ROLL_RESULT")
        if type(fmt) ~= "string" or fmt == "" or not API.Readable(fmt) then fmt = "%s rolls %d (%d-%d)" end
        rollPattern = toPattern(fmt)
    end
    return rollPattern
end

-------------------------------------------------------------------------------
-- Rolls
--   roll = { id, itemID, link, how, host, eligible = set|nil, eligibleList, duration,
--            ends (server time), localEnds (GetTime), rolls = {key = n}, order = {keys},
--            tie, done, doneAt, winner, winRoll, reason }
-------------------------------------------------------------------------------
local roll
local rollTicker
local pendingWins = {}    -- itemID.."|"..winner -> { how, t, link }
local groupRolls = {}     -- itemID -> server time a group-loot roll began
local markDeskWinner      -- defined with the desk

local function setOf(list)
    local s = {}
    for _, k in ipairs(list) do s[k] = true end
    return s
end

local function stopTicker()
    if rollTicker then rollTicker:Cancel(); rollTicker = nil end
end

local function timeLeft(r) return (r.localEnds or 0) - API.Time() end

local function sortedRolls(r)
    local out = {}
    for _, key in ipairs(r.order) do out[#out + 1] = { key = key, n = r.rolls[key] } end
    sort(out, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return a.key < b.key
    end)
    return out
end
Loot.SortedRolls = sortedRolls

local function redraw()
    if refreshPanel then refreshPanel() end
    if refreshDesk then refreshDesk() end
end

local finishRoll

local function tick()
    local r = roll
    if not r then stopTicker(); return end
    if r.done then
        if API.Time() - (r.doneAt or 0) > 8 then
            roll = nil
            stopTicker()
            redraw()
        end
        return
    end
    local left = timeLeft(r)
    if r.host == API.MyKey() then
        if left <= 0 then finishRoll() return end
    elseif left < -12 then
        -- the host went quiet (disconnect, lockdown): stop waiting
        r.done, r.doneAt, r.reason = true, API.Time(), "timeout"
        redraw()
        return
    end
    if refreshPanel then refreshPanel(true) end
end

local function beginRoll(r)
    roll = r
    stopTicker()
    rollTicker = GF:Ticker(0.1, tick)
    if showPanel then showPanel() end
    if refreshDesk then refreshDesk() end
end

local function endRoll(r, winner, value, reason)
    r.done, r.doneAt = true, API.Time()
    r.winner, r.winRoll, r.reason = winner, value, reason
    redraw()
end

local function namesLine(keys, budget)
    local out, used = {}, 0
    for i, k in ipairs(keys) do
        local n = U.ShortName(k)
        if used + #n + 2 > budget then
            out[#out + 1] = "+" .. (#keys - i + 1)
            break
        end
        out[#out + 1] = n
        used = used + #n + 2
    end
    return concat(out, ", ")
end

local function rollLine(r)
    local link = linkOf(r.itemID, r.link)
    local head
    if r.how == "SR" then
        head = ("%sSR roll for %s - /roll now (%ds), only: "):format(r.tie and "Reroll! " or "", link, r.duration)
        return head .. namesLine(r.eligibleList or {}, max(20, 250 - #head))
    end
    local kind = r.how == "OS" and "Off-spec" or "Main-spec"
    if r.tie then
        head = ("Reroll! %s tie on %s - /roll now (%ds): "):format(kind, link, r.duration)
        return head .. namesLine(r.eligibleList or {}, max(20, 250 - #head))
    end
    return ("%s roll for %s - /roll now (%ds)"):format(kind, link, r.duration)
end

local function winnerToast(winner, itemID, link, how)
    local l = linkOf(itemID, link)
    local key = "lw:" .. tostring(itemID) .. ":" .. tostring(winner)
    if winner == API.MyKey() then
        UI:Toast({ title = "Get in!", text = "You won " .. l .. ". Don't let it go to your head.",
            style = "green", icon = API.ItemIcon(itemID), key = key, duration = 8 })
    else
        UI:Toast({ title = U.ShortName(winner) .. " wins", text = GF.Roster:Colored(winner) .. " takes " .. l .. (how == "SR" and " off SR." or "."),
            style = "blue", icon = API.ItemIcon(itemID), key = key, duration = 5 })
    end
end

--- StartRoll(itemID, link, how, eligibleKeys, isTie) -> ok, err   (host / desk user)
function Loot:StartRoll(itemID, link, how, eligibleList, isTie)
    local me = API.MyKey()
    if not me then return false, "Still waking up." end
    if type(itemID) ~= "number" then return false, "No item." end
    if not canRunDesk() then return false, DESK_DENIED end
    if roll and not roll.done and roll.host == me and not isTie then return false, "Finish the current roll first." end
    if not API.InGroup() then return false, "You need a group to roll with." end
    how = HOW[how] and how or "MS"
    local dur = isTie and REROLL_SECONDS or ROLL_SECONDS
    local t = API.ServerTime()
    local r = {
        id = me .. ":" .. t .. ":" .. itemID, itemID = itemID, link = link, how = how, host = me,
        duration = dur, ends = t + dur, localEnds = API.Time() + dur, rolls = {}, order = {}, tie = isTie and true or nil,
    }
    if type(eligibleList) == "table" and #eligibleList > 0 then
        r.eligibleList = eligibleList
        r.eligible = setOf(eligibleList)
    end
    beginRoll(r)
    Comm:Group("LR", { id = r.id, itemID = itemID, link = link, eligible = r.eligibleList, ends = r.ends, how = how, tie = r.tie }, "ALERT")
    -- a tie reroll is started by the timer, not a click, so it follows srAutoAnnounce
    say(rollLine(r), isTie)
    return true
end

local function declareWinner(r, winner, value)
    endRoll(r, winner, value)
    Comm:Group("LW", { id = r.id, itemID = r.itemID, winner = winner, roll = value, how = r.how, link = r.link }, "ALERT")
    pendingWins[r.itemID .. "|" .. winner] = { how = r.how, t = API.ServerTime(), link = r.link }
    if markDeskWinner then markDeskWinner(r.itemID, winner, value, r.how) end
    say(("%s goes to %s%s%s. Grats!"):format(linkOf(r.itemID, r.link), U.ShortName(winner),
        value and (" (" .. value .. ")") or "", r.how == "SR" and " off SR" or ""), true)
    winnerToast(winner, r.itemID, r.link, r.how)
end

-- SR ties go to the higher plus when exactly one player has it; otherwise reroll.
local function plusTiebreak(r, tied)
    if r.how ~= "SR" then return nil end
    local plus = {}
    for _, e in ipairs(reservesFor(r.itemID)) do plus[e.player] = e.plus or 0 end
    local best, who, count = -1, nil, 0
    for _, k in ipairs(tied) do
        local p = plus[k] or 0
        if p > best then best, who, count = p, k, 1 elseif p == best then count = count + 1 end
    end
    if count == 1 and best > 0 then return who end
    return nil
end

finishRoll = function()
    local r = roll
    if not r or r.done or r.host ~= API.MyKey() then return end
    local best, tied = nil, {}
    for _, key in ipairs(r.order) do
        local v = r.rolls[key]
        if not best or v > best then
            best, tied = v, { key }
        elseif v == best then
            tied[#tied + 1] = key
        end
    end
    local link = linkOf(r.itemID, r.link)
    if not best then
        endRoll(r, nil, nil, "none")
        Comm:Group("LX", { id = r.id, itemID = r.itemID, why = "none" }, "ALERT")
        say(("Nobody rolled on %s. Free real estate."):format(link), true)
        return
    end
    if #tied > 1 then
        local byPlus = plusTiebreak(r, tied)
        if byPlus then return declareWinner(r, byPlus, best) end
        r.done, r.doneAt, r.reason = true, API.Time(), "tie"
        say(("Tie on %s at %d: %s. Reroll!"):format(link, best, namesLine(tied, 120)), true)
        Loot:StartRoll(r.itemID, r.link, r.how, tied, true)
        return
    end
    declareWinner(r, tied[1], best)
end

function Loot:EndRollNow()
    if roll and not roll.done and roll.host == API.MyKey() then finishRoll() end
end

function Loot:CancelRoll()
    local r = roll
    if not r or r.done or r.host ~= API.MyKey() then return end
    endRoll(r, nil, nil, "cancelled")
    Comm:Group("LX", { id = r.id, itemID = r.itemID, why = "cancel" }, "ALERT")
    say(("Roll on %s cancelled. As you were."):format(linkOf(r.itemID, r.link)))
end

--- Hands an item straight to its only reserver (no roll needed).
function Loot:GiveToReserver(itemID, link, key)
    local me = API.MyKey()
    if not me or type(key) ~= "string" or type(itemID) ~= "number" then return false, "No item." end
    if not canRunDesk() then return false, DESK_DENIED end
    if roll and not roll.done and roll.host == me then return false, "Finish the current roll first." end
    local r = { id = me .. ":" .. API.ServerTime() .. ":" .. itemID, itemID = itemID, link = link, how = "SR", host = me,
                rolls = {}, order = {}, duration = 0, ends = API.ServerTime(), localEnds = API.Time() }
    roll = r
    stopTicker()
    rollTicker = GF:Ticker(0.1, tick)
    declareWinner(r, key, nil)
    if showPanel then showPanel() end
    return true
end

function Loot:CurrentRoll() return roll end

-------------------------------------------------------------------------------
-- Roll results from chat
-------------------------------------------------------------------------------
GF:RegisterEvent("CHAT_MSG_SYSTEM", function(_, msg)
    local r = roll
    if not r or r.done then return end
    msg = API.CleanString(msg)
    if not msg then return end
    local name, v, lo, hi = msg:match(getRollPattern())
    v, lo, hi = tonumber(v), tonumber(lo), tonumber(hi)
    if not name or not v or lo ~= 1 or hi ~= 100 then return end
    local key = API.Key(name)
    if not key or r.rolls[key] then return end          -- first roll counts, rerolls don't
    if not GF.Roster:InGroup(key) and key ~= API.MyKey() then return end
    if r.eligible and not r.eligible[key] then return end
    if timeLeft(r) < -0.5 then return end
    r.rolls[key] = v
    r.order[#r.order + 1] = key
    redraw()
end)

function Loot:CanRoll()
    local f = G("RandomRoll")
    return f ~= nil
end

function Loot:DoRoll()
    local f = G("RandomRoll")
    if f then pcall(f, 1, 100) end
end

-------------------------------------------------------------------------------
-- Ops: LR (roll started), LW (winner), LX (cancelled / nobody rolled)
-------------------------------------------------------------------------------
Comm:Register("LR", function(p, sender)
    if type(p) ~= "table" or type(p.itemID) ~= "number" or type(p.ends) ~= "number" then return end
    if not trustedRoller(sender) then return end
    if roll and not roll.done and roll.host == API.MyKey() then return end
    local left = U.Clamp(p.ends - API.ServerTime(), 0, 60)
    local r = {
        id = type(p.id) == "string" and p.id or (sender .. ":" .. p.itemID), itemID = floor(p.itemID),
        link = type(p.link) == "string" and p.link or nil, how = HOW[p.how] and p.how or "MS", host = sender,
        ends = p.ends, duration = max(left, 1), localEnds = API.Time() + left, rolls = {}, order = {}, tie = p.tie and true or nil,
    }
    if type(p.eligible) == "table" then
        local list = {}
        for _, k in ipairs(p.eligible) do if type(k) == "string" then list[#list + 1] = k end end
        if #list > 0 then r.eligibleList = list; r.eligible = setOf(list) end
    end
    beginRoll(r)
end)

Comm:Register("LW", function(p, sender)
    if type(p) ~= "table" or type(p.itemID) ~= "number" or type(p.winner) ~= "string" then return end
    if not trustedRoller(sender) then return end
    local how = HOW[p.how] and p.how or "MS"
    local link = type(p.link) == "string" and p.link or nil
    local pk = p.itemID .. "|" .. p.winner
    if p.a then
        -- handed out from the desk without a roll: no roll panel, just the news
        local known = pendingWins[pk]
        pendingWins[pk] = { how = how, t = API.ServerTime(), link = link }
        if markDeskWinner then markDeskWinner(p.itemID, p.winner, nil, how) end
        if not known then winnerToast(p.winner, p.itemID, link, how) end
        return
    end
    if markDeskWinner then markDeskWinner(p.itemID, p.winner, tonumber(p.roll), how) end
    local r = roll
    if r and r.host == sender and r.itemID == p.itemID then
        endRoll(r, p.winner, tonumber(p.roll))
    else
        -- missed the start (joined late, loading screen): show the result anyway
        local nr = { id = type(p.id) == "string" and p.id or nil, itemID = p.itemID, link = link, how = how,
                     host = sender, rolls = {}, order = {}, duration = 1, ends = API.ServerTime(), localEnds = API.Time() }
        roll = nr
        stopTicker()
        rollTicker = GF:Ticker(0.1, tick)
        endRoll(nr, p.winner, tonumber(p.roll))
        if showPanel then showPanel() end
    end
    pendingWins[pk] = { how = how, t = API.ServerTime(), link = link }
    winnerToast(p.winner, p.itemID, link, how)
end)

Comm:Register("LX", function(p, sender)
    if type(p) ~= "table" then return end
    local r = roll
    if not r or r.done or r.host ~= sender then return end
    if p.id and r.id and p.id ~= r.id then return end
    endRoll(r, nil, nil, p.why == "none" and "none" or "cancelled")
end)

-------------------------------------------------------------------------------
-- Desk model: what's on the desk right now
--   entry = { itemID, link, q, slot, state = nil|"won"|"awarded", winner, value, how }
-------------------------------------------------------------------------------
local MAX_DESK = 8
local deskItems = {}
local deskInfo = {}        -- { sig, boss, instance }
local lootOpen = false
local announcedSigs = {}
local dismissedSig

Loot.DeskItems = function() return deskItems end
Loot.DeskInfo = function() return deskInfo end

local function deskFind(itemID, includeAwarded)
    for i, e in ipairs(deskItems) do
        if e.itemID == itemID and (includeAwarded or e.state ~= "awarded") then return e, i end
    end
    return nil
end

--- Two copies of the same item on one corpse are two rows: a result goes to the first
-- row that's still open (or already shows this winner), never over another row's winner.
local function deskFindFor(itemID, winner)
    local open, fallback
    for _, e in ipairs(deskItems) do
        if e.itemID == itemID and e.state ~= "awarded" then
            if winner and e.winner == winner then return e end
            if not e.winner and not open then open = e end
            if not fallback then fallback = e end
        end
    end
    return open or fallback
end

markDeskWinner = function(itemID, winner, value, how)
    local e = deskFindFor(itemID, winner)
    if not e then return end
    e.state, e.winner, e.value, e.how = "won", winner, value, how
    if refreshDesk then refreshDesk() end
end

local function signature(items)
    local ids = {}
    for _, it in ipairs(items) do ids[#ids + 1] = tostring(it.itemID) end
    sort(ids)
    return concat(ids, ",")
end

local function trimDesk()
    while #deskItems > MAX_DESK do
        local removed = false
        for i, e in ipairs(deskItems) do
            if e.state == "awarded" then table.remove(deskItems, i); removed = true; break end
        end
        if not removed then table.remove(deskItems, 1) end
    end
end

--- Pairs each drop with a desk row: one row per copy, so a corpse with two of the same
-- item gets two rows. Returns the drops nothing matched.
local function matchDesk(items)
    local claimed, unmatched = {}, {}
    for _, it in ipairs(items) do
        local cur
        for _, e in ipairs(deskItems) do
            if e.itemID == it.itemID and e.state ~= "awarded" and not claimed[e] then cur = e break end
        end
        if cur then
            claimed[cur] = true
            cur.slot = it.slot or cur.slot
        else
            unmatched[#unmatched + 1] = it
        end
    end
    return unmatched
end

--- Puts a set of drops on the desk; a new corpse replaces finished items.
local function feedDesk(items, boss, instance)
    if #items == 0 then return end
    local sig = signature(items)
    if sig ~= deskInfo.sig then
        local keep = {}
        local busy = roll and not roll.done
        for _, e in ipairs(deskItems) do
            -- keep anything still in play: mid-roll, or won but not yet handed over
            if (e.state == "won") or (busy and roll.itemID == e.itemID and e.state ~= "awarded") then keep[#keep + 1] = e end
        end
        deskItems = keep
        for _, it in ipairs(matchDesk(items)) do
            deskItems[#deskItems + 1] = { itemID = it.itemID, link = it.link, q = it.q, slot = it.slot }
        end
        trimDesk()
        deskInfo.sig, deskInfo.boss, deskInfo.instance = sig, boss, instance
    else
        matchDesk(items)
    end
    if dismissedSig ~= sig then Loot:OpenDesk() elseif refreshDesk then refreshDesk() end
end

--- Adds one item by hand (shift-clicked from bags, traded, whatever).
function Loot:AddToDesk(item)
    local itemID = API.ItemID(item)
    if not itemID then return false, "That's not an item. Shift-click one or paste a link / ID." end
    if deskFind(itemID) then return false, "That's already on the desk." end
    local link = (type(item) == "string" and item:find("|H", 1, true)) and item or API.ItemLink(itemID)
    deskItems[#deskItems + 1] = { itemID = itemID, link = link, q = qualityOf(itemID, link) }
    trimDesk()
    if refreshDesk then refreshDesk() end
    return true
end

function Loot:RemoveFromDesk(entry)
    for i, e in ipairs(deskItems) do
        if e == entry then table.remove(deskItems, i) break end
    end
    if refreshDesk then refreshDesk() end
end

function Loot:ClearDesk()
    deskItems = {}
    deskInfo = {}
    if refreshDesk then refreshDesk() end
end

-------------------------------------------------------------------------------
-- Loot window
-------------------------------------------------------------------------------
local function scanLootWindow()
    local out = {}
    for slot = 1, numLootItems() do
        if slotHasItem(slot) then
            local link = slotLink(slot)
            local id = API.ItemID(link)
            if id then
                out[#out + 1] = { slot = slot, itemID = id, link = link, q = qualityOf(id, link) or slotQuality(slot) }
            end
        end
    end
    return out
end

--- "Name (+2), Other" for chat, kept inside `budget` bytes (whole names only).
local function srNames(list, budget)
    local out, used = {}, 0
    for i, e in ipairs(list) do
        local n = U.ShortName(e.player) .. (((e.plus or 0) > 0) and (" (+" .. e.plus .. ")") or "")
        if used + #n + 2 > budget then
            out[#out + 1] = "+" .. (#list - i + 1)
            break
        end
        out[#out + 1] = n
        used = used + #n + 2
    end
    return concat(out, ", ")
end

--- Once per loot window, the SR host tells the raid who reserved what.
local function autoAnnounce(items, sig)
    if announcedSigs[sig] then return end
    if not hostingSession() or settings().srAutoAnnounce == false then return end
    announcedSigs[sig] = true
    local n = 0
    for _, it in ipairs(items) do
        local list = reservesFor(it.itemID)
        if #list > 0 and n < 4 then
            local head = linkOf(it.itemID, it.link) .. " - SR: "
            local line = head .. srNames(list, max(20, 250 - #head))
            -- spaced out rather than four lines in one frame (kinder to the chat throttle)
            if n == 0 then say(line, true) else GF:After(n * 0.4, function() say(line, true) end) end
            n = n + 1
        end
    end
end

local function rareOnly(items)
    local out = {}
    for _, it in ipairs(items) do
        if (it.q or 0) >= MIN_QUALITY then out[#out + 1] = it end
    end
    return out
end

GF:RegisterEvent("LOOT_OPENED", function(_, autoLoot, isFromItem)
    lootOpen = true
    if API.Clean(isFromItem) == true then return end
    local inside, info = lootContext()
    if not inside then return end
    local items = rareOnly(scanLootWindow())
    if #items == 0 then return end
    local boss = currentBoss()
    for _, it in ipairs(items) do Loot:Learn(it.itemID, it.link, it.q, boss, info.name) end
    if isDeskUser() then feedDesk(items, boss, info.name) end
    autoAnnounce(items, signature(items))
    if refreshDesk then refreshDesk() end
end)

GF:RegisterEvent("LOOT_CLOSED", function()
    lootOpen = false
    if refreshDesk then refreshDesk() end
end)

-------------------------------------------------------------------------------
-- Group-loot rolls: SR reminders + learning + desk feed
-------------------------------------------------------------------------------
local rollBatch = {}

local function flushRollBatch()
    local items = rollBatch
    rollBatch = {}
    if #items == 0 or not isDeskUser() then return end
    local _, info = lootContext()
    feedDesk(items, currentBoss(), info.name)
end

local function srPopup(itemID, link, rollID)
    if settings().srPopups == false then return end
    local list = reservesFor(itemID)
    if #list == 0 then return end
    local me = API.MyKey()
    local mine, others = false, {}
    for _, e in ipairs(list) do
        if e.player == me then mine = true else others[#others + 1] = e end
    end
    local l = linkOf(itemID, link)
    if mine then
        local text = "You SR'd " .. l .. " - smash NEED"
        if #others > 0 then text = text .. ". Up against " .. coloredNames(others, 3) .. "." end
        UI:Toast({ title = "Smash need", text = text, style = "green", icon = API.ItemIcon(itemID),
            key = "srpop:" .. tostring(rollID or itemID), duration = 10, sound = 8959 })
    else
        UI:Toast({ title = "Hands off", text = coloredNames(others, 4) .. " reserved " .. l .. ". Pass it.",
            style = "yellow", icon = API.ItemIcon(itemID), key = "srpop:" .. tostring(rollID or itemID), duration = 8 })
    end
end

GF:RegisterEvent("START_LOOT_ROLL", function(_, rollID)
    rollID = API.CleanNumber(rollID)
    if not rollID then return end
    local link = callClean("GetLootRollItemLink", rollID)
    if type(link) ~= "string" then return end
    local itemID = API.ItemID(link)
    if not itemID then return end
    groupRolls[itemID] = API.ServerTime()
    local q = qualityOf(itemID, link)
    local inside, info = lootContext()
    if inside then Loot:Learn(itemID, link, q, currentBoss(), info.name) end
    srPopup(itemID, link, rollID)
    if inside and (q or 0) >= MIN_QUALITY then
        rollBatch[#rollBatch + 1] = { itemID = itemID, link = link, q = q }
        GF:Debounce("loot-rollbatch", 1, flushRollBatch)
    end
end)

-------------------------------------------------------------------------------
-- Who actually received what (encounter loot + loot chat), recorded by one client
-------------------------------------------------------------------------------
local function noteReceived(itemID, key, link, q, boss, info, class)
    if not itemID or not key then return end
    local e = deskFindFor(itemID, key)
    if e and (not e.winner or e.winner == key) then
        e.state, e.winner = "awarded", key
        if refreshDesk then refreshDesk() end
    end
    if (q or 0) < MIN_QUALITY or not isRecorder() then return end
    local pend = pendingWins[itemID .. "|" .. key]
    local how
    if pend and API.ServerTime() - pend.t < 1800 then
        how = pend.how
        pendingWins[itemID .. "|" .. key] = nil
    else
        if info.type ~= "raid" or not inGuildGroup() then return end
        local gr = groupRolls[itemID]
        how = (gr and API.ServerTime() - gr < 600) and "ROLL" or "FREE"
    end
    local s = activeSession()
    Loot:Record({
        itemID = itemID, link = link, winner = key, how = how, boss = boss, instance = info.name,
        class = class, session = s and s.id or nil, feed = HOW[how].rank >= 3,
    })
end

GF:RegisterEvent("ENCOUNTER_LOOT_RECEIVED", function(_, encounterID, itemID, link, _, playerName, className)
    encounterID = API.CleanNumber(encounterID)
    itemID = API.CleanNumber(itemID)
    link = API.CleanString(link)
    playerName = API.CleanString(playerName)
    if not itemID or not playerName then return end
    local key = API.Key(playerName)
    local inside, info = lootContext()
    local boss = (encounterID and encounterNames()[encounterID]) or currentBoss()
    local q = qualityOf(itemID, link)
    if inside then Loot:Learn(itemID, link, q, boss, info.name) end
    noteReceived(itemID, key, link, q, boss, info, validClass(API.CleanString(className)))
end)

local lootPatterns
local function getLootPatterns()
    if lootPatterns then return lootPatterns end
    lootPatterns = {}
    local defs = {
        { "LOOT_ITEM_MULTIPLE", false }, { "LOOT_ITEM", false },
        { "LOOT_ITEM_SELF_MULTIPLE", true }, { "LOOT_ITEM_SELF", true },
    }
    for _, d in ipairs(defs) do
        local fmt = rawget(_G, d[1])
        if type(fmt) == "string" and fmt ~= "" and API.Readable(fmt) then
            lootPatterns[#lootPatterns + 1] = { pattern = toPattern(fmt), self = d[2] }
        end
    end
    return lootPatterns
end

-- Best-effort supplement: loot chat text is secret inside instances on Forever, in
-- which case it's skipped and ENCOUNTER_LOOT_RECEIVED / desk awards carry the load.
GF:RegisterEvent("CHAT_MSG_LOOT", function(_, msg)
    msg = API.CleanString(msg)
    if not msg then return end
    local inside, info = lootContext()
    if not inside then return end
    for _, p in ipairs(getLootPatterns()) do
        local a, b = msg:match(p.pattern)
        if a then
            local who, itemText
            if p.self then who, itemText = API.MyKey(), a else who, itemText = API.Key(a), b end
            local itemID = API.ItemID(itemText)
            if itemID and who then
                local link = itemText:match("(|c.-|r)") or nil
                local q = qualityOf(itemID, link)
                Loot:Learn(itemID, link, q, currentBoss(), info.name)
                noteReceived(itemID, who, link, q, currentBoss(), info, nil)
            end
            return
        end
    end
end)

-------------------------------------------------------------------------------
-- Shared window bits
-------------------------------------------------------------------------------
local function fail(msg)
    UI:Toast({ title = "Nah", text = msg or "That didn't work.", style = "red", icon = "warning", duration = 5 })
end

local function savePos(frame, key)
    local p, _, rp, x, y = frame:GetPoint(1)
    if p then prefs()[key] = { p, rp, x, y } end
end

local function restorePos(frame, key, dp, dx, dy)
    local pos = prefs()[key]
    frame:ClearAllPoints()
    if type(pos) == "table" and type(pos[1]) == "string" then
        frame:SetPoint(pos[1], UIParent, pos[2], tonumber(pos[3]) or 0, tonumber(pos[4]) or 0)
    else
        frame:SetPoint(dp, UIParent, dp, dx, dy)
    end
end

local function makeDraggable(frame, handle, key)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    handle:EnableMouse(true)
    handle:RegisterForDrag("LeftButton")
    handle:SetScript("OnDragStart", function() frame:StartMoving() end)
    handle:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        savePos(frame, key)
    end)
end

-------------------------------------------------------------------------------
-- Warcraft dressing: gold-framed windows, quality-framed item slots, gold bars
-------------------------------------------------------------------------------
local function tile(tex, path, r, g, b, a)
    tex:SetTexture(path, "REPEAT", "REPEAT")
    tex:SetHorizTile(true)
    tex:SetVertTile(true)
    tex:SetVertexColor(r, g, b, a)
end

local function gradient(tex, orient, r, g, b, a1, a2)
    tex:SetTexture(T.tex.white)
    if tex.SetGradient and CreateColor then
        tex:SetGradient(orient, CreateColor(r, g, b, a1), CreateColor(r, g, b, a2))
    else
        tex:SetColorTexture(r, g, b, (a1 + a2) / 2)
    end
end

--- A floating window in the game's own chrome: dark slate under worn stone, and a gold
-- 9-slice rim with ornate corners riding above the content (it never takes the mouse).
local function goldWindow(f, corner)
    UI:SetBackdrop(f, C.bg1, false)
    UI:Shadow(f, 18)
    f.slate = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    f.slate:SetPoint("TOPLEFT", 2, -2)
    f.slate:SetPoint("BOTTOMRIGHT", -2, 2)
    tile(f.slate, T.tex.stone, 0.5, 0.55, 0.52, 0.55)
    local chrome = CreateFrame("Frame", nil, f)
    chrome:SetPoint("TOPLEFT", -5, 5)
    chrome:SetPoint("BOTTOMRIGHT", 5, -5)
    chrome:SetFrameLevel(f:GetFrameLevel() + 30)
    chrome.rim = chrome:CreateTexture(nil, "OVERLAY")
    chrome.rim:SetAllPoints()
    UI.Sliced(chrome.rim, T.tex.frameGold, 16)
    for _, c in ipairs({ { "TOPLEFT", -3, 3, 0, 1, 0, 1 }, { "TOPRIGHT", 3, 3, 1, 0, 0, 1 },
                         { "BOTTOMLEFT", -3, -3, 0, 1, 1, 0 }, { "BOTTOMRIGHT", 3, -3, 1, 0, 1, 0 } }) do
        local t = chrome:CreateTexture(nil, "OVERLAY", nil, 1)
        t:SetTexture(T.tex.cornerGold)
        t:SetSize(corner or 28, corner or 28)
        t:SetPoint(c[1], chrome, c[1], c[2], c[3])
        t:SetTexCoord(c[4], c[5], c[6], c[7])
    end
    f.chrome = chrome
end

--- Leather title band with the ornate gold rule along its bottom edge.
local function leatherBand(parent, height)
    local h = CreateFrame("Frame", nil, parent)
    h:SetPoint("TOPLEFT", 2, -2)
    h:SetPoint("TOPRIGHT", -2, -2)
    h:SetHeight(height)
    h.bg = h:CreateTexture(nil, "BACKGROUND")
    h.bg:SetAllPoints()
    h.bg:SetColorTexture(C.bg1[1], C.bg1[2], C.bg1[3], 1)
    h.leather = h:CreateTexture(nil, "BACKGROUND", nil, 1)
    h.leather:SetAllPoints()
    tile(h.leather, T.tex.leather, 0.85, 0.8, 0.75, 0.9)
    h.shade = h:CreateTexture(nil, "BACKGROUND", nil, 2)
    h.shade:SetAllPoints()
    gradient(h.shade, "VERTICAL", 0, 0, 0, 0.35, 0)
    h.line = h:CreateTexture(nil, "ARTWORK")
    h.line:SetPoint("BOTTOMLEFT")
    h.line:SetPoint("BOTTOMRIGHT")
    h.line:SetHeight(2)
    h.line:SetColorTexture(C.bronze[1], C.bronze[2], C.bronze[3], 1)
    h.rule = h:CreateTexture(nil, "OVERLAY")
    h.rule:SetTexture(T.tex.dividerGold)
    h.rule:SetHeight(12)
    h.rule:SetPoint("LEFT", h.line, "LEFT", 0, 0)
    h.rule:SetPoint("RIGHT", h.line, "RIGHT", 0, 0)
    return h
end

--- Turns a kit ItemButton into a Warcraft item slot: the icon sits under a bevelled frame
-- tinted to the item's quality (gold while the quality is unknown or common), with an
-- optional soft quality glow behind it. Tooltip, shift-link and clicks are untouched.
local function dressItem(b, glow)
    local size = b:GetWidth() or 32
    local inset = max(2, floor(size * 0.09 + 0.5))
    b.icon:ClearAllPoints()
    b.icon:SetPoint("TOPLEFT", inset, -inset)
    b.icon:SetPoint("BOTTOMRIGHT", -inset, inset)
    b.qframe = b:CreateTexture(nil, "OVERLAY", nil, -1)
    b.qframe:SetAllPoints()
    UI.Sliced(b.qframe, T.tex.iconFrame, max(4, floor(size * 0.16)))
    if glow then
        b.qglow = b:CreateTexture(nil, "BACKGROUND", nil, -7)
        b.qglow:SetTexture(T.tex.glow)
        b.qglow:SetPoint("CENTER")
        b.qglow:SetSize(size * 1.8, size * 1.8)
        b.qglow:SetBlendMode("ADD")
        b.qglow:Hide()
    end
    local update = b.Update
    b.Update = function(self)
        update(self)
        self:SetBackdropBorderColor(0, 0, 0, 0)
        local q = self.itemID and (API.ItemQuality(self.link or self.itemID) or linkQuality(self.link) or self.qHint)
        q = type(q) == "number" and q or nil
        if q and q >= 2 then
            local r, g, bb = API.QualityColor(q)
            self.qframe:SetDesaturated(true)
            self.qframe:SetVertexColor(min(1, r * 1.1 + 0.12), min(1, g * 1.1 + 0.12), min(1, bb * 1.1 + 0.12), 1)
        else
            self.qframe:SetDesaturated(false)
            self.qframe:SetVertexColor(1, 1, 1, 1)
        end
        if self.qglow then
            if q and q >= 3 then
                local r, g, bb = API.QualityColor(q)
                self.qglow:SetVertexColor(r, g, bb, 0.30)
                self.qglow:Show()
            else
                self.qglow:Hide()
            end
        end
    end
    b:Update()
    return b
end

--- Countdown bar in a gold bevel (cast-bar style) with a spark riding the fill.
-- Same face as UI:Bar where the panel uses it: :SetValue(0..1), :SetColor(c).
local function goldBar(parent, height)
    local b = CreateFrame("Frame", nil, parent)
    b:SetHeight(height or 14)
    b.well = b:CreateTexture(nil, "BACKGROUND")
    b.well:SetPoint("TOPLEFT", 2, -2)
    b.well:SetPoint("BOTTOMRIGHT", -2, 2)
    b.well:SetColorTexture(0, 0, 0, 0.7)
    b.fill = b:CreateTexture(nil, "ARTWORK")
    b.fill:SetTexture(T.tex.bar)
    b.fill:SetPoint("TOPLEFT", 3, -3)
    b.fill:SetPoint("BOTTOMLEFT", 3, 3)
    b.spark = b:CreateTexture(nil, "ARTWORK", nil, 1)
    b.spark:SetTexture(T.tex.glow)
    b.spark:SetBlendMode("ADD")
    b.spark:SetSize(14, (height or 14) + 10)
    b.spark:SetPoint("CENTER", b.fill, "RIGHT", 0, 0)
    b.rim = b:CreateTexture(nil, "OVERLAY")
    b.rim:SetAllPoints()
    UI.Sliced(b.rim, T.tex.iconFrame, 5)
    b.value = 0
    function b:SetColor(c)
        c = UI.col(c)
        self.fill:SetVertexColor(c[1], c[2], c[3], 1)
        self.spark:SetVertexColor(c[1], c[2], c[3], 0.9)
    end
    function b:SetValue(v)
        self.value = U.Clamp(tonumber(v) or 0, 0, 1)
        local w = max(0, (self:GetWidth() or 0) - 6)
        self.fill:SetWidth(max(0.001, w * self.value))
        self.fill:SetShown(self.value > 0)
        self.spark:SetShown(self.value > 0 and self.value < 1)
    end
    b:SetScript("OnSizeChanged", function(self) self:SetValue(self.value) end)
    b:SetColor("green")
    return b
end

-------------------------------------------------------------------------------
-- Loot Desk (host / master looter / raid leader)
-------------------------------------------------------------------------------
local desk
local DESK_W, DROW_H, DESK_HEAD, DESK_FOOT = 540, 74, 56, 52
local ROW_GAP = 6
local shone = setmetatable({}, { __mode = "k" })   -- desk entry -> winner already celebrated

local function announceItem(e)
    local list = reservesFor(e.itemID)
    local link = linkOf(e.itemID, e.link)
    if #list == 0 then
        say(link .. " - no soft reserves. Main-spec roll coming up.")
    else
        local head = link .. " - SR'd by: "
        say(head .. srNames(list, max(20, 250 - #head)))
    end
end

local function findMLCandidate(e, key)
    local getCand = G("GetMasterLootCandidate")
    if not getCand then return nil end
    for slot = 1, numLootItems() do
        if slotHasItem(slot) and API.ItemID(slotLink(slot)) == e.itemID then
            for i = 1, 40 do
                local ok, name = pcall(getCand, slot, i)
                name = ok and API.CleanString(name) or nil
                if name and API.Key(name) == key then return slot, i end
            end
        end
    end
    return nil
end

--- Award(entry, playerKey): master-loot hand-over when available, else announce + record.
function Loot:Award(e, key)
    if type(e) ~= "table" or type(key) ~= "string" then return end
    if not canRunDesk() then return fail(DESK_DENIED) end
    local how
    if e.winner == key and e.how then
        how = e.how
    else
        for _, r in ipairs(reservesFor(e.itemID)) do
            if r.player == key then how = "SR" end
        end
        how = how or "FREE"
    end
    local link = linkOf(e.itemID, e.link)
    local function finish(viaML)
        e.state, e.winner, e.how = "awarded", key, how
        local s = activeSession()
        local _, info = lootContext()
        -- tell the group too: whoever records history then logs it with the right "how"
        -- instead of racing our doc with a FREE one when the item lands in their bags
        pendingWins[e.itemID .. "|" .. key] = { how = how, t = API.ServerTime(), link = e.link }
        Comm:Group("LW", { id = API.MyKey() .. ":" .. API.ServerTime() .. ":" .. e.itemID, itemID = e.itemID,
            winner = key, how = how, link = e.link, a = 1 }, "NORMAL")
        Loot:Record({
            itemID = e.itemID, link = e.link, winner = key, how = how,
            boss = deskInfo.boss or currentBoss(), instance = deskInfo.instance or info.name,
            class = GF.Roster:Class(key), session = s and s.id or nil, feed = true,
        })
        say(("%s -> %s%s. Grats!"):format(link, U.ShortName(key), how == "SR" and " (SR)" or ""), viaML)
        if refreshDesk then refreshDesk() end
    end
    if masterLootReady() and lootOpen then
        local slot, idx = findMLCandidate(e, key)
        if slot and idx then
            UI:Confirm("Hand it over?", ("Give %s to %s via master loot?"):format(link, GF.Roster:Colored(key)), function()
                local f = G("GiveMasterLoot")
                local ok = f and pcall(f, slot, idx)
                if ok then finish(true) else fail("Master loot said no. Try trading it instead.") end
            end, "Give it", "green")
            return
        end
    end
    finish(false)
end

local function awardMenu(anchor, e)
    local items = { { text = "Award to...", title = true } }
    local added = {}
    local function add(key, note)
        if type(key) ~= "string" or added[key] then return end
        added[key] = true
        items[#items + 1] = {
            text = U.ClassName(key, GF.Roster:Class(key)) .. (note and T:Wrap("faint", "  " .. note) or ""),
            func = function() Loot:Award(e, key) end,
        }
    end
    if e.winner then add(e.winner, e.value and ("rolled " .. e.value) or "winner") end
    for _, r in ipairs(reservesFor(e.itemID)) do add(r.player, "SR" .. (((r.plus or 0) > 0) and (" +" .. r.plus) or "")) end
    local others = {}
    for _, g in ipairs(GF.Roster:Group()) do
        if g.key and not added[g.key] then others[#others + 1] = g.key end
    end
    sort(others)
    if #others > 0 and #items > 1 then items[#items + 1] = { separator = true } end
    for _, k in ipairs(others) do add(k) end
    if #items == 1 then items[#items + 1] = { text = "Nobody here. Join a group first.", disabled = true } end
    UI:OpenMenu(anchor, items, { width = 210 })
end

local function deskButton(row, text, style, onClick, tip)
    return UI:Button(row, text, { style = style, height = 22, size = 10, tooltip = tip, onClick = function()
        if row.entry then onClick(row.entry, row) end
    end })
end

--- One drop on the desk, dressed like a loot slot: dark slate under a bronze rim, a wash
-- of the item's quality colour behind its framed icon, and a state bar down the left.
local function deskRow(parent)
    local r = CreateFrame("Frame", nil, parent)
    r:SetHeight(DROW_H)
    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetPoint("TOPLEFT", 2, -2)
    r.bg:SetPoint("BOTTOMRIGHT", -2, 2)
    r.bg:SetColorTexture(0.035, 0.045, 0.04, 0.82)
    r.wash = r:CreateTexture(nil, "BACKGROUND", nil, 1)
    r.wash:SetPoint("TOPLEFT", 2, -2)
    r.wash:SetPoint("BOTTOMLEFT", 2, 2)
    r.wash:SetWidth(240)
    r.rim = r:CreateTexture(nil, "BORDER")
    r.rim:SetAllPoints()
    UI.Sliced(r.rim, T.tex.frameBronze, 8)
    r.stripe = r:CreateTexture(nil, "ARTWORK")
    r.stripe:SetPoint("TOPLEFT", 3, -4)
    r.stripe:SetPoint("BOTTOMLEFT", 3, 4)
    r.stripe:SetWidth(3)
    r.item = dressItem(UI:ItemButton(r, 40), true)
    r.item:SetPoint("TOPLEFT", 12, -10)
    -- right edges hang off TOP points (a plain "RIGHT" is the row's middle and would
    -- stretch the text box down over the buttons)
    r.name = UI:Text(r, 13, "text", "ui")
    r.name:SetPoint("TOPLEFT", r.item, "TOPRIGHT", 10, -1)
    r.name:SetPoint("TOPRIGHT", r, "TOPRIGHT", -170, -11)
    r.who = UI:Text(r, 11, "dim")
    r.who:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 0, -4)
    r.who:SetPoint("TOPRIGHT", r.name, "BOTTOMRIGHT", 20, -4)
    r.dismiss = UI:IconButton(r, "close", 18, "Take it off the desk", function()
        if r.entry then Loot:RemoveFromDesk(r.entry) end
    end, "faint")
    r.dismiss:SetPoint("TOPRIGHT", -7, -7)
    r.status = UI:Text(r, 11, "faint", "head")
    r.status:SetPoint("TOPRIGHT", -30, -11)
    r.status:SetJustifyH("RIGHT")
    r.contested = UI:Pill(r, "CONTESTED", "yellow", { height = 16, size = 9, icon = "warning" })
    r.contested:SetPoint("TOPRIGHT", r.status, "BOTTOMRIGHT", 0, -4)

    r.bAnnounce = deskButton(r, "Announce", "secondary", announceItem,
        { "Announce", { "Posts the item and its reservers to group chat." } })
    r.bSR = deskButton(r, "Roll SR", "primary", function(e)
        local list = reservesFor(e.itemID)
        if #list == 1 then
            local ok, err = Loot:GiveToReserver(e.itemID, e.link, list[1].player)
            if not ok then fail(err) end
            return
        end
        local keys = {}
        for _, x in ipairs(list) do keys[#keys + 1] = x.player end
        local ok, err = Loot:StartRoll(e.itemID, e.link, "SR", keys)
        if not ok then fail(err) end
    end, { "Roll SR", { "Only the reservers may roll. One reserver? It's theirs, no roll needed." } })
    r.bMS = deskButton(r, "Roll MS", "secondary", function(e)
        local ok, err = Loot:StartRoll(e.itemID, e.link, "MS")
        if not ok then fail(err) end
    end, { "Main-spec roll", { "Everyone in the group, /roll 100, 20 seconds." } })
    r.bOS = deskButton(r, "Roll OS", "secondary", function(e)
        local ok, err = Loot:StartRoll(e.itemID, e.link, "OS")
        if not ok then fail(err) end
    end, { "Off-spec roll", { "Everyone in the group, /roll 100, 20 seconds." } })
    r.bAward = deskButton(r, "Award", "warn", function(e, row) awardMenu(row.bAward, e) end,
        { "Award", { "Pick who gets it. Uses master loot when it's on, otherwise announces and logs it." } })
    r.bAnnounce:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 62, 8)
    r.bSR:SetPoint("LEFT", r.bAnnounce, "RIGHT", 5, 0)
    r.bMS:SetPoint("LEFT", r.bSR, "RIGHT", 5, 0)
    r.bOS:SetPoint("LEFT", r.bMS, "RIGHT", 5, 0)
    r.bAward:SetPoint("LEFT", r.bOS, "RIGHT", 5, 0)
    return r
end

local function stripeColor(r, c)
    c = UI.col(c)
    r.stripe:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
end

local function updateDeskRow(row, e, can)
    row.entry = e
    row.item.qHint = e.q
    row.item:SetItem(e.link or e.itemID)
    row.name:SetText(coloredName(e.itemID, e.link, e.q))
    local qr, qg, qb = API.QualityColor(e.q or qualityOf(e.itemID, e.link) or 1)
    gradient(row.wash, "HORIZONTAL", qr, qg, qb, 0.16, 0)
    local list = reservesFor(e.itemID)
    if #list > 0 then
        row.who:SetText(T:Wrap("green", "SR  ") .. coloredNames(list, 5))
    else
        row.who:SetText(T:Wrap("faint", "No soft reserves. Fair game."))
    end
    row.contested:SetShown(#list >= 2)
    local r = roll
    local live = r and not r.done
    local thisRoll = r and r.itemID == e.itemID
    if e.state == "awarded" then
        row.status:SetText(T:Wrap("green", "TO ") .. U.ClassName(e.winner, GF.Roster:Class(e.winner)))
        stripeColor(row, "greenDim")
        row:SetAlpha(0.6)
    elseif thisRoll and live then
        local n = #r.order
        row.status:SetText(T:Wrap("yellow", "ROLLING") .. T:Wrap("faint", "  " .. n .. " in"))
        stripeColor(row, "yellow")
        row:SetAlpha(1)
    elseif e.state == "won" then
        row.status:SetText(T:Wrap("gold", "WON  ") .. U.ClassName(e.winner, GF.Roster:Class(e.winner)) .. (e.value and T:Wrap("dim", " " .. e.value) or ""))
        stripeColor(row, "wowGold")
        row:SetAlpha(1)
        -- one light sweep the first time this drop shows its winner
        if shone[e] ~= e.winner then
            shone[e] = e.winner
            UI:Shine(row, 0.9)
        end
    elseif thisRoll and r.done and r.reason == "none" then
        row.status:SetText(T:Wrap("faint", "NO TAKERS"))
        stripeColor(row, "line")
        row:SetAlpha(1)
    else
        row.status:SetText("")
        stripeColor(row, #list > 0 and "sign" or "line")
        row:SetAlpha(1)
    end
    -- the drop in play (being rolled, or won and waiting to be handed over) wears gold
    local prized = (thisRoll and live) or e.state == "won"
    if row.prized ~= prized then
        row.prized = prized
        if prized then UI.Sliced(row.rim, T.tex.frameGold, 16) else UI.Sliced(row.rim, T.tex.frameBronze, 8) end
    end
    -- spectators (anyone who isn't host / ML / lead) can look but not touch
    local open = e.state ~= "awarded" and can
    local grouped = API.InGroup()
    row.bSR:SetText(#list == 1 and "Give SR" or "Roll SR")
    row.bSR:SetActive(open and grouped and #list > 0 and not live)
    row.bMS:SetActive(open and grouped and not live)
    row.bOS:SetActive(open and grouped and not live)
    row.bAnnounce:SetActive(can and grouped)
    row.bAward:SetActive(open)
end

local function buildDesk()
    if desk then return desk end
    local f = CreateFrame("Frame", "GreenfieldsLootDesk", UIParent, "BackdropTemplate")
    f:Hide()
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetSize(DESK_W, 200)
    goldWindow(f, 30)
    tinsert(UISpecialFrames, "GreenfieldsLootDesk")

    -- leather title band; the guild's green street sign names the window, and the corpse
    -- it came off reads in the game's gold, the way the real loot frame titles itself
    local head = leatherBand(f, DESK_HEAD)
    -- the blank sign is 4:1, so a 4:1 plate keeps its white border and rounded corners true
    head.sign = head:CreateTexture(nil, "ARTWORK")
    head.sign:SetSize(144, 36)
    head.sign:SetPoint("LEFT", 18, 1)
    head.sign:SetTexture(T.tex.signGreen)
    head.icon = UI:Icon(head, 15, "bag", "OVERLAY", { 1, 1, 1, 1 })
    head.icon:SetPoint("LEFT", head.sign, "LEFT", 17, 1)
    f.title = UI:Text(head, 16, { 1, 1, 1, 1 }, "head")
    f.title:SetPoint("LEFT", head.icon, "RIGHT", 8, -1)
    f.title:SetText("LOOT DESK")
    -- right edges stop short of the MASTER LOOT pill and the close button
    f.heading = UI:Text(head, 14, "wowGold", "ui")
    f.heading:SetPoint("TOPLEFT", head.sign, "TOPRIGHT", 14, -2)
    f.heading:SetPoint("TOPRIGHT", head, "TOPRIGHT", -150, -11)
    f.sub = UI:Text(head, 11, "dim")
    f.sub:SetPoint("TOPLEFT", f.heading, "BOTTOMLEFT", 0, -4)
    f.sub:SetPoint("TOPRIGHT", f.heading, "BOTTOMRIGHT", 0, -4)
    f.close = UI:IconButton(head, "close", 24, "Close (Esc)", function() f:Hide() end)
    -- closed by hand (button or Esc): don't pop up again for the same corpse
    f:SetScript("OnHide", function() dismissedSig = deskInfo.sig end)
    f.close:SetPoint("RIGHT", -10, 1)
    f.ml = UI:Pill(head, "MASTER LOOT", "wowGold", { height = 18, size = 10, icon = "crown",
        tooltip = { "Master loot", { "Award hands items straight over while the loot window is open." } } })
    f.ml:SetPoint("RIGHT", f.close, "LEFT", -8, 0)
    makeDraggable(f, head, "deskPos")
    f.head = head

    f.rows = {}
    for i = 1, MAX_DESK do
        local row = deskRow(f)
        local y = -(DESK_HEAD + 10 + (i - 1) * (DROW_H + ROW_GAP))
        row:SetPoint("TOPLEFT", 12, y)
        row:SetPoint("TOPRIGHT", -12, y)
        row:Hide()
        f.rows[i] = row
    end
    f.empty = UI:Empty(f, "Nothing on the desk. Open a corpse with loot, or shift-click an item into the box below.", "bag")
    f.empty:ClearAllPoints()
    f.empty:SetPoint("TOP", 0, -DESK_HEAD - 14)
    f.empty:SetHeight(80)

    local foot = CreateFrame("Frame", nil, f)
    foot:SetPoint("BOTTOMLEFT", 12, 13)
    foot:SetPoint("BOTTOMRIGHT", -12, 13)
    foot:SetHeight(26)
    foot.rule = foot:CreateTexture(nil, "ARTWORK")
    foot.rule:SetTexture(T.tex.dividerGold)
    foot.rule:SetHeight(10)
    foot.rule:SetPoint("BOTTOMLEFT", foot, "TOPLEFT", -10, 3)
    foot.rule:SetPoint("BOTTOMRIGHT", foot, "TOPRIGHT", 10, 3)
    foot.rule:SetAlpha(0.7)
    f.input = UI:Input(foot, { placeholder = "Add an item: shift-click it or paste a link / ID", onEnter = function(text, box)
        local ok, err = Loot:AddToDesk(U.Trim(text))
        if not ok then return fail(err) end
        box:SetText("")
        box:RefreshPlaceholder()
    end })
    f.input:SetPoint("TOPLEFT")
    f.input:SetPoint("TOPRIGHT", -178, 0)
    if GF.SR and GF.SR.AddLinkTarget then GF.SR:AddLinkTarget(f.input) end
    f.add = UI:Button(foot, "Add", { width = 56, onClick = function()
        local ok, err = Loot:AddToDesk(U.Trim(f.input:GetText()))
        if not ok then return fail(err) end
        f.input:SetText("")
        f.input:RefreshPlaceholder()
    end })
    f.add:SetPoint("LEFT", f.input, "RIGHT", 6, 0)
    f.clear = UI:Button(foot, "Clear desk", { icon = "trash", onClick = function() Loot:ClearDesk() end })
    f.clear:SetPoint("TOPRIGHT")
    f.foot = foot

    restorePos(f, "deskPos", "RIGHT", -120, 40)
    desk = f
    return f
end

refreshDesk = function()
    local f = desk
    if not f or not f:IsShown() then return end
    local n = min(#deskItems, MAX_DESK)
    -- the corpse (or the instance) heads the window in gold; the rest sits under it
    local heading = deskInfo.boss or deskInfo.instance
    local bits = {}
    if deskInfo.boss and deskInfo.instance then bits[#bits + 1] = deskInfo.instance end
    local s = activeSession()
    if s then bits[#bits + 1] = "SR: " .. U.ChatSafe(s.title or "open") end
    local can = canRunDesk()
    if heading then
        f.heading:SetText(heading)
        f.sub:SetText(#bits > 0 and concat(bits, DOT) or (can and "You're the boss." or "Just looking."))
    elseif can then
        f.heading:SetText("Drops, reservers, rolls")
        f.sub:SetText(#bits > 0 and concat(bits, DOT) or "You're the boss.")
    else
        f.heading:SetText("Just looking")
        f.sub:SetText(#bits > 0 and concat(bits, DOT) or "The SR host, master looter or raid lead runs the show.")
    end
    f.ml:SetShown(masterLootReady())
    for i, row in ipairs(f.rows) do
        local e = deskItems[i]
        if e and i <= n then
            updateDeskRow(row, e, can)
            row:Show()
        else
            row.entry = nil
            row:Hide()
        end
    end
    f.empty:SetShown(n == 0)
    local body = n > 0 and (n * (DROW_H + ROW_GAP) + 14) or 116
    f:SetHeight(DESK_HEAD + body + DESK_FOOT)
end

function Loot:OpenDesk()
    buildDesk()
    dismissedSig = nil
    desk:Show()
    desk:Raise()
    if #deskItems == 0 and lootOpen then
        local items = rareOnly(scanLootWindow())
        if #items > 0 then
            local _, info = lootContext()
            feedDesk(items, currentBoss(), info.name)
            return
        end
    end
    refreshDesk()
end

function Loot:ToggleDesk()
    if desk and desk:IsShown() then desk:Hide() else self:OpenDesk() end
end

-------------------------------------------------------------------------------
-- Roll panel (everyone running Greenfields sees the live roll)
-------------------------------------------------------------------------------
local panel
local PANEL_W, ROLL_ROWS = 310, 8
local PANEL_HEAD, ROLL_TOP, ROLL_ROW_H, ROLL_ROW_GAP, WIN_H = 30, 128, 20, 2, 32
local KICKER = { SR = { "SR ROLL", "green" }, MS = { "MAIN-SPEC ROLL", "blue" }, OS = { "OFF-SPEC ROLL", "dim" } }

local function buildPanel()
    if panel then return panel end
    local f = CreateFrame("Frame", "GreenfieldsRollPanel", UIParent, "BackdropTemplate")
    f:Hide()
    f:SetFrameStrata("DIALOG")
    f:EnableMouse(true)
    f:SetSize(PANEL_W, 200)
    goldWindow(f, 24)
    makeDraggable(f, f, "rollPos")
    f.head = leatherBand(f, PANEL_HEAD)
    f.head:EnableMouse(false)
    f.kicker = UI:Text(f.head, 12, "green", "ui")
    f.kicker:SetPoint("LEFT", 12, 1)
    f.close = UI:IconButton(f.head, "close", 20, "Hide (the roll carries on)", function() f:Hide() end)
    f.close:SetPoint("RIGHT", -6, 1)
    f.item = dressItem(UI:ItemButton(f, 40), true)
    f.item:SetPoint("TOPLEFT", 14, -(PANEL_HEAD + 12))
    f.name = UI:Text(f, 13, "text", "ui")
    f.name:SetPoint("TOPLEFT", f.item, "TOPRIGHT", 10, -3)
    f.name:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -(PANEL_HEAD + 15))
    f.who = UI:Text(f, 11, "dim")
    f.who:SetPoint("TOPLEFT", f.name, "BOTTOMLEFT", 0, -5)
    f.who:SetPoint("TOPRIGHT", f.name, "BOTTOMRIGHT", 0, -5)
    f.bar = goldBar(f, 14)
    f.bar:SetPoint("TOPLEFT", 12, -(PANEL_HEAD + 64))
    f.bar:SetPoint("TOPRIGHT", -12, -(PANEL_HEAD + 64))
    f.count = UI:Text(f, 10, "dim", "head")
    f.count:SetPoint("TOPLEFT", f.bar, "BOTTOMLEFT", 2, -5)
    f.time = UI:Text(f, 12, "wowGold", "num")
    f.time:SetPoint("TOPRIGHT", f.bar, "BOTTOMRIGHT", -2, -4)
    f.rows = {}
    for i = 1, ROLL_ROWS do
        local r = CreateFrame("Frame", nil, f)
        local y = -ROLL_TOP - (i - 1) * (ROLL_ROW_H + ROLL_ROW_GAP)
        r:SetHeight(ROLL_ROW_H)
        r:SetPoint("TOPLEFT", 12, y)
        r:SetPoint("TOPRIGHT", -12, y)
        r.bg = UI:Tex(r, "BACKGROUND", C.bg3)
        r.bg:SetAllPoints()
        r.rank = UI:Text(r, 11, "bronze", "num")
        r.rank:SetPoint("LEFT", 7, 0)
        r.crown = UI:Icon(r, 12, "crown", "OVERLAY", "wowGold")
        r.crown:SetPoint("CENTER", r, "LEFT", 10, 0)
        r.name = UI:Text(r, 12, "text")
        r.name:SetPoint("LEFT", 26, 0)
        r.name:SetPoint("RIGHT", -44, 0)
        r.value = UI:Text(r, 13, "text", "num")
        r.value:SetPoint("RIGHT", -8, 0)
        r.value:SetJustifyH("RIGHT")
        r:Hide()
        f.rows[i] = r
    end
    -- the verdict: a gold-rimmed plaque; a winner gets the crown and a light sweep
    local win = CreateFrame("Frame", nil, f)
    win:SetHeight(WIN_H)
    win.bg = win:CreateTexture(nil, "BACKGROUND")
    win.bg:SetPoint("TOPLEFT", 2, -2)
    win.bg:SetPoint("BOTTOMRIGHT", -2, 2)
    win.bg:SetColorTexture(0, 0, 0, 0.55)
    win.glow = win:CreateTexture(nil, "BACKGROUND", nil, 1)
    win.glow:SetPoint("TOPLEFT", 2, -2)
    win.glow:SetPoint("BOTTOMRIGHT", -2, 2)
    win.rim = win:CreateTexture(nil, "BORDER")
    win.rim:SetAllPoints()
    UI.Sliced(win.rim, T.tex.iconFrame, 6)
    win.crown = UI:Icon(win, 16, "crown", "ARTWORK", "wowGold")
    win.crown:SetPoint("LEFT", 10, 0)
    win:Hide()
    f.win = win
    f.result = UI:Text(win, 13, "text", "ui")
    f.result:SetPoint("LEFT", 34, 0)
    f.result:SetPoint("RIGHT", -10, 0)
    f.btnRoll = UI:Button(f, "Roll", { style = "primary", icon = "dice", height = 24, onClick = function() Loot:DoRoll() end })
    f.btnEnd = UI:Button(f, "End now", { height = 24, onClick = function() Loot:EndRollNow() end })
    f.btnCancel = UI:Button(f, "Cancel", { style = "danger", height = 24, onClick = function() Loot:CancelRoll() end })
    restorePos(f, "rollPos", "TOP", 0, -220)
    panel = f
    return f
end

local function resultText(r)
    if r.reason == "tie" then return T:Wrap("yellow", "Tie! Reroll incoming...") end
    if r.reason == "none" then return T:Wrap("dim", "Nobody rolled. Free real estate.") end
    if r.reason == "cancelled" then return T:Wrap("dim", "Roll cancelled.") end
    if r.reason == "timeout" then return T:Wrap("dim", "Lost the host. Check chat for the result.") end
    if r.winner then
        return T:Wrap("gold", "Winner  ") .. U.ClassName(r.winner, GF.Roster:Class(r.winner))
            .. (r.winRoll and T:Wrap("gold", "  " .. r.winRoll) or "")
    end
    return ""
end

refreshPanel = function(fast)
    local f = panel
    if not f then return end
    local r = roll
    if not r then f:Hide() return end
    if not f:IsShown() then return end
    local left = max(0, timeLeft(r))
    f.bar:SetValue((not r.done and r.duration > 0) and (left / r.duration) or 0)
    f.bar:SetColor(left <= 5 and "yellow" or "green")
    f.time:SetText(r.done and "" or (ceil(left) .. "s"))
    if fast then return end
    local kick = KICKER[r.how] or KICKER.MS
    f.kicker:SetText((r.tie and "REROLL  " or "") .. kick[1])
    UI:SetTextColor(f.kicker, kick[2])
    f.item.qHint = linkQuality(r.link)
    f.item:SetItem(r.link or r.itemID)
    f.name:SetText(coloredName(r.itemID, r.link))
    if r.eligibleList then
        local list = {}
        for _, k in ipairs(r.eligibleList) do list[#list + 1] = { player = k, class = GF.Roster:Class(k) } end
        f.who:SetText(T:Wrap("faint", "Only ") .. coloredNames(list, 5))
    else
        f.who:SetText(T:Wrap("faint", "Everyone: /roll 100"))
    end
    local rolls = sortedRolls(r)
    f.count:SetText(#rolls .. " " .. U.Plural(#rolls, "ROLL", "ROLLS"))
    local me = API.MyKey()
    local shown = min(#rolls, ROLL_ROWS)
    for i, row in ipairs(f.rows) do
        local e = rolls[i]
        if e and i <= shown then
            local lead = i == 1
            -- the leader wears the crown instead of a number
            row.rank:SetText(lead and "" or i)
            row.crown:SetShown(lead)
            row.name:SetText(U.ClassName(e.key, GF.Roster:Class(e.key)) .. (e.key == me and T:Wrap("faint", "  (you)") or ""))
            row.value:SetText(e.n)
            UI:SetTextColor(row.value, lead and "wowGold" or "text")
            if lead then
                gradient(row.bg, "HORIZONTAL", C.wowGold[1], C.wowGold[2], C.wowGold[3], 0.18, 0.04)
            else
                row.bg:SetColorTexture(0, 0, 0, 0.35)
            end
            row:Show()
        else
            row:Hide()
        end
    end
    local y = ROLL_TOP + shown * (ROLL_ROW_H + ROLL_ROW_GAP) + 4
    local win = f.win
    win:ClearAllPoints()
    win:SetPoint("TOPLEFT", 12, -y)
    win:SetPoint("TOPRIGHT", -12, -y)
    local verdict = r.done and resultText(r) or ""
    f.result:SetText(verdict)
    win:SetShown(verdict ~= "")
    if verdict ~= "" then
        local crowned = r.winner ~= nil and r.reason == nil
        win.crown:SetShown(crowned)
        f.result:SetPoint("LEFT", crowned and 34 or 12, 0)
        if crowned then
            win.rim:SetVertexColor(1, 1, 1, 1)
            gradient(win.glow, "HORIZONTAL", C.wowGold[1], C.wowGold[2], C.wowGold[3], 0.20, 0.02)
            -- one sweep per result, not one per redraw
            local key = tostring(r.id) .. ":" .. tostring(r.winner)
            if win.shone ~= key then
                win.shone = key
                UI:Shine(win, 0.9)
            end
        else
            win.rim:SetVertexColor(0.7, 0.55, 0.35, 0.8)
            win.glow:SetColorTexture(0, 0, 0, 0)
        end
        y = y + WIN_H + 6
    end
    local canRoll = not r.done and Loot:CanRoll() and me and not r.rolls[me] and (not r.eligible or r.eligible[me])
    local isHost = r.host == me and not r.done
    f.btnRoll:SetShown(canRoll and true or false)
    f.btnEnd:SetShown(isHost)
    f.btnCancel:SetShown(isHost)
    local prev
    for _, b in ipairs({ f.btnRoll, f.btnEnd, f.btnCancel }) do
        b:ClearAllPoints()
        if b:IsShown() then
            if prev then b:SetPoint("LEFT", prev, "RIGHT", 6, 0) else b:SetPoint("TOPLEFT", 12, -y) end
            prev = b
        end
    end
    if prev then y = y + 24 + 8 end
    f:SetHeight(y + 8)
end

showPanel = function()
    buildPanel()
    panel:Show()
    panel:Raise()
    refreshPanel()
end

-------------------------------------------------------------------------------
-- Item tooltips: "Soft-reserved by" + "Drops in" (cached per itemID)
-------------------------------------------------------------------------------
local function tooltipLines(itemID)
    local c = tipCache[itemID]
    if c then return c end
    c = {}
    local list = reservesFor(itemID)
    if #list > 0 then
        local names = {}
        for _, e in ipairs(list) do
            names[#names + 1] = U.ClassName(e.player, e.class) .. (((e.plus or 0) > 0) and T:Wrap("green", " (+" .. e.plus .. ")") or "")
        end
        c.sr = T:Wrap("green", "Soft-reserved by: ") .. concat(names, ", ")
    end
    local e = Loot:CatalogEntry(itemID)
    if e and e.i then
        c.drop = "Drops in: " .. e.i .. (e.b and (" (" .. e.b .. ")") or "")
    end
    tipCache[itemID] = c
    return c
end

local function onItemTooltip(tooltip, data)
    if settings().tooltipSR == false or type(tooltip) ~= "table" then return end
    if tooltip ~= rawget(_G, "GameTooltip") and tooltip ~= rawget(_G, "ItemRefTooltip") then return end
    local itemID = type(data) == "table" and API.CleanNumber(data.id) or nil
    if not itemID and tooltip.GetItem then
        local ok, _, link = pcall(tooltip.GetItem, tooltip)
        if ok then itemID = API.ItemID(API.CleanString(link)) end
    end
    if not itemID then return end
    local c = tooltipLines(itemID)
    if c.sr then tooltip:AddLine(c.sr, 1, 1, 1, true) end
    if c.drop then tooltip:AddLine(c.drop, C.faint[1], C.faint[2], C.faint[3], true) end
end

-------------------------------------------------------------------------------
-- Loot Log page
-------------------------------------------------------------------------------
local logPage
local SIDE_W = 270

local function q(v)
    v = tostring(v or "")
    if v:find('[,"\r\n]') then v = '"' .. (v:gsub('"', '""')) .. '"' end
    return v
end

local function exportHistory()
    local lines = { "Date,Item,ItemId,Winner,How,Boss,Instance" }
    for _, e in ipairs(allHistory()) do
        lines[#lines + 1] = concat({ date("%Y-%m-%d %H:%M", e.t), q(nameOf(e.itemID, e.link) or ""), e.itemID,
            q(U.ShortName(e.winner)), e.how, q(e.boss), q(e.instance) }, ",")
    end
    UI:CopyBox("Export loot history", concat(lines, "\n"), nil, "Every receipt we've got. Ctrl+C to copy.")
end

-- the stored link already carries the quality; asking the client instead would queue a
-- server lookup for every uncached item in a 400-day history on every refresh
local function entryQuality(e)
    return linkQuality(e.link) or qualityOf(e.itemID, e.link) or 0
end

--- Server time of local midnight on the Wednesday this week started (U.WeekKey's
-- bucket), so "this week" is one comparison per entry instead of two date() tables.
local function weekStart()
    local now = API.ServerTime()
    local t = date("*t", now)
    if type(t) ~= "table" then return nil end
    local back = (t.wday - 4) % 7
    local ok, ts = pcall(time, { year = t.year, month = t.month, day = t.day - back, hour = 0, min = 0, sec = 0 })
    return (ok and type(ts) == "number") and ts or nil
end

local function logRowCreate(row)
    row.btn = dressItem(UI:ItemButton(row, 28))
    row.btn:SetPoint("LEFT", 4, 0)
    row.name = UI:Text(row, 12, "text")
    row.name:SetPoint("TOPLEFT", row.btn, "TOPRIGHT", 10, -1)
    row.name:SetPoint("TOPRIGHT", row, "TOPRIGHT", -170, -5)
    row.sub = UI:Text(row, 11, "dim")
    row.sub:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -3)
    row.sub:SetPoint("TOPRIGHT", row.name, "BOTTOMRIGHT", 0, -3)
    row.ago = UI:Text(row, 11, "faint")
    row.ago:SetPoint("RIGHT", -12, 0)
    row.ago:SetWidth(80)
    row.ago:SetJustifyH("RIGHT")
    row.how = UI:Pill(row, "", "green", { height = 18, size = 10 })
    row.how:SetPoint("RIGHT", -100, 0)
end

local function logRowUpdate(row, e)
    row.btn.qHint = entryQuality(e)
    row.btn:SetItem(e.link or e.itemID)
    row.name:SetText(coloredName(e.itemID, e.link))
    local where = e.boss and (e.boss .. (e.instance and (DOT .. e.instance) or "")) or (e.instance or "Out in the wild")
    row.sub:SetText(U.ClassName(e.winner, e.class or GF.Roster:Class(e.winner)) .. T:Wrap("faint", DOT .. where))
    local meta = HOW[e.how] or HOW.FREE
    row.how:SetText(meta.label, meta.color)
    row.ago:SetText(U.Ago(e.t))
end

local function logRowEnter(row, e)
    if not GameTooltip then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    if e.link then pcall(GameTooltip.SetHyperlink, GameTooltip, e.link) else pcall(GameTooltip.SetItemByID, GameTooltip, e.itemID) end
    local meta = HOW[e.how] or HOW.FREE
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("Won by", U.ClassName(e.winner, e.class or GF.Roster:Class(e.winner)), 0.6, 0.67, 0.63, 1, 1, 1)
    GameTooltip:AddDoubleLine("How", meta.label .. " - " .. meta.tip, 0.6, 0.67, 0.63, 1, 1, 1)
    GameTooltip:AddDoubleLine("When", U.DateTime(e.t), 0.6, 0.67, 0.63, 1, 1, 1)
    if e.by and e.by ~= e.winner then
        GameTooltip:AddDoubleLine("Logged by", U.ShortName(e.by), 0.6, 0.67, 0.63, 1, 1, 1)
    end
    GameTooltip:AddLine("Right-click for options", C.faint[1], C.faint[2], C.faint[3])
    GameTooltip:Show()
end

local function logRowClick(e, row, button)
    if button ~= "RightButton" then return end
    local items = { { text = coloredName(e.itemID, e.link), title = true } }
    items[#items + 1] = { text = "Link in chat", icon = "bubble", func = function() UI:InsertLink(linkOf(e.itemID, e.link)) end }
    items[#items + 1] = { text = "Whisper " .. U.ShortName(e.winner), icon = "bubble", func = function() UI:Whisper(e.winner) end }
    if Loot:CanDelete(e) then
        items[#items + 1] = { separator = true }
        items[#items + 1] = { text = "Delete this entry", icon = "trash", color = "red", func = function()
            UI:Confirm("Delete this receipt?", "Removes it from everyone's Loot Log. The bin chickens will deny everything.", function()
                if not Loot:Delete(e.id) then fail("Only officers or whoever logged it can delete it.") end
            end, "Delete", "red")
        end }
    end
    UI:OpenMenu(nil, items, { width = 210 })
end

local function chickenRow(parent, i)
    local r = CreateFrame("Frame", nil, parent)
    r:SetHeight(30)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * 32)
    r:SetPoint("TOPRIGHT", 0, -(i - 1) * 32)
    -- the top spot gets a faint gold wash behind it (and the crown)
    r.lead = r:CreateTexture(nil, "BACKGROUND")
    r.lead:SetAllPoints()
    gradient(r.lead, "HORIZONTAL", C.wowGold[1], C.wowGold[2], C.wowGold[3], 0.14, 0)
    r.lead:Hide()
    r.rank = UI:Text(r, 14, "bronze", "num")
    r.rank:SetPoint("LEFT", 2, 0)
    r.rank:SetWidth(18)
    r.crown = UI:Icon(r, 14, "crown", "OVERLAY", "wowGold")
    r.crown:SetPoint("CENTER", r.rank, "CENTER", 0, 0)
    -- class icon in a gold slot frame
    r.icon = UI:FramedIcon(r, 22)
    r.icon:SetPoint("LEFT", 24, 0)
    function r.icon:SetClass(classFile)
        API.SetClassIcon(self.icon, classFile)
        self.icon:SetVertexColor(1, 1, 1, 1)
    end
    r.name = UI:Text(r, 12, "text", "head")
    r.name:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 8, 1)
    r.name:SetPoint("TOPRIGHT", r, "TOPRIGHT", -40, -3)
    r.bar = UI:Bar(r, { height = 4, color = "yellow" })
    r.bar:SetPoint("BOTTOMLEFT", r.icon, "BOTTOMRIGHT", 8, 0)
    r.bar:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -40, 5)
    r.n = UI:Text(r, 16, "text", "num")
    r.n:SetPoint("RIGHT", -2, 0)
    r.n:SetJustifyH("RIGHT")
    r:Hide()
    return r
end

local function statTile(parent, x, y, label, icon)
    local t = CreateFrame("Frame", nil, parent)
    t:SetSize(110, 40)
    t:SetPoint("TOPLEFT", x, y)
    -- our line icon, small and centred in a gold slot (full-bleed it shouts)
    t.icon = UI:FramedIcon(t, 28, icon)
    t.icon:SetPoint("TOPLEFT", 0, -3)
    t.icon.icon:ClearAllPoints()
    t.icon.icon:SetPoint("CENTER")
    t.icon.icon:SetSize(15, 15)
    t.icon.well:ClearAllPoints()
    t.icon.well:SetPoint("TOPLEFT", 3, -3)
    t.icon.well:SetPoint("BOTTOMRIGHT", -3, 3)
    t.n = UI:Text(t, 22, "text", "num")
    t.n:SetPoint("TOPLEFT", t.icon, "TOPRIGHT", 8, 3)
    t.l = UI:Text(t, 10, "bronze", "head")
    t.l:SetPoint("TOPLEFT", t.n, "BOTTOMLEFT", 0, -2)
    t.l:SetText(label:upper())
    return t
end

local function instFilterItems()
    local out = { { value = "", text = "All places" } }
    local seen = {}
    for _, e in ipairs(allHistory()) do
        if e.instance and not seen[e.instance] then
            seen[e.instance] = true
            out[#out + 1] = { value = e.instance, text = e.instance }
        end
    end
    -- strict ordering ("All places" first): cmp(x, x) must be false for table.sort
    sort(out, function(a, b)
        local ea, eb = a.value == "", b.value == ""
        if ea ~= eb then return ea end
        return a.text < b.text
    end)
    return out
end

local function howFilterItems()
    local out = { { value = "", text = "Any way" } }
    for _, k in ipairs(HOW_ORDER) do
        out[#out + 1] = { value = k, text = HOW[k].label .. T:Wrap("faint", "  " .. HOW[k].tip), color = HOW[k].color }
    end
    return out
end

local function whoFilterItems()
    local out = { { value = "", text = "Everyone" } }
    for _, row in ipairs(Loot:Leaderboard()) do
        out[#out + 1] = { value = row.key, text = U.ClassName(row.key, GF.Roster:Class(row.key)) .. T:Wrap("faint", "  " .. row.n) }
    end
    return out
end

local function buildLog(page)
    logPage = page
    page.f = { inst = "", how = "", who = "", q = "" }
    local header = UI:PageHeader(page, "Loot Log", "Who got what. Receipts for the bin chickens.")
    page.header = header
    header:AddAction(UI:Button(header, "Export", { icon = "export", onClick = exportHistory,
        tooltip = { "Export", { "Copy the whole loot history as CSV." } } }))
    header:AddAction(UI:Button(header, "Loot desk", { icon = "bag", onClick = function() Loot:OpenDesk() end }))

    local bar = CreateFrame("Frame", nil, page)
    bar:SetHeight(26)
    bar:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -8)
    bar:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -8)
    page.search = UI:Search(bar, { width = 200, placeholder = "Search loot, players, bosses...",
        onChange = function(text) page.f.q = text; page.refresh() end })
    page.search:SetPoint("LEFT")
    local function dd(width, items, field)
        return UI:Dropdown(bar, { width = width, items = items,
            get = function() return page.f[field] end,
            set = function(v) page.f[field] = v or ""; page.refresh() end })
    end
    page.fInst = dd(150, instFilterItems, "inst")
    page.fInst:SetPoint("LEFT", page.search, "RIGHT", 8, 0)
    page.fHow = dd(110, howFilterItems, "how")
    page.fHow:SetPoint("LEFT", page.fInst, "RIGHT", 8, 0)
    page.fWho = dd(150, whoFilterItems, "who")
    page.fWho:SetPoint("LEFT", page.fHow, "RIGHT", 8, 0)

    local nums = UI:Card(page, { title = "The numbers", icon = "coin" })
    nums:SetPoint("BOTTOMRIGHT")
    nums:SetSize(SIDE_W, 128)
    nums.items = statTile(nums.body, 0, 0, "Items", "bag")
    nums.sr = statTile(nums.body, 124, 0, "Off SR", "dice")
    nums.week = statTile(nums.body, 0, -44, "This week", "calendar")
    nums.epics = statTile(nums.body, 124, -44, "Epics", "star_fill")
    page.nums = nums

    local side = UI:Card(page, { title = "Bin Chicken Watch", icon = "trophy", accent = "yellow", subtitle = "items per main" })
    side:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT", 0, -12)
    side:SetPoint("BOTTOMRIGHT", nums, "TOPRIGHT", 0, 16)
    side:SetWidth(SIDE_W)
    side.rows = {}
    for i = 1, 10 do side.rows[i] = chickenRow(side.body, i) end
    side.empty = UI:Empty(side.body, "No bin chickens spotted yet. Give it one raid.", "trophy")
    side.empty:SetWidth(SIDE_W - 30)
    side.empty.text:SetWidth(SIDE_W - 40)
    page.side = side

    local hist = UI:Card(page, { title = "Loot history", icon = "bag" })
    hist:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -12)
    hist:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -(SIDE_W + 16), 0)
    hist.count = UI:Text(hist.right, 11, "faint", "head")
    hist.count:SetPoint("RIGHT", -4, 0)
    hist.list = UI:List(hist.body, {
        rowHeight = 34, createRow = logRowCreate, updateRow = logRowUpdate,
        onEnter = logRowEnter, onClick = logRowClick,
        isSelected = function(e) return e.winner == API.MyKey() end,
    })
    hist.list:SetAllPoints()
    hist.empty = UI:Empty(hist.body, GF.Flavor.emptyStates.loot, "bag")
    page.hist = hist
end

local function matches(e, f)
    if f.inst ~= "" and e.instance ~= f.inst then return false end
    if f.how ~= "" and e.how ~= f.how then return false end
    if f.who ~= "" and mainOf(e.winner) ~= f.who then return false end
    if f.q ~= "" then
        return U.Matches(linkName(e.link) or nameOf(e.itemID, e.link), f.q) or U.Matches(e.winner, f.q)
            or U.Matches(e.boss, f.q) or U.Matches(e.instance, f.q)
    end
    return true
end

local function refreshLog()
    local page = logPage
    if not page then return end
    local f = page.f
    local all = allHistory()
    local rows, place = {}, {}
    local srN, weekN, epicN = 0, 0, 0
    local since = weekStart()
    local thisWeek = not since and U.WeekKey() or nil
    for _, e in ipairs(all) do
        if f.inst == "" or e.instance == f.inst then place[#place + 1] = e end
        if matches(e, f) then
            rows[#rows + 1] = e
            if e.how == "SR" then srN = srN + 1 end
            if (since and e.t >= since) or (thisWeek and U.WeekKey(e.t) == thisWeek) then weekN = weekN + 1 end
            if entryQuality(e) >= 4 then epicN = epicN + 1 end
        end
    end
    local hist = page.hist
    hist.list:SetItems(rows, true)
    hist.count:SetText(#rows .. " " .. U.Plural(#rows, "ITEM", "ITEMS"))
    if #rows == 0 then
        hist.empty:SetText(#all == 0 and GF.Flavor.emptyStates.loot or "Nothing matches. The receipts don't lie.")
        hist.empty:Show()
    else
        hist.empty:Hide()
    end
    page.nums.items.n:SetText(#rows)
    page.nums.sr.n:SetText(srN)
    page.nums.week.n:SetText(weekN)
    page.nums.epics.n:SetText(epicN)
    UI:SetTextColor(page.nums.epics.n, epicN > 0 and "purple" or "text")

    -- leaderboard follows the place filter only, so it's the real pecking order
    local board = Loot:Leaderboard(place)
    local side = page.side
    local fit = max(1, floor(((side.body:GetHeight() or 0) + 2) / 32))
    local top = board[1] and board[1].n or 1
    local shown = 0
    for i, row in ipairs(side.rows) do
        local b = board[i]
        if b and i <= fit then
            shown = shown + 1
            local cls = GF.Roster:Class(b.key)
            row.rank:SetText(i == 1 and "" or i)
            row.crown:SetShown(i == 1)
            row.lead:SetShown(i == 1)
            row.icon:SetClass(cls)
            row.name:SetText(U.ClassName(b.key, cls))
            row.bar:SetValue(b.n / max(1, top))
            row.bar:SetColor(i == 1 and "wowGold" or "bronze")
            row.n:SetText(b.n)
            UI:SetTextColor(row.n, i == 1 and "wowGold" or "text")
            row:Show()
            -- a new top bin chicken gets one light sweep across the crown row
            if i == 1 and side.crowned ~= b.key then
                side.crowned = b.key
                UI:Shine(row, 0.9)
            end
        else
            row:Hide()
        end
    end
    side.empty:SetShown(shown == 0)
    page.fInst:Refresh()
    page.fHow:Refresh()
    page.fWho:Refresh()
end

UI:RegisterPage({
    key = "loot", title = "Loot Log", subtitle = "Who got what. Receipts for the bin chickens.",
    icon = "bag", group = "raid", order = 30,
    build = function(page)
        buildLog(page)
        page.refresh = refreshLog
        page.side:HookScript("OnSizeChanged", function() GF:Debounce("loot-log-size", 0.1, refreshLog) end)
    end,
    onShow = function() refreshLog() end,
})

-------------------------------------------------------------------------------
-- Wiring
-------------------------------------------------------------------------------
function Loot:OnLogin()
    -- pre-create the floating windows hidden (gamepad navigation hooks CreateFrame)
    buildDesk()
    buildPanel()
    API.TooltipPostCall("Item", onItemTooltip)
end

GF:On("GF_SR_UPDATED", function()
    tipCache = {}
    if refreshDesk then refreshDesk() end
    if refreshPanel and roll then refreshPanel() end
end)

GF:On("GF_ROSTER_UPDATED", function() statCache, mainMemo = nil, {} end)

-- a profile's declared main changes who an alt's loot rolls up to
GF:On("GF_STORE_CHANGED", function(name)
    if name == "profile" then statCache, mainMemo = nil, {} end
end)

GF:On("GF_GROUP_UPDATED", function()
    if refreshDesk then refreshDesk() end
end)

-- Fires for every item the client loads anywhere (bags, AH, other addons). Only redraw
-- what's on screen, and never for a failed load: the redraw would ask again and fail
-- again, forever.
GF:RegisterEvent("GET_ITEM_INFO_RECEIVED", function(_, _, success)
    if API.Clean(success) == false then return end
    local visible = (desk and desk:IsShown()) or (panel and panel:IsShown())
        or (UI:IsMainShown() and UI:CurrentPage() == "loot")
    if not visible then return end
    GF:Debounce("loot-iteminfo", 0.5, function()
        if refreshDesk then refreshDesk() end
        if refreshPanel and roll then refreshPanel() end
        UI:RefreshPage("loot")
    end)
end)

GF:RegisterSlash("desk", function() Loot:ToggleDesk() end, "open or close the Loot Desk")
GF:RegisterSlash("loot", function() UI:OpenMain("loot") end, "open the Loot Log")
