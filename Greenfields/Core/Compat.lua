--[[ Greenfields - Core/Compat.lua
     GF.API: the ONLY place that touches version-sensitive client APIs.

     Forever (1.60.1, Interface 16001) runs Classic content on a Midnight-era API:
       * classic globals are gone (GetItemInfo, GetSpellInfo, ...): use C_Item / C_Spell
       * C APIs throw on nil or wrongly typed arguments: every call is type-checked + pcall'd
       * "secret values": in combat / encounters some returns (names, GUIDs, aura fields,
         chat text) are opaque and raise when compared or used as table keys. Anything
         that came from the client goes through API.Readable / API.Clean before use.
       * names are region-unique, and the second return of UnitFullName is a surname,
         not a realm, so players are keyed by bare name (see API.Key).
     Every function here returns plain Lua values and never raises. ]]

local _, GF = ...

local API = {}
GF.API = API

local type, pcall, select, tostring, tonumber, floor = type, pcall, select, tostring, tonumber, math.floor
local rawget = rawget

local function G(name) return rawget(_G, name) end
local function pack(...) return { n = select("#", ...), ... } end

-------------------------------------------------------------------------------
-- Secret values
-------------------------------------------------------------------------------
local canaccess = G("canaccessvalue")
local issecret = G("issecretvalue")

--- true when v can be safely compared/concatenated/used as a key.
function API.Readable(v)
    if v == nil then return true end
    if canaccess then
        local ok, r = pcall(canaccess, v)
        if ok then return r and true or false end
        return false
    end
    if issecret then
        local ok, r = pcall(issecret, v)
        if ok then return not r end
        return false
    end
    return true
end
local Readable = API.Readable

--- v when readable, otherwise nil.
function API.Clean(v)
    if Readable(v) then return v end
    return nil
end

function API.CleanString(v)
    if type(v) == "string" and Readable(v) then return v end
    return nil
end

function API.CleanNumber(v)
    if type(v) == "number" and Readable(v) then return v end
    return nil
end

-------------------------------------------------------------------------------
-- Clocks
-------------------------------------------------------------------------------
function API.ServerTime()
    local f = G("GetServerTime")
    if f then
        local ok, t = pcall(f)
        if ok and type(t) == "number" then return t end
    end
    return time()
end

function API.Time()
    local f = G("GetTime")
    return f and f() or 0
end

function API.InCombat()
    local f = G("InCombatLockdown")
    return f and f() and true or false
end

-------------------------------------------------------------------------------
-- Identity: players are keyed by name. Forever has region-unique names, so any
-- "-Suffix" is dropped there; other clients keep Ambiguate's "Name-Realm" for
-- players from other realms.
-------------------------------------------------------------------------------
local uniqueNames

function API.UniqueNames()
    if uniqueNames == nil then
        uniqueNames = false
        local pid, camelot = G("WOW_PROJECT_ID"), G("WOW_PROJECT_CAMELOT")
        if pid and camelot and pid == camelot then uniqueNames = true end
        local f = G("RegionalUniqueNamesEnabled")
        if f then
            local ok, r = pcall(f)
            if ok and r then uniqueNames = true end
        end
    end
    return uniqueNames
end

function API.IsForever()
    local pid, camelot = G("WOW_PROJECT_ID"), G("WOW_PROJECT_CAMELOT")
    return (pid and camelot and pid == camelot) and true or false
end

--- Key(rawName) -> stable player key or nil (secret / empty).
function API.Key(name)
    if type(name) ~= "string" or not Readable(name) or name == "" then return nil end
    local amb = G("Ambiguate")
    if amb then
        local ok, n = pcall(amb, name, "none")
        if ok and type(n) == "string" and n ~= "" then name = n end
    end
    if API.UniqueNames() then
        -- region-unique first names: drop a "-Realm" suffix and Forever's surname (the guild
        -- roster says "Kaghul Doomskull" while addon senders and UnitName say "Kaghul")
        name = name:match("^([^%s%-]+)") or name
    end
    return name
end

local myKey
function API.MyKey()
    if not myKey then
        local n = API.UnitName("player")
        myKey = API.Key(n)
    end
    return myKey
end

function API.NormalizedRealm()
    local f = G("GetNormalizedRealmName")
    if f then
        local ok, r = pcall(f)
        if ok and type(r) == "string" and Readable(r) then return r end
    end
    return ""
end

-------------------------------------------------------------------------------
-- Units
-------------------------------------------------------------------------------
function API.UnitName(unit)
    local f = G("UnitName")
    if not f or type(unit) ~= "string" then return nil end
    local ok, n = pcall(f, unit)
    if ok and type(n) == "string" and Readable(n) and n ~= "" and n ~= UNKNOWNOBJECT then return n end
    return nil
end

function API.UnitKey(unit) return API.Key(API.UnitName(unit)) end

--- UnitClassFile(unit) -> "WARRIOR" etc or nil
function API.UnitClassFile(unit)
    local f = G("UnitClass")
    if not f or type(unit) ~= "string" then return nil end
    local ok, _, file = pcall(f, unit)
    if ok and type(file) == "string" and Readable(file) then return file end
    return nil
end

function API.UnitLevel(unit)
    local f = G("UnitLevel")
    if not f then return 0 end
    local ok, l = pcall(f, unit)
    if ok and type(l) == "number" and Readable(l) then return l end
    return 0
end

function API.UnitRace(unit)
    local f = G("UnitRace")
    if not f then return nil end
    local ok, loc, file = pcall(f, unit)
    if ok and Readable(file) then return file, Readable(loc) and loc or nil end
    return nil
end

function API.UnitFaction(unit)
    local f = G("UnitFactionGroup")
    if not f then return nil end
    local ok, fac = pcall(f, unit or "player")
    if ok and type(fac) == "string" and Readable(fac) then return fac end
    return nil
end

function API.UnitGUID(unit)
    local f = G("UnitGUID")
    if not f then return nil end
    local ok, g = pcall(f, unit)
    if ok and type(g) == "string" and Readable(g) then return g end
    return nil
end

local function boolCall(fname, ...)
    local f = G(fname)
    if not f then return false end
    local ok, r = pcall(f, ...)
    if ok and Readable(r) then return r and true or false end
    return false
end

function API.UnitIsConnected(unit) return boolCall("UnitIsConnected", unit) end
function API.UnitIsDead(unit) return boolCall("UnitIsDeadOrGhost", unit) end
function API.UnitIsAFK(unit) return boolCall("UnitIsAFK", unit or "player") end
function API.UnitExists(unit) return boolCall("UnitExists", unit) end

--- UnitIsVisible(unit) -> bool; true when the client can't tell us.
function API.UnitIsVisible(unit)
    local f = G("UnitIsVisible")
    if not f or type(unit) ~= "string" then return true end
    local ok, r = pcall(f, unit)
    if not ok or not Readable(r) then return true end
    return r and true or false
end
function API.IsFalling() return boolCall("IsFalling") end
function API.IsGroupLeader(unit) return boolCall("UnitIsGroupLeader", unit or "player") end
function API.IsGroupAssistant(unit) return boolCall("UnitIsGroupAssistant", unit or "player") end

-------------------------------------------------------------------------------
-- Classes
-------------------------------------------------------------------------------
API.CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

local FALLBACK_CLASS_COLORS = {
    WARRIOR = { 0.78, 0.61, 0.43 }, PALADIN = { 0.96, 0.55, 0.73 }, HUNTER = { 0.67, 0.83, 0.45 },
    ROGUE = { 1.00, 0.96, 0.41 }, PRIEST = { 1.00, 1.00, 1.00 }, SHAMAN = { 0.00, 0.44, 0.87 },
    MAGE = { 0.25, 0.78, 0.92 }, WARLOCK = { 0.53, 0.53, 0.93 }, DRUID = { 1.00, 0.49, 0.04 },
}

--- ClassColor("MAGE") -> {r=,g=,b=}
function API.ClassColor(classFile)
    if type(classFile) ~= "string" then return nil end
    local rcc = G("RAID_CLASS_COLORS")
    local c = rcc and rcc[classFile]
    if c and c.r then return c end
    local fb = FALLBACK_CLASS_COLORS[classFile]
    if fb then return { r = fb[1], g = fb[2], b = fb[3] } end
    return nil
end

function API.ClassName(classFile)
    local t = G("LOCALIZED_CLASS_NAMES_MALE")
    if t and classFile and t[classFile] then return t[classFile] end
    return classFile and GF.Util.Capitalize(classFile) or "?"
end

--- Sets a texture to the class icon. Prefers the retail atlas, falls back to the classic
-- sheet + CLASS_ICON_TCOORDS.
function API.SetClassIcon(tex, classFile)
    if not tex or type(classFile) ~= "string" then
        if tex then tex:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark"); tex:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
        return
    end
    local atlas = "classicon-" .. classFile:lower()
    local CT = G("C_Texture")
    if CT and CT.GetAtlasInfo then
        local ok, info = pcall(CT.GetAtlasInfo, atlas)
        if ok and info then
            tex:SetTexCoord(0, 1, 0, 1)
            tex:SetAtlas(atlas)
            return
        end
    end
    local coords = G("CLASS_ICON_TCOORDS")
    coords = coords and coords[classFile]
    tex:SetTexture("Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES")
    if coords then
        tex:SetTexCoord(coords[1] + 0.015, coords[2] - 0.015, coords[3] + 0.015, coords[4] - 0.015)
    else
        tex:SetTexCoord(0, 1, 0, 1)
    end
end

-------------------------------------------------------------------------------
-- Items
-------------------------------------------------------------------------------
local function isItemArg(v)
    if type(v) == "number" then return v > 0 end
    return type(v) == "string" and v ~= ""
end

--- ItemInfo(id|link) -> name, link, quality, ilvl, minLevel, type, subType, stack, equipLoc, icon, sell, classID, subclassID ...
-- nothing when uncached (GET_ITEM_INFO_RECEIVED follows a RequestItem).
function API.ItemInfo(item)
    if not isItemArg(item) then return end
    local CI = G("C_Item")
    local f = (CI and CI.GetItemInfo) or G("GetItemInfo")
    if not f then return end
    local res = pack(pcall(f, item))
    if not res[1] then return end
    return unpack(res, 2, res.n)
end

function API.ItemInfoInstant(item)
    if not isItemArg(item) then return end
    local CI = G("C_Item")
    local f = (CI and CI.GetItemInfoInstant) or G("GetItemInfoInstant")
    if not f then return end
    local res = pack(pcall(f, item))
    if not res[1] then return end
    return unpack(res, 2, res.n)
end

function API.ItemName(item)
    local name = API.ItemInfo(item)
    return name
end

function API.ItemIcon(item)
    local _, _, _, _, icon = API.ItemInfoInstant(item)
    return icon or 134400 -- question mark
end

function API.ItemQuality(item)
    local _, _, q = API.ItemInfo(item)
    return API.CleanNumber(q)
end

function API.ItemLink(item)
    local _, link = API.ItemInfo(item)
    return link
end

--- ItemID from an item link, "item:123" string, or number.
function API.ItemID(item)
    if type(item) == "number" then
        if not Readable(item) then return nil end
        return item > 0 and floor(item) or nil
    end
    if type(item) ~= "string" or not Readable(item) then return nil end
    local id = item:match("item:(%d+)")
    if id then return tonumber(id) end
    if item:match("^%d+$") then return tonumber(item) end
    return nil
end

function API.RequestItem(id)
    if type(id) ~= "number" or id <= 0 then return end
    local CI = G("C_Item")
    if CI and CI.RequestLoadItemDataByID then pcall(CI.RequestLoadItemDataByID, id) end
end

function API.QualityColor(q)
    local CI = G("C_Item")
    if type(q) == "number" and CI and CI.GetItemQualityColor then
        local ok, r, g, b = pcall(CI.GetItemQualityColor, q)
        if ok and type(r) == "number" then return r, g, b end
    end
    local t = G("ITEM_QUALITY_COLORS")
    if t and q and t[q] then return t[q].r, t[q].g, t[q].b end
    local fb = { [0] = { .62, .62, .62 }, { 1, 1, 1 }, { .12, 1, 0 }, { 0, .44, .87 }, { .64, .21, .93 }, { 1, .5, 0 } }
    local c = fb[q or 1] or fb[1]
    return c[1], c[2], c[3]
end

function API.ItemCount(itemID, includeBank)
    if type(itemID) ~= "number" or itemID <= 0 then return 0 end
    local CI = G("C_Item")
    local f = (CI and CI.GetItemCount) or G("GetItemCount")
    if not f then return 0 end
    local ok, n = pcall(f, itemID, includeBank and true or false)
    if ok and type(n) == "number" then return n end
    return 0
end

--- Seconds of cooldown left on an item (0 = ready).
function API.ItemCooldownLeft(itemID)
    if type(itemID) ~= "number" or itemID <= 0 then return 0 end
    local CC, CI = G("C_Container"), G("C_Item")
    local f = (CC and CC.GetItemCooldown) or (CI and CI.GetItemCooldown) or G("GetItemCooldown")
    if not f then return 0 end
    local ok, start, duration = pcall(f, itemID)
    if not ok or type(start) ~= "number" or type(duration) ~= "number" or not Readable(start) or not Readable(duration) then return 0 end
    if start == 0 or duration == 0 then return 0 end
    local left = start + duration - API.Time()
    return left > 0 and left or 0
end

--- ItemSpell(item) -> spellName, spellID (the spell cast when the item is used)
function API.ItemSpell(item)
    if not isItemArg(item) then return nil end
    local CI = G("C_Item")
    local f = (CI and CI.GetItemSpell) or G("GetItemSpell")
    if not f then return nil end
    local ok, name, id = pcall(f, item)
    if ok then return API.CleanString(name), API.CleanNumber(id) end
    return nil
end

-------------------------------------------------------------------------------
-- Spells
-------------------------------------------------------------------------------
function API.SpellName(id)
    if type(id) ~= "number" or id <= 0 then return nil end
    local CS = G("C_Spell")
    if CS and CS.GetSpellName then
        local ok, n = pcall(CS.GetSpellName, id)
        if ok and type(n) == "string" and Readable(n) then return n end
    end
    if CS and CS.GetSpellInfo then
        local ok, info = pcall(CS.GetSpellInfo, id)
        if ok and type(info) == "table" and type(info.name) == "string" and Readable(info.name) then return info.name end
    end
    local gsi = G("GetSpellInfo")
    if gsi then
        local ok, n = pcall(gsi, id)
        if ok and type(n) == "string" and Readable(n) then return n end
    end
    return nil
end

function API.SpellIcon(id)
    if type(id) ~= "number" or id <= 0 then return 134400 end
    local CS = G("C_Spell")
    if CS and CS.GetSpellTexture then
        local ok, t = pcall(CS.GetSpellTexture, id)
        if ok and t then return t end
    end
    if CS and CS.GetSpellInfo then
        local ok, info = pcall(CS.GetSpellInfo, id)
        if ok and type(info) == "table" and info.iconID then return info.iconID end
    end
    local gst = G("GetSpellTexture")
    if gst then
        local ok, t = pcall(gst, id)
        if ok and t then return t end
    end
    return 134400
end

--- Knows(spellID): is this spell (incl. recipe spells and talents) known by the player?
-- IsPlayerSpell is proven on Forever with every window shut.
function API.Knows(id)
    if type(id) ~= "number" or id <= 0 then return false end
    local ips = G("IsPlayerSpell")
    if ips then
        local ok, r = pcall(ips, id)
        if ok and r then return true end
    end
    local CSB = G("C_SpellBook")
    if CSB and CSB.IsSpellKnown then
        local ok, r = pcall(CSB.IsSpellKnown, id)
        if ok and r then return true end
    end
    local isk = G("IsSpellKnown")
    if isk then
        local ok, r = pcall(isk, id)
        if ok and r then return true end
    end
    return false
end

-------------------------------------------------------------------------------
-- Auras (readable out of combat only on Forever)
-------------------------------------------------------------------------------
function API.AurasSecret()
    local CS = G("C_Secrets")
    if CS and CS.ShouldAurasBeSecret then
        local ok, r = pcall(CS.ShouldAurasBeSecret)
        if ok then return r and true or false end
    end
    return false
end

--- ForEachBuff(unit, fn): fn(spellId, name, auraTable) for every readable buff; return
-- true from fn to stop early. Returns false if auras are currently unreadable.
function API.ForEachBuff(unit, fn)
    if type(unit) ~= "string" or API.AurasSecret() then return false end
    local CU = G("C_UnitAuras")
    local getter
    if CU and CU.GetBuffDataByIndex then
        getter = function(i) return CU.GetBuffDataByIndex(unit, i) end
    elseif CU and CU.GetAuraDataByIndex then
        getter = function(i) return CU.GetAuraDataByIndex(unit, i, "HELPFUL") end
    end
    if getter then
        for i = 1, 80 do
            local ok, a = pcall(getter, i)
            if not ok or type(a) ~= "table" then break end
            local sid, name = a.spellId, a.name
            if Readable(sid) and Readable(name) then
                if fn(sid, name, a) then return true end
            end
        end
        return true
    end
    local ub = G("UnitBuff")
    if ub then
        for i = 1, 80 do
            local ok, name, _, _, _, _, _, _, _, _, sid = pcall(ub, unit, i)
            if not ok or not name then break end
            if Readable(sid) and Readable(name) then
                if fn(sid, name, nil) then return true end
            end
        end
        return true
    end
    return false
end

--- PlayerHasAura(spellID) - works for hidden auras too where the client allows it.
function API.PlayerHasAura(spellID)
    if type(spellID) ~= "number" then return false end
    local CU = G("C_UnitAuras")
    if CU and CU.GetPlayerAuraBySpellID then
        local ok, a = pcall(CU.GetPlayerAuraBySpellID, spellID)
        if ok and a then return true end
        if ok then return false end
    end
    local found = false
    API.ForEachBuff("player", function(sid) if sid == spellID then found = true return true end end)
    return found
end

-------------------------------------------------------------------------------
-- Instance / group
-------------------------------------------------------------------------------
--- InstanceInfo() -> {name, type ("none","party","raid","pvp","arena"), difficulty, maxPlayers, id}
function API.InstanceInfo()
    local f = G("GetInstanceInfo")
    if not f then return { type = "none" } end
    local ok, name, itype, diff, _, maxPlayers, _, _, id = pcall(f)
    if not ok then return { type = "none" } end
    return {
        name = Readable(name) and name or nil,
        type = Readable(itype) and itype or "none",
        difficulty = Readable(diff) and diff or nil,
        maxPlayers = Readable(maxPlayers) and maxPlayers or nil,
        id = Readable(id) and id or nil,
    }
end

function API.InRaidInstance() return API.InstanceInfo().type == "raid" end

function API.InRaid() return boolCall("IsInRaid") end

function API.InGroup()
    local f = G("IsInGroup")
    if not f then return false end
    local ok, r = pcall(f)
    return ok and r and true or false
end

--- The addon/chat channel for the current group, or nil when solo.
function API.GroupChannel()
    local inGroup = G("IsInGroup")
    local cat = G("LE_PARTY_CATEGORY_INSTANCE")
    if inGroup and cat then
        local ok, r = pcall(inGroup, cat)
        if ok and r then return "INSTANCE_CHAT" end
    end
    if API.InRaid() then return "RAID" end
    if API.InGroup() then return "PARTY" end
    return nil
end

function API.NumGroupMembers()
    local f = G("GetNumGroupMembers")
    if not f then return 0 end
    local ok, n = pcall(f)
    return ok and type(n) == "number" and n or 0
end

--- GroupMembers() -> list of {unit, name, key, class, level, subgroup, rank(0/1/2), online, dead, isML, role}
-- Always includes the player. Secret entries are skipped.
function API.GroupMembers()
    local out = {}
    if API.InRaid() then
        local f = G("GetRaidRosterInfo")
        for i = 1, API.NumGroupMembers() do
            if f then
                local ok, name, rank, subgroup, level, _, classFile, _, online, isDead, role, isML = pcall(f, i)
                if ok and type(name) == "string" and Readable(name) then
                    out[#out + 1] = {
                        unit = "raid" .. i, name = name, key = API.Key(name),
                        class = Readable(classFile) and classFile or nil,
                        level = Readable(level) and level or 0,
                        subgroup = Readable(subgroup) and subgroup or 1,
                        rank = Readable(rank) and rank or 0,
                        online = Readable(online) and online and true or false,
                        dead = Readable(isDead) and isDead and true or false,
                        isML = Readable(isML) and isML and true or false,
                        role = Readable(role) and role or nil,
                    }
                end
            end
        end
    else
        local units = { "player" }
        if API.InGroup() then for i = 1, 4 do units[#units + 1] = "party" .. i end end
        for _, u in ipairs(units) do
            if API.UnitExists(u) then
                local name = API.UnitName(u)
                if name then
                    out[#out + 1] = {
                        unit = u, name = name, key = API.Key(name), class = API.UnitClassFile(u),
                        level = API.UnitLevel(u), subgroup = 1,
                        rank = API.IsGroupLeader(u) and 2 or 0,
                        online = u == "player" or API.UnitIsConnected(u),
                        dead = API.UnitIsDead(u),
                    }
                end
            end
        end
    end
    return out
end

function API.CanLeadGroup()
    if not API.InGroup() then return false end
    return API.IsGroupLeader("player") or API.IsGroupAssistant("player")
end

function API.Invite(name)
    if type(name) ~= "string" then return false end
    local CP = G("C_PartyInfo")
    local f = (CP and CP.InviteUnit) or G("InviteUnit")
    if not f then return false end
    return pcall(f, name)
end

function API.ConvertToRaid()
    local CP = G("C_PartyInfo")
    local f = (CP and CP.ConvertToRaid) or G("ConvertToRaid")
    if f then pcall(f) end
end

function API.SetRaidSubgroup(raidIndex, group)
    local f = G("SetRaidSubgroup")
    if not f or type(raidIndex) ~= "number" or type(group) ~= "number" then return false end
    return pcall(f, raidIndex, group)
end

function API.SwapRaidSubgroup(a, b)
    local f = G("SwapRaidSubgroup")
    if not f or type(a) ~= "number" or type(b) ~= "number" then return false end
    return pcall(f, a, b)
end

-------------------------------------------------------------------------------
-- Guild
-------------------------------------------------------------------------------
function API.InGuild() return boolCall("IsInGuild") end

--- GuildInfo() -> guildName, rankName, rankIndex (0 = GM)
function API.GuildInfo()
    local f = G("GetGuildInfo")
    if not f then return nil end
    local ok, gname, rankName, rankIndex = pcall(f, "player")
    if not ok or type(gname) ~= "string" or not Readable(gname) then return nil end
    return gname, Readable(rankName) and rankName or nil, Readable(rankIndex) and rankIndex or nil
end

function API.RequestGuildRoster()
    local CG = G("C_GuildInfo")
    if CG and CG.GuildRoster then pcall(CG.GuildRoster) return end
    local f = G("GuildRoster")
    if f then pcall(f) end
end

--- GuildMembers() -> list of {name, key, rankName, rankIndex, level, class, zone, note, officerNote, online, guid, mobile}
function API.GuildMembers()
    local out = {}
    local num = G("GetNumGuildMembers")
    local info = G("GetGuildRosterInfo")
    if not num or not info then return out end
    local ok, total = pcall(num)
    if not ok or type(total) ~= "number" then return out end
    for i = 1, total do
        local ok2, name, rankName, rankIndex, level, _, zone, note, officerNote, online, _, classFile, _, _, isMobile, _, _, guid = pcall(info, i)
        if ok2 and type(name) == "string" and Readable(name) then
            out[#out + 1] = {
                index = i,
                name = name,
                key = API.Key(name),
                rankName = Readable(rankName) and rankName or "",
                rankIndex = Readable(rankIndex) and rankIndex or 99,
                level = Readable(level) and level or 0,
                class = Readable(classFile) and classFile or nil,
                zone = Readable(zone) and zone or nil,
                note = Readable(note) and note or "",
                officerNote = Readable(officerNote) and officerNote or "",
                online = Readable(online) and online and true or false,
                mobile = Readable(isMobile) and isMobile and true or false,
                guid = Readable(guid) and guid or nil,
            }
        end
    end
    return out
end

-------------------------------------------------------------------------------
-- Professions (skill levels) - GetProfessions/GetProfessionInfo are the Forever path.
-------------------------------------------------------------------------------
--- Professions() -> list of {skillLine, name, rank, max, icon}
function API.Professions()
    local out = {}
    local gp, gpi = G("GetProfessions"), G("GetProfessionInfo")
    if not gp or not gpi then return out end
    local res = pack(pcall(gp))
    if not res[1] then return out end
    local seen = {}
    for i = 2, res.n do
        local idx = res[i]
        if type(idx) == "number" and not seen[idx] then
            seen[idx] = true
            local ok, name, icon, rank, maxRank, _, _, skillLine = pcall(gpi, idx)
            if ok and type(name) == "string" and Readable(rank) then
                out[#out + 1] = { skillLine = Readable(skillLine) and skillLine or nil, name = name, rank = rank or 0, max = maxRank or 0, icon = icon }
            end
        end
    end
    return out
end

-------------------------------------------------------------------------------
-- Money
-------------------------------------------------------------------------------
function API.Money()
    local f = G("GetMoney")
    if not f then return 0 end
    local ok, m = pcall(f)
    return ok and type(m) == "number" and m or 0
end

-------------------------------------------------------------------------------
-- Chat & addon messages
-------------------------------------------------------------------------------
function API.ChatLockdown()
    local CC = G("C_ChatInfo")
    if CC and CC.InChatMessagingLockdown then
        local ok, r = pcall(CC.InChatMessagingLockdown)
        if ok then return r and true or false end
    end
    return false
end

--- SendChat(text, chatType, target) -> ok. Only call from user actions for SAY/YELL.
function API.SendChat(text, chatType, target)
    if type(text) ~= "string" or text == "" or type(chatType) ~= "string" then return false end
    if API.ChatLockdown() then return false, "lockdown" end
    local CC = G("C_ChatInfo")
    local f = (CC and CC.SendChatMessage) or G("SendChatMessage")
    if not f then return false end
    if #text > 255 then text = text:sub(1, 255) end
    local ok, err = pcall(f, text, chatType, nil, target)
    return ok, err
end

function API.RegisterPrefix(prefix)
    local CC = G("C_ChatInfo")
    local f = (CC and CC.RegisterAddonMessagePrefix) or G("RegisterAddonMessagePrefix")
    if f then pcall(f, prefix) end
end

--- SendAddon(prefix, text, channel, target) -> ok, reason ("throttle" | "lockdown" | "error")
function API.SendAddon(prefix, text, channel, target)
    local CC = G("C_ChatInfo")
    local f = (CC and CC.SendAddonMessage) or G("SendAddonMessage")
    if not f then return false, "error" end
    local ok, res = pcall(f, prefix, text, channel, target)
    if not ok then return false, "error" end
    if res == nil or res == true then return true end
    if res == false then return false, "error" end
    if type(res) == "number" then
        local E = G("Enum") and Enum.SendAddonMessageResult
        local success = E and E.Success or 0
        if res == success then return true end
        local t1 = E and E.AddonMessageThrottle or 3
        local t2 = E and E.ChannelThrottle or 8
        if res == t1 or res == t2 then return false, "throttle" end
        local lock = E and E.AddOnMessageLockdown
        if lock and res == lock then return false, "lockdown" end
        return false, "error"
    end
    return true
end

-------------------------------------------------------------------------------
-- Compression (deflate+base64 via C_EncodingUtil after a self-test)
-------------------------------------------------------------------------------
local zState

local function zUsable()
    if zState ~= nil then return zState end
    zState = false
    local E = G("C_EncodingUtil")
    local Enum_ = G("Enum")
    local method = Enum_ and Enum_.CompressionMethod and Enum_.CompressionMethod.Deflate
    if not (E and E.CompressString and E.DecompressString and E.EncodeBase64 and E.DecodeBase64 and method) then return false end
    local probe = "^{^S4:test^S20:greenfields-selftest!^}"
    local ok, back = pcall(function()
        return E.DecompressString(E.DecodeBase64(E.EncodeBase64(E.CompressString(probe, method))), method)
    end)
    zState = (ok and back == probe) and true or false
    return zState
end

function API.CanCompress() return zUsable() end

function API.Compress(text)
    if not zUsable() then return nil end
    local E = C_EncodingUtil
    local ok, b64 = pcall(function() return E.EncodeBase64(E.CompressString(text, Enum.CompressionMethod.Deflate)) end)
    if ok and type(b64) == "string" then return b64 end
    return nil
end

function API.Decompress(b64)
    if not zUsable() or type(b64) ~= "string" then return nil end
    local E = C_EncodingUtil
    local ok, text = pcall(function() return E.DecompressString(E.DecodeBase64(b64), Enum.CompressionMethod.Deflate) end)
    if ok and type(text) == "string" then return text end
    return nil
end

-------------------------------------------------------------------------------
-- Misc UI helpers
-------------------------------------------------------------------------------
function API.PlaySound(kit)
    if not kit then return end
    local f = G("PlaySound")
    if type(kit) == "string" then
        local SK = G("SOUNDKIT")
        kit = SK and SK[kit]
    end
    if f and type(kit) == "number" then pcall(f, kit, "Master") end
end

function API.PlaySoundFile(path)
    local f = G("PlaySoundFile")
    if f and path then pcall(f, path, "Master") end
end

function API.AddOnMeta(field)
    local CA = G("C_AddOns")
    local f = (CA and CA.GetAddOnMetadata) or G("GetAddOnMetadata")
    if not f then return nil end
    local ok, v = pcall(f, GF.ADDON, field)
    return ok and v or nil
end

--- TooltipPostCall("Item"|"Unit", fn(tooltip, data)) using TooltipDataProcessor when
-- present (hooking OnTooltipSetUnit raises on this client).
function API.TooltipPostCall(kind, fn)
    local TDP = G("TooltipDataProcessor")
    local E = G("Enum")
    local tt = E and E.TooltipDataType and E.TooltipDataType[kind]
    if TDP and TDP.AddTooltipPostCall and tt ~= nil then
        TDP.AddTooltipPostCall(tt, function(tooltip, data) GF:Safe("tooltip:" .. kind, fn, tooltip, data) end)
        return true
    end
    local script = kind == "Item" and "OnTooltipSetItem" or "OnTooltipSetUnit"
    local gt = G("GameTooltip")
    if gt and gt.HasScript and gt:HasScript(script) then
        gt:HookScript(script, function(self) GF:Safe("tooltip:" .. kind, fn, self, nil) end)
        return true
    end
    return false
end

function API.CursorFocusOnEditBox()
    local f = G("GetCurrentKeyBoardFocus")
    return f and f() or nil
end

function API.IsShiftKeyDown() local f = G("IsShiftKeyDown"); return f and f() and true or false end
function API.IsControlKeyDown() local f = G("IsControlKeyDown"); return f and f() and true or false end
