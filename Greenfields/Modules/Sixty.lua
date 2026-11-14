--[[ Greenfields - Modules/Sixty.lua
     Level 60: the ceremony when you hit it, fireworks for the street when a guildie does, and the
     Sixty Club, everyone who's made it, in order. How it all looks is Modules/SixtyUI.lua.

       GreenfieldsCharDB.sixty   { t = when you hit 60, p = /played at the first reading after it,
                                   pt = when that reading was, n = which 60 in the guild you were,
                                   late = it happened before this was here, seen = when the ceremony played }
       GreenfieldsDB.sixties     [character key] = when, for every 60 on this account, so an alt's
                                   ceremony knows it isn't your first. 0 = time unknown.
       profile.sixty             { t, p, f, s, n } in your own profile doc (Core/Profile.lua): when,
                                   /played, the level and time the addon started watching you from, and
                                   which 60 in the guild you were
       op "S6"                   { t, p, n } to the guild the moment it happens, for the fireworks

     A 60 from before this was here still gets its ceremony, once, a little after login, when
     Core/Books.lua stamped the ding (so the addon saw it happen). The ceremony waits out combat and
     death, and never runs with the guild lock shut (Core/Gate.lua).

     The street hears about a 60 twice: this module's "S6" and the Neighbourhood Watch's level-60 line
     (Modules/Feed.lua hands that one here instead of popping its own sign). Whichever lands first
     starts the fireworks and the other fills in what it knows, so a mate on an older copy, who only
     sends the Watch line, still gets them.

     Fires GF_SIXTY_CEREMONY(recap), GF_SIXTY_HEARD(key, info, fresh) and GF_SIXTY_CHANGED. ]]

local _, GF = ...
local API, U = GF.API, GF.Util

local S = GF:NewModule("Sixty")
GF.Sixty = S

local type, pairs, ipairs, tonumber, tostring = type, pairs, ipairs, tonumber, tostring
local floor, abs, sort = math.floor, math.abs, table.sort

local MAX = 60
S.MAX = MAX
local DING_DELAY = 2.5      -- the game's own "you have reached level 60" goes first
local LOGIN_DELAY = 14      -- a late ceremony waits for the login signs to clear
local RETRY = 3             -- seconds between looks while you're in a fight or dead
local RETRY_FOR = 1800      -- and it gives up after half an hour of that (next login tries again)
local PLAYED_WAIT = 4       -- how long the street's news waits for /played
local LATE_PLAYED = 6 * 3600  -- a /played read this long after the ding is "so far", not "to 60"
local HEARD_GAP = 1800      -- one round of fireworks per guildie per half hour
local FRESH = 1800          -- a 60 older than this is news, not fireworks
local NEXT_MAX = 8

local function G(name) return rawget(_G, name) end
local function settings() return GF.db and GF.db.settings or {} end

local function num(v, lo, hi)
    v = API.CleanNumber(v)
    if type(v) ~= "number" or v ~= v or v < (lo or 0) or v > (hi or 4e9) then return nil end
    return v
end

local function mine()
    if type(GF.cdb) ~= "table" then return nil end
    if type(GF.cdb.sixty) ~= "table" then GF.cdb.sixty = {} end
    return GF.cdb.sixty
end

local function account()
    if type(GF.db) ~= "table" then return {} end
    if type(GF.db.sixties) ~= "table" then GF.db.sixties = {} end
    return GF.db.sixties
end

local function myLevel() return API.UnitLevel("player") or 0 end

-------------------------------------------------------------------------------
-- Words
-------------------------------------------------------------------------------
-- The ceremony's line, under your name. Proud first, with the odd one for the old days.
local LEAD = {
    "Not bad for someone from Greenfields.",
    "Nobody from round here was meant to get this far. Look at you.",
    "From the back of the servo to the top of Azeroth.",
    "They said you'd never amount to anything. They were wrong about sixty times.",
    "Sixty levels, and not one of them handed to you.",
    "You got out of the alley. Took the long way round, but you got out.",
    "Mum always said you'd go places. She didn't mean Silithus, but still.",
    "Clean, sober and sixty. Well. Sixty.",
    "The highest you've ever been without help.",
    "Put the pipe down and the lighter up. You've earned this one.",
}
S.LEAD = LEAD

-- Your own "Tell the guild" button, in guild chat.
local TELL = {
    "SIXTY. Not bad for someone from Greenfields.",
    "Dinged 60. Thanks for the carries, legends.",
    "60! Somebody light the drum.",
    "Made it to 60. Never doubted myself once. (I doubted myself constantly.)",
}

-- A guildie's "Grats" button on someone else's fireworks.
local GRATS = {
    "Grats {name}! Sixty!",
    "Grats {name}, you absolute weapon.",
    "SIXTY! Get around {name}!",
    "Grats {name}. Not bad for someone from Greenfields.",
    "Grats {name}! First round's on you.",
}

local function fill(line, name) return (line:gsub("{name}", function() return name or "legend" end)) end

-------------------------------------------------------------------------------
-- What the books say
-------------------------------------------------------------------------------
--- The climb as the books have it: { {l, t}, ... }, oldest first, every level a step up. It ends at
-- 60 when we know when that was. Starts wherever we started watching (Core/Books.lua's floor).
function S:Climb()
    local b = type(GF.cdb) == "table" and GF.cdb.books
    local pts = {}
    if type(b) == "table" then
        local fl = b.floor
        if type(fl) == "table" and type(fl.l) == "number" and type(fl.t) == "number" then
            pts[#pts + 1] = { l = fl.l, t = fl.t }
        end
        if type(b.dings) == "table" then
            for l, t in pairs(b.dings) do
                if type(l) == "number" and type(t) == "number" and l >= 2 and l <= MAX then
                    pts[#pts + 1] = { l = l, t = t }
                end
            end
        end
    end
    local m = mine()
    if m and type(m.t) == "number" then pts[#pts + 1] = { l = MAX, t = m.t } end
    sort(pts, function(a, c)
        if a.t ~= c.t then return a.t < c.t end
        return a.l < c.l
    end)
    -- only ever up: a stamp that goes backwards (the PC's clock jumped) is dropped
    local out, top = {}, 0
    for _, p in ipairs(pts) do
        if p.l > top then
            out[#out + 1] = p
            top = p.l
        end
    end
    return out
end

--- Someone's 60 as their profile tells it: { t, p, f } or nil. Yours comes from your own books.
function S:Of(key)
    if key and key == API.MyKey() then
        local m = mine()
        if not m or myLevel() < MAX and not m.t then return nil end
        local climb = self:Climb()
        local first = climb[1]
        local from = first and m.t and first.t < m.t and first or nil
        return { t = m.t, p = m.p, f = from and from.l or nil, s = from and from.t or nil, n = m.n }
    end
    local prof = GF.Profile and GF.Profile:Get(key)
    local s = type(prof) == "table" and prof.sixty
    return type(s) == "table" and s or nil
end

local function memberLevel(m) return type(m) == "table" and tonumber(m.level) or 0 end

local function others()
    local out, me = {}, API.MyKey()
    for key, m in pairs(GF.Roster:All()) do
        if key ~= me and memberLevel(m) >= MAX then out[#out + 1] = key end
    end
    return out
end

local function rosterRead()
    local R = GF.Roster
    return R and R.Count and R:Count() >= 2
end

--- Which 60 in the guild you are: 1 for the first, nil when it can't be told. Right when it happens
-- that's everyone already there plus you. Later on, everyone else needs a known time to be sure.
local function place(t, live)
    if not rosterRead() then return nil end
    local list = others()
    if live or #list == 0 then return #list + 1 end
    if not t then return nil end
    local n = 1
    for _, key in ipairs(list) do
        local s = S:Of(key)
        if not (s and s.t) then return nil end
        if s.t < t then n = n + 1 end
    end
    return n
end

--- Your earlier 60s on this account (an unknown time counts as earlier).
local function altsBefore(t)
    local n, me = 0, API.MyKey()
    for key, when in pairs(account()) do
        if key ~= me and type(when) == "number" and (when == 0 or not t or when < t) then n = n + 1 end
    end
    return n
end

local function stat(key)
    local s = type(GF.cdb) == "table" and GF.cdb.stats
    return type(s) == "table" and tonumber(s[key]) or 0
end

local function myName()
    local R = GF.Roster
    local key = API.MyKey()
    local colored = R and R.Colored and key and R:Colored(key)
    return key, type(colored) == "string" and colored or key
end

--- Everything the ceremony shows, for this character.
function S:Recap()
    local m = mine() or {}
    local key, colored = myName()
    local climb = self:Climb()
    local first = climb[1]
    local t = m.t
    local _, raceName = API.UnitRace("player")
    local r = {
        key = key, colored = colored, class = API.UnitClassFile("player"), race = raceName,
        t = t, p = m.p, pLate = m.p and m.pt and t and (m.pt - t) > LATE_PLAYED or false,
        late = m.late and true or false,
        climb = climb,
        from = first and first.l or nil,
        days = (t and first and first.t < t) and (t - first.t) / 86400 or nil,
        n = m.n or place(t, false),
        alts = altsBefore(t),
        stats = { deaths = stat("deaths_total"), quests = stat("quests"), jumps = stat("jumps"),
                  flights = stat("flights"), hearths = stat("hearths") },
        lead = U.Pick(LEAD),
    }
    local N = GF.Nemesis
    if N and N.NemesisOf and key then
        local ok, p, n = pcall(N.NemesisOf, N, key)
        if ok and type(p) == "table" and type(n) == "number" and n > 0 then r.nemesis = { name = p.name, n = n, entry = p } end
    end
    return r
end

-------------------------------------------------------------------------------
-- The ceremony
-------------------------------------------------------------------------------
local waiting = false

local function ready()
    return not API.InCombat() and not API.UnitIsDead("player")
end

--- Plays the ceremony once it's safe: out of a fight, alive, and the guild lock open.
function S:Queue(delay)
    if waiting then return end
    waiting = true
    local started = API.Time()
    local function try()
        if GF.gateShut then waiting = false return end
        if not ready() then
            if API.Time() - started > RETRY_FOR then waiting = false return end
            return GF:After(RETRY, try)
        end
        waiting = false
        S:Play()
    end
    GF:After(delay or DING_DELAY, try)
end

function S:Play()
    if GF.gateShut then return end
    local m = mine()
    if not m then return end
    m.seen = API.ServerTime()
    local key = API.MyKey()
    if key then account()[key] = m.t or account()[key] or 0 end
    local r = self:Recap()
    -- a late ceremony works its place out from the street's dates; once it can, it keeps it
    if r.n and not m.n then
        m.n = r.n
        if GF.Profile then GF.Profile:Touch() end
    end
    GF:Fire("GF_SIXTY_CEREMONY", r)
end

--- A ceremony for someone who isn't 60 yet: your name, a made-up climb. /gf sixty test.
function S:Preview()
    local key, colored = myName()
    local now = API.ServerTime()
    local climb, t = {}, now - 9 * 86400
    -- an honest-looking climb: quick early, slow late, the odd night off
    local gaps = { 0.6, 0.7, 0.8, 1, 1.1, 1.3, 1.4, 1.6, 1.8, 2, 2.2, 2.5, 2.6, 3, 3.1, 3.4, 3.6, 3.9, 4.1, 4.4 }
    for l = 1, MAX do
        climb[#climb + 1] = { l = l, t = t }
        local g = gaps[floor((l - 1) / 3) + 1] or 4.6
        t = t + floor(g * 3600 * (l % 7 == 0 and 4 or 1))
    end
    climb[#climb].t = now
    return {
        key = key, colored = colored, class = API.UnitClassFile("player"), race = select(2, API.UnitRace("player")),
        t = now, p = 4 * 86400 + 7 * 3600, climb = climb, from = 1,
        days = (now - climb[1].t) / 86400, n = 3, alts = 0, preview = true,
        stats = { deaths = 37, quests = 412, jumps = 18204, flights = 66, hearths = 51 },
        nemesis = { name = "Gnomeo", n = 6 },
        lead = U.Pick(LEAD),
    }
end

function S:TellLine() return U.Pick(TELL) end
function S:GratsLine(name) return fill(U.Pick(GRATS), name) end

-------------------------------------------------------------------------------
-- When it happens
-------------------------------------------------------------------------------
local function askPlayed()
    local f = G("RequestTimePlayed")
    if type(f) ~= "function" then return false end
    return pcall(f) and true or false
end

local function tellStreet()
    local m = mine()
    if not (m and m.t) or GF.gateShut or not (GF.Comm and GF.Comm.Guild) then return end
    if m.told then return end
    m.told = true
    GF.Comm:Guild("S6", { t = m.t, p = m.p, n = m.n }, "NORMAL")
end

local function reached(now)
    local m = mine()
    if not m or m.t then return end    -- once per character
    m.t = now
    m.n = place(now, true)
    m.late = nil
    local key = API.MyKey()
    if key then account()[key] = now end
    askPlayed()
    GF:After(PLAYED_WAIT, tellStreet)
    if GF.Profile then GF.Profile:Touch() end
    GF:Fire("GF_SIXTY_CHANGED")
    S:Queue(DING_DELAY)
end

GF:RegisterEvent("PLAYER_LEVEL_UP", function(_, level)
    local now = API.ServerTime()
    level = API.CleanNumber(level)
    if level then
        if level >= MAX then reached(now) end
        return
    end
    -- the event wouldn't say: ask the client a moment later, but keep the time it happened
    GF:After(1, function() if myLevel() >= MAX then reached(now) end end)
end, "Sixty")

GF:RegisterEvent("TIME_PLAYED_MSG", function(_, total)
    total = num(total, 1, 1e9)
    local m = mine()
    if not (m and total) or myLevel() < MAX or m.p then return end
    -- the first reading at 60 is the one that counts
    m.p, m.pt = floor(total), API.ServerTime()
    if GF.Profile then GF.Profile:Touch() end
    GF:Fire("GF_SIXTY_CHANGED")
    if m.t and not m.told and API.ServerTime() - m.t < FRESH then tellStreet() end
end, "Sixty")

-- Hit 60 before this arrived: the ceremony you missed, once. It goes by the books' ding stamp, so it's
-- for a 60 the addon saw happen. Someone who was 60 before they installed it has no ding to celebrate;
-- the Sixty Club still lists them.
GF:On("GF_LOGIN", function()
    GF:After(LOGIN_DELAY, function()
        local m = mine()
        if not m or m.seen or myLevel() < MAX then return end
        if not m.t then
            local b = GF.cdb.books
            local t = type(b) == "table" and type(b.dings) == "table" and b.dings[MAX]
            if type(t) ~= "number" then return end
            m.t, m.late = t, true
        end
        if not m.p then askPlayed() end
        if GF.Profile then GF.Profile:Touch() end
        S:Queue(0.1)
    end)
end)

-------------------------------------------------------------------------------
-- The street
-------------------------------------------------------------------------------
local heard = {}   -- key -> { at, info }

--- A guildie hit 60. info: { t, p, n, line }. Returns true when there are fireworks for it, which
-- tells the Watch to keep its own sign.
function S:Heard(key, info)
    if GF.gateShut or type(key) ~= "string" or key == API.MyKey() then return false end
    if settings().sixtyBanners == false then return false end
    local R = GF.Roster
    if R and R.Count and R:Count() > 0 and not R:IsMember(key) then return false end
    info = type(info) == "table" and info or {}
    local now = API.ServerTime()
    if info.t and abs(now - info.t) > FRESH then return false end
    local h = heard[key]
    local fresh = not h or API.Time() - h.at > HEARD_GAP
    if fresh then
        h = { at = API.Time(), info = {} }
        heard[key] = h
    end
    for k, v in pairs(info) do h.info[k] = v end
    GF:Fire("GF_SIXTY_HEARD", key, h.info, fresh)
    return true
end

GF.Comm:Register("S6", function(p, sender, channel)
    if channel ~= "GUILD" or type(p) ~= "table" or type(sender) ~= "string" then return end
    S:Heard(sender, { t = num(p.t, 1), p = num(p.p, 1, 1e9), n = num(p.n, 1, 1000) })
end)

-------------------------------------------------------------------------------
-- The Sixty Club
-------------------------------------------------------------------------------
--- Everyone on the roster who's made it, in the order they did: { key, t, p, f, s, n, place, me }.
-- Those without a known time (no addon, or they got there before it) come after, A to Z.
function S:Club()
    local out, seen, me = {}, {}, API.MyKey()
    local function add(key, level)
        if seen[key] then return end
        local s = self:Of(key)
        if level < MAX and not (s and s.t) then return end
        seen[key] = true
        out[#out + 1] = { key = key, t = s and s.t, p = s and s.p, f = s and s.f, s = s and s.s, n = s and s.n,
                          me = key == me }
    end
    for key, m in pairs(GF.Roster:All()) do add(key, memberLevel(m)) end
    if me and myLevel() >= MAX then add(me, MAX) end
    sort(out, function(a, b)
        if (a.t ~= nil) ~= (b.t ~= nil) then return a.t ~= nil end
        if a.t and a.t ~= b.t then return a.t < b.t end
        return tostring(a.key) < tostring(b.key)
    end)
    -- the place is the one each of them counted the day they made it, which knows about the 60s
    -- without a date. Failing that it's the order here, which only holds when every date is known.
    local undated = 0
    for _, e in ipairs(out) do
        if not e.t then undated = undated + 1 end
    end
    for i, e in ipairs(out) do
        if e.t then e.place = e.n or (undated == 0 and i or nil) end
    end
    return out
end

--- Who's next through the door: the closest under 60, highest first. { key, level }
function S:Next(n)
    local out, me = {}, API.MyKey()
    for key, m in pairs(GF.Roster:All()) do
        local l = memberLevel(m)
        if l >= 40 and l < MAX and not (key == me and myLevel() >= MAX) then out[#out + 1] = { key = key, level = l } end
    end
    sort(out, function(a, b)
        if a.level ~= b.level then return a.level > b.level end
        return tostring(a.key) < tostring(b.key)
    end)
    for i = (n or NEXT_MAX) + 1, #out do out[i] = nil end
    return out
end

--- How many on the roster, and how many of them are 60.
function S:Count()
    local all, at = 0, 0
    for _, m in pairs(GF.Roster:All()) do
        all = all + 1
        if memberLevel(m) >= MAX then at = at + 1 end
    end
    return at, all
end

GF.Profile:Contribute("sixty", function()
    if myLevel() < MAX then return nil end
    local s = S:Of(API.MyKey())
    return s and { t = s.t, p = s.p, f = s.f, s = s.s, n = s.n } or nil
end)

GF:On("GF_STORE_CHANGED", function(name)
    if name == "profile" then GF:Debounce("sixty-changed", 1, function() GF:Fire("GF_SIXTY_CHANGED") end) end
end)
GF:On("GF_ROSTER_UPDATED", function() GF:Debounce("sixty-changed", 1, function() GF:Fire("GF_SIXTY_CHANGED") end) end)

-------------------------------------------------------------------------------
-- /gf sixty
-------------------------------------------------------------------------------
GF:RegisterSlash("sixty", function(args)
    args = (args or ""):lower()
    if args == "test" then
        GF:Fire("GF_SIXTY_CEREMONY", S:Preview())
    elseif args == "street" then
        local key = API.MyKey() or "Bazza"
        GF:Fire("GF_SIXTY_HEARD", key, { t = API.ServerTime(), p = 4 * 86400 + 7 * 3600, n = 2,
            line = (key .. " hit 60. Someone light the drum."), preview = true }, true)
    elseif myLevel() >= MAX or (mine() and mine().t) then
        S:Play()
    else
        GF:Print("You're level %d. Here's what 60 looks like, so you know what you're in for.", myLevel())
        GF:Fire("GF_SIXTY_CEREMONY", S:Preview())
    end
end, "[test|street] - play your level 60 again (test: a preview; street: a guildie's fireworks)")
