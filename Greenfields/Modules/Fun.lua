--[[ Greenfields - Modules/Fun.lua
     The larrikin bits. None of this is load-bearing; all of it is important.

       Login greeting   a road sign ~6 s after logging in (setting `welcome`), once a session
       Wipe roasts      a yellow sign on a raid/dungeon wipe just for you (`wipeRoastsLocal`);
                        a raid leader who opts in (`wipeRoastsRaid`) gets a sign that reads the
                        line out in raid chat when clicked (RAID sends are click-only on
                        Forever, FOREVER_FACTS D.7), at most once a minute
       Boss kills       a green sign when a raid or dungeon boss goes down
       /gf servo        a made-up servo pie review (local print)
       /gf roast <name> a good-natured roast, printed only to you
       /gf yeahnah      let the street make your decisions for you

     Lines come from GF.Flavor plus this file's own Mandurah material. Every encounter
     payload is Clean'd before use; nothing here is stored or sent except the opt-in,
     click-to-send roast. ]]

local _, GF = ...
local API, U, UI, T = GF.API, GF.Util, GF.UI, GF.Theme

local Fun = GF:NewModule("Fun")

local type, ipairs, tostring = type, ipairs, tostring
local floor = math.floor
local gsub, sub, upper, lower, byte = string.gsub, string.sub, string.upper, string.lower, string.byte
local CleanString, CleanNumber = API.CleanString, API.CleanNumber

local GREET_DELAY = 6
local RAID_ROAST_GAP = 60          -- seconds between roasts in raid chat
local ROAST_TRIES = 4              -- clicks on a "chat's locked" sign before we let it go
local MAX_NAME = 24

-------------------------------------------------------------------------------
-- House material (added to GF.Flavor's lines wherever they're picked)
-------------------------------------------------------------------------------
local EXTRA = {
    greetings = {
        "G'day {name}. The estuary's calm and the raid isn't. Welcome back.",
        "{name}'s back. Someone tell the bin chickens to clear the footpath.",
        "Welcome back {name}. Thongs on, kettle on, logged on.",
        "{name} has rolled in like a ute with a dodgy muffler.",
        "Look who's back from Crab Fest. Welcome home, {name}.",
        "Oi {name}, the dolphins were asking about you.",
    },
    wipes = {
        "Wiped harder than a ute windscreen after a swarm of midges.",
        "That pull was a Kwinana Freeway merge: everyone at once, nobody indicating.",
        "The dolphins in the estuary have better coordination than that.",
        "Down like the Peel Inlet tide. Back up in six hours, apparently.",
        "Seen tidier scenes at a Bunnings sausage sizzle in a hailstorm.",
        "Crab Fest had less carnage, and they boil the guests.",
        "Everyone lie down and pretend it's a beach day at Silver Sands.",
    },
    kills = {
        "{boss} folded like a deck chair on the foreshore.",
        "{boss} is done. Snags are on at Bunnings to celebrate.",
        "{boss} took the Kwinana Freeway in the wrong lane. Gone.",
        "Another one for the estuary. Rest easy, {boss}.",
        "{boss} down. The bin chickens have been notified.",
    },
}

local ROASTS = {
    "{name} plays like they learned the rotation off a Bunnings catalogue.",
    "{name}'s DPS is lower than the Peel Inlet at low tide.",
    "{name} has the map awareness of a bin chicken in a revolving door.",
    "{name} once got lost on the Kwinana Freeway. It's a straight line, mate.",
    "{name} pulls like a dolphin chasing the ferry: enthusiastic, pointless.",
    "{name}'s gear is held together with thongs and hope.",
    "{name} was spotted at Crab Fest trying to vendor the crabs.",
    "{name} brings the energy of a 4am servo pie: lukewarm and full of regret.",
    "{name} stands in fire like it's a heater on a Mandurah winter night.",
    "{name} has more alts than the estuary has jellyfish.",
    "If {name} was a Bunnings snag, they'd be the one that fell through the grill.",
    "{name} parks the ute across two bays and the raid across two wipes.",
}

local SERVO = {
    servos = {
        "the Greenfields servo", "the servo on Pinjarra Road", "the servo by the estuary bridge",
        "the 24-hour servo halfway down the Kwinana Freeway", "the servo next to the Halls Head boat ramp",
        "the servo that's somehow always out of milk",
    },
    pies = {
        "chunky steak pie", "mince and cheese pie", "pepper steak pie", "chicken and leek pie (allegedly chicken)",
        "sausage roll (honorary pie)", "curry pie of no fixed address", "pie of the day (the day is unknown)",
        "steak and kidney pie (bold choice)",
    },
    pastry = {
        "flakier than our raid attendance", "structurally sound, could survive the Crab Fest crowd",
        "soggy as a thong left out in the rain", "golden like a Mandurah sunset", "has seen things, mostly the warmer",
    },
    filling = {
        "lava on the first bite, frozen solid on the second", "70% gravy, 30% mystery", "contains meat. Probably.",
        "mostly air and optimism", "chunky enough to tank Onyxia",
    },
    verdicts = {
        { 10, "flawless. Somebody frame the paper bag" }, { 9, "would wipe to Onyxia for another" },
        { 7, "solid. Like a raid that only wipes twice" }, { 6, "does the job. Like a Bunnings snag, but sadder" },
        { 4, "edible, the way a bin chicken considers things edible" }, { 2, "even the dolphins wouldn't touch it" },
    },
}

local YEAHNAH = {
    { "Yeah nah.", "That's a no, but a polite one.", "red" },
    { "Nah yeah.", "That's a yes. Go for it.", "green" },
    { "Yeah yeah.", "Absolutely. Send it.", "green" },
    { "Nah nah.", "Not a chance, mate.", "red" },
    { "Yeah nah yeah.", "Honestly? Ask again after a servo pie.", "yellow" },
    { "Nah yeah nah.", "The dolphins say no.", "red" },
    { "Yeah, nah, yeah, nah...", "Flip a thong. Heads it's a yes.", "yellow" },
    { "Yeah mate.", "The bin chickens approve.", "green" },
    { "Nah, mate.", "Even Bunnings is closed for this one.", "red" },
    { "Ehh... yeah?", "Same odds as finding parking at Crab Fest.", "yellow" },
}

local GREET_TITLES = { "G'day", "Welcome home", "Back on the street" }
local KILL_TITLES = { "Boss down", "Got 'em", "Evicted" }
local WIPE_TITLES = { "Wipe", "Yeah nah", "Floor inspection complete" }

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------
local merged = {}

--- GF.Flavor[name] plus this file's extras, built once.
local function lines(name)
    if merged[name] then return merged[name] end
    local out = {}
    local F = GF.Flavor
    if F and type(F[name]) == "table" then
        for _, l in ipairs(F[name]) do out[#out + 1] = l end
    end
    for _, l in ipairs(EXTRA[name] or {}) do out[#out + 1] = l end
    merged[name] = out
    return out
end

local function fill(line, vars)
    local F = GF.Flavor
    if F and F.Fill then return F.Fill(line, vars) end
    return line
end

--- Capitalises the first letter, so "{boss}" filled with "the boss" still reads right.
local function sentence(s)
    return (gsub(tostring(s or ""), "^%l", upper))
end

local function pickLine(name, vars)
    return sentence(fill(U.Pick(lines(name)) or "", vars))
end

local function settings() return GF.db and GF.db.settings or {} end

local function toast(opts)
    if UI and UI.Toast then UI:Toast(opts) end
end

-------------------------------------------------------------------------------
-- Login greeting
-------------------------------------------------------------------------------
local greeted = false

local function greet(tries)
    if settings().welcome == false then return end
    local me = API.MyKey()
    if not me then
        -- identity can lag a few seconds on a cold login
        if (tries or 0) < 3 then GF:After(4, function() greet((tries or 0) + 1) end) end
        return
    end
    toast({
        title = U.Pick(GREET_TITLES), text = pickLine("greetings", { name = U.ClassName(me, API.UnitClassFile("player")) }),
        icon = "home", style = "green", duration = 8, key = "fun:greet",
        onClick = function() if UI.OpenMain then UI:OpenMain("home") end end,
    })
end

GF:On("GF_ENTER_WORLD", function(_, isReload)
    if greeted then return end
    greeted = true
    -- a /reload isn't a new arrival
    if API.Clean(isReload) == true then return end
    GF:After(GREET_DELAY, function() greet(0) end)
end)

-------------------------------------------------------------------------------
-- Boss kills and wipe roasts
-------------------------------------------------------------------------------
local encounter
local lastRaidRoast = -RAID_ROAST_GAP

--- Opt-in only, leader only, raids only, and never more than once a minute.
local function raidRoastAllowed()
    return settings().wipeRoastsRaid == true and API.InRaid() and API.IsGroupLeader("player")
        and API.Time() - lastRaidRoast >= RAID_ROAST_GAP
end

--- Runs from a click on the wipe sign: RAID chat is click-only on Forever (FOREVER_FACTS
-- D.7), so nothing here ever fires from a timer.
local function postRoast(text, try)
    if not raidRoastAllowed() then return end
    local ok, why = API.SendChat(text, "RAID")
    if ok then
        lastRaidRoast = API.Time()
        return
    end
    -- right after a pull the client may still hold chat: offer another click
    if why == "lockdown" and try < ROAST_TRIES then
        toast({
            title = "Hold that thought", text = "Raid chat's locked till the dust settles. Click to try again.",
            icon = "bubble", style = "yellow", duration = 10, force = true,
            onClick = function() postRoast(text, try + 1) end,
        })
    end
end

local function onKill(boss, tag)
    toast({
        title = U.Pick(KILL_TITLES), text = pickLine("kills", { boss = boss }),
        icon = "trophy", style = "green", key = "fun:kill:" .. tag,
    })
end

local function onWipe(boss, tag)
    local line = pickLine("wipes", { boss = boss })
    if raidRoastAllowed() then
        -- the leader opted in: their sign doubles as the "read it out" button
        local text = U.ChatSafe(U.StripCodes("Wipe report: " .. line))
        toast({
            title = "Wipe. Click to tell the raid", text = line, icon = "megaphone", style = "yellow",
            duration = 12, force = true, key = "fun:wipe:" .. tag,
            onClick = function() postRoast(text, 1) end,
        })
    elseif settings().wipeRoastsLocal ~= false then
        toast({ title = U.Pick(WIPE_TITLES), text = line, icon = "skull", style = "yellow", key = "fun:wipe:" .. tag })
    end
end

GF:RegisterEvent("ENCOUNTER_START", function(_, encounterID, encounterName)
    encounter = { id = CleanNumber(encounterID), name = CleanString(encounterName) }
end, "Fun")

GF:RegisterEvent("ENCOUNTER_END", function(_, encounterID, encounterName, _, _, success)
    local enc = encounter
    encounter = nil
    -- 1/0 on retail; take a boolean too in case Forever hands one over
    success = API.Clean(success)
    if success == true then success = 1 elseif success == false then success = 0 end
    if success ~= 0 and success ~= 1 then return end
    local itype = API.InstanceInfo().type
    if itype ~= "raid" and itype ~= "party" then return end
    local boss = CleanString(encounterName) or (enc and enc.name) or "the boss"
    local id = CleanNumber(encounterID) or (enc and enc.id)
    local tag = id and tostring(id) or boss
    if success == 1 then
        GF:Safe("fun:kill", onKill, boss, tag)
    else
        GF:Safe("fun:wipe", onWipe, boss, tag)
    end
end, "Fun")

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------
local function scoreColor(n)
    if n >= 8 then return "green" end
    if n >= 5 then return "yellow" end
    return "red"
end

local function servoReview()
    local v = U.Pick(SERVO.verdicts)
    GF:Print(T:Wrap("yellow", "Servo pie review:") .. " " .. sentence(U.Pick(SERVO.pies)) .. " from " .. U.Pick(SERVO.servos) .. ".")
    GF:Print("  Pastry: " .. U.Pick(SERVO.pastry) .. ". Filling: " .. U.Pick(SERVO.filling) .. ".")
    GF:Print("  Verdict: " .. T:Wrap(scoreColor(v[1]), v[1] .. "/10") .. " - " .. v[2] .. ".")
end

--- UTF-8 safe byte cut.
local function cut(s, n)
    if #s <= n then return s end
    local i = n
    while i > 0 do
        local b = byte(s, i + 1)
        if not b or b < 128 or b >= 192 then break end
        i = i - 1
    end
    return sub(s, 1, i)
end

--- First word of what was typed, with no escape codes, cased like a name ("bAZZA" ->
-- "Bazza", so it still finds the roster key; lower() only touches ASCII).
local function typedName(args)
    local s = U.Trim(args):match("^(%S+)") or ""
    s = gsub(s, "|", "")
    s = cut(s, MAX_NAME)
    if s == "" then return nil end
    return upper(sub(s, 1, 1)) .. lower(sub(s, 2))
end

--- Roast lines: the house list plus every GF.Flavor death line that has a {name} in it.
local function roastPool()
    if merged.roasts then return merged.roasts end
    local out = {}
    for _, l in ipairs(ROASTS) do out[#out + 1] = l end
    local F = GF.Flavor
    if F and type(F.deaths) == "table" then
        for _, kind in ipairs({ "fire", "falling", "drowning", "pvp", "generic" }) do
            for _, l in ipairs(F.deaths[kind] or {}) do
                if type(l) == "string" and l:find("{name}", 1, true) then out[#out + 1] = l end
            end
        end
    end
    merged.roasts = out
    return out
end

local function roast(args)
    local me = API.MyKey()
    local name = typedName(args or "")
    local key = name and API.Key(name)
    local mirror = not name or (key ~= nil and key == me)
    local shown
    if mirror then
        shown = me and U.ClassName(me, API.UnitClassFile("player")) or "You"
    elseif key and GF.Roster and GF.Roster.IsMember and GF.Roster:IsMember(key) then
        shown = GF.Roster:Colored(key)
    else
        shown = name
    end
    local line = sentence(fill(U.Pick(roastPool()) or "{name}, mate. Words fail us.", { name = shown }))
    if mirror then line = "Roasting yourself? Brave. " .. line end
    GF:Print(T:Wrap("yellow", "Roast:") .. " " .. line .. T:Wrap("faint", "  (only you can see this)"))
end

local function yeahNah(args)
    local pick = U.Pick(YEAHNAH)
    local question = U.Trim(args or "")
    -- no dedupe key: asking twice in ten seconds should still get an answer
    toast({ title = pick[1], text = pick[2], icon = "dice", style = pick[3] })
    if question ~= "" then
        question = gsub(cut(question, 120), "|", "||")
        GF:Print('"%s" %s %s', question, T:Wrap(pick[3], pick[1]), pick[2])
    end
end

GF:RegisterSlash("servo", servoReview, "rate a random servo pie (just for you)")
GF:RegisterSlash("roast", roast, "<name> - roast a local (only you see it)")
GF:RegisterSlash("yeahnah", yeahNah, "[question] - let the street decide")
