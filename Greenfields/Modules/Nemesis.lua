--[[ Greenfields - Modules/Nemesis.lua
     Most Wanted. When an enemy player kills a guildie their mugshot goes up on every pole in
     Greenfields with a price on it, and the guildie who drops them collects. The page, the posters
     and the popups are Modules/NemesisUI.lua.

     There's no combat log on Forever, so nobody's told who killed them. This file keeps a short
     memory of the enemy players it can see (nameplates, your target, mouseover, and who's got you
     targeted), looks again just after you die (your killer's usually still standing over you), and
     asks the death recap when the client has one. It only names someone it has good reason to, and
     the victim can take a poster down ("Wasn't them").

     Points: 1 a body, +1 for every different guildie they've done, +1 for each dog act (10 or more
     levels under them). A killing blow collects every point since the last one; revenge is worth 1
     more, and a hand in the kill (the honour) is worth 1.

     Data: the replicated dataset "wanted" (code "wn"), one doc per thing that happened:
       death  "<victim>:<time>"     { k = "d", v = victim, e = enemy, r = race key, rn = race name,
                                      c = class file, s = sex (2 male, 3 female), l = level,
                                      vl = victim's level, g = guild, z = zone, t = time }
       claim  "<hunter>:c:<time>"   { k = "c", by = hunter, e = enemy, kb = 1 for the killing blow
                                      (nil for a hand in it), z = zone, t = time }
     Only the victim writes a death and only the hunter a claim; an officer can tear a poster down.
     Every client works the same board out of the same docs.

     Op "WS" { e = enemy, z = zone }: a wanted enemy's been spotted (guild, throttled per enemy).

     Public:
       N:Board() -> { wanted = {entries}, dealt = {entries}, byName = {}, hunters = {rows} }
       N:Get(name) -> entry      N:NemesisOf(key) -> entry, times      N:HunterOf(key) -> row
       N:Mug(entry) -> texture, left, right, top, bottom
       N:Describe(entry) -> "Night Elf Rogue, level 34"     N:PointsText(n) -> "5 points"
       N:LastSeen(entry) -> { t, z, by } or nil             N:Retract(id), N:TearDown(name)
     Fires GF_WANTED_CHANGED when the board moves. ]]

local _, GF = ...
local API, U = GF.API, GF.Util
local CleanString, CleanNumber, Readable = API.CleanString, API.CleanNumber, API.Readable
local type, pairs, ipairs, tostring, tonumber = type, pairs, ipairs, tostring, tonumber
local max, floor = math.max, math.floor
local tsort, concat = table.sort, table.concat

local N = GF:NewModule("Nemesis")
GF.Nemesis = N

local DATA = "wanted"
local KEEP_DAYS = 120
local WITNESS = 30          -- an enemy seen this long before a death can still be the one
local AIMED = 12            -- someone with you targeted this long before you dropped was in it
local LOOKS = { 0.3, 1.2, 2.6 }   -- look round again this long after dying
local DECIDE = 3.2
local DEALT_DAYS = 7        -- a dealt-with poster stays on the wall this long
local SIGHT_GAP = 300       -- per enemy: one sighting alert, and one broadcast, every 5 minutes
local CLAIM_GAP = 8         -- a killing blow and its honour line this close together are one kill
local DOG_LEVELS = 10       -- picking on someone this many levels under you is a dog act
local REVENGE, ASSIST = 1, 1

local function G(name) return rawget(_G, name) end

--- pcalls a client global; the results are raw, so Clean whatever's used.
local function call(fname, ...)
    local f = G(fname)
    if type(f) ~= "function" then return nil end
    local ok, a, b, c, d, e, f2, g = pcall(f, ...)
    if not ok then return nil end
    return a, b, c, d, e, f2, g
end

local function settings() return GF.db and GF.db.settings or {} end

local function plainField(v, n)
    return v == nil or (type(v) == "string" and Readable(v) and #v <= n and not v:find("|", 1, true))
end

-- what the client says it saw, kept for /gf doctor
local diag = { deaths = 0, named = 0, reads = 0, hidden = 0, recap = "not asked", why = "none yet", claims = 0, kbHidden = 0 }
N.diag = diag

-------------------------------------------------------------------------------
-- Race and class
-------------------------------------------------------------------------------
--- "NightElf" / "Night Elf" / "SkyborneHighOrder" -> "nightelf" / "skyborne"
local function raceKey(token)
    if type(token) ~= "string" or not Readable(token) then return nil end
    local low = token:lower():gsub("[^a-z]", "")
    if low == "" then return nil end
    if low:find("sky", 1, true) then return "skyborne" end
    return low
end

local RACE_NAMES = { human = "Human", dwarf = "Dwarf", nightelf = "Night Elf", gnome = "Gnome", skyborne = "Skyborne" }

function N:Describe(p)
    if type(p) ~= "table" then return "" end
    local parts = {}
    local race = p.raceName or RACE_NAMES[p.race or ""]
    if race then parts[#parts + 1] = race end
    if p.class then parts[#parts + 1] = API.ClassName(p.class) or U.Capitalize(p.class:lower()) end
    local s = concat(parts, " ")
    if p.level == -1 then
        s = s ~= "" and (s .. ", level ??") or "Level ??"
    elseif type(p.level) == "number" and p.level > 0 then
        s = s ~= "" and (s .. ", level " .. p.level) or ("Level " .. p.level)
    end
    return s ~= "" and s or "Nobody got a good look"
end

function N:PointsText(n)
    n = tonumber(n) or 0
    return n == 1 and "1 point" or (n .. " points")
end

--- The mugshot for an entry: texture, then its texcoords on the sheet.
function N:Mug(p)
    local A = GF.WantedArt
    if not A or type(p) ~= "table" then return nil end
    local sex = p.sex == 3 and "f" or "m"
    local m = p.race and p.class and A.mugs[p.race .. "_" .. p.class:lower() .. "_" .. sex]
    if not m then
        -- nobody got a look (or a face we haven't drawn): one of the hoods, picked by name so it sticks
        local pool = sex == "f" and { "unknown_f", "unknown_mask", "unknown_sack" } or { "unknown_m", "unknown_sack", "unknown_mask" }
        local h = 0
        for i = 1, #(p.name or "") do h = (h * 31 + p.name:byte(i)) % 997 end
        m = A.mugs[pool[(h % #pool) + 1]] or A.mugs.unknown_m
    end
    if not m then return nil end
    local tex = A.sheets[m[1]]
    if not tex then return nil end
    return tex, m[2], m[3], m[4], m[5]
end

-------------------------------------------------------------------------------
-- The board: worked out from the docs, the same on every client
-------------------------------------------------------------------------------
local board

function N:Invalidate()
    board = nil
    GF:Debounce("wanted-changed", 0.3, function() GF:Fire("GF_WANTED_CHANGED") end)
end

local function mainOf(key)
    local R = GF.Roster
    if R and R.MainOf and type(key) == "string" then
        local ok, m = pcall(R.MainOf, R, key)
        if ok and type(m) == "string" then return m end
    end
    return key
end

local function byTime(a, b)
    if a.t ~= b.t then return a.t < b.t end
    return tostring(a.v or a.by) < tostring(b.v or b.by)
end

--- A kill on someone 10 or more levels under them. Classic shows a level that far above you as
-- "??" (stored as -1), which is exactly that.
local function dogAct(d)
    if type(d.vl) ~= "number" or d.vl <= 0 or type(d.l) ~= "number" then return false end
    if d.l == -1 then return true end
    return d.l > 0 and d.l - d.vl >= DOG_LEVELS
end

--- Open deaths -> points, how many different guildies, how many dog acts.
local function pointsFor(deaths)
    local pts, seen, spread, dogs = 0, {}, 0, 0
    for _, d in ipairs(deaths) do
        pts = pts + 1
        local v = mainOf(d.v)
        if not seen[v] then seen[v] = true; spread = spread + 1 end
        if dogAct(d) then dogs = dogs + 1 end
    end
    return pts + max(0, spread - 1) + dogs, spread, dogs
end
N.PointsFor = pointsFor

local function localState()
    if not (GF.gdb and GF.gdb["local"]) then return nil end
    local l = GF.DB and GF.DB.Local and GF.DB:Local("Nemesis")
    if type(l) ~= "table" then return nil end
    l.seen = type(l.seen) == "table" and l.seen or {}
    return l
end

local function buildBoard()
    local all = GF.Store and GF.Store:All(DATA) or {}
    local byName, order = {}, {}
    for id, d in pairs(all) do
        if type(d) == "table" and type(d.e) == "string" and type(d.t) == "number" then
            local p = byName[d.e]
            if not p then
                p = { name = d.e, deaths = {}, claims = {}, victims = {} }
                byName[d.e] = p
                order[#order + 1] = p
            end
            -- copies: synced docs are never written to
            if d.k == "d" and type(d.v) == "string" then
                p.deaths[#p.deaths + 1] = { id = id, t = d.t, v = d.v, l = d.l, vl = d.vl, r = d.r, rn = d.rn,
                    c = d.c, s = d.s, g = d.g, z = d.z }
            elseif d.k == "c" and type(d.by) == "string" then
                p.claims[#p.claims + 1] = { id = id, t = d.t, by = d.by, kb = d.kb, z = d.z }
            end
        end
    end

    local hunters = {}
    local function hunter(key)
        local m = mainOf(key)
        local h = hunters[m]
        if not h then
            h = { key = m, points = 0, claims = 0, assists = 0, revenge = 0, best = 0 }
            hunters[m] = h
        end
        return h
    end

    local now = API.ServerTime()
    local seenLocal = localState()
    seenLocal = seenLocal and seenLocal.seen or {}
    local wanted, dealt = {}, {}
    for _, p in ipairs(order) do
        tsort(p.deaths, byTime)
        tsort(p.claims, byTime)
        for _, d in ipairs(p.deaths) do
            -- the latest look at them wins
            p.race = d.r or p.race
            p.raceName = d.rn or p.raceName
            p.class = d.c or p.class
            p.sex = d.s or p.sex
            p.guild = d.g or p.guild
            if type(d.l) == "number" and d.l ~= 0 then p.level = d.l end
            p.lastDeath, p.lastZone, p.lastVictim = d.t, d.z or p.lastZone, d.v
            local v = mainOf(d.v)
            p.victims[v] = (p.victims[v] or 0) + 1
        end
        p.priors = #p.deaths
        -- one kill can bring a killing blow and that same hunter's honour line: it's the kill, not both
        local kbs = {}
        for _, c in ipairs(p.claims) do
            if c.kb then kbs[#kbs + 1] = c end
        end
        local function ownKill(c)
            local m = mainOf(c.by)
            for _, k in ipairs(kbs) do
                if mainOf(k.by) == m and math.abs(k.t - c.t) <= CLAIM_GAP then return true end
            end
            return false
        end
        -- deaths and claims together, oldest first: a killing blow settles everything open
        local open, di = {}, 1
        p.history = {}
        local lastKB
        for _, c in ipairs(p.claims) do
            while di <= #p.deaths and p.deaths[di].t <= c.t do
                open[#open + 1] = p.deaths[di]
                di = di + 1
            end
            if c.kb then
                if #open > 0 then
                    local pts = pointsFor(open)
                    local hm, revenge = mainOf(c.by), false
                    for _, d in ipairs(open) do
                        if mainOf(d.v) == hm then revenge = true break end
                    end
                    local h = hunter(c.by)
                    h.points = h.points + pts + (revenge and REVENGE or 0)
                    h.claims = h.claims + 1
                    if revenge then h.revenge = h.revenge + 1 end
                    if pts > h.best then h.best = pts end
                    lastKB = { by = c.by, t = c.t, points = pts, revenge = revenge, z = c.z, helpers = {} }
                    p.history[#p.history + 1] = lastKB
                    open = {}
                end
            elseif not ownKill(c) and (#open > 0 or (lastKB and c.t - lastKB.t <= 20)) then
                -- a hand in it, while there's a price on them (or just as it's paid)
                local h = hunter(c.by)
                h.assists = h.assists + 1
                h.points = h.points + ASSIST
            end
        end
        -- who helped on each collection: anyone else's honour within 20 s either side of it
        for _, k in ipairs(p.history) do
            local km, named = mainOf(k.by), {}
            for _, c in ipairs(p.claims) do
                local m = mainOf(c.by)
                if not c.kb and m ~= km and not named[m] and math.abs(c.t - k.t) <= 20 then
                    named[m] = true
                    k.helpers[#k.helpers + 1] = c.by
                end
            end
        end
        while di <= #p.deaths do
            open[#open + 1] = p.deaths[di]
            di = di + 1
        end
        p.open = open
        p.bounty, p.spread, p.dogs = pointsFor(open)
        p.lastClaim = p.history[#p.history]
        local spot = seenLocal[p.name]
        if type(spot) == "table" and type(spot.t) == "number" and (not p.lastDeath or spot.t > p.lastDeath) then
            p.seen = { t = spot.t, z = spot.z, by = spot.by }
        elseif p.lastDeath then
            p.seen = { t = p.lastDeath, z = p.lastZone, by = p.lastVictim }
        end
        if #open > 0 then
            p.status = "wanted"
            wanted[#wanted + 1] = p
        elseif p.lastClaim and now - p.lastClaim.t < DEALT_DAYS * 86400 then
            p.status = "dealt"
            dealt[#dealt + 1] = p
        else
            p.status = "cold"
        end
    end
    tsort(wanted, function(a, b)
        if a.bounty ~= b.bounty then return a.bounty > b.bounty end
        if (a.lastDeath or 0) ~= (b.lastDeath or 0) then return (a.lastDeath or 0) > (b.lastDeath or 0) end
        return a.name < b.name
    end)
    tsort(dealt, function(a, b) return a.lastClaim.t > b.lastClaim.t end)
    local rows = {}
    for _, h in pairs(hunters) do rows[#rows + 1] = h end
    tsort(rows, function(a, b)
        if a.points ~= b.points then return a.points > b.points end
        if a.claims ~= b.claims then return a.claims > b.claims end
        return a.key < b.key
    end)
    return { wanted = wanted, dealt = dealt, byName = byName, hunters = rows, hunterOf = hunters }
end

function N:Board()
    if not board then
        local ok, b = GF:Safe("wanted:board", buildBoard)
        board = ok and b or { wanted = {}, dealt = {}, byName = {}, hunters = {}, hunterOf = {} }
    end
    return board
end

function N:Get(name)
    if type(name) ~= "string" then return nil end
    return self:Board().byName[name]
end

function N:HunterOf(key)
    if type(key) ~= "string" then return nil end
    return self:Board().hunterOf[mainOf(key)]
end

--- The enemy who's had this guildie (and their alts) the most -> entry, times.
function N:NemesisOf(key)
    if type(key) ~= "string" then return nil end
    local m = mainOf(key)
    local best, bestN, bestT = nil, 0, 0
    for _, p in pairs(self:Board().byName) do
        local n = p.victims[m] or 0
        local t = p.lastDeath or 0
        if n > bestN or (n == bestN and n > 0 and (t > bestT or (t == bestT and p.name < best.name))) then
            best, bestN, bestT = p, n, t
        end
    end
    return best, bestN
end

function N:LastSeen(p) return type(p) == "table" and p.seen or nil end

-------------------------------------------------------------------------------
-- Writing
-------------------------------------------------------------------------------
--- "<author>:..." is how every doc id starts.
local function ownsId(author, id)
    return type(author) == "string" and type(id) == "string" and id:sub(1, #author + 1) == author .. ":"
end

--- A field as it may be stored: plain text no longer than n, or nil.
local function fit(v, n)
    if type(v) == "string" and Readable(v) and #v <= n and not v:find("|", 1, true) then return v end
    return nil
end

local NAME_MAX = 36   -- bytes: twelve letters of a name can run to two bytes each

local function validDoc(id, d)
    if type(d) ~= "table" or type(d.t) ~= "number" or type(d.e) ~= "string" then return false end
    if #d.e < 2 or #d.e > NAME_MAX or d.e:find("[|:]") then return false end
    if not plainField(d.z, 64) then return false end
    if d.k == "d" then
        return type(d.v) == "string" and plainField(d.r, 24) and plainField(d.rn, 32) and plainField(d.c, 16)
            and plainField(d.g, 48) and (d.s == nil or d.s == 2 or d.s == 3)
            and (d.l == nil or type(d.l) == "number") and (d.vl == nil or type(d.vl) == "number")
    end
    if d.k == "c" then return type(d.by) == "string" and (d.kb == nil or d.kb == 1) end
    return false
end

GF.Store:Define({
    name = DATA, code = "wn", owner = "shared", keepDays = KEEP_DAYS,
    canWrite = function(author, id, new, old)
        if type(id) ~= "string" then return false end
        if new then
            if type(new) ~= "table" then return false end
            local who = new.k == "c" and new.by or new.v
            return author == who and ownsId(author, id)
        end
        if old then
            local who = old.k == "c" and old.by or old.v
            return author == who or GF.Roster:IsOfficer(author)
        end
        -- a tombstone for a doc we never held: the id (or an officer) is the proof. Turning it away
        -- would leave the digests mismatched for good, and the street re-syncing it forever.
        return ownsId(author, id) or GF.Roster:IsOfficer(author)
    end,
    validate = validDoc,
    onChange = function() N:Invalidate() end,
})

local function feed(kind, text, opts)
    if GF.Feed and GF.Feed.Post then GF.Feed:Post(kind, text, opts) end
end

local function nameOf(key)
    local R = GF.Roster
    if R and R.Colored then
        local ok, s = pcall(R.Colored, R, key)
        if ok and type(s) == "string" then return s end
    end
    return tostring(key)
end

local function enemyText(p) return "|cffe8473c" .. p.name .. "|r" end

local DEATH_LINES = {
    "{enemy} ({what}) did over {victim}. New face on the poles: {points}.",
    "{enemy} put {victim} in the dirt. Their mugshot's going up on every pole in Greenfields. {points}.",
    "Dog act. {enemy} rolled {victim}. Price on their head: {points}.",
    "{victim} got done over by {enemy}. Nobody's calling the cops. Bounty's {points}.",
}
local CLIMB_LINES = {
    "{enemy} did {victim} too. Bounty's up to {points}. Someone sort them out.",
    "{enemy} again, this time {victim}. That's {points} on their head now.",
    "{victim} is the latest to get rolled by {enemy}. {points} and climbing.",
}
local CLAIM_LINES = {
    "{hunter} collected {points} on {enemy}. Paid in full.",
    "Street justice: {hunter} dropped {enemy} and walked off with {points}.",
    "{hunter} dealt with {enemy}. {points}. They'll be back in thirty seconds, but still.",
    "{enemy}'s been sorted by {hunter}. {points} collected, no questions asked.",
}

local function fill(line, vars)
    return (line:gsub("{(%w+)}", function(k) return vars[k] ~= nil and tostring(vars[k]) or "" end))
end

--- My death, put down to `s` (a sighting). ctx = the death: { t (server time it happened), lvl, zone }.
local function record(s, why, ctx)
    local me = API.MyKey()
    if not me or type(s.name) ~= "string" then return end
    local before = N:Get(s.name)
    local wasOpen = before and before.status == "wanted" and before.bounty or 0
    -- stamped when it happened, not when it was worked out, so a quick revenge still settles it
    local t = ctx.t or API.ServerTime()
    local id = me .. ":" .. t
    if GF.Store:Get(DATA, id) then id = id .. ":2" end
    local d = {
        k = "d", v = me, e = s.name, r = fit(s.race, 24), rn = fit(s.raceName, 32), c = fit(s.class, 16),
        s = (s.sex == 2 or s.sex == 3) and s.sex or nil, l = s.level, vl = ctx.lvl,
        g = fit(s.guild, 48), z = fit(ctx.zone, 64), t = t,
    }
    if not validDoc(id, d) or not GF.Store:Put(DATA, id, d) then
        diag.why = "couldn't write the report"
        return
    end
    diag.named = diag.named + 1
    diag.why = why
    local p = N:Get(s.name) or { name = s.name, bounty = 1, priors = 1 }
    local vars = { enemy = enemyText(p), victim = nameOf(me), what = N:Describe(p), points = N:PointsText(p.bounty) }
    local fresh = wasOpen == 0
    -- the first price and every jump past a round number make the Watch; the rest just move the poster
    local milestone = fresh or (wasOpen < 5 and p.bounty >= 5) or (wasOpen < 10 and p.bounty >= 10)
        or (wasOpen < 20 and p.bounty >= 20)
    if milestone then
        feed("wanted", fill(U.Pick(fresh and DEATH_LINES or CLIMB_LINES), vars),
            { key = "wanted:" .. s.name .. ":" .. t, icon = "skull", toast = not fresh })
    end
    GF:Fire("GF_WANTED_DEATH", p, id, why)
end

--- Writes my claim on `name`, made at server time t, if there was a price on them by then.
-- false: no price yet (the death that put it there may still be on its way).
local function settle(name, kb, t, zone)
    local p = N:Get(name)
    local open = {}
    for _, d in ipairs(p and p.open or {}) do
        if d.t <= t then open[#open + 1] = d end
    end
    if #open == 0 then return false end
    local me = API.MyKey()
    if not me then return false end
    local id = me .. ":c:" .. t .. ":" .. name
    if GF.Store:Get(DATA, id) then return true end
    local pts = pointsFor(open)
    local revenge, mm = false, mainOf(me)
    for _, d in ipairs(open) do
        if mainOf(d.v) == mm then revenge = true break end
    end
    local d = { k = "c", by = me, e = name, kb = kb and 1 or nil, z = fit(zone, 64), t = t }
    if not validDoc(id, d) or not GF.Store:Put(DATA, id, d) then return true end
    diag.claims = diag.claims + 1
    if not kb then return true end
    local vars = { hunter = nameOf(me), enemy = enemyText(p), points = N:PointsText(pts + (revenge and REVENGE or 0)) }
    local text = fill(U.Pick(CLAIM_LINES), vars)
    if revenge then text = text .. " Revenge, served cold." end
    feed("bounty", text, { key = "bounty:" .. name .. ":" .. t, icon = "coin", toast = true })
    GF:Fire("GF_WANTED_CLAIMED", p, pts, revenge)
    return true
end

--- I dropped (kb) or helped drop someone. If there's no price on them yet it waits a minute for
-- one: a guildie's death is written a few seconds after it happens, and revenge can be quicker.
local lastKB, waiting = {}, {}
local function claim(name, kb)
    if type(name) ~= "string" then return end
    local now = API.Time()
    if kb then
        if lastKB[name] and now - lastKB[name] < CLAIM_GAP then return end
        lastKB[name] = now
    elseif lastKB[name] and now - lastKB[name] < CLAIM_GAP then
        return   -- the honour line for my own killing blow
    end
    local t, zone = API.ServerTime(), API.ZoneName()
    if settle(name, kb, t, zone) then return end
    if #waiting < 20 then
        waiting[#waiting + 1] = { name = name, kb = kb, t = t, zone = zone, deadline = now + 60 }
    end
end
N.Claim = claim   -- for the harness

local function retryWaiting()
    if #waiting == 0 then return end
    local now, keep = API.Time(), {}
    for _, w in ipairs(waiting) do
        if now <= w.deadline and not settle(w.name, w.kb, w.t, w.zone) then keep[#keep + 1] = w end
    end
    waiting = keep
end

--- Takes my own report back off the board ("Wasn't them").
function N:Retract(id)
    if type(id) ~= "string" then return false end
    return GF.Store:Delete(DATA, id)
end

--- Officers: the open reports about `name` come down. Bounties already paid stay paid.
function N:TearDown(name)
    local p = self:Get(name)
    local n = 0
    for _, d in ipairs(p and p.open or {}) do
        if GF.Store:Delete(DATA, d.id) then n = n + 1 end
    end
    return n
end

-------------------------------------------------------------------------------
-- Watching: who's about, who's got you targeted
-------------------------------------------------------------------------------
local seen = {}       -- guid (or "n:Name") -> sighting: { name, guid, race, raceName, class, sex, level, guild,
                      --   t (last seen), mine / mouse (my target, under my mouse), atMe (had me targeted
                      --   while I was up), overMe (had my body targeted), after (about once I'd dropped) }
local byName = {}     -- name -> the same sighting, for reads where the GUID's hidden
local myGUID
local pending         -- the death being worked out
local lastEnemy = 0   -- when any enemy player was last about

local function me()
    if not myGUID then myGUID = API.UnitGUID("player") end
    return myGUID
end

local function enemyPlayer(unit)
    if not API.UnitExists(unit) then return false end
    local isPlayer = call("UnitIsPlayer", unit)
    if not Readable(isPlayer) or not isPlayer then return false end
    local fac, mine = API.UnitFaction(unit), API.UnitFaction("player")
    if fac and mine then return fac ~= mine and fac ~= "Neutral" end
    local enemy = call("UnitIsEnemy", "player", unit)
    return Readable(enemy) and enemy and true or false
end
N.EnemyPlayer = enemyPlayer

local function aimedAtMe(unit)
    local tu = unit .. "target"
    local g, mine = API.UnitGUID(tu), me()
    if g and mine then return g == mine end
    local S = G("C_Secrets")
    if type(S) == "table" and type(S.CanCompareUnitTokens) == "function" then
        local ok, can = pcall(S.CanCompareUnitTokens)
        if ok and Readable(can) and can then
            local r = call("UnitIsUnit", tu, "player")
            return Readable(r) and r and true or false
        end
    end
    return false
end

--- Fills what a GUID can tell us that the unit couldn't.
local function fromGUID(s)
    if type(s.guid) ~= "string" or (s.name and s.class and s.race and s.sex) then return end
    local _, class, race, raceFile, sex, name = call("GetPlayerInfoByGUID", s.guid)
    class, raceFile, sex, name = CleanString(class), CleanString(raceFile), CleanNumber(sex), CleanString(name)
    race = CleanString(race)
    if name and name ~= "" and not s.name then s.name = API.Key(name) end
    if class and not s.class then s.class = class end
    if raceFile and not s.race then s.race = raceKey(raceFile); s.raceName = s.raceName or race end
    if (sex == 2 or sex == 3) and not s.sex then s.sex = sex end
end

local sighted   -- below

--- The sighting for this GUID and/or name, made if need be: one person, one entry, however they
-- were read (by name while the GUID was hidden, or the other way round).
local function entryFor(guid, name)
    local s = guid and seen[guid]
    if s then return s end
    local named = name and byName[name]
    if named and (not guid or not named.guid or named.guid == guid) then
        if guid and not named.guid then
            for id, v in pairs(seen) do
                if v == named then seen[id] = nil end
            end
            seen[guid] = named
        end
        return named
    end
    s = {}
    seen[guid or ("n:" .. name)] = s
    return s
end

local function readUnit(unit, how)
    if not enemyPlayer(unit) then return nil end
    diag.reads = diag.reads + 1
    local name = API.UnitName(unit)
    name = name and API.Key(name)
    local guid = API.UnitGUID(unit)
    if guid and not guid:match("^Player%-") then guid = nil end
    if not name then diag.hidden = diag.hidden + 1 end
    if not guid and not name then return nil end
    local s = entryFor(guid, name)
    local now = API.Time()
    s.t = now
    lastEnemy = now
    s.guid = guid or s.guid
    if name then s.name = name end
    local raceFile, raceLoc = API.UnitRace(unit)
    if raceFile then
        s.race = raceKey(raceFile) or s.race
        s.raceName = CleanString(raceLoc) or s.raceName
    end
    s.class = API.UnitClassFile(unit) or s.class
    local sex = CleanNumber(call("UnitSex", unit))
    if sex == 2 or sex == 3 then s.sex = sex end
    local lvl = API.UnitLevel(unit)
    if lvl and lvl ~= 0 then s.level = lvl end
    local gname = CleanString(call("GetGuildInfo", unit))
    if gname and gname ~= "" then s.guild = gname end
    -- what happened while you were up is evidence; what happens over your body is a different kind
    if aimedAtMe(unit) then
        if pending then s.overMe = now else s.atMe = now end
    end
    if pending then
        s.after = now
    elseif how == "target" then
        s.mine = now
    elseif how == "mouse" then
        s.mouse = now
    end
    fromGUID(s)
    if s.name then byName[s.name] = s end
    if s.name and not pending then sighted(s) end
    return s
end
N.ReadUnit = readUnit

local function scanAll(how)
    readUnit("target", "target")
    readUnit("mouseover", how)
    readUnit("focus", how)
    for i = 1, 40 do
        local u = "nameplate" .. i
        if API.UnitExists(u) then readUnit(u, how) end
    end
end

-- forget anyone not seen for a few minutes
local function prune()
    local now = API.Time()
    for id, s in pairs(seen) do
        if now - (s.t or 0) > 300 then
            seen[id] = nil
            if s.name and byName[s.name] == s then byName[s.name] = nil end
        end
    end
end

-------------------------------------------------------------------------------
-- Who did it
-------------------------------------------------------------------------------
-- the races of each side, for a death recap that names one of our own (a duel gone wrong, the arena
-- in Stranglethorn, a mind control). Skyborne fight for both, so they're never ruled out by race.
local SIDES = {
    Alliance = { human = true, dwarf = true, nightelf = true, gnome = true },
    Horde = { orc = true, scourge = true, undead = true, tauren = true, troll = true },
}

local function friendly(s)
    local R = GF.Roster
    if s.name and R and R.IsMember and R:IsMember(s.name) then return true end
    local mine = API.UnitFaction("player")
    local side = mine and SIDES[mine]
    return side and s.race and side[s.race] and true or false
end

--- The death recap's killing blow, when the client has one and will say.
-- -> sighting, "player" | nil, "mob" (a creature, the ground or one of ours: no poster) | nil (can't say)
local function recapKiller()
    local DR = G("C_DeathRecap")
    if type(DR) ~= "table" or type(DR.GetRecapEvents) ~= "function" then
        diag.recap = "not on this client"
        return nil
    end
    local ok, events = pcall(DR.GetRecapEvents)
    if not ok or type(events) ~= "table" then
        diag.recap = ok and "nothing back" or "errored"
        return nil
    end
    -- the blow that went over is the killing blow; failing that, the latest
    local blow, latest, latestTs, hidden = nil, nil, -1, 0
    for i = 1, 20 do
        local e = events[i]
        if type(e) ~= "table" then break end
        local raw = e.sourceGUID
        local entry
        if type(raw) == "nil" then
            entry = { env = true }            -- falling, drowning, lava: nobody did it
        else
            local g = CleanString(raw)
            if g then entry = { guid = g, name = CleanString(e.sourceName) } else hidden = hidden + 1 end
        end
        if entry then
            local over = CleanNumber(e.overkill)
            local ts = CleanNumber(e.timestamp) or 0
            if over and over > 0 and not blow then blow = entry end
            if ts > latestTs then latest, latestTs = entry, ts end
        end
    end
    local kb = blow or latest
    if not kb then
        diag.recap = hidden > 0 and "hidden" or "empty"
        return nil
    end
    if kb.env or not kb.guid:match("^Player%-") then
        -- an enemy hunter's pet: the owner's still about, so it's down to the usual evidence
        if kb.guid and kb.guid:match("^Pet%-") then
            diag.recap = "a pet did it"
            return nil
        end
        diag.recap = "a mob or the ground did it"
        return nil, "mob"
    end
    local s = entryFor(kb.guid, kb.name and API.Key(kb.name))
    s.guid = kb.guid
    if kb.name and not s.name then s.name = API.Key(kb.name) end
    s.t = s.t or API.Time()
    fromGUID(s)
    if not s.name then
        diag.recap = "named nobody"
        return nil
    end
    byName[s.name] = s
    if friendly(s) then
        diag.recap = "one of ours did it"
        return nil, "mob"
    end
    diag.recap = "named the killer"
    return s, "player"
end

local function targetIsMob()
    if not API.UnitExists("target") then return false end
    local isPlayer = call("UnitIsPlayer", "target")
    if not Readable(isPlayer) or isPlayer then return false end
    local can = call("UnitCanAttack", "player", "target")
    return Readable(can) and can and true or false
end

local function decide()
    local p = pending
    pending = nil
    if not p then return end
    local killer, verdict = recapKiller()
    if not killer and verdict == "mob" then
        diag.why = "the recap says it wasn't an enemy player"
        return
    end
    local why = killer and "death recap"
    if not killer then
        local best, bestScore, about = nil, -1, 0
        for _, s in pairs(seen) do
            if s.name and (s.t or 0) >= p.at - WITNESS then
                about = about + 1
                local engaged, score = false, 0
                if s.atMe and s.atMe >= p.at - AIMED then score, engaged = score + 100, true end
                if s.mine and s.mine >= p.at - 15 then score, engaged = score + 60, true end
                -- standing over the body only counts if no mob was on you and you're still lying there
                if not p.mob and not p.released then
                    if s.overMe and s.overMe >= p.at then score, engaged = score + 50, true end
                    if s.after and s.after >= p.at then score = score + 30 end
                end
                score = score + max(0, WITNESS - (p.at - math.min(s.t, p.at)))
                s.engaged = engaged
                if score > bestScore then best, bestScore = s, score end
            end
        end
        if best and best.engaged then
            killer = best
            if best.atMe and best.atMe >= p.at - AIMED then why = "had you targeted"
            elseif best.mine and best.mine >= p.at - 15 then why = "was your target"
            else why = "standing over you" end
        elseif best and about == 1 and not p.mob and not p.released and best.after and (best.t or 0) >= p.at - 8 then
            killer, why = best, "only enemy about"
        else
            diag.why = about == 0 and "no enemy players about" or "nobody clearly on you"
        end
    end
    if killer then record(killer, why, p) end
end

local function onDead()
    if pending then return end
    -- the open world only: dungeons and raids have no enemy players, and a battleground would bury the wall
    local inst = API.InstanceInfo().type
    if inst == "party" or inst == "raid" or inst == "pvp" or inst == "arena" then return end
    me()
    diag.deaths = diag.deaths + 1
    pending = { at = API.Time(), t = API.ServerTime(), lvl = API.UnitLevel("player"), zone = API.ZoneName(), mob = targetIsMob() }
    if pending.lvl == 0 then pending.lvl = nil end
    for _, d in ipairs(LOOKS) do
        GF:After(d, function() if pending and not pending.released then scanAll("after") end end)
    end
    GF:After(DECIDE, decide)
end

--- Released or back on your feet: whoever's about now is at the graveyard, not over your body.
local function onUp()
    if pending then pending.released = true end
end

-------------------------------------------------------------------------------
-- Collecting: killing blows and honour
-------------------------------------------------------------------------------
local kbHidden   -- when my killing blow landed on someone the client wouldn't name

local function nameFromGUID(guid)
    local s = seen[guid]
    if s and s.name then return s.name end
    local _, _, _, _, _, name = call("GetPlayerInfoByGUID", guid)
    name = CleanString(name)
    return name and name ~= "" and API.Key(name) or nil
end

local function onPartyKill(_, attackerGUID, targetGUID)
    local a, t = CleanString(attackerGUID), CleanString(targetGUID)
    if not a then return end
    -- my kill, or my pet's
    if a ~= me() and a ~= API.UnitGUID("pet") then return end
    if t then
        if not t:match("^Player%-") then return end
        local name = nameFromGUID(t)
        if name then return claim(name, true) end
    end
    -- hidden or nameless: the honour line that follows names them
    diag.kbHidden = diag.kbHidden + 1
    kbHidden = API.Time()
end

--- Was I on them a moment ago (my target, or under my mouse)?
local function wasOnThem(name)
    local s = byName[name]
    if not s then return false end
    local now = API.Time()
    return (s.mine and now - s.mine <= 6) or (s.mouse and now - s.mouse <= 6) or false
end

local function fmtToPattern(fmt)
    if type(fmt) ~= "string" or fmt == "" then return nil end
    local out, pos, len = {}, 1, #fmt
    local first
    while pos <= len do
        local c = fmt:sub(pos, pos)
        if c == "%" then
            local num, conv, np = fmt:match("^%%(%d)%$([sd])()", pos)
            if not num then conv, np = fmt:match("^%%([sd])()", pos) end
            if conv then
                if conv == "s" and not first then first = #out + 1 end
                out[#out + 1] = conv == "d" and "%d+" or ".+"
                pos = np
            else
                out[#out + 1] = "%%"
                pos = pos + ((fmt:sub(pos + 1, pos + 1) == "%") and 2 or 1)
            end
        elseif c:find("[%^%$%(%)%.%[%]%*%+%-%?]") then
            out[#out + 1] = "%" .. c
            pos = pos + 1
        else
            out[#out + 1] = c
            pos = pos + 1
        end
    end
    if not first then return nil end
    out[first] = "(.-)"
    return "^" .. concat(out) .. "$"
end

local honorPats
local function honorVictim(text)
    if not honorPats then
        honorPats = {}
        for _, g in ipairs({ "COMBATLOG_HONORGAIN", "COMBATLOG_HONORGAIN_NO_RANK" }) do
            local pat = fmtToPattern(CleanString(G(g)))
            if pat then honorPats[#honorPats + 1] = pat end
        end
        honorPats[#honorPats + 1] = "^(.-) dies, honorable kill"
    end
    for _, pat in ipairs(honorPats) do
        local name = text:match(pat)
        if name and name ~= "" then return name end
    end
    return nil
end

local function onHonor(_, text)
    text = CleanString(text)
    if not text then return end
    local victim = honorVictim(text)
    local name = victim and API.Key(victim)
    if not name then return end
    -- a hidden killing blow could have been on a mob: it's only theirs if I was on them
    if kbHidden and API.Time() - kbHidden <= 3 and wasOnThem(name) then
        kbHidden = nil
        return claim(name, true)
    end
    claim(name, false)
end

-------------------------------------------------------------------------------
-- Sightings
-------------------------------------------------------------------------------
local sightAt, heardAt = {}, {}

local function remember(name, z, by)
    local l = localState()
    if not l then return end
    l.seen[name] = { t = API.ServerTime(), z = z, by = by }
    -- the board keeps last-seen in its entries: move it without rebuilding everything
    local p = board and board.byName[name]
    if p then p.seen = l.seen[name] end
end

local function alert(p, text)
    local UI = GF.UI
    if not (UI and UI.Toast) or settings().wantedSightings == false then return end
    UI:Toast({
        title = "Wanted: " .. p.name, text = text, icon = "skull", style = "red",
        key = "wanted-sight:" .. p.name, sound = 8959, duration = 8,
        onClick = function() if UI.OpenMain then UI:OpenMain("wanted", p.name) end end,
    })
end

sighted = function(s)
    local p = N:Get(s.name)
    if not p or p.status ~= "wanted" or API.UnitIsDead("player") then return end
    local now = API.Time()
    if sightAt[s.name] and now - sightAt[s.name] < SIGHT_GAP then return end
    sightAt[s.name] = now
    local zone = API.ZoneName()
    remember(s.name, zone, API.MyKey())
    alert(p, ("They're right here. %s on their head."):format(N:PointsText(p.bounty)))
    if GF.Comm and GF.Comm.Guild then GF.Comm:Guild("WS", { e = s.name, z = zone }, "NORMAL") end
    GF:Fire("GF_WANTED_SEEN", p)
end

GF.Comm:Register("WS", function(msg, sender)
    if type(msg) ~= "table" or type(msg.e) ~= "string" or type(sender) ~= "string" then return end
    local R = GF.Roster
    if R and R.IsMember and R:Count() > 0 and not R:IsMember(sender) then return end
    if #msg.e > 24 or not plainField(msg.z, 64) then return end
    local p = N:Get(msg.e)
    if not p or p.status ~= "wanted" then return end
    remember(msg.e, msg.z, sender)
    GF:Fire("GF_WANTED_SEEN", p)
    local now = API.Time()
    if heardAt[msg.e] and now - heardAt[msg.e] < SIGHT_GAP then return end
    heardAt[msg.e] = now
    -- only worth a sign if you're close enough to do something about it
    local here = API.ZoneName()
    if msg.z and here and msg.z == here then
        alert(p, ("Spotted in %s by %s. %s on their head."):format(msg.z, nameOf(sender), N:PointsText(p.bounty)))
    end
end)

-------------------------------------------------------------------------------
-- Tooltips
-------------------------------------------------------------------------------
local SKULL = "Interface\\AddOns\\Greenfields\\Media\\icon_skull"

local function onUnitTooltip(tooltip)
    if settings().tooltipWanted == false then return end
    if type(tooltip) ~= "table" or type(tooltip.GetUnit) ~= "function" or type(tooltip.AddLine) ~= "function" then return end
    local ok, _, unit = pcall(tooltip.GetUnit, tooltip)
    unit = ok and CleanString(unit) or nil
    if not unit or not enemyPlayer(unit) then return end
    local key = API.UnitKey(unit)
    local p = key and N:Get(key)
    if not p then return end
    if p.status == "wanted" then
        tooltip:AddLine(("|T%s:14:14:0:0|t WANTED: %s on their head"):format(SKULL, N:PointsText(p.bounty)), 1, 0.30, 0.24)
        local done = p.spread > 1 and ("Done over %d of us, %d different."):format(#p.open, p.spread) or ("Done over %d of us."):format(#p.open)
        tooltip:AddLine(done .. " Priors: " .. p.priors .. ".", 0.85, 0.76, 0.62)
    else
        local by = p.lastClaim and (" Last sorted out by " .. U.StripCodes(nameOf(p.lastClaim.by)) .. ".") or ""
        tooltip:AddLine(("Known to Greenfields. Priors: %d.%s"):format(p.priors, by), 0.85, 0.76, 0.62)
    end
    if type(tooltip.Show) == "function" then tooltip:Show() end
end

-------------------------------------------------------------------------------
-- Doctor
-------------------------------------------------------------------------------
function N:DoctorLines(add)
    local function has(path)
        local t = _G
        for part in path:gmatch("[^%.]+") do
            if type(t) ~= "table" then return false end
            t = rawget(t, part)
        end
        return t ~= nil
    end
    add("Most Wanted: %d deaths watched, %d killers named (last: %s); %d claims", diag.deaths, diag.named, diag.why, diag.claims)
    add("Most Wanted: %d enemy reads, %d with the name hidden; %d killing blows on a hidden target; death recap: %s",
        diag.reads, diag.hidden, diag.kbHidden, diag.recap)
    add("Most Wanted APIs: GetPlayerInfoByGUID %s, UnitSex %s, C_DeathRecap %s, honour line %s",
        tostring(has("GetPlayerInfoByGUID")), tostring(has("UnitSex")), tostring(has("C_DeathRecap.GetRecapEvents")),
        tostring(fmtToPattern(CleanString(G("COMBATLOG_HONORGAIN"))) ~= nil))
    local b = self:Board()
    add("Most Wanted board: %d wanted, %d dealt with, %d bounty hunters", #b.wanted, #b.dealt, #b.hunters)
end

-------------------------------------------------------------------------------
-- Wiring
-------------------------------------------------------------------------------
function N:OnInit()
    local owner = "Nemesis"
    GF:RegisterEvent("PLAYER_DEAD", function() GF:Safe("wanted:dead", onDead) end, owner)
    GF:RegisterEvent("PLAYER_ALIVE", onUp, owner)
    GF:RegisterEvent("PLAYER_UNGHOST", onUp, owner)
    GF:RegisterEvent("NAME_PLATE_UNIT_ADDED", function(_, unit)
        unit = CleanString(unit)
        if unit then readUnit(unit, "plate") end
    end, owner)
    GF:RegisterEvent("PLAYER_TARGET_CHANGED", function() readUnit("target", "target") end, owner)
    GF:RegisterEvent("UPDATE_MOUSEOVER_UNIT", function() readUnit("mouseover", "mouse") end, owner)
    GF:RegisterEvent("UNIT_TARGET", function(_, unit)
        unit = CleanString(unit)
        if unit and (unit:find("^nameplate") or unit == "target" or unit == "mouseover" or unit == "focus") then
            readUnit(unit, unit == "target" and "target" or "plate")
        end
    end, owner)
    GF:RegisterEvent("PARTY_KILL", onPartyKill, owner)
    GF:RegisterEvent("CHAT_MSG_COMBAT_HONOR_GAIN", onHonor, owner)
    GF:RegisterEvent("PLAYER_ENTERING_WORLD", function() myGUID = nil end, owner)
end

function N:OnLogin()
    API.TooltipPostCall("Unit", onUnitTooltip)
    -- in a fight with enemy players about, keep an eye on the nameplates (who's on you)
    GF:Ticker(1, function()
        if pending or not API.InCombat() then return end
        if API.Time() - lastEnemy > 60 then return end
        scanAll("fight")
    end)
    GF:Ticker(60, prune)
end

GF:On("GF_GUILD_READY", function() N:Invalidate() end)
-- a claim waiting on the death that priced it
GF:On("GF_WANTED_CHANGED", function() GF:Safe("wanted:retry", retryWaiting) end)
-- who's whose alt lives in the profile docs, and the board rolls alts up to their mains
GF:On("GF_STORE_CHANGED", function(name)
    if name == "profile" then GF:Debounce("wanted-profiles", 5, function() N:Invalidate() end) end
end)
GF:On("GF_ROSTER_UPDATED", function() GF:Debounce("wanted-roster", 5, function() N:Invalidate() end) end)
