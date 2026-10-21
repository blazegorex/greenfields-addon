--[[ Greenfields - Data/Flavor.lua
     The neighbourhood's voice. Every line here is picked at random somewhere in the UI.
     {name} is replaced with a player's short name, {boss} with an encounter name. ]]

local _, GF = ...

GF.Flavor = {
    taglines = {
        "Est. Mandurah, WA  \194\183  She'll be right",
        "Neighbourhood Watch is watching",
        "No ninjas. Plenty of bin chickens.",
        "Proudly unfunded by Centrelink",
        "Where the floor is a raid mechanic",
        "Population: us. Property values: low.",
        "Lock ya bikes, we're raiding",
        "Raiding harder than the Crab Fest queue",
        "Open late, like the servo",
    },

    greetings = {
        "G'day {name}. Welcome back to Greenfields.",
        "Oi {name}! The servo's open and so is the raid.",
        "Look what crawled out of the estuary. Welcome back, {name}.",
        "{name} has entered the neighbourhood. Lock ya bikes.",
        "Hide the copper wire, {name}'s online.",
        "Nah yeah, {name}'s back.",
        "Mind the shopping trolleys, {name}.",
        "Welcome back {name}. Your ute's where you left it. Mostly.",
        "Don't feed the bin chickens, {name}.",
        "{name}! Thought the Rangers finally got ya.",
    },

    wipes = {
        "Yeah nah. That's a wipe.",
        "More cooked than a servo pie at 3am.",
        "Even the Mandurah dolphins are embarrassed for you.",
        "Someone call St John, we've got a carpet of bodies.",
        "That pull had the coordination of a shopping trolley in the estuary.",
        "Who let the eshays pull?",
        "Stood in more fire than a Greenfields bin on cracker night.",
        "Strategy: 'she'll be right'. Result: she was not right.",
        "That went about as well as merging onto the Kwinana at 5pm.",
        "Not even a Bunnings snag could save that.",
        "We didn't wipe, we did a tactical lie-down.",
        "Absolute scenes. Absolutely cooked.",
        "Floor's comfy, innit?",
        "{boss} would like to thank the academy and our healers.",
        "Run it back. Nobody tell Centrelink we call this work.",
    },

    kills = {
        "{boss} got done like a dinner. Good work, lads.",
        "{boss} is now a former resident of the neighbourhood.",
        "Down goes {boss}. Someone check its pockets.",
        "{boss} cooked. Greenfields remains undefeated (this week).",
        "{boss} just got evicted. No bond back.",
    },

    deaths = {
        fire = { "Mate. It's FIRE. You don't sit in it.", "Total fire ban, {name}. TOTAL.", "Smells like a burnt snag in here." },
        falling = { "Took the stairs the fast way.", "Gravity: 1, {name}: 0.", "That's not how you get off the Peel Inlet bridge." },
        drowning = { "Peel Inlet Swim Club claims another member.", "Should've brought the floaties." },
        pvp = { "Got jumped at the servo.", "Rolled by randoms. Tough luck, champ." },
        generic = { "Down like a sack of spuds.", "Have a lie down, {name}.", "RIP bozo. Rez incoming. Probably." },
    },

    campPing = {
        "OI {name}! The raid needs your {object}. Get it on the ground.",
        "{name}, chuck down a {object}, the raid's missing {buff}.",
        "Camp duty, {name}: {object}. Don't make us beg.",
    },

    tooltips = {
        richest = "Rich. How rich? Wouldn't you like to know.",
        poorest = "Gold? Never heard of her.",
    },

    emptyStates = {
        roster = "No one's home. Suspicious.",
        events = "No raids planned. Go touch grass (it's dead, it's Greenfields).",
        sr = "No soft reserves yet. Everyone's playing it cool.",
        loot = "No loot yet. The bin chickens are circling.",
        attendance = "No raids recorded yet. Attendance: theoretical.",
        profs = "Nobody's shared their professions yet. Tell them to open their tradeskill windows.",
        feed = "Quiet on the street tonight. Too quiet.",
        buffs = "Get in a group and this lights up.",
    },
}

--- Fills {name}/{boss}/{object}/{buff} placeholders.
function GF.Flavor.Fill(line, vars)
    if type(line) ~= "string" then return "" end
    vars = vars or {}
    return (line:gsub("{(%w+)}", function(k)
        local v = vars[k]
        if v == nil then return "{" .. k .. "}" end
        return tostring(v)
    end))
end

function GF.Flavor.Random(list, vars)
    local pick = GF.Util.Pick(list)
    return GF.Flavor.Fill(pick, vars)
end
