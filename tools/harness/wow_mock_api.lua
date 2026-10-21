--[[ tools/harness/wow_mock_api.lua  --  WoW-shaped globals that are not game state:
     Lua extensions (strsplit, wipe, bit, degree trig, ...), Mixin / ColorMixin /
     BackdropTemplateMixin, constants and GlobalStrings, Enum, font objects, the
     always-present frames (UIParent, WorldFrame, Minimap, DEFAULT_CHAT_FRAME, GameTooltip,
     ItemRefTooltip, SettingsPanel), frame templates, GameTooltip behaviour and
     TooltipDataProcessor, Settings, C_AddOns, C_Texture, C_EncodingUtil, C_EventUtils,
     hooksecurefunc and the error-handler globals.

     Everything is collected in MOCK.G and copied into _G by MOCK.InstallGlobals(). ]]

local MOCK = ...
local R = MOCK.R
local type, pairs, ipairs, select, tostring, tonumber = R.type, R.pairs, R.ipairs, R.select, R.tostring, R.tonumber
local error, rawget, rawset, setmetatable = R.error, R.rawget, R.rawset, R.setmetatable
local floor, max, min, abs = R.floor, R.max, R.min, R.abs
local format, sub, gsub, find, upper, lower, byte, char = R.format, R.sub, R.gsub, R.find, R.upper, R.lower, R.byte, R.char
local tinsert, tremove, concat, sort = R.insert, R.remove, R.concat, R.sort
local S, ST = MOCK.S, MOCK.ST
local Protect, isSecret = MOCK.Protect, MOCK.IsSecret

local G = {}
MOCK.G = G

local function isNum(v) return type(v) == "number" and v == v end

-------------------------------------------------------------------------------
-- Lua extensions present in the WoW environment
-------------------------------------------------------------------------------
G.time = MOCK.time
G.date = MOCK.date
G.difftime = function(a, b) return (a or 0) - (b or 0) end
G.random = MOCK.random
G.fastrandom = MOCK.random
G.floor, G.ceil, G.abs, G.max, G.min, G.sqrt = math.floor, math.ceil, math.abs, math.max, math.min, math.sqrt
G.exp, G.log, G.log10, G.frexp, G.ldexp = math.exp, math.log, math.log10, math.frexp, math.ldexp
G.mod = math.fmod
G.deg, G.rad = math.deg, math.rad
G.PI = math.pi
-- WoW's global trig works in degrees
G.sin = function(d) return math.sin(math.rad(d)) end
G.cos = function(d) return math.cos(math.rad(d)) end
G.tan = function(d) return math.tan(math.rad(d)) end
G.asin = function(v) return math.deg(math.asin(v)) end
G.acos = function(v) return math.deg(math.acos(v)) end
G.atan = function(v) return math.deg(math.atan(v)) end
G.atan2 = function(y, x) return math.deg(math.atan2(y, x)) end
G.gcinfo = gcinfo

local function wipe(t)
    if type(t) ~= "table" then error("bad argument #1 to 'wipe' (table expected, got " .. type(t) .. ")", 2) end
    for k in pairs(t) do t[k] = nil end
    return t
end
G.wipe = wipe
table.wipe = wipe

local function strsplit(delim, str, pieces)
    if type(delim) ~= "string" or type(str) ~= "string" then
        error("bad argument to 'strsplit' (Usage: strsplit(delimiter, string[, pieces]))", 2)
    end
    local out = {}
    local set = {}
    for i = 1, #delim do set[byte(delim, i)] = true end
    local start = 1
    for i = 1, #str do
        if set[byte(str, i)] and (not pieces or #out < pieces - 1) then
            out[#out + 1] = sub(str, start, i - 1)
            start = i + 1
        end
    end
    out[#out + 1] = sub(str, start)
    return R.unpack(out)
end
G.strsplit = strsplit
G.strsplittable = function(delim, str, pieces) return { strsplit(delim, str, pieces) } end
local function strjoin(delim, ...)
    if type(delim) ~= "string" then error("bad argument #1 to 'strjoin' (string expected)", 2) end
    local n = select("#", ...)
    local t = {}
    for i = 1, n do
        local v = select(i, ...)
        if type(v) ~= "string" and not isNum(v) then error("bad argument #" .. (i + 1) .. " to 'strjoin' (string expected, got " .. type(v) .. ")", 2) end
        t[i] = v
    end
    return concat(t, delim)
end
G.strjoin = strjoin
local function strtrim(str, chars)
    if type(str) ~= "string" then error("bad argument #1 to 'strtrim' (string expected, got " .. type(str) .. ")", 2) end
    chars = chars or " \t\r\n"
    local set = {}
    for i = 1, #chars do set[byte(chars, i)] = true end
    local a, b = 1, #str
    while a <= b and set[byte(str, a)] do a = a + 1 end
    while b >= a and set[byte(str, b)] do b = b - 1 end
    return sub(str, a, b)
end
G.strtrim = strtrim
G.strconcat = function(...) local t = { ... } for i = 1, select("#", ...) do t[i] = tostring(t[i]) end return concat(t) end
G.strlenutf8 = function(s) return MOCK.utf8len(s) end
G.strcmputf8i = function(a, b) a, b = lower(a), lower(b) if a == b then return 0 end return a < b and -1 or 1 end
G.strlen, G.strsub, G.strupper, G.strlower = string.len, string.sub, string.upper, string.lower
G.strfind, G.strmatch, G.gmatch, G.gsub = string.find, string.match, string.gmatch, string.gsub
G.strbyte, G.strchar, G.strrep, G.strrev = string.byte, string.char, string.rep, string.reverse
G.format = string.format
G.tinsert, G.tremove, G.sort = table.insert, table.remove, table.sort
G.foreach, G.foreachi, G.getn = table.foreach, table.foreachi, table.getn
string.split = strsplit
string.join = strjoin
string.trim = strtrim
G.tostringall = function(...) local t = { ... } for i = 1, select("#", ...) do t[i] = tostring(t[i]) end return R.unpack(t, 1, select("#", ...)) end
G.scrub = function(...) return ... end

-- bit library (32-bit, as the client's)
local function tobit(x) x = floor(x or 0) % 4294967296 if x >= 2147483648 then x = x - 4294967296 end return x end
local function u32(x) return floor(x or 0) % 4294967296 end
local function bitop(a, b, f)
    a, b = u32(a), u32(b)
    local r, p = 0, 1
    for _ = 1, 32 do
        local x, y = a % 2, b % 2
        if f(x, y) then r = r + p end
        a, b, p = floor(a / 2), floor(b / 2), p * 2
    end
    return tobit(r)
end
G.bit = {
    band = function(a, b, ...) local r = bitop(a, b, function(x, y) return x == 1 and y == 1 end) if ... then return G.bit.band(r, ...) end return r end,
    bor = function(a, b, ...) local r = bitop(a, b or 0, function(x, y) return x == 1 or y == 1 end) if ... then return G.bit.bor(r, ...) end return r end,
    bxor = function(a, b, ...) local r = bitop(a, b or 0, function(x, y) return x ~= y end) if ... then return G.bit.bxor(r, ...) end return r end,
    bnot = function(a) return tobit(4294967295 - u32(a)) end,
    lshift = function(a, n) return tobit(u32(a) * 2 ^ (n % 32)) end,
    rshift = function(a, n) return tobit(floor(u32(a) / 2 ^ (n % 32))) end,
    arshift = function(a, n) a = tobit(a) return tobit(floor(a / 2 ^ (n % 32))) end,
    mod = function(a, b) return math.fmod(a, b) end,
    tobit = tobit,
}

-- print goes to the chat frame, as in the client
G.print = function(...)
    local t = {}
    for i = 1, select("#", ...) do t[i] = R.tostring((select(i, ...))) end
    local cf = rawget(_G, "DEFAULT_CHAT_FRAME")
    if cf then cf:AddMessage(concat(t, " ")) end
end

-------------------------------------------------------------------------------
-- Errors, debugging, security
-------------------------------------------------------------------------------
local function defaultErrorHandler(err)
    MOCK.RecordError("errorhandler", "geterrorhandler()", err, MOCK.traceback(2, 12))
    return err
end
G.geterrorhandler = function() return MOCK.GetUserErrorHandler() or defaultErrorHandler end
G.seterrorhandler = function(fn)
    if type(fn) ~= "function" then error("Usage: seterrorhandler(errfunc)", 2) end
    MOCK.SetUserErrorHandler(fn)
end
G.debugstack = function(start, count1, count2)
    local tb = MOCK.traceback((start or 1) + 1, (count1 or 12) + (count2 or 10))
    return tb .. "\n"
end
G.debuglocals = function() return "" end
G.debugprofilestart = function() MOCK.profileStart = MOCK.uptime end
G.debugprofilestop = function() return ((MOCK.uptime or 0) - (MOCK.profileStart or 0)) * 1000 end
G.GetTimePreciseSec = function() return MOCK.uptime end
G.issecure = function() return false end
G.issecurevariable = function() return false, "Greenfields" end
G.forceinsecure = function() end
G.securecall = function(fn, ...)
    if type(fn) == "string" then fn = rawget(_G, fn) end
    if type(fn) ~= "function" then error("securecall(): function expected", 2) end
    return select(2, Protect("securecall", "securecall", fn, ...))
end
G.securecallfunction = G.securecall
G.secureexecuterange = function(t, fn, ...) for k, v in pairs(t) do Protect("securecall", "secureexecuterange", fn, k, v, ...) end end
G.issecretvalue = function(v) return isSecret(v) end
G.canaccessvalue = function(v) return not isSecret(v) end
G.issecrettable = function(t) return false end
G.canaccesstable = function(t) return true end
G.scrubsecretvalues = function(...)
    local t = MOCK.packn(...)
    for i = 1, t.n do if isSecret(t[i]) then t[i] = nil end end
    return R.unpack(t, 1, t.n)
end
G.hooksecurefunc = function(a, b, c)
    local tbl, name, fn
    if type(a) == "table" then tbl, name, fn = a, b, c else tbl, name, fn = _G, a, b end
    if type(name) ~= "string" or type(fn) ~= "function" then error("Usage: hooksecurefunc([table,] \"functionName\", hookfunc)", 2) end
    local orig = rawget(tbl, name)
    if orig == nil and type(tbl) == "table" then orig = tbl[name] end
    if type(orig) ~= "function" then error("hooksecurefunc(): " .. name .. " is not a function", 2) end
    rawset(tbl, name, function(...)
        local res = MOCK.packn(orig(...))
        Protect("hook", "hooksecurefunc " .. name, fn, ...)
        return R.unpack(res, 1, res.n)
    end)
end

-------------------------------------------------------------------------------
-- Mixins and colours
-------------------------------------------------------------------------------
local function Mixin(object, ...)
    if type(object) ~= "table" then error("Mixin(): object must be a table", 2) end
    for i = 1, select("#", ...) do
        local m = select(i, ...)
        if type(m) ~= "table" then error("Mixin(): mixin #" .. i .. " must be a table", 2) end
        for k, v in pairs(m) do object[k] = v end
    end
    return object
end
G.Mixin = Mixin
G.CreateFromMixins = function(...) return Mixin({}, ...) end
G.CreateAndInitFromMixin = function(m, ...) local o = Mixin({}, m) if o.Init then o:Init(...) end return o end

local ColorMixin = {}
function ColorMixin:OnLoad(r, g, b, a) self:SetRGBA(r, g, b, a) end
function ColorMixin:SetRGBA(r, g, b, a) self.r, self.g, self.b, self.a = r, g, b, a end
function ColorMixin:SetRGB(r, g, b) self:SetRGBA(r, g, b, nil) end
function ColorMixin:GetRGB() return self.r, self.g, self.b end
function ColorMixin:GetRGBA() return self.r, self.g, self.b, self.a or 1 end
function ColorMixin:GetRGBAsBytes() return floor(self.r * 255 + 0.5), floor(self.g * 255 + 0.5), floor(self.b * 255 + 0.5) end
function ColorMixin:GetRGBAAsBytes() local r, g, b = self:GetRGBAsBytes() return r, g, b, floor((self.a or 1) * 255 + 0.5) end
function ColorMixin:IsRGBEqualTo(o) return self.r == o.r and self.g == o.g and self.b == o.b end
function ColorMixin:IsEqualTo(o) return self:IsRGBEqualTo(o) and (self.a or 1) == (o.a or 1) end
function ColorMixin:GenerateHexColor() return format("ff%02x%02x%02x", self:GetRGBAsBytes()) end
function ColorMixin:GenerateHexColorNoAlpha() return format("%02x%02x%02x", self:GetRGBAsBytes()) end
function ColorMixin:GenerateHexColorMarkup() return "|c" .. self:GenerateHexColor() end
function ColorMixin:WrapTextInColorCode(text) return "|c" .. self:GenerateHexColor() .. tostring(text) .. "|r" end
G.ColorMixin = ColorMixin
local function CreateColor(r, g, b, a)
    local c = Mixin({}, ColorMixin)
    c:SetRGBA(r, g, b, a)
    return c
end
G.CreateColor = CreateColor
MOCK.CreateColor = CreateColor
G.CreateColorFromHexString = function(hex)
    if type(hex) ~= "string" or #hex ~= 8 then return nil end
    local a, r, g, b = tonumber(sub(hex, 1, 2), 16), tonumber(sub(hex, 3, 4), 16), tonumber(sub(hex, 5, 6), 16), tonumber(sub(hex, 7, 8), 16)
    return CreateColor(r / 255, g / 255, b / 255, a / 255)
end
G.CreateColorFromRGBHexString = function(hex) return G.CreateColorFromHexString("ff" .. hex) end
G.WrapTextInColorCode = function(text, hex) return "|c" .. hex .. tostring(text) .. "|r" end
G.WrapTextInColor = function(text, color) return color:WrapTextInColorCode(text) end
G.CreateTextureMarkup = function(file, fw, fh, w, h, l, r, t, b, x, y)
    return format("|T%s:%d:%d:%d:%d:%d:%d:%d:%d:%d:%d|t", tostring(file), h or 0, w or 0, x or 0, y or 0, fw or 0, fh or 0, (l or 0) * (fw or 0), (r or 1) * (fw or 0), (t or 0) * (fh or 0), (b or 1) * (fh or 0))
end
G.CreateAtlasMarkup = function(atlas, w, h) return format("|A:%s:%d:%d|a", tostring(atlas), h or 0, w or 0) end
G.CreateSimpleTextureMarkup = function(file, w, h) return format("|T%s:%d:%d|t", tostring(file), h or 0, w or 0) end

-- FrameXML table/number helpers
G.CopyTable = function(t, seen)
    local function cp(x, s)
        if type(x) ~= "table" then return x end
        if s[x] then return s[x] end
        local c = {}
        s[x] = c
        for k, v in pairs(x) do c[cp(k, s)] = cp(v, s) end
        return c
    end
    return cp(t, seen or {})
end
G.tContains = function(t, v) for _, x in pairs(t) do if x == v then return true end end return false end
G.tIndexOf = function(t, v) for i = 1, #t do if t[i] == v then return i end end return nil end
G.tInvert = function(t) local o = {} for k, v in pairs(t) do o[v] = k end return o end
G.tDeleteItem = function(t, v) local n = 0 for i = #t, 1, -1 do if t[i] == v then tremove(t, i) n = n + 1 end end return n end
G.tAppendAll = function(t, src) for i = 1, #src do t[#t + 1] = src[i] end end
G.tUnorderedRemove = function(t, i) t[i] = t[#t]; t[#t] = nil end
G.GetOrCreateTableEntry = function(t, k, d) local v = t[k] if v == nil then v = d or {} t[k] = v end return v end
G.Clamp = function(v, lo, hi) return min(hi, max(lo, v)) end
G.Saturate = function(v) return min(1, max(0, v)) end
G.Lerp = function(a, b, t) return a + (b - a) * t end
G.Round = function(v) return floor(v + 0.5) end
G.BreakUpLargeNumbers = function(n)
    n = floor(tonumber(n) or 0)
    local s = tostring(abs(n))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    if sub(out, 1, 1) == "," then out = sub(out, 2) end
    return (n < 0 and "-" or "") .. out
end
G.FormatLargeNumber = G.BreakUpLargeNumbers
G.AbbreviateNumbers = function(n)
    n = tonumber(n) or 0
    if n >= 1e6 then return format("%.1fM", n / 1e6) end
    if n >= 1e3 then return format("%.1fK", n / 1e3) end
    return tostring(floor(n))
end
G.AbbreviateLargeNumbers = G.AbbreviateNumbers
G.SecondsToTime = function(sec)
    sec = floor(tonumber(sec) or 0)
    local d, h, m, s = floor(sec / 86400), floor(sec / 3600) % 24, floor(sec / 60) % 60, sec % 60
    local parts = {}
    if d > 0 then parts[#parts + 1] = d .. " Day" .. (d > 1 and "s" or "") end
    if h > 0 then parts[#parts + 1] = h .. " Hr" end
    if m > 0 then parts[#parts + 1] = m .. " Min" end
    if s > 0 or #parts == 0 then parts[#parts + 1] = s .. " Sec" end
    return concat(parts, " ")
end
local function coinString(copper, icons)
    copper = floor(tonumber(copper) or 0)
    local g, s, c = floor(copper / 10000), floor(copper / 100) % 100, copper % 100
    local t = {}
    if g > 0 then t[#t + 1] = icons and (G.BreakUpLargeNumbers(g) .. "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t") or (g .. "g") end
    if s > 0 then t[#t + 1] = icons and (s .. "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t") or (s .. "s") end
    if c > 0 or #t == 0 then t[#t + 1] = icons and (c .. "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t") or (c .. "c") end
    return concat(t, " ")
end
G.GetMoneyString = function(copper) return coinString(copper, true) end
G.GetCoinTextureString = function() return "" end   -- present but answers nothing on Forever (FACTS A.15)
G.GetCoinText = function(copper) return coinString(copper, false) end
G.C_CurrencyInfo = {
    GetCoinTextureString = function(copper) return coinString(copper, true) end,
    GetCoinText = function(copper) return coinString(copper, false) end,
    GetCurrencyInfo = function() return nil end,
}

-------------------------------------------------------------------------------
-- Enum
-------------------------------------------------------------------------------
G.Enum = {
    SendAddonMessageResult = { Success = 0, InvalidPrefix = 1, InvalidMessage = 2, AddonMessageThrottle = 3,
        InvalidChatType = 4, NotInGroup = 5, TargetRequired = 6, InvalidChannel = 7, ChannelThrottle = 8,
        GeneralError = 9, NotInGuild = 10, AddOnMessageLockdown = 11, TargetOffline = 12 },
    RegisterAddonMessagePrefixResult = { Success = 0, DuplicatePrefix = 1, InvalidPrefix = 2, MaxPrefixes = 3 },
    TooltipDataType = { Item = 0, Spell = 1, Unit = 2, Corpse = 3, Object = 4, Currency = 5, BattlePet = 6,
        UnitAura = 7, AzeriteEssence = 8, CompanionPet = 9, Mount = 10, PetAction = 11, Achievement = 12,
        EnhancedConduit = 13, EquipmentSet = 14, InstanceLock = 15, PvPBrawl = 16, RecipeRankInfo = 17,
        Totem = 18, Toy = 19, CorruptionCleanser = 20, MinimapMouseover = 21, Flyout = 22, Quest = 23,
        QuestPartyProgress = 24, Macro = 25, Debug = 26 },
    CompressionMethod = { Deflate = 0, Zlib = 1, Gzip = 2 },
    CompressionLevel = { Default = 0, OptimizeForSpeed = 1, OptimizeForSize = 2 },
    Base64Variant = { Standard = 0, StandardUrlSafe = 1 },
    UITextureSliceMode = { Stretched = 0, Tiled = 1 },
    LootSlotType = { None = 0, Item = 1, Money = 2, Currency = 3 },
    LootMethod = { Freeforall = 0, Roundrobin = 1, Masterlooter = 2, Group = 3, Needbeforegreed = 4, Personal = 5 },
    ItemQuality = { Poor = 0, Common = 1, Standard = 1, Uncommon = 2, Good = 2, Rare = 3, Superior = 3, Epic = 4,
        Legendary = 5, Artifact = 6, Heirloom = 7, WoWToken = 8 },
    ItemClass = { Consumable = 0, Container = 1, Weapon = 2, Gem = 3, Armor = 4, Reagent = 5, Projectile = 6,
        Tradegoods = 7, ItemEnhancement = 8, Recipe = 9, CurrencyTokenObsolete = 10, Quiver = 11, Questitem = 12,
        Key = 13, PermanentObsolete = 14, Miscellaneous = 15, Glyph = 16, Battlepet = 17, WoWToken = 18, Profession = 19 },
    PlayerInteractionType = { None = 0, TradePartner = 1, Item = 2, Gossip = 3, QuestGiver = 4, Merchant = 5,
        TaxiNode = 6, Trainer = 7, Banker = 8, AlliedRaceDetailsGiver = 9, GuildBanker = 10, Registrar = 11,
        Vendor = 12, PetitionVendor = 13, GuildTabardVendor = 14, TalentMaster = 15, SpecializationMaster = 16,
        MailInfo = 17, SpiritHealer = 18, AreaSpiritHealer = 19, Binder = 20, Auctioneer = 21, StableMaster = 22,
        BattleMaster = 23, Transmogrifier = 24, LFGDungeon = 25, VoidStorageBanker = 26, BlackMarketAuctioneer = 27 },
    AddOnRestrictionType = { Chat = 0, Combat = 1, Encounter = 2, Map = 3, PvPMatch = 4, ChallengeMode = 5 },
    GameRule = { PvPRuleset = 0, RPRuleset = 1, HardcoreRuleset = 2 },
    UnitAuraSortRule = { Default = 0, BigDefensive = 1, Expiration = 2 },
    ChatChannelType = { None = 0, Custom = 1, PrivateParty = 2, PublicParty = 3, Communities = 4 },
}

-------------------------------------------------------------------------------
-- Constants & GlobalStrings
-------------------------------------------------------------------------------
G.WOW_PROJECT_MAINLINE, G.WOW_PROJECT_CLASSIC = 1, 2
G.WOW_PROJECT_CAMELOT = 18
G.WOW_PROJECT_ID = 18
G.LE_PARTY_CATEGORY_HOME, G.LE_PARTY_CATEGORY_INSTANCE = 1, 2
G.NUM_BAG_SLOTS, G.NUM_BANKBAGSLOTS, G.BACKPACK_CONTAINER, G.BANK_CONTAINER = 4, 6, 0, -1
G.NUM_BAG_FRAMES = 4
G.MAX_PARTY_MEMBERS, G.MAX_RAID_MEMBERS, G.MEMBERS_PER_RAID_GROUP = 4, 40, 5
G.STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
G.UNIT_NAME_FONT = "Fonts\\FRIZQT__.TTF"
G.DAMAGE_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
G.NAMEPLATE_FONT = "Fonts\\FRIZQT__.TTF"
G.UNKNOWNOBJECT = "Unknown"
G.UNKNOWN = "Unknown"

local CLASS_DATA = {
    { "WARRIOR", "Warrior", 1, 0.78, 0.61, 0.43, "ffc69b6d", { 0, 0.25, 0, 0.25 } },
    { "PALADIN", "Paladin", 2, 0.96, 0.55, 0.73, "fff48cba", { 0, 0.25, 0.5, 0.75 } },
    { "HUNTER", "Hunter", 3, 0.67, 0.83, 0.45, "ffaad372", { 0, 0.25, 0.25, 0.5 } },
    { "ROGUE", "Rogue", 4, 1.00, 0.96, 0.41, "fffff468", { 0.49609375, 0.7421875, 0, 0.25 } },
    { "PRIEST", "Priest", 5, 1.00, 1.00, 1.00, "ffffffff", { 0.49609375, 0.7421875, 0.25, 0.5 } },
    { "SHAMAN", "Shaman", 7, 0.00, 0.44, 0.87, "ff0070dd", { 0.25, 0.49609375, 0.25, 0.5 } },
    { "MAGE", "Mage", 8, 0.25, 0.78, 0.92, "ff3fc7eb", { 0.25, 0.49609375, 0, 0.25 } },
    { "WARLOCK", "Warlock", 9, 0.53, 0.53, 0.93, "ff8788ee", { 0.7421875, 0.98828125, 0.25, 0.5 } },
    { "DRUID", "Druid", 11, 1.00, 0.49, 0.04, "ffff7c0a", { 0.7421875, 0.98828125, 0, 0.25 } },
}
MOCK.CLASS_DATA = {}
G.RAID_CLASS_COLORS, G.CLASS_ICON_TCOORDS, G.LOCALIZED_CLASS_NAMES_MALE, G.LOCALIZED_CLASS_NAMES_FEMALE = {}, {}, {}, {}
G.CLASS_SORT_ORDER = {}
for _, c in ipairs(CLASS_DATA) do
    local col = CreateColor(c[4], c[5], c[6], 1)
    col.colorStr = c[7]
    G.RAID_CLASS_COLORS[c[1]] = col
    G.CLASS_ICON_TCOORDS[c[1]] = c[8]
    G.LOCALIZED_CLASS_NAMES_MALE[c[1]] = c[2]
    G.LOCALIZED_CLASS_NAMES_FEMALE[c[1]] = c[2]
    G.CLASS_SORT_ORDER[#G.CLASS_SORT_ORDER + 1] = c[1]
    MOCK.CLASS_DATA[c[1]] = { file = c[1], name = c[2], id = c[3] }
end

local QUALITY = { [0] = { 0.62, 0.62, 0.62, "ff9d9d9d" }, { 1, 1, 1, "ffffffff" }, { 0.12, 1, 0, "ff1eff00" },
    { 0, 0.44, 0.87, "ff0070dd" }, { 0.64, 0.21, 0.93, "ffa335ee" }, { 1, 0.5, 0, "ffff8000" },
    { 0.9, 0.8, 0.5, "ffe6cc80" }, { 0, 0.8, 1, "ff00ccff" } }
MOCK.QUALITY = QUALITY
G.ITEM_QUALITY_COLORS = {}
for q, c in pairs(QUALITY) do
    G.ITEM_QUALITY_COLORS[q] = { r = c[1], g = c[2], b = c[3], hex = "|c" .. c[4], color = CreateColor(c[1], c[2], c[3], 1) }
end

G.SOUNDKIT = { IG_MAINMENU_OPTION_CHECKBOX_ON = 856, IG_MAINMENU_OPTION_CHECKBOX_OFF = 857,
    IG_CHARACTER_INFO_TAB = 841, IG_CHARACTER_INFO_OPEN = 839, IG_CHARACTER_INFO_CLOSE = 840,
    IG_MAINMENU_OPTION = 852, IG_MAINMENU_OPEN = 850, IG_MAINMENU_CLOSE = 851, IG_ABILITY_PAGE_TURN = 836,
    UI_BNET_TOAST = 18019, RAID_WARNING = 8959, READY_CHECK = 8960, LOOT_WINDOW_COIN_SOUND = 120,
    IG_QUEST_LIST_OPEN = 875, IG_QUEST_LIST_CLOSE = 876, U_CHAT_SCROLL_BUTTON = 1115, TELL_MESSAGE = 3081,
    IG_PLAYER_INVITE = 880, ALARM_CLOCK_WARNING_3 = 12889, UI_EPICLOOT_TOAST = 31578, LEVELUP = 888,
    UI_LEGENDARY_LOOT_TOAST = 63971, IG_BACKPACK_OPEN = 862, IG_BACKPACK_CLOSE = 863, MONEY_FRAME_OPEN = 891,
    MONEY_FRAME_CLOSE = 892, UI_GARRISON_TOAST_MISSION_COMPLETE = 44294, ACHIEVEMENT_MENU_OPEN = 13832,
    GS_TITLE_OPTION_OK = 798, IG_SPELLBOOK_OPEN = 829, PVP_THROUGH_QUEUE = 8458 }
MOCK.knownSounds = {}
for _, id in pairs(G.SOUNDKIT) do MOCK.knownSounds[id] = true end

local GS = {
    LOOT_ITEM_SELF = "You receive loot: %s.", LOOT_ITEM_SELF_MULTIPLE = "You receive loot: %sx%d.",
    LOOT_ITEM = "%s receives loot: %s.", LOOT_ITEM_MULTIPLE = "%s receives loot: %sx%d.",
    LOOT_ITEM_PUSHED_SELF = "You receive item: %s.", LOOT_ITEM_PUSHED_SELF_MULTIPLE = "You receive item: %sx%d.",
    LOOT_ITEM_PUSHED = "%s receives item: %s.", LOOT_ITEM_PUSHED_MULTIPLE = "%s receives item: %sx%d.",
    LOOT_ITEM_CREATED_SELF = "You create: %s.", LOOT_ITEM_CREATED_SELF_MULTIPLE = "You create: %sx%d.",
    LOOT_ITEM_BONUS_ROLL_SELF = "You receive bonus loot: %s.",
    LOOT_ROLL_WON = "%s won: %s", LOOT_ROLL_YOU_WON = "You won: %s", LOOT_ROLL_ALL_PASSED = "Everyone passed on: %s",
    LOOT_ROLL_NEED = "%s has selected Need for: %s", LOOT_ROLL_GREED = "%s has selected Greed for: %s",
    LOOT_ROLL_PASSED = "%s passed on: %s", LOOT_ROLL_ROLLED_NEED = "Need Roll - %d for %s by %s",
    LOOT_ROLL_ROLLED_GREED = "Greed Roll - %d for %s by %s",
    YOU_LOOT_MONEY = "You loot %s", LOOT_MONEY_SPLIT = "Your share of the loot is %s.",
    RANDOM_ROLL_RESULT = "%s rolls %d (%d-%d)",
    DUEL_WINNER_KNOCKOUT = "%1$s has defeated %2$s in a duel", DUEL_WINNER_RETREAT = "%2$s has fled from %1$s in a duel",
    DRUNK_MESSAGE_SELF1 = "You feel sober again.", DRUNK_MESSAGE_SELF2 = "You feel tipsy.  Whee!",
    DRUNK_MESSAGE_SELF3 = "You feel drunk.  Woah!", DRUNK_MESSAGE_SELF4 = "You feel completely smashed.",
    DRUNK_MESSAGE_ITEM_SELF1 = "You drink the %s and feel sober again.",
    DRUNK_MESSAGE_ITEM_SELF2 = "You drink the %s and feel tipsy.  Whee!",
    DRUNK_MESSAGE_ITEM_SELF3 = "You drink the %s and feel drunk.  Woah!",
    DRUNK_MESSAGE_ITEM_SELF4 = "You drink the %s and feel completely smashed.",
    DRUNK_MESSAGE_OTHER1 = "%s seems to be sobering up.", DRUNK_MESSAGE_OTHER2 = "%s looks tipsy.",
    DRUNK_MESSAGE_OTHER3 = "%s looks drunk.", DRUNK_MESSAGE_OTHER4 = "%s looks completely smashed.",
    ERR_FRIEND_ONLINE_SS = "|Hplayer:%s|h[%s]|h has come online.", ERR_FRIEND_OFFLINE_S = "%s has gone offline.",
    ERR_GUILD_JOIN_S = "%s has joined the guild.", ERR_GUILD_LEAVE_S = "%s has left the guild.",
    ERR_GUILD_REMOVE_SS = "%s has been kicked out of the guild by %s.",
    ERR_GUILD_PROMOTE_SSS = "%s has promoted %s to %s.", ERR_GUILD_DEMOTE_SSS = "%s has demoted %s to %s.",
    ERR_RAID_MEMBER_ADDED_S = "%s has joined the raid group.", ERR_RAID_MEMBER_REMOVED_S = "%s has left the raid group.",
    ERR_JOINED_GROUP_S = "%s joins the party.", ERR_LEFT_GROUP_S = "%s leaves the party.",
    ERR_LEFT_GROUP_YOU = "You leave the group.", ERR_PARTY_CONVERTED_TO_RAID = "Party converted to Raid",
    ERR_NEW_LEADER_S = "%s is now the group leader.", ERR_NEW_LEADER_YOU = "You are now the group leader.",
    ERR_NOT_IN_GROUP = "You aren't in a party.", ERR_NOT_IN_RAID = "You are not in a raid group",
    ERR_QUEST_REWARD_EXP_I = "Experience gained: %d.", ERR_QUEST_REWARD_MONEY_S = "Received %s.",
    ERR_SKILL_UP_SI = "Your skill in %s has increased to %d.",
    ERR_LEARN_RECIPE_S = "You have learned how to create a new item: %s.", ERR_LEARN_SPELL_S = "You have learned a new spell: %s.",
    ERR_ZONE_EXPLORED = "Discovered: %s", ERR_ZONE_EXPLORED_XP = "Discovered %s: %d experience gained",
    ERR_AUCTION_SOLD_S = "A buyer has been found for your auction of %s.", ERR_TRADE_COMPLETE = "Trade complete.",
    ERR_PLAYER_DIED_S = "%s has died.", ERR_DUNGEON_DIFFICULTY_CHANGED_S = "Dungeon difficulty set to %s.",
    ERR_INVITE_PLAYER_S = "You have invited %s to join your group.", ERR_SET_LOOT_GROUP = "Looting set to group loot.",
    ERR_SET_LOOT_MASTER = "Looting set to master looter.", ERR_READY_CHECK_IN_PROGRESS = "A ready check is in progress.",
    ERR_RAID_YOU_LEFT = "You have left the raid group.", ERR_GROUP_DISBANDED = "Your group has been disbanded.",
    MARKED_AFK = "You are now AFK.", MARKED_AFK_MESSAGE = "You are now AFK: %s", CLEARED_AFK = "You are no longer AFK.",
    MARKED_DND = "You are now DND: %s.", CLEARED_DND = "You are no longer marked DND.",
    COMBATLOG_HONORGAIN = "%s dies, honorable kill Rank: %s (Estimated Honor Points: %d)",
    COMBATLOG_HONORGAIN_NO_RANK = "%s dies, honorable kill (Estimated Honor Points: %d)",
    COMBATLOG_HONORAWARD = "You have been awarded %d honor points.",
    COMBATLOG_XPGAIN_FIRSTPERSON = "%s dies, you gain %d experience.",
    GOLD_AMOUNT = "%d Gold", SILVER_AMOUNT = "%d Silver", COPPER_AMOUNT = "%d Copper",
    ITEM_QUALITY0_DESC = "Poor", ITEM_QUALITY1_DESC = "Common", ITEM_QUALITY2_DESC = "Uncommon",
    ITEM_QUALITY3_DESC = "Rare", ITEM_QUALITY4_DESC = "Epic", ITEM_QUALITY5_DESC = "Legendary",
    YES = "Yes", NO = "No", OKAY = "Okay", CANCEL = "Cancel", ACCEPT = "Accept", DECLINE = "Decline", CLOSE = "Close",
    SEARCH = "Search", NONE = "None", GUILD = "Guild", RAID = "Raid", PARTY = "Party", LEVEL = "Level", NAME = "Name",
    CLASS = "Class", ZONE = "Zone", RANK = "Rank", NOTE = "Note", OFFLINE = "Offline", ONLINE = "Online",
    AFK = "AFK", DND = "DND", DEAD = "Dead", TANK = "Tank", HEALER = "Healer", DAMAGER = "Damage",
    GUILD_ONLINE_LABEL = "Online", FRIENDS_LIST_OFFLINE = "Offline", LOOT = "Loot", ROLL = "Roll", NEED = "Need",
    GREED = "Greed", PASS = "Pass", TRADE = "Trade", BOSS = "Boss", ENCOUNTER_JOURNAL_ENCOUNTER = "Encounter",
    HEARTHSTONE = "Hearthstone", PROFESSIONS_TRACKER_HEADER_PROFESSION = "Professions",
    TRADE_SKILLS = "Professions", PRIMARY_SKILLS = "Professions:", SECONDARY_SKILLS = "Secondary Skills:",
    ADDON_ACTION_FORBIDDEN = "%s has been blocked from an action only available to the Blizzard UI.",
    ADDON_ACTION_BLOCKED = "%s tried to call the protected function '%s'.",
    SPELL_FAILED_NOT_IN_CONTROL = "Can't do that while not in control", ERR_NOT_IN_COMBAT = "You can't do that while in combat",
    CHAT_MSG_GUILD = "Guild", CHAT_MSG_RAID = "Raid", CHAT_MSG_PARTY = "Party", CHAT_MSG_WHISPER_INFORM = "To",
    FISHING = "Fishing", COOKING = "Cooking", FIRST_AID = "First Aid",
}
for k, v in pairs(GS) do G[k] = v end

-------------------------------------------------------------------------------
-- Font objects
-------------------------------------------------------------------------------
local function CreateFont(name)
    if name ~= nil and type(name) ~= "string" then error("Usage: CreateFont(\"name\")", 2) end
    if name and rawget(_G, name) and S[rawget(_G, name)] and S[rawget(_G, name)].isFontObject then return rawget(_G, name) end
    local fo = MOCK.NewObject("Font", { isFontObject = true, name = name })
    if name then rawset(_G, name, fo) end
    return fo
end
G.CreateFont = CreateFont
MOCK.CreateFontObject = CreateFont

local FONTS = {
    { "GameFontNormal", "Fonts\\FRIZQT__.TTF", 12, "", { 1, 0.82, 0 } },
    { "GameFontHighlight", "Fonts\\FRIZQT__.TTF", 12, "", { 1, 1, 1 } },
    { "GameFontDisable", "Fonts\\FRIZQT__.TTF", 12, "", { 0.5, 0.5, 0.5 } },
    { "GameFontNormalSmall", "Fonts\\FRIZQT__.TTF", 10, "", { 1, 0.82, 0 } },
    { "GameFontHighlightSmall", "Fonts\\FRIZQT__.TTF", 10, "", { 1, 1, 1 } },
    { "GameFontDisableSmall", "Fonts\\FRIZQT__.TTF", 10, "", { 0.5, 0.5, 0.5 } },
    { "GameFontNormalLarge", "Fonts\\FRIZQT__.TTF", 16, "", { 1, 0.82, 0 } },
    { "GameFontHighlightLarge", "Fonts\\FRIZQT__.TTF", 16, "", { 1, 1, 1 } },
    { "GameFontNormalHuge", "Fonts\\FRIZQT__.TTF", 20, "", { 1, 0.82, 0 } },
    { "GameFontRed", "Fonts\\FRIZQT__.TTF", 12, "", { 1, 0.1, 0.1 } },
    { "GameFontGreen", "Fonts\\FRIZQT__.TTF", 12, "", { 0.1, 1, 0.1 } },
    { "GameFontWhite", "Fonts\\FRIZQT__.TTF", 12, "", { 1, 1, 1 } },
    { "GameFontBlack", "Fonts\\FRIZQT__.TTF", 12, "", { 0, 0, 0 } },
    { "GameFontNormalLeft", "Fonts\\FRIZQT__.TTF", 12, "", { 1, 0.82, 0 } },
    { "GameFontHighlightLeft", "Fonts\\FRIZQT__.TTF", 12, "", { 1, 1, 1 } },
    { "ChatFontNormal", "Fonts\\ARIALN.TTF", 14, "", { 1, 1, 1 } },
    { "ChatFontSmall", "Fonts\\ARIALN.TTF", 12, "", { 1, 1, 1 } },
    { "NumberFontNormal", "Fonts\\ARIALN.TTF", 14, "OUTLINE", { 1, 1, 1 } },
    { "NumberFontNormalSmall", "Fonts\\ARIALN.TTF", 12, "OUTLINE", { 1, 1, 1 } },
    { "GameTooltipText", "Fonts\\FRIZQT__.TTF", 12, "", { 1, 1, 1 } },
    { "GameTooltipTextSmall", "Fonts\\FRIZQT__.TTF", 10, "", { 1, 1, 1 } },
    { "GameTooltipHeaderText", "Fonts\\FRIZQT__.TTF", 14, "", { 1, 1, 1 } },
    { "SystemFont_Shadow_Med1", "Fonts\\FRIZQT__.TTF", 12, "", { 1, 1, 1 } },
    { "SystemFont_Shadow_Large", "Fonts\\FRIZQT__.TTF", 16, "", { 1, 1, 1 } },
    { "SystemFont_Small", "Fonts\\FRIZQT__.TTF", 10, "", { 1, 1, 1 } },
    { "Game12Font", "Fonts\\FRIZQT__.TTF", 12, "", { 1, 1, 1 } },
    { "Game15Font", "Fonts\\FRIZQT__.TTF", 15, "", { 1, 1, 1 } },
    { "QuestFont", "Fonts\\MORPHEUS.TTF", 14, "", { 0.18, 0.12, 0.06 } },
}
function MOCK.CreateStandardFonts()
    for _, f in ipairs(FONTS) do
        local fo = CreateFont(f[1])
        local st = S[fo]
        st.font = { f[2], f[3], f[4] }
        st.textColor = { f[5][1], f[5][2], f[5][3], 1 }
        st.shadowColor = { 0, 0, 0, 1 }
        st.shadowOffset = { 1, -1 }
        st.justifyH = "CENTER"
        st.justifyV = "MIDDLE"
        G[f[1]] = fo
    end
end

-------------------------------------------------------------------------------
-- BackdropTemplateMixin (behaves like the retail Lua mixin: pieces are real textures)
-------------------------------------------------------------------------------
local PIECES = { "TopLeftCorner", "TopRightCorner", "BottomLeftCorner", "BottomRightCorner",
    "TopEdge", "BottomEdge", "LeftEdge", "RightEdge", "Center" }
local EDGE_COORDS = {
    LeftEdge = { 0, 0.125, 0, 1 }, RightEdge = { 0.125, 0.25, 0, 1 }, TopEdge = { 0.25, 0.375, 0, 1 },
    BottomEdge = { 0.375, 0.5, 0, 1 }, TopLeftCorner = { 0.5, 0.625, 0, 1 }, TopRightCorner = { 0.625, 0.75, 0, 1 },
    BottomLeftCorner = { 0.75, 0.875, 0, 1 }, BottomRightCorner = { 0.875, 1, 0, 1 },
}
local Backdrop = {}
function Backdrop:OnBackdropLoaded()
    if self.backdropInfo then
        if not self.backdropInfo.edgeFile and not self.backdropInfo.bgFile then self.backdropInfo = nil return end
        self:ApplyBackdrop()
        if self.backdropColor then
            local r, g, b = self.backdropColor:GetRGB()
            self:SetBackdropColor(r, g, b, self.backdropColorAlpha or 1)
        end
        if self.backdropBorderColor then
            local r, g, b = self.backdropBorderColor:GetRGB()
            self:SetBackdropBorderColor(r, g, b, self.backdropBorderColorAlpha or 1)
        end
        if self.backdropBorderBlendMode then self:SetBorderBlendMode(self.backdropBorderBlendMode) end
    end
end
function Backdrop:OnBackdropSizeChanged()
    if self.backdropInfo then self:SetupTextureCoordinates() end
end
function Backdrop:GetEdgeSize() return (self.backdropInfo and self.backdropInfo.edgeSize) or 39 end
function Backdrop:SetupTextureCoordinates()
    for _, name in ipairs(PIECES) do
        local p = self[name]
        local c = EDGE_COORDS[name]
        if p and c and self.backdropInfo and self.backdropInfo.edgeFile then p:SetTexCoord(c[1], c[2], c[3], c[4]) end
    end
end
function Backdrop:SetupPieceVisuals() end
function Backdrop:SetBorderBlendMode(mode)
    for _, name in ipairs(PIECES) do
        if name ~= "Center" and self[name] then self[name]:SetBlendMode(mode) end
    end
end
function Backdrop:HasBackdropInfo(info) return self.backdropInfo == info end
function Backdrop:ClearBackdrop()
    if self.backdropInfo then
        for _, name in ipairs(PIECES) do if self[name] then self[name]:Hide() end end
    end
    self.backdropInfo = nil
end
function Backdrop:ApplyBackdrop()
    local info = self.backdropInfo
    local e = info.edgeSize or 39
    local ins = info.insets or {}
    for _, name in ipairs(PIECES) do
        local p = self[name]
        local layer = name == "Center" and "BACKGROUND" or "BORDER"
        if not p then
            p = self:CreateTexture(nil, layer, nil, -8)
            self[name] = p
        end
        p:ClearAllPoints()
        local file = (name == "Center") and info.bgFile or info.edgeFile
        if file then
            p:SetTexture(file, name == "Center" and (info.tile and "REPEAT" or nil) or nil, name == "Center" and (info.tile and "REPEAT" or nil) or nil)
            p:Show()
        else
            p:Hide()
        end
    end
    local TL, TR, BL, BR = self.TopLeftCorner, self.TopRightCorner, self.BottomLeftCorner, self.BottomRightCorner
    TL:SetPoint("TOPLEFT", self, "TOPLEFT"); TL:SetSize(e, e)
    TR:SetPoint("TOPRIGHT", self, "TOPRIGHT"); TR:SetSize(e, e)
    BL:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT"); BL:SetSize(e, e)
    BR:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT"); BR:SetSize(e, e)
    self.TopEdge:SetPoint("TOPLEFT", TL, "TOPRIGHT"); self.TopEdge:SetPoint("BOTTOMRIGHT", TR, "BOTTOMLEFT")
    self.BottomEdge:SetPoint("BOTTOMLEFT", BL, "BOTTOMRIGHT"); self.BottomEdge:SetPoint("TOPRIGHT", BR, "TOPLEFT")
    self.LeftEdge:SetPoint("TOPLEFT", TL, "BOTTOMLEFT"); self.LeftEdge:SetPoint("BOTTOMRIGHT", BL, "TOPRIGHT")
    self.RightEdge:SetPoint("TOPRIGHT", TR, "BOTTOMRIGHT"); self.RightEdge:SetPoint("BOTTOMLEFT", BR, "TOPLEFT")
    self.Center:SetPoint("TOPLEFT", self, "TOPLEFT", ins.left or 0, -(ins.top or 0))
    self.Center:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -(ins.right or 0), ins.bottom or 0)
    if info.tile then
        self.Center:SetHorizTile(true)
        self.Center:SetVertTile(true)
    end
    self:SetupTextureCoordinates()
end
function Backdrop:SetBackdrop(info)
    if info then
        if type(info) ~= "table" then error("Usage: SetBackdrop(backdropInfo)", 2) end
        self.backdropInfo = info
        self:ApplyBackdrop()
    else
        self:ClearBackdrop()
    end
end
function Backdrop:GetBackdrop()
    if not self.backdropInfo then return nil end
    local c = {}
    for k, v in pairs(self.backdropInfo) do c[k] = v end
    return c
end
function Backdrop:GetBackdropColor() if self.Center then return self.Center:GetVertexColor() end end
function Backdrop:SetBackdropColor(r, g, b, a) if self.Center then self.Center:SetVertexColor(r, g, b, a or 1) end end
function Backdrop:GetBackdropBorderColor() if self.TopEdge then return self.TopEdge:GetVertexColor() end end
function Backdrop:SetBackdropBorderColor(r, g, b, a)
    if self.TopLeftCorner then
        for _, name in ipairs(PIECES) do
            if name ~= "Center" then self[name]:SetVertexColor(r, g, b, a or 1) end
        end
    end
end
G.BackdropTemplateMixin = Backdrop
G.BACKDROP_TOOLTIP_16_16_5555 = { bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileEdge = true, tileSize = 16, edgeSize = 16, insets = { left = 5, right = 5, top = 5, bottom = 5 } }
G.BACKDROP_DIALOG_32_32 = { bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 32, edgeSize = 32, insets = { left = 11, right = 12, top = 12, bottom = 11 } }

-------------------------------------------------------------------------------
-- Templates (CreateFrame inherits)
-------------------------------------------------------------------------------
local T = MOCK.templates
local function tex(f, layer, file, sub_)
    local t = f:CreateTexture(nil, layer, nil, sub_)
    if file then t:SetTexture(file) end
    return t
end
local function fontStr(f, layer, fontObj)
    local fs = f:CreateFontString(nil, layer, fontObj)
    return fs
end
local function needType(st, kinds, tname)
    for _, k in ipairs(kinds) do if st.T.isa[lower(k)] then return end end
    MOCK.Warn("template", tname .. " inherited by a " .. st.otype .. " (template expects " .. concat(kinds, "/") .. ")", 4)
end

T.BackdropTemplate = function(f)
    Mixin(f, Backdrop)
    f:SetScript("OnSizeChanged", f.OnBackdropSizeChanged)
    f:OnBackdropLoaded()
end
T.TooltipBackdropTemplate = function(f, st)
    T.BackdropTemplate(f, st)
    f.backdropInfo = G.BACKDROP_TOOLTIP_16_16_5555
    f:ApplyBackdrop()
    f:SetBackdropColor(0.09, 0.09, 0.19, 1)
end
T.UIPanelButtonTemplate = function(f, st, kind)
    needType(st, { "Button" }, "UIPanelButtonTemplate")
    f.Left = tex(f, "BACKGROUND", "Interface\\Buttons\\UI-Panel-Button-Up")
    f.Middle = tex(f, "BACKGROUND", "Interface\\Buttons\\UI-Panel-Button-Up")
    f.Right = tex(f, "BACKGROUND", "Interface\\Buttons\\UI-Panel-Button-Up")
    f.Left:SetPoint("TOPLEFT"); f.Left:SetPoint("BOTTOMLEFT"); f.Left:SetWidth(12)
    f.Right:SetPoint("TOPRIGHT"); f.Right:SetPoint("BOTTOMRIGHT"); f.Right:SetWidth(12)
    f.Middle:SetPoint("TOPLEFT", f.Left, "TOPRIGHT"); f.Middle:SetPoint("BOTTOMRIGHT", f.Right, "BOTTOMLEFT")
    if st.isButton then
        f:SetNormalFontObject(G.GameFontNormal)
        f:SetHighlightFontObject(G.GameFontHighlight)
        f:SetDisabledFontObject(G.GameFontDisable)
        local fs = fontStr(f, "OVERLAY", "GameFontNormal")
        fs:SetPoint("CENTER")
        f:SetFontString(fs)
        f.Text = fs
        f:SetHighlightTexture("Interface\\Buttons\\UI-Panel-Button-Highlight", "ADD")
    end
end
T.UIPanelCloseButton = function(f, st)
    needType(st, { "Button" }, "UIPanelCloseButton")
    f:SetSize(32, 32)
    if st.isButton then
        f:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
        f:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
        f:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight", "ADD")
        f:SetScript("OnClick", function(self)
            local p = self:GetParent()
            if p then
                if MOCK.state and MOCK.state.combat then
                    MOCK.NoteForbidden("UIPanelCloseButton -> HideUIPanel in combat", 2)
                else
                    p:Hide()
                end
            end
        end)
    end
end
T.UIPanelCloseButtonNoScripts = T.UIPanelCloseButton
T.UICheckButtonTemplate = function(f, st)
    needType(st, { "CheckButton" }, "UICheckButtonTemplate")
    f:SetSize(32, 32)
    if st.isButton then
        f:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
        f:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
        f:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
        if st.isCheckButton then f:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check") end
    end
    -- whether .Text exists on Forever is UNKNOWN (FACTS E.1): deliberately not provided
end
T.InputBoxTemplate = function(f, st)
    needType(st, { "EditBox" }, "InputBoxTemplate")
    f.Left = tex(f, "BACKGROUND", "Interface\\Common\\Common-Input-Border")
    f.Right = tex(f, "BACKGROUND", "Interface\\Common\\Common-Input-Border")
    f.Middle = tex(f, "BACKGROUND", "Interface\\Common\\Common-Input-Border")
    f.Left:SetPoint("LEFT", -5, 0); f.Left:SetSize(8, 20)
    f.Right:SetPoint("RIGHT", 0, 0); f.Right:SetSize(8, 20)
    f.Middle:SetPoint("LEFT", f.Left, "RIGHT"); f.Middle:SetPoint("RIGHT", f.Right, "LEFT"); f.Middle:SetHeight(20)
    if st.isEditBox then f:SetFontObject(G.ChatFontNormal) end
end
T.SearchBoxTemplate = function(f, st)
    T.InputBoxTemplate(f, st)
    f.searchIcon = tex(f, "OVERLAY", "Interface\\Common\\UI-Searchbox-Icon")
    f.searchIcon:SetSize(14, 14)
    f.searchIcon:SetPoint("LEFT", 0, -2)
    f.Instructions = fontStr(f, "ARTWORK", "GameFontDisableSmall")
    f.Instructions:SetPoint("LEFT", 16, 0)
    f.clearButton = MOCK.CreateFrame("Button", nil, f)
    f.clearButton:SetSize(17, 17)
    f.clearButton:SetPoint("RIGHT", -3, 0)
    f.clearButton:Hide()
end
local function scrollBarFor(f, kind)
    local bar = MOCK.CreateFrame(kind or "Slider", nil, f)
    bar:SetWidth(16)
    bar:SetPoint("TOPLEFT", f, "TOPRIGHT", 6, -16)
    bar:SetPoint("BOTTOMLEFT", f, "BOTTOMRIGHT", 6, 16)
    return bar
end
T.UIPanelScrollFrameTemplate = function(f, st)
    needType(st, { "ScrollFrame" }, "UIPanelScrollFrameTemplate")
    local bar = scrollBarFor(f, "Slider")
    bar.ScrollUpButton = MOCK.CreateFrame("Button", nil, bar)
    bar.ScrollDownButton = MOCK.CreateFrame("Button", nil, bar)
    f.ScrollBar = bar
end
T.ScrollFrameTemplate = function(f, st)
    needType(st, { "ScrollFrame" }, "ScrollFrameTemplate")
    f.ScrollBar = scrollBarFor(f, "EventFrame")
end
local function stubTemplate(tname)
    return function(f)
        MOCK.Warn("template", tname .. ": Blizzard template stub (layout/behaviour not mocked)", 4)
    end
end
for _, n in ipairs({ "MinimalScrollBar", "WowScrollBoxList", "WowScrollBox", "WowStyle1DropdownTemplate",
    "WowStyle1FilterDropdownTemplate", "NineSlicePanelTemplate", "InsetFrameTemplate", "SecureActionButtonTemplate",
    "SecureHandlerBaseTemplate", "SecureFrameTemplate" }) do
    T[n] = stubTemplate(n)
end
local function panelTemplate(tname)
    return function(f, st)
        f.Bg = tex(f, "BACKGROUND", "Interface\\FrameGeneral\\UI-Background-Rock", -6)
        f.Bg:SetAllPoints()
        f.TitleText = fontStr(f, "OVERLAY", "GameFontNormal")
        f.TitleText:SetPoint("TOP", 0, -5)
        f.CloseButton = MOCK.CreateFrame("Button", nil, f, "UIPanelCloseButton")
        f.CloseButton:SetPoint("TOPRIGHT", 5, 5)
        f.Inset = MOCK.CreateFrame("Frame", nil, f)
        f.Inset:SetPoint("TOPLEFT", 4, -24)
        f.Inset:SetPoint("BOTTOMRIGHT", -6, 26)
        f.NineSlice = MOCK.CreateFrame("Frame", nil, f)
        f.NineSlice:SetAllPoints()
        if tname ~= "BasicFrameTemplate" and tname ~= "BasicFrameTemplateWithInset" then
            f.PortraitContainer = MOCK.CreateFrame("Frame", nil, f)
            f.PortraitContainer:SetSize(62, 62)
            f.PortraitContainer:SetPoint("TOPLEFT", -5, 7)
            f.PortraitContainer.portrait = tex(f.PortraitContainer, "OVERLAY")
            f.PortraitContainer.portrait:SetAllPoints()
            f.TitleContainer = MOCK.CreateFrame("Frame", nil, f)
            f.TitleContainer:SetPoint("TOPLEFT", 58, -1)
            f.TitleContainer:SetPoint("TOPRIGHT", -24, -1)
            f.TitleContainer:SetHeight(20)
            f.TitleContainer.TitleText = f.TitleText
        end
    end
end
for _, n in ipairs({ "PortraitFrameTemplate", "ButtonFrameTemplate", "BasicFrameTemplate", "BasicFrameTemplateWithInset", "DefaultPanelTemplate" }) do
    T[n] = panelTemplate(n)
end
G.ButtonFrameTemplate_HidePortrait = function(f) if f.PortraitContainer then f.PortraitContainer:Hide() end end
G.ButtonFrameTemplate_HideButtonBar = function() end
T.GameTooltipTemplate = function(f, st)
    if st.otype ~= "GameTooltip" then MOCK.Warn("template", "GameTooltipTemplate inherited by a " .. st.otype, 4) end
end
T.SharedTooltipTemplate = T.GameTooltipTemplate

-------------------------------------------------------------------------------
-- GameTooltip
-------------------------------------------------------------------------------
local M_Tooltip = MOCK.Types.GameTooltip.methods
MOCK.tooltipPostCalls = {}    -- dataType -> { fn, ... }
MOCK.tooltipPreCalls = {}

local function ttLines(st)
    st.lines = st.lines or {}
    return st.lines
end
local function ttClear(self, st)
    st.lines = {}
    st.data = nil
    st.item, st.spell, st.unit = nil, nil, nil
    for _, fs in ipairs(st.lineFS or {}) do fs:Hide() end
    for _, fs in ipairs(st.lineFSR or {}) do fs:Hide() end
    MOCK.RunScript(self, "OnTooltipCleared")
end
function M_Tooltip:SetOwner(owner, anchor, x, y)
    local st = ST(self)
    if not (S[owner] and S[owner].isRegionLike) then error("Usage: GameTooltip:SetOwner(owner, anchor[, x, y])", 2) end
    if anchor ~= nil and type(anchor) ~= "string" then error("Usage: GameTooltip:SetOwner(owner, anchor[, x, y])", 2) end
    st.owner = owner
    st.anchor = anchor or "ANCHOR_LEFT"
    st.ox, st.oy = x or 0, y or 0
    ttClear(self, st)
end
function M_Tooltip:GetOwner() return ST(self).owner end
function M_Tooltip:IsOwned(f) return ST(self).owner == f end
function M_Tooltip:SetAnchorType(anchor, x, y) local st = ST(self) st.anchor, st.ox, st.oy = anchor, x or 0, y or 0 end
function M_Tooltip:GetAnchorType() return ST(self).anchor end
local function checkLineText(text, fname)
    if text ~= nil and type(text) ~= "string" and not isNum(text) and not isSecret(text) then
        error(format("bad argument #1 to '%s' (string expected, got %s)", fname, type(text)), 3)
    end
end
function M_Tooltip:AddLine(text, r, g, b, wrap)
    local st = ST(self)
    checkLineText(text, "AddLine")
    if isNum(text) then text = tostring(text) end
    local l = ttLines(st)
    l[#l + 1] = { left = text or "", lc = { r or 1, g or 0.82, b or 0 }, wrap = wrap and true or false }
end
function M_Tooltip:AddDoubleLine(lt, rt, lr, lg, lb, rr, rg, rb)
    local st = ST(self)
    checkLineText(lt, "AddDoubleLine")
    checkLineText(rt, "AddDoubleLine")
    local l = ttLines(st)
    l[#l + 1] = { left = lt and tostring(lt) or "", right = rt and tostring(rt) or "", lc = { lr or 1, lg or 0.82, lb or 0 }, rc = { rr or 1, rg or 0.82, rb or 0 } }
end
function M_Tooltip:SetText(text, r, g, b, a, wrap)
    local st = ST(self)
    checkLineText(text, "SetText")
    ttClear(self, st)
    st.lines = { { left = text or "", lc = { r or 1, g or 1, b or 1 }, wrap = wrap and true or false } }
end
function M_Tooltip:AppendText(text)
    local st = ST(self)
    local l = ttLines(st)
    if #l == 0 then l[1] = { left = "", lc = { 1, 1, 1 } } end
    l[1].left = tostring(l[1].left) .. tostring(text or "")
end
function M_Tooltip:AddTexture() ST(self) return true end
function M_Tooltip:AddSpellByID(id) self:AddLine(G.C_Spell.GetSpellName(id) or "", 1, 1, 1) end
function M_Tooltip:NumLines() return #(ST(self).lines or {}) end
function M_Tooltip:ClearLines() local st = ST(self) ttClear(self, st) end
function M_Tooltip:SetMinimumWidth(w) ST(self).minWidth = w end
function M_Tooltip:GetMinimumWidth() return ST(self).minWidth or 0 end
function M_Tooltip:SetPadding(r, b, l, t) ST(self).padding = { r, b, l, t } end
function M_Tooltip:GetPadding() local p = ST(self).padding or { 0, 0, 0, 0 } return p[1], p[2], p[3], p[4] end
function M_Tooltip:FadeOut() self:Hide() end
function M_Tooltip:SetCustomLineSpacing(n) ST(self).lineSpacing = n end
function M_Tooltip:SetBackdropBorderColor() ST(self) end
function M_Tooltip:GetItem() local st = ST(self) local it = st.item if not it then return nil end return it.name, it.link, it.id end
function M_Tooltip:GetSpell() local st = ST(self) local sp = st.spell if not sp then return nil end return sp.name, sp.id end
function M_Tooltip:GetUnit() local st = ST(self) local u = st.unit if not u then return nil end return u.name, u.unit, u.guid end
function M_Tooltip:GetTooltipData() return ST(self).data end
function M_Tooltip:GetPrimaryTooltipData() return ST(self).data end
function M_Tooltip:IsTooltipType(t) local d = ST(self).data return d ~= nil and d.type == t end

function MOCK.RunTooltipPostCalls(tooltip, dataType, data)
    for _, key in ipairs({ dataType, "ALL" }) do
        for _, fn in ipairs(MOCK.tooltipPostCalls[key] or {}) do
            Protect("tooltip", "TooltipDataProcessor post-call", fn, tooltip, data)
        end
    end
end

local function itemTooltip(self, st, id, link)
    local CI = G.C_Item
    local name, ilink, q = CI.GetItemInfo(link or id)
    local rec = MOCK.ItemRecord(id)
    if not rec then
        self:AddLine(G.RETRIEVING_ITEM_INFO or "Retrieving item information", 1, 0, 0)
        return
    end
    name = name or rec.name
    q = q or rec.quality
    local c = MOCK.QUALITY[q] or MOCK.QUALITY[1]
    self:AddLine(name, c[1], c[2], c[3])
    if rec.bind == 1 then self:AddLine("Binds when picked up", 1, 1, 1) end
    if rec.equipLoc ~= "" then self:AddDoubleLine(rec.subType, rec.type, 1, 1, 1, 1, 1, 1) end
    if rec.ilvl then self:AddLine("Item Level " .. rec.ilvl, 1, 0.82, 0) end
    st.item = { id = id, name = name, link = ilink or link }
    st.data = { type = G.Enum.TooltipDataType.Item, id = id, hyperlink = ilink or link, lines = {}, dataInstanceID = MOCK.tickNo }
    MOCK.RunTooltipPostCalls(self, G.Enum.TooltipDataType.Item, st.data)
end
function M_Tooltip:SetHyperlink(link)
    local st = ST(self)
    if type(link) ~= "string" then error("Usage: GameTooltip:SetHyperlink(\"link\")", 2) end
    local kind, rest = R.match(link, "|?H?(%a+):([^|]*)")
    if not kind then kind, rest = R.match(link, "^(%a+):(.*)$") end
    if kind == "item" then
        ttClear(self, st)
        local id = tonumber(R.match(rest, "^(%d+)"))
        itemTooltip(self, st, id, link)
    elseif kind == "spell" then
        ttClear(self, st)
        self:SetSpellByID(tonumber(R.match(rest, "^(%d+)")))
    elseif kind == "unit" or kind == "player" or kind == "quest" or kind == "enchant" or kind == "trade" or kind == "achievement" then
        ttClear(self, st)
        self:AddLine(link, 1, 1, 1)
    else
        error("GameTooltip:SetHyperlink(): Unknown link type", 2)
    end
end
function M_Tooltip:SetItemByID(id)
    local st = ST(self)
    if not isNum(id) then error("Usage: GameTooltip:SetItemByID(itemID)", 2) end
    ttClear(self, st)
    itemTooltip(self, st, id, nil)
end
function M_Tooltip:SetSpellByID(id)
    local st = ST(self)
    if not isNum(id) then error("Usage: GameTooltip:SetSpellByID(spellID)", 2) end
    local sp = MOCK.SpellRecord(id)
    ttClear(self, st)
    self:AddLine(sp and sp.name or "Unknown spell", 1, 1, 1)
    st.spell = { id = id, name = sp and sp.name }
    st.data = { type = G.Enum.TooltipDataType.Spell, id = id, lines = {} }
    MOCK.RunTooltipPostCalls(self, G.Enum.TooltipDataType.Spell, st.data)
end
function M_Tooltip:SetUnit(unit)
    local st = ST(self)
    if type(unit) ~= "string" then error("Usage: GameTooltip:SetUnit(\"unit\")", 2) end
    ttClear(self, st)
    local UN, UG = rawget(_G, "UnitName"), rawget(_G, "UnitGUID")
    local name = UN and UN(unit)
    if not name then return end
    self:AddLine(name, 1, 1, 1)
    local guid = UG and UG(unit)
    st.unit = { name = name, unit = unit, guid = guid }
    st.data = { type = G.Enum.TooltipDataType.Unit, guid = guid, lines = {} }
    MOCK.RunTooltipPostCalls(self, G.Enum.TooltipDataType.Unit, st.data)
end
function M_Tooltip:SetBagItem(bag, slot)
    local CC = G.C_Container
    local id = CC.GetContainerItemID(bag, slot)
    if id then self:SetItemByID(id) return true end
    return false
end
function M_Tooltip:SetLootItem(slot)
    local link = rawget(_G, "GetLootSlotLink") and _G.GetLootSlotLink(slot)
    if link and not isSecret(link) then self:SetHyperlink(link) end
end
function M_Tooltip:SetLootRollItem(id)
    local link = rawget(_G, "GetLootRollItemLink") and _G.GetLootRollItemLink(id)
    if link then self:SetHyperlink(link) end
end
function M_Tooltip:SetInventoryItem() ST(self) return false, false, 0 end
function M_Tooltip:SetUnitAura() ST(self) end
function M_Tooltip:SetUnitBuff() ST(self) end

--- lays out the lines into FontStrings, sizes and anchors the tooltip (on Show)
local function layoutTooltip(self, st)
    st.lineFS = st.lineFS or {}
    st.lineFSR = st.lineFSR or {}
    local lines = st.lines or {}
    local name = st.name or "Tooltip"
    local y = -10
    local width = st.minWidth or 0
    for i, l in ipairs(lines) do
        local fs = st.lineFS[i]
        if not fs then
            fs = self:CreateFontString(name .. "TextLeft" .. i, "ARTWORK", i == 1 and "GameTooltipHeaderText" or "GameTooltipText")
            st.lineFS[i] = fs
            local fr = self:CreateFontString(name .. "TextRight" .. i, "ARTWORK", "GameTooltipText")
            st.lineFSR[i] = fr
            S[fs].where, S[fr].where = "client", "client"   -- created by the client, not the addon
        end
        local fr = st.lineFSR[i]
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", self, "TOPLEFT", 10, y)
        fs:SetJustifyH("LEFT")
        fs:SetText(l.left)
        fs:SetTextColor(l.lc[1], l.lc[2], l.lc[3], 1)
        S[fs].width = nil
        local lw = fs:GetUnboundedStringWidth()
        if l.wrap and lw > 260 then
            fs:SetWidth(260)
            fs:SetWordWrap(true)
            lw = 260
        else
            fs:SetWordWrap(false)
        end
        fs:Show()
        local rw = 0
        if l.right then
            fr:ClearAllPoints()
            fr:SetPoint("TOPRIGHT", self, "TOPRIGHT", -10, y)
            fr:SetJustifyH("RIGHT")
            fr:SetText(l.right)
            fr:SetTextColor(l.rc[1], l.rc[2], l.rc[3], 1)
            fr:Show()
            rw = fr:GetUnboundedStringWidth() + 20
        else
            fr:Hide()
        end
        width = max(width, lw + rw)
        y = y - fs:GetStringHeight() - 2
    end
    for i = #lines + 1, #st.lineFS do st.lineFS[i]:Hide(); st.lineFSR[i]:Hide() end
    self:SetSize(width + 20, -y + 8)
    local owner = st.owner
    if owner and st.anchor ~= "ANCHOR_NONE" and st.anchor ~= "ANCHOR_PRESERVE" then
        self:ClearAllPoints()
        local a = st.anchor or "ANCHOR_LEFT"
        local ox, oy = st.ox or 0, st.oy or 0
        if a == "ANCHOR_RIGHT" then self:SetPoint("BOTTOMLEFT", owner, "TOPRIGHT", ox, oy)
        elseif a == "ANCHOR_LEFT" then self:SetPoint("BOTTOMRIGHT", owner, "TOPLEFT", ox, oy)
        elseif a == "ANCHOR_TOP" then self:SetPoint("BOTTOM", owner, "TOP", ox, oy)
        elseif a == "ANCHOR_BOTTOM" then self:SetPoint("TOP", owner, "BOTTOM", ox, oy)
        elseif a == "ANCHOR_TOPLEFT" then self:SetPoint("BOTTOMLEFT", owner, "TOPLEFT", ox, oy)
        elseif a == "ANCHOR_TOPRIGHT" then self:SetPoint("BOTTOMRIGHT", owner, "TOPRIGHT", ox, oy)
        elseif a == "ANCHOR_BOTTOMLEFT" then self:SetPoint("TOPRIGHT", owner, "BOTTOMLEFT", ox, oy)
        elseif a == "ANCHOR_BOTTOMRIGHT" then self:SetPoint("TOPLEFT", owner, "BOTTOMRIGHT", ox, oy)
        elseif a == "ANCHOR_CURSOR" or a == "ANCHOR_CURSOR_RIGHT" or a == "ANCHOR_CURSOR_LEFT" then
            self:SetPoint("BOTTOMLEFT", rawget(_G, "UIParent"), "BOTTOMLEFT", MOCK.cursorX + 10, MOCK.cursorY + 10)
        else self:SetPoint("BOTTOMRIGHT", owner, "TOPLEFT", ox, oy) end
    end
end
local baseShow = MOCK.M.ScriptRegion.Show
function M_Tooltip:Show()
    local st = ST(self)
    Protect("mock", "tooltip layout", layoutTooltip, self, st)
    baseShow(self)
end

local function newTooltip(name)
    local tt = MOCK.NewFrame("GameTooltip", name, rawget(_G, "UIParent"))
    local st = S[tt]
    st.strata = "TOOLTIP"
    st.shown = false
    st.clamped = true
    Mixin(tt, Backdrop)
    tt.backdropInfo = { bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 }
    tt:ApplyBackdrop()
    tt:SetBackdropColor(0.04, 0.04, 0.06, 0.94)
    tt:SetBackdropBorderColor(0.3, 0.3, 0.35, 1)
    return tt
end
MOCK.NewTooltip = newTooltip

G.TooltipDataProcessor = {
    AllTypes = "ALL",
    AddTooltipPostCall = function(dataType, fn)
        if type(fn) ~= "function" then error("Usage: TooltipDataProcessor.AddTooltipPostCall(dataType, func)", 2) end
        if dataType == nil then error("Usage: TooltipDataProcessor.AddTooltipPostCall(dataType, func)", 2) end
        MOCK.tooltipPostCalls[dataType] = MOCK.tooltipPostCalls[dataType] or {}
        tinsert(MOCK.tooltipPostCalls[dataType], fn)
    end,
    AddTooltipPreCall = function(dataType, fn)
        MOCK.tooltipPreCalls[dataType] = MOCK.tooltipPreCalls[dataType] or {}
        tinsert(MOCK.tooltipPreCalls[dataType], fn)
    end,
    AddLinePostCall = function() end,
}

-------------------------------------------------------------------------------
-- Minimap frame type methods
-------------------------------------------------------------------------------
local M_Minimap = MOCK.Types.Minimap.methods
function M_Minimap:GetZoom() return ST(self).zoom or 0 end
function M_Minimap:SetZoom(z) ST(self).zoom = z end
function M_Minimap:GetZoomLevels() ST(self) return 6 end
function M_Minimap:SetMaskTexture(t) ST(self).mask = t end
function M_Minimap:SetBlipTexture() ST(self) end
function M_Minimap:PingLocation() ST(self) end

-------------------------------------------------------------------------------
-- Namespaces that are not game state
-------------------------------------------------------------------------------
G.C_Timer = MOCK.C_Timer
G.C_EventUtils = {
    IsEventValid = function(event)
        if type(event) ~= "string" then error("bad argument #1 to 'IsEventValid' (string expected)", 2) end
        return MOCK.validEvents[event] == true
    end,
}
G.C_Texture = {
    GetAtlasInfo = function(atlas)
        if type(atlas) ~= "string" then error("bad argument #1 to 'GetAtlasInfo' (string expected, got " .. type(atlas) .. ")", 2) end
        local a = MOCK.atlases[atlas] or MOCK.atlases[lower(atlas)]
        if not a then return nil end
        local c = {}
        for k, v in pairs(a) do c[k] = v end
        return c
    end,
    GetFilenameFromFileDataID = function(id) return nil end,
}

-- C_EncodingUtil: compression is the identity (lupa has no zlib) so the addon's compress
-- path (self-test, encode, decode) is exercised end to end; Base64 is real.
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64URL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local function b64encode(s, alphabet)
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = byte(s, i, i + 2)
        local v = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1, c2, c3, c4 = floor(v / 262144) % 64, floor(v / 4096) % 64, floor(v / 64) % 64, v % 64
        out[#out + 1] = sub(alphabet, c1 + 1, c1 + 1) .. sub(alphabet, c2 + 1, c2 + 1)
            .. (b and sub(alphabet, c3 + 1, c3 + 1) or "=") .. (c and sub(alphabet, c4 + 1, c4 + 1) or "=")
    end
    return concat(out)
end
local function b64decode(s, alphabet)
    local dec = {}
    for i = 1, 64 do dec[byte(alphabet, i)] = i - 1 end
    local out = {}
    local buf, bits = 0, 0
    for i = 1, #s do
        local ch = byte(s, i)
        if ch == 61 then break end
        local v = dec[ch]
        if v == nil then error("DecodeBase64: invalid input", 3) end
        buf = buf * 64 + v
        bits = bits + 6
        if bits >= 8 then
            bits = bits - 8
            local x = floor(buf / 2 ^ bits)
            out[#out + 1] = char(x % 256)
            buf = buf % 2 ^ bits
        end
    end
    return concat(out)
end
local function checkMethod(m, fname)
    if m == nil then return end
    local ok = false
    for _, v in pairs(G.Enum.CompressionMethod) do if v == m then ok = true end end
    if not ok then error("bad argument #2 to '" .. fname .. "' (invalid compression method)", 3) end
end
G.C_EncodingUtil = {
    CompressString = function(s, method, level)
        if type(s) ~= "string" then error("bad argument #1 to 'CompressString' (string expected, got " .. type(s) .. ")", 2) end
        checkMethod(method, "CompressString")
        MOCK.compressCalls = (MOCK.compressCalls or 0) + 1
        return s
    end,
    DecompressString = function(s, method)
        if type(s) ~= "string" then error("bad argument #1 to 'DecompressString' (string expected, got " .. type(s) .. ")", 2) end
        checkMethod(method, "DecompressString")
        return s
    end,
    EncodeBase64 = function(s, variant)
        if type(s) ~= "string" then error("bad argument #1 to 'EncodeBase64' (string expected, got " .. type(s) .. ")", 2) end
        return b64encode(s, variant == 1 and B64URL or B64)
    end,
    DecodeBase64 = function(s, variant)
        if type(s) ~= "string" then error("bad argument #1 to 'DecodeBase64' (string expected, got " .. type(s) .. ")", 2) end
        return b64decode(s, variant == 1 and B64URL or B64)
    end,
}

-- Settings (canvas categories)
MOCK.settingsCategories = {}
local Category = {}
Category.__index = Category
function Category:GetID() return self.ID end
function Category:GetName() return self.name end
function Category:SetName(n) self.name = n end
function Category:GetOrder() return self.order or 0 end
function Category:SetOrder(o) self.order = o end
function Category:HasParentCategory() return false end
G.Settings = {
    RegisterCanvasLayoutCategory = function(frame, name, group)
        if not (S[frame] and S[frame].isFrame) then error("Usage: Settings.RegisterCanvasLayoutCategory(frame, name)", 2) end
        if type(name) ~= "string" then error("Usage: Settings.RegisterCanvasLayoutCategory(frame, name)", 2) end
        local cat = setmetatable({ ID = name, name = name, frame = frame }, Category)
        return cat, {}
    end,
    RegisterVerticalLayoutCategory = function(name)
        MOCK.Warn("settings", "Settings.RegisterVerticalLayoutCategory: taints on Forever (FACTS E.5)", 2)
        return setmetatable({ ID = name, name = name }, Category), {}
    end,
    RegisterCanvasLayoutSubcategory = function(parent, frame, name)
        return setmetatable({ ID = name, name = name, frame = frame }, Category), {}
    end,
    RegisterAddOnCategory = function(cat)
        if type(cat) ~= "table" or getmetatable(cat) ~= Category then error("Usage: Settings.RegisterAddOnCategory(category)", 2) end
        MOCK.settingsCategories[#MOCK.settingsCategories + 1] = cat
    end,
    OpenToCategory = function(id)
        if MOCK.state.combat then MOCK.NoteForbidden("Settings.OpenToCategory in combat (ShowUIPanel blocked)", 2) return false end
        if type(id) == "table" then MOCK.Warn("settings", "Settings.OpenToCategory(category) - pass category:GetID() (FACTS R27)", 2) end
        local sp = rawget(_G, "SettingsPanel")
        if sp then sp:Show() end
        return true
    end,
    GetCategory = function(id)
        for _, c in ipairs(MOCK.settingsCategories) do if c.ID == id then return c end end
    end,
}
G.HideUIPanel = function(f)
    if not (S[f] and S[f].isFrame) then return end
    if MOCK.state.combat then MOCK.NoteForbidden("HideUIPanel in combat", 2) return end
    f:Hide()
end
G.ShowUIPanel = function(f)
    if not (S[f] and S[f].isFrame) then return end
    if MOCK.state.combat then MOCK.NoteForbidden("ShowUIPanel in combat", 2) return end
    f:Show()
end
G.CloseSpecialWindows = function()
    local found = false
    for _, name in ipairs(rawget(_G, "UISpecialFrames") or {}) do
        local f = rawget(_G, name)
        if f and S[f] and f:IsShown() then f:Hide() found = true end
    end
    return found
end

G.StaticPopupDialogs = {}
G.StaticPopup_Show = function(which, text1, text2, data)
    local d = G.StaticPopupDialogs[which]
    if type(d) ~= "table" then return nil end
    local f = MOCK.CreateFrame("Frame", nil, rawget(_G, "UIParent"))
    f.which, f.data = which, data
    if d.hasEditBox then f.editBox = MOCK.CreateFrame("EditBox", nil, f); f.EditBox = f.editBox; f.editBox:SetAutoFocus(false) end
    if d.OnShow then Protect("script", "StaticPopup OnShow " .. which, d.OnShow, f, data) end
    return f
end
G.StaticPopup_Hide = function() end
G.StaticPopup_Visible = function() return nil end

G.UISpecialFrames = {}
G.SlashCmdList = {}
G.hash_SlashCmdList = {}

-- AddOns (metadata from the TOC, supplied by run.py)
local function tocMeta() return MOCK.CFG.toc or {} end
G.C_AddOns = {
    GetAddOnMetadata = function(name, field)
        if type(name) ~= "string" and not isNum(name) then error("bad argument #1 to 'GetAddOnMetadata' (string expected)", 2) end
        if type(field) ~= "string" then error("bad argument #2 to 'GetAddOnMetadata' (string expected)", 2) end
        if name ~= MOCK.CFG.addonName and name ~= 1 then return nil end
        local m = tocMeta()
        for k, v in pairs(m) do if lower(k) == lower(field) then return v end end
        return nil
    end,
    IsAddOnLoaded = function(name)
        local loaded = name == MOCK.CFG.addonName or name == 1
        return loaded, loaded
    end,
    GetNumAddOns = function() return 1 end,
    GetAddOnInfo = function(i)
        if i == 1 or i == MOCK.CFG.addonName then
            return MOCK.CFG.addonName, tocMeta().Title, tocMeta().Notes, true, "INSECURE", nil, false
        end
    end,
    LoadAddOn = function(name) return name == MOCK.CFG.addonName, nil end,
    IsAddOnLoadOnDemand = function() return false end,
    EnableAddOn = function() MOCK.Warn("addons", "C_AddOns.EnableAddOn changes user configuration - never call it (FACTS A.2)", 2) end,
    DisableAddOn = function() MOCK.Warn("addons", "C_AddOns.DisableAddOn changes user configuration", 2) end,
    GetAddOnEnableState = function() return 2 end,
    DoesAddOnExist = function(name) return name == MOCK.CFG.addonName end,
}

G.C_Secrets = {
    ShouldAurasBeSecret = function() return MOCK.secretOn.auras == true or (MOCK.state and MOCK.state.combat) == true end,
    CanCompareUnitTokens = function() return not MOCK.secretOn.names end,
    ShouldUnitIdentityBeSecret = function(unit) return MOCK.secretOn.names == true and unit ~= "player" end,
}
G.C_RestrictedActions = {
    IsAddOnRestrictionActive = function(kind)
        local E = G.Enum.AddOnRestrictionType
        local st = MOCK.state
        if kind == E.Chat then return st.chatLockdown == true end
        if kind == E.Combat then return st.combat == true end
        if kind == E.Encounter then return st.encounter ~= nil end
        return false
    end,
}
G.C_GameRules = { IsGameRuleActive = function() return false end }

-------------------------------------------------------------------------------
-- Root frames (created by MOCK.CreateRootFrames once the API is in _G)
-------------------------------------------------------------------------------
function MOCK.CreateRootFrames()
    local ui = MOCK.NewFrame("Frame", "UIParent", nil)
    local ust = S[ui]
    ust.isScreenRoot = true
    ust.strata = "MEDIUM"
    ust.level = 0
    ust.where = "client"
    G.UIParent = ui
    local wf = MOCK.NewFrame("Frame", "WorldFrame", nil)
    S[wf].isScreenRoot = true
    S[wf].strata = "BACKGROUND"
    S[wf].where = "client"
    G.WorldFrame = wf
    local mm = MOCK.NewFrame("Minimap", "Minimap", ui)
    mm:SetSize(198, 198)
    mm:SetPoint("TOPRIGHT", ui, "TOPRIGHT", -24, -36)
    S[mm].strata = "LOW"
    S[mm].where = "client"
    S[mm].mouse = true
    G.Minimap = mm
    local cf = MOCK.NewFrame("ScrollingMessageFrame", "ChatFrame1", ui)
    cf:SetSize(430, 180)
    cf:SetPoint("BOTTOMLEFT", ui, "BOTTOMLEFT", 32, 96)
    S[cf].where = "client"
    S[cf].shown = false
    cf.editBox = MOCK.NewFrame("EditBox", "ChatFrame1EditBox", ui)
    S[cf.editBox].shown = false
    S[cf.editBox].autoFocus = false
    G.DEFAULT_CHAT_FRAME = cf
    G.SELECTED_CHAT_FRAME = cf
    G.CHAT_FRAMES = { "ChatFrame1" }
    G.GameTooltip = newTooltip("GameTooltip")
    G.ItemRefTooltip = newTooltip("ItemRefTooltip")
    local sp = MOCK.NewFrame("Frame", "SettingsPanel", ui)
    S[sp].shown = false
    S[sp].strata = "HIGH"
    sp:SetSize(920, 724)
    sp:SetPoint("CENTER")
    G.SettingsPanel = sp
    G.AddonCompartmentFrame = MOCK.NewFrame("Frame", "AddonCompartmentFrame", mm)
    G.AddonCompartmentFrame.registeredAddons = {}
    G.AddonCompartmentFrame.RegisterAddon = function(self, info) tinsert(self.registeredAddons, info) end
    G.AddonCompartmentFrame.UpdateDisplay = function() end
    for _, o in ipairs(MOCK.objects) do S[o].where = S[o].where or "client" end
end

function MOCK.InstallGlobals()
    for k, v in pairs(G) do rawset(_G, k, v) end
    rawset(_G, "CreateFrame", MOCK.CreateFrame)
end
