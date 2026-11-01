--[[ Greenfields - Modules/Attendance.lua
     "Roll Call": raid attendance, taken automatically while the guild raids.

     One client per raid is the recorder: the raid leader if they run Greenfields, else the
     alphabetically-lowest officer in the raid who does. A roll call that is already running
     stays with whoever runs it, so a leader swap mid-raid never forks the record, and a
     recorder back from a disconnect asks the guild for newer copies before it writes
     again (a backup may have carried on without them). The
     recorder snapshots the group every 5 minutes and 3 s after every ENCOUNTER_END (logging
     the kill or wipe) and keeps everything in the replicated "attendance" dataset, so every
     guildie sees the same numbers. No combat log anywhere: presence comes from the group
     roster, kills from ENCOUNTER_END (BOSS_KILL breaks the tie when `success` is secret).

     Doc (id = startTs .. ":" .. instanceKey), short keys to stay under ~2.5 KB:
       s  start (server epoch)          e  end (nil while live)
       i  instance name                 l  recorder (leader) key
       ev linked event id (GF.Raids)    n  snapshots taken
       m  { [charKey] = { f = first seen (nil = 0), l = last seen, n = snapshots present,
                          b = boss kills present (nil = 0), late = 1|nil } }
       bo { { bossName, t, k = 1 kill | 0 wipe } }        bn { benched keys }
     Times inside m and bo are MINUTES since s; f may be negative (seen in the raid group
     before the roll call started, so the instance walk doesn't make everyone "late").
     Stats roll alts up to mains with Roster:MainOf; bench counts as attended.

     Public API (CORE_API.md section 5):
       Attendance:Percent(key, weeks)   Attendance:Summary(key)   Attendance:Raids(n)
       Attendance:IsRecording() -> liveInMyGroup, iAmTheRecorder ]]

local _, GF = ...
local API, U, UI, T = GF.API, GF.Util, GF.UI, GF.Theme
local C = T.c
local Store = GF.Store

local type, pairs, ipairs, tostring, tonumber, pcall = type, pairs, ipairs, tostring, tonumber, pcall
local floor, max, min = math.floor, math.max, math.min
local format, concat, sort, tremove = string.format, table.concat, table.sort, table.remove

local Attendance = GF:NewModule("Attendance")
GF.Attendance = Attendance

local DATASET = "attendance"
local SNAP_EVERY = 300          -- seconds between roster snapshots
local BOSS_DELAY = 3            -- snapshot this long after ENCOUNTER_END
local OUT_GRACE = 600           -- end after this long out of the instance/group
local LATE_AFTER = 900          -- first seen this long after the event start = late
local MAX_MEMBERS = 40
local MAX_BOSSES = 24
local MAX_BENCH = 20
local DOC_BUDGET = 2500         -- serialized bytes per doc: old wipes are trimmed above this
local DOC_HARD = 4000           -- members are only ever dropped above this
local OPEN_MAX_AGE = 12 * 3600  -- an open roll call older than this is treated as over
local STALE_AFTER = 12 * 60     -- open doc not written for this long has lost its recorder
local ADOPT_WINDOW = 30 * 60    -- same-instance open doc this fresh can be taken over
local PRE_MAX_AGE = 6 * 3600    -- pre-roll sightings older than this are forgotten
local RESUME_GAP = 2 * 3600     -- my roll call untouched this long belongs to another night
local SYNC_SETTLE = 25          -- wait this long for newer copies before writing to a stale doc
local WEEK = 7 * 86400
local TICK = 30
local VALID_WINDOW = { [0] = true, [4] = true, [8] = true, [12] = true }

-------------------------------------------------------------------------------
-- Small helpers
-------------------------------------------------------------------------------
--- Per-viewer page preferences (account-wide settings, our own sub-table).
local function settings()
    local s = GF.db and GF.db.settings
    if not s then return { window = 8, sort = "pct", desc = true } end
    if type(s.attendance) ~= "table" then s.attendance = {} end
    local a = s.attendance
    -- a hand-edited or older SavedVariables value would leave the dropdown blank
    if not VALID_WINDOW[a.window] then a.window = 8 end
    if type(a.sort) ~= "string" then a.sort = "pct" end
    if type(a.desc) ~= "boolean" then a.desc = true end
    return a
end

--- Per-guild, non-replicated scratch (live recorder state, pre-roll sightings, boss names).
local function localState()
    if not (GF.DB and GF.gdb) then return {} end
    return GF.DB:Local("Attendance")
end

--- Cuts a string to n bytes without leaving half a UTF-8 character behind.
local function clip(s, n)
    if type(s) ~= "string" then return nil end
    if #s <= n then return s end
    return (s:sub(1, n):gsub("[\192-\255][\128-\191]*$", ""))
end

--- Guarded call into the Raids module (loads after us, may be missing entirely).
local function raidsCall(fn, ...)
    local R = GF.Raids
    if not (R and type(R[fn]) == "function") then return nil end
    local ok, res = GF:Safe("att:raids:" .. fn, R[fn], R, ...)
    if ok then return res end
    return nil
end

local function mainOf(key)
    if type(key) ~= "string" then return nil end
    local m = GF.Roster:MainOf(key)
    if type(m) == "string" and m ~= "" then return m end
    return key
end

local function countKeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local lastBadge
local function refreshSoon()
    GF:Debounce("att-refresh", 0.4, function()
        if UI.RefreshPage then UI:RefreshPage("attendance") end
        -- the sidebar REC bubble only changes when a roll call starts or stops; roster and
        -- group churn mid-raid shouldn't re-run every page's badge each time
        local rec = (Attendance.IsRecording and Attendance:IsRecording()) and true or false
        if rec ~= lastBadge and UI.RefreshNav then
            lastBadge = rec
            UI:RefreshNav()
        end
    end)
end

-------------------------------------------------------------------------------
-- Dataset
-------------------------------------------------------------------------------
local onDocChanged -- forward (recording engine reacts to remote edits)

--- Officers write anything. Otherwise only the recorder (author == new.l) may write, and a
-- finished roll call run by someone else stays theirs. The recorder may delete its own
-- open doc (empty roll calls, or yielding to a duplicate).
local function canWrite(author, id, new, old)
    if GF.Roster:IsOfficer(author) then return true end
    if new == nil then
        return type(old) == "table" and old.l == author and not old.e
    end
    if type(new) ~= "table" or new.l ~= author then return false end
    if type(old) == "table" and old.l ~= author and old.e then return false end
    return true
end

--- Shape check for every doc we read or accept. The scalar fields are typed too: they are
-- compared, subtracted and formatted all over this file, and a malformed relay
-- (n = "5", e = {}) would otherwise break the index for everyone who received it.
local function validate(id, d)
    return type(id) == "string" and type(d) == "table" and type(d.s) == "number" and d.s == d.s -- not NaN
        and type(d.l) == "string" and (d.m == nil or type(d.m) == "table")
        and (d.bo == nil or type(d.bo) == "table") and (d.bn == nil or type(d.bn) == "table")
        and (d.n == nil or type(d.n) == "number") and (d.e == nil or type(d.e) == "number")
        and (d.i == nil or type(d.i) == "string")
end

Store:Define({
    name = DATASET, code = "at", owner = "shared",
    canWrite = canWrite, validate = validate,
    keepDays = 400,          -- a year of raiding history
    onChange = function(id, data, rec, isRemote)
        if onDocChanged then onDocChanged(id, data, rec, isRemote) end
    end,
})

-------------------------------------------------------------------------------
-- Index: every recorded raid, newest first, with per-main sets. Built lazily and
-- thrown away whenever attendance, profiles (mains), signups or the roster change.
-------------------------------------------------------------------------------
local index

local function invalidate() index = nil end

--- mainOf, memoised for the length of one index build (MainOf reads profiles and notes).
local function mainVia(cache, key)
    if type(key) ~= "string" then return nil end
    local m = cache[key]
    if m == nil then
        m = mainOf(key) or false
        cache[key] = m
    end
    return m or nil
end

--- Signed up yes/late, main never showed and wasn't benched.
local function flakesFor(d, present, bench, cache)
    local out = {}
    if d.ev == nil then return out end
    local list = raidsCall("SignupsFor", d.ev)
    if type(list) ~= "table" then return out end
    for _, su in ipairs(list) do
        if type(su) == "table" and (su.status == "yes" or su.status == "late") then
            local main = mainVia(cache, su.player or su.char)
            if main and not present[main] and not bench[main] then out[main] = true end
        end
    end
    return out
end

--- Expands one doc into the shape the stats and the UI read.
local function buildRaid(id, d, now, cache)
    cache = cache or {}
    local r = {
        id = id, doc = d, s = d.s, present = {}, late = {}, bench = {}, seen = {},
        headcount = 0, kills = 0, wipes = 0, last = d.s,
        open = d.e == nil and (now - d.s) < OPEN_MAX_AGE,
    }
    local onTime = {}
    for key, e in pairs(d.m or {}) do
        local main = type(e) == "table" and mainVia(cache, key)
        if main then
            r.headcount = r.headcount + 1
            r.present[main] = true
            -- a main is late only if every character they brought turned up late
            if e.late then r.late[main] = true else onTime[main] = true end
            local last = d.s + (tonumber(e.l) or 0) * 60
            if last > (r.seen[main] or 0) then r.seen[main] = last end
            if last > r.last then r.last = last end
        end
    end
    for main in pairs(onTime) do r.late[main] = nil end
    for _, key in ipairs(d.bn or {}) do
        local main = mainVia(cache, key)
        if main and not r.present[main] then r.bench[main] = true end
    end
    for _, b in ipairs(d.bo or {}) do
        if type(b) == "table" then
            if b.k == 1 then r.kills = r.kills + 1 else r.wipes = r.wipes + 1 end
        end
    end
    r.flakes = flakesFor(d, r.present, r.bench, cache)
    r.mains = countKeys(r.present)
    return r
end

local function getIndex()
    if index then return index end
    local list, now, cache = {}, API.ServerTime(), {}
    for id, d in pairs(Store:All(DATASET)) do
        if type(id) == "string" and validate(id, d) and (d.n or 0) > 0 then
            list[#list + 1] = buildRaid(id, d, now, cache)
        end
    end
    sort(list, function(a, b)
        if a.s ~= b.s then return a.s > b.s end
        return a.id > b.id
    end)
    index = list
    return list
end

local function cutoffFor(weeks)
    weeks = tonumber(weeks)
    if not weeks or weeks <= 0 then return nil end
    return API.ServerTime() - weeks * WEEK
end

local function raidsIn(cutoff)
    local out = {}
    for _, r in ipairs(getIndex()) do
        if not cutoff or r.s >= cutoff then out[#out + 1] = r end
    end
    return out
end

local function findRaid(id)
    for _, r in ipairs(getIndex()) do
        if r.id == id then return r end
    end
    return nil
end

--- Stats for one main over a list of raids (newest first). A live raid they haven't
-- reached yet neither counts against them nor breaks their streak.
local function statsFor(main, raids)
    local st = { attended = 0, total = 0, late = 0, flakes = 0, streak = 0, lastSeen = nil }
    local streaking = true
    for _, r in ipairs(raids) do
        local here = r.present[main] or r.bench[main]
        if here or not r.open then
            st.total = st.total + 1
            if here then
                st.attended = st.attended + 1
                if streaking then st.streak = st.streak + 1 end
            else
                streaking = false
            end
            if r.late[main] then st.late = st.late + 1 end
            if not r.open and r.flakes[main] then st.flakes = st.flakes + 1 end
            local seen = r.seen[main]
            if seen and (not st.lastSeen or seen > st.lastSeen) then st.lastSeen = seen end
        end
    end
    st.pct = U.Pct(st.attended, st.total)
    return st
end

--- Every guild main who showed, sat on the bench or flaked in the window.
local function leaderboard(weeks)
    local raids = raidsIn(cutoffFor(weeks))
    local mains = {}
    for _, r in ipairs(raids) do
        for m in pairs(r.present) do mains[m] = true end
        for m in pairs(r.bench) do mains[m] = true end
        if not r.open then for m in pairs(r.flakes) do mains[m] = true end end
    end
    local R = GF.Roster
    local rosterKnown = R:Count() > 0
    local rows = {}
    for main in pairs(mains) do
        if not rosterKnown or R:IsMember(main) or GF.Profile:Get(main) then
            local st = statsFor(main, raids)
            if st.total > 0 then
                st.key = main
                st.class = R:Class(main)
                rows[#rows + 1] = st
            end
        end
    end
    return rows, raids
end

-------------------------------------------------------------------------------
-- Public API (never errors; safe defaults when there's no data)
-------------------------------------------------------------------------------
--- Percent(key, weeks) -> 0..100 (attended incl. bench / raids recorded), nil without data.
function Attendance:Percent(key, weeks)
    local ok, res = GF:Safe("att:Percent", function()
        if type(key) ~= "string" then return nil end
        local raids = raidsIn(cutoffFor(weeks))
        if #raids == 0 then return nil end
        local st = statsFor(mainOf(key), raids)
        if st.total == 0 then return nil end
        return st.pct
    end)
    if ok then return res end
    return nil
end

--- Summary(key) -> {attended, total, pct, streak, late, flakes, lastSeen} (all time) or nil.
function Attendance:Summary(key)
    local ok, res = GF:Safe("att:Summary", function()
        if type(key) ~= "string" then return nil end
        local raids = getIndex()
        if #raids == 0 then return nil end
        local st = statsFor(mainOf(key), raids)
        if st.total == 0 then return nil end
        return {
            attended = st.attended, total = st.total, pct = st.pct, streak = st.streak,
            late = st.late, flakes = st.flakes, lastSeen = st.lastSeen,
        }
    end)
    if ok then return res end
    return nil
end

--- Raids(n) -> newest-first raid records: the doc fields (s, e, i, l, ev, n, m, bo, bn;
-- treat them as read-only) plus id, time, instance, headcount, kills, wipes, bench,
-- flakes (count) and open.
function Attendance:Raids(n)
    local ok, res = GF:Safe("att:Raids", function()
        local out = {}
        n = tonumber(n) or 10
        for _, r in ipairs(getIndex()) do
            if #out >= n then break end
            local d = r.doc
            out[#out + 1] = {
                id = r.id, s = d.s, e = d.e, i = d.i, l = d.l, ev = d.ev, n = d.n,
                m = d.m, bo = d.bo, bn = d.bn,
                time = d.s, instance = d.i, headcount = r.headcount,
                kills = r.kills, wipes = r.wipes, bench = countKeys(r.bench),
                flakes = r.open and 0 or countKeys(r.flakes), open = r.open,
            }
        end
        return out
    end)
    if ok and type(res) == "table" then return res end
    return {}
end

-------------------------------------------------------------------------------
-- Recording engine
-------------------------------------------------------------------------------
local live            -- my roll call: { id, manual, lastSnap, outSince } (mirrored to localState)
local pendingSnap     -- { kill } a snapshot that couldn't read the roster yet
local waitSince       -- watchdog: when we started waiting on a recorder who never showed
local groupLiveId     -- open roll call for my current group (mine or someone else's)
local ready = false   -- guild partition active
local lastPull        -- boss name from the last readable ENCOUNTER_START
local lastBossKillAt  -- GetTime() of the last BOSS_KILL (kill/wipe tie-breaker)
local ticker

local function saveLive()
    local st = localState()
    if live then
        st.live = { id = live.id, manual = live.manual, lastSnap = live.lastSnap, outSince = live.outSince }
    else
        st.live = nil
    end
end

--- Stable instance part of a raid id: the instanceID, else the name squashed to ASCII.
local function instanceKey(info)
    if info and info.type == "raid" then
        if type(info.id) == "number" then return tostring(info.id) end
        if type(info.name) == "string" then
            local k = info.name:gsub("[^%w]", "")
            if k ~= "" then return k end
        end
        return "raid"
    end
    return "manual"
end

local function idInstance(id) return type(id) == "string" and id:match(":(.+)$") or nil end

--- Group roster plus whether all of it was readable (the API skips secret entries).
local function readGroup()
    local list = API.GroupMembers()
    local readable = #list >= max(1, API.NumGroupMembers())
    for _, g in ipairs(list) do
        if not g.key then readable = false end
    end
    return list, readable
end

--- Is this a Greenfields raid (and not a pug we happen to be in)?
local function guildRun(group)
    local R = GF.Roster
    if R:Count() == 0 then return true end
    local n = 0
    for _, g in ipairs(group) do
        if g.key and R:IsMember(g.key) then n = n + 1 end
    end
    return n >= 2 and n * 4 >= #group
end

--- Recorder candidates in priority order: the leader, then officers A-Z. Everyone listed
-- is an online guildie who runs Greenfields.
local function candidates(group)
    local R, Comm = GF.Roster, GF.Comm
    local rosterKnown = R:Count() > 0
    local function eligible(g)
        return g.key and g.online and Comm:HasAddon(g.key) and (not rosterKnown or R:IsMember(g.key))
    end
    local out, leader = {}, nil
    for _, g in ipairs(group) do
        if g.rank == 2 and eligible(g) then leader = g.key end
    end
    if leader then out[1] = leader end
    local officers = {}
    for _, g in ipairs(group) do
        if g.key ~= leader and eligible(g) and R:IsOfficer(g.key) then officers[#officers + 1] = g.key end
    end
    sort(officers)
    for _, k in ipairs(officers) do out[#out + 1] = k end
    return out
end

--- True when at least half of my group is already on this roll call (same raid, not a
-- second guild group that happens to be in the same instance).
local function overlaps(d, group)
    if type(d.m) ~= "table" or #group == 0 then return false end
    local n = 0
    for _, g in ipairs(group) do
        if g.key and d.m[g.key] then n = n + 1 end
    end
    return n * 2 >= #group
end

--- Newest open roll call that belongs to my group: one being taken right now by me or
-- someone in the group, or (with instKey) one recorded lately in this same instance by
-- the group or with mostly the same people. A stale doc from another instance (the ZG
-- run earlier tonight whose recorder logged off) is never picked up and continued.
-- Returns id, doc, fresh.
local function findOpen(instKey, group)
    local now, me = API.ServerTime(), API.MyKey()
    local R = GF.Roster
    local bestId, best, bestFresh
    for id, d in pairs(Store:All(DATASET)) do
        if type(id) == "string" and validate(id, d) and not d.e and now - d.s < OPEN_MAX_AGE then
            local rec = Store:Rec(DATASET, id)
            local age = now - (tonumber(rec and rec.t) or d.s)
            local ours = d.l == me or R:InGroup(d.l)
            local here = instKey and instKey ~= "manual" and idInstance(id) == instKey and age < ADOPT_WINDOW
            local same = here and group and overlaps(d, group)
            if (ours and (age < STALE_AFTER or here)) or same then
                if not best or d.s > best.s or (d.s == best.s and id < bestId) then
                    bestId, best, bestFresh = id, d, age < STALE_AFTER
                end
            end
        end
    end
    return bestId, best, bestFresh
end

--- Another live roll call for my group that started first (two recorders raced).
local function findRival(myId, mine)
    local now, me = API.ServerTime(), API.MyKey()
    for id, d in pairs(Store:All(DATASET)) do
        if id ~= myId and type(id) == "string" and validate(id, d) and not d.e and d.l ~= me
            and now - d.s < OPEN_MAX_AGE and GF.Roster:InGroup(d.l) then
            local rec = Store:Rec(DATASET, id)
            local fresh = rec and now - (tonumber(rec.t) or 0) < STALE_AFTER
            if fresh and (d.s < mine.s or (d.s == mine.s and id < myId)) then return id end
        end
    end
    return nil
end

local function eventTime(evId)
    if evId == nil then return nil end
    local ev = raidsCall("Get", evId)
    return type(ev) == "table" and tonumber(ev.time) or nil
end

--- Last time anyone wrote this roll call (as far as our copy knows).
local function lastWriteOf(id, d)
    local rec = Store:Rec(DATASET, id)
    return max(d.s, tonumber(rec and rec.t) or 0)
end

local syncAsked = {} -- id -> when we asked the guild for newer copies of it
--- Is our copy of a roll call safe to write over? Store revs are timestamps, so a write
-- made from an out-of-date copy silently replaces the newer record everywhere: come back
-- from a disconnect while a backup kept the roll call going, snapshot from your old copy,
-- and their half hour of names is gone. When nobody has written it for a while, ask the
-- guild for newer copies once and hold off for a moment; if a newer one lands,
-- onDocChanged hands it over before we ever write.
local function settledFor(id, lastWrite, now)
    if now - lastWrite < STALE_AFTER then return true end
    local asked = syncAsked[id]
    if not asked or now - asked > STALE_AFTER then
        syncAsked[id] = now
        if Store.SyncNow then Store:SyncNow() end
        return false
    end
    return now - asked >= SYNC_SETTLE
end

-------------------------------------------------------------------------------
-- Pre-roll + boss names (local only)
-------------------------------------------------------------------------------
local function preRoll()
    local st = localState()
    if type(st.pre) ~= "table" then st.pre = {} end
    return st.pre
end

--- Remembers when each raider was first seen in the raid group, so the walk from the
-- summoning stone doesn't make everyone "late" once the roll call starts in the instance.
local function trackPreRoll(inRaid, group)
    if not inRaid then localState().pre = nil return end
    local p, now = preRoll(), API.ServerTime()
    for _, g in ipairs(group) do
        if g.key and g.online then
            local t = p[g.key]
            if type(t) ~= "number" or now - t > PRE_MAX_AGE then p[g.key] = now end
        end
    end
end

--- encounterID -> name, learned at runtime (IDs aren't published for Forever).
local function knownBoss(eid)
    local b = localState().bosses
    return type(b) == "table" and b[eid] or nil
end

local function rememberBoss(eid, name)
    local st = localState()
    if type(st.bosses) ~= "table" then st.bosses = {} end
    st.bosses[eid] = clip(name, 40)
end

-------------------------------------------------------------------------------
-- Snapshots
-------------------------------------------------------------------------------
--- Drops whoever was present for the fewest snapshots. Returns false when m is empty.
local function dropWeakest(m)
    local worst, worstN
    for key, e in pairs(m) do
        local n = type(e) == "table" and tonumber(e.n) or 0
        local k = tostring(key)
        if not worst or n < worstN or (n == worstN and k > tostring(worst)) then worst, worstN = key, n end
    end
    if not worst then return false end
    m[worst] = nil
    return true
end

local function applyMembers(doc, group, now, killCredit)
    local mins = floor((now - doc.s) / 60)
    local evTime = eventTime(doc.ev)
    local pre = preRoll()
    for _, g in ipairs(group) do
        local key = g.key
        if key and g.online then
            local e = doc.m[key]
            if type(e) ~= "table" then
                if countKeys(doc.m) >= MAX_MEMBERS then dropWeakest(doc.m) end
                local first = now
                local p = pre[key]
                if type(p) == "number" and p < first and doc.s - p < PRE_MAX_AGE then first = p end
                e = {}
                local f = floor((first - doc.s) / 60)
                if f ~= 0 then e.f = f end -- on time from the start: omitted to save bytes
                if evTime and first > evTime + LATE_AFTER then e.late = 1 end
                doc.m[key] = e
            end
            e.l = mins
            e.n = (tonumber(e.n) or 0) + 1
            if killCredit then e.b = (tonumber(e.b) or 0) + 1 end
        end
    end
end

local function encodedSize(doc)
    local ok, s = pcall(GF.Serialize.Encode, doc)
    return (ok and type(s) == "string") and #s or 0
end

local function oldestWipe(bo)
    for i = 1, #bo do
        if type(bo[i]) ~= "table" or bo[i].k ~= 1 then return i end
    end
    return nil
end

--- Trims a doc to its byte budget. Old wipes go first; attendance itself is only cut
-- (least-present member first) if a doc somehow blows past the hard ceiling.
local function fit(doc)
    local bo = doc.bo
    while #bo > MAX_BOSSES do tremove(bo, oldestWipe(bo) or 1) end
    local size, guard = encodedSize(doc), 0
    while size > DOC_BUDGET and guard < 80 do
        guard = guard + 1
        local cut = oldestWipe(bo)
        if cut then
            tremove(bo, cut)
        elseif size <= DOC_HARD or not dropWeakest(doc.m) then
            break
        end
        size = encodedSize(doc)
    end
end

--- A roll call that ended inside a raid instance keeps auto-start quiet there until we
-- leave, so wrapping up early doesn't instantly start a fresh one.
local function quietHere()
    local info = API.InstanceInfo()
    if info.type == "raid" then
        localState().quiet = { k = instanceKey(info), t = API.ServerTime() }
    end
end

local function handOver(why)
    if not live then return end
    GF:Debug("roll call %s: %s", tostring(live.id), tostring(why))
    live, pendingSnap = nil, nil
    saveLive()
    refreshSoon()
end

--- One roll call snapshot. `boss` = {name, kill} logs an encounter result; `credit`
-- gives everyone present a boss-kill tick.
local function snapshot(reason, boss, credit)
    if not live then return end
    local now, me = API.ServerTime(), API.MyKey()
    local cur = Store:Get(DATASET, live.id)
    if type(cur) ~= "table" or cur.e then return end
    if cur.l ~= me then handOver("taken over by " .. tostring(cur.l)) return end
    local doc = U.Copy(cur)
    doc.m = type(doc.m) == "table" and doc.m or {}
    doc.bo = type(doc.bo) == "table" and doc.bo or {}
    if boss then
        doc.bo[#doc.bo + 1] = { boss.name, floor((now - doc.s) / 60), k = boss.kill and 1 or 0 }
    end
    local group, readable = readGroup()
    if readable then
        applyMembers(doc, group, now, credit)
        doc.n = (doc.n or 0) + 1
        live.lastSnap = now
        pendingSnap = nil
    else
        -- names are secret right now (combat / encounter): retry once they read again
        pendingSnap = { kill = credit or (pendingSnap and pendingSnap.kill) or nil }
        if not boss then saveLive() return end
    end
    fit(doc)
    local ok, err = Store:Put(DATASET, live.id, doc)
    if not ok then GF:Debug("roll call write failed (%s): %s", tostring(reason), tostring(err)) end
    saveLive()
end

-------------------------------------------------------------------------------
-- Start / end
-------------------------------------------------------------------------------
--- Unique mains present and flakes for a finished doc.
local function tally(id, doc)
    local r = buildRaid(id, doc, API.ServerTime())
    return r.mains, countKeys(r.flakes)
end

local function announce(id, doc)
    local mains, flakes = tally(id, doc)
    if GF.Feed and GF.Feed.Post then
        -- the name may be an officer-typed event title: no stray escape codes into the feed
        local where = (tostring(doc.i or "the raid"):gsub("|", ""))
        local tail = flakes > 0 and format("%d flaked. You know who you are.", flakes)
            or "Nobody flaked. Mark the calendar."
        local text = format("Roll call for %s: %d %s showed up. %s", where, mains, U.Plural(mains, "local"), tail)
        GF:Safe("att:feed", GF.Feed.Post, GF.Feed, "raid", text, { key = "att:" .. id, icon = "check" })
    end
    return mains, flakes
end

--- My roll call was ended (or deleted) by someone else, e.g. an officer hit End.
local function finishLocal(id, d)
    live, pendingSnap = nil, nil
    if groupLiveId == id then groupLiveId = nil end
    saveLive()
    localState().pre = nil
    quietHere()
    if type(d) == "table" and d.e and (d.n or 0) > 0 then announce(id, d) end
    refreshSoon()
end

--- Stamps the end time on a roll call. Returns ok, doc.
local function closeDoc(id, at)
    local cur = Store:Get(DATASET, id)
    if type(cur) ~= "table" or cur.e then return false end
    local doc = U.Copy(cur)
    doc.e = max(doc.s, at or API.ServerTime())
    local ok = Store:Put(DATASET, id, doc)
    return ok and true or false, doc
end

--- Start(manual) -> ok, reason, who. Resumes my own open roll call, takes over one whose
-- recorder went quiet, or starts a fresh one linked to the current raid event.
function Attendance:Start(manual)
    if live then return true end
    local me = API.MyKey()
    if not ready or not me then return false, "loading" end
    if not API.InGroup() then return false, "solo" end
    if manual and not GF.Roster:CanManage() then return false, "perm" end
    if manual then localState().quiet = nil end
    local now = floor(API.ServerTime())
    local info = API.InstanceInfo()
    local ik = instanceKey(info)
    local openId, open, fresh = findOpen(info.type == "raid" and ik or nil, (readGroup()))
    if openId then
        if fresh and open.l ~= me and GF.Roster:InGroup(open.l) then return false, "taken", open.l end
        -- our copy of a quiet roll call may be behind (someone else picked it up): check first
        if not fresh and not settledFor(openId, lastWriteOf(openId, open), API.ServerTime()) then
            return false, "sync"
        end
        local doc = U.Copy(open)
        doc.l = me
        if Store:Put(DATASET, openId, doc) then
            live = { id = openId, manual = manual and true or nil, lastSnap = 0 }
            groupLiveId, waitSince = openId, nil
            saveLive()
            snapshot("adopt")
            refreshSoon()
            return true
        end
    end
    local ev = raidsCall("Current")
    local evId
    if type(ev) == "table" and (type(ev.id) == "string" or type(ev.id) == "number") then evId = ev.id end
    local name = (info.type == "raid" and info.name) or (type(ev) == "table" and (ev.title or ev.instance)) or "Raid night"
    local id = tostring(now) .. ":" .. ik
    local doc = { s = now, i = clip(tostring(name), 40), l = me, ev = evId, n = 0, m = {}, bo = {}, bn = {} }
    local ok, err = Store:Put(DATASET, id, doc)
    if not ok then return false, err end
    live = { id = id, manual = manual and true or nil, lastSnap = 0 }
    groupLiveId, waitSince = id, nil
    saveLive()
    snapshot("start")
    UI:Toast({ title = "Roll call", text = "Taking names. Snapshot every 5 minutes, so no hiding in the bushes.",
        icon = "check", style = "green", key = "att-start" })
    refreshSoon()
    return true
end

--- Closes my live roll call: a final snapshot first unless `at` backdates the end.
-- `silent` skips the feed post, the toast and the quiet spell (used when tidying away a
-- roll call left open from another night, which nobody needs announced the next day).
local function wrapUp(at, silent)
    local id = live.id
    if not at and API.InGroup() then snapshot("final") end
    local cur = Store:Get(DATASET, id)
    live, pendingSnap, groupLiveId = nil, nil, nil
    saveLive()
    localState().pre = nil -- the next roll call tonight starts its own "first seen" clock
    if not silent then quietHere() end
    if type(cur) == "table" and not cur.e then
        if (tonumber(cur.n) or 0) == 0 and #(cur.bo or {}) == 0 then
            Store:Delete(DATASET, id) -- nothing worth keeping
        else
            local ok, doc = closeDoc(id, at)
            if ok and not silent then
                local mains, flakes = announce(id, doc)
                UI:Toast({ title = "Roll call wrapped",
                    text = format("%d %s on the books, %d %s. The street's been told.", mains, U.Plural(mains, "local"),
                        flakes, U.Plural(flakes, "flake")),
                    icon = "check", style = flakes > 0 and "yellow" or "green", key = "att-end" })
            end
        end
    end
    refreshSoon()
    return true
end

--- End(at) closes my roll call (a final snapshot first, unless `at` backdates the end).
-- An officer can also close someone else's live roll call for the group.
function Attendance:End(at)
    if not live then
        if groupLiveId and GF.Roster:IsOfficer(API.MyKey()) then
            local ok = closeDoc(groupLiveId, at)
            if ok then
                groupLiveId = nil
                -- without this my own client would auto-start a fresh one here a few minutes later
                if not at then quietHere() end
                refreshSoon()
            end
            return ok
        end
        return false
    end
    return wrapUp(at)
end

--- IsRecording() -> a roll call is live for my group, and whether I'm the one taking it.
function Attendance:IsRecording()
    if live then return true, true end
    return groupLiveId ~= nil, false
end

-------------------------------------------------------------------------------
-- The loop: decides who records, keeps the cadence, ends the night
-------------------------------------------------------------------------------
local function resume()
    local st = localState()
    local saved = st.live
    live = nil
    if type(saved) ~= "table" or type(saved.id) ~= "string" then st.live = nil return end
    local d = Store:Get(DATASET, saved.id)
    if type(d) ~= "table" or d.e or d.l ~= API.MyKey() then st.live = nil return end
    live = { id = saved.id, manual = saved.manual, lastSnap = tonumber(saved.lastSnap) or 0,
             outSince = tonumber(saved.outSince) }
    groupLiveId = saved.id
end

local function tickLive(now, inGroup, inInst)
    local d = Store:Get(DATASET, live.id)
    if type(d) ~= "table" or d.e then finishLocal(live.id, d) return end
    if d.l ~= API.MyKey() then handOver("taken over by " .. tostring(d.l)) return end
    local lastWrite = max(lastWriteOf(live.id, d), tonumber(live.lastSnap) or 0)
    -- back from a disconnect / relog: make sure nobody took it over meanwhile before any write
    if not settledFor(live.id, lastWrite, now) then return end
    if now - d.s >= OPEN_MAX_AGE or now - lastWrite >= RESUME_GAP then
        -- left open from another night (crashed or logged off mid-raid, resumed at login):
        -- close it where it stopped instead of snapshotting tonight's raid into it
        wrapUp(lastWrite, true)
        return
    end
    local rival = findRival(live.id, d)
    if rival then
        -- two recorders raced: the later roll call bows out (the other one has the same people)
        local id = live.id
        handOver("yielding to " .. rival)
        Store:Delete(DATASET, id)
        groupLiveId = rival
        return
    end
    groupLiveId = live.id
    if inGroup and (live.manual or inInst) then
        live.outSince = nil
        if pendingSnap and not API.InCombat() then
            snapshot("retry", nil, pendingSnap.kill)
        elseif now - (live.lastSnap or 0) >= SNAP_EVERY then
            snapshot("tick")
        end
    else
        if not live.outSince then
            -- long gap since the last snapshot (logged off?): we left back then, not now
            local last = live.lastSnap or 0
            live.outSince = (last > 0 and now - last > 2 * SNAP_EVERY) and last or now
        end
        if now - live.outSince >= OUT_GRACE then Attendance:End(live.outSince) return end
    end
    saveLive()
end

local function evaluate()
    local me = API.MyKey()
    if not ready or not me then return end
    local now = API.ServerTime()
    local info = API.InstanceInfo()
    local inInst = info.type == "raid"
    local inGroup, inRaid = API.InGroup(), API.InRaid()
    local group = readGroup()
    trackPreRoll(inRaid, group)

    if live then tickLive(now, inGroup, inInst) return end
    if not inGroup then
        if groupLiveId then groupLiveId = nil; refreshSoon() end
        waitSince = nil
        return
    end

    local openId, open, fresh = findOpen(inInst and instanceKey(info) or nil, group)
    local before = groupLiveId
    groupLiveId = (inGroup and openId and fresh) and openId or nil
    if before ~= groupLiveId then refreshSoon() end
    local quiet = localState().quiet
    if type(quiet) == "table" then
        if not inInst or quiet.k ~= instanceKey(info) or now - (tonumber(quiet.t) or 0) > PRE_MAX_AGE then
            localState().quiet = nil
        else
            waitSince = nil
            return
        end
    end
    -- (no guild = no roster to tell guildies from pugs, and nobody to sync the record to)
    if not (inRaid and inInst) or not API.InGuild() or not guildRun(group) then waitSince = nil return end
    if groupLiveId and open.l ~= me then waitSince = nil return end -- someone's on it
    local list, pos = candidates(group), nil
    for i, k in ipairs(list) do
        if k == me then pos = i break end
    end
    if not pos then waitSince = nil return end
    if pos == 1 then Attendance:Start(false) return end
    -- the rightful recorder may have uninstalled: backups step in one at a time
    waitSince = waitSince or now
    if now - waitSince >= 150 + 60 * (pos - 1) then Attendance:Start(false) end
end

local function evaluateSoon(delay) GF:Debounce("att-eval", delay or 1, evaluate) end

onDocChanged = function(id, data, rec, isRemote)
    invalidate()
    if isRemote then
        if live and live.id == id then
            if type(data) ~= "table" or data.e then
                finishLocal(id, data)
            elseif data.l ~= API.MyKey() then
                handOver("taken over by " .. tostring(data.l))
            end
        elseif type(data) == "table" and not data.e and GF.Roster:InGroup(data.l) then
            groupLiveId = groupLiveId or id
        elseif groupLiveId == id then
            groupLiveId = nil
            -- my group's roll call was just wrapped by hand (End stamps "now"; the walk-out
            -- timeout backdates it): every backup recorder stays quiet in here too, or the
            -- next one in line would start a fresh roll call a few minutes later
            if type(data) == "table" and data.e and API.ServerTime() - data.e < OUT_GRACE / 2 then quietHere() end
        end
    end
    refreshSoon()
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------
GF:RegisterEvent("ENCOUNTER_START", function(_, encounterID, encounterName)
    local eid, name = API.CleanNumber(encounterID), API.CleanString(encounterName)
    if eid and name then rememberBoss(eid, name) end
    lastPull = name or (eid and knownBoss(eid)) or nil
end)

GF:RegisterEvent("BOSS_KILL", function() lastBossKillAt = API.Time() end)

-- ENCOUNTER_END(encounterID, encounterName, difficultyID, groupSize, success)
GF:RegisterEvent("ENCOUNTER_END", function(_, encounterID, encounterName, difficultyID, groupSize, success)
    if not live then return end
    local eid, cleanName = API.CleanNumber(encounterID), API.CleanString(encounterName)
    if eid and cleanName then rememberBoss(eid, cleanName) end
    local name = clip(cleanName or (eid and knownBoss(eid)) or lastPull or "Unknown boss", 40)
    local res = API.Clean(success)
    GF:After(BOSS_DELAY, function()
        local kill
        if res ~= nil then
            kill = res == 1 or res == true
        else
            -- outcome was secret: a BOSS_KILL right around the end means it died
            kill = lastBossKillAt ~= nil and API.Time() - lastBossKillAt < 15
        end
        lastPull = nil
        snapshot("boss", { name = name, kill = kill }, kill)
    end)
end)

GF:RegisterEvent("PLAYER_REGEN_ENABLED", function()
    if not (live and pendingSnap) then return end
    GF:After(1, function()
        if live and pendingSnap and not API.InCombat() then snapshot("retry", nil, pendingSnap.kill) end
    end)
end)

GF:RegisterEvent("ZONE_CHANGED_NEW_AREA", function() evaluateSoon(3) end)
GF:On("GF_GROUP_UPDATED", function() evaluateSoon(2); refreshSoon() end)
GF:On("GF_ENTER_WORLD", function() evaluateSoon(4) end)
GF:On("GF_ROSTER_UPDATED", function() invalidate(); refreshSoon() end)
GF:On("GF_STORE_CHANGED", function(name)
    if name == "profile" or name == "signups" or name == "events" then
        invalidate()
        GF:Debounce("att-refresh-ext", 1.5, refreshSoon)
    end
end)
-- pruning drops docs without a GF_STORE_CHANGED per doc
GF:On("GF_STORE_PRUNED", function(name)
    if name == DATASET or name == "profile" or name == "signups" or name == "events" then
        invalidate()
        GF:Debounce("att-refresh-ext", 1.5, refreshSoon)
    end
end)

GF:On("GF_GUILD_CHANGED", function(key)
    invalidate()
    if key ~= GF.guildReady then
        ready, live, groupLiveId, pendingSnap = false, nil, nil, nil
    else
        -- back on the partition we'd already resolved (kicked and reinvited, or one blank guild read)
        ready = true
        resume()
        if live then Store:SyncNow() end   -- so a roll call ended while we were away stays ended
    end
end)

GF:On("GF_GUILD_READY", function()
    ready = true
    invalidate()
    resume()
    if not ticker then ticker = GF:Ticker(TICK, evaluate) end
    evaluateSoon(5)
    refreshSoon()
end)

local REASONS = {
    loading = "Hang on, still loading the neighbourhood.",
    solo = "Get a group together first. You can't roll call yourself.",
    perm = "Only officers or the raid leader and assists can start a roll call.",
    sync = "There's an open roll call for this raid. Checking nobody's still on it - try again in half a minute.",
}

local function reasonText(why, who)
    if why == "taken" then return U.ShortName(who) .. " is already taking names." end
    return REASONS[why] or ("Couldn't start the roll call (" .. tostring(why) .. ").")
end

GF:RegisterSlash("rollcall", function(arg)
    arg = U.Trim(arg):lower()
    if arg == "start" then
        local ok, why, who = Attendance:Start(true)
        GF:Print(ok and "Roll call started. Taking names." or reasonText(why, who))
    elseif arg == "end" or arg == "stop" then
        GF:Print(Attendance:End() and "Roll call wrapped." or "No roll call of yours to end.")
    else
        local on, mine = Attendance:IsRecording()
        if mine then
            GF:Print("You're taking the roll call. /gf rollcall end to wrap it.")
        elseif on then
            GF:Print("A roll call is running for your raid.")
        else
            GF:Print("No roll call running. /gf rollcall start to kick one off.")
        end
    end
end, "start | end - run the raid roll call (attendance)")

-------------------------------------------------------------------------------
-- Page: Roll Call
--   header: window dropdown, Start/End roll call, Export CSV
--   live card (while a roll call runs for my group)
--   left: leaderboard of mains          right: recent raids + raid detail
-------------------------------------------------------------------------------
local P = {}          -- page widgets
local D = {}          -- detail card widgets
local selectedId      -- raid shown in the detail card
local clock           -- 1 s ticker for the live elapsed time (only while the page shows)
local refreshBoard, refreshDetail, recTip, onRecClick -- forward

local WINDOWS = {
    { value = 4, text = "Last 4 weeks" },
    { value = 8, text = "Last 8 weeks" },
    { value = 12, text = "Last 12 weeks" },
    { value = 0, text = "All time" },
}

-- Leaderboard: how far each number's right edge sits from the row's. Wide enough for its heading
-- plus the sort chevron, so a sorted column never leans on its neighbour.
local NUM_RIGHT = { flakes = 4, late = 54, streak = 92, raids = 142, pct = 186, barEdge = 228 }
local NAME_X = 54                  -- rank (20) + gap + class crest (20) + gap
local NAME_MIN, NAME_MAX, BAR_PREF, BAR_MIN = 64, 110, 72, 36
local RAID_ROW, RAIDS_SHOWN, RAIDS_MIN = 44, 4, 92
local NAME_CELL_W = 104            -- raid detail: Present's name columns
local LIVE_STAT_W = { elapsed = 88, snaps = 66, heads = 70 }
local ZERO_DASH = "\226\128\147"
local DOT = " \194\183 "
local PILL_ORDER = { "present", "bench", "flakes", "kills", "wipes" }
local SECTION_ORDER = { "present", "bench", "flakes", "bosses" }

local MEDALS = { C.wowGold, { 0.80, 0.82, 0.86, 1 }, { 0.82, 0.54, 0.30, 1 } }   -- 1st, 2nd, 3rd
--- Quest-log art per raid (classic-era icon files), the same set the dashboard uses.
local RAID_ART = {
    ["Barrow Deeps"] = "Interface\\Icons\\INV_Misc_Bone_ElfSkull_01",
    ["Hyjal Summit"] = "Interface\\Icons\\Spell_Nature_Tranquility",
    ["Onyxia's Lair"] = "Interface\\Icons\\INV_Misc_Head_Dragon_01",
}
local RAID_ART_DEFAULT = "Interface\\Icons\\INV_Misc_Head_Dragon_Black"
local ART_INDENT = 40                -- detail card: text starts right of the 32px raid art

local function raidArt(name)
    return (type(name) == "string" and RAID_ART[name]) or RAID_ART_DEFAULT
end

--- Puts a raid's art into a framed icon, skipping the work when it's already showing.
local function setRaidArt(fi, name)
    local art = raidArt(name)
    if fi.artPath ~= art then
        fi.artPath = art
        fi:SetIcon(art)
    end
end

--- The bars are muted, so the names stay the first thing you read; only a poor record shouts.
local function pctBar(p)
    if p >= 80 then return { 0.22, 0.60, 0.38, 1 } end
    if p >= 50 then return { 0.80, 0.62, 0.14, 1 } end
    return { 0.78, 0.28, 0.26, 1 }
end

local function pctText(p)
    if p >= 80 then return "text" end
    if p >= 50 then return "yellow" end
    return "red"
end

--- Inline media icon for FontStrings, tinted with a theme colour.
local function glyph(name, size, color)
    local c = UI.col(color or "dim")
    return format("|T%s:%d:%d:0:0:32:32:0:32:0:32:%d:%d:%d|t", T.Icon(name), size, size,
        floor(c[1] * 255 + 0.5), floor(c[2] * 255 + 0.5), floor(c[3] * 255 + 0.5))
end

--- Replicated strings are shown as text, never as markup.
local function plain(s) return U.ChatSafe(tostring(s or "")) end

local function named(key)
    if type(key) ~= "string" then return "?" end
    if key:find("|", 1, true) then key = key:gsub("|", "") end
    return GF.Roster:Colored(key)
end

local function windowLabel(w)
    for _, it in ipairs(WINDOWS) do
        if it.value == w then return it.text end
    end
    return "All time"
end

local function emptyLine(key, fallback)
    local F = GF.Flavor
    return (F and F.emptyStates and F.emptyStates[key]) or fallback
end

local function liveDoc()
    local id = live and live.id or groupLiveId
    local d = id and Store:Get(DATASET, id)
    if type(d) == "table" and not d.e then return id, d end
    return nil
end

local function canBench(d)
    local me = API.MyKey()
    return GF.Roster:IsOfficer(me) or (live ~= nil and d ~= nil and d.l == me)
end

-------------------------------------------------------------------------------
-- Sorting + export
-------------------------------------------------------------------------------
local SORTS = {
    name = function(r) return U.ShortName(r.key):lower() end,
    pct = function(r) return r.pct end,
    attended = function(r) return r.attended end,
    streak = function(r) return r.streak end,
    late = function(r) return r.late end,
    flakes = function(r) return r.flakes end,
}

local function sortRows(rows)
    local s = settings()
    if not SORTS[s.sort] then s.sort, s.desc = "pct", true end -- keeps a header highlighted
    local keyFn = SORTS[s.sort]
    local desc = s.desc and true or false
    sort(rows, function(a, b)
        local ka, kb = keyFn(a), keyFn(b)
        if ka ~= kb then
            if desc then return ka > kb end
            return ka < kb
        end
        if a.pct ~= b.pct then return a.pct > b.pct end
        if a.attended ~= b.attended then return a.attended > b.attended end
        return a.key < b.key
    end)
    return rows
end

local function csvField(s)
    s = tostring(s or "")
    if s:find('[,"\n]') then s = '"' .. (s:gsub('"', '""')) .. '"' end
    return s
end

local function exportCSV()
    local w = settings().window
    local rows = leaderboard(w)
    sortRows(rows)
    if #rows == 0 then
        UI:Toast({ title = "Nothing to export", text = "No raids in this window. The spreadsheet stays as empty as the servo at 4am.",
            icon = "export", style = "yellow" })
        return
    end
    local lines = { "Name,Attended,Total,Pct,Late,Flakes,Streak" }
    for _, r in ipairs(rows) do
        lines[#lines + 1] = concat({ csvField(U.ShortName(r.key)), r.attended, r.total, r.pct, r.late, r.flakes, r.streak }, ",")
    end
    UI:CopyBox("Roll call export", concat(lines, "\n"), nil,
        windowLabel(w) .. ". Ctrl+C to copy, then paste it into your spreadsheet of shame.")
end

-------------------------------------------------------------------------------
-- Bench picker
-------------------------------------------------------------------------------
local function toggleBench(id, key)
    local cur = Store:Get(DATASET, id)
    if type(cur) ~= "table" or cur.e then return end
    local doc = U.Copy(cur)
    doc.bn = type(doc.bn) == "table" and doc.bn or {}
    local removed = false
    for i = #doc.bn, 1, -1 do
        if doc.bn[i] == key then tremove(doc.bn, i); removed = true end
    end
    if not removed then
        if #doc.bn >= MAX_BENCH then
            UI:Toast({ title = "Bench is full", text = "Twenty on the pine is plenty. Untick someone first.", icon = "warning", style = "yellow" })
            return
        end
        doc.bn[#doc.bn + 1] = key
    end
    local ok, err = Store:Put(DATASET, id, doc)
    if not ok then
        UI:Toast({ title = "Nah", text = "Couldn't update the bench (" .. tostring(err) .. ").", icon = "lock", style = "red" })
    end
end

--- Online guildies who aren't in the raid, as their mains (benched ones first, so they
-- can be unticked). Someone sitting out on an alt still shows up under their main.
local function benchMenu(anchor)
    local id, d = liveDoc()
    if not d then return end
    local benched = {}
    for _, k in ipairs(d.bn or {}) do
        if type(k) == "string" then benched[k] = true end
    end
    local inRaid = {}
    for _, g in ipairs(API.GroupMembers()) do
        if g.key then inRaid[mainOf(g.key)] = true end
    end
    local items, listed = { { text = "Tick who's on the bench", title = true } }, {}
    local function add(key)
        if listed[key] then return end
        listed[key] = true
        items[#items + 1] = { text = named(key), value = key, checked = benched[key] or nil,
            func = function() toggleBench(id, key) end }
    end
    for _, k in ipairs(U.Keys(benched)) do add(k) end
    local sitting = {}
    for _, m in ipairs(GF.Roster:List(function(m) return m.online and m.key ~= nil end)) do
        local main = mainOf(m.key)
        if main and not inRaid[main] then sitting[main] = true end
    end
    for _, k in ipairs(U.Keys(sitting)) do add(k) end
    if #items == 1 then items[2] = { text = "Everyone online is already in. Legends.", disabled = true } end
    UI:OpenMenu(anchor, items, { width = 210, point = "TOPRIGHT", relPoint = "BOTTOMRIGHT" })
end

-------------------------------------------------------------------------------
-- Live card
-------------------------------------------------------------------------------
local function stopClock()
    if clock then clock:Cancel(); clock = nil end
end

local function stopPulse()
    if P.rec and P.rec.pulse then P.rec.pulse:Stop(); P.rec:SetAlpha(1) end
end

local function updateClock()
    -- the window can close without the page's onHide firing: stop ticking when unseen
    if not (P.page and P.page:IsVisible()) then stopClock(); stopPulse() return end
    local _, d = liveDoc()
    if d and P.liveElapsed then P.liveElapsed:SetText(U.Duration(API.ServerTime() - d.s)) end
end

--- The right-hand stats sit against the card's edge, left of whichever buttons are showing, and
-- the raid's name and facts get everything left over.
local function layoutLiveStats()
    local b = P.live and P.live.body
    if not b then return end
    local w = b:GetWidth() or 0
    local x = 0
    if P.benchBtn:IsShown() then x = x + (P.benchBtn:GetWidth() or 70) end
    if P.snapBtn:IsShown() then x = x + 24 + (x > 0 and 4 or 0) end
    if x > 0 then x = x + 16 end
    -- rarely wanted, and the first thing to give way on a small window
    P.liveStats.snaps:SetShown(w >= 680)
    P.liveDividers[2]:SetShown(w >= 680)
    for i, key in ipairs({ "heads", "snaps", "elapsed" }) do
        local s = P.liveStats[key]
        if s:IsShown() then
            x = x + LIVE_STAT_W[key]
            s:ClearAllPoints()
            s:SetPoint("BOTTOMLEFT", b, "BOTTOMRIGHT", -x, 8)
            local div = P.liveDividers[i]
            if div then
                div:ClearAllPoints()
                div:SetPoint("TOPLEFT", b, "TOPRIGHT", -(x + 10), -10)
                div:SetPoint("BOTTOMLEFT", b, "BOTTOMRIGHT", -(x + 10), 8)
            end
            x = x + 20
        end
    end
    P.liveMeta:SetPoint("TOPRIGHT", -x, -24)
    P.liveBosses:SetPoint("TOPRIGHT", -x, -40)
end

local function refreshLive()
    local id, d = liveDoc()
    if not d then
        P.live:Hide()
        stopPulse()
        stopClock()
        return false
    end
    P.live:Show()
    if not (P.rec.pulse and P.rec.pulse:IsPlaying()) then UI:Pulse(P.rec) end
    P.liveName:SetText(plain(d.i or "Raid night"))
    setRaidArt(P.liveArt, d.i)
    local meta = "Taken by " .. named(d.l)
    local ev = d.ev ~= nil and raidsCall("Get", d.ev) or nil
    if type(ev) == "table" and type(ev.title) == "string" then meta = meta .. DOT .. plain(ev.title) end
    P.liveMeta:SetText(meta)
    local kills, wipes = 0, 0
    for _, b in ipairs(d.bo or {}) do
        if type(b) == "table" then
            if b.k == 1 then kills = kills + 1 else wipes = wipes + 1 end
        end
    end
    local bosses
    if kills + wipes == 0 then
        bosses = "No pulls yet. Trash is trash."
    else
        bosses = T:Wrap("green", kills .. " down") .. "   " .. T:Wrap("red", wipes .. " " .. U.Plural(wipes, "wipe"))
    end
    -- who's on the pine is for everyone to see, not just whoever holds the Bench button
    if #(d.bn or {}) > 0 then
        local names = {}
        for _, k in ipairs(d.bn) do names[#names + 1] = named(k) end
        bosses = bosses .. T:Wrap("dim", DOT .. "Bench: ") .. concat(names, ", ")
    end
    P.liveBosses:SetText(bosses)
    -- a boss just went down on this roll call: the card catches the light
    if P.killsFor == id and kills > (P.kills or 0) then UI:Shine(P.live, 1.0) end
    P.killsFor, P.kills = id, kills
    P.liveSnaps:SetText(tostring(d.n or 0))
    local heads = 0
    for _, g in ipairs(API.GroupMembers()) do
        if g.online then heads = heads + 1 end
    end
    P.liveHeads:SetText(tostring(heads))
    updateClock()
    local benched = #(d.bn or {})
    P.benchBtn:SetShown(canBench(d))
    P.benchBtn:SetText(benched > 0 and ("Bench (" .. benched .. ")") or "Bench")
    P.snapBtn:SetShown(live ~= nil and live.id == id)
    layoutLiveStats()
    if not clock then clock = GF:Ticker(1, updateClock) end
    return true
end

--- Who's on the pine, for the button's tooltip.
local function benchTip()
    local lines = { "Tick online guildies sitting out tonight. Bench counts as attended." }
    local _, d = liveDoc()
    if d and #(d.bn or {}) > 0 then
        local names = {}
        for _, k in ipairs(d.bn) do names[#names + 1] = named(k) end
        lines[#lines + 1] = " "
        lines[#lines + 1] = concat(names, ", ")
    end
    return { "Bench", lines }
end

local function buildLive(page)
    -- while a roll call runs it's what the page is about: the one gold rim here, flush with the
    -- columns below it
    local card = UI:Card(page, { tier = "hero" })
    card:SetHeight(84)
    card:SetPoint("TOPLEFT", P.header, "BOTTOMLEFT", 0, -14)
    card:SetPoint("TOPRIGHT", P.header, "BOTTOMRIGHT", 0, -14)
    P.live = card

    local b = card.body
    P.liveArt = UI:FramedIcon(b, 48, RAID_ART_DEFAULT, "gold")
    P.liveArt:SetPoint("LEFT", 0, 0)
    P.liveName = UI:Text(b, 18, "wowGold", "title")
    P.liveName:SetPoint("TOPLEFT", 60, -1)
    P.rec = UI:Pill(b, "REC", "red", { icon = "dot", height = 18 })
    P.rec:SetPoint("LEFT", P.liveName, "RIGHT", 10, 0)
    P.liveMeta = UI:Text(b, 11, "dim")
    P.liveMeta:SetPoint("TOPLEFT", 60, -24)
    P.liveMeta:SetPoint("TOPRIGHT", 0, -24)
    P.liveBosses = UI:Text(b, 11, "dim")
    P.liveBosses:SetPoint("TOPLEFT", 60, -40)
    P.liveBosses:SetPoint("TOPRIGHT", 0, -40)

    P.liveStats = {
        elapsed = UI:Stat(b, { value = "0s", label = "Elapsed", size = 22 }),
        snaps = UI:Stat(b, { value = "0", label = "Snapshots" }),
        heads = UI:Stat(b, { value = "0", label = "Headcount" }),
    }
    -- these tick by themselves, so they get fixed columns rather than sizing to their text
    P.liveStats.elapsed:SetSize(LIVE_STAT_W.elapsed, 38)
    P.liveStats.snaps:SetSize(LIVE_STAT_W.snaps, 36)
    P.liveStats.heads:SetSize(LIVE_STAT_W.heads, 36)
    P.liveElapsed = P.liveStats.elapsed.value
    P.liveSnaps = P.liveStats.snaps.value
    P.liveHeads = P.liveStats.heads.value
    P.liveDividers = {}
    for i = 1, 2 do
        P.liveDividers[i] = UI:Tex(b, "ARTWORK", { C.bronze[1], C.bronze[2], C.bronze[3], 0.3 })
        P.liveDividers[i]:SetWidth(1)
    end

    P.benchBtn = UI:Button(b, "Bench", { icon = "plus", height = 24, onClick = function(self) benchMenu(self) end, tooltip = benchTip })
    P.benchBtn:SetPoint("RIGHT", 0, 0)
    P.snapBtn = UI:IconButton(b, "sync", 24, "Take a snapshot now", function()
        if not live then return end
        local since = API.ServerTime() - (live.lastSnap or 0)
        if since < 30 then
            UI:Toast({ title = "Easy, tiger", text = "Last snapshot was " .. since .. "s ago. Nobody's snuck off yet.", icon = "clock", style = "yellow" })
            return
        end
        snapshot("manual")
        refreshSoon()
    end)
    P.snapBtn:SetPoint("RIGHT", P.benchBtn, "LEFT", -4, 0)
    card:Hide()
end

-------------------------------------------------------------------------------
-- Leaderboard
-------------------------------------------------------------------------------
local function verdict(st)
    if st.flakes >= 3 then return "Signs up, never shows. A Greenfields classic." end
    if st.pct >= 90 then return "Turns up more reliably than a 3am servo pie." end
    if st.pct >= 70 then return "Solid local. Rocks up, does the job." end
    if st.pct >= 50 then return "Here about as often as the bus runs on time." end
    return "Rarer than a shopping trolley with four working wheels."
end

local function rowTip(row, st)
    local lines = {
        { "Attended", format("%d of %d %s", st.attended, st.total, U.Plural(st.total, "raid")) },
        { "Streak", tostring(st.streak) },
        { "Late", tostring(st.late) },
        { "Flaked", tostring(st.flakes) },
        { "Last seen", st.lastSeen and U.Ago(st.lastSeen) or "never" },
    }
    local alts = GF.Roster:AltsOf(st.key)
    if #alts > 0 then
        local names = {}
        for i = 1, min(#alts, 6) do names[#names + 1] = named(alts[i]) end
        lines[#lines + 1] = { "Alts", concat(names, ", ") }
    end
    lines[#lines + 1] = " "
    lines[#lines + 1] = T:Wrap("dim", verdict(st))
    UI:Tip(row, named(st.key), lines)
end

--- Where the leaderboard's columns sit in a row this wide. Header and rows read the same numbers.
-- Numbers keep their column at every size; the name flexes, and the bar is first to go.
local function boardColumns(w)
    local room = w - NAME_X - 8 - NUM_RIGHT.barEdge
    local name = U.Clamp(room - BAR_PREF, NAME_MIN, NAME_MAX)
    local bar = room - name
    if bar < BAR_MIN then
        return { name = min(NAME_MAX, room), bar = 0 }
    end
    return { name = name, bar = bar }
end

--- A number or a quiet dash: a zero isn't worth reading.
local function setCount(fs, n, color)
    if n > 0 then
        fs:SetText(tostring(n))
        UI:SetTextColor(fs, color)
    else
        fs:SetText(ZERO_DASH)
        UI:SetTextColor(fs, "faint")
    end
end

local function numCell(row, key)
    local fs = UI:Text(row, 12, "text", "num")
    fs:SetPoint("RIGHT", row, "RIGHT", -NUM_RIGHT[key], 0)
    fs:SetJustifyH("RIGHT")
    return fs
end

local function createBoardRow(row)
    row.rank = UI:Text(row, 12, "faint", "num")
    row.rank:SetPoint("LEFT", 0, 0)
    row.rank:SetWidth(20)
    row.rank:SetJustifyH("RIGHT")
    row.crest = UI:IconChip(row, 20)
    row.crest:SetPoint("LEFT", 26, 0)
    row.name = UI:Text(row, 12, "text", "ui")
    row.name:SetPoint("LEFT", row, "LEFT", NAME_X, 0)
    row.pct = numCell(row, "pct")
    row.xy = numCell(row, "raids")
    row.streak = numCell(row, "streak")
    row.late = numCell(row, "late")
    row.flakes = numCell(row, "flakes")
    row.flame = UI:Icon(row, 12, "flame", "ARTWORK", "gold")
    row.flame:Hide()
    row.bar = UI:Bar(row, { height = 8 })
    row.bar:SetPoint("RIGHT", row, "RIGHT", -NUM_RIGHT.barEdge, 0)
    -- the podium: a soft wash from the left on the top three
    row.podium = row:CreateTexture(nil, "BACKGROUND", nil, 3)
    row.podium:SetAllPoints()
    row.podium:Hide()
end

local function updateBoardRow(row, st, idx)
    row.rank:SetText(tostring(idx))
    local medal = MEDALS[idx]
    UI:SetTextColor(row.rank, medal or "dim")
    if medal then
        UI:Gradient(row.podium, "HORIZONTAL", medal[1], medal[2], medal[3], 0.09, 0)
        row.podium:Show()
    else
        row.podium:Hide()
    end
    API.SetClassIcon(row.crest.icon, st.class)
    local cols = boardColumns(row:GetWidth() or 0)
    row.name:SetWidth(cols.name)
    row.name:SetText(named(st.key))
    row.bar:SetShown(cols.bar > 0)
    if cols.bar > 0 then
        row.bar:SetWidth(cols.bar)
        row.bar:SetColor(pctBar(st.pct))
        row.bar:SetValue(st.pct / 100)
    end
    row.pct:SetText(st.pct .. "%")
    UI:SetTextColor(row.pct, pctText(st.pct))
    row.xy:SetText(st.attended .. "/" .. st.total)
    UI:SetTextColor(row.xy, "dim")
    setCount(row.streak, st.streak, st.streak >= 3 and "gold" or "text")
    -- the flame is earned: when it shows, it means something
    row.flame:SetShown(st.streak >= 3)
    if st.streak >= 3 then
        row.flame:ClearAllPoints()
        row.flame:SetPoint("RIGHT", row, "RIGHT", -(NUM_RIGHT.streak + (row.streak:GetStringWidth() or 8) + 2), 0)
    end
    setCount(row.late, st.late, "yellow")
    setCount(row.flakes, st.flakes, "red")
end

--- A sortable column heading. Numeric ones sit flush right over their numbers, with the chevron on
-- the far side of the label so turning it on doesn't shift anything.
local function sortButton(parent, text, key, short, left)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(18)
    b.key = key
    b.label = UI:Text(b, 11, "bronze", "ui")
    b.chev = UI:Icon(b, 9, "chevron_down", "OVERLAY", "wowGold")
    if left then
        b.label:SetPoint("LEFT", 0, 0)
        b.chev:SetPoint("LEFT", b.label, "RIGHT", 3, 0)
    else
        b.label:SetPoint("RIGHT", 0, 0)
        b.chev:SetPoint("RIGHT", b.label, "LEFT", -3, 0)
    end
    --- narrow: show the short label (the column under it has shrunk)
    function b:Fit(narrow)
        self.label:SetText((narrow and short) or text)
        self:SetWidth((self.label:GetStringWidth() or 30) + 12)
    end
    b:Fit(false)
    b:SetScript("OnClick", function(self)
        local s = settings()
        if s.sort == self.key then
            s.desc = not s.desc
        else
            s.sort, s.desc = self.key, self.key ~= "name"
        end
        UI.Sound(841)
        refreshBoard()
    end)
    b:SetScript("OnEnter", function(self)
        if settings().sort ~= self.key then UI:SetTextColor(self.label, "text") end
        UI:Tip(self, nil, { "Sort by " .. text:lower() .. ". Click again to flip it." })
    end)
    b:SetScript("OnLeave", function(self)
        if settings().sort ~= self.key then UI:SetTextColor(self.label, "bronze") end
        UI:HideTip()
    end)
    return b
end

local function buildBoard(page)
    local card = UI:Card(page, { title = "Leaderboard", icon = "trophy" })
    P.board = card
    local hdr = CreateFrame("Frame", nil, card.body)
    hdr:SetHeight(18)
    hdr:SetPoint("TOPLEFT", 0, 0)
    hdr:SetPoint("TOPRIGHT", 0, 0)
    hdr.rule = UI:Hairline(hdr, "bronze", 0.4, "none")
    hdr.rule:SetPoint("BOTTOMLEFT")
    hdr.rule:SetPoint("BOTTOMRIGHT")
    P.hdr = hdr
    local function at(b, right)
        b:SetPoint("RIGHT", hdr, "RIGHT", -right, 0)
        return b
    end
    local resident = sortButton(hdr, "Resident", "name", nil, true)
    resident:SetPoint("LEFT", hdr, "LEFT", 26, 0)
    P.sorts = {
        resident,
        at(sortButton(hdr, "Attendance", "pct", "%"), NUM_RIGHT.pct),
        at(sortButton(hdr, "Raids", "attended"), NUM_RIGHT.raids),
        at(sortButton(hdr, "Streak", "streak"), NUM_RIGHT.streak),
        at(sortButton(hdr, "Late", "late"), NUM_RIGHT.late),
        at(sortButton(hdr, "Flakes", "flakes"), NUM_RIGHT.flakes),
    }
    -- without a bar under it, the full Attendance label would run into Resident
    hdr:SetScript("OnSizeChanged", function(self, w)
        P.sorts[2]:Fit(boardColumns(w or self:GetWidth() or 0).bar == 0)
    end)
    P.list = UI:List(card.body, {
        rowHeight = 32,
        spacing = 0,
        createRow = createBoardRow,
        updateRow = updateBoardRow,
        onEnter = function(row, item)
            rowTip(row, item)
            -- the podium catches the light (only when ranked by attendance, best first)
            local s = settings()
            if (row.index or 99) <= 3 and s.sort == "pct" and s.desc then UI:Shine(row, 0.6) end
        end,
        onClick = function(item)
            if UI.OpenProfile then UI:OpenProfile(item.key) end
        end,
    })
    -- the kit keeps 10 spare on a row's right for the scrollbar: hang that in the card's margin
    -- so the numbers finish under their headings
    P.list:SetPoint("TOPLEFT", 0, -20)
    P.list:SetPoint("BOTTOMRIGHT", 10, 0)
    P.boardEmpty = UI:Empty(card.body, "", "trophy", { action = "Start roll call", actionStyle = "primary",
        onAction = function() onRecClick() end })
    UI.AttachTip(P.boardEmpty.action, function() return recTip() end)
    P.boardEmpty:Hide()
    -- launch morning: not two half-dead columns, one block on the page, like Raid Nights
    local ground = CreateFrame("Frame", nil, page)
    ground:SetPoint("TOPLEFT", P.header, "BOTTOMLEFT", 0, -14)
    ground:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
    P.bareEmpty = UI:Empty(ground, "", "trophy", { heading = "The oval's empty", width = 540,
        action = "Start roll call", actionStyle = "primary", actionIcon = "check",
        onAction = function() onRecClick() end })
    UI.AttachTip(P.bareEmpty.action, function() return recTip() end)
    P.bareEmpty:Hide()
end

refreshBoard = function()
    if not P.board then return end
    local s = settings()
    local rows = leaderboard(s.window)
    sortRows(rows)
    -- nothing anywhere and no roll call running: the page says so once, and the cards step aside
    local bare = #rows == 0 and (P.raidCount or 0) == 0 and not P.live:IsShown()
    P.bare = bare
    P.board:SetShown(not bare)
    P.raids:SetShown(not bare)
    P.bareEmpty:SetShown(bare)
    if bare then
        P.bareEmpty:SetText((#getIndex() == 0 and emptyLine("attendance", "No raids recorded yet.")
            or "Nobody's raided in this window. Someone's squatting in the instance.")
            .. "\nNo roll calls on the books. Either nobody raided or nobody was game enough to count."
            .. "\nNothing to pick apart yet. The first roll call lands here.")
        P.bareEmpty.action:SetShown(GF.Roster:CanManage())
        P.bareEmpty.action:SetActive(API.InGroup())
    end
    if #rows == 0 then
        P.list:SetItems({})
        P.list:Hide()
        P.hdr:Hide()
        P.boardEmpty:SetText(#getIndex() == 0 and emptyLine("attendance", "No raids recorded yet.")
            or "Nobody's raided in this window. Someone's squatting in the instance.")
        -- the same button as the header's, in the same state, because here's where the eye lands
        local act = P.boardEmpty.action
        local on = Attendance:IsRecording()
        act:SetShown(not on and GF.Roster:CanManage())
        act:SetActive(API.InGroup())
        P.boardEmpty:Show()
    else
        P.boardEmpty:Hide()
        P.hdr:Show()
        P.list:Show()
        P.list:SetItems(rows, true)
    end
    for _, b in ipairs(P.sorts) do
        local on = s.sort == b.key
        UI:SetTextColor(b.label, on and "wowGold" or "bronze")
        b.chev:SetShown(on)
        if on then b.chev:SetRotation(s.desc and 0 or math.pi) end
    end
end

-------------------------------------------------------------------------------
-- Recent raids + detail
-------------------------------------------------------------------------------
local function createRaidRow(row)
    -- the kit's selection wash and bar, in the game's gold
    UI:Gradient(row.sel, "HORIZONTAL", C.wowGold[1], C.wowGold[2], C.wowGold[3], 0.08, 0.08)
    row.selBar:SetColorTexture(C.wowGold[1], C.wowGold[2], C.wowGold[3], 1)
    -- a fixed gutter, so a live raid's dot doesn't push its name out of line with the date under it
    row.dot = UI:Icon(row, 8, "dot", "ARTWORK", "red")
    row.dot:SetPoint("TOPLEFT", 4, -10)
    row.title = UI:Text(row, 12, "text", "ui")
    row.title:SetPoint("TOPLEFT", 16, -7)
    row.title:SetPoint("TOPRIGHT", row, "TOPRIGHT", -74, -7)
    row.sub = UI:Text(row, 11, "dim")
    row.sub:SetPoint("TOPLEFT", 16, -24)
    row.sub:SetPoint("TOPRIGHT", row, "TOPRIGHT", -74, -24)
    row.kills = UI:Text(row, 12, "green", "num")
    row.kills:SetPoint("TOPRIGHT", -4, -7)
    row.wipes = UI:Text(row, 12, "red", "num")
    row.wipes:SetPoint("TOPRIGHT", -4, -24)
end

local function updateRaidRow(row, r)
    local d = r.doc
    row.dot:SetShown(r.open and true or false)
    UI:SetTextColor(row.title, r.id == selectedId and "wowGold" or "text")
    if r.kills > 0 then
        row.kills:SetText(r.kills .. " down")
        UI:SetTextColor(row.kills, "green")
    else
        row.kills:SetText("no kills")
        UI:SetTextColor(row.kills, "dim")
    end
    row.wipes:SetText(r.wipes > 0 and (r.wipes .. " " .. U.Plural(r.wipes, "wipe")) or "")
    -- the name and date get whatever the counts on the right don't use
    row.title:SetPoint("TOPRIGHT", row, "TOPRIGHT", -((row.kills:GetStringWidth() or 60) + 12), -7)
    row.sub:SetPoint("TOPRIGHT", row, "TOPRIGHT", r.wipes > 0 and -((row.wipes:GetStringWidth() or 40) + 12) or -4, -24)
    row.title:SetText(plain(d.i or "Raid night"))
    local when = U.DateTime(d.s)
    if (row:GetWidth() or 0) < 284 then when = when:match("^(.-),") or U.DateShort(d.s) end -- "Thu 3 Dec"
    row.sub:SetText(when .. DOT .. r.mains .. " " .. U.Plural(r.mains, "local"))
end

--- Present reads as columns of names when there's room; a comma list is hard to scan at 25.
local function layoutNames(content, names, y, w)
    local cols = max(1, floor(w / NAME_CELL_W))
    local cw = floor(w / cols)
    D.nameCells = D.nameCells or {}
    for i, text in ipairs(names) do
        local cell = D.nameCells[i]
        if not cell then
            cell = UI:Text(content, 12, "dim")
            D.nameCells[i] = cell
        end
        local col = (i - 1) % cols
        local line = floor((i - 1) / cols)
        cell:ClearAllPoints()
        cell:SetPoint("TOPLEFT", content, "TOPLEFT", col * cw, -(y + line * 18))
        cell:SetWidth(cw - 6)
        cell:SetText(text)
        cell:Show()
    end
    return y + math.ceil(#names / cols) * 18
end

local function layoutDetail()
    local sf, content = P.detailScroll, P.detailContent
    if not sf or not sf:IsShown() then return end
    -- leave the scrollbar its own lane instead of writing under it
    local w = max(120, (sf:GetWidth() or 0) - 14)
    local y = 0
    local function place(fs, gap, indent)
        indent = indent or 0
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", content, "TOPLEFT", indent, -y)
        fs:SetWidth(w - indent)
        y = y + max(12, fs:GetStringHeight() or 12) + gap
    end
    -- quest-log heading: the raid's art, the name and the facts beside it. While the raid's live
    -- the card up top is already showing its art.
    local art = D.art:IsShown()
    D.art:ClearAllPoints()
    D.art:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    local indent = art and ART_INDENT or 0
    if w >= 230 then
        place(D.title, 4, indent)
        place(D.meta, 12, indent)
        if art then y = max(y, D.art:GetHeight() + 12) end
    else
        -- narrow column: the name beside the art, the facts full width under both
        y = art and 8 or 0
        place(D.title, 4, indent)
        if art then y = max(y, D.art:GetHeight() + 8) end
        place(D.meta, 12)
    end
    D.factsTip:ClearAllPoints()
    D.factsTip:SetPoint("TOPLEFT", D.meta, "TOPLEFT")
    D.factsTip:SetPoint("BOTTOMRIGHT", D.meta, "BOTTOMRIGHT")
    local x = 0
    for _, key in ipairs(PILL_ORDER) do
        local p = D.pills[key]
        if p:IsShown() then
            local pw = p:GetWidth() or 40
            if x > 0 and x + pw > w then x, y = 0, y + 22 end
            p:ClearAllPoints()
            p:SetPoint("TOPLEFT", content, "TOPLEFT", x, -y)
            x = x + pw + 6
        end
    end
    if x > 0 then y = y + 18 + 16 else y = y + 4 end
    local cells = 0
    for _, key in ipairs(SECTION_ORDER) do
        local s = D.sections[key]
        if s.label:IsShown() then
            place(s.label, 6)
            if key == "present" and D.presentNames and #D.presentNames > 0 and w >= NAME_CELL_W * 2 then
                s.body:Hide()
                cells = #D.presentNames
                y = layoutNames(content, D.presentNames, y, w) + 14
            else
                s.body:Show()
                place(s.body, 14)
            end
        end
    end
    for i, cell in ipairs(D.nameCells or {}) do
        if i > cells then cell:Hide() end
    end
    sf:SetContentHeight(y)
end

local function setSection(key, label, body)
    local s = D.sections[key]
    s.label:SetShown(label ~= nil)
    s.body:SetShown(label ~= nil)
    if label then
        s.label:SetText(label)
        s.body:SetText(body or "")
    end
end

local function setPill(key, n, text)
    local p = D.pills[key]
    -- the head count isn't one: "Present (10)" says it straight underneath
    p:SetShown(n > 0 and key ~= "present")
    p:SetText(n .. " " .. text)
end

local function presentList(d)
    local keys = U.Keys(d.m or {}, function(a, b) return U.ShortName(a):lower() < U.ShortName(b):lower() end)
    local out = {}
    for _, key in ipairs(keys) do
        local e = d.m[key]
        if type(key) == "string" and type(e) == "table" then
            local s = named(key)
            local main = mainOf(key)
            if main ~= key then s = s .. T:Wrap("faint", " (" .. plain(U.ShortName(main)) .. ")") end
            if e.late then s = s .. " " .. glyph("clock", 11, "yellow") end
            out[#out + 1] = s
        end
    end
    return out
end

local function bossLines(d)
    local out = {}
    for _, b in ipairs(d.bo or {}) do
        if type(b) == "table" then
            local kill = b.k == 1
            local t = max(0, floor(tonumber(b[2]) or 0))
            out[#out + 1] = format("%s  %s  %s", glyph(kill and "skull" or "warning", 11, kill and "green" or "red"),
                kill and plain(b[1]) or T:Wrap("dim", plain(b[1])), T:Wrap("faint", format("+%d:%02d", floor(t / 60), t % 60)))
        end
    end
    return out
end

refreshDetail = function()
    if not P.detail then return end
    local r = selectedId and findRaid(selectedId)
    if not r then
        P.detailScroll:Hide()
        P.detailEmpty:SetText(P.raidList:IsShown() and "Pick a raid up top to see who rocked up and who chucked a sickie."
            or "Nothing to pick apart yet. The first roll call lands here.")
        P.detailEmpty:Show()
        P.deleteBtn:Hide()
            return
    end
    P.detailEmpty:Hide()
    P.detailScroll:Show()
    local d = r.doc
    P.deleteBtn:SetShown(GF.Roster:IsOfficer(API.MyKey()) and not r.open)

    D.title:SetText(plain(d.i or "Raid night"))
    setRaidArt(D.art, d.i)
    D.art:SetShown(not (r.open and P.live:IsShown()))
    local stop = d.e or (r.open and API.ServerTime()) or r.last
    local meta = U.DateTime(d.s) .. DOT .. U.Duration(stop - d.s) .. "\nTaken by " .. named(d.l)
    local ev = d.ev ~= nil and raidsCall("Get", d.ev) or nil
    if type(ev) == "table" and type(ev.title) == "string" then meta = meta .. DOT .. plain(ev.title) end
    D.meta:SetText(meta)
    D.factsText = (d.n or 0) .. " " .. U.Plural(d.n or 0, "snapshot")

    -- r.bench / r.flakes are resolved to mains (a benched main who turned up anyway counts
    -- as present), so the pills agree with the leaderboard and Raids()
    local bench, flakes = {}, {}
    for _, k in ipairs(U.Keys(r.bench)) do bench[#bench + 1] = named(k) end
    for _, k in ipairs(U.Keys(r.flakes)) do flakes[#flakes + 1] = named(k) end
    setPill("present", r.mains, U.Plural(r.mains, "local"))
    setPill("bench", #bench, "bench")
    setPill("flakes", r.open and 0 or #flakes, U.Plural(#flakes, "flake"))
    setPill("kills", r.kills, U.Plural(r.kills, "kill"))
    setPill("wipes", r.wipes, U.Plural(r.wipes, "wipe"))

    local present = presentList(d)
    D.presentNames = present
    setSection("present", "Present (" .. #present .. ")", #present > 0 and concat(present, ", ")
        or T:Wrap("faint", "Nobody. Not even the leader. Spooky."))
    setSection("bench", #bench > 0 and ("Bench (" .. #bench .. ")") or nil, concat(bench, ", "))
    local flakeBody
    if d.ev == nil then
        flakeBody = T:Wrap("faint", "No raid event linked, so nobody could flake. Lucky them.")
    elseif #flakes == 0 then
        flakeBody = T:Wrap("faint", r.open and "Everyone who said yeah is here. Mark the calendar." or "Nobody flaked. Mark the calendar.")
    else
        flakeBody = concat(flakes, ", ")
    end
    setSection("flakes", r.open and "Not here yet" or "Flaked", flakeBody)
    local bosses = bossLines(d)
    setSection("bosses", "Boss timeline", #bosses > 0 and concat(bosses, "\n")
        or T:Wrap("faint", "No bosses logged. Trash-only night, or the pulls never happened."))
    layoutDetail()
end

local function onDelete()
    local id = selectedId
    local r = id and findRaid(id)
    if not r or not GF.Roster:IsOfficer(API.MyKey()) then return end
    UI:Confirm("Bin this roll call", "Delete the " .. plain(r.doc.i or "raid") .. " roll call from " .. U.DateShort(r.s)
        .. " for everyone? Attendance gets recounted without it.", function()
        if Store:Delete(DATASET, id) then
            selectedId = nil
            refreshSoon()
        end
    end, "Bin it", "red")
end

local function buildRaids(page)
    local card = UI:Card(page, { title = "Recent raids", icon = "calendar" })
    P.raids = card
    P.raidList = UI:List(card.body, {
        rowHeight = RAID_ROW,
        spacing = 0,
        createRow = createRaidRow,
        updateRow = updateRaidRow,
        isSelected = function(r) return r.id == selectedId end,
        onClick = function(r)
            if r.id ~= selectedId then P.detailScroll:SetVerticalScroll(0) end
            selectedId = r.id
            P.raidList:Refresh()
            refreshDetail()
        end,
    })
    P.raidList:SetPoint("TOPLEFT")
    P.raidList:SetPoint("BOTTOMRIGHT", 10, 0)
    P.raidsEmpty = UI:Empty(card.body, "No roll calls on the books. Either nobody raided or nobody was game enough to count.", "calendar")
    P.raidsEmpty:Hide()

    local det = UI:Card(page, { title = "Raid detail", icon = "clipboard" })
    det:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 0, -16)
    det:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
    P.detail = det
    P.deleteBtn = UI:IconButton(det, "trash", 22, "Bin this roll call (officers only)", onDelete, "dim")
    P.deleteBtn:SetPoint("TOPRIGHT", -8, -5)
    local sf, content = UI:Scroll(det.body)
    sf:SetAllPoints(det.body)
    sf:HookScript("OnSizeChanged", function() layoutDetail() end)
    P.detailScroll, P.detailContent = sf, content
    D.art = UI:FramedIcon(content, 32, RAID_ART_DEFAULT)
    D.title = UI:Text(content, 15, "wowGold", "ui")
    D.meta = UI:Text(content, 11, "dim")
    D.meta:SetWordWrap(true)
    if D.meta.SetSpacing then D.meta:SetSpacing(2) end
    -- the snapshot count is for the curious: it lives on hover, off the facts
    D.factsTip = CreateFrame("Frame", nil, content)
    D.factsTip:EnableMouse(true)
    UI.AttachTip(D.factsTip, function() return D.factsText end)
    D.pills = {
        present = UI:Pill(content, "", "green", { icon = "roster" }),
        bench = UI:Pill(content, "", "blue", { icon = "minus" }),
        flakes = UI:Pill(content, "", "red", { icon = "close" }),
        kills = UI:Pill(content, "", "green", { icon = "skull" }),
        wipes = UI:Pill(content, "", "red", { icon = "warning" }),
    }
    D.sections = {}
    -- section heads in Friz gold (the flakes head stays red: it's a telling-off)
    local accents = { present = "wowGold", bench = "wowGold", flakes = "red", bosses = "wowGold" }
    for _, key in ipairs(SECTION_ORDER) do
        local label = UI:Text(content, 12, accents[key], "ui")
        local body = UI:Text(content, 12, "dim")
        body:SetWordWrap(true)
        body:SetSpacing(3)
        D.sections[key] = { label = label, body = body }
    end
    P.detailEmpty = UI:Empty(det.body, "Pick a raid up top to see who rocked up and who chucked a sickie.", "clipboard")
    P.detailEmpty:Hide()
end

local function refreshRaids()
    local w = settings().window
    local raids = raidsIn(cutoffFor(w))
    local found = false
    for _, r in ipairs(raids) do
        if r.id == selectedId then found = true break end
    end
    if not found then selectedId = raids[1] and raids[1].id or nil end
    P.raidCount = #raids
    P.raidList:SetItems(raids, true)
    P.raidList:SetShown(#raids > 0)
    P.raidsEmpty:SetShown(#raids == 0)
end

-------------------------------------------------------------------------------
-- Header + layout
-------------------------------------------------------------------------------
recTip = function()
    local on, mine = Attendance:IsRecording()
    if on then
        return { "End roll call", { mine and "Takes one last headcount, closes the record and tells the street who flaked."
            or "Closes the roll call someone else is running. Their numbers so far are kept." } }
    end
    local lines = { "Starts taking attendance for your group right now.", "Inside a raid instance it starts by itself." }
    if not API.InGroup() then lines[#lines + 1] = T:Wrap("yellow", "You need to be in a group first.") end
    return { "Start roll call", lines }
end

onRecClick = function()
    local on, mine = Attendance:IsRecording()
    if on then
        UI:Confirm("End roll call", mine and "Wrap it up? One last headcount, then the street hears who flaked."
            or "Close the roll call someone else is running? Their numbers so far are kept.", function()
            Attendance:End()
            refreshSoon()
        end, "End it", "red")
        return
    end
    local ok, why, who = Attendance:Start(true)
    if not ok then UI:Toast({ title = "Nah", text = reasonText(why, who), icon = "warning", style = "yellow" }) end
end

local function layoutActions()
    local h = P.header
    for i = #h.actions, 1, -1 do
        h.actions[i]:ClearAllPoints()
        h.actions[i] = nil
    end
    h:AddAction(P.exportBtn)
    if P.recBtn:IsShown() then h:AddAction(P.recBtn) end
    h:AddAction(P.windowDD)
end

local function refreshHeader()
    local on, mine = Attendance:IsRecording()
    local btn = P.recBtn
    if on and (mine or GF.Roster:IsOfficer(API.MyKey())) then
        UI:SetIcon(btn.icon, "close")
        btn:SetStyle("danger")
        btn:SetText("End roll call")
        btn:SetActive(true)
        btn:Show()
    elseif P.bare then
        -- it's in the middle of the page right now: one's plenty
        btn:Hide()
    elseif not on and GF.Roster:CanManage() then
        UI:SetIcon(btn.icon, "check")
        btn:SetStyle("primary")
        btn:SetText("Start roll call")
        btn:SetActive(API.InGroup())
        btn:Show()
    else
        btn:Hide()
    end
    layoutActions()
    local w = settings().window
    local raids = raidsIn(cutoffFor(w))
    if #raids == 0 then
        P.header:SetSubtitle("Who showed, who flaked, who's running on Mandurah time.")
    else
        local heads = 0
        for _, r in ipairs(raids) do heads = heads + r.mains end
        -- the dropdown beside it already says which window
        P.header:SetSubtitle(format("%d %s, about %d locals a night.", #raids,
            U.Plural(#raids, "raid"), floor(heads / #raids + 0.5)))
    end
end

local function layoutColumns(showLive)
    local page = P.page
    local top = showLive and P.live or P.header
    P.board:ClearAllPoints()
    P.board:SetPoint("TOPLEFT", top, "BOTTOMLEFT", 0, showLive and -16 or -14)
    P.board:SetPoint("BOTTOMRIGHT", page, "BOTTOM", 90, 0)
    -- An invisible right column carries the edges, so the recent-raids card can take a
    -- fixed height (a plain RIGHT anchor would pin its vertical centre and squash the
    -- detail card hanging underneath).
    if not P.rightCol then P.rightCol = CreateFrame("Frame", nil, page) end
    P.rightCol:ClearAllPoints()
    P.rightCol:SetPoint("TOPLEFT", P.board, "TOPRIGHT", 16, 0)
    P.rightCol:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
    P.raids:ClearAllPoints()
    P.raids:SetPoint("TOPLEFT", P.rightCol, "TOPLEFT", 0, 0)
    local n = P.raidCount or 0
    P.detail:SetShown(n > 0)
    if n == 0 then
        -- nothing to pick apart yet: the list's own empty state gets the whole column
        P.raids:SetPoint("BOTTOMRIGHT", P.rightCol, "BOTTOMRIGHT", 0, 0)
    else
        P.raids:SetPoint("TOPRIGHT", P.rightCol, "TOPRIGHT", 0, 0)
        -- only as tall as its rows: the detail below is what people came for
        local avail = (P.rightCol:GetHeight() or 0)
        local want = 48 + min(n, RAIDS_SHOWN) * RAID_ROW
        P.raids:SetHeight(max(RAIDS_MIN, avail > 0 and min(want, floor(avail * 0.45)) or want))
    end
end

local function refreshAll()
    if not P.page then return end
    local showLive = refreshLive()
    refreshRaids()
    layoutColumns(showLive)
    refreshBoard()
    refreshHeader()
    refreshDetail()
end

--- A button that stays out of the way but can still be read on top of the night scene: plain
-- text on a carved dark plate instead of metal.
local function quietButton(parent, text, opts)
    opts.style = "ghost"
    local b = UI:Button(parent, text, opts)
    b.plate = UI:Nine(b, "inset", "BACKGROUND", -6)
    return b
end

local function build(page)
    P.page = page
    P.header = UI:PageHeader(page, "Roll Call", "Who showed, who flaked, who's running on Mandurah time.")
    P.exportBtn = quietButton(page, "Export CSV", { icon = "export", onClick = exportCSV,
        tooltip = { "Export CSV", { "Copies the leaderboard for this window: Name, Attended, Total, Pct, Late, Flakes, Streak." } } })
    P.recBtn = UI:Button(page, "Start roll call", { style = "primary", icon = "check", onClick = onRecClick, tooltip = recTip })
    P.windowDD = UI:Dropdown(page, {
        width = 130, items = WINDOWS,
        get = function() return settings().window end,
        set = function(v) settings().window = v; refreshAll() end,
        tooltip = "How far back the leaderboard, raid list and export look.",
    })
    layoutActions()
    buildLive(page)
    buildBoard(page)
    buildRaids(page)
    layoutColumns(false)
    page:SetScript("OnSizeChanged", function()
        if P.live then
            layoutColumns(P.live:IsShown())
            layoutLiveStats()
        end
    end)
end

UI:RegisterPage({
    key = "attendance", title = "Roll Call", subtitle = "Who showed, who flaked, who's running on Mandurah time.",
    icon = "check", group = "raid", order = 40,
    build = build,
    onShow = function() refreshAll() end,
    onHide = function() stopClock(); stopPulse() end,
    badge = function() return Attendance:IsRecording() and "REC" or nil end,
})
