--[[ tools/harness/wow_mock_game.lua  --  the GAME-STATE layer of the Forever client mock.

     Everything that depends on "who am I, where am I, who am I with": player identity,
     guild roster, group/raid membership and unit tokens, instances, professions and the
     spellbook, items/bags/item cache, auras, the trade skill window, loot and rolls,
     money/merchant, chat + addon-message transport (outbox drained by run.py), combat /
     encounter / chat-lockdown state, modifiers and the cursor.

     Driven by MOCK.CFG (built by run.py per client):
       CFG.name            this client's character name
       CFG.realm           realm name ("Arugal")
       CFG.world           array of every character in the simulated world
                           { name, realm, class, race, faction, level, guid, sex, client }
       CFG.guild           { name, ranks = {...}, members = { {name, rankIndex, note,
                             officerNote, online, mobile, zone, ap}, ... } } or nil
       CFG.money, CFG.zone, CFG.professions (slot -> {skillLine, name, rank, max, icon}),
       CFG.known (array of spell IDs), CFG.bags ({[bag] = { {itemID, count}, ...}}),
       CFG.cachedItems (array of item IDs cached at login), CFG.pvp = {hk, dk, rank}

     Dynamic state changes go through MOCK.Game.* (called by run.py) which also fire the
     matching events the way the client does. Requests the client makes of "the server"
     (chat, rolls, invites, subgroup moves) are queued on MOCK.requests; addon messages on
     MOCK.outbox. run.py routes both between clients and delivers them next tick.

     Secret values: MOCK.MaybeSecret(category, v) wraps values when run.py switched the
     category on (MOCK.secretOn). Categories used here: names (unit names/class tokens of
     non-player units), guids, roster (guild/raid roster fields), auras (aura fields; also
     forced in combat, as Forever hides auras in combat), spell (spell cooldowns in combat),
     chat (chat payloads; see wow_mock_data.lua), encounter (encounter payloads). ]]

local MOCK = ...
local R = MOCK.R
local type, pairs, ipairs, select, tostring, tonumber = R.type, R.pairs, R.ipairs, R.select, R.tostring, R.tonumber
local error, rawget, rawset, setmetatable = R.error, R.rawget, R.rawset, R.setmetatable
local floor, max, min, abs = R.floor, R.max, R.min, R.abs
local format, sub, gsub, find, upper, lower, match, rep = R.format, R.sub, R.gsub, R.find, R.upper, R.lower, R.match, R.rep
local tinsert, tremove, concat, sort = R.insert, R.remove, R.concat, R.sort
local S, ST = MOCK.S, MOCK.ST
local Protect, isSecret, MaybeSecret = MOCK.Protect, MOCK.IsSecret, MOCK.MaybeSecret
local G = MOCK.G
local CFG = MOCK.CFG

local function isNum(v) return type(v) == "number" and v == v end
local function argErr(fname, n, expected, got, level)
    error(format("bad argument #%d to '%s' (%s expected, got %s)", n, fname, expected,
        isSecret(got) and "secret" or type(got)), (level or 2) + 1)
end
local function needString(v, fname, n, level)
    if type(v) ~= "string" or isSecret(v) then argErr(fname, n or 1, "string", v, (level or 2) + 1) end
end
local function needNumber(v, fname, n, level)
    if not isNum(v) or isSecret(v) then argErr(fname, n or 1, "number", v, (level or 2) + 1) end
end

local Game = {}
MOCK.Game = Game

-------------------------------------------------------------------------------
-- World / identity
-------------------------------------------------------------------------------
local W = { realm = CFG.realm or "Arugal", players = {}, byName = {} }
MOCK.world = W
for _, p in ipairs(CFG.world or {}) do
    p.realm = p.realm or W.realm
    W.players[#W.players + 1] = p
    W.byName[p.name] = p
end
local MYNAME = CFG.name or MOCK.clientName or "Player"
if not W.byName[MYNAME] then
    local me = { name = MYNAME, realm = W.realm, class = CFG.class or "WARRIOR", race = CFG.race or "Human",
        faction = CFG.faction or "Alliance", level = CFG.level or 60, guid = CFG.guid or "Player-1-00000001", sex = 2 }
    W.players[#W.players + 1] = me
    W.byName[MYNAME] = me
end
local ME = W.byName[MYNAME]

local RACES = {
    Human = { "Human", 1 }, Orc = { "Orc", 2 }, Dwarf = { "Dwarf", 3 }, NightElf = { "Night Elf", 4 },
    Scourge = { "Undead", 5 }, Tauren = { "Tauren", 6 }, Gnome = { "Gnome", 7 }, Troll = { "Troll", 8 },
    Skyborne = { "Skyborne", 90 },
}

local state = {
    combat = false, encounter = nil, chatLockdown = false, forceChatLockdown = false,
    dead = false, ghost = false, afk = false, dnd = false, falling = false, taxi = false,
    money = CFG.money or 0, zone = CFG.zone or "Stormwind City", subzone = CFG.subzone or "",
    group = nil, instance = nil, target = nil,
    guildLoaded = false, lastRosterRequest = -1000,
    auras = {}, spellCD = {}, itemCD = {},
    loot = nil, rolls = {}, tradeskill = nil, merchant = nil,
    mods = { shift = false, ctrl = false, alt = false },
    readyCheck = nil,
    xp = 0,
}
MOCK.state = state

MOCK.outbox = {}       -- addon messages: { prefix, text, chatType, target, logged, t }
MOCK.requests = {}     -- "server" requests: { kind = ..., ... }
MOCK.chatLog = {}      -- every chat line this client sent: { t, chatType, target, text, hw }
MOCK.printLog = {}     -- DEFAULT_CHAT_FRAME:AddMessage lines (addon prints)
MOCK.sounds = {}       -- soundKitID / file -> count
MOCK.later = {}        -- { due, fn } run at the start of a later tick
MOCK.commStats = { sent = 0, bytes = 0, rejected = {}, throttled = 0 }

local function later(delay, fn)
    MOCK.later[#MOCK.later + 1] = { due = MOCK.uptime + (delay or 0), fn = fn, seq = #MOCK.later + 1 }
end
MOCK.Later = later

local function fire(event, ...) return MOCK.FireEvent(event, ...) end

local function fullName(rec)
    if not rec then return nil end
    return rec.name .. "-" .. gsub(rec.realm or W.realm, "[%s']", "")
end
MOCK.FullName = function(name) local r = W.byName[name] return r and fullName(r) or (name .. "-" .. W.realm) end

local function stripRealm(name)
    if type(name) ~= "string" then return name end
    return match(name, "^([^%-]+)") or name
end

-------------------------------------------------------------------------------
-- Guild
-------------------------------------------------------------------------------
local guild = CFG.guild
local guildByName = {}
if guild then
    guild.ranks = guild.ranks or { "Guild Master", "Officer", "Veteran", "Member", "Initiate" }
    for _, m in ipairs(guild.members or {}) do guildByName[m.name] = m end
end
local function myGuildRank()
    local m = guild and guildByName[MYNAME]
    return m and m.rankIndex or 3
end

-------------------------------------------------------------------------------
-- Group
-------------------------------------------------------------------------------
-- state.group = { kind = "party"|"raid", category = 1, members = { {name, subgroup, rank, role,
--                 combatRole, isML, online, dead, zone}, ... }, byName = { name -> entry } }
local function groupEntry(name)
    local g = state.group
    return g and g.byName[name] or nil
end

local function memberRec(entry)
    if not entry then return nil end
    return W.byName[entry.name] or { name = entry.name, realm = entry.realm or W.realm, class = entry.class or "WARRIOR",
        race = entry.race or "Human", faction = ME.faction, level = entry.level or 60,
        guid = entry.guid or ("Player-1-" .. format("%08X", #entry.name * 7919)), sex = 2 }
end

local function partyList()
    -- party1..4 : other members of my party (raid: my subgroup), in roster order
    local g = state.group
    local out = {}
    if not g then return out end
    local mine = groupEntry(MYNAME)
    for _, e in ipairs(g.members) do
        if e.name ~= MYNAME and (g.kind ~= "raid" or (mine and e.subgroup == mine.subgroup)) then out[#out + 1] = e end
    end
    return out
end

--- resolve(unit) -> worldRec, groupEntry, isSelf  (nil when the token names nobody)
local function resolve(unit)
    if type(unit) ~= "string" then return nil end
    local u = lower(unit)
    if u == "player" then return ME, groupEntry(MYNAME), true end
    local g = state.group
    local n = match(u, "^party(%d)$")
    if n then
        local e = partyList()[tonumber(n)]
        if e then return memberRec(e), e, e.name == MYNAME end
        return nil
    end
    n = match(u, "^raid(%d+)$")
    if n then
        if not (g and g.kind == "raid") then return nil end
        local e = g.members[tonumber(n)]
        if e then return memberRec(e), e, e.name == MYNAME end
        return nil
    end
    if u == "target" then
        if not state.target then return nil end
        local rec = W.byName[state.target]
        return rec, groupEntry(state.target), state.target == MYNAME
    end
    if u == "focus" or u == "mouseover" or u == "npc" or u == "pet" or u == "vehicle" or u == "none"
        or match(u, "^boss%d$") or match(u, "^arena%d$") or match(u, "^nameplate%d+$") or match(u, "target$")
        or match(u, "pet%d*$") then
        return nil
    end
    -- a group member's name works as a unit token
    local name = stripRealm(unit)
    if name == MYNAME then return ME, groupEntry(MYNAME), true end
    local e = groupEntry(name)
    if e then return memberRec(e), e, false end
    return nil
end
MOCK.ResolveUnit = resolve

local function unitCheck(unit, fname)
    if type(unit) ~= "string" then
        error(format("bad argument #1 to '%s' (Usage: %s(unit))", fname, fname), 3)
    end
    if isSecret(unit) then error(format("bad argument #1 to '%s' (secret unit token)", fname), 3) end
end

local function secretFor(cat, isSelf, v)
    if isSelf then return v end
    return MaybeSecret(cat, v)
end

-------------------------------------------------------------------------------
-- Time / build / realm / misc globals
-------------------------------------------------------------------------------
G.GetTime = function() return MOCK.uptime end
G.GetServerTime = function() return floor(MOCK.epoch) end
G.GetGameTime = function()
    local t = MOCK.date("*t", floor(MOCK.epoch))
    return t.hour, t.min
end
G.GetSessionTime = function() return floor(MOCK.uptime - (CFG.uptime or 1000)) end
G.C_DateAndTime = {
    GetServerTimeLocal = function() return floor(MOCK.epoch) + MOCK.TZ end,
    GetCurrentCalendarTime = function()
        local t = MOCK.date("*t", floor(MOCK.epoch))
        return { year = t.year, month = t.month, monthDay = t.day, weekday = t.wday, hour = t.hour, minute = t.min }
    end,
    GetSecondsUntilWeeklyReset = function()
        -- weekly reset: Wednesday 08:00 AWST (Oceanic)
        local now = floor(MOCK.epoch) + MOCK.TZ
        local dow = (floor(now / 86400) + 4) % 7          -- 0 = Sunday
        local into = now % 86400
        local daysUntil = (3 - dow) % 7
        local secs = daysUntil * 86400 + 8 * 3600 - into
        if secs <= 0 then secs = secs + 7 * 86400 end
        return secs
    end,
    GetSecondsUntilDailyReset = function()
        local into = (floor(MOCK.epoch) + MOCK.TZ) % 86400
        local s = 8 * 3600 - into
        if s <= 0 then s = s + 86400 end
        return s
    end,
}
G.GetQuestResetTime = G.C_DateAndTime.GetSecondsUntilDailyReset

G.GetBuildInfo = function() return "1.60.1", "70425", "Oct 16 2026", 16001, "", "Release", 16001 end
G.GetLocale = function() return CFG.locale or "enUS" end
G.GetRealmName = function() return W.realm end
G.GetNormalizedRealmName = function() return (gsub(W.realm, "[%s%-']", "")) end
G.GetRealmID = function() return 5 end
G.RegionalUniqueNamesEnabled = function() return true end
G.GetCurrentRegion = function() return 4 end
G.GetCurrentRegionName = function() return "OC" end
G.IsTrialAccount = function() return false end
G.IsVeteranTrialAccount = function() return false end
G.GetScreenWidth = function() return MOCK.SCREEN_W end
G.GetScreenHeight = function() return MOCK.SCREEN_H end
G.GetPhysicalScreenSize = function() return MOCK.SCREEN_W, MOCK.SCREEN_H end
G.GetFramerate = function() return 60 end
G.GetNetStats = function() return 0, 0, 40, 40 end

G.Ambiguate = function(name, context)
    if isSecret(name) then
        local r = G.Ambiguate(MOCK.Unwrap(name), context)
        return MOCK.Secret(r)
    end
    needString(name, "Ambiguate", 1)
    needString(context, "Ambiguate", 2)
    local n, realm = match(name, "^([^%-]+)%-(.+)$")
    if not n then return name end
    if context == "short" then return n end
    local mine = gsub(W.realm, "[%s%-']", "")
    if realm == W.realm or realm == mine then return n end
    return name
end

G.GetCursorPosition = function() return MOCK.cursorX, MOCK.cursorY end
G.GetMouseFoci = function() if MOCK.hoverObject then return { MOCK.hoverObject } end return { rawget(_G, "WorldFrame") } end
G.IsMouseButtonDown = function() return false end
G.IsShiftKeyDown = function() return state.mods.shift == true end
G.IsControlKeyDown = function() return state.mods.ctrl == true end
G.IsAltKeyDown = function() return state.mods.alt == true end
G.IsLeftShiftKeyDown, G.IsRightShiftKeyDown = G.IsShiftKeyDown, function() return false end
G.IsModifierKeyDown = function() return state.mods.shift or state.mods.ctrl or state.mods.alt or false end
local MODCLICK = { CHATLINK = "shift", DRESSUP = "ctrl", SPLITSTACK = "shift", PICKUPACTION = "shift",
    STICKYCAMERA = "ctrl", COMPAREITEMS = "shift", SOCKETITEM = "shift", EXPANDITEM = "alt", OPENALLBAGS = "shift" }
G.IsModifiedClick = function(action)
    if action == nil then return G.IsModifierKeyDown() end
    needString(action, "IsModifiedClick", 1)
    local m = MODCLICK[action]
    if not m then return false end
    return state.mods[m] == true
end
G.GetCurrentKeyBoardFocus = function() return MOCK.focus end
G.GetBindingKey = function() return nil end
G.GetBindingText = function(k) return k or "" end

-- sounds
local SOUND_CHANNELS = { Master = true, SFX = true, Music = true, Ambience = true, Dialog = true, ["Talking Head"] = true }
G.PlaySound = function(kit, channel, noDup, runCallback)
    if not isNum(kit) then
        error("bad argument #1 to 'PlaySound' (Usage: local willPlay, soundHandle = PlaySound(soundKitID [, channel, forceNoDuplicates, runFinishCallback]))", 2)
    end
    if channel ~= nil and (type(channel) ~= "string" or not SOUND_CHANNELS[channel]) then
        MOCK.Warn("sound", "PlaySound: unknown channel '" .. tostring(channel) .. "'", 2)
    end
    MOCK.sounds[kit] = (MOCK.sounds[kit] or 0) + 1
    return true, #MOCK.sounds + 1
end
G.PlaySoundFile = function(file, channel)
    if type(file) ~= "string" and not isNum(file) then
        error("bad argument #1 to 'PlaySoundFile' (Usage: local willPlay, soundHandle = PlaySoundFile(soundFile [, channel]))", 2)
    end
    MOCK.sounds[tostring(file)] = (MOCK.sounds[tostring(file)] or 0) + 1
    return true, 1
end
G.StopSound = function() end
G.PlayMusic = function() end
G.StopMusic = function() end

-- input stubs that addons hook (hooksecurefunc needs real functions to wrap)
G.DoEmote = function(token, unit)
    if type(token) ~= "string" then error("Usage: DoEmote(\"token\"[, \"unit\"])", 2) end
    MOCK.requests[#MOCK.requests + 1] = { kind = "emote", token = token }
end
G.JumpOrAscendStart = function() if not MOCK.hw then MOCK.NoteForbidden("JumpOrAscendStart without a hardware event", 2) end end
G.AscendStop = function() end
G.ToggleFrame = function(f) if S[f] then if f:IsShown() then f:Hide() else f:Show() end end end

-------------------------------------------------------------------------------
-- Units
-------------------------------------------------------------------------------
G.UnitName = function(unit)
    unitCheck(unit, "UnitName")
    local rec, _, self = resolve(unit)
    if not rec then return nil end
    local name = rec.name
    if rec.realm and rec.realm ~= W.realm then
        return secretFor("names", self, name), secretFor("names", self, rec.realm)
    end
    return secretFor("names", self, name), nil
end
G.UnitNameUnmodified = G.UnitName
G.GetUnitName = function(unit, showServer)
    unitCheck(unit, "GetUnitName")
    local rec, _, self = resolve(unit)
    if not rec then return nil end
    local n = rec.name
    if showServer and rec.realm and rec.realm ~= W.realm then n = n .. "-" .. rec.realm end
    return secretFor("names", self, n)
end
G.UnitFullName = function(unit)
    unitCheck(unit, "UnitFullName")
    local rec, _, self = resolve(unit)
    if not rec then return nil end
    -- Forever: the second return is a surname (or nil), not a realm (FACTS 0.2.8)
    return secretFor("names", self, rec.name), rec.surname
end
G.UnitGUID = function(unit)
    unitCheck(unit, "UnitGUID")
    local rec, _, self = resolve(unit)
    if not rec then return nil end
    return secretFor("guids", self, rec.guid)
end
G.UnitClass = function(unit)
    unitCheck(unit, "UnitClass")
    local rec, _, self = resolve(unit)
    if not rec then return nil end
    local cd = MOCK.CLASS_DATA[rec.class] or MOCK.CLASS_DATA.WARRIOR
    return secretFor("names", self, cd.name), secretFor("names", self, cd.file), secretFor("names", self, cd.id)
end
G.UnitClassBase = function(unit)
    local _, file, id = G.UnitClass(unit)
    return file, id
end
G.UnitLevel = function(unit)
    unitCheck(unit, "UnitLevel")
    local rec, e, self = resolve(unit)
    if not rec then return 0 end
    return self and (ME.level or 60) or (e and e.level or rec.level or 60)
end
G.UnitEffectiveLevel = G.UnitLevel
G.UnitRace = function(unit)
    unitCheck(unit, "UnitRace")
    local rec, _, self = resolve(unit)
    if not rec then return nil end
    local r = RACES[rec.race] or { rec.race, 0 }
    return secretFor("names", self, r[1]), secretFor("names", self, rec.race), r[2]
end
G.UnitFactionGroup = function(unit)
    unitCheck(unit, "UnitFactionGroup")
    local rec = resolve(unit)
    if not rec then return nil end
    return rec.faction or "Alliance", rec.faction or "Alliance"
end
G.UnitSex = function(unit)
    unitCheck(unit, "UnitSex")
    local rec = resolve(unit)
    return rec and rec.sex or 1
end
G.UnitExists = function(unit)
    unitCheck(unit, "UnitExists")
    return resolve(unit) ~= nil
end
G.UnitIsPlayer = function(unit)
    unitCheck(unit, "UnitIsPlayer")
    return resolve(unit) ~= nil
end
G.UnitPlayerControlled = G.UnitIsPlayer
G.UnitIsConnected = function(unit)
    unitCheck(unit, "UnitIsConnected")
    local rec, e, self = resolve(unit)
    if not rec then return false end
    if self then return true end
    if e then return e.online ~= false end
    return true
end
G.UnitIsDeadOrGhost = function(unit)
    unitCheck(unit, "UnitIsDeadOrGhost")
    local rec, e, self = resolve(unit)
    if not rec then return false end
    if self then return state.dead or state.ghost end
    return e and (e.dead or e.ghost) and true or false
end
G.UnitIsDead = function(unit)
    unitCheck(unit, "UnitIsDead")
    local rec, e, self = resolve(unit)
    if not rec then return false end
    if self then return state.dead and not state.ghost end
    return e and e.dead and true or false
end
G.UnitIsGhost = function(unit)
    unitCheck(unit, "UnitIsGhost")
    local rec, e, self = resolve(unit)
    if not rec then return false end
    if self then return state.ghost end
    return e and e.ghost and true or false
end
G.UnitIsAFK = function(unit)
    unitCheck(unit, "UnitIsAFK")
    local rec, e, self = resolve(unit)
    if not rec then return false end
    if self then return state.afk end
    return e and e.afk and true or false
end
G.UnitIsDND = function(unit)
    unitCheck(unit, "UnitIsDND")
    local _, e, self = resolve(unit)
    if self then return state.dnd end
    return e and e.dnd and true or false
end
G.UnitOnTaxi = function(unit)
    unitCheck(unit, "UnitOnTaxi")
    local _, _, self = resolve(unit)
    return self and state.taxi or false
end
G.UnitIsVisible = function(unit)
    unitCheck(unit, "UnitIsVisible")
    local rec, e, self = resolve(unit)
    if not rec then return false end
    if self then return true end
    return e == nil or e.online ~= false
end
G.UnitInRange = function(unit)
    unitCheck(unit, "UnitInRange")
    local rec = resolve(unit)
    return rec ~= nil, rec ~= nil
end
G.UnitIsUnit = function(a, b)
    unitCheck(a, "UnitIsUnit")
    if type(b) ~= "string" then error("bad argument #2 to 'UnitIsUnit' (Usage: UnitIsUnit(unit, otherUnit))", 2) end
    local ra, _, sa = resolve(a)
    local rb, _, sb = resolve(b)
    local r = ra ~= nil and rb ~= nil and ra.name == rb.name
    if sa and sb then return r end
    return MaybeSecret("names", r)
end
G.UnitIsFriend = function() return true end
G.UnitIsEnemy = function() return false end
G.UnitCanAttack = function() return false end
G.UnitAffectingCombat = function(unit)
    unitCheck(unit, "UnitAffectingCombat")
    local rec = resolve(unit)
    return rec ~= nil and state.combat
end
G.UnitHealth = function(unit) unitCheck(unit, "UnitHealth") local rec, e, s = resolve(unit) if not rec then return 0 end if (s and state.dead) or (e and e.dead) then return 0 end return 5000 end
G.UnitHealthMax = function(unit) unitCheck(unit, "UnitHealthMax") return resolve(unit) and 5000 or 0 end
G.UnitPower = function(unit) unitCheck(unit, "UnitPower") return resolve(unit) and 3000 or 0 end
G.UnitPowerMax = function(unit) unitCheck(unit, "UnitPowerMax") return resolve(unit) and 3000 or 0 end
G.UnitInRaid = function(unit)
    unitCheck(unit, "UnitInRaid")
    local g = state.group
    if not (g and g.kind == "raid") then return nil end
    local rec = resolve(unit)
    if not rec then return nil end
    for i, e in ipairs(g.members) do if e.name == rec.name then return i end end
    return nil
end
G.UnitInParty = function(unit)
    unitCheck(unit, "UnitInParty")
    if not state.group then return false end
    local rec, e = resolve(unit)
    return rec ~= nil and e ~= nil
end
G.UnitIsGroupLeader = function(unit, category)
    unitCheck(unit, "UnitIsGroupLeader")
    local rec, e = resolve(unit)
    return rec ~= nil and e ~= nil and e.rank == 2
end
G.UnitIsGroupAssistant = function(unit, category)
    unitCheck(unit, "UnitIsGroupAssistant")
    local rec, e = resolve(unit)
    return rec ~= nil and e ~= nil and e.rank == 1 and state.group ~= nil and state.group.kind == "raid"
end
G.UnitGroupRolesAssigned = function(unit)
    unitCheck(unit, "UnitGroupRolesAssigned")
    local _, e = resolve(unit)
    return (e and e.combatRole) or "NONE"
end
G.UnitIsInMyGuild = function(unit)
    unitCheck(unit, "UnitIsInMyGuild")
    local rec = resolve(unit)
    return rec ~= nil and guildByName[rec.name] ~= nil
end
G.GetPlayerInfoByGUID = function(guid)
    if type(guid) ~= "string" then argErr("GetPlayerInfoByGUID", 1, "string", guid) end
    if isSecret(guid) then return nil end
    for _, p in ipairs(W.players) do
        if p.guid == guid then
            local cd = MOCK.CLASS_DATA[p.class] or MOCK.CLASS_DATA.WARRIOR
            local r = RACES[p.race] or { p.race }
            return cd.name, cd.file, r[1], p.race, p.sex or 2, p.name, p.realm ~= W.realm and p.realm or ""
        end
    end
    return nil
end
G.C_ClassColor = {
    GetClassColor = function(classFile)
        if type(classFile) ~= "string" then argErr("GetClassColor", 1, "string", classFile) end
        return G.RAID_CLASS_COLORS[classFile]
    end,
}
G.C_CreatureInfo = {
    GetCreatureID = function(guid)
        if type(guid) ~= "string" then argErr("GetCreatureID", 1, "string", guid) end
        local id = match(guid, "^Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
        return id and tonumber(id) or nil
    end,
}

-------------------------------------------------------------------------------
-- Group & raid
-------------------------------------------------------------------------------
local function checkCategory(cat, fname)
    if cat ~= nil and not isNum(cat) then argErr(fname, 1, "number", cat, 3) end
end
local function groupMatches(cat)
    local g = state.group
    if not g then return false end
    if cat == nil then return true end
    return (g.category or 1) == cat
end
G.IsInGroup = function(cat) checkCategory(cat, "IsInGroup") return groupMatches(cat) end
G.IsInRaid = function(cat)
    checkCategory(cat, "IsInRaid")
    return groupMatches(cat) and state.group.kind == "raid"
end
G.GetNumGroupMembers = function(cat)
    checkCategory(cat, "GetNumGroupMembers")
    if not groupMatches(cat) then return 0 end
    return #state.group.members
end
G.GetNumSubgroupMembers = function(cat)
    checkCategory(cat, "GetNumSubgroupMembers")
    if not groupMatches(cat) then return 0 end
    return #partyList()
end
G.IsInInstance = function()
    local i = state.instance
    if i then return true, i.type end
    return false, "none"
end
G.GetRaidRosterInfo = function(i)
    if not isNum(i) then argErr("GetRaidRosterInfo", 1, "number", i) end
    local g = state.group
    if not (g and g.kind == "raid") then return nil end
    local e = g.members[i]
    if not e then return nil end
    local rec = memberRec(e)
    local cd = MOCK.CLASS_DATA[rec.class] or MOCK.CLASS_DATA.WARRIOR
    local name = rec.name
    if rec.realm and rec.realm ~= W.realm then name = name .. "-" .. rec.realm end
    local isSelf = rec.name == MYNAME
    local dead = isSelf and (state.dead or state.ghost) or (e.dead or e.ghost) or false
    return MaybeSecret("roster", name), e.rank or 0, e.subgroup or 1, (isSelf and ME.level) or e.level or rec.level or 60,
        MaybeSecret("roster", cd.name), MaybeSecret("roster", cd.file), MaybeSecret("roster", e.zone or state.zone),
        isSelf or e.online ~= false, dead and true or false, e.role, e.isML and true or false, e.combatRole or "NONE"
end
G.GetReadyCheckStatus = function(unit)
    unitCheck(unit, "GetReadyCheckStatus")
    local rc = state.readyCheck
    local rec = resolve(unit)
    if not (rc and rec) then return nil end
    return rc[rec.name] or "waiting"
end
G.GetReadyCheckTimeLeft = function() return state.readyCheck and 20 or 0 end
G.DoReadyCheck = function()
    local e = groupEntry(MYNAME)
    if not (state.group and e and (e.rank or 0) >= 1) then return end
    MOCK.requests[#MOCK.requests + 1] = { kind = "readycheck" }
end
G.ConfirmReadyCheck = function(isReady)
    MOCK.requests[#MOCK.requests + 1] = { kind = "readyconfirm", ready = isReady and true or false }
end

local function requireLead(fname)
    local e = groupEntry(MYNAME)
    if not (state.group and e and (e.rank or 0) >= 1) then
        later(0, function() Game.SystemMessage(G.ERR_NOT_LEADER or "You are not the party leader.") end)
        return false
    end
    return true
end
G.SetRaidSubgroup = function(index, subgroup)
    if not isNum(index) then argErr("SetRaidSubgroup", 1, "number", index) end
    if not isNum(subgroup) then argErr("SetRaidSubgroup", 2, "number", subgroup) end
    if not (state.group and state.group.kind == "raid") then return end
    if not requireLead("SetRaidSubgroup") then return end
    if subgroup < 1 or subgroup > 8 then return end
    MOCK.requests[#MOCK.requests + 1] = { kind = "subgroup", index = index, subgroup = subgroup }
end
G.SwapRaidSubgroup = function(a, b)
    if not isNum(a) then argErr("SwapRaidSubgroup", 1, "number", a) end
    if not isNum(b) then argErr("SwapRaidSubgroup", 2, "number", b) end
    if not (state.group and state.group.kind == "raid") then return end
    if not requireLead("SwapRaidSubgroup") then return end
    MOCK.requests[#MOCK.requests + 1] = { kind = "swap", a = a, b = b }
end
G.PromoteToAssistant = function(unit) unitCheck(unit, "PromoteToAssistant") if requireLead() then MOCK.requests[#MOCK.requests + 1] = { kind = "assist", unit = unit } end end
G.PromoteToLeader = function(unit) unitCheck(unit, "PromoteToLeader") if requireLead() then MOCK.requests[#MOCK.requests + 1] = { kind = "lead", unit = unit } end end
G.RandomRoll = function(lo, hi)
    lo = tonumber(lo) or 1
    hi = tonumber(hi) or 100
    if lo > hi then lo, hi = hi, lo end
    local r = MOCK.random(floor(lo), floor(hi))
    MOCK.requests[#MOCK.requests + 1] = { kind = "roll", name = MYNAME, roll = r, lo = floor(lo), hi = floor(hi) }
end
G.C_PartyInfo = {
    InviteUnit = function(name)
        needString(name, "InviteUnit", 1)
        local e = groupEntry(MYNAME)
        if state.group and e and (e.rank or 0) < 1 then return end
        MOCK.requests[#MOCK.requests + 1] = { kind = "invite", target = name }
        later(0, function() Game.SystemMessage(format(G.ERR_INVITE_PLAYER_S, stripRealm(name))) end)
    end,
    UninviteUnit = function(name)
        needString(name, "UninviteUnit", 1)
        if requireLead() then MOCK.requests[#MOCK.requests + 1] = { kind = "uninvite", target = name } end
    end,
    ConvertToRaid = function()
        local g = state.group
        if not g or g.kind == "raid" then return end
        local e = groupEntry(MYNAME)
        if not (e and e.rank == 2) then return end
        MOCK.requests[#MOCK.requests + 1] = { kind = "convert" }
    end,
    ConvertToParty = function() MOCK.requests[#MOCK.requests + 1] = { kind = "convertparty" } end,
    LeaveParty = function() MOCK.requests[#MOCK.requests + 1] = { kind = "leave" } end,
    CanInvite = function()
        local e = groupEntry(MYNAME)
        return not state.group or (e ~= nil and (e.rank or 0) >= 1)
    end,
    IsPartyFull = function() local g = state.group return g ~= nil and #g.members >= ((g.kind == "raid") and 40 or 5) end,
    GetLootMethod = function()
        if not state.group then return G.Enum.LootMethod.Freeforall end
        return state.group.lootMethod or G.Enum.LootMethod.Group, nil, nil
    end,
    GetMinLevel = function() return 1 end,
}

-------------------------------------------------------------------------------
-- Instances & zones
-------------------------------------------------------------------------------
G.GetInstanceInfo = function()
    local i = state.instance
    if i then
        return i.name, i.type, i.difficultyID or 0, i.difficultyName or "", i.maxPlayers or 0, 0, false,
            i.instanceID or 0, i.groupSize or i.maxPlayers or 0, nil
    end
    local cont = CFG.continent or "Eastern Kingdoms"
    return cont, "none", 0, "", 0, 0, false, CFG.continentID or 0, 0, nil
end
G.GetZoneText = function() return state.zone end
G.GetRealZoneText = function() return state.zone end
G.GetSubZoneText = function() return state.subzone end
G.GetMinimapZoneText = function() return state.subzone ~= "" and state.subzone or state.zone end
G.GetZonePVPInfo = function() return "friendly", nil, nil end
G.IsResting = function() return state.instance == nil and (state.zone == "Stormwind City" or state.zone == "Ironforge") end
G.IsIndoors = function() return state.instance ~= nil end
G.IsOutdoors = function() return state.instance == nil end
G.IsFalling = function() return state.falling end
G.IsFlying = function() return false end
G.IsSwimming = function() return state.swimming == true end
G.IsMounted = function() return false end
G.IsStealthed = function() return false end
G.GetUnitSpeed = function() return 0, 7, 7, 4.72 end
G.HasFullControl = function() return not state.taxi end

-------------------------------------------------------------------------------
-- Combat / lockdown
-------------------------------------------------------------------------------
G.InCombatLockdown = function() return state.combat end
G.C_ChatInfo = {}       -- filled below
G.C_RestrictedActions.IsAddOnRestrictionActive = function(kind)
    local E = G.Enum.AddOnRestrictionType
    if kind == E.Chat then return state.chatLockdown == true end
    if kind == E.Combat then return state.combat == true end
    if kind == E.Encounter then return state.encounter ~= nil end
    if kind == E.Map then return state.instance ~= nil and state.encounter ~= nil end
    return false
end

-------------------------------------------------------------------------------
-- Guild API
-------------------------------------------------------------------------------
G.IsInGuild = function() return guild ~= nil end
G.GetGuildInfo = function(unit)
    unitCheck(unit, "GetGuildInfo")
    if not guild or not state.guildLoaded then return nil end
    local rec, _, self = resolve(unit)
    if not rec then return nil end
    local m = guildByName[rec.name]
    if not m then return nil end
    return guild.name, guild.ranks[(m.rankIndex or 0) + 1] or "Member", m.rankIndex or 0, nil
end
G.GetNumGuildMembers = function()
    if not guild or not state.guildLoaded then return 0, 0, 0 end
    local online, mobile = 0, 0
    for _, m in ipairs(guild.members) do
        if m.online then online = online + 1 elseif m.mobile then mobile = mobile + 1 end
    end
    return #guild.members, online, online + mobile
end
local GUILD_ZONE_OFFLINE = nil
G.GetGuildRosterInfo = function(i)
    if not isNum(i) then argErr("GetGuildRosterInfo", 1, "number", i) end
    if not guild or not state.guildLoaded then return nil end
    local m = guild.members[i]
    if not m then return nil end
    local rec = W.byName[m.name] or { name = m.name, realm = W.realm, class = m.class or "WARRIOR", level = m.level or 60, guid = m.guid }
    local cd = MOCK.CLASS_DATA[rec.class] or MOCK.CLASS_DATA.WARRIOR
    local status = (m.afk and 1) or (m.dnd and 2) or 0
    local zone = m.online and (m.zone or "Stormwind City") or GUILD_ZONE_OFFLINE
    return MaybeSecret("roster", fullName(rec)), guild.ranks[(m.rankIndex or 0) + 1] or "Member", m.rankIndex or 0,
        rec.level or 60, cd.name, MaybeSecret("roster", zone), MaybeSecret("roster", m.note or ""),
        MaybeSecret("roster", m.officerNote or ""), m.online and true or false, status, cd.file,
        m.ap or 0, i, m.mobile and not m.online or false, false, 5, MaybeSecret("roster", rec.guid)
end
G.C_GuildInfo = {
    GuildRoster = function()
        if not guild then return end
        local now = MOCK.uptime
        if now - state.lastRosterRequest < 10 then return end   -- server throttle
        state.lastRosterRequest = now
        later(0, function()            -- the server answers on the next tick
            state.guildLoaded = true
            fire("GUILD_ROSTER_UPDATE", true)
        end)
    end,
    IsGuildOfficer = nil,   -- UNKNOWN on Forever (FACTS A.11): deliberately absent
    GetGuildTabardInfo = function() return nil end,
}

-------------------------------------------------------------------------------
-- Professions & spellbook
-------------------------------------------------------------------------------
local PROF_SLOTS = { "prof1", "prof2", "firstAid", "fishing", "cooking" }
local profByIndex = {}
do
    local idx = 0
    for _, slot in ipairs(PROF_SLOTS) do
        local p = CFG.professions and CFG.professions[slot]
        if p then
            idx = idx + 1          -- spellbook skill-line index (any small integer on the client)
            profByIndex[idx] = p
            p.slotIndex = idx
        end
    end
end
G.GetProfessions = function()
    local out = {}
    local n = 0
    for _, slot in ipairs(PROF_SLOTS) do
        n = n + 1
        local p = CFG.professions and CFG.professions[slot]
        out[n] = p and p.slotIndex or nil
    end
    return out[1], out[2], out[3], out[4], out[5]
end
G.GetProfessionInfo = function(index)
    if not isNum(index) then argErr("GetProfessionInfo", 1, "number", index) end
    local p = profByIndex[index]
    if not p then return nil end
    return p.name, p.icon or 136240, p.rank or 1, p.max or 300, p.numSpells or 1, p.spellOffset or 0, p.skillLine,
        p.modifier or 0, 0, 0, p.name
end

local known = {}
for _, id in ipairs(CFG.known or {}) do known[id] = true end
MOCK.knownSpells = known
local function isKnown(id) return known[id] == true end
G.IsPlayerSpell = function(id)
    if not isNum(id) then argErr("IsPlayerSpell", 1, "number", id) end
    return isKnown(id)
end
G.IsSpellKnown = function(id, isPet)
    if not isNum(id) then argErr("IsSpellKnown", 1, "number", id) end
    if isPet then return false end
    return isKnown(id)
end
G.IsSpellKnownOrOverridesKnown = G.IsSpellKnown
G.C_SpellBook = {
    IsSpellKnown = function(id, bank)
        if not isNum(id) then argErr("IsSpellKnown", 1, "number", id) end
        return isKnown(id)
    end,
    IsSpellInSpellBook = function(id) if not isNum(id) then argErr("IsSpellInSpellBook", 1, "number", id) end return isKnown(id) end,
    GetSpellBookItemName = function() return nil end,
    GetNumSpellBookSkillLines = function() return 2 end,
}

-------------------------------------------------------------------------------
-- C_Spell
-------------------------------------------------------------------------------
local function spellArg(v, fname)
    if isNum(v) then return MOCK.SpellRecord(v), v end
    if type(v) == "string" and not isSecret(v) then
        local id = tonumber(match(v, "spell:(%d+)") or "")
        if id then return MOCK.SpellRecord(id), id end
        for sid, s in pairs(MOCK.spells) do if s.name == v and not s.generic then return s, sid end end
        return nil
    end
    error(format("bad argument #1 to '%s' (Usage: %s(spellIdentifier))", fname, fname), 3)
end
G.C_Spell = {
    GetSpellName = function(id) local s = spellArg(id, "GetSpellName") return s and s.name or nil end,
    GetSpellTexture = function(id) local s = spellArg(id, "GetSpellTexture") if not s then return nil end return s.icon, s.icon end,
    GetSpellInfo = function(id)
        local s, sid = spellArg(id, "GetSpellInfo")
        if not s then return nil end
        return { name = s.name, iconID = s.icon, originalIconID = s.icon, castTime = s.castTime or 0,
                 minRange = 0, maxRange = 0, spellID = sid }
    end,
    GetSpellLink = function(id)
        local s, sid = spellArg(id, "GetSpellLink")
        if not s then return nil end
        return format("|cff71d5ff|Hspell:%d:0|h[%s]|h|r", sid, s.name)
    end,
    GetSpellDescription = function(id) local s = spellArg(id, "GetSpellDescription") return s and ("Mock description of " .. s.name) or nil end,
    DoesSpellExist = function(id) return spellArg(id, "DoesSpellExist") ~= nil end,
    IsSpellUsable = function(id) local _, sid = spellArg(id, "IsSpellUsable") return sid ~= nil and isKnown(sid), false end,
    GetSpellCooldown = function(id)
        local s, sid = spellArg(id, "GetSpellCooldown")
        if not s then return nil end
        local cd = state.spellCD[sid]
        local start, dur = 0, 0
        if cd and MOCK.uptime < cd.start + cd.dur then start, dur = cd.start, cd.dur end
        local secret = state.combat and MOCK.secretOn.spell
        local function m(v) if secret then return MOCK.Secret(v) end return v end
        return { startTime = m(start), duration = m(dur), isEnabled = m(true), modRate = m(1) }
    end,
    GetSpellCharges = function() return nil end,
    GetSpellPowerCost = function() return {} end,
    IsSpellPassive = function() return false end,
    RequestLoadSpellData = function(id) later(0.05, function() fire("SPELL_DATA_LOAD_RESULT", id, MOCK.SpellRecord(id) ~= nil) end) end,
}

-------------------------------------------------------------------------------
-- Items, bags, item cache
-------------------------------------------------------------------------------
local itemCache = {}
local pendingItems = {}
MOCK.itemCache = itemCache
for _, id in ipairs(CFG.cachedItems or {}) do itemCache[id] = true end

local bags = {}
MOCK.bags = bags
local BAG_SLOTS = { [0] = 16, 14, 14, 14, 14 }
for b = 0, 4 do bags[b] = {} end
for b, list in pairs(CFG.bags or {}) do
    local bag = tonumber(b)
    if bag and bags[bag] then
        for i, e in ipairs(list) do
            bags[bag][i] = { id = e[1] or e.id, count = e[2] or e.count or 1 }
            itemCache[bags[bag][i].id] = true
        end
    end
end

function MOCK.AddItem(id, name, quality, ilvl, minLevel, itype, subType, stack, equipLoc, icon, sell, classID, subclassID, bind, spell)
    MOCK.items[id] = { name = name, quality = quality or 1, ilvl = ilvl or 1, minLevel = minLevel or 0, type = itype or "Miscellaneous",
        subType = subType or "Other", stack = stack or 1, equipLoc = equipLoc or "", icon = icon or 134400, sell = sell or 0,
        classID = classID or 15, subclassID = subclassID or 0, bind = bind or 0, spell = spell }
end

local function itemLink(id, rec)
    local q = MOCK.QUALITY[rec.quality] or MOCK.QUALITY[1]
    return format("|c%s|Hitem:%d::::::::%d:::::::::|h[%s]|h|r", q[4], id, ME.level or 60, rec.name)
end
MOCK.ItemLink = function(id) local rec = MOCK.ItemRecord(id) return rec and itemLink(id, rec) or nil end

local function requestItem(id)
    if itemCache[id] or pendingItems[id] then return end
    pendingItems[id] = true
    later(0.15, function()
        pendingItems[id] = nil
        local rec = MOCK.ItemRecord(id)
        itemCache[id] = true
        fire("ITEM_DATA_LOAD_RESULT", id, rec ~= nil)
        fire("GET_ITEM_INFO_RECEIVED", id, rec ~= nil)
    end)
end

--- item argument -> itemID or nil (name lookups only hit cached items, as on the client)
local function itemArg(item, fname)
    if isNum(item) then return floor(item) end
    if type(item) == "string" and not isSecret(item) then
        local id = match(item, "item:(%-?%d+)")
        if id then return tonumber(id) end
        if match(item, "^%d+$") then return tonumber(item) end
        for iid in pairs(itemCache) do
            local rec = MOCK.items[iid]
            if rec and rec.name == item then return iid end
        end
        return nil
    end
    error(format("bad argument #1 to '%s' (Usage: %s(itemInfo))", fname, fname), 3)
end

local function bagCount(id)
    local n = 0
    for b = 0, 4 do
        for _, e in pairs(bags[b]) do if e and e.id == id then n = n + e.count end end
    end
    return n
end

G.C_Item = {
    GetItemInfo = function(item)
        local id = itemArg(item, "GetItemInfo")
        if not id then return nil end
        local rec = MOCK.ItemRecord(id)
        if not rec then return nil end
        if not itemCache[id] then requestItem(id) return nil end
        return rec.name, itemLink(id, rec), rec.quality, rec.ilvl, rec.minLevel, rec.type, rec.subType, rec.stack,
            rec.equipLoc, rec.icon, rec.sell, rec.classID, rec.subclassID, rec.bind, 0, nil, rec.classID == 7
    end,
    GetItemInfoInstant = function(item)
        local id = itemArg(item, "GetItemInfoInstant")
        if not id then return nil end
        local rec = MOCK.ItemRecord(id)
        if not rec then return nil end
        return id, rec.type, rec.subType, rec.equipLoc, rec.icon, rec.classID, rec.subclassID
    end,
    GetItemNameByID = function(item)
        local id = itemArg(item, "GetItemNameByID")
        local rec = id and MOCK.ItemRecord(id)
        if not rec then return nil end
        if not itemCache[id] then requestItem(id) return nil end
        return rec.name
    end,
    GetItemIconByID = function(item)
        local id = itemArg(item, "GetItemIconByID")
        local rec = id and MOCK.ItemRecord(id)
        return rec and rec.icon or nil
    end,
    GetItemQualityByID = function(item)
        local id = itemArg(item, "GetItemQualityByID")
        local rec = id and MOCK.ItemRecord(id)
        if not rec or not itemCache[id] then return nil end
        return rec.quality
    end,
    GetItemCount = function(item, includeBank, includeUses, includeReagentBank)
        local id = itemArg(item, "GetItemCount")
        if not id then return 0 end
        return bagCount(id)
    end,
    GetItemSpell = function(item)
        local id = itemArg(item, "GetItemSpell")
        local rec = id and MOCK.ItemRecord(id)
        if not rec or not rec.spell then return nil end
        local s = MOCK.SpellRecord(rec.spell)
        return s and s.name, rec.spell
    end,
    GetItemCooldown = function(item)
        local id = itemArg(item, "GetItemCooldown")
        local cd = id and state.itemCD[id]
        if cd and MOCK.uptime < cd.start + cd.dur then return cd.start, cd.dur, true end
        return 0, 0, true
    end,
    RequestLoadItemDataByID = function(item)
        local id = itemArg(item, "RequestLoadItemDataByID")
        if not id then return end
        if itemCache[id] then
            later(0, function() fire("ITEM_DATA_LOAD_RESULT", id, true) end)
        else
            requestItem(id)
        end
    end,
    IsItemDataCachedByID = function(item)
        local id = itemArg(item, "IsItemDataCachedByID")
        return id ~= nil and itemCache[id] == true
    end,
    DoesItemExistByID = function(item)
        local id = itemArg(item, "DoesItemExistByID")
        return id ~= nil and MOCK.ItemRecord(id) ~= nil
    end,
    GetItemQualityColor = function(q)
        if not isNum(q) then argErr("GetItemQualityColor", 1, "number", q) end
        local c = MOCK.QUALITY[q]
        if not c then return 1, 1, 1, "ffffffff" end
        return c[1], c[2], c[3], c[4]
    end,
    GetItemClassInfo = function(classID) return ({ [0] = "Consumable", [2] = "Weapon", [4] = "Armor", [7] = "Tradeskill", [15] = "Miscellaneous" })[classID] end,
    IsEquippableItem = function(item) local id = itemArg(item, "IsEquippableItem") local rec = id and MOCK.ItemRecord(id) return rec ~= nil and rec.equipLoc ~= "" end,
}

G.C_Container = {
    GetContainerNumSlots = function(bag)
        if not isNum(bag) then argErr("GetContainerNumSlots", 1, "number", bag) end
        return BAG_SLOTS[bag] or 0
    end,
    GetContainerNumFreeSlots = function(bag)
        if not isNum(bag) then argErr("GetContainerNumFreeSlots", 1, "number", bag) end
        local n = BAG_SLOTS[bag] or 0
        local used = 0
        for _ in pairs(bags[bag] or {}) do used = used + 1 end
        return n - used, 0
    end,
    GetContainerItemInfo = function(bag, slot)
        if not isNum(bag) then argErr("GetContainerItemInfo", 1, "number", bag) end
        if not isNum(slot) then argErr("GetContainerItemInfo", 2, "number", slot) end
        local e = bags[bag] and bags[bag][slot]
        if not e then return nil end
        local rec = MOCK.ItemRecord(e.id) or {}
        return { iconFileID = rec.icon, stackCount = e.count, isLocked = false, quality = rec.quality,
                 isReadable = false, hasLoot = false, hyperlink = itemLink(e.id, rec), isFiltered = false,
                 hasNoValue = (rec.sell or 0) == 0, itemID = e.id, isBound = (rec.bind or 0) == 1 }
    end,
    GetContainerItemID = function(bag, slot)
        if not isNum(bag) then argErr("GetContainerItemID", 1, "number", bag) end
        if not isNum(slot) then argErr("GetContainerItemID", 2, "number", slot) end
        local e = bags[bag] and bags[bag][slot]
        return e and e.id or nil
    end,
    GetContainerItemLink = function(bag, slot)
        if not isNum(bag) then argErr("GetContainerItemLink", 1, "number", bag) end
        if not isNum(slot) then argErr("GetContainerItemLink", 2, "number", slot) end
        local e = bags[bag] and bags[bag][slot]
        return e and MOCK.ItemLink(e.id) or nil
    end,
    GetItemCooldown = function(itemID)
        if not isNum(itemID) then argErr("GetItemCooldown", 1, "number", itemID) end
        local cd = state.itemCD[itemID]
        if cd and MOCK.uptime < cd.start + cd.dur then return cd.start, cd.dur, 1 end
        return 0, 0, 1
    end,
    GetBagName = function(bag) return bag == 0 and "Backpack" or ("Bag " .. tostring(bag)) end,
}

-------------------------------------------------------------------------------
-- Auras
-------------------------------------------------------------------------------
local auraSeq = 0
local function aurasSecret() return MOCK.secretOn.auras == true or state.combat == true end
G.C_Secrets.ShouldAurasBeSecret = aurasSecret
G.C_Secrets.ShouldSpellCooldownBeSecret = function() return state.combat and MOCK.secretOn.spell == true end

local function auraList(unit)
    local rec, _, self = resolve(unit)
    if not rec then return nil end
    return state.auras[rec.name] or {}, self
end
local AURA_FIELDS = { "applications", "auraInstanceID", "duration", "expirationTime", "icon", "name", "spellId",
    "sourceUnit", "isHelpful", "isHarmful", "dispelName", "charges", "maxCharges", "isStealable", "isBossAura",
    "isFromPlayerOrPlayerPet", "isRaid", "timeMod", "canApplyAura", "nameplateShowAll", "nameplateShowPersonal" }
local function auraData(a)
    local d = {
        applications = a.applications or 0, auraInstanceID = a.auraInstanceID, duration = a.duration or 0,
        expirationTime = a.expirationTime or 0, icon = a.icon or (MOCK.SpellRecord(a.spellId) or {}).icon,
        name = a.name or (MOCK.SpellRecord(a.spellId) or {}).name, spellId = a.spellId,
        sourceUnit = a.sourceUnit, isHelpful = not a.isHarmful, isHarmful = a.isHarmful and true or false,
        dispelName = a.dispelName, charges = 0, maxCharges = 0, isStealable = false, isBossAura = false,
        isFromPlayerOrPlayerPet = a.fromPlayer and true or false, isRaid = false, timeMod = 1, canApplyAura = false,
        nameplateShowAll = false, nameplateShowPersonal = false, isNameplateOnly = false, points = {},
    }
    if aurasSecret() then
        for _, k in ipairs(AURA_FIELDS) do
            if d[k] ~= nil then d[k] = MOCK.Secret(d[k]) end
        end
    end
    return d
end
local function filterMatch(a, filter)
    filter = filter and upper(filter) or "HELPFUL"
    if find(filter, "HARMFUL", 1, true) then return a.isHarmful == true end
    return not a.isHarmful
end
local function auraByIndex(fname, unit, index, filter)
    unitCheck(unit, fname)
    if not isNum(index) then argErr(fname, 2, "number", index, 3) end
    if filter ~= nil and type(filter) ~= "string" then argErr(fname, 3, "string", filter, 3) end
    local list = auraList(unit)
    if not list then return nil end
    local n = 0
    for _, a in ipairs(list) do
        if not a.hidden and filterMatch(a, filter) then
            n = n + 1
            if n == index then return auraData(a) end
        end
    end
    return nil
end
G.C_UnitAuras = {
    GetBuffDataByIndex = function(unit, index, filter)
        return auraByIndex("GetBuffDataByIndex", unit, index, filter and ("HELPFUL|" .. filter) or "HELPFUL")
    end,
    GetDebuffDataByIndex = function(unit, index, filter)
        return auraByIndex("GetDebuffDataByIndex", unit, index, "HARMFUL")
    end,
    GetAuraDataByIndex = function(unit, index, filter)
        return auraByIndex("GetAuraDataByIndex", unit, index, filter)
    end,
    GetPlayerAuraBySpellID = function(spellID)
        if not isNum(spellID) then argErr("GetPlayerAuraBySpellID", 1, "number", spellID) end
        for _, a in ipairs(state.auras[MYNAME] or {}) do
            if a.spellId == spellID then return auraData(a) end
        end
        return nil
    end,
    GetAuraDataBySpellName = function(unit, name, filter)
        unitCheck(unit, "GetAuraDataBySpellName")
        needString(name, "GetAuraDataBySpellName", 2)
        for _, a in ipairs(auraList(unit) or {}) do
            local an = a.name or (MOCK.SpellRecord(a.spellId) or {}).name
            if an == name and filterMatch(a, filter) then return auraData(a) end
        end
        return nil
    end,
    GetAuraDataByAuraInstanceID = function(unit, id)
        unitCheck(unit, "GetAuraDataByAuraInstanceID")
        if not isNum(id) then argErr("GetAuraDataByAuraInstanceID", 2, "number", id) end
        for _, a in ipairs(auraList(unit) or {}) do if a.auraInstanceID == id then return auraData(a) end end
        return nil
    end,
    GetUnitAuras = function(unit, filter, maxCount)
        unitCheck(unit, "GetUnitAuras")
        if type(filter) ~= "string" then argErr("GetUnitAuras", 2, "string", filter) end
        local out = {}
        for _, a in ipairs(auraList(unit) or {}) do
            if not a.hidden and filterMatch(a, filter) then
                out[#out + 1] = auraData(a)
                if maxCount and #out >= maxCount then break end
            end
        end
        return out
    end,
    IsAuraFilteredOutByInstanceID = function() return false end,
}

-------------------------------------------------------------------------------
-- Trade skill window
-------------------------------------------------------------------------------
-- state.tradeskill = { open, ready, skillLine, child, name, rank, max, recipes = { {recipeID, name,
--                      learned, item, difficulty, skillUps, categoryID} }, byID = {} }
local function ts() return state.tradeskill end
local function tsOpen() local t = ts() return t ~= nil and t.open end
local function profInfo(line, child)
    local t = ts()
    local open = t and t.open
    if not open then
        return { professionID = 0, professionName = "", expansionName = "", skillLevel = 0, maxSkillLevel = 0,
                 skillModifier = 0, isPrimaryProfession = false, parentProfessionID = nil, parentProfessionName = nil,
                 sourceCounter = 0, profession = nil }
    end
    if child then
        return { professionID = t.child or t.skillLine, professionName = t.name, expansionName = "Classic",
                 skillLevel = t.rank, maxSkillLevel = t.max, skillModifier = 0, isPrimaryProfession = true,
                 parentProfessionID = t.skillLine, parentProfessionName = t.name, sourceCounter = 1 }
    end
    return { professionID = t.skillLine, professionName = t.name, expansionName = "", skillLevel = t.rank,
             maxSkillLevel = t.max, skillModifier = 0, isPrimaryProfession = true, parentProfessionID = nil,
             parentProfessionName = nil, sourceCounter = 1 }
end
G.C_TradeSkillUI = {
    IsTradeSkillReady = function() local t = ts() return t ~= nil and t.open and t.ready end,
    IsTradeSkillLinked = function() local t = ts() return t ~= nil and t.open and t.linked == true end,
    IsTradeSkillGuild = function() local t = ts() return t ~= nil and t.open and t.guild == true end,
    IsNPCCrafting = function() return false end,
    IsDataSourceChanging = function() return false end,
    GetBaseProfessionInfo = function() return profInfo(nil, false) end,
    GetChildProfessionInfo = function() return profInfo(nil, true) end,
    GetProfessionInfoBySkillLineID = function(line)
        if not isNum(line) then argErr("GetProfessionInfoBySkillLineID", 1, "number", line) end
        for _, p in pairs(profByIndex) do
            if p.skillLine == line then
                return { professionID = line, professionName = p.name, skillLevel = p.rank, maxSkillLevel = p.max,
                         skillModifier = 0, isPrimaryProfession = line ~= 129 and line ~= 185 and line ~= 356 }
            end
        end
        return { professionID = line, professionName = "", skillLevel = 0, maxSkillLevel = 0, skillModifier = 0 }
    end,
    GetAllProfessionTradeSkillLines = function()
        local out = {}
        for i = 1, #profByIndex do out[#out + 1] = profByIndex[i].skillLine end
        return out
    end,
    GetTradeSkillLineInfoByID = function(line)
        if not isNum(line) then argErr("GetTradeSkillLineInfoByID", 1, "number", line) end
        for _, p in pairs(profByIndex) do
            if p.skillLine == line then return p.name, p.rank, p.max, 0, nil end
        end
        return nil
    end,
    GetAllRecipeIDs = function()
        local out = {}
        local t = ts()
        if t and t.open and t.ready then for i, r in ipairs(t.recipes) do out[i] = r.recipeID end end
        return out
    end,
    GetFilteredRecipeIDs = function()
        local out = {}
        local t = ts()
        if t and t.open and t.ready then for _, r in ipairs(t.recipes) do if r.learned then out[#out + 1] = r.recipeID end end end
        return out
    end,
    GetRecipeInfo = function(recipeID, recipeLevel)
        if not isNum(recipeID) then argErr("GetRecipeInfo", 1, "number", recipeID) end
        local t = ts()
        local r = t and t.byID and t.byID[recipeID]
        if not r then
            local s = MOCK.spells[recipeID]
            if not s then return nil end
            return { recipeID = recipeID, name = s.name, learned = false, icon = s.icon, categoryID = 0,
                     relativeDifficulty = 3, numSkillUps = 0, craftable = false, disabled = false, favorite = false }
        end
        local s = MOCK.SpellRecord(recipeID) or {}
        return { recipeID = recipeID, name = r.name or s.name, learned = (t.open and r.learned) and true or false,
                 icon = s.icon, categoryID = r.categoryID or 1, relativeDifficulty = r.difficulty or 2,
                 numSkillUps = r.skillUps or 1, craftable = true, disabled = false, favorite = false,
                 hyperlink = G.C_Spell.GetSpellLink(recipeID), supportsQualities = false, isRecraft = false }
    end,
    GetRecipeOutputItemData = function(recipeID, reagents, allocGUID, qualityID)
        if not isNum(recipeID) then argErr("GetRecipeOutputItemData", 1, "number", recipeID) end
        local t = ts()
        local r = t and t.byID and t.byID[recipeID]
        if not (r and r.item) then return nil end
        return { itemID = r.item, hyperlink = MOCK.ItemLink(r.item) }
    end,
    GetTradeSkillLineForRecipe = function(recipeID)
        if not isNum(recipeID) then argErr("GetTradeSkillLineForRecipe", 1, "number", recipeID) end
        local t = ts()
        if t and t.byID and t.byID[recipeID] then return t.skillLine, t.name, t.skillLine end
        return nil
    end,
    GetCraftableCount = function(recipeID) if not isNum(recipeID) then argErr("GetCraftableCount", 1, "number", recipeID) end return 0 end,
    GetRecipeSchematic = function(recipeID)
        if not isNum(recipeID) then argErr("GetRecipeSchematic", 1, "number", recipeID) end
        return { recipeID = recipeID, quantityMin = 1, quantityMax = 1, reagentSlotSchematics = {} }
    end,
    OpenTradeSkill = function(line)
        if not isNum(line) then argErr("OpenTradeSkill", 1, "number", line) end
        if not MOCK.hw then MOCK.NoteForbidden("C_TradeSkillUI.OpenTradeSkill without a hardware event (shows UI)", 2) end
        for _, p in pairs(profByIndex) do
            if p.skillLine == line then
                MOCK.requests[#MOCK.requests + 1] = { kind = "opentradeskill", line = line }
                return true
            end
        end
        return false
    end,
    CloseTradeSkill = function() if tsOpen() then later(0, function() Game.CloseTradeSkill() end) end end,
    CraftRecipe = function(recipeID, count)
        if not MOCK.hw then
            MOCK.NoteForbidden("C_TradeSkillUI.CraftRecipe outside a hardware event (ADDON_ACTION_BLOCKED)", 2)
            later(0, function() fire("ADDON_ACTION_BLOCKED", "Greenfields", "C_TradeSkillUI.CraftRecipe()") end)
            return
        end
    end,
    GetRecipesTracked = function() return {} end,
    GetRemainingRecasts = function() return 0 end,
    StopRecipeRepeat = function() end,
}

-------------------------------------------------------------------------------
-- Loot & rolls
-------------------------------------------------------------------------------
-- state.loot = { slots = { {kind="item"|"money", id, count, copper, quality, quest} }, fishing, autoLoot }
local function lootSlot(slot, fname)
    if not isNum(slot) then argErr(fname, 1, "number", slot, 3) end
    local l = state.loot
    return l and l.slots[slot] or nil
end
G.GetNumLootItems = function() local l = state.loot return l and #l.slots or 0 end
G.LootSlotHasItem = function(slot)
    local s = lootSlot(slot, "LootSlotHasItem")
    return s ~= nil and s.kind == "item" and not s.looted
end
G.GetLootSlotType = function(slot)
    local s = lootSlot(slot, "GetLootSlotType")
    if not s or s.looted then return G.Enum.LootSlotType.None end
    return s.kind == "money" and G.Enum.LootSlotType.Money or G.Enum.LootSlotType.Item
end
G.GetLootSlotLink = function(slot)
    local s = lootSlot(slot, "GetLootSlotLink")
    if not s or s.kind ~= "item" or s.looted then return nil end
    itemCache[s.id] = true
    return MOCK.ItemLink(s.id)
end
G.GetLootSlotInfo = function(slot)
    local s = lootSlot(slot, "GetLootSlotInfo")
    if not s or s.looted then return nil end
    if s.kind == "money" then
        local copper = s.copper or 0
        local text = G.GetCoinText(copper)
        return 133784, text, 0, nil, 0, false, false, nil, false, true
    end
    local rec = MOCK.ItemRecord(s.id) or { name = "?", icon = 134400, quality = 1 }
    itemCache[s.id] = true
    return rec.icon, rec.name, s.count or 1, nil, rec.quality, false, s.quest and true or false, nil, false, false
end
G.GetLootSourceInfo = function(slot)
    local s = lootSlot(slot, "GetLootSourceInfo")
    if not s then return nil end
    return MaybeSecret("guids", "Creature-0-4170-1999-12-" .. (s.npc or 99001) .. "-0000ABCDEF"), s.count or 1
end
G.IsFishingLoot = function() return state.loot ~= nil and state.loot.fishing == true end
G.LootSlot = function(slot)
    local s = lootSlot(slot, "LootSlot")
    if not s or s.looted then return end
    s.looted = true
    later(0, function()
        if s.kind == "money" then
            Game.SetMoney(state.money + (s.copper or 0))
            Game.DeliverChat("CHAT_MSG_MONEY", format(G.YOU_LOOT_MONEY, G.GetCoinText(s.copper or 0)), "")
        else
            Game.AddItem(s.id, s.count or 1)
            local link = MOCK.ItemLink(s.id)
            local text = (s.count or 1) > 1 and format(G.LOOT_ITEM_SELF_MULTIPLE, link, s.count) or format(G.LOOT_ITEM_SELF, link)
            Game.DeliverChat("CHAT_MSG_LOOT", text, MYNAME)
            MOCK.requests[#MOCK.requests + 1] = { kind = "lootline", item = s.id, count = s.count or 1 }
        end
        fire("LOOT_SLOT_CLEARED", slot)
    end)
end
G.CloseLoot = function() if state.loot then later(0, function() Game.CloseLoot() end) end end
G.GetLootThreshold = function() return 2 end
G.GetLootRollItemLink = function(rollID)
    if not isNum(rollID) then argErr("GetLootRollItemLink", 1, "number", rollID) end
    local r = state.rolls[rollID]
    return r and MOCK.ItemLink(r.id) or nil
end
G.GetLootRollItemInfo = function(rollID)
    if not isNum(rollID) then argErr("GetLootRollItemInfo", 1, "number", rollID) end
    local r = state.rolls[rollID]
    if not r then return nil end
    local rec = MOCK.ItemRecord(r.id) or {}
    return rec.icon, rec.name, r.count or 1, rec.quality, (rec.bind or 0) == 1, true, true, false, 0, 0, 0, 0, false
end
G.GetLootRollTimeLeft = function(rollID)
    local r = state.rolls[rollID]
    if not r then return 0 end
    return max(0, (r.started + r.duration / 1000 - MOCK.uptime) * 1000)
end
G.RollOnLoot = function(rollID, rollType)
    if not isNum(rollID) then argErr("RollOnLoot", 1, "number", rollID) end
    local r = state.rolls[rollID]
    if not r then return end
    MOCK.requests[#MOCK.requests + 1] = { kind = "rollonloot", rollID = rollID, rollType = rollType or 0 }
end
G.ConfirmLootRoll = function() end
G.ConfirmLootSlot = function() end

-------------------------------------------------------------------------------
-- Money, merchant, PvP
-------------------------------------------------------------------------------
G.GetMoney = function() return state.money end
G.CanMerchantRepair = function() return state.merchant ~= nil and state.merchant.canRepair == true end
G.GetRepairAllCost = function()
    local m = state.merchant
    if not m then return 0, false end
    return m.repairCost or 0, (m.repairCost or 0) > 0 and m.canRepair == true
end
G.RepairAllItems = function() if MOCK.hw and state.merchant then local c = state.merchant.repairCost or 0 state.merchant.repairCost = 0 Game.SetMoney(state.money - c) end end
G.GetMerchantNumItems = function() return state.merchant and 3 or 0 end
G.GetPVPLifetimeStats = function()
    local p = CFG.pvp or {}
    return p.hk or 0, p.dk or 0, p.rank or 0
end
-- UnitHonor / GetHonor* / GetPVPRankInfo are UNKNOWN on Forever (FACTS A.15): deliberately absent
G.GetXPExhaustion = function() return nil end
G.UnitXP = function() return state.xp end
G.UnitXPMax = function() return 200000 end

-------------------------------------------------------------------------------
-- Chat & addon messages
-------------------------------------------------------------------------------
local prefixes = {}
local prefixCount = 0
local throttle = {}     -- prefix -> { tokens, last }
local THROTTLE_BURST, THROTTLE_REGEN = (CFG.throttle and CFG.throttle.burst) or 10, (CFG.throttle and CFG.throttle.regen) or 1.0
local CHAT_TYPES = { SAY = true, EMOTE = true, YELL = true, PARTY = true, RAID = true, GUILD = true, OFFICER = true,
    WHISPER = true, RAID_WARNING = true, INSTANCE_CHAT = true, CHANNEL = true, AFK = true, DND = true }
local ADDON_CHAT_TYPES = { PARTY = true, RAID = true, GUILD = true, OFFICER = true, WHISPER = true, INSTANCE_CHAT = true, CHANNEL = true }

local function takeToken(prefix)
    local b = throttle[prefix]
    local now = MOCK.uptime
    if not b then b = { tokens = THROTTLE_BURST, last = now }; throttle[prefix] = b end
    b.tokens = min(THROTTLE_BURST, b.tokens + (now - b.last) / THROTTLE_REGEN)
    b.last = now
    if b.tokens < 1 then return false end
    b.tokens = b.tokens - 1
    return true
end

local function rejected(code, why)
    local k = tostring(code) .. ":" .. why
    MOCK.commStats.rejected[k] = (MOCK.commStats.rejected[k] or 0) + 1
    return code
end

local function sendAddon(fname, logged, prefix, text, chatType, target)
    if isSecret(prefix) or type(prefix) ~= "string" then argErr(fname, 1, "string", prefix, 3) end
    if isSecret(text) then
        MOCK.LogTaint(fname .. "(secret text)", 3, "error")
        error(format("bad argument #2 to '%s' (secret value)", fname), 3)
    end
    if type(text) ~= "string" then argErr(fname, 2, "string", text, 3) end
    if type(chatType) ~= "string" then argErr(fname, 3, "string", chatType, 3) end
    if target ~= nil and (type(target) ~= "string" or isSecret(target)) then argErr(fname, 4, "string", target, 3) end
    local E = G.Enum.SendAddonMessageResult
    if #prefix == 0 or #prefix > 16 then return rejected(E.InvalidPrefix, "prefix length") end
    if not prefixes[prefix] then
        MOCK.Warn("comm", fname .. ": prefix '" .. prefix .. "' was never registered", 3)
        return rejected(E.InvalidPrefix, "unregistered prefix")
    end
    if find(text, "\0", 1, true) then
        MOCK.Warn("comm", fname .. ": message contains an embedded \\0", 3)
        return rejected(E.InvalidMessage, "embedded NUL")
    end
    if #text > 255 then
        MOCK.Warn("comm", fname .. ": message of " .. #text .. " bytes (limit 255)", 3)
        return rejected(E.InvalidMessage, "over 255 bytes")
    end
    local ct = upper(chatType)
    if not ADDON_CHAT_TYPES[ct] then return rejected(E.InvalidChatType, "chat type " .. ct) end
    if state.chatLockdown then return rejected(E.AddOnMessageLockdown, "lockdown") end
    if ct == "GUILD" or ct == "OFFICER" then
        if not guild then return rejected(E.NotInGuild, "not in guild") end
    elseif ct == "PARTY" or ct == "RAID" then
        if not state.group then return rejected(E.NotInGroup, "not in group") end
    elseif ct == "INSTANCE_CHAT" then
        if not groupMatches(2) then return rejected(E.NotInGroup, "no instance group") end
    elseif ct == "WHISPER" then
        if not target or target == "" then return rejected(E.TargetRequired, "no target") end
    elseif ct == "CHANNEL" then
        MOCK.Warn("comm", fname .. ": CHANNEL addon messages are not delivered on Forever (FACTS R6)", 3)
        return rejected(E.InvalidChannel, "CHANNEL")
    end
    if not takeToken(prefix) then
        MOCK.commStats.throttled = MOCK.commStats.throttled + 1
        return rejected(E.AddonMessageThrottle, "throttle")
    end
    if ct == "RAID" and state.group.kind ~= "raid" then ct = "PARTY" end
    MOCK.outbox[#MOCK.outbox + 1] = { prefix = prefix, text = text, chatType = ct, target = target, logged = logged, t = MOCK.uptime }
    MOCK.commStats.sent = MOCK.commStats.sent + 1
    MOCK.commStats.bytes = MOCK.commStats.bytes + #text
    return E.Success
end

local CC = G.C_ChatInfo
CC.RegisterAddonMessagePrefix = function(prefix)
    if type(prefix) ~= "string" then argErr("RegisterAddonMessagePrefix", 1, "string", prefix) end
    local E = G.Enum.RegisterAddonMessagePrefixResult
    if #prefix == 0 or #prefix > 16 then return E.InvalidPrefix end
    if prefixes[prefix] then return E.DuplicatePrefix end
    if prefixCount >= 512 then return E.MaxPrefixes end
    prefixes[prefix] = true
    prefixCount = prefixCount + 1
    return E.Success
end
CC.IsAddonMessagePrefixRegistered = function(prefix)
    if type(prefix) ~= "string" then argErr("IsAddonMessagePrefixRegistered", 1, "string", prefix) end
    return prefixes[prefix] == true
end
CC.GetRegisteredAddonMessagePrefixes = function()
    local out = {}
    for p in pairs(prefixes) do out[#out + 1] = p end
    sort(out)
    return out
end
CC.SendAddonMessage = function(prefix, text, chatType, target) return sendAddon("SendAddonMessage", false, prefix, text, chatType, target) end
CC.SendAddonMessageLogged = function(prefix, text, chatType, target) return sendAddon("SendAddonMessageLogged", true, prefix, text, chatType, target) end
CC.InChatMessagingLockdown = function() return state.chatLockdown == true end
CC.IsChatLineCensored = function() return false end
CC.GetChannelList = function() return end
CC.GetNumActiveChannels = function() return 0 end
CC.PerformEmote = function(token, unit)
    if type(token) ~= "string" then argErr("PerformEmote", 1, "string", token) end
    MOCK.requests[#MOCK.requests + 1] = { kind = "emote", token = token }
end

local HW_CHAT = { SAY = true, YELL = true, CHANNEL = true }
CC.SendChatMessage = function(msg, chatType, languageID, target)
    if isSecret(msg) then
        MOCK.LogTaint("SendChatMessage(secret text)", 2, "error")
        error("bad argument #1 to 'SendChatMessage' (secret value)", 2)
    end
    if type(msg) ~= "string" then argErr("SendChatMessage", 1, "string", msg) end
    if chatType ~= nil and type(chatType) ~= "string" then argErr("SendChatMessage", 2, "string", chatType) end
    if target ~= nil and type(target) ~= "string" and not isNum(target) then argErr("SendChatMessage", 4, "string", target) end
    local ct = upper(chatType or "SAY")
    if not CHAT_TYPES[ct] then error("SendChatMessage(): invalid chat type '" .. tostring(chatType) .. "'", 2) end
    if find(msg, "\n", 1, true) then MOCK.Warn("chat", "SendChatMessage: newline in message (the client cuts the line there)", 2) end
    if #msg > 255 then
        MOCK.Warn("chat", "SendChatMessage: " .. #msg .. " bytes (limit 255; the server truncates)", 2)
        msg = sub(msg, 1, 255)
    end
    local entry = { t = MOCK.uptime, chatType = ct, target = target, text = msg, hw = MOCK.hw, scenario = MOCK.scenario,
                    where = MOCK.addonWhere(2) }
    if state.chatLockdown then
        entry.blocked = "lockdown"
        MOCK.chatLog[#MOCK.chatLog + 1] = entry
        MOCK.NoteForbidden("SendChatMessage(" .. ct .. ") during chat lockdown", 2)
        return
    end
    if HW_CHAT[ct] and not MOCK.hw and not state.instance then
        entry.blocked = "hardware event required"
        MOCK.chatLog[#MOCK.chatLog + 1] = entry
        MOCK.NoteForbidden("SendChatMessage(" .. ct .. ") without a hardware event", 2)
        later(0, function() fire("ADDON_ACTION_BLOCKED", "Greenfields", "SendChatMessage()") end)
        return
    end
    if not MOCK.hw and (ct == "RAID" or ct == "WHISPER" or ct == "RAID_WARNING") then
        MOCK.Warn("chat", "automatic " .. ct .. " chat send (no hardware event; FACTS D.7 says click-only)", 2)
    end
    if ct == "WHISPER" and (target == nil or target == "") then error("SendChatMessage(): WHISPER needs a target", 2) end
    if (ct == "GUILD" or ct == "OFFICER") and not guild then later(0, function() Game.SystemMessage(G.ERR_GUILD_PLAYER_NOT_IN_GUILD or "You are not in a guild.") end) return end
    if (ct == "PARTY" or ct == "RAID" or ct == "RAID_WARNING") and not state.group then
        later(0, function() Game.SystemMessage(G.ERR_NOT_IN_GROUP) end)
        return
    end
    MOCK.chatLog[#MOCK.chatLog + 1] = entry
    MOCK.requests[#MOCK.requests + 1] = { kind = "chat", chatType = ct, text = msg, target = target and tostring(target) or nil }
end
-- the global SendChatMessage is ABSENT on Forever (CORE_API / task spec)

-- Chat frame utilities (the chat edit box is ChatFrame1EditBox)
local function chatBox() return rawget(_G, "ChatFrame1EditBox") end
local function openChat(text)
    local box = chatBox()
    if not box then return false end
    box:Show()
    MOCK.EditBoxSetText(box, S[box], text or "", false)
    MOCK.SetFocus(box)
    return true
end
MOCK.chatFilters = {}
G.ChatFrameUtil = {
    InsertLink = function(link)
        if type(link) ~= "string" then argErr("InsertLink", 1, "string", link) end
        local box = chatBox()
        if box and box:IsShown() and S[box].focus then
            box:Insert(link)
            return true
        end
        return false
    end,
    SendTell = function(name, chatFrame)
        needString(name, "SendTell", 1)
        return openChat("/w " .. name .. " ")
    end,
    OpenChat = function(text, chatFrame, desiredCursorPosition)
        if text ~= nil and type(text) ~= "string" then argErr("OpenChat", 1, "string", text) end
        return openChat(text or "")
    end,
    ChooseBoxForSend = function() return chatBox() end,
    ActivateChat = function(box) if box and S[box] then box:Show(); MOCK.SetFocus(box) end end,
    AddMessageEventFilter = function(event, fn)
        needString(event, "AddMessageEventFilter", 1)
        if type(fn) ~= "function" then argErr("AddMessageEventFilter", 2, "function", fn) end
        MOCK.chatFilters[event] = MOCK.chatFilters[event] or {}
        tinsert(MOCK.chatFilters[event], fn)
    end,
    RemoveMessageEventFilter = function(event, fn)
        local l = MOCK.chatFilters[event]
        if not l then return end
        for i = #l, 1, -1 do if l[i] == fn then tremove(l, i) end end
    end,
}
G.ChatEdit_InsertLink = function(link) return G.ChatFrameUtil.InsertLink(link) end
G.ChatEdit_GetActiveWindow = function()
    local box = chatBox()
    if box and box:IsShown() and S[box].focus then return box end
    return nil
end
G.ChatTypeInfo = setmetatable({}, { __index = function() return { r = 1, g = 1, b = 1, id = 1, sticky = 0 } end })
G.RaidNotice_AddMessage = function(frame, msg) MOCK.printLog[#MOCK.printLog + 1] = { t = MOCK.uptime, text = "[raid notice] " .. tostring(msg) } end
G.RaidWarningFrame = nil

-------------------------------------------------------------------------------
-- Root frames the game layer adds (chat edit box behaviour, trade skill frame)
-------------------------------------------------------------------------------
function Game.CreateClientFrames()
    local box = rawget(_G, "ChatFrame1EditBox")
    if box then
        local bst = S[box]
        bst.font = { "Fonts\\ARIALN.TTF", 14, "" }
        bst.scripts.OnEscapePressed = function(self) self:SetText(""); self:ClearFocus(); self:Hide() end
        bst.scripts.OnEnterPressed = function(self)
            local text = self:GetText()
            self:SetText("")
            self:ClearFocus()
            self:Hide()
            if text ~= "" then MOCK.requests[#MOCK.requests + 1] = { kind = "typed", text = text } end
        end
        box:SetSize(420, 24)
        box:SetPoint("BOTTOMLEFT", rawget(_G, "UIParent"), "BOTTOMLEFT", 32, 70)
    end
    MOCK.OnChatFrameMessage = function(_, text)
        MOCK.printLog[#MOCK.printLog + 1] = { t = MOCK.uptime, text = isSecret(text) and "<secret>" or R.tostring(text), scenario = MOCK.scenario }
    end
end

-------------------------------------------------------------------------------
-- Event pre/post hooks: combat, encounter, death state follow the events
-------------------------------------------------------------------------------
local rawFire = MOCK.FireEvent
local PRE, POST = {}, {}
MOCK.eventPre, MOCK.eventPost = PRE, POST
function MOCK.FireEvent(event, ...)
    local pre = PRE[event]
    if pre then pre(...) end
    local n = rawFire(event, ...)
    local post = POST[event]
    if post then post(...) end
    return n
end
fire = function(event, ...) return MOCK.FireEvent(event, ...) end
-- PLAYER_REGEN_DISABLED fires before lockdown starts; PLAYER_REGEN_ENABLED after it ends.
POST.PLAYER_REGEN_DISABLED = function() state.combat = true end
PRE.PLAYER_REGEN_ENABLED = function() state.combat = false end
PRE.ENCOUNTER_START = function(id, name, diff, size)
    state.encounter = { id = MOCK.Unwrap(id), name = MOCK.Unwrap(name), started = MOCK.uptime }
    if state.instance then state.chatLockdown = true end
end
POST.ENCOUNTER_END = function()
    state.encounter = nil
    state.chatLockdown = state.forceChatLockdown
end
PRE.PLAYER_DEAD = function() state.dead = true end
PRE.PLAYER_ALIVE = function() if state.dead then state.dead = false; state.ghost = true end end
PRE.PLAYER_UNGHOST = function() state.dead = false; state.ghost = false end
PRE.PLAYER_LEVEL_UP = function(level) if isNum(level) then ME.level = level end end
PRE.PLAYER_TARGET_CHANGED = function() end

-------------------------------------------------------------------------------
-- Tick hook: deferred work, pending forbidden-action events
-------------------------------------------------------------------------------
MOCK.tickHooks[#MOCK.tickHooks + 1] = function()
    local now = MOCK.uptime
    local list = MOCK.later
    if #list > 0 then
        local due, keep = {}, {}
        for _, e in ipairs(list) do
            if e.due <= now + 1e-9 then due[#due + 1] = e else keep[#keep + 1] = e end
        end
        MOCK.later = keep
        for _, e in ipairs(due) do Protect("mock", "deferred", e.fn) end
    end
    if MOCK.pendingForbidden and #MOCK.pendingForbidden > 0 then
        local p = MOCK.pendingForbidden
        MOCK.pendingForbidden = {}
        for _, a in ipairs(p) do fire("ADDON_ACTION_FORBIDDEN", a[1], a[2]) end
    end
end

-------------------------------------------------------------------------------
-- Harness entry points (run.py)
-------------------------------------------------------------------------------
function Game.SetSecret(cat, on) MOCK.secretOn[cat] = on and true or nil end

function Game.SetModifiers(shift, ctrl, alt)
    state.mods.shift, state.mods.ctrl, state.mods.alt = shift and true or false, ctrl and true or false, alt and true or false
end

function Game.SetCursor(x, y) MOCK.cursorX, MOCK.cursorY = x, y end
function Game.CursorTo(obj)
    local l, b, w, h = MOCK.ScreenRect(obj)
    if l then MOCK.cursorX, MOCK.cursorY = l + w / 2, b + h / 2 end
end

function Game.RosterLoaded()
    state.guildLoaded = true
end

function Game.SetMemberOnline(name, online, zone)
    local m = guildByName[name]
    if m then
        m.online = online and true or false
        if zone then m.zone = zone end
    end
end

function Game.SetMemberField(name, field, value)
    local m = guildByName[name]
    if m then m[field] = value end
end

--- spec = { kind, category, lootMethod, members = { {name, subgroup, rank, role, combatRole, isML, online, dead, zone, level} } }
function Game.SetGroup(spec)
    if spec == nil then
        local was = state.group ~= nil
        state.group = nil
        if was then fire("GROUP_LEFT", 1, "") end
        fire("GROUP_ROSTER_UPDATE")
        return
    end
    local wasIn = state.group ~= nil
    local g = { kind = spec.kind or "party", category = spec.category or 1, lootMethod = spec.lootMethod, members = {}, byName = {} }
    for i, m in ipairs(spec.members or {}) do
        local e = {}
        for k, v in pairs(m) do e[k] = v end
        e.subgroup = e.subgroup or 1
        e.rank = e.rank or 0
        g.members[i] = e
        g.byName[e.name] = e
    end
    if not g.byName[MYNAME] then
        -- not in this group (e.g. a client outside the raid)
        if wasIn then state.group = nil; fire("GROUP_LEFT", 1, ""); fire("GROUP_ROSTER_UPDATE") end
        return
    end
    local oldLeader
    if state.group then for _, e in ipairs(state.group.members) do if e.rank == 2 then oldLeader = e.name end end end
    state.group = g
    if not wasIn then fire("GROUP_JOINED", g.category, "Party-1-" .. format("%08X", 4242)) end
    fire("GROUP_ROSTER_UPDATE")
    local newLeader
    for _, e in ipairs(g.members) do if e.rank == 2 then newLeader = e.name end end
    if newLeader ~= oldLeader then fire("PARTY_LEADER_CHANGED") end
end

function Game.EnterInstance(spec)
    state.instance = spec
    state.zone = spec and spec.name or (CFG.zone or "Stormwind City")
    fire("PLAYER_ENTERING_WORLD", false, false)
    fire("ZONE_CHANGED_NEW_AREA")
    fire("UPDATE_INSTANCE_INFO")
end
function Game.LeaveInstance(zone)
    state.instance = nil
    state.zone = zone or CFG.zone or "Stormwind City"
    fire("PLAYER_ENTERING_WORLD", false, false)
    fire("ZONE_CHANGED_NEW_AREA")
end
function Game.SetZone(zone, subzone)
    state.zone = zone or state.zone
    state.subzone = subzone or ""
    fire("ZONE_CHANGED_NEW_AREA")
end

function Game.SetCombat(on)
    if on and not state.combat then fire("PLAYER_REGEN_DISABLED")
    elseif not on and state.combat then fire("PLAYER_REGEN_ENABLED") end
end
function Game.SetChatLockdown(on)
    state.forceChatLockdown = on and true or false
    state.chatLockdown = state.forceChatLockdown or (state.encounter ~= nil and state.instance ~= nil)
end

function Game.SetMoney(copper)
    copper = floor(copper)
    if copper == state.money then return end
    state.money = copper
    fire("PLAYER_MONEY")
end

function Game.SetLevel(level)
    ME.level = level
    fire("PLAYER_LEVEL_UP", level, 50, 30, 1, 1, 1, 1, 1)
    fire("UNIT_LEVEL", "player")
    fire("PLAYER_LEVEL_CHANGED", level - 1, level)
end

function Game.SetFlag(flag, on)
    if flag == "afk" then state.afk = on and true or false
    elseif flag == "dnd" then state.dnd = on and true or false
    elseif flag == "falling" then state.falling = on and true or false
    elseif flag == "taxi" then state.taxi = on and true or false
    elseif flag == "swimming" then state.swimming = on and true or false end
    if flag == "afk" or flag == "dnd" then fire("PLAYER_FLAGS_CHANGED", "player") end
end

function Game.SetTarget(name)
    state.target = name
    fire("PLAYER_TARGET_CHANGED")
end

function Game.AddItem(id, count)
    count = count or 1
    MOCK.ItemRecord(id)
    itemCache[id] = true
    for b = 0, 4 do
        local stack = (MOCK.items[id] or {}).stack or 1
        for _, e in pairs(bags[b]) do
            if e.id == id and e.count + count <= stack then
                e.count = e.count + count
                fire("BAG_UPDATE", b)
                later(0, function() fire("BAG_UPDATE_DELAYED") end)
                return true
            end
        end
    end
    for b = 0, 4 do
        for slot = 1, BAG_SLOTS[b] do
            if not bags[b][slot] then
                bags[b][slot] = { id = id, count = count }
                fire("BAG_UPDATE", b)
                later(0, function() fire("BAG_UPDATE_DELAYED") end)
                return true
            end
        end
    end
    return false
end
function Game.RemoveItem(id, count)
    count = count or 1
    for b = 0, 4 do
        for slot, e in pairs(bags[b]) do
            if e.id == id then
                local take = min(count, e.count)
                e.count = e.count - take
                count = count - take
                if e.count <= 0 then bags[b][slot] = nil end
                fire("BAG_UPDATE", b)
                if count <= 0 then later(0, function() fire("BAG_UPDATE_DELAYED") end) return true end
            end
        end
    end
    later(0, function() fire("BAG_UPDATE_DELAYED") end)
    return count <= 0
end

--- auras: array of { spellId, name?, duration, remaining, applications, hidden, isHarmful, sourceUnit }
function Game.SetAuras(name, auras)
    local list = {}
    for i, a in ipairs(auras or {}) do
        auraSeq = auraSeq + 1
        local e = {}
        for k, v in pairs(a) do e[k] = v end
        e.auraInstanceID = auraSeq
        local dur = e.duration or 0
        e.expirationTime = dur > 0 and (MOCK.uptime + (e.remaining or dur)) or 0
        list[i] = e
    end
    state.auras[name] = list
    -- UNIT_AURA for whichever tokens point at that unit
    if name == MYNAME then
        fire("UNIT_AURA", "player", { isFullUpdate = true })
    else
        local g = state.group
        if g then
            if g.kind == "raid" then
                for i, e in ipairs(g.members) do if e.name == name then fire("UNIT_AURA", "raid" .. i, { isFullUpdate = true }) end end
            end
            for i, e in ipairs(partyList()) do if e.name == name then fire("UNIT_AURA", "party" .. i, { isFullUpdate = true }) end end
        end
    end
end

local castSeq = 0
function Game.Cast(spellID, opts)
    opts = opts or {}
    castSeq = castSeq + 1
    local guid = format("Cast-3-4170-0-%d-%d-%010X", MOCK.tickNo, spellID, castSeq)
    if opts.cooldown then state.spellCD[spellID] = { start = MOCK.uptime, dur = opts.cooldown } end
    if opts.itemCooldown and opts.item then state.itemCD[opts.item] = { start = MOCK.uptime, dur = opts.itemCooldown } end
    fire("UNIT_SPELLCAST_SENT", "player", opts.target or "", guid, spellID)
    fire("UNIT_SPELLCAST_START", "player", guid, spellID)
    fire("UNIT_SPELLCAST_STOP", "player", guid, spellID)
    fire("UNIT_SPELLCAST_SUCCEEDED", "player", guid, spellID)
    if opts.cooldown then fire("SPELL_UPDATE_COOLDOWN") end
    return guid
end

--- spec = { skillLine, child, name, rank, max, recipes = { {recipeID, name, learned, item, difficulty, skillUps} } }
function Game.OpenTradeSkill(spec)
    local t = { open = true, ready = false, skillLine = spec.skillLine, child = spec.child, name = spec.name,
                rank = spec.rank or 1, max = spec.max or 300, recipes = {}, byID = {}, linked = spec.linked, guild = spec.guild }
    for i, r in ipairs(spec.recipes or {}) do
        local e = {}
        for k, v in pairs(r) do e[k] = v end
        t.recipes[i] = e
        t.byID[e.recipeID] = e
        if e.item then MOCK.ItemRecord(e.item) end
    end
    state.tradeskill = t
    local pf = rawget(_G, "ProfessionsFrame")
    if not pf then
        pf = MOCK.NewFrame("Frame", "ProfessionsFrame", rawget(_G, "UIParent"))
        S[pf].where = "client"
        pf:SetSize(942, 658)
        pf:SetPoint("TOPLEFT", 16, -116)
        S[pf].strata = "MEDIUM"
        S[pf].shown = false
    end
    pf:Show()
    fire("TRADE_SKILL_SHOW")
    later(0.1, function()
        t.ready = true
        fire("TRADE_SKILL_DATA_SOURCE_CHANGED")
        fire("TRADE_SKILL_LIST_UPDATE")
    end)
end
function Game.CloseTradeSkill()
    local t = state.tradeskill
    if not t then return end
    t.open, t.ready = false, false
    local pf = rawget(_G, "ProfessionsFrame")
    if pf then pf:Hide() end
    fire("TRADE_SKILL_CLOSE")
end
function Game.LearnRecipe(recipeID)
    known[recipeID] = true
    fire("NEW_RECIPE_LEARNED", recipeID, 1, nil)
    fire("LEARNED_SPELL_IN_TAB", recipeID, 1, false)
    fire("SKILL_LINES_CHANGED")
end

--- slots = { {kind="item", id, count, quality?} | {kind="money", copper} }
function Game.OpenLoot(slots, opts)
    opts = opts or {}
    local l = { slots = {}, fishing = opts.fishing and true or false }
    for i, s in ipairs(slots or {}) do
        local e = {}
        for k, v in pairs(s) do e[k] = v end
        l.slots[i] = e
    end
    state.loot = l
    fire("LOOT_READY", opts.autoLoot and true or false)
    fire("LOOT_OPENED", opts.autoLoot and true or false, opts.fromItem and true or false)
end
function Game.CloseLoot()
    if not state.loot then return end
    state.loot = nil
    fire("LOOT_CLOSED")
end
function Game.StartRoll(rollID, itemID, durationMs, count)
    MOCK.ItemRecord(itemID)
    state.rolls[rollID] = { id = itemID, count = count or 1, duration = durationMs or 60000, started = MOCK.uptime }
    fire("START_LOOT_ROLL", rollID, durationMs or 60000, nil)
end
function Game.EndRoll(rollID)
    if state.rolls[rollID] then
        state.rolls[rollID] = nil
        fire("CANCEL_LOOT_ROLL", rollID)
    end
end

function Game.OpenMerchant(spec)
    state.merchant = { canRepair = spec and spec.canRepair ~= false, repairCost = spec and spec.repairCost or 0 }
    fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", G.Enum.PlayerInteractionType.Merchant)
    fire("MERCHANT_SHOW")
end
function Game.CloseMerchant()
    if not state.merchant then return end
    state.merchant = nil
    fire("MERCHANT_CLOSED")
    fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", G.Enum.PlayerInteractionType.Merchant)
end

function Game.Die() fire("PLAYER_DEAD") end
function Game.Release() fire("PLAYER_ALIVE") end
function Game.Resurrect() fire("PLAYER_UNGHOST") fire("PLAYER_ALIVE") end

function Game.SetMemberState(name, field, value)
    local e = groupEntry(name)
    if e then e[field] = value end
end

--- delivers a chat event the way the client builds it (17 args)
local lineID = 0
function Game.DeliverChat(event, text, sender, opts)
    opts = opts or {}
    lineID = lineID + 1
    local senderFull = ""
    local guid = nil
    if sender and sender ~= "" then
        local rec = W.byName[stripRealm(sender)]
        senderFull = find(sender, "-", 1, true) and sender or (rec and fullName(rec) or (sender .. "-" .. W.realm))
        guid = rec and rec.guid or nil
    end
    -- chat message filters (ChatFrameUtil.AddMessageEventFilter) run for the chat frame only
    for _, fn in ipairs(MOCK.chatFilters[event] or {}) do
        Protect("chatfilter", "chat filter " .. event, fn, rawget(_G, "DEFAULT_CHAT_FRAME"), event, text, senderFull)
    end
    return fire(event, text, senderFull, opts.language or "", opts.channelName or "", opts.target or "", opts.flags or "",
        opts.zoneChannelID or 0, opts.channelIndex or 0, opts.channelBaseName or "", 0, lineID, guid, 0, false, false, false, false)
end

function Game.SystemMessage(text) return Game.DeliverChat("CHAT_MSG_SYSTEM", text, "") end

--- addon message arriving from the bus
function Game.DeliverAddon(prefix, text, channel, sender, target, logged)
    if not prefixes[prefix] then return 0 end
    local senderFull = find(sender, "-", 1, true) and sender or MOCK.FullName(sender)
    return fire(logged and "CHAT_MSG_ADDON_LOGGED" or "CHAT_MSG_ADDON", prefix, text, channel, senderFull,
        target or "", 0, 0, "", 0)
end

function Game.ReadyCheck(initiator, timeLeft)
    state.readyCheck = {}
    fire("READY_CHECK", initiator, timeLeft or 35)
end
function Game.ReadyConfirm(name, ready)
    if not state.readyCheck then return end
    state.readyCheck[name] = ready and "ready" or "notready"
    local token
    if name == MYNAME then token = "player"
    elseif state.group and state.group.kind == "raid" then
        for i, e in ipairs(state.group.members) do if e.name == name then token = "raid" .. i end end
    end
    if token then fire("READY_CHECK_CONFIRM", token, ready and true or false) end
end
function Game.ReadyFinished()
    fire("READY_CHECK_FINISHED", false)
    state.readyCheck = nil
end

function Game.TakeOutbox()
    local o = MOCK.outbox
    MOCK.outbox = {}
    return o
end
function Game.TakeRequests()
    local r = MOCK.requests
    MOCK.requests = {}
    return r
end

-------------------------------------------------------------------------------
-- Setup: the order the pieces must be installed in (called by run.py)
-------------------------------------------------------------------------------
function MOCK.Setup()
    MOCK.installSecretWrappers()
    MOCK.CreateStandardFonts()
    MOCK.InstallGlobals()
    MOCK.CreateRootFrames()
    Game.CreateClientFrames()
    MOCK.InstallGlobals()
    MOCK.StripStockLibs()
    MOCK.InstallRawgetProbe()
    MOCK.InstallStrictGlobals()
end
