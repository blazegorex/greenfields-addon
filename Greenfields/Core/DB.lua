--[[ Greenfields - Core/DB.lua
     SavedVariables layout.

       GreenfieldsDB (account)
         settings          account-wide toggles (GF.db.settings)
         guilds[guildKey]  everything shared with one guild (GF.gdb)
           store           replicated datasets (Core/Store.lua)
           feed            Neighbourhood Watch history (local)
           local           per-guild local-only state modules may use
         ui                window position/size, last tab

       GreenfieldsCharDB (per character) -> GF.cdb
         stats, tracking state, anything only this character needs

     Forever's beta has been reported not restoring SavedVariables, so everything must
     work from an empty DB. ]]

local _, GF = ...

local DB = {}
GF.DB = DB
local U = GF.Util

local DEFAULT_SETTINGS = {
    debug = false,
    toasts = true,
    toastSounds = true,
    feedToasts = true,          -- toast for guild feed events
    welcome = true,             -- login greeting
    minimap = { hide = false, angle = 200 },
    shareWealth = true,         -- send the hidden-amount wealth score
    wipeRoastsLocal = true,     -- show a roast toast on wipes
    wipeRoastsRaid = false,     -- (leader) post a roast in raid chat on wipes
    srAutoAnnounce = false,     -- (opt-in) announce SR'd items in raid chat when loot drops (host)
    srPopups = true,            -- "you SR'd this, hit Need" popup
    campPings = true,           -- receive camp-duty pings
    tooltipSR = true,           -- show SR'ers on item tooltips
    tooltipCrafters = true,     -- show guild crafters on item tooltips
    tooltipTitles = true,       -- show Greenfields titles on player tooltips
    scale = 1,
}

local DEFAULT_GUILD = {
    store = {},
    feed = {},
    ["local"] = {},
}

local DEFAULT_CHAR = {
    stats = {},        -- [statKey] = all-time value
    weekly = {},       -- [weekKey] = { [statKey] = value }
    track = {},        -- tracker scratch state
}

function DB:Init()
    GreenfieldsDB = type(GreenfieldsDB) == "table" and GreenfieldsDB or {}
    GreenfieldsCharDB = type(GreenfieldsCharDB) == "table" and GreenfieldsCharDB or {}
    local db = GreenfieldsDB
    db.settings = U.Defaults(db.settings, DEFAULT_SETTINGS)
    db.guilds = db.guilds or {}
    db.ui = db.ui or {}
    db.version = GF.VERSION
    GF.db = db
    GF.cdb = U.Defaults(GreenfieldsCharDB, DEFAULT_CHAR)
    -- until we know the guild, point at a scratch partition
    self:UseGuild(nil)
end

--- Guild partitions keep data from different guilds (alts in other guilds) apart.
function DB:GuildKey()
    local gname = GF.API.GuildInfo()
    if not gname then return nil end
    local faction = GF.API.UnitFaction("player") or "?"
    return gname .. "|" .. faction
end

function DB:UseGuild(key)
    key = key or "_noguild"
    local g = GF.db.guilds[key]
    if not g then
        g = U.Copy(DEFAULT_GUILD)
        GF.db.guilds[key] = g
    end
    U.Defaults(g, DEFAULT_GUILD)
    local changed = GF.gdbKey ~= key
    GF.gdb = g
    GF.gdbKey = key
    if changed then GF:Fire("GF_GUILD_CHANGED", key) end
end

--- Per-guild local scratch table for a module (not replicated).
function DB:Local(moduleName)
    local l = GF.gdb["local"]
    l[moduleName] = l[moduleName] or {}
    return l[moduleName]
end

-- Resolve the guild once the client knows it (GetGuildInfo is empty very early).
-- Fires GF_GUILD_READY(key) once per resolved guild. Modules that publish their own
-- replicated docs (profile, stats, professions) should wait for it, so nothing lands in
-- the scratch partition.
local function resolveGuild()
    local key = DB:GuildKey()
    if key then
        DB:UseGuild(key)
        if GF.guildReady ~= key then
            GF.guildReady = key
            GF:Fire("GF_GUILD_READY", key)
        end
        return true
    end
    return false
end

--- True once the player's guild partition is active (or we know they have no guild).
function DB:Ready() return GF.guildReady ~= nil end

GF:On("GF_LOGIN", function()
    if not resolveGuild() then
        GF:After(5, resolveGuild)
        GF:After(15, resolveGuild)
        GF:After(30, function()
            if not GF.guildReady and not resolveGuild() and not GF.API.InGuild() then
                GF.guildReady = "_noguild"
                GF:Fire("GF_GUILD_READY", "_noguild")
            end
        end)
    end
end)

GF:RegisterEvent("PLAYER_GUILD_UPDATE", function(_, unit)
    if unit == nil or unit == "player" then
        if not resolveGuild() then DB:UseGuild(nil) end
    end
end)

GF:RegisterEvent("GUILD_ROSTER_UPDATE", function()
    if GF.gdbKey == "_noguild" then resolveGuild() end
end)
