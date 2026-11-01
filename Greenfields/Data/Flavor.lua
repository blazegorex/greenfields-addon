--[[ Greenfields - Data/Flavor.lua
     The neighbourhood's voice. Every line here is picked at random somewhere in the UI.
     {name} is replaced with a player's short name, {boss} with an encounter name. ]]

local _, GF = ...

GF.Flavor = {
    taglines = {
        "Est. Mandurah, WA  \194\183  She'll be right",
        "Neighbourhood Watch is watching",
        "No ninjas. Plenty of trolleys.",
        "Proudly unfunded by Centrelink",
        "Where the floor is a raid mechanic",
        "Population: us. Property values: low.",
        "Lock ya bikes, we're raiding",
        "Harder to get into than Crab Fest parking",
        "Open late, like the servo",
        "Cash only. No receipts. No questions.",
        "The foil's just for the heat",
        "Been up since Tuesday",
        "Smells like burning. It's fine.",
        "Ask for Daz. Don't ask what for.",
        "Every window boarded, every buff up",
        "Fifty a point. Raid's free.",
        "Scratching since Tuesday",
        "Who's holding?",
        "Clean since Thursday arvo",
        "Two moons? Mate, go to bed.",
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
        "Don't feed the staffy, {name}.",
        "{name}! Thought the Rangers finally got ya.",
        "{name}'s back. Someone check the copper's still in the walls.",
        "Knock three times, {name}. Not the front door.",
        "{name}! You look terrible. When'd you last sleep?",
        "Oi {name}, that you in the hoodie? Thought you were the cops.",
        "Welcome home, {name}. The Commodore's still on fire.",
        "{name}'s online. Somebody hide the good foil.",
        "Back already, {name}? Thought you weren't out till Thursday.",
        "The staffy remembers you, {name}. That's not a good thing.",
        "G'day {name}. You owe Daz forty bucks.",
        "{name}! You holding?",
        "{name}'s back, and they've brought their own foil.",
        "You right, {name}? You're scratching again.",
        "That's not a shadow person, {name}. That's the raid leader.",
        "Sit down, {name}. You've been pacing since you logged in.",
        "{name}'s up. Been up. Hasn't come down.",
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
        "Not even forty bucks and a lawyer could save that.",
        "We didn't wipe, we did a tactical lie-down.",
        "Absolute scenes. Absolutely cooked.",
        "Floor's comfy, hey?",
        "{boss} would like to thank the academy and our healers.",
        "Run it back. Nobody tell Centrelink we call this work.",
        "Everyone's down. Nobody saw nothing.",
        "That pull had the focus of a bloke on day four.",
        "Burnt out faster than the Commodore.",
        "Most people on the floor since the last house party.",
        "Raid's been repossessed.",
        "If the cops ask, {boss} started it.",
        "Nobody panic. Someone check the pockets.",
        "That's a wipe. The neighbours have called it in.",
        "{boss} just moved the whole street on.",
        "Whole raid's on the nod.",
        "That went down like a bad batch.",
        "Someone check they're breathing. Nah, they're right.",
        "Everyone's seeing shadow people now. Run it back.",
        "Forty people, one brain cell, and someone's sold it.",
    },

    kills = {
        "{boss} got done like a dinner. Good work, lads.",
        "{boss} is now a former resident of the neighbourhood.",
        "Down goes {boss}. Someone check its pockets.",
        "{boss} cooked. Greenfields remains undefeated (this week).",
        "{boss} just got evicted. No bond back.",
        "{boss} got stripped for parts. Check the pawn shop tomorrow.",
        "{boss}'s gear is already at the pawn shop.",
        "{boss} has been moved on by the residents.",
        "{boss} should've paid Daz.",
        "Someone's got to clean up {boss}. Not it.",
        "{boss} went down harder than the property values.",
        "{boss} just got done for supply.",
        "{boss} came down hard. They always do.",
        "{boss} must've been cut with something. Went down easy.",
        "{boss} owed money. Not any more.",
    },

    deaths = {
        fire = { "Mate. It's FIRE, {name}. You don't sit in it.", "Total fire ban, {name}. TOTAL.", "{name}'s gone up like the Commodore.", "Put it out, {name}. The fire, mate. Put out the fire.", "{name} held the lighter too close." },
        falling = { "{name} took the stairs the fast way.", "Gravity: 1, {name}: 0.", "Came off the roof again, {name}.", "That's not how you get off the Peel Inlet bridge, {name}.", "{name} came down. Everyone comes down eventually." },
        drowning = { "Peel Inlet Swim Club claims another member: {name}.", "Should've brought the floaties, {name}.", "The canal's got {name} again." },
        pvp = { "{name} got jumped at the servo.", "Rolled by randoms. Tough luck, {name}.", "{name} got rolled behind the shops.", "They took your shoes, {name}. They're on the wire now.", "{name} owed someone money." },
        generic = { "Down like a sack of spuds, {name}.", "Have a lie down, {name}.", "RIP {name}. Rez incoming. Probably.", "Someone check {name}'s pockets before the medics get here.", "{name}'s having a lie down in the gutter.", "{name} copped a bad batch.", "{name}'s on the nod. Give it a minute.", "{name} mixed their flasks again.", "Somebody roll {name} on their side." },
    },

    campPing = {
        "OI {name}! The raid needs your {object}. Get it on the ground.",
        "{name}, chuck your {object} down, the raid's missing {buff}.",
        "Camp duty, {name}: {object}. Don't make us beg.",
        "{name}, you're on the drum. {object}. Now.",
        "{name}, the drum's lit and your {object}'s not down.",
        "{name}, put the pipe down and get your {object} out.",
    },

    tooltips = {
        richest = "Rich. How rich? Wouldn't you like to know.",
        poorest = "Gold? Never heard of her.",
    },

    emptyStates = {
        roster = "No one's home. Suspicious.",
        events = "No raids planned. Go touch grass (it's dead, it's Greenfields).",
        sr = "No soft reserves yet. Everyone's playing it cool.",
        loot = "No loot yet. The pawn shop's getting nervous.",
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
