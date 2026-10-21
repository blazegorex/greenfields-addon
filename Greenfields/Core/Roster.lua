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
       Roster:Count()
     Fires GF_ROSTER_UPDATED and GF_GROUP_UPDATED. Member joins/leaves fire
     GF_MEMBER_JOINED(key) / GF_MEMBER_LEFT(key). ]]

local _, GF = ...

local Roster = {}
GF.Roster = Roster

local API, U = GF.API, GF.Util
local pairs, ipairs, type = pairs, ipairs, type

local members = {}      -- key -> member
local count = 0
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
local function scanGuild()
    if not API.InGuild() then
        if count > 0 then
            members, count = {}, 0
            GF:Fire("GF_ROSTER_UPDATED")
        end
        return
    end
    local list = API.GuildMembers()
    if #list == 0 then return end -- the client answers empty very early; keep what we had
    local fresh, n = {}, 0
    for _, m in ipairs(list) do
        if m.key then
            fresh[m.key] = m
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
    members, count = fresh, n
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
function Roster:IsMember(key) return key ~= nil and members[key] ~= nil end
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

function Roster:OnlineCount()
    local n = 0
    for _, m in pairs(members) do if m.online then n = n + 1 end end
    return n
end

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
