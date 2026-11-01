--[[ Greenfields - Core/Books.lua
     Starting the books on day one. A race board can't go back and ask who dinged when, so this writes
     it down for later. Nothing here goes on screen and nothing's sent.

       GreenfieldsCharDB.books      this character's own dings
         dings[level] = time        the first time we saw this character hit that level
         floor = { l, t }           the level it was already at when we started watching. Anything before
                                    that is a gap, not a guess, so a late install gets an honest floor.
       GF.DB:Local("books")         this PC's note on the guild, one per guild partition
         seen[full name] = time     the first time this PC saw them on the roster
         since = time               when the note started: anyone stamped about then was already here

     Dings carry on with the gate shut, like the rest of the stats, because the ones from before the
     charter goes in on launch morning are the ones you can't get back. The guild note doesn't: it's
     only written with the gate open, for a guild whose name we can read right now and whose partition
     is the one in use. So once the lock's live, no other guild's roster gets written down. Before that
     the gate's open for anyone, but each guild has its own partition, so a test guild's note can't end
     up in the Greenfields one.

     It reads the whole roster each time rather than the roster's join events, which skip big swings.
     Full names, because first names can repeat. ]]

local _, GF = ...

local API = GF.API
local floor = math.floor

local MAX_LEVEL = 100       -- a level above this isn't a level, which is what caps the ding rows
local MAX_SEEN = 1000       -- the most a guild can hold. Later arrivals just don't get noted
local LEVEL_READ_DELAY = 1  -- the client's own level catches up a moment after the event

local function books()
    if type(GF.cdb) ~= "table" then return nil end
    if type(GF.cdb.books) ~= "table" then GF.cdb.books = {} end
    local b = GF.cdb.books
    if type(b.dings) ~= "table" then b.dings = {} end
    return b
end

local function setFloor(b, level, now)
    if type(b.floor) ~= "table" and level > 0 then b.floor = { l = level, t = now } end
end

local function stamp(level, now)
    local b = books()
    if not b or type(level) ~= "number" or level ~= floor(level) or level < 2 or level > MAX_LEVEL then return end
    setFloor(b, level, now)
    if not b.dings[level] then b.dings[level] = now end
end

GF:RegisterEvent("PLAYER_LEVEL_UP", function(_, level)
    local now = API.ServerTime()
    level = API.CleanNumber(level)
    if level then return stamp(level, now) end
    -- the event wouldn't say, so ask the client, but keep the time it happened
    GF:After(LEVEL_READ_DELAY, function() stamp(API.UnitLevel("player"), now) end)
end, "Books")

local function noteRoster()
    if GF.gateShut or not GF.DB:Ready() then return end
    local guild = GF.DB:GuildKey()
    if not guild or guild ~= GF.gdbKey then return end
    local l = GF.DB:Local("books")
    if type(l.seen) ~= "table" then l.seen, l.count = {}, 0 end
    local seen, count = l.seen, tonumber(l.count) or 0
    local now = API.ServerTime()
    l.since = l.since or now
    local function note(name)
        if type(name) == "string" and not seen[name] and count < MAX_SEEN then
            seen[name] = now
            count = count + 1
        end
    end
    for key, m in pairs(GF.Roster:All()) do
        -- namesakes share a row on the roster, so the row only has one of their names on it
        local names = GF.Roster:Clash(key)
        if names then
            for _, name in ipairs(names) do note(name) end
        else
            note(m.name)
        end
    end
    l.count = count
end

GF:On("GF_ROSTER_UPDATED", noteRoster)

GF:On("GF_LOGIN", function()
    local b = books()
    if b then setFloor(b, API.UnitLevel("player"), API.ServerTime()) end
end)
