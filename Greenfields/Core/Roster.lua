--[[ Greenfields - Core/Roster.lua
     Guild roster cache + group membership + mains/alts + permissions.

       Roster:Get(key)         -> member table or nil
       Roster:All()            -> { [key] = member }
       Roster:List(filterFn)   -> sorted array
       Roster:IsMember(key)    Roster:InGroup(key)    Roster:IsOnline(key)
       Roster:Class(key)       class file from roster, group, peers or profile
       Roster:MainOf(key)      main character key (alts resolve to their main)
       Roster:AltsOf(mainKey)  -> array of alt keys
       Roster:IsOfficer(key)   rankIndex <= officer threshold (config dataset)
       Roster:IsGM(key)
       Roster:CanManage()      officer, or leader/assist of the current group
       Roster:Count()          people on the roster; namesakes count as two
       Roster:Clash(key)       full names sharing this first name, or nil (see scanGuild)
     Fires GF_ROSTER_UPDATED and GF_GROUP_UPDATED. Member joins/leaves fire
     GF_MEMBER_JOINED(key) / GF_MEMBER_LEFT(key). ]]

local _, GF = ...

local Roster = {}
GF.Roster = Roster

local API, U = GF.API, GF.Util
local pairs, ipairs, type = pairs, ipairs, type

local members = {}      -- key -> member
local everMember = {}   -- first name -> true: on the roster at some point this session
local readAll = false   -- a scan has read every row
local hiddenRows = 0    -- rows the last scan couldn't read
local count = 0
local onlineCount = 0
local clashes = {}      -- first name -> sorted full names: two or more people, one key
local toldClash = {}    -- first name -> the GM's been told
local group = {}        -- key -> group entry (from API.GroupMembers)
local groupList = {}
local firstScan = true

-------------------------------------------------------------------------------
-- Guild config (shared, GM-writable): officer rank threshold etc.
-------------------------------------------------------------------------------
GF.Store:Define({
    name = "config", code = "cf", owner = "shared",
    canWrite = function(author) return Roster:IsGM(author) end,
    keepDays = 100000,
})

function Roster:Config()
    local c = GF.Store:Get("config", "guild") or {}
    return {
        officerRank = type(c.officerRank) == "number" and c.officerRank or 1,
        raidDays = c.raidDays,
        srLimit = type(c.srLimit) == "number" and c.srLimit or 2,
        motd = c.motd,
    }
end

-------------------------------------------------------------------------------
-- Scans
-------------------------------------------------------------------------------
local function firstName(key) return key:match("^[^%s%-]+") or key end

-- One line to the GM, once a clash. The rank comes from the client, since a GM in the clash has no
-- rights on the roster. Held back while the gate's shut, so it's said once it opens.
local function tellGM()
    if GF.gateShut or select(3, API.GuildInfo()) ~= 0 then return end
    for key, names in pairs(clashes) do
        if not toldClash[key] then
            toldClash[key] = true
            GF:Print("%d residents answer to %s (%s), and the addon can't pick the right one out of a lineup. No officer rights, whispers or invites on that name till one of them's gone.",
                #names, key, table.concat(names, ", "))
        end
    end
end

local function scanGuild()
    if API.NoGuild() then
        if count > 0 then
            members, count, onlineCount, clashes, toldClash = {}, 0, 0, {}, {}
            -- that roster's no use for telling who's a guildie in the next one (see hears() in Comm.lua).
            -- Behind the count, so a false "no guild" this early at login has nothing to wipe.
            everMember, readAll, hiddenRows = {}, false, 0
            GF:Fire("GF_ROSTER_UPDATED")
        end
        return
    end
    local list, hidden = API.GuildMembers()
    if #list == 0 then return end -- the client answers empty very early; keep what we had
    hiddenRows = hidden
    if hidden == 0 then readAll = true end
    local fresh, n, online, rows, found = {}, 0, 0, {}, {}
    for _, m in ipairs(list) do
        -- a full name only ever belongs to one person, so the same one twice is one row read twice
        if m.key and not rows[m.name] then
            rows[m.name] = true
            if m.online then online = online + 1 end
            local other = fresh[m.key]
            if other then
                found[m.key] = found[m.key] or { other.name }
                table.insert(found[m.key], m.name)
                m.online = m.online or other.online
            end
            fresh[m.key] = m
            everMember[firstName(m.key)] = true
            n = n + 1
        end
    end
    -- Only small diffs are real joins/leaves; a big swing is the client returning a
    -- partial roster (e.g. the "show offline" toggle), not people moving in or out.
    if not firstScan and math.abs(n - count) <= 3 then
        for key in pairs(fresh) do
            if not members[key] then GF:Fire("GF_MEMBER_JOINED", key) end
        end
        for key in pairs(members) do
            if not fresh[key] then GF:Fire("GF_MEMBER_LEFT", key) end
        end
    end
    firstScan = false
    -- Blizzard lets first names repeat and a key is only a first name, so namesakes are one row with
    -- nobody's rank on it. A hidden row or a partial roster can hide half a pair, which is no reason to
    -- hand the other half the rights back: a clash only ends on a full read that hasn't jumped. A recruit
    -- with the GM's first name switches off GM rights until they leave. That's recoverable, and handing
    -- them to the wrong one isn't. Stats still merge; only the full name fix can stop that.
    if hidden > 0 or math.abs(n - count) > 3 then
        for key, names in pairs(clashes) do found[key] = found[key] or names end
    end
    for key, names in pairs(found) do
        table.sort(names)
        if fresh[key] then fresh[key].rankIndex, fresh[key].rankName = 99, "" end
    end
    for key in pairs(toldClash) do
        if not found[key] then toldClash[key] = nil end
    end
    members, count, onlineCount, clashes = fresh, n, online, found
    tellGM()
    GF:Fire("GF_ROSTER_UPDATED")
end

local function scanGroup()
    group = {}
    groupList = API.GroupMembers()
    for _, g in ipairs(groupList) do
        if g.key then group[g.key] = g end
    end
    GF:Fire("GF_GROUP_UPDATED")
end

function Roster:Refresh()
    API.RequestGuildRoster()
end

GF:RegisterEvent("GUILD_ROSTER_UPDATE", function()
    GF:Debounce("roster-scan", 0.5, scanGuild)
end)
GF:RegisterEvent("GROUP_ROSTER_UPDATE", function()
    GF:Debounce("group-scan", 0.3, scanGroup)
end)
GF:RegisterEvent("PLAYER_GUILD_UPDATE", function() GF:Debounce("roster-scan", 1, scanGuild) end)

GF:On("GF_LOGIN", function()
    API.RequestGuildRoster()
    scanGroup()
    GF:After(3, scanGuild)
    -- keep online status fresh without hammering the server
    GF:Ticker(90, function() API.RequestGuildRoster() end)
end)

-------------------------------------------------------------------------------
-- Queries
-------------------------------------------------------------------------------
function Roster:Get(key) return key and members[key] or nil end
function Roster:All() return members end
function Roster:Count() return count end
function Roster:Clash(key) return key and clashes[key] or nil end
function Roster:Clashes() return clashes end
function Roster:IsMember(key) return key ~= nil and members[key] ~= nil end
--- A row that drops out mid-raid (the client can hide roster fields in combat) doesn't stop someone
-- being a guildie, so this is what decides whose addon messages count (Core/Comm.lua). It goes by
-- first name alone, so it holds up even if the client's surnames stop being stripped from keys.
function Roster:WasMember(key) return key ~= nil and everMember[firstName(key)] == true end
--- A scan has read every row, so someone missing from WasMember really isn't a guildie.
function Roster:ReadAll() return readAll end
function Roster:HiddenRows() return hiddenRows end
function Roster:InGroup(key) return key ~= nil and group[key] ~= nil end
function Roster:Group() return groupList end
function Roster:GroupEntry(key) return key and group[key] or nil end

function Roster:IsOnline(key)
    if key == API.MyKey() then return true end
    local m = members[key]
    if m then return m.online end
    local g = group[key]
    return g and g.online or false
end

function Roster:Class(key)
    if not key then return nil end
    local m = members[key]
    if m and m.class then return m.class end
    local g = group[key]
    if g and g.class then return g.class end
    local prof = GF.Store:Get("profile", key)
    if prof and type(prof.class) == "string" then return prof.class end
    local p = GF.Comm.peers[key]
    return p and type(p.class) == "string" and p.class or nil
end

function Roster:Level(key)
    local m = members[key]
    if m then return m.level end
    local g = group[key]
    if g then return g.level end
    local prof = GF.Store:Get("profile", key)
    return prof and type(prof.level) == "number" and prof.level or 0
end

function Roster:RankIndex(key)
    local m = members[key]
    return m and m.rankIndex or 99
end

function Roster:IsGM(key) return self:RankIndex(key) == 0 end

function Roster:IsOfficer(key)
    if not key then return false end
    return self:RankIndex(key) <= self:Config().officerRank
end

--- Officer, or (when in a group) the leader/an assistant. Use for raid-time tools.
function Roster:CanManage(key)
    key = key or API.MyKey()
    if self:IsOfficer(key) then return true end
    if clashes[key] then return false end -- group lead goes by the same name, so that's a guess too
    local g = group[key]
    return g ~= nil and (g.rank or 0) >= 1
end

--- Sorted array of members passing filterFn(member).
function Roster:List(filterFn, sortKey)
    local out = {}
    for _, m in pairs(members) do
        if not filterFn or filterFn(m) then out[#out + 1] = m end
    end
    sortKey = sortKey or "name"
    table.sort(out, function(a, b)
        if sortKey == "rank" and a.rankIndex ~= b.rankIndex then return a.rankIndex < b.rankIndex end
        if sortKey == "level" and a.level ~= b.level then return a.level > b.level end
        if sortKey == "online" and a.online ~= b.online then return a.online end
        if sortKey == "class" and (a.class or "") ~= (b.class or "") then return (a.class or "") < (b.class or "") end
        return (a.key or "") < (b.key or "")
    end)
    return out
end

function Roster:OnlineCount() return onlineCount end

-------------------------------------------------------------------------------
-- Mains & alts. Sources, in priority order:
--   1. the alt's own profile doc: profile.main = "MainName"
--   2. guild notes: "alt of X", "X's alt", "alt: X", "alt - X", "(X)"
-------------------------------------------------------------------------------
local NOTE_PATTERNS = {
    "[Aa][Ll][Tt]%s+[Oo][Ff]%s+([%a\128-\255]+)",
    "([%a\128-\255]+)'?s%s+[Aa][Ll][Tt]",
    "[Aa][Ll][Tt]%s*[:%-]%s*([%a\128-\255]+)",
    "^%s*%(([%a\128-\255]+)%)%s*$",
}

local function mainFromNote(note)
    if type(note) ~= "string" or note == "" then return nil end
    for _, pat in ipairs(NOTE_PATTERNS) do
        local name = note:match(pat)
        if name and #name >= 2 then
            local key = API.Key(name:sub(1, 1):upper() .. name:sub(2):lower())
            if key and members[key] then return key end
        end
    end
    return nil
end

function Roster:MainOf(key)
    if not key then return nil end
    local prof = GF.Store:Get("profile", key)
    if prof and type(prof.main) == "string" and prof.main ~= "" and prof.main ~= key
        and #prof.main <= 48 and not prof.main:find("|", 1, true) then
        return prof.main
    end
    local m = members[key]
    if m then
        local main = mainFromNote(m.officerNote) or mainFromNote(m.note)
        if main and main ~= key then return main end
    end
    return key
end

function Roster:IsAlt(key) return self:MainOf(key) ~= key end

function Roster:AltsOf(mainKey)
    local out = {}
    for key in pairs(members) do
        if key ~= mainKey and self:MainOf(key) == mainKey then out[#out + 1] = key end
    end
    table.sort(out)
    return out
end

--- Display helper: class-coloured short name.
function Roster:Colored(key)
    return U.ClassName(key, self:Class(key))
end
