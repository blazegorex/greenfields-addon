--[[ Greenfields - Core/Profile.lua
     The "profile" dataset: one small player-owned doc per character, assembled from
     fields that modules contribute.

       Profile:Contribute("field", fn() -> value)   module adds a field to my profile
       Profile:Touch()                               my data changed; republish soon
       Profile:Get(key) -> profile doc or nil        anyone's profile

     Built-in fields: class, level, race, faction, v (addon version), main (declared main),
     profs = { [skillLine] = rank }, t (published at). ]]

local _, GF = ...

local Profile = {}
GF.Profile = Profile

local API, U, Store = GF.API, GF.Util, GF.Store
local contributors = {}

-- Remote profiles are shown everywhere, so junk is rejected at the door.
local function validProfile(_, d)
    if type(d) ~= "table" then return false end
    if d.class ~= nil and (type(d.class) ~= "string" or #d.class > 16 or not d.class:match("^%u+$")) then return false end
    if d.level ~= nil and type(d.level) ~= "number" then return false end
    if d.main ~= nil and (type(d.main) ~= "string" or #d.main > 48 or d.main:find("|", 1, true)) then return false end
    if d.race ~= nil and (type(d.race) ~= "string" or #d.race > 24 or not d.race:match("^[%a]+$")) then return false end
    if d.v ~= nil and (type(d.v) ~= "string" or #d.v > 16 or not d.v:match("^[%w%.%-]+$")) then return false end
    if d.profs ~= nil then
        if type(d.profs) ~= "table" then return false end
        for k, v in pairs(d.profs) do
            if type(k) ~= "number" or type(v) ~= "number" then return false end
        end
    end
    return true
end

Store:Define({
    name = "profile", code = "pl", owner = "player", lazy = 30, keepDays = 120, validate = validProfile,
})

function Profile:Contribute(field, fn)
    contributors[field] = fn
end

function Profile:Get(key) return Store:Get("profile", key) end

local function build()
    local doc = {
        class = API.UnitClassFile("player"),
        level = API.UnitLevel("player"),
        race = API.UnitRace("player"),
        faction = API.UnitFaction("player"),
        v = GF.VERSION,
        main = GF.cdb.main,
        t = API.ServerTime(),
    }
    local profs = {}
    for _, p in ipairs(API.Professions()) do
        local line = p.skillLine
        if line then
            line = GF.BuffData.childSkillLines[line] or line
            profs[line] = math.max(profs[line] or 0, p.rank or 0)
        end
    end
    doc.profs = profs
    for field, fn in pairs(contributors) do
        local ok, val = pcall(fn)
        if ok then doc[field] = val end
    end
    return doc
end

local function sameShape(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do
        if k ~= "t" and not sameShape(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if k ~= "t" and a[k] == nil then return false end
    end
    return true
end

function Profile:Publish()
    if not GF.DB:Ready() or not API.MyKey() then return end
    local doc = build()
    local cur = Store:Mine("profile")
    if cur and sameShape(cur, doc) and (API.ServerTime() - (cur.t or 0)) < 6 * 3600 then return end
    Store:PutMine("profile", doc)
end

function Profile:Touch()
    GF:Debounce("profile-publish", 5, function() Profile:Publish() end)
end

--- Declare which character is your main (nil/"" clears it, i.e. this IS a main).
function Profile:SetMain(mainName)
    if mainName and mainName ~= "" then
        GF.cdb.main = API.Key(mainName)
    else
        GF.cdb.main = nil
    end
    self:Touch()
end

GF:On("GF_GUILD_READY", function() GF:After(4, function() Profile:Publish() end) end)
GF:RegisterEvent("PLAYER_LEVEL_UP", function() Profile:Touch() end)
GF:RegisterEvent("SKILL_LINES_CHANGED", function() Profile:Touch() end)
GF:RegisterEvent("LEARNED_SPELL_IN_TAB", function() Profile:Touch() end)

GF:RegisterSlash("main", function(arg)
    Profile:SetMain(arg)
    if GF.cdb.main then
        GF:Print("Marked this character as an alt of %s.", GF.cdb.main)
    else
        GF:Print("This character is now a main.")
    end
end, "<name> - mark this character as an alt of <name> (blank = this is a main)")
