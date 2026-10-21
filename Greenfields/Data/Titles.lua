--[[ Greenfields - Data/Titles.lua
     The stat catalogue behind the Hall of Fame / Hall of Shame.

     Every stat is self-reported: each player's client tracks its own numbers and
     broadcasts them, so a stat only exists for members running Greenfields.

     Fields
       key        stat id (also the wire key - keep stable)
       kind       "sum"  - counter, higher wins
                  "max"  - best single value, higher wins
                  "rank" - only the ordering is ever shown (wealth)
       group      "shame" | "fame"
       title      the crown the current leader wears
       label      what is measured (shown under the title)
       blurb      the roast/brag line on the card
       icon       Media icon name (icon_<name>.tga) or a game icon path
       unit       optional suffix for display
       milestones { {n, "Badge name"}, ... } personal achievements
       source     "self" (combat/events) | "attendance" | "loot" (computed from shared data) ]]

local _, GF = ...

GF.Titles = {
    ---------------------------------------------------------------- shame
    { key = "deaths_raid", kind = "sum", group = "shame", source = "self",
      title = "Stands In Fire", label = "Most deaths in raids",
      blurb = "The floor has never been so thoroughly inspected.",
      icon = "skull",
      milestones = { { 10, "Speed Bump" }, { 50, "Carpet Sample" }, { 100, "Professional Floor Model" }, { 250, "Lives In The Floor Now" } } },

    { key = "deaths_total", kind = "sum", group = "shame", source = "self",
      title = "Spirit Healer's Bestie", label = "Most deaths, anywhere",
      blurb = "On a first-name basis with the angel lady.",
      icon = "skull",
      milestones = { { 25, "Frequent Flyer" }, { 100, "Ghost Run Veteran" }, { 500, "Has A Loyalty Card" } } },

    { key = "deaths_falling", kind = "sum", group = "shame", source = "self",
      title = "Gravity Tester", label = "Deaths to fall damage",
      blurb = "Took the stairs the fast way.",
      icon = "chevron_down",
      milestones = { { 3, "Trust Fall" }, { 10, "Peel Inlet Bridge Jumper" } } },

    { key = "deaths_drowning", kind = "sum", group = "shame", source = "self",
      title = "Peel Inlet Swim Club", label = "Deaths to drowning & fatigue",
      blurb = "Should've brought the floaties.",
      icon = "dot",
      milestones = { { 3, "Floaties Required" } } },

    { key = "first_death_wipe", kind = "sum", group = "shame", source = "self",
      title = "Opening Act", label = "First to die on a wipe",
      blurb = "Sets the tone. Every. Single. Time.",
      icon = "warning",
      milestones = { { 5, "Warm-Up Act" }, { 20, "Wipe Starter" } } },

    { key = "deaths_pvp", kind = "sum", group = "shame", source = "self",
      title = "Got Jumped At The Servo", label = "Deaths to enemy players",
      blurb = "Wrong place, wrong time, every time.",
      icon = "sword",
      milestones = { { 25, "Easy Target" }, { 100, "Walking Honor Point" } } },

    { key = "afk_minutes", kind = "sum", group = "shame", source = "self",
      title = "Durry Break Champion", label = "Minutes spent AFK",
      blurb = "'Back in 5.' Narrator: they were not back in 5.",
      icon = "clock", unit = "min",
      milestones = { { 600, "Smoko Professional" }, { 3000, "Permanent Smoko" } } },

    { key = "flakes", kind = "sum", group = "shame", source = "attendance",
      title = "Said Yeah, Meant Nah", label = "Signed up, didn't show",
      blurb = "Accepted the invite. Accepted nothing else.",
      icon = "calendar",
      milestones = { { 3, "Flaky Pastry" } } },

    { key = "late", kind = "sum", group = "shame", source = "attendance",
      title = "Running On Mandurah Time", label = "Late arrivals to raid",
      blurb = "Pull time is a suggestion, apparently.",
      icon = "clock",
      milestones = { { 5, "Fashionably Late" } } },

    { key = "jumps", kind = "sum", group = "shame", source = "self",
      title = "Skippy", label = "Times jumped",
      blurb = "Bounces around like a roo on the Forrest Highway.",
      icon = "chevron_left",
      milestones = { { 10000, "Pogo Stick" }, { 100000, "Can't Stop, Won't Stop" } } },

    { key = "emotes", kind = "sum", group = "shame", source = "self",
      title = "Doof Doof Merchant", label = "Emotes used (/dance, /flex...)",
      blurb = "Subwoofer in the boot, rattling the whole street.",
      icon = "megaphone",
      milestones = { { 100, "Party Starter" }, { 1000, "Doof Doof" } } },

    { key = "repair_gold", kind = "sum", group = "shame", source = "self",
      title = "Panel Beater's Best Customer", label = "Gold spent on repairs",
      blurb = "The blacksmith named a kid after you.",
      icon = "hammer", unit = "g",
      milestones = { { 100, "Smash Repairs Regular" }, { 1000, "Write-Off" } } },

    { key = "duel_losses", kind = "sum", group = "shame", source = "self",
      title = "Got Smacked At Maccas", label = "Duels lost",
      blurb = "Started it in the drive-thru. Lost it in the car park.",
      icon = "sword",
      milestones = { { 10, "Glass Jaw" } } },

    { key = "wipes", kind = "sum", group = "shame", source = "self",
      title = "Wipe Veteran", label = "Boss wipes survived (or not)",
      blurb = "Has seen things. Terrible things. Mostly the floor.",
      icon = "skull",
      milestones = { { 25, "Battle Scarred" }, { 100, "Seen Some Stuff" }, { 500, "Thousand-Yard Stare" } } },

    { key = "drunk", kind = "sum", group = "shame", source = "self",
      title = "Absolutely Rotten", label = "Times got properly drunk",
      blurb = "Started at the pub, finished in a garden bed.",
      icon = "heart",
      milestones = { { 10, "Two Pots Screamer" }, { 50, "Schooner Legend" } } },

    { key = "hearths", kind = "sum", group = "shame", source = "self",
      title = "Mummy's Boy", label = "Hearthstones used",
      blurb = "Runs home more than a uni student with laundry.",
      icon = "home",
      milestones = { { 100, "Homebody" }, { 500, "Never Left The Nest" } } },

    { key = "wealth_low", kind = "rank", group = "shame", source = "self",
      title = "Centrelink's Favourite", label = "Poorest (amount hidden)",
      blurb = "Gold? Never heard of her.",
      icon = "coin", inverse = true },

    ---------------------------------------------------------------- fame
    { key = "pvp_kills", kind = "sum", group = "fame", source = "self",
      title = "Eshay Brah", label = "Most PvP killing blows",
      blurb = "Adlay. Bag of hits, bag of kills.",
      icon = "sword",
      milestones = { { 10, "Corner Lurker" }, { 100, "Servo Menace" }, { 500, "Most Wanted In Mandurah" } } },

    { key = "loot_raid", kind = "sum", group = "fame", source = "self",
      title = "Bin Chicken", label = "Biggest Loot Whore (rare+ items from raids)",
      blurb = "Beak first into every bin. Leaves nothing for anyone.",
      icon = "bag",
      milestones = { { 10, "Five-Finger Discount" }, { 50, "Dumpster Diver" }, { 150, "Certified Bin Chicken" } } },

    { key = "loot_epics", kind = "sum", group = "fame", source = "self",
      title = "Purple Rain", label = "Epics looted, anywhere",
      blurb = "Dripping in purple like a Fremantle supporter.",
      icon = "star_fill",
      milestones = { { 5, "Ooh, Shiny" }, { 25, "Purple Patch" } } },

    { key = "wealth", kind = "rank", group = "fame", source = "self",
      title = "Mandurah Millionaire", label = "Richest (amount hidden)",
      blurb = "Rich. How rich? Wouldn't you like to know.",
      icon = "coin" },

    { key = "attendance", kind = "max", group = "fame", source = "attendance",
      title = "Ride Or Die", label = "Best raid attendance %",
      blurb = "Shows up more reliably than the 4am garbage truck.",
      icon = "check", unit = "%" },

    { key = "consumables", kind = "sum", group = "fame", source = "self",
      title = "Chemist Warehouse Loyalty Card", label = "Potions, elixirs & flasks consumed",
      blurb = "Prescription: everything. Twice.",
      icon = "heart",
      milestones = { { 50, "Regular Customer" }, { 500, "Pharmacy Platinum" } } },

    { key = "rezzes", kind = "sum", group = "fame", source = "self",
      title = "Paramedic", label = "Resurrections cast",
      blurb = "Back from the dead faster than a cheap servo pie.",
      icon = "heart",
      milestones = { { 50, "Defibrillator" }, { 250, "Lazarus Pit Crew" } } },

    { key = "fish", kind = "sum", group = "fame", source = "self",
      title = "Blue Manna Crabber", label = "Things caught fishing",
      blurb = "Lives on the jetty. Smells like it too.",
      icon = "dot",
      milestones = { { 100, "Jetty Regular" }, { 1000, "Crab Fest Legend" } } },

    { key = "camps", kind = "sum", group = "fame", source = "self",
      title = "Happy Camper", label = "Camp objects & campfires placed",
      blurb = "Treats the world like the Falcon Bay caravan park.",
      icon = "campfire",
      milestones = { { 10, "Weekend Camper" }, { 100, "Grey Nomad" } } },

    { key = "quests", kind = "sum", group = "fame", source = "self",
      title = "Mutual Obligations Met", label = "Quests turned in",
      blurb = "Centrelink would be so proud.",
      icon = "clipboard",
      milestones = { { 100, "Job Seeker" }, { 1000, "Employee Of The Month" } } },

    { key = "duel_wins", kind = "sum", group = "fame", source = "self",
      title = "Car Park Scrapper", label = "Duels won",
      blurb = "Meet me outside. No, really.",
      icon = "sword",
      milestones = { { 10, "Scrapper" }, { 100, "Undisputed" } } },

    { key = "flights", kind = "sum", group = "fame", source = "self",
      title = "Uber Eats Driver", label = "Flight paths taken",
      blurb = "Spends more time in transit than a Kwinana Freeway commuter.",
      icon = "pin",
      milestones = { { 100, "Frequent Flyer" }, { 500, "Gold Status" } } },

    { key = "rezzed", kind = "sum", group = "fame", source = "self",
      title = "Lazarus", label = "Times brought back from the dead",
      blurb = "Dies a lot. Refuses to stay dead. Respect.",
      icon = "sync",
      milestones = { { 25, "Second Chances" }, { 100, "Nine Lives" } } },

    { key = "honor_kills", kind = "sum", group = "fame", source = "self",
      title = "Neighbourhood Menace", label = "Honorable kills",
      blurb = "The other faction has a restraining order out.",
      icon = "crown",
      milestones = { { 100, "Troublemaker" }, { 1000, "Public Enemy" } } },

    { key = "sr_wins", kind = "sum", group = "fame", source = "loot",
      title = "Rigged Dice", label = "Soft-reserve rolls won",
      blurb = "Statistically suspicious. We're watching you.",
      icon = "dice" },
}

--- Game icon for each title (classic-era icon files present in every client); shown in a
-- gold frame wherever a title appears. Swap any of these for custom art later.
GF.TitleArt = {
    deaths_raid = "Spell_Fire_Immolation", deaths_total = "Spell_Shadow_RaiseDead",
    deaths_falling = "Spell_Magic_FeatherFall", deaths_drowning = "Spell_Shadow_DemonBreath",
    first_death_wipe = "Spell_Shadow_DeathScream", deaths_pvp = "Ability_Rogue_Ambush",
    afk_minutes = "Spell_Nature_Sleep", flakes = "Ability_Vanish", late = "INV_Misc_PocketWatch_01",
    jumps = "Ability_Rogue_Sprint", emotes = "Ability_Warrior_BattleShout", repair_gold = "INV_Hammer_20",
    duel_losses = "Spell_Frost_Stun", wipes = "Spell_Shadow_AnimateDead", drunk = "INV_Drink_04",
    hearths = "INV_Misc_Rune_01", wealth_low = "INV_Misc_Coin_06", pvp_kills = "Ability_Rogue_Eviscerate",
    loot_raid = "INV_Misc_Bag_09", loot_epics = "INV_Misc_Gem_Amethyst_02", wealth = "INV_Misc_Coin_02",
    attendance = "Ability_Mount_RidingHorse", consumables = "INV_Potion_51", rezzes = "Spell_Holy_Resurrection",
    fish = "Trade_Fishing", camps = "Spell_Fire_Fire", quests = "INV_Misc_Note_02", duel_wins = "Ability_DualWield",
    flights = "Ability_Hunter_EagleEye", rezzed = "Spell_Nature_Reincarnation", honor_kills = "INV_BannerPVP_02",
    sr_wins = "INV_Misc_Coin_03",
}

GF.TitlesByKey = {}
for i, t in ipairs(GF.Titles) do
    t.order = i
    if GF.TitleArt[t.key] then t.art = "Interface\\Icons\\" .. GF.TitleArt[t.key] end
    -- painted art from Media/art (Data/Art.lua) wins over the game icon
    local custom = GF.Art and GF.Art.titles and GF.Art.titles[t.key]
    if custom then t.art = custom end
    GF.TitlesByKey[t.key] = t
end

--- Wealth is never broadcast as an amount. Each client sends only this log-scale score
-- (about 12% wide steps), and the UI only ever shows the resulting ordering.
function GF.WealthScore(copper)
    local gold = math.max(0, (tonumber(copper) or 0) / 10000)
    return math.floor(20 * math.log10(gold + 1))
end
