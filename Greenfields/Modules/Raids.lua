--[[ Greenfields - Modules/Raids.lua
     Raid Nights, the data side. Officers put raids on the calendar ("events"), everyone
     answers with a signup ("signups": one doc per main per raid), and officers save a
     lineup (groups + bench) back into the event doc. This file owns both datasets and the
     public GF.Raids API that Home, the header pill and the minimap tooltip read. It also
     runs raid reminders and the officer "nudge", and holds the raid-time tools the page
     calls: invite the signed, sort the groups, post the lineup.

       events   "e<time>-<n>-<hash>"   { title, instance, size, time, duration, notes, leader,
                                          srLimit, lineup = { groups = {{keys}}, bench = {keys} },
                                          created, cancelled }
       signups  eventId.."|"..mainKey  { event, player (main), char (the toon coming), class,
                                          role, status, note, t }

     Times are server epoch seconds; the page shows them in local time. Lineups hold
     character keys (the toon that turns up), never mains. Every value written here is
     either typed in by the player or read through GF.API, so nothing secret is stored. ]]

local _, GF = ...
local API, U, T = GF.API, GF.Util, GF.Theme
local Store, Comm = GF.Store, GF.Comm

local Raids = GF:NewModule("Raids")
GF.Raids = Raids

local type, pairs, ipairs, tostring, tonumber, rawget, pcall = type, pairs, ipairs, tostring, tonumber, rawget, pcall
local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min
local tsort, concat = table.sort, table.concat

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------
local DEFAULT_DURATION = 10800
local KEEP_LISTED = 3 * 3600        -- Upcoming() keeps a raid this long after the pull
local CURRENT_LEAD = 1800           -- Current() starts half an hour before the pull
local RAID_LEVEL = 55               -- "should be raiding" line for the not-answered list
local NUDGE_COOLDOWN = 600          -- an officer can poke the guild once per raid per 10 min
local NUDGE_SHOW_GAP = 1800         -- and we show at most one poke per raid per half hour
local MAX_TITLE, MAX_NOTES, MAX_NOTE = 40, 160, 60

Raids.DEFAULT_DURATION = DEFAULT_DURATION

--- Launch raids (FOREVER_FACTS F.1), plus "Other" for anything else the guild gets up to.
Raids.INSTANCES = {
    { name = "Barrow Deeps", size = 10, color = "blue" },
    { name = "Hyjal Summit", size = 20, color = "green" },
    { name = "Onyxia's Lair", size = 40, color = "gold" },
    { name = "Other", color = "purple" },
}
Raids.SIZES = { 5, 10, 15, 20, 25, 40 }

local INSTANCE_BY_NAME = {}
for _, inst in ipairs(Raids.INSTANCES) do INSTANCE_BY_NAME[inst.name] = inst end

local CLASS_ROLE = {
    WARRIOR = "melee", ROGUE = "melee", HUNTER = "ranged", MAGE = "ranged", WARLOCK = "ranged",
    PRIEST = "healer", DRUID = "healer", PALADIN = "healer", SHAMAN = "healer",
}
local CLASS_OK = {}
for _, c in ipairs(API.CLASSES) do CLASS_OK[c] = true end

local DAY_NAME = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local CHAT_LINE_MAX = 240           -- PostLineup packs groups into lines this long

local STATUS_RANK, ROLE_RANK = {}, {}
for i, s in ipairs(T.statusOrder) do STATUS_RANK[s] = i end
for i, r in ipairs(T.roleOrder) do ROLE_RANK[r] = i end
Raids.STATUS_RANK, Raids.ROLE_RANK = STATUS_RANK, ROLE_RANK

-------------------------------------------------------------------------------
-- Local calendar helpers. date/time are Lua's os functions; guarded all the same.
-------------------------------------------------------------------------------
local function osDate(fmt, ts)
    local f = rawget(_G, "date")
    if type(f) ~= "function" or type(ts) ~= "number" then return nil end
    local ok, r = pcall(f, fmt, ts)
    if ok then return r end
    return nil
end

local function osTime(t)
    local f = rawget(_G, "time")
    if type(f) ~= "function" or type(t) ~= "table" then return nil end
    local ok, r = pcall(f, t)
    if ok and type(r) == "number" then return r end
    return nil
end

--- DateParts(ts) -> date("*t") table in local time, or nil.
function Raids.DateParts(ts)
    local t = osDate("*t", ts)
    return type(t) == "table" and t or nil
end

--- LocalEpoch(y, m, d, hour, minute) -> epoch seconds of that local wall-clock time.
function Raids.LocalEpoch(y, m, d, hh, mm)
    if type(y) ~= "number" or type(m) ~= "number" or type(d) ~= "number" then return nil end
    return osTime({ year = y, month = m, day = d, hour = hh or 0, min = mm or 0, sec = 0 })
end

--- ShiftDays(ts, n): the same local wall-clock time n days later (survives DST changes).
function Raids.ShiftDays(ts, n)
    local t = Raids.DateParts(ts)
    if t then
        t.day = t.day + n
        t.isdst = nil
        local r = osTime(t)
        if r then return r end
    end
    return ts + n * 86400
end

-------------------------------------------------------------------------------
-- Small helpers
-------------------------------------------------------------------------------
--- Cuts a string to n bytes without splitting a UTF-8 character.
local function utf8Cut(s, n)
    if #s <= n then return s end
    local i = n
    while i > 0 do
        local b = s:byte(i + 1)
        if not b or b < 128 or b >= 192 then break end
        i = i - 1
    end
    return s:sub(1, i)
end

--- Player-typed text made safe to store, show and post: no codes, pipes or control chars.
local function cleanText(s, maxLen)
    s = API.CleanString(s)
    if not s then return "" end
    s = U.StripCodes(s)
    s = s:gsub("|", ""):gsub("%c", " ")
    return utf8Cut(U.Trim(s), maxLen or 255)
end
Raids.CleanText = cleanText

--- A player key as it may appear in a doc from another client: a short plain string.
-- Anything with escape codes or control characters in it is junk (or mischief).
local function validKey(k)
    return type(k) == "string" and k ~= "" and #k <= 48 and not k:find("[|%c]")
end
Raids.ValidKey = validKey

--- Text from another client's doc: passed through when it's already tidy, scrubbed and
-- cut to size when it isn't (nobody gets to paint textures across the page).
local function safeText(s, n)
    if type(s) ~= "string" or s == "" then return nil end
    if #s > n or s:find("[|%c]") then s = cleanText(s, n) end
    return s ~= "" and s or nil
end

local function clampSize(n)
    n = tonumber(n)
    if not n or n ~= n then return 40 end
    return U.Clamp(floor(n), 5, 40)
end

local function isOfficer(key)
    local R = GF.Roster
    if not key or not R then return false end
    return R:IsOfficer(key) and true or false
end

local function mainOf(key)
    local R = GF.Roster
    if type(key) ~= "string" or not R then return key end
    local m = R:MainOf(key)
    if type(m) == "string" and m ~= "" then return m end
    return key
end

local function toast(opts)
    local UI = GF.UI
    if UI and UI.Toast then UI:Toast(opts) end
end

--- Feedback for raid tools: a toast when toasts are on, chat otherwise.
local function notify(text, style)
    if GF.db and GF.db.settings and GF.db.settings.toasts == false then
        GF:Print(text)
        return
    end
    toast({ title = "Raid tools", text = text, icon = "roster", style = style or "green", duration = 6, force = true })
end
Raids.Notify = notify

function Raids.GroupsFor(size) return U.Clamp(ceil(clampSize(size) / 5), 1, 8) end
function Raids.InstanceInfo(name) return INSTANCE_BY_NAME[name] or INSTANCE_BY_NAME.Other end
function Raids.DefaultRole(class) return CLASS_ROLE[class] or "ranged" end

function Raids:IsOfficer(key) return isOfficer(key or API.MyKey()) end

function Raids:CanManage()
    local R = GF.Roster
    return R ~= nil and R:CanManage() and true or false
end

-------------------------------------------------------------------------------
-- Validation + lineups
-------------------------------------------------------------------------------
local function validEvent(id, d)
    return type(id) == "string" and type(d) == "table" and type(d.time) == "number" and d.time == d.time
end

local function validSignup(id, d)
    return type(d) == "table" and type(d.event) == "string" and validKey(d.player)
        and (d.char == nil or d.char == "" or validKey(d.char))
        and type(d.status) == "string" and T.status[d.status] ~= nil and id == d.event .. "|" .. d.player
end

--- FitLineup(raw, nGroups) -> { groups = {{keys}} x nGroups, bench = {keys} }: no
-- duplicates, at most five per group; anything that doesn't fit lands on the bench.
local function fitLineup(raw, nGroups)
    local out, seen, spill = { groups = {}, bench = {} }, {}, {}
    for g = 1, nGroups do out.groups[g] = {} end
    local function take(key)
        if validKey(key) and not seen[key] then
            seen[key] = true
            return true
        end
        return false
    end
    local groups = type(raw) == "table" and type(raw.groups) == "table" and raw.groups or {}
    for g = 1, 8 do
        local list = groups[g]
        if type(list) == "table" then
            for _, key in ipairs(list) do
                if take(key) then
                    local dest = out.groups[g]
                    if dest and #dest < 5 then dest[#dest + 1] = key else spill[#spill + 1] = key end
                end
            end
        end
    end
    local bench = type(raw) == "table" and type(raw.bench) == "table" and raw.bench or {}
    for _, key in ipairs(bench) do
        if take(key) and #out.bench < 40 then out.bench[#out.bench + 1] = key end
    end
    for _, key in ipairs(spill) do
        if #out.bench < 40 then out.bench[#out.bench + 1] = key end
    end
    return out
end
Raids.FitLineup = fitLineup

function Raids.LineupCount(l)
    local n = 0
    if type(l) == "table" and type(l.groups) == "table" then
        for _, list in ipairs(l.groups) do
            if type(list) == "table" then n = n + #list end
        end
    end
    return n
end

-------------------------------------------------------------------------------
-- Datasets
-------------------------------------------------------------------------------
local cache = {}
local function invalidate()
    cache.events = nil
    cache.byEvent = nil
end

local function changed()
    invalidate()
    GF:Debounce("raids-changed", 0.2, function() GF:Fire("GF_RAIDS_CHANGED") end)
end

Store:Define({
    name = "events", code = "ev", owner = "shared", keepDays = 90,
    canWrite = function(author) return GF.Roster:IsOfficer(author) end,
    validate = function(id, d) return validEvent(id, d) end,
    -- raids still ahead (or barely behind) survive pruning however old the record is
    keep = function(_, rec)
        local d = type(rec) == "table" and rec.d
        return type(d) == "table" and type(d.time) == "number" and d.time > API.ServerTime() - 14 * 86400
    end,
    onChange = function() changed() end,
})

--- Officers write anything. Otherwise you may only file an answer under yourself or your
-- main. Naming yourself as the toon coming (char) is not enough: that's a field the
-- writer picks, so it would let anyone overwrite anyone's answer. Deletes may also tidy
-- away an old answer you brought a toon to.
local function signupWriter(author, _, new, old)
    if isOfficer(author) then return true end
    local main = mainOf(author)
    if type(new) == "table" then
        return new.player ~= nil and (author == new.player or main == new.player)
    end
    if type(old) == "table" then
        return author == old.player or author == old.char or (old.player ~= nil and main == old.player)
    end
    return false
end

Store:Define({
    name = "signups", code = "su", owner = "shared", keepDays = 90,
    canWrite = signupWriter,
    validate = function(id, d) return validSignup(id, d) end,
    keep = function(_, rec)
        local d = type(rec) == "table" and rec.d
        return type(d) == "table" and type(d.event) == "string" and Store:Get("events", d.event) ~= nil
    end,
    onChange = function() changed() end,
})

GF:On("GF_GUILD_CHANGED", invalidate)
-- pruning drops docs without an onChange, so the indexes would keep the dead ones
GF:On("GF_STORE_PRUNED", function(name)
    if name == "events" or name == "signups" then changed() end
end)

-------------------------------------------------------------------------------
-- Indexes (rebuilt lazily after any change)
-------------------------------------------------------------------------------
local function eventList()
    if cache.events then return cache.events end
    local list = {}
    for id, d in pairs(Store:All("events")) do
        if validEvent(id, d) then list[#list + 1] = { id = id, d = d } end
    end
    tsort(list, function(a, b)
        if a.d.time ~= b.d.time then return a.d.time < b.d.time end
        return a.id < b.id
    end)
    cache.events = list
    return list
end

local function signupIndex()
    if cache.byEvent then return cache.byEvent end
    local idx = {}
    for id, d in pairs(Store:All("signups")) do
        if validSignup(id, d) then
            local list = idx[d.event]
            if not list then
                list = {}
                idx[d.event] = list
            end
            list[#list + 1] = { id = id, d = d }
        end
    end
    cache.byEvent = idx
    return idx
end

local function durationOf(d)
    local n = tonumber(d.duration)
    if not n or n ~= n or n <= 0 then return DEFAULT_DURATION end
    return min(floor(n), 12 * 3600)
end

--- A fresh, sanitised copy of an event doc (callers may keep or change it). Docs come
-- from other clients, so every string is checked before the page or chat sees it.
local function eventView(id, d)
    local sr = d.srLimit
    local v = {
        id = id,
        title = safeText(d.title, MAX_TITLE),
        instance = safeText(d.instance, MAX_TITLE) or "Other",
        size = clampSize(d.size),
        time = d.time,
        duration = durationOf(d),
        notes = safeText(d.notes, MAX_NOTES),
        leader = validKey(d.leader) and d.leader or nil,
        srLimit = (type(sr) == "number" and sr == sr) and U.Clamp(floor(sr), 0, 5) or nil,
        created = type(d.created) == "number" and d.created or nil,
        cancelled = d.cancelled and true or nil,
    }
    v.title = v.title or (v.instance ~= "Other" and v.instance) or "Raid night"
    if type(d.lineup) == "table" then v.lineup = fitLineup(d.lineup, Raids.GroupsFor(v.size)) end
    return v
end

local function signupView(id, d)
    local class = (type(d.class) == "string" and CLASS_OK[d.class]) and d.class or nil
    local role = (type(d.role) == "string" and T.roles[d.role]) and d.role or Raids.DefaultRole(class)
    local char = validKey(d.char) and d.char or d.player
    return {
        id = id, event = d.event, player = d.player, char = char, class = class, role = role,
        status = d.status, note = safeText(d.note, MAX_NOTE),
        t = (type(d.t) == "number" and d.t == d.t) and d.t or 0,
    }
end

-------------------------------------------------------------------------------
-- My characters (account-wide memory for the character picker)
-------------------------------------------------------------------------------
local function charsDB()
    if type(GF.db) ~= "table" then return nil end
    if type(GF.db.raidsChars) ~= "table" then GF.db.raidsChars = {} end
    return GF.db.raidsChars
end

local function roleMemory()
    local c = GF.cdb
    if type(c) ~= "table" then return nil end
    if type(c.raids) ~= "table" then c.raids = {} end
    if type(c.raids.roles) ~= "table" then c.raids.roles = {} end
    return c.raids.roles
end

--- Remembers the logged-in character: class, level and which guild partition it lives in.
local function recordMe()
    local me = API.MyKey()
    local db = charsDB()
    if not me or not db then return end
    local c = type(db[me]) == "table" and db[me] or {}
    c.class = API.UnitClassFile("player") or c.class
    local lvl = API.UnitLevel("player")
    if lvl and lvl > 0 then c.level = lvl end
    if GF.gdbKey and GF.gdbKey ~= "_noguild" then c.g = GF.gdbKey end
    c.t = API.ServerTime()
    db[me] = c
end

--- MyChars() -> array of { key, class, level, current } for this account in this guild,
-- the logged-in character first.
function Raids:MyChars()
    local out, seen = {}, {}
    local me = API.MyKey()
    local guild = GF.gdbKey
    for key, c in pairs(charsDB() or {}) do
        if type(key) == "string" and type(c) == "table" and (key == me or c.g == nil or c.g == guild) then
            seen[key] = true
            out[#out + 1] = {
                key = key, class = type(c.class) == "string" and c.class or nil,
                level = tonumber(c.level) or 0, current = key == me,
            }
        end
    end
    if me and not seen[me] then
        out[#out + 1] = { key = me, class = API.UnitClassFile("player"), level = API.UnitLevel("player"), current = true }
    end
    tsort(out, function(a, b)
        if a.current ~= b.current then return a.current end
        if a.level ~= b.level then return a.level > b.level end
        return a.key < b.key
    end)
    return out
end

local function mySet()
    local set = {}
    local me = API.MyKey()
    if me then set[me] = true end
    local guild = GF.gdbKey
    for key, c in pairs(charsDB() or {}) do
        if type(key) == "string" and type(c) == "table" and (c.g == nil or c.g == guild) then set[key] = true end
    end
    return set
end

function Raids:ClassOf(key)
    if type(key) ~= "string" then return nil end
    if key == API.MyKey() then return API.UnitClassFile("player") end
    local db = charsDB()
    local c = db and db[key]
    if type(c) == "table" and type(c.class) == "string" then return c.class end
    return GF.Roster and GF.Roster:Class(key) or nil
end

function Raids:LevelOf(key)
    if type(key) ~= "string" then return 0 end
    if key == API.MyKey() then return API.UnitLevel("player") end
    local lvl = GF.Roster and GF.Roster:Level(key) or 0
    if type(lvl) ~= "number" or lvl <= 0 then
        local db = charsDB()
        local c = db and db[key]
        lvl = type(c) == "table" and tonumber(c.level) or 0
    end
    return lvl or 0
end

--- RoleFor(char): last role picked for that toon, else its class default.
function Raids:RoleFor(char)
    local mem = roleMemory()
    local r = mem and type(char) == "string" and mem[char]
    if type(r) == "string" and T.roles[r] then return r end
    local db = charsDB()
    local c = db and type(char) == "string" and db[char]
    r = type(c) == "table" and c.role
    if type(r) == "string" and T.roles[r] then return r end
    return Raids.DefaultRole(self:ClassOf(char))
end

function Raids:RememberRole(char, role)
    if type(char) ~= "string" or not T.roles[role] then return end
    local mem = roleMemory()
    if mem then mem[char] = role end
    local db = charsDB()
    if db and type(db[char]) == "table" then db[char].role = role end
end

-------------------------------------------------------------------------------
-- Public API (CORE_API.md section 5)
-------------------------------------------------------------------------------
--- Upcoming(n) -> array of event docs (with .id), soonest first, not cancelled, still
-- within three hours of the pull.
function Raids:Upcoming(n)
    local out, now = {}, API.ServerTime()
    if type(n) == "number" and n < 1 then return out end
    for _, e in ipairs(eventList()) do
        if e.d.time > now - KEEP_LISTED and not e.d.cancelled then
            out[#out + 1] = eventView(e.id, e.d)
            if type(n) == "number" and #out >= n then break end
        end
    end
    return out
end

function Raids:Get(id)
    if type(id) ~= "string" then return nil end
    local d = Store:Get("events", id)
    if not validEvent(id, d) then return nil end
    return eventView(id, d)
end

--- SignupsFor(id) -> array of { id, player, char, class, role, status, note, t }, oldest first.
function Raids:SignupsFor(id)
    local out = {}
    local list = type(id) == "string" and signupIndex()[id]
    if not list then return out end
    for _, e in ipairs(list) do out[#out + 1] = signupView(e.id, e.d) end
    tsort(out, function(a, b)
        if a.t ~= b.t then return a.t < b.t end
        return a.player < b.player
    end)
    return out
end

--- MySignup(id): this account's answer - filed under my main, as this toon, or as any
-- of my other characters.
function Raids:MySignup(id)
    local list = type(id) == "string" and signupIndex()[id]
    local me = API.MyKey()
    if not list or not me then return nil end
    local main = mainOf(me)
    local mine
    local best, rank
    for _, e in ipairs(list) do
        local d = e.d
        local r
        if d.player == main then
            r = 1
        elseif d.char == me or d.player == me then
            r = 2
        else
            mine = mine or mySet()
            if mine[d.player] or (type(d.char) == "string" and mine[d.char]) then r = 3 end
        end
        if r and (not rank or r < rank) then best, rank = e, r end
    end
    return best and signupView(best.id, best.d) or nil
end

function Raids:Lineup(id)
    if type(id) ~= "string" then return nil end
    local d = Store:Get("events", id)
    if not validEvent(id, d) or type(d.lineup) ~= "table" then return nil end
    return fitLineup(d.lineup, Raids.GroupsFor(d.size))
end

--- Current(): the raid on right now (half an hour before the pull until it wraps up).
function Raids:Current()
    local now = API.ServerTime()
    for _, e in ipairs(eventList()) do
        local d = e.d
        if not d.cancelled and now >= d.time - CURRENT_LEAD and now <= d.time + durationOf(d) then
            return eventView(e.id, d)
        end
    end
    return nil
end

--- SetSignup(eventId, status, role, note) -> ok, err. Signs this character up under its main.
function Raids:SetSignup(eventId, status, role, note)
    return self:SignupAs(eventId, nil, status, role, note)
end

-------------------------------------------------------------------------------
-- Page helpers (used by RaidsUI)
-------------------------------------------------------------------------------
--- List(): every raid worth showing on the page - upcoming, live or just finished,
-- cancelled ones included.
function Raids:List()
    local out, now = {}, API.ServerTime()
    for _, e in ipairs(eventList()) do
        if e.d.time > now - KEEP_LISTED or e.d.time + durationOf(e.d) > now then
            out[#out + 1] = eventView(e.id, e.d)
        end
    end
    return out
end

function Raids:IsOver(ev, now)
    if type(ev) ~= "table" or type(ev.time) ~= "number" then return true end
    return (now or API.ServerTime()) > ev.time + (ev.duration or DEFAULT_DURATION)
end

function Raids:IsLive(ev, now)
    if type(ev) ~= "table" or type(ev.time) ~= "number" then return false end
    now = now or API.ServerTime()
    return now >= ev.time and now <= ev.time + (ev.duration or DEFAULT_DURATION)
end

--- Counts(id) -> { yes, late, maybe, bench, no, total, roles = { tank, ... } (yes + late only) }
function Raids:Counts(id)
    local c = { total = 0, roles = {} }
    for _, s in ipairs(T.statusOrder) do c[s] = 0 end
    for _, r in ipairs(T.roleOrder) do c.roles[r] = 0 end
    local list = type(id) == "string" and signupIndex()[id]
    if not list then return c end
    for _, e in ipairs(list) do
        local st = e.d.status
        c[st] = c[st] + 1
        c.total = c.total + 1
        if st == "yes" or st == "late" then
            local role = (type(e.d.role) == "string" and T.roles[e.d.role]) and e.d.role or Raids.DefaultRole(e.d.class)
            c.roles[role] = c.roles[role] + 1
        end
    end
    return c
end

--- Unanswered(days): raids starting within `days` that this account hasn't answered.
function Raids:Unanswered(days)
    local n, now = 0, API.ServerTime()
    local horizon = now + (days or 14) * 86400
    for _, e in ipairs(eventList()) do
        local t = e.d.time
        if t > now and t <= horizon and not e.d.cancelled and not self:MySignup(e.id) then n = n + 1 end
    end
    return n
end

--- NotResponded(id) -> guild mains (online, or level 55+) with no answer, online first.
function Raids:NotResponded(id)
    local out = {}
    local R = GF.Roster
    if not R or type(id) ~= "string" then return out end
    local answered = {}
    for _, s in ipairs(self:SignupsFor(id)) do
        answered[s.player] = true
        answered[s.char] = true
        answered[mainOf(s.char)] = true
    end
    for key, m in pairs(R:All()) do
        if not answered[key] and (m.online or (m.level or 0) >= RAID_LEVEL) and not R:IsAlt(key) then
            out[#out + 1] = { key = key, class = m.class, level = m.level or 0, online = m.online and true or false }
        end
    end
    tsort(out, function(a, b)
        if a.online ~= b.online then return a.online end
        return a.key < b.key
    end)
    return out
end

-------------------------------------------------------------------------------
-- Signups
-------------------------------------------------------------------------------
--- SignupAs(eventId, charKey, status, role, note) -> ok, err. Answers for this account's
-- main, bringing `charKey` (default: the logged-in toon). nil role/note keep what's there.
function Raids:SignupAs(eventId, charKey, status, role, note)
    if type(eventId) ~= "string" then return false, "No raid picked." end
    if type(status) ~= "string" or not T.status[status] then return false, "That's not a real answer." end
    local me = API.MyKey()
    if not me then return false, "Still loading - give it a sec." end
    local ev = self:Get(eventId)
    if not ev then return false, "That raid doesn't exist any more." end
    if ev.cancelled then return false, "That raid's been called off." end
    if self:IsOver(ev) then return false, "That raid's done and dusted." end
    local char = (type(charKey) == "string" and charKey ~= "") and charKey or me
    local player = mainOf(me) or me
    local old = self:MySignup(eventId)
    if type(role) ~= "string" or not T.roles[role] then
        role = (old and old.char == char and old.role) or self:RoleFor(char)
    end
    if note == nil then note = old and old.note or "" end
    note = cleanText(note, MAX_NOTE)
    local doc = {
        event = eventId, player = player, char = char, class = self:ClassOf(char), role = role,
        status = status, note = note ~= "" and note or nil,
        -- first in, first served: changing your answer puts you at the back of that queue
        t = (old and old.status == status and old.t ~= 0 and old.t) or API.ServerTime(),
    }
    local id = eventId .. "|" .. player
    local ok, err = Store:Put("signups", id, doc)
    if not ok then return false, err or "Couldn't save that." end
    -- tidy an older answer filed under another of my keys (before a main was declared)
    if old and old.id ~= id then Store:Delete("signups", old.id) end
    self:RememberRole(char, role)
    return true
end

--- SetStatusFor(signupId, status): officers re-file someone's answer (bench them, etc).
function Raids:SetStatusFor(signupId, status)
    local cur = Store:Get("signups", signupId)
    if not validSignup(signupId, cur) then return false, "That answer's gone." end
    if type(status) ~= "string" or not T.status[status] then return false, "That's not a real answer." end
    if cur.status == status then return true end
    local doc = U.Copy(cur)
    doc.status = status
    doc.t = API.ServerTime()
    return Store:Put("signups", signupId, doc)
end

function Raids:RemoveSignup(signupId)
    if not Store:Get("signups", signupId) then return false, "Already gone." end
    return Store:Delete("signups", signupId)
end

-------------------------------------------------------------------------------
-- Events (officers)
-------------------------------------------------------------------------------
local idCounter = 0

local function newId()
    idCounter = idCounter + 1
    local who = GF.Serialize.Hash(API.MyKey() or "?"):sub(1, 4)
    return "e" .. tostring(API.ServerTime()) .. "-" .. idCounter .. "-" .. who
end

--- Turns editor fields into a clean doc (without leader/created/lineup) or nil, err.
local function buildEventDoc(f)
    if type(f) ~= "table" then return nil, "Nothing to save." end
    local inst = Raids.InstanceInfo(f.instance)
    local size = inst.size or clampSize(f.size)
    local title = cleanText(f.title, MAX_TITLE)
    if title == "" then title = inst.size and inst.name or "Raid night" end
    if type(f.time) ~= "number" or f.time ~= f.time then return nil, "Pick a date and a start time." end
    local dur = U.Clamp(floor(tonumber(f.duration) or DEFAULT_DURATION), 1800, 8 * 3600)
    local sr = tonumber(f.srLimit)
    sr = sr and sr == sr and U.Clamp(floor(sr), 0, 5) or nil
    local notes = cleanText(f.notes, MAX_NOTES)
    return {
        title = title, instance = inst.name, size = size, time = floor(f.time), duration = dur,
        notes = notes ~= "" and notes or nil, srLimit = sr,
    }
end

--- "Wed 13 Nov". Text that other people read never carries a clock time: it would be
-- the writer's local time, and the guild doesn't all live in Perth.
local function dayText(ts)
    local t = Raids.DateParts(ts)
    if not t then return U.DateShort(ts) end
    return (DAY_NAME[t.wday] or "?") .. " " .. U.DateShort(ts)
end
Raids.DayText = dayText

--- Only the officer who puts a raid up announces it (CORE_API rule 14).
local function announce(id, doc, weeks)
    local F = GF.Feed
    if not (F and F.Post) then return end
    local who = U.ClassName(API.MyKey() or "?", API.UnitClassFile("player"))
    local more = (weeks or 1) > 1 and (" (then weekly, %d all up)"):format(weeks) or ""
    local text = ("%s put up %s for %s%s - sign up, legends."):format(who, doc.title, dayText(doc.time), more)
    GF:Safe("raids:feed", F.Post, F, "raid", text, { key = "raid:" .. id, icon = "calendar" })
end

--- CreateEvent(fields, weeks) -> ok, ids | false, err. weeks > 1 repeats it weekly.
function Raids:CreateEvent(fields, weeks)
    local me = API.MyKey()
    if not me then return false, "Still loading - give it a sec." end
    if not isOfficer(me) then return false, "Only officers can put raids up." end
    local base, err = buildEventDoc(fields)
    if not base then return false, err end
    weeks = U.Clamp(floor(tonumber(weeks) or 1), 1, 12)
    local ids = {}
    for w = 0, weeks - 1 do
        local doc = U.Copy(base)
        if w > 0 then doc.time = Raids.ShiftDays(base.time, 7 * w) end
        doc.leader = me
        doc.created = API.ServerTime()
        local id = newId()
        local ok, perr = Store:Put("events", id, doc)
        if not ok then return false, perr or "Couldn't save that." end
        ids[#ids + 1] = id
    end
    announce(ids[1], base, #ids)
    return true, ids
end

--- UpdateEvent(id, fields) -> ok, err. Keeps leader, created and the lineup (refitted
-- when the size changes).
function Raids:UpdateEvent(id, fields)
    local cur = Store:Get("events", id)
    if not validEvent(id, cur) then return false, "That raid's gone walkabout." end
    if not isOfficer(API.MyKey()) then return false, "Only officers can edit raids." end
    local base, err = buildEventDoc(fields)
    if not base then return false, err end
    local doc = U.Copy(cur)
    for k, v in pairs(base) do doc[k] = v end
    doc.notes = base.notes
    doc.srLimit = base.srLimit
    if type(doc.lineup) == "table" then doc.lineup = fitLineup(doc.lineup, Raids.GroupsFor(doc.size)) end
    return Store:Put("events", id, doc)
end

function Raids:SetCancelled(id, flag)
    local cur = Store:Get("events", id)
    if not validEvent(id, cur) then return false, "That raid's gone walkabout." end
    if not isOfficer(API.MyKey()) then return false, "Only officers can call raids off." end
    local doc = U.Copy(cur)
    doc.cancelled = flag and true or nil
    return Store:Put("events", id, doc)
end

--- DeleteEvent(id): bins the raid and every answer to it.
function Raids:DeleteEvent(id)
    if not Store:Get("events", id) then return false, "Already gone." end
    if not isOfficer(API.MyKey()) then return false, "Only officers can bin raids." end
    local ok, err = Store:Delete("events", id)
    if not ok then return false, err or "Couldn't delete that." end
    for _, s in ipairs(self:SignupsFor(id)) do Store:Delete("signups", s.id) end
    return true
end

function Raids:SaveLineup(id, lineup)
    local cur = Store:Get("events", id)
    if not validEvent(id, cur) then return false, "That raid's gone walkabout." end
    if not isOfficer(API.MyKey()) then return false, "Only officers can save lineups." end
    local doc = U.Copy(cur)
    doc.lineup = fitLineup(lineup, Raids.GroupsFor(cur.size))
    return Store:Put("events", id, doc)
end

-------------------------------------------------------------------------------
-- Auto-fill: tanks up front, a healer (or more) in every group, melee packed together
-- from the top, casters packed together from the bottom. Same classes sit together.
-------------------------------------------------------------------------------
function Raids:AutoFill(id)
    local ev = self:Get(id)
    if not ev then return nil end
    local G = Raids.GroupsFor(ev.size)
    local cap = min(ev.size, G * 5)
    local going, benched = {}, {}
    for _, s in ipairs(self:SignupsFor(id)) do
        if s.status == "yes" or s.status == "late" then
            going[#going + 1] = s
        elseif s.status == "bench" then
            benched[#benched + 1] = s
        end
    end
    -- yeahs before lates, then first in first served
    tsort(going, function(a, b)
        if a.status ~= b.status then return a.status == "yes" end
        if a.t ~= b.t then return a.t < b.t end
        return a.char < b.char
    end)
    local lineup = { groups = {}, bench = {} }
    for g = 1, G do lineup.groups[g] = {} end
    local byRole = { tank = {}, healer = {}, melee = {}, ranged = {} }
    for i, s in ipairs(going) do
        if i <= cap then
            local list = byRole[s.role] or byRole.ranged
            list[#list + 1] = s
        else
            lineup.bench[#lineup.bench + 1] = s.char
        end
    end
    for _, s in ipairs(benched) do lineup.bench[#lineup.bench + 1] = s.char end
    local function byClass(a, b)
        if (a.class or "") ~= (b.class or "") then return (a.class or "") < (b.class or "") end
        return a.char < b.char
    end
    for _, list in pairs(byRole) do tsort(list, byClass) end

    local groups = lineup.groups
    local function put(g, s) groups[g][#groups[g] + 1] = s.char end
    local function firstFree(from, to, step)
        for g = from, to, step do
            if #groups[g] < 5 then return g end
        end
        return nil
    end
    for _, s in ipairs(byRole.tank) do
        local g = firstFree(1, G, 1)
        if g then put(g, s) end
    end
    local heals = {}
    for g = 1, G do heals[g] = 0 end
    for _, s in ipairs(byRole.healer) do
        local best
        for g = 1, G do
            if #groups[g] < 5 and (not best or heals[g] < heals[best]) then best = g end
        end
        if best then
            put(best, s)
            heals[best] = heals[best] + 1
        end
    end
    for _, s in ipairs(byRole.melee) do
        local g = firstFree(1, G, 1)
        if g then put(g, s) end
    end
    for _, s in ipairs(byRole.ranged) do
        local g = firstFree(G, 1, -1)
        if g then put(g, s) end
    end
    return fitLineup(lineup, G)
end

-------------------------------------------------------------------------------
-- Raid-time tools: invites
-------------------------------------------------------------------------------
--- InviteCandidates(id) -> char keys of online yeah/late answers not already with us,
-- lineup members first, then yeahs, then lates.
function Raids:InviteCandidates(id)
    local out = {}
    local ev = self:Get(id)
    local R = GF.Roster
    if not ev or not R then return out end
    local me = API.MyKey()
    local placed = {}
    if ev.lineup then
        for _, list in ipairs(ev.lineup.groups) do
            for _, k in ipairs(list) do placed[k] = true end
        end
    end
    local list = {}
    for _, s in ipairs(self:SignupsFor(id)) do
        local k = s.char
        if (s.status == "yes" or s.status == "late") and k ~= me and R:IsOnline(k) and not R:InGroup(k) then
            list[#list + 1] = { key = k, rank = placed[k] and 0 or (s.status == "yes" and 1 or 2), t = s.t }
        end
    end
    tsort(list, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        if a.t ~= b.t then return a.t < b.t end
        return a.key < b.key
    end)
    for i, e in ipairs(list) do out[i] = e.key end
    return out
end

local inv            -- the running invite job
local invGen = 0
local invStep

--- Waits for the first accept. GROUP_ROSTER_UPDATE wakes us early; this poll is the
-- fallback (the event is unconfirmed on Forever).
local function invWait(gen)
    inv.waiting = true
    inv.deadline = API.Time() + 90
    local function poll()
        local job = inv
        if not job or job.gen ~= gen or not job.waiting then return end
        if API.InGroup() then
            job.waiting = false
            invStep(gen)
        elseif API.Time() > job.deadline then
            inv = nil
            notify("Nobody's accepted yet, so the rest are on hold. Hit invite again soon.", "yellow")
        else
            GF:After(2, poll)
        end
    end
    GF:After(2, poll)
end

--- One invite every 0.35 s. A party only holds five, so when the job needs more than
-- that we send four, wait for someone to accept, convert to a raid and carry on.
invStep = function(gen)
    local job = inv
    if not job or job.gen ~= gen then return end
    if job.i > #job.queue then
        inv = nil
        return
    end
    if job.base + #job.queue > 5 and not API.InRaid() then
        if API.InGroup() then
            if not API.IsGroupLeader("player") then
                inv = nil
                notify("Need the lead to turn this into a raid.", "red")
                return
            end
            job.converts = job.converts + 1
            if job.converts > 3 then
                inv = nil
                notify("Couldn't turn the party into a raid. Try converting it yourself.", "red")
                return
            end
            API.ConvertToRaid()
            GF:After(1.2, function() invStep(gen) end)
            return
        end
        if job.solo >= 4 then
            invWait(gen)
            return
        end
        job.solo = job.solo + 1
    end
    API.Invite(job.queue[job.i])
    job.i = job.i + 1
    GF:After(0.35, function() invStep(gen) end)
end

--- InviteSigned(id) -> ok, invitedCount, leftOut | false, err
function Raids:InviteSigned(id)
    if not self:CanManage() then return false, "Officers, or raid lead and assists, only." end
    if API.InGroup() and not API.CanLeadGroup() then return false, "You need lead or assist to send invites." end
    local ev = self:Get(id)
    if not ev then return false, "No raid picked." end
    if ev.cancelled then return false, "That raid's been called off." end
    local base = max(1, API.NumGroupMembers())
    local room = ev.size - base
    if room <= 0 then return false, "The group's already full." end
    local cands = self:InviteCandidates(id)
    if #cands == 0 then return false, "Nobody who said yeah is online and outside the group." end
    local queue = {}
    for i = 1, min(room, #cands) do queue[i] = cands[i] end
    invGen = invGen + 1
    inv = { gen = invGen, queue = queue, i = 1, base = base, solo = 0, converts = 0 }
    invStep(invGen)
    return true, #queue, #cands - #queue
end

-------------------------------------------------------------------------------
-- Raid-time tools: apply groups (one move at a time, waiting for the roster between)
-------------------------------------------------------------------------------
local apply
local applyGen = 0

local function raidIndex(unit)
    if type(unit) ~= "string" then return nil end
    return tonumber(unit:match("^raid(%d+)$"))
end

local applyStep

local function applyWait(gen)
    local job = apply
    job.waiting = true
    job.move = job.move + 1
    local mv = job.move
    -- GROUP_ROSTER_UPDATE normally wakes us; this is the fallback
    GF:After(1.5, function()
        if apply and apply.gen == gen and apply.waiting and apply.move == mv then
            apply.waiting = false
            applyStep(gen)
        end
    end)
end

applyStep = function(gen)
    local job = apply
    if not job or job.gen ~= gen then return end
    job.waiting = false
    if API.InCombat() then
        apply = nil
        notify("Combat! Group sorting stopped - hit Apply groups again after.", "red")
        return
    end
    if not API.InRaid() then
        apply = nil
        return
    end
    job.steps = job.steps + 1
    if job.steps > 80 then
        apply = nil
        notify("Gave up sorting groups - people kept moving.", "red")
        return
    end
    local members = API.GroupMembers()
    local count, byGroup = {}, {}
    for g = 1, 8 do
        count[g] = 0
        byGroup[g] = {}
    end
    for _, m in ipairs(members) do
        local g = m.subgroup
        if type(g) == "number" and count[g] then
            count[g] = count[g] + 1
            byGroup[g][#byGroup[g] + 1] = m
        end
    end
    for _, m in ipairs(members) do
        local want = m.key and job.desired[m.key]
        local idx = raidIndex(m.unit)
        if want and idx and m.subgroup ~= want and (job.tries[m.key] or 0) < 3 then
            job.tries[m.key] = (job.tries[m.key] or 0) + 1
            local moved = false
            if count[want] < 5 then
                moved = API.SetRaidSubgroup(idx, want) and true or false
            else
                -- full group: swap with someone who isn't meant to be there
                for _, o in ipairs(byGroup[want]) do
                    local oIdx = raidIndex(o.unit)
                    if oIdx and job.desired[o.key] ~= want then
                        moved = API.SwapRaidSubgroup(idx, oIdx) and true or false
                        break
                    end
                end
            end
            if moved then
                applyWait(gen)
                return
            end
        end
    end
    apply = nil
    -- "moved" only means the client took the call, so count who actually ended up out of
    -- place from this last look at the raid (refused moves and spent tries included)
    local missing, stuck = 0, 0
    for key in pairs(job.desired) do
        if not (GF.Roster and GF.Roster:InGroup(key)) then missing = missing + 1 end
    end
    for _, m in ipairs(members) do
        local want = m.key and job.desired[m.key]
        if want and m.subgroup ~= want then stuck = stuck + 1 end
    end
    if stuck > 0 then
        notify(("Sorted what I could. %d wouldn't budge - drag them in the raid frame."):format(stuck), "yellow")
    elseif missing > 0 then
        notify(("Groups sorted. %d from the lineup aren't in the raid yet."):format(missing), "yellow")
    else
        notify("Groups sorted. Righto, let's go.", "green")
    end
end

--- ApplyGroups(id, lineup) -> ok, err. lineup defaults to the saved one.
function Raids:ApplyGroups(id, lineup)
    local ev = self:Get(id)
    if not ev then return false, "No raid picked." end
    lineup = lineup and fitLineup(lineup, Raids.GroupsFor(ev.size)) or self:Lineup(id)
    if not lineup or Raids.LineupCount(lineup) == 0 then return false, "No lineup yet - build one in the roster builder." end
    if not API.InRaid() then return false, "You need to be in a raid group." end
    if not API.CanLeadGroup() then return false, "You need lead or assist to move people." end
    if API.InCombat() then return false, "Not in combat, legend." end
    local desired = {}
    for g, list in ipairs(lineup.groups) do
        for _, key in ipairs(list) do desired[key] = g end
    end
    applyGen = applyGen + 1
    apply = { gen = applyGen, desired = desired, tries = {}, steps = 0, move = 0 }
    applyStep(applyGen)
    return true
end

-------------------------------------------------------------------------------
-- Raid-time tools: post the lineup (button click only)
-------------------------------------------------------------------------------
local function chatName(key) return (key:match("^([^%-]+)")) or key end

function Raids:PostLineup(id, lineup)
    local ev = self:Get(id)
    if not ev then return false, "No raid picked." end
    lineup = lineup and fitLineup(lineup, Raids.GroupsFor(ev.size)) or self:Lineup(id)
    if not lineup or Raids.LineupCount(lineup) == 0 then return false, "No lineup to post yet." end
    local channel = (API.InRaid() and "RAID") or (API.InGroup() and "PARTY") or nil
    if not channel then return false, "You're not in a group, mate." end
    -- no clock time in the header: it would be the poster's local time, not the reader's
    local where = (ev.title ~= ev.instance) and ev.instance or (ev.size .. "-man")
    local lines = { ("Greenfields lineup - %s (%s)"):format(ev.title, where) }
    -- groups (then the bench) packed into as few lines as fit, so one click sends a
    -- handful of messages rather than a burst of ten the chat throttle eats
    local cur = ""
    local function add(seg, sep, prefix)
        if cur ~= "" and #cur + #sep + #seg > CHAT_LINE_MAX then
            lines[#lines + 1] = cur
            cur = ""
        end
        cur = (cur == "") and ((prefix or "") .. seg) or (cur .. sep .. seg)
    end
    local function flush()
        if cur ~= "" then lines[#lines + 1] = cur end
        cur = ""
    end
    for g, list in ipairs(lineup.groups) do
        if #list > 0 then
            local names = {}
            for i, k in ipairs(list) do names[i] = chatName(k) end
            add(("G%d: %s"):format(g, concat(names, ", ")), "  /  ")
        end
    end
    flush()
    for _, k in ipairs(lineup.bench) do add(chatName(k), ", ", "Bench: ") end
    flush()
    for _, line in ipairs(lines) do
        local ok, why = API.SendChat(U.ChatSafe(line), channel)
        if not ok then
            return false, why == "lockdown" and "Chat messages are restricted right now." or "Chat wouldn't take it."
        end
    end
    return true, #lines
end

-------------------------------------------------------------------------------
-- Officer nudge: a guild addon message that pokes everyone who hasn't answered
-------------------------------------------------------------------------------
local nudgeSent, nudgeShown = {}, {}

function Raids:Nudge(id)
    local me = API.MyKey()
    if not isOfficer(me) then return false, "Only officers can nudge." end
    local ev = self:Get(id)
    if not ev or ev.cancelled or self:IsOver(ev) then return false, "That raid isn't taking answers." end
    local t = API.Time()
    if nudgeSent[id] and t - nudgeSent[id] < NUDGE_COOLDOWN then
        return false, "Easy, you only just nudged them. Give it a few minutes."
    end
    if not Comm:Guild("RQ", { k = "n", e = id }, "NORMAL") then return false, "Couldn't reach the guild." end
    nudgeSent[id] = t
    return true
end

Comm:Register("RQ", function(p, sender)
    if type(p) ~= "table" or p.k ~= "n" or type(p.e) ~= "string" then return end
    if not isOfficer(sender) then return end
    local ev = Raids:Get(p.e)
    if not ev or ev.cancelled or ev.time < API.ServerTime() then return end
    if Raids:MySignup(p.e) then return end
    local t = API.Time()
    if nudgeShown[p.e] and t - nudgeShown[p.e] < NUDGE_SHOW_GAP then return end
    nudgeShown[p.e] = t
    local UI = GF.UI
    toast({
        title = "Oi, you in?",
        text = ("%s is rounding up for %s. Yeah or nah?"):format(U.ShortName(sender), ev.title),
        icon = "calendar", style = "yellow", duration = 12, key = "raids:nudge:" .. ev.id,
        onClick = function() if UI and UI.OpenMain then UI:OpenMain("raids", ev.id) end end,
    })
end)

-------------------------------------------------------------------------------
-- Reminders: 30 and 5 minutes out, for raids you said yeah (or late) to
-------------------------------------------------------------------------------
local function reminderStore()
    if not (GF.DB and GF.gdb) then return nil end
    local l = GF.DB:Local("Raids")
    if type(l.reminded) ~= "table" then l.reminded = {} end
    return l.reminded
end

local function pruneReminders()
    local r = reminderStore()
    if not r then return end
    local cutoff = API.ServerTime() - 3 * 86400
    for k, t in pairs(r) do
        if type(t) ~= "number" or t < cutoff then r[k] = nil end
    end
end

local function timeOf(ts)
    local s = U.DateTime(ts)
    return s:match(", (.+)$") or s
end

local function remind(ev, minutes, final)
    local UI = GF.UI
    local title, text
    if final and minutes <= 0 then
        title = "Pulling now"
        text = ("%s is pulling now. Camp up? Buffs on? Get in here."):format(ev.title)
    elseif final then
        title = ("Pull in %d min"):format(minutes)
        text = ("%s pulls in %d. Camp up? Buffs on? Get in, legend."):format(ev.title, minutes)
    else
        title = ("Raid in %d min"):format(minutes)
        text = ("%s at %s. Set up camp and get your buffs on, legend."):format(ev.title, timeOf(ev.time))
    end
    toast({
        title = title,
        text = text, icon = "calendar", style = "yellow", duration = final and 15 or 10,
        key = "raids:remind:" .. ev.id .. "@" .. ev.time .. (final and ":5" or ":30"),
        onClick = function() if UI and UI.OpenMain then UI:OpenMain("raids", ev.id) end end,
    })
end

local function checkReminders()
    local done = reminderStore()
    if not done then return end
    local now = API.ServerTime()
    for _, ev in ipairs(Raids:Upcoming(8)) do
        local left = ev.time - now
        if left > -60 and left <= 1800 then
            local s = Raids:MySignup(ev.id)
            if s and (s.status == "yes" or s.status == "late") then
                -- keyed by start time too, so a raid moved after its reminder fires again
                local base = ev.id .. "@" .. ev.time
                local k30, k5 = base .. ":30", base .. ":5"
                if left <= 300 then
                    if not done[k5] then
                        done[k5] = now
                        done[k30] = done[k30] or now
                        remind(ev, left > 0 and ceil(left / 60) or 0, true)
                    end
                elseif left > 360 and not done[k30] then
                    done[k30] = now
                    remind(ev, ceil(left / 60), false)
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Lifecycle + events
-------------------------------------------------------------------------------
function Raids:OnLogin()
    recordMe()
    GF:Ticker(20, checkReminders)
    GF:After(12, function()
        pruneReminders()
        checkReminders()
    end)
end

GF:On("GF_GUILD_READY", function()
    recordMe()
    changed()
end)

GF:RegisterEvent("PLAYER_LEVEL_UP", function()
    GF:After(1, recordMe)
end)

GF:RegisterEvent("GROUP_ROSTER_UPDATE", function()
    if inv and inv.waiting and API.InGroup() then
        inv.waiting = false
        local gen = inv.gen
        GF:After(0.5, function() invStep(gen) end)
    end
    if apply and apply.waiting then
        apply.waiting = false
        local gen = apply.gen
        GF:After(0.25, function() applyStep(gen) end)
    end
end)
