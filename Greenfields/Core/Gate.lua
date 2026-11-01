--[[ Greenfields - Core/Gate.lua
     Residents only: the addon only runs for characters in the Greenfields guild.

     This is a front gate, not a vault. Blizzard's addon rules say the code has to stay readable, so
     anyone handy can delete this file. What it stops is a copy doing anything for someone who got
     hold of it and isn't in the guild.

     While the gate is shut nothing is sent or listened to, no signs, tooltip lines or chat go out,
     and the window only says why (UI/GateScreen.lua). Modules still run underneath and keep counting
     for this character, so deaths and dings from before the charter goes in on launch morning still
     count. Saved data is never touched.

     A wrong answer here locks the whole guild out on launch morning and there's no real client to
     try it on first, so it only shuts on evidence:
       a guild name we can read that isn't ours   shuts straight away
       no guild, for GRACE seconds                the client says that while it's still loading your
                                                  guild; until then the window says it's checking
       a guild whose name we can't read           never shuts (too early, or a secret value). After
                                                  GRACE it opens a gate shut for having no guild; one
                                                  shut for another guild waits for a name it can read
       a "no guild" we can't read                 never shuts either
     It's read again every few seconds, so a wrong answer fixes itself, and so does joining or leaving.
     Nobody hears about a shut that fixes itself within TELL_AFTER seconds.

       GF.gateShut       the one flag everything else reads. Stays nil (open) if this file didn't
                         load, which is what happens after updating with the game open.
       Gate:Why()        nil (open) | "checking" | "noguild" | "other"
       Gate:Guild()      the other guild's name, when Why() is "other"
       Gate:IsTest()     showing the shut gate on purpose (/gf gate test)
       Gate:IsLive()     Forever has gone live, so the guild rules apply
       Gate:Status()     one line for chat and /gf doctor
     Fires GF_GATE_CHANGED(shut, was, quiet). ]]

local _, GF = ...

local Gate = {}
GF.Gate = Gate

local API = GF.API

local function squash(s) return (s:lower():gsub("%s+", "")) end

-- Any guild with this in its name counts, whatever the capitals and spaces, so if someone beats us
-- to plain "Greenfields" on launch morning, "The Greenfields" or "Green Field WA" still opens up.
local OURS = squash("Greenfield")
-- Forever goes live at 3pm PST 4 Nov 2026 (7am Thu 5 Nov in Mandurah). Until then the gate stays
-- open, so the addon can still be tested from whatever guild you happen to be in.
local LIVE_AT = 1793833200
local GRACE = 30        -- seconds the client has to keep giving the same non-answer before we act on it
local TICK = 5
local LATE = 5          -- checking for longer than this and the login hello may have gone nowhere
local TELL_AFTER = 5    -- a shut that fixes itself sooner than this was the client catching up

local why, otherGuild
local noGuildSince, unreadSince, checkingSince, shutAt
local seenOurs = false     -- the right guild has turned up this session
local testing, leavingTest = false, false
local told = false         -- said why in chat since the gate last opened

local function isOurs(name)
    return squash(name):find(OURS, 1, true) ~= nil
end

-- The hello and sync at login went nowhere if you joined after them, so do them now.
local function joined()
    GF.Roster:Refresh()
    GF:After(5 + math.random() * 10, function() GF.Comm:SendHello("GUILD") end)
    GF:After(20 + math.random() * 20, function() GF.Store:SyncNow() end)
    GF:After(120 + math.random() * 20, function() GF.Store:SyncNow() end)
end

local function set(newWhy, name, quiet)
    quiet = quiet or leavingTest
    otherGuild = name
    if newWhy == why then return end
    local was = why
    why = newWhy
    GF.gateShut = newWhy ~= nil
    if newWhy == nil then
        local announce = told and not quiet
        told, shutAt = false, nil
        if was == "noguild" or was == "other" then
            if announce then GF:Print("You're on the street. The gate's open.") end
            if not quiet then joined() end
        elseif was == "checking" and not quiet and API.Time() - (checkingSince or 0) >= LATE then
            joined()
        end
        quiet = not announce
    elseif newWhy ~= "checking" then
        shutAt = shutAt or API.Time()
    end
    GF:Fire("GF_GATE_CHANGED", GF.gateShut, was, quiet)
end

local function settle()
    if testing then return set("noguild", nil, true) end
    if not Gate:IsLive() then
        noGuildSince, unreadSince = nil, nil
        return set(nil)
    end
    local name = API.GuildInfo()
    if name and name ~= "" then
        noGuildSince, unreadSince = nil, nil
        if isOurs(name) then
            seenOurs = true
            return set(nil)
        end
        return set("other", name)
    end
    local now = API.Time()
    if not API.NoGuild() then
        -- in a guild, but its name isn't through or can't be read just now: that's no reason to
        -- shut, and if it stays that way it's no reason to stay shut either
        noGuildSince = nil
        unreadSince = unreadSince or now
        if why == "checking" or leavingTest or (why == "noguild" and now - unreadSince >= GRACE) then set(nil) end
        return
    end
    unreadSince = nil
    noGuildSince = noGuildSince or now
    if now - noGuildSince >= GRACE then
        set("noguild")
    elseif why == nil and not seenOurs then
        checkingSince = now
        set("checking")
    end
end

function Gate:Check()
    settle()
    if shutAt and not told and not testing and API.Time() - shutAt >= TELL_AFTER then
        told = true
        GF:Print("Residents only. Greenfields only runs for characters in the Greenfields guild.")
    end
end

function Gate:IsLive() return API.ServerTime() >= LIVE_AT end
function Gate:Why() return why end
function Gate:Guild() return otherGuild end
function Gate:IsTest() return testing end

function Gate:Status()
    if testing then return "Test mode: the gate's shut on purpose. /gf gate test opens it back up." end
    local guild = API.GuildInfo() or (API.NoGuild() and "none") or "one we can't read yet"
    if not self:IsLive() then
        return ("Open for everyone until Forever goes live, then Greenfields only. Guild: %s."):format(guild)
    end
    if why == nil then return ("Open. Guild: %s."):format(guild) end
    if why == "checking" then return "Still working out your guild." end
    return ("Shut. This character's %s."):format(why == "other" and ("with " .. tostring(otherGuild)) or "not in a guild")
end

-- Registered ahead of everything else that listens for these, so the gate has already moved by the
-- time the rest of the addon hears about a new guild and starts talking.
GF:RegisterEvent("PLAYER_GUILD_UPDATE", function(_, unit)
    if unit == nil or unit == "player" then Gate:Check() end
end)
GF:RegisterEvent("GUILD_ROSTER_UPDATE", function() Gate:Check() end)
-- The clock keeps running through a loading screen, and that time doesn't count against anyone.
GF:RegisterEvent("PLAYER_ENTERING_WORLD", function() noGuildSince = nil end)

GF:On("GF_LOGIN", function()
    GF:Ticker(TICK, function() Gate:Check() end)
end)

GF:RegisterSlash("gate", function(arg)
    if arg ~= "test" then
        GF:Print(Gate:Status())
        return
    end
    testing = not testing
    if testing then
        Gate:Check()
        GF:Print("Test mode: this is what someone outside the guild gets. /gf gate test opens it back up.")
        if GF.UI and GF.UI.ShowGate then GF.UI:ShowGate() end
    else
        -- straight to the real answer: someone outside the guild never sees it open along the way.
        -- Quietly, unless they'd been told they were out, in which case an invite that landed during
        -- the test gets the same welcome as any other.
        testing, leavingTest = false, not told
        Gate:Check()
        leavingTest = false
        GF:Print("Test over.")
        if GF.gateShut and GF.UI and GF.UI.ShowGate then GF.UI:ShowGate() end
    end
end, "[test] - is the guild lock open for you? test shows what people outside the guild get", true)
