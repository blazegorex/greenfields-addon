--[[ Greenfields - Modules/Stats.lua
     Self-tracked stats, Hall of Fame titles, milestone badges and the player tooltip line.

     There is no combat log on Forever, so every number here is the player's own client
     watching its own events (deaths, spellcasts, loot lines, money, system messages,
     hooked jump/emote calls) and publishing the totals in the player-owned "stats" doc:
       { a = {[stat] = all-time}, w = {[stat] = this week}, wk = weekKey,
         ws = wealth score (only while shareWealth is on), t = published at }
     Readers keep only current guild members' docs, roll alts up to their mains (sum for
     "sum" stats, max for "max"/"rank") and crown the leader of every stat in GF.Titles.
     Wealth is only ever a log-scale score and the UI only ever shows the ordering.
     Only the new holder's own client announces a title changing hands.

     First death on a wipe: every Greenfields client in the raid sends op "DW"
     {e = encounterID, d = myDeathTime or nil} to the group on a wipe; 6 s later the client
     with the earliest death time (ties -> lowest key) claims it. Raiders who don't run
     Greenfields can't take part, so they can never "win" it either.

     Public API (CORE_API section 5):
       Stats:Value(key, statKey, scope)   Stats:Leader(statKey, scope)
       Stats:TitlesOf(key)                Stats:Badges(key)
     Extras for Modules/HallOfFame.lua (read-only helpers):
       Stats:Board(statKey, scope)  Stats:Format(statKey, value, rank)  Stats:MyValue(statKey, scope)
       Stats:NextMilestone(statKey) Stats:HasWeekly(statKey)            Stats:TopBadge(key)
     Fires GF_STATS_CHANGED (throttled) whenever boards may have moved. ]]

local _, GF = ...
local API, U, UI, T = GF.API, GF.Util, GF.UI, GF.Theme

local Stats = GF:NewModule("Stats")
GF.Stats = Stats

local type, pairs, ipairs, tostring, tonumber = type, pairs, ipairs, tostring, tonumber
local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local rawget, pcall, sort, concat, format = rawget, pcall, table.sort, table.concat, string.format
local Clean, CleanNumber, CleanString = API.Clean, API.CleanNumber, API.CleanString

local DATASET = "stats"
local WEEKS_KEPT = 8
local PUBLISH_DELAY = 15       -- seconds between local doc rewrites (the Store batches broadcasts)
local TITLE_DELAY = 4          -- seconds between board recomputes
local SETTLE_TIME = 90         -- title flips this soon after the guild loads are sync noise
local CACHE_TTL = 120          -- computed boards (attendance/loot) refresh at least this often
local WIPE_WINDOW = 6          -- seconds to collect "DW" reports after a wipe
local FALL_GRACE = 1.5         -- a death this soon after falling is a fall death...
local FALL_MIN = 0.9           -- ...if the fall lasted longer than a normal jump
local CAST_WINDOW = 2          -- consumable bag drop <-> spellcast pairing window
local LOOT_DEDUPE = 5
local FISH_WINDOW = 3
local JUMP_GAP = 0.55

local HEARTHSTONE = 8690
local REZ_IDS = {}
for _, id in ipairs({ 2006, 2010, 10880, 10881, 20770,            -- Resurrection
                      7328, 10322, 10324, 20772, 20773,           -- Redemption
                      2008, 20609, 20610, 20776, 20777,           -- Ancestral Spirit
                      20484, 20739, 20742, 20747, 20748 }) do     -- Rebirth
    REZ_IDS[id] = true
end
local FISHING_IDS = { [7620] = true, [7731] = true, [7732] = true, [18248] = true }
local CONSUMABLE_CLASS = 0
local CONSUMABLE_SUBCLASS = { [1] = true, [2] = true, [3] = true }  -- potion, elixir, flask
local NO_WEEKLY = { flakes = true, late = true, sr_wins = true }     -- sources keep no weekly split

-- Catalogue split: counters this client tracks itself vs stats computed from shared data.
local SELF_KEYS, COMPUTED = {}, {}
for _, def in ipairs(GF.Titles) do
    if def.source == "self" then
        if def.kind ~= "rank" then SELF_KEYS[def.key] = true end
    else
        COMPUTED[def.key] = true
    end
end

local state = {
    dead = false, released = false,
    lastFalling = -100, fallStart = nil, fallDur = 0, mirror = {},
    encounter = nil, wipes = {},
    afkSince = nil, money = nil, lastWs = nil, lastShare = nil, lastWeek = nil,
    merchant = false, busy = {}, repairPending = 0,
    drunk = 0, onTaxi = false, honorMode = nil, lifetimeHK = nil,
    lastCast = -100, castPending = {}, bagSnap = nil,
    lootSeen = {}, fishChannelEnd = -100, lastFishLoot = -100, lastCamp = -100, lastEmote = nil,
    readyAt = nil, skew = nil, lastServer = nil,
}

local add, changed  -- forward declarations

-------------------------------------------------------------------------------
-- Small guarded client helpers (everything not wrapped by GF.API)
-------------------------------------------------------------------------------
local function G(name) return rawget(_G, name) end

--- Calls a client global under pcall; returns its first result Clean'd (nil if missing/secret).
local function call(name, ...)
    local f = G(name)
    if type(f) ~= "function" then return nil end
    local ok, r = pcall(f, ...)
    if not ok then return nil end
    return Clean(r)
end

--- key -> main, memoised: every board rebuild asks for every doc. Cleared by
-- invalidate(true), i.e. whenever profiles or the roster (guild notes) change.
local mainCache = {}

local function mainOf(key)
    if type(key) ~= "string" then return key end
    local cached = mainCache[key]
    if cached then return cached end
    local main = key
    local R = GF.Roster
    if R and R.MainOf then
        local ok, m = pcall(R.MainOf, R, key)
        if ok and type(m) == "string" and m ~= "" then main = m end
    end
    mainCache[key] = main
    return main
end

local function colored(key)
    local R = GF.Roster
    if R and R.Colored then
        local ok, s = pcall(R.Colored, R, key)
        if ok and type(s) == "string" then return s end
    end
    return U.ShortName(key)
end

local function lowerFirst(s)
    s = tostring(s or "")
    return s:sub(1, 1):lower() .. s:sub(2)
end

--- Turns a Blizzard format string ("%1$s has defeated %2$s") into an anchored Lua pattern
-- plus the argument position of each capture, escaping every pattern magic character.
local function fmtToPattern(fmt)
    if type(fmt) ~= "string" or fmt == "" then return nil end
    local out, order, pos, seq, len = {}, {}, 1, 0, #fmt
    while pos <= len do
        local c = fmt:sub(pos, pos)
        if c == "%" then
            local num, conv, nextPos = fmt:match("^%%(%d)%$([sd])()", pos)
            if num then
                order[#order + 1] = tonumber(num)
                out[#out + 1] = conv == "d" and "(%d+)" or "(.+)"
                pos = nextPos
            else
                local conv2, np = fmt:match("^%%([sd])()", pos)
                if conv2 then
                    seq = seq + 1
                    order[#order + 1] = seq
                    out[#out + 1] = conv2 == "d" and "(%d+)" or "(.+)"
                    pos = np
                elseif fmt:sub(pos + 1, pos + 1) == "%" then
                    out[#out + 1] = "%%"
                    pos = pos + 2
                else
                    out[#out + 1] = "%%"
                    pos = pos + 1
                end
            end
        elseif c:find("[%^%$%(%)%.%[%]%*%+%-%?]") then
            out[#out + 1] = "%" .. c
            pos = pos + 1
        else
            out[#out + 1] = c
            pos = pos + 1
        end
    end
    return "^" .. concat(out) .. "$", order
end

--- matchFormat({pat, order}, text) -> args by format position, or nil.
local function matchFormat(p, text)
    local caps = { text:match(p.pat) }
    if caps[1] == nil then return nil end
    local args = {}
    for i, argPos in ipairs(p.order) do args[argPos] = caps[i] end
    return args
end

-------------------------------------------------------------------------------
-- Local storage: GF.cdb.stats (all-time) and GF.cdb.weekly[weekKey]
-------------------------------------------------------------------------------
local function ensureTables()
    local c = GF.cdb
    if not c then return false end
    if type(c.stats) ~= "table" then c.stats = {} end
    if type(c.weekly) ~= "table" then c.weekly = {} end
    if type(c.track) ~= "table" then c.track = {} end
    return true
end

local function pruneWeeks()
    local weekly = GF.cdb.weekly
    local keys = {}
    for k in pairs(weekly) do
        if type(k) == "number" then keys[#keys + 1] = k else weekly[k] = nil end
    end
    sort(keys, function(a, b) return a > b end)
    for i = WEEKS_KEPT + 1, #keys do weekly[keys[i]] = nil end
end

local function weekBucket()
    local wk = U.WeekKey()
    local weekly = GF.cdb.weekly
    local b = weekly[wk]
    if type(b) ~= "table" then
        b = {}
        weekly[wk] = b
        pruneWeeks()
    end
    return b, wk
end

local function wealthScore()
    if GF.db and GF.db.settings and GF.db.settings.shareWealth == false then return nil end
    if type(GF.WealthScore) ~= "function" then return nil end
    local copper = CleanNumber(API.Money())
    if not copper then return nil end
    local ok, ws = pcall(GF.WealthScore, copper)
    return (ok and type(ws) == "number") and ws or nil
end

-------------------------------------------------------------------------------
-- The replicated "stats" dataset
-------------------------------------------------------------------------------
GF.Store:Define({
    name = DATASET, code = "st", owner = "player", lazy = 300, keepDays = 120,
    validate = function(_, d)
        return type(d) == "table" and (d.a == nil or type(d.a) == "table") and (d.w == nil or type(d.w) == "table")
    end,
})

--- A count read from someone's doc: a positive, finite, believable number or nil. The
-- serializer happily carries 1e999 (inf), and nobody has jumped a billion times.
local MAX_COUNT = 1e9
local function sane(v)
    v = tonumber(v)
    if not v or v ~= v or v <= 0 or v >= MAX_COUNT then return nil end
    return v
end

--- Wealth score (GF.WealthScore: 0 for broke, ~120 for a million gold) or nil.
local function saneScore(v)
    v = tonumber(v)
    if not v or v ~= v or v < 0 or v > 400 then return nil end
    return v
end

local function nonZero(src)
    local out = {}
    if type(src) ~= "table" then return out end
    for k, v in pairs(src) do
        if SELF_KEYS[k] and type(v) == "number" and v >= 1 then out[k] = floor(v) end
    end
    return out
end

local function sameCounts(x, y)
    if type(x) ~= "table" or type(y) ~= "table" then return false end
    for k, v in pairs(x) do if y[k] ~= v then return false end end
    for k in pairs(y) do if x[k] == nil then return false end end
    return true
end

local function buildDoc()
    local wb, wk = weekBucket()
    return { a = nonZero(GF.cdb.stats), w = nonZero(wb), wk = wk, ws = wealthScore(), t = API.ServerTime() }
end

local publishPending = false

local function publish(force)
    publishPending = false
    if not ensureTables() or not (GF.DB and GF.DB:Ready()) or not API.MyKey() then return end
    -- An empty character DB (new install, or the beta not restoring SavedVariables) holds
    -- off until the guild has had a chance to hand our old doc back (see adopt()):
    -- publishing first would give the near-empty doc a newer rev and wipe our history
    -- off every guildie's copy.
    local hold = state.holdUntil and (state.holdUntil - API.Time())
    if hold and hold > 0 then
        publishPending = true
        GF:After(hold + 1, function() publish(force) end)
        return
    end
    state.holdUntil = nil
    local doc = buildDoc()
    local cur = GF.Store:Mine(DATASET)
    if not force and type(cur) == "table" and cur.wk == doc.wk and cur.ws == doc.ws
        and sameCounts(cur.a, doc.a) and sameCounts(cur.w, doc.w)
        and API.ServerTime() - (tonumber(cur.t) or 0) < 6 * 3600 then
        return
    end
    -- from here on any copy of our doc that beats ours came from another PC: max, never sum
    if GF.Store:PutMine(DATASET, doc) then state.freshSV = false end
end

local function schedulePublish()
    if publishPending then return end
    publishPending = true
    GF:After(PUBLISH_DELAY, function() publish(false) end)
end

-------------------------------------------------------------------------------
-- Boards: per-stat rankings of mains, cached until data changes
-------------------------------------------------------------------------------
local selfCache, computedCache = {}, {}
local docsCache                 -- memberDocs() result, shared by every board build
local tipCache = {}             -- player tooltip lines by key

local function invalidate(all)
    selfCache = {}
    docsCache = nil
    tipCache = {}
    if all then
        computedCache = {}
        mainCache = {}
    end
end

--- What I count myself, read live (my published doc can lag by a few minutes).
local function liveDoc()
    local wb, wk = weekBucket()
    return { a = GF.cdb.stats, w = wb, wk = wk, ws = wealthScore() }
end

--- Current guild members' stats docs, keyed by character. Cached until invalidate():
-- add(), wealth changes, week rollover, store and roster changes all invalidate.
local function memberDocs()
    if docsCache then return docsCache end
    local out = {}
    local R = GF.Roster
    local filter = R and R.Count and R:Count() > 0
    for id, d in pairs(GF.Store:All(DATASET)) do
        if type(id) == "string" and type(d) == "table" and (not filter or R:IsMember(id)) then out[id] = d end
    end
    local me = API.MyKey()
    if me and ensureTables() then out[me] = liveDoc() end
    docsCache = out
    return out
end

local function docValue(d, stat, scope, wk)
    local src = d.a
    if scope == "week" then
        if d.wk ~= wk then return 0 end
        src = d.w
    end
    local v = type(src) == "table" and sane(src[stat]) or nil
    return v or 0
end

--- Stats computed by other modules (they already roll alts up to mains).
local function computedValue(key, stat, scope)
    if stat == "attendance" then
        local A = GF.Attendance
        if A and A.Percent then
            local ok, p = pcall(A.Percent, A, key, scope == "week" and 1 or 8)
            if ok and type(p) == "number" then return p end
        end
    elseif stat == "flakes" or stat == "late" then
        local A = GF.Attendance
        if A and A.Summary then
            local ok, s = pcall(A.Summary, A, key)
            if ok and type(s) == "table" and type(s[stat]) == "number" then return s[stat] end
        end
    elseif stat == "sr_wins" then
        local L = GF.Loot
        if L and L.SRWins then
            local ok, n = pcall(L.SRWins, L, key)
            if ok and type(n) == "number" then return n end
        end
    end
    return nil
end

local function collectComputed(stat, scope, totals)
    local seen, keys = {}, {}
    local R = GF.Roster
    if R and R.All then
        for k in pairs(R:All()) do keys[#keys + 1] = k end
    end
    local me = API.MyKey()
    if me then keys[#keys + 1] = me end
    for _, k in ipairs(keys) do
        local m = mainOf(k)
        if not seen[m] then
            seen[m] = true
            local v = computedValue(m, stat, scope)
            if v and v > 0 then totals[m] = v end
        end
    end
end

local function collectSelf(def, scope, totals)
    local wk = U.WeekKey()
    for id, d in pairs(memberDocs()) do
        local m = mainOf(id)
        if def.kind == "rank" then
            local ws = saneScore(d.ws)
            if ws and (totals[m] == nil or ws > totals[m]) then totals[m] = ws end
        else
            local v = docValue(d, def.key, scope, wk)
            if v > 0 then
                if def.kind == "max" then
                    if v > (totals[m] or 0) then totals[m] = v end
                else
                    totals[m] = (totals[m] or 0) + v
                end
            end
        end
    end
end

local function buildBoard(def, scope)
    local totals = {}
    if COMPUTED[def.key] then collectComputed(def.key, scope, totals) else collectSelf(def, scope, totals) end
    local list = {}
    for k, v in pairs(totals) do list[#list + 1] = { key = k, score = v } end
    local asc = def.inverse and true or false
    sort(list, function(a, b)
        if a.score ~= b.score then
            if asc then return a.score < b.score end
            return a.score > b.score
        end
        return a.key < b.key
    end)
    local map = {}
    for i, e in ipairs(list) do
        e.rank = i
        -- rank stats expose only the ordering, never the score
        if def.kind ~= "rank" then e.value = e.score end
        e.score = nil
        map[e.key] = e
    end
    return { list = list, map = map, t = API.Time() }
end

local EMPTY_BOARD = { list = {}, map = {} }

local function board(stat, scope)
    local def = GF.TitlesByKey[stat]
    if not def then return EMPTY_BOARD end
    scope = scope == "week" and "week" or "all"
    local cache = COMPUTED[stat] and computedCache or selfCache
    local ck = stat .. ":" .. scope
    local b = cache[ck]
    if not b or (COMPUTED[stat] and API.Time() - b.t > CACHE_TTL) then
        b = buildBoard(def, scope)
        cache[ck] = b
    end
    return b
end

-------------------------------------------------------------------------------
-- Public API (never errors; safe defaults)
-------------------------------------------------------------------------------
local function guarded(label, fallback, fn, ...)
    local ok, a, b = GF:Safe(label, fn, ...)
    if ok then return a, b end
    return fallback
end

--- Value(key, statKey, scope) -> number. Rolled up to the player's main. For rank stats
-- this is the board position (1 = top), never an amount; 0 when unranked.
function Stats:Value(key, statKey, scope)
    return guarded("stats:value", 0, function()
        local def = type(statKey) == "string" and GF.TitlesByKey[statKey]
        if not def or type(key) ~= "string" then return 0 end
        local e = board(statKey, scope).map[mainOf(key)]
        if not e then return 0 end
        if def.kind == "rank" then return e.rank end
        return e.value or 0
    end)
end

--- Leader(statKey, scope) -> key, value (value is nil for rank stats).
function Stats:Leader(statKey, scope)
    return guarded("stats:leader", nil, function()
        local def = type(statKey) == "string" and GF.TitlesByKey[statKey]
        if not def then return nil end
        local e = board(statKey, scope).list[1]
        if not e then return nil end
        return e.key, e.value
    end)
end

--- TitlesOf(key) -> title defs `key` (or their main) currently holds, all-time, catalogue order.
function Stats:TitlesOf(key)
    return guarded("stats:titles", {}, function()
        local out = {}
        if type(key) ~= "string" then return out end
        local m = mainOf(key)
        for _, def in ipairs(GF.Titles) do
            local e = board(def.key, "all").list[1]
            if e and e.key == m then out[#out + 1] = def end
        end
        return out
    end)
end

--- A character's own all-time count (not rolled up): badges belong to the character.
local function rawAllTime(key, stat)
    if key == API.MyKey() and ensureTables() then return tonumber(GF.cdb.stats[stat]) or 0 end
    local d = GF.Store:Get(DATASET, key)
    local v = type(d) == "table" and type(d.a) == "table" and sane(d.a[stat]) or nil
    return v or 0
end

local function badgeSource(key, def)
    if COMPUTED[def.key] then return computedValue(mainOf(key), def.key, "all") or 0 end
    return rawAllTime(key, def.key)
end

--- Badges(key) -> array of {stat, n, name, tier, icon, group}, catalogue order then threshold.
function Stats:Badges(key)
    return guarded("stats:badges", {}, function()
        local out = {}
        if type(key) ~= "string" then return out end
        for _, def in ipairs(GF.Titles) do
            if def.milestones then
                local v = badgeSource(key, def)
                for tier, m in ipairs(def.milestones) do
                    if v >= m[1] then
                        out[#out + 1] = { stat = def.key, n = m[1], name = m[2], tier = tier, icon = def.icon, group = def.group }
                    end
                end
            end
        end
        return out
    end)
end

--- TopBadge(key) -> the most prestigious badge (highest tier, then catalogue order) or nil.
function Stats:TopBadge(key)
    local best
    for _, b in ipairs(self:Badges(key)) do
        if not best or b.tier > best.tier then best = b end
    end
    return best
end

--- Board(statKey, scope) -> read-only array of {key, rank, value} (value nil for rank stats).
function Stats:Board(statKey, scope)
    return guarded("stats:board", {}, function() return board(statKey, scope).list end)
end

--- HasWeekly(statKey) -> false for stats whose source keeps no weekly split.
function Stats:HasWeekly(statKey) return not NO_WEEKLY[statKey] end

--- MyValue(statKey, scope) -> this character's own number (computed stats: my main's).
function Stats:MyValue(statKey, scope)
    return guarded("stats:mine", 0, function()
        local def = GF.TitlesByKey[statKey]
        local me = API.MyKey()
        if not def or not me or not ensureTables() then return 0 end
        if COMPUTED[statKey] then return computedValue(mainOf(me), statKey, scope) or 0 end
        if def.kind == "rank" then return 0 end
        local src = GF.cdb.stats
        if scope == "week" then src = weekBucket() end
        return tonumber(src[statKey]) or 0
    end)
end

--- NextMilestone(statKey) -> nextMilestone {n, name} or nil, myValue, previousThreshold, tier.
function Stats:NextMilestone(statKey)
    local def = GF.TitlesByKey[statKey]
    if not def or not def.milestones then return nil, 0, 0, 0 end
    local me = API.MyKey()
    local v = me and guarded("stats:next", 0, badgeSource, me, def) or 0
    local prev = 0
    for tier, m in ipairs(def.milestones) do
        if v < m[1] then return m, v, prev, tier end
        prev = m[1]
    end
    return nil, v, prev, #def.milestones
end

--- Format(statKey, value, rank) -> display string. Rank stats never show an amount.
function Stats:Format(statKey, value, rank)
    local def = GF.TitlesByKey[statKey]
    if not def then return "" end
    if def.kind == "rank" then return "#" .. tostring(rank or "?") .. " - amount classified" end
    value = tonumber(value) or 0
    local s = value >= 10000 and U.Short(value) or U.Commas(value)
    if def.unit == "%" or def.unit == "g" then return s .. def.unit end
    if def.unit then return s .. " " .. def.unit end
    return s
end

-------------------------------------------------------------------------------
-- Counting + badges
-------------------------------------------------------------------------------
local titlesPending = false
local recomputeTitles -- defined with the title logic below

local function scheduleTitles()
    if titlesPending then return end
    titlesPending = true
    GF:After(TITLE_DELAY, function()
        titlesPending = false
        recomputeTitles()
    end)
end

changed = function()
    invalidate(false)
    schedulePublish()
    scheduleTitles()
end

local function announceBadge(def, m)
    local amount = Stats:Format(def.key, m[1])
    local fame = def.group == "fame"
    if UI and UI.Toast then
        UI:Toast({
            title = "Badge unlocked: " .. m[2],
            text = format("%s: %s. Wear it with %s.", def.label, amount, fame and "pride" or "shame"),
            icon = def.icon, style = fame and "green" or "yellow",
            key = "badge:" .. def.key .. ":" .. m[1],
        })
    end
    local me = API.MyKey()
    if me and GF.Feed and GF.Feed.Post then
        GF:Safe("stats:feed", GF.Feed.Post, GF.Feed, "badge",
            format("%s earned the %s badge: %s hit %s.", colored(me), m[2], lowerFirst(def.label), amount),
            { icon = def.icon, key = "badge:" .. def.key .. ":" .. m[1] .. ":" .. me })
    end
end

local function crossBadges(def, old, new)
    if not (def and def.milestones) then return end
    for _, m in ipairs(def.milestones) do
        if old < m[1] and new >= m[1] then GF:Safe("stats:badge", announceBadge, def, m) end
    end
end

--- add(stat, n): the only way a self-tracked counter moves.
add = function(stat, n)
    n = tonumber(n) or 1
    if n <= 0 or not SELF_KEYS[stat] or not ensureTables() then return end
    local all = GF.cdb.stats
    local old = tonumber(all[stat]) or 0
    all[stat] = old + n
    local wb = weekBucket()
    wb[stat] = (tonumber(wb[stat]) or 0) + n
    crossBadges(GF.TitlesByKey[stat], old, old + n)
    changed()
end

-------------------------------------------------------------------------------
-- Localized spell-name sets (one name covers every rank)
-------------------------------------------------------------------------------
local nameSets, nameSetsAt = nil, -100

local function names()
    if nameSets and (nameSets.complete or API.Time() - nameSetsAt < 30) then return nameSets end
    local sets = { hearth = { Hearthstone = true }, rez = {}, fishing = { Fishing = true }, complete = true }
    local n = CleanString(API.SpellName(HEARTHSTONE))
    if n then sets.hearth[n] = true else sets.complete = false end
    for id in pairs(REZ_IDS) do
        local s = CleanString(API.SpellName(id))
        if s then sets.rez[s] = true end
    end
    for id in pairs(FISHING_IDS) do
        local s = CleanString(API.SpellName(id))
        if s then sets.fishing[s] = true end
    end
    nameSets, nameSetsAt = sets, API.Time()
    return sets
end

--- Spells that place a camp object or campfire: the known placement spells plus the
-- use-spell of every camp/campfire kit item (resolved once the items are cached).
local campSet, campSetComplete, campSetAt = nil, false, -100

local function campSpells()
    if campSet and (campSetComplete or API.Time() - campSetAt < 30) then return campSet end
    local set, complete = {}, true
    local D = GF.BuffData
    if D then
        for _, id in ipairs(D.CAMP_PLACE_SPELLS or {}) do set[id] = true end
        local items = {}
        for _, o in ipairs(D.camp or {}) do
            for _, it in ipairs(o.items or {}) do items[#items + 1] = it end
        end
        for _, f in ipairs(D.campfires or {}) do
            if f.item then items[#items + 1] = f.item end
        end
        for _, it in ipairs(items) do
            local _, sid = API.ItemSpell(it)
            sid = CleanNumber(sid)
            if sid then
                set[sid] = true
            else
                complete = false
                API.RequestItem(it)
            end
        end
    end
    campSet, campSetComplete, campSetAt = set, complete, API.Time()
    return set
end

-------------------------------------------------------------------------------
-- Deaths: total / raid / pvp / falling / drowning, plus the wipe death clock
-------------------------------------------------------------------------------
--- Sub-second server time, calibrated whenever GetServerTime ticks over (see tick()).
local function deathStamp()
    if state.skew then return API.Time() + state.skew end
    return API.ServerTime()
end

--- Breath/fatigue running out. With readable timer values a death only counts once the
-- bar is (nearly) empty; without them, any running drain counts.
local function drowning(now)
    for _, m in pairs(state.mirror) do
        if m.draining and (not m.expires or now >= m.expires - 2) then return true end
    end
    return false
end

local function isPaused(p)
    return p == true or (type(p) == "number" and p > 0)
end

local function onMirrorStart(_, timer, value, _, scale, paused)
    timer = CleanString(timer)
    if timer ~= "BREATH" and timer ~= "EXHAUSTION" then return end
    value, scale = CleanNumber(value), CleanNumber(scale)
    local m = { draining = not isPaused(Clean(paused)) and not (scale and scale >= 0) }
    if m.draining and value and scale then
        m.expires = API.Time() + value / 1000 / max(0.01, -scale)
    end
    state.mirror[timer] = m
end

local function onMirrorPause(_, timer, paused)
    timer = CleanString(timer)
    local m = timer and state.mirror[timer]
    if m and isPaused(Clean(paused)) then m.draining, m.expires = false, nil end
end

local function onMirrorStop(_, timer)
    timer = CleanString(timer)
    if timer then state.mirror[timer] = nil end
end

local function onPlayerDead()
    local now = API.Time()
    state.dead, state.released = true, false
    add("deaths_total")
    local itype = API.InstanceInfo().type
    if itype == "raid" then
        add("deaths_raid")
    elseif itype == "pvp" or itype == "arena" then
        add("deaths_pvp")
    end
    local fell = state.fallStart and (now - state.fallStart) or state.fallDur
    if now - state.lastFalling <= FALL_GRACE and fell >= FALL_MIN then add("deaths_falling") end
    if drowning(now) then add("deaths_drowning") end
    local enc = state.encounter
    if enc and not enc.myDeath then enc.myDeath = deathStamp() end
end

--- Rezzed: back on our feet without ever releasing to a ghost.
local function onAlive()
    GF:After(0.3, function()
        if call("UnitIsGhost", "player") then state.released = true return end
        if API.UnitIsDead("player") then return end
        if state.dead and not state.released then add("rezzed") end
        state.dead, state.released = false, false
    end)
end

local function onUnghost()
    state.dead, state.released = false, false
end

--- 0.2 s ticker: falling edges + the sub-second server clock calibration.
local function tick()
    local now = API.Time()
    if API.IsFalling() then
        state.fallStart = state.fallStart or now
        state.lastFalling = now
    elseif state.fallStart then
        state.fallDur = now - state.fallStart
        state.fallStart = nil
    end
    local st = API.ServerTime()
    if state.lastServer and st == state.lastServer + 1 then state.skew = st - now end
    state.lastServer = st
end

-------------------------------------------------------------------------------
-- Wipes and first death on a wipe (op "DW", group channel)
-------------------------------------------------------------------------------
local function wipeFor(e)
    local w = state.wipes[e]
    if not w then
        w = { votes = {}, t = API.Time() }
        state.wipes[e] = w
    end
    return w
end

local function settleWipe(e)
    local w = state.wipes[e]
    state.wipes[e] = nil
    if not w then return end
    local bestKey, bestT
    for key, t in pairs(w.votes) do
        if type(t) == "number" and (not bestT or t < bestT or (t == bestT and key < bestKey)) then
            bestKey, bestT = key, t
        end
    end
    if bestKey and bestKey == API.MyKey() then add("first_death_wipe") end
end

local function onEncounterStart(_, encounterID)
    state.encounter = { id = CleanNumber(encounterID) or 0 }
end

local function onEncounterEnd(_, encounterID, _, _, _, success)
    local enc = state.encounter
    state.encounter = nil
    if CleanNumber(success) ~= 0 or not API.InRaidInstance() then return end
    local e = CleanNumber(encounterID) or (enc and enc.id) or 0
    local d = enc and enc.myDeath or nil
    add("wipes")
    local me = API.MyKey()
    local w = wipeFor(e)
    w.t = API.Time()
    if me then w.votes[me] = d or false end
    if GF.Comm and GF.Comm.Group then GF.Comm:Group("DW", { e = e, d = d }, "ALERT") end
    GF:After(WIPE_WINDOW, function() settleWipe(e) end)
end

GF.Comm:Register("DW", function(p, sender)
    if type(p) ~= "table" or type(sender) ~= "string" then return end
    local R = GF.Roster
    if R and R.InGroup and not R:InGroup(sender) then return end
    local w = wipeFor(tonumber(p.e) or 0)
    w.votes[sender] = tonumber(p.d) or false
end)

-------------------------------------------------------------------------------
-- PvP: killing blows on players and honorable kills
-------------------------------------------------------------------------------
local function onPartyKill(_, attackerGUID, targetGUID)
    local a, t = CleanString(attackerGUID), CleanString(targetGUID)
    if not a or not t then return end
    local mine = API.UnitGUID("player")
    if mine and a == mine and t:match("^Player%-") then add("pvp_kills") end
end

--- Lifetime HK delta. A jump from 0 is the stats loading in, not kills, so re-baseline.
local function readHonor()
    local f = G("GetPVPLifetimeStats")
    if type(f) ~= "function" then return nil end
    local ok, hk = pcall(f)
    hk = ok and CleanNumber(hk) or nil
    if not hk then return nil end
    local last = state.lifetimeHK
    if last and hk > last and hk - last <= 100 and not (last == 0 and hk > 3) then
        add("honor_kills", hk - last)
    end
    state.lifetimeHK = hk
    return hk
end

local honorPatterns

local function onHonorGain(_, text)
    -- one source only: the lifetime counter wins when the client has it
    if state.honorMode == "lifetime" then GF:Debounce("stats-hk", 1, readHonor) return end
    text = CleanString(text)
    if not text then return end
    if not honorPatterns then
        honorPatterns = {}
        for _, name in ipairs({ "COMBATLOG_HONORGAIN", "COMBATLOG_HONORGAIN_NO_RANK" }) do
            local pat, order = fmtToPattern(G(name))
            if pat then honorPatterns[#honorPatterns + 1] = { pat = pat, order = order } end
        end
    end
    if #honorPatterns > 0 then
        for _, p in ipairs(honorPatterns) do
            if text:match(p.pat) then add("honor_kills") return end
        end
        return
    end
    local low = text:lower()
    if low:find("honorable kill", 1, true) and not low:find("dishonorable", 1, true) then add("honor_kills") end
end

local function onPvPKillsChanged()
    if state.honorMode == "lifetime" then GF:Debounce("stats-hk", 1, readHonor) end
end

-------------------------------------------------------------------------------
-- AFK minutes (seconds carry in GF.cdb.track so nothing is lost between flushes)
-------------------------------------------------------------------------------
local function afkCredit(sec)
    if sec <= 0 or not ensureTables() then return end
    local track = GF.cdb.track
    local carry = (tonumber(track.afkSec) or 0) + min(sec, 4 * 3600)
    local whole = floor(carry / 60)
    track.afkSec = carry - whole * 60
    if whole > 0 then add("afk_minutes", whole) end
end

local function flushAFK()
    if not state.afkSince then return end
    local now = API.Time()
    afkCredit(now - state.afkSince)
    state.afkSince = now
end

local function checkAFK()
    local afk = API.UnitIsAFK("player")
    if afk and not state.afkSince then
        state.afkSince = API.Time()
    elseif not afk and state.afkSince then
        flushAFK()
        state.afkSince = nil
    end
end

local function onFlagsChanged(_, unit)
    unit = CleanString(unit)
    if unit == nil or unit == "player" then checkAFK() end
end

-------------------------------------------------------------------------------
-- Jumps and emotes (secure hooks; nothing is broadcast per call)
-------------------------------------------------------------------------------
--- The post-hook runs after the jump has started, so IsFalling can't tell a real jump from
-- mid-air mashing. A jump arc lasts ~0.6 s: presses closer together than that are one jump.
local function onJump()
    if state.onTaxi or call("IsSwimming") or call("IsFlying") then return end
    local now = API.Time()
    if now - (state.lastJump or -100) < JUMP_GAP then return end
    state.lastJump = now
    add("jumps")
end

--- DoEmote may be a Lua wrapper around C_ChatInfo.PerformEmote: same token, same frame = one.
local function onEmote(token)
    token = CleanString(token)
    local now = API.Time()
    local last = state.lastEmote
    if last and last.t == now and last.token == token then return end
    state.lastEmote = { t = now, token = token }
    add("emotes")
end

local function hookInputs()
    local hsf = G("hooksecurefunc")
    if type(hsf) ~= "function" then return end
    if type(G("JumpOrAscendStart")) == "function" then
        pcall(hsf, "JumpOrAscendStart", function() GF:Safe("stats:jump", onJump) end)
    end
    if type(G("DoEmote")) == "function" then
        pcall(hsf, "DoEmote", function(token) GF:Safe("stats:emote", onEmote, token) end)
    end
    local CC = G("C_ChatInfo")
    if type(CC) == "table" and type(CC.PerformEmote) == "function" then
        pcall(hsf, CC, "PerformEmote", function(token) GF:Safe("stats:emote", onEmote, token) end)
    end
end

-------------------------------------------------------------------------------
-- Vendors, banks, mail, trade, AH: "busy" windows where bag/money changes aren't stats
-------------------------------------------------------------------------------
local function busy()
    for _, since in pairs(state.busy) do
        if since then return true end
    end
    return false
end

local scanBags -- defined with the consumables tracker

local function setBusy(what, open)
    state.busy[what] = open and API.Time() or nil   -- opened at (housekeeping expires stale ones)
    if not open then
        -- whatever moved while the window was open is the new baseline
        GF:After(0.5, function() if not busy() then state.bagSnap = scanBags() end end)
    end
end

-------------------------------------------------------------------------------
-- Money: repair bills and the (hidden-amount) wealth score
-------------------------------------------------------------------------------
local function repairCost()
    local can = G("CanMerchantRepair")
    if type(can) == "function" then
        local ok, r = pcall(can)
        if not ok or not Clean(r) then return 0 end
    end
    local f = G("GetRepairAllCost")
    if type(f) ~= "function" then return 0 end
    local ok, cost = pcall(f)
    cost = ok and CleanNumber(cost) or nil
    return (cost and cost > 0) and cost or 0
end

local function addRepair(copper)
    if not ensureTables() then return end
    local track = GF.cdb.track
    local carry = (tonumber(track.repairCopper) or 0) + copper
    local gold = floor(carry / 10000)
    track.repairCopper = carry - gold * 10000
    if gold > 0 then add("repair_gold", gold) end
end

local function wealthCheck()
    local ws = wealthScore()
    if ws ~= state.lastWs then
        state.lastWs = ws
        invalidate(false)
        schedulePublish()
        scheduleTitles()
        if GF.Profile and GF.Profile.Touch then GF.Profile:Touch() end
    end
end

local function near(a, b) return abs(a - b) <= max(1, b * 0.02) end

--- A repair (all, or one slot) shows up twice: the money drops, and the repair bill drops
-- by the same amount. PLAYER_MONEY and UPDATE_INVENTORY_DURABILITY can arrive in either
-- order, so each side is remembered for a few seconds and the second one books it.
-- (A purchase only moves the money; a mismatched pair is left to go stale.)
local REPAIR_PAIR = 3

local function matchRepair()
    local md, cd = state.moneyDrop, state.costDrop
    if not (md and cd) or abs(md.t - cd.t) > REPAIR_PAIR or not near(md.n, cd.n) then return end
    state.moneyDrop, state.costDrop = nil, nil
    addRepair(md.n)
end

--- Re-reads the bill; a drop since the last read is the cost side of a repair.
local function checkBill()
    if not state.merchant then return end
    local cost = repairCost()
    local before = state.repairPending or 0
    state.repairPending = cost
    if cost < before then
        state.costDrop = { n = before - cost, t = API.Time() }
        matchRepair()
    end
end

local function onMoney()
    local m = CleanNumber(API.Money())
    if not m then return end
    local before = state.money
    state.money = m
    if before and state.merchant and m < before then
        state.moneyDrop = { n = before - m, t = API.Time() }
        matchRepair()
        -- the durability event may never come (or come first): look at the bill ourselves too
        GF:After(0.5, checkBill)
    end
    wealthCheck()
end

local function onMerchantShow()
    state.merchant = true
    setBusy("merchant", true)
    state.money = CleanNumber(API.Money()) or state.money
    state.repairPending = repairCost()
    state.moneyDrop, state.costDrop = nil, nil
end

local function onMerchantClosed()
    state.merchant = false
    state.repairPending = 0
    state.moneyDrop, state.costDrop = nil, nil
    setBusy("merchant", false)
end

local function onDurability() checkBill() end

-------------------------------------------------------------------------------
-- System messages: duels and getting on the drink
-------------------------------------------------------------------------------
local duelPatterns, drunkLevels, drunkItemPatterns

local function buildSystemPatterns()
    duelPatterns = {}
    for _, name in ipairs({ "DUEL_WINNER_KNOCKOUT", "DUEL_WINNER_RETREAT" }) do
        local pat, order = fmtToPattern(G(name))
        if pat then duelPatterns[#duelPatterns + 1] = { pat = pat, order = order } end
    end
    -- "You feel drunk." and, when it came out of a bottle, "You drink the %s and feel drunk."
    drunkLevels, drunkItemPatterns = {}, {}
    for i = 1, 4 do
        local s = G("DRUNK_MESSAGE_SELF" .. i)
        if type(s) == "string" and s ~= "" then drunkLevels[s] = i - 1 end
        local pat, order = fmtToPattern(G("DRUNK_MESSAGE_ITEM_SELF" .. i))
        if pat then drunkItemPatterns[#drunkItemPatterns + 1] = { pat = pat, order = order, level = i - 1 } end
    end
end

local function drunkLevelOf(text)
    local level = drunkLevels[text]
    if level then return level end
    for _, p in ipairs(drunkItemPatterns) do
        if text:match(p.pat) then return p.level end
    end
    return nil
end

local function onSystem(_, text)
    text = CleanString(text)
    if not text then return end
    if not duelPatterns then buildSystemPatterns() end
    local level = drunkLevelOf(text)
    if level then
        -- 0 sober, 1 tipsy, 2 drunk, 3 smashed: count each climb into drunk-or-worse
        if level >= 2 and state.drunk < 2 then add("drunk") end
        state.drunk = level
        return
    end
    local me = API.MyKey()
    if not me then return end
    for _, p in ipairs(duelPatterns) do
        local args = matchFormat(p, text)
        if args then
            -- %1$s is always the winner, %2$s the loser
            if API.Key(U.StripCodes(args[1])) == me then
                add("duel_wins")
            elseif API.Key(U.StripCodes(args[2])) == me then
                add("duel_losses")
            end
            return
        end
    end
end

-------------------------------------------------------------------------------
-- Spellcasts: hearths, rezzes, camps; also the clock consumables pair against
-------------------------------------------------------------------------------
local function flushCastPending(now)
    local list = state.castPending
    if #list == 0 then return end
    state.castPending = {}
    local n = 0
    for _, p in ipairs(list) do
        if now - p.t <= CAST_WINDOW then n = n + p.n end
    end
    if n > 0 then add("consumables", n) end
end

local function onSpellcast(_, unit, _, spellID)
    if CleanString(unit) ~= "player" then return end
    local now = API.Time()
    state.lastCast = now
    flushCastPending(now)
    local id = CleanNumber(spellID)
    if not id then return end
    local name = CleanString(API.SpellName(id))
    local N = names()
    if id == HEARTHSTONE or (name and N.hearth[name]) then add("hearths") end
    if REZ_IDS[id] or (name and N.rez[name]) then add("rezzes") end
    if campSpells()[id] and now - state.lastCamp > 2 then
        -- a kit can fire its use-spell and the placement spell back to back: one camp
        state.lastCamp = now
        add("camps")
    end
end

local function onChannelStop(_, unit, _, spellID)
    if CleanString(unit) ~= "player" then return end
    local id = CleanNumber(spellID)
    if not id then return end
    local name = CleanString(API.SpellName(id))
    if FISHING_IDS[id] or (name and names().fishing[name]) then state.fishChannelEnd = API.Time() end
end

-------------------------------------------------------------------------------
-- Flights: count once per flight when we go onto a taxi
-------------------------------------------------------------------------------
local function checkTaxi(silent)
    local on = call("UnitOnTaxi", "player") and true or false
    if on and not state.onTaxi and not silent then add("flights") end
    state.onTaxi = on
end

local function onControlLost()
    GF:After(0.5, function() checkTaxi(false) end)
    GF:After(2.5, function() checkTaxi(false) end)
end

local function onControlGained()
    GF:After(0.5, function() checkTaxi(false) end)
end

-------------------------------------------------------------------------------
-- Loot: rare+ from raids, epics anywhere (self loot lines, encounter loot fallback)
-------------------------------------------------------------------------------
local lootPatterns

local function buildLootPatterns()
    lootPatterns = {}
    -- the multiple-count forms first, or "x2" would be swallowed into the link
    for _, name in ipairs({ "LOOT_ITEM_SELF_MULTIPLE", "LOOT_ITEM_PUSHED_SELF_MULTIPLE", "LOOT_ITEM_SELF", "LOOT_ITEM_PUSHED_SELF" }) do
        local pat, order = fmtToPattern(G(name))
        if pat then
            lootPatterns[#lootPatterns + 1] = { pat = pat, order = order, pushed = name:find("PUSHED", 1, true) ~= nil }
        end
    end
end

--- One item per id per LOOT_DEDUPE seconds, whichever source saw it first.
local function lootDupe(id)
    local now = API.Time()
    local last = state.lootSeen[id]
    if last and now - last < LOOT_DEDUPE then return true end
    state.lootSeen[id] = now
    return false
end

local function processLoot(item, inRaid, tries)
    local id = API.ItemID(item)
    if not id then return end
    local q = CleanNumber(API.ItemQuality(item))
    if q then
        if q >= 3 and inRaid then add("loot_raid") end
        if q >= 4 then add("loot_epics") end
        return
    end
    -- uncached: ask the server and look again shortly
    API.RequestItem(id)
    tries = (tries or 0) + 1
    if tries <= 5 then GF:After(1.5 * tries, function() processLoot(item, inRaid, tries) end) end
end

local function onChatLoot(_, text)
    text = CleanString(text)
    if not text then return end
    if not lootPatterns then buildLootPatterns() end
    for _, p in ipairs(lootPatterns) do
        local args = matchFormat(p, text)
        if args then
            -- "You receive item" while shopping/mailing/trading is a purchase, not loot
            if p.pushed and busy() then return end
            local link = args[1]
            local id = API.ItemID(link)
            if id and not lootDupe(id) then processLoot(link, API.InRaidInstance()) end
            return
        end
    end
end

--- Fallback for when CHAT_MSG_LOOT is secret: the boss loot event (deduped against chat).
local function onEncounterLoot(_, _, itemID, itemLink, _, playerName)
    local who = API.Key(CleanString(playerName))
    if not who or who ~= API.MyKey() then return end
    local link = CleanString(itemLink)
    local id = CleanNumber(itemID) or API.ItemID(link)
    if not id or lootDupe(id) then return end
    processLoot(link or id, API.InRaidInstance())
end

-------------------------------------------------------------------------------
-- Consumables: a potion/elixir/flask leaving the bags next to a cast of ours
-------------------------------------------------------------------------------
local consumableCache = {}

local function isConsumable(itemID)
    local c = consumableCache[itemID]
    if c ~= nil then return c end
    local _, _, _, _, _, classID, subID = API.ItemInfoInstant(itemID)
    classID, subID = CleanNumber(classID), CleanNumber(subID)
    if classID == nil then return false end -- not known yet; don't cache the guess
    c = classID == CONSUMABLE_CLASS and subID ~= nil and CONSUMABLE_SUBCLASS[subID] == true
    consumableCache[itemID] = c
    return c
end

--- { [itemID] = count } of consumables in the backpack + bags, or nil when unreadable.
scanBags = function()
    local CC = G("C_Container")
    if type(CC) ~= "table" or type(CC.GetContainerNumSlots) ~= "function" or type(CC.GetContainerItemInfo) ~= "function" then
        return nil
    end
    local counts = {}
    local lastBag = CleanNumber(G("NUM_BAG_SLOTS")) or 4
    for bag = 0, lastBag do
        local ok, n = pcall(CC.GetContainerNumSlots, bag)
        n = ok and CleanNumber(n) or 0
        for slot = 1, n do
            local ok2, info = pcall(CC.GetContainerItemInfo, bag, slot)
            if not ok2 or (info ~= nil and not API.Readable(info)) then return nil end
            if type(info) == "table" then
                local id, count = CleanNumber(info.itemID), CleanNumber(info.stackCount)
                if not id or not count then return nil end
                if isConsumable(id) then counts[id] = (counts[id] or 0) + count end
            end
        end
    end
    return counts
end

local function onBags()
    local snap = scanBags()
    local prev = state.bagSnap
    state.bagSnap = snap
    if not snap or not prev or busy() then return end
    local now = API.Time()
    for id, n in pairs(prev) do
        local d = n - (snap[id] or 0)
        -- a single use drops a stack by one; bigger drops are moves, deletes or splits
        if d > 0 and d <= 3 then
            if now - state.lastCast <= CAST_WINDOW then
                add("consumables", d)
            else
                state.castPending[#state.castPending + 1] = { n = d, t = now }
            end
        end
    end
end

--- BAG_UPDATE_DELAYED comes in bursts while looting/fighting; one bag walk per burst.
local bagsQueued = false
local function queueBags()
    if bagsQueued then return end
    bagsQueued = true
    GF:After(0.25, function()
        bagsQueued = false
        onBags()
    end)
end

-------------------------------------------------------------------------------
-- Fishing and quests
-------------------------------------------------------------------------------
local function lootSlotIsItem(slot)
    local t = call("GetLootSlotType", slot)
    if type(t) == "number" then
        local E = G("Enum")
        local item = E and E.LootSlotType and E.LootSlotType.Item or 1
        return t == item
    end
    return call("LootSlotHasItem", slot) and true or false
end

local function onLootOpened()
    local now = API.Time()
    if now - state.lastFishLoot < 1 then return end
    local fishing = call("IsFishingLoot")
    if not fishing and now - state.fishChannelEnd > FISH_WINDOW then return end
    local n = call("GetNumLootItems")
    n = type(n) == "number" and n or 0
    local items = 0
    for slot = 1, n do
        if lootSlotIsItem(slot) then items = items + 1 end
    end
    state.fishChannelEnd = -100
    if items > 0 then
        state.lastFishLoot = now
        add("fish", items)
    end
end

local function onQuestTurnedIn() add("quests") end

-------------------------------------------------------------------------------
-- Titles changing hands + badges earned from shared data (attendance)
-------------------------------------------------------------------------------
local function settled()
    local ready = GF.guildReady
    return ready and ready ~= "_noguild" and state.readyAt and API.Time() - state.readyAt >= SETTLE_TIME
end

local function postTitle(def, holder, old)
    if not (GF.Feed and GF.Feed.Post) then return end
    local text
    if old then
        text = format("%s is the new %s (%s), knocking off %s.", colored(holder), def.title, def.label, colored(old))
    else
        text = format("%s is the new %s (%s). First name on the board.", colored(holder), def.title, def.label)
    end
    GF:Safe("stats:title", GF.Feed.Post, GF.Feed, "title", text,
        { key = "title:" .. def.key .. ":" .. holder, toast = true, icon = "crown" })
end

--- Remembers every all-time holder (per guild) and announces a change only from the new
-- holder's own client, and never during the post-login sync flurry.
local function detectTitles()
    local ready = GF.guildReady
    if not ready or ready == "_noguild" or not (GF.DB and GF.DB.Local) then return end
    local loc = GF.DB:Local("Stats")
    if type(loc.holders) ~= "table" then loc.holders = {} end
    local first = not loc.init
    local announce = not first and settled()
    local me = API.MyKey()
    local myMain = me and mainOf(me)
    for _, def in ipairs(GF.Titles) do
        local top = board(def.key, "all").list[1]
        local cur = top and top.key or false
        local old = loc.holders[def.key]
        if announce and cur and cur ~= old and cur == myMain then
            postTitle(def, cur, old or nil)
        end
        loc.holders[def.key] = cur
    end
    loc.init = true
end

--- Milestones on computed stats (e.g. flakes) can't be seen in add(); compare against the
-- last value this character saw instead.
local function checkComputedBadges()
    local me = API.MyKey()
    if not me or not settled() or not ensureTables() then return end
    local seen = GF.cdb.track.computedSeen
    if type(seen) ~= "table" then
        seen = {}
        GF.cdb.track.computedSeen = seen
    end
    local m = mainOf(me)
    for stat in pairs(COMPUTED) do
        local def = GF.TitlesByKey[stat]
        if def and def.milestones then
            local v = computedValue(m, stat, "all")
            if v then
                local old = tonumber(seen[stat])
                -- the number is the main's, so only the main announces it (not every alt)
                if old and m == me then crossBadges(def, old, v) end
                seen[stat] = v
            end
        end
    end
end

recomputeTitles = function()
    GF:Safe("stats:detect", detectTitles)
    GF:Safe("stats:cbadges", checkComputedBadges)
    GF:Fire("GF_STATS_CHANGED")
end

-------------------------------------------------------------------------------
-- Player tooltip: "Greenfields: <title>, <title>" + top badge
-------------------------------------------------------------------------------
local function tooltipKey(tooltip)
    if type(tooltip.GetUnit) ~= "function" then return nil end
    local ok, name, unit = pcall(tooltip.GetUnit, tooltip)
    if not ok then return nil end
    unit = CleanString(unit)
    if unit then
        if not call("UnitIsPlayer", unit) then return nil end
        return API.UnitKey(unit)
    end
    name = CleanString(name)
    return name and API.Key(name) or nil
end

--- Inline "|T..|t " of a title's art (trimmed like an action button) for tooltip lines.
local function inlineArt(def)
    local art = type(def) == "table" and def.art
    if type(art) ~= "string" or art == "" then return "" end
    return format("|T%s:14:14:0:0:64:64:5:59:5:59|t ", art)
end

local function onUnitTooltip(tooltip)
    if not GF.db or GF.db.settings.tooltipTitles == false then return end
    if type(tooltip) ~= "table" or type(tooltip.AddLine) ~= "function" then return end
    local key = tooltipKey(tooltip)
    local R = GF.Roster
    if not key or not (R and R.IsMember and R:IsMember(key)) then return end
    -- tooltips refresh constantly; the answer only moves when the boards do (invalidate)
    local hit = tipCache[key]
    if not hit or API.Time() - hit.t > 30 then
        hit = { t = API.Time(), titles = Stats:TitlesOf(key), badge = Stats:TopBadge(key) }
        tipCache[key] = hit
    end
    local titles, badge = hit.titles, hit.badge
    if not titles[1] and not badge then return end
    if titles[1] then
        local list = { titles[1].title }
        if titles[2] then list[2] = titles[2].title end
        local c = T.c.wowGold
        tooltip:AddLine(inlineArt(titles[1]) .. "Greenfields: " .. concat(list, ", "), c[1], c[2], c[3])
    end
    if badge then
        local c = T.c.dim
        tooltip:AddLine(inlineArt(GF.TitlesByKey[badge.stat]) .. "Top badge: " .. badge.name, c[1], c[2], c[3])
    end
    if type(tooltip.Show) == "function" then tooltip:Show() end
end

-------------------------------------------------------------------------------
-- Housekeeping (30 s): AFK flush, week rollover, wealth opt-in changes, stale scratch
-------------------------------------------------------------------------------
local function housekeeping()
    flushAFK()
    checkAFK()
    local now = API.Time()
    for id, t in pairs(state.lootSeen) do
        if now - t > 60 then state.lootSeen[id] = nil end
    end
    for e, w in pairs(state.wipes) do
        if now - w.t > 60 then state.wipes[e] = nil end
    end
    for what, since in pairs(state.busy) do
        if now - since > 1800 then state.busy[what] = nil end   -- a close event we never got
    end
    -- bag drops that never met a cast (deleted potions and the like)
    if #state.castPending > 0 then
        local keep = {}
        for _, p in ipairs(state.castPending) do
            if now - p.t <= CAST_WINDOW then keep[#keep + 1] = p end
        end
        state.castPending = keep
    end
    local share = not (GF.db and GF.db.settings and GF.db.settings.shareWealth == false)
    local wk = U.WeekKey()
    if share ~= state.lastShare or wk ~= state.lastWeek then
        state.lastShare, state.lastWeek = share, wk
        wealthCheck()
        invalidate(false)
        schedulePublish()
        scheduleTitles()
    end
end

-------------------------------------------------------------------------------
-- Lifecycle and events
-------------------------------------------------------------------------------
local BUSY_EVENTS = {
    { "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "bank" },
    { "MAIL_SHOW", "MAIL_CLOSED", "mail" },
    { "TRADE_SHOW", "TRADE_CLOSED", "trade" },
    { "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "ah" },
    { "GUILDBANKFRAME_OPENED", "GUILDBANKFRAME_CLOSED", "gbank" },
}

local function onInteractShow(_, kind)
    kind = CleanNumber(kind)
    if kind then setBusy("interact" .. kind, true) end
end

local function onInteractHide(_, kind)
    kind = CleanNumber(kind)
    if kind then setBusy("interact" .. kind, false) end
end

local function resetMirror() state.mirror = {} end

function Stats:OnInit()
    if not ensureTables() then return end
    pruneWeeks()
    state.freshSV = next(GF.cdb.stats) == nil   -- see publish() / adopt()
    local owner = "Stats"
    GF:RegisterEvent("PLAYER_DEAD", onPlayerDead, owner)
    GF:RegisterEvent("PLAYER_ALIVE", function() resetMirror(); onAlive() end, owner)
    GF:RegisterEvent("PLAYER_UNGHOST", function() resetMirror(); onUnghost() end, owner)
    GF:RegisterEvent("MIRROR_TIMER_START", onMirrorStart, owner)
    GF:RegisterEvent("MIRROR_TIMER_PAUSE", onMirrorPause, owner)
    GF:RegisterEvent("MIRROR_TIMER_STOP", onMirrorStop, owner)
    GF:RegisterEvent("ENCOUNTER_START", onEncounterStart, owner)
    GF:RegisterEvent("ENCOUNTER_END", onEncounterEnd, owner)
    GF:RegisterEvent("PARTY_KILL", onPartyKill, owner)
    GF:RegisterEvent("CHAT_MSG_COMBAT_HONOR_GAIN", onHonorGain, owner)
    GF:RegisterEvent("PLAYER_PVP_KILLS_CHANGED", onPvPKillsChanged, owner)
    GF:RegisterEvent("PLAYER_FLAGS_CHANGED", onFlagsChanged, owner)
    GF:RegisterEvent("PLAYER_LOGOUT", function() flushAFK(); publish(false) end, owner)
    GF:RegisterEvent("MERCHANT_SHOW", onMerchantShow, owner)
    GF:RegisterEvent("MERCHANT_CLOSED", onMerchantClosed, owner)
    GF:RegisterEvent("UPDATE_INVENTORY_DURABILITY", onDurability, owner)
    GF:RegisterEvent("PLAYER_MONEY", onMoney, owner)
    GF:RegisterEvent("CHAT_MSG_SYSTEM", onSystem, owner)
    GF:RegisterEvent("PLAYER_CONTROL_LOST", onControlLost, owner)
    GF:RegisterEvent("PLAYER_CONTROL_GAINED", onControlGained, owner)
    GF:RegisterEvent("CHAT_MSG_LOOT", onChatLoot, owner)
    GF:RegisterEvent("ENCOUNTER_LOOT_RECEIVED", onEncounterLoot, owner)
    GF:RegisterEvent("BAG_UPDATE_DELAYED", queueBags, owner)
    GF:RegisterEvent("LOOT_OPENED", onLootOpened, owner)
    GF:RegisterEvent("QUEST_TURNED_IN", onQuestTurnedIn, owner)
    GF:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", onInteractShow, owner)
    GF:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", onInteractHide, owner)
    for _, b in ipairs(BUSY_EVENTS) do
        local what = b[3]
        GF:RegisterEvent(b[1], function() setBusy(what, true) end, owner)
        GF:RegisterEvent(b[2], function() setBusy(what, false) end, owner)
    end
    GF:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        resetMirror()
        -- a loading screen closes every vendor/bank/mail window: drop any flag whose
        -- *_CLOSED / FRAME_HIDE never arrived, or bag tracking would stay off all session
        state.busy, state.merchant, state.repairPending = {}, false, 0
        checkTaxi(true)
        GF:After(2, function() if not busy() then state.bagSnap = scanBags() end end)
    end, owner)
    GF:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", onSpellcast)
    GF:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player", onChannelStop)
end

function Stats:OnLogin()
    hookInputs()
    API.TooltipPostCall("Unit", onUnitTooltip)
    state.money = CleanNumber(API.Money())
    state.lastWs = wealthScore()
    state.lastShare = not (GF.db and GF.db.settings and GF.db.settings.shareWealth == false)
    state.lastWeek = U.WeekKey()
    checkTaxi(true)
    checkAFK()
    GF:Ticker(0.2, tick)
    GF:Ticker(30, housekeeping)
    GF:After(3, function() state.bagSnap = scanBags() end)
    -- the lifetime HK counter (when the client has one) is the only honor source after this
    GF:After(10, function() state.honorMode = readHonor() and "lifetime" or "chat" end)
end

if GF.Profile and GF.Profile.Contribute then
    GF.Profile:Contribute("wealth", function() return wealthScore() end)
end

--- Our own doc relayed back by a guildie (owner = "player": only we can author it). If
-- this character's DB started empty, the old totals come home and this session's counts
-- go on top; otherwise the bigger number wins (same character played on two PCs).
-- Badges aren't re-announced: crossBadges only fires on add().
local function adopt(d)
    if type(d) ~= "table" or not ensureTables() then return end
    local sum = state.freshSV and not state.adopted
    state.adopted = true
    local function merge(dst, src)
        if type(src) ~= "table" then return end
        for k, v in pairs(src) do
            v = SELF_KEYS[k] and sane(v)
            if v then
                v = floor(v)
                local cur = tonumber(dst[k]) or 0
                if sum then dst[k] = cur + v elseif v > cur then dst[k] = v end
            end
        end
    end
    merge(GF.cdb.stats, d.a)
    local wb, wk = weekBucket()
    if d.wk == wk then merge(wb, d.w) end
    state.holdUntil = nil
    invalidate(false)
    scheduleTitles()
    -- publish the merged doc now; a still-pending held publish finds nothing new to send
    GF:After(2, function() publish(false) end)
end

GF:On("GF_GUILD_READY", function(key)
    state.readyAt = API.Time()
    invalidate(true)
    scheduleTitles()
    GF:After(SETTLE_TIME + 2, scheduleTitles)
    if key ~= "_noguild" then
        if state.freshSV and not state.adopted then
            -- the account DB may still hold our doc even when the character DB came back empty
            local mine = GF.Store:Mine(DATASET)
            if type(mine) == "table" then
                GF:Safe("stats:adopt", adopt, mine)
            else
                state.holdUntil = API.Time() + SETTLE_TIME
            end
        end
        GF:After(6, function() publish(true) end)
    end
end)

local COMPUTED_SOURCES = { attendance = true, loot = true, profile = true, srsessions = true, reserves = true }

GF:On("GF_STORE_CHANGED", function(name, id, data, _, isRemote)
    if name == DATASET then
        if isRemote and data and id == API.MyKey() then GF:Safe("stats:adopt", adopt, data) end
        invalidate(false)
    elseif COMPUTED_SOURCES[name] then
        invalidate(true)
    else
        return
    end
    scheduleTitles()
end)

GF:On("GF_ROSTER_UPDATED", function()
    invalidate(true)
    scheduleTitles()
end)

GF:On("GF_GUILD_CHANGED", function() invalidate(true) end)

-------------------------------------------------------------------------------
-- /gf stats
-------------------------------------------------------------------------------
GF:RegisterSlash("stats", function()
    local me = API.MyKey()
    local shown = 0
    GF:Print("Your Greenfields stats (all time / this week):")
    for _, def in ipairs(GF.Titles) do
        if SELF_KEYS[def.key] then
            local a = Stats:MyValue(def.key, "all")
            if a > 0 then
                shown = shown + 1
                GF:Print("  %s: |cffffd140%s|r / %s", def.label, Stats:Format(def.key, a),
                    Stats:Format(def.key, Stats:MyValue(def.key, "week")))
            end
        elseif COMPUTED[def.key] then
            local v = Stats:MyValue(def.key, "all")
            if v > 0 then
                shown = shown + 1
                GF:Print("  %s: |cffffd140%s|r (from guild records)", def.label, Stats:Format(def.key, v))
            end
        end
    end
    if shown == 0 then GF:Print("  Nothing on the books yet. Squeaky clean. Suspicious, really.") end
    local titles = me and Stats:TitlesOf(me) or {}
    if titles[1] then
        local list = {}
        for i, def in ipairs(titles) do list[i] = def.title end
        GF:Print("  Titles held: |cffffd140%s|r", concat(list, ", "))
    end
end, "print your own tracked stats")
