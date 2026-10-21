--[[ Greenfields - Data/Buffs.lua
     Raid buff categories for WoW Forever, the camp objects that stand in for them, and
     the professions that build those objects.

     Sources: Blizzard Forever beta dev notes (Sept 24 - Oct 16 2026), Wowhead Forever
     datamine, and the shipped game data (recipe -> kit item IDs). Spell IDs are Classic
     rank IDs; matching also goes by the localized name read at runtime, so a renamed or
     re-ranked spell still matches. Never hard-code magnitudes (they changed). ]]

local _, GF = ...

local D = {}
GF.BuffData = D

-- who: which part of the raid benefits ("all", "mana" = healers/casters, "physical" = melee/hunters)
-- camp: key of the camp object that is a (weaker, mutually exclusive) substitute
-- core: one of the big "everyone wants it" buffs the Buff Check grades
-- talent: provided only by a talent/spec, so a class alone doesn't prove it
-- probe: spell IDs a Greenfields client checks with IsPlayerSpell to prove it can provide it
D.categories = {
    { key = "stamina", label = "Stamina", long = "Power Word: Fortitude", classes = { PRIEST = true },
      ids = { 1243, 1244, 1245, 2791, 10937, 10938, 21562, 21564 }, probe = { 1243, 21562 },
      camp = "first_aid_kit", core = true, who = "all", icon = 1243 },
    { key = "wild", label = "Mark of the Wild", long = "Mark / Gift of the Wild", classes = { DRUID = true },
      ids = { 1126, 5232, 6756, 5234, 8907, 9884, 9885, 21849, 21850 }, probe = { 1126, 21849 },
      camp = "enchanted_lute", core = true, who = "all", icon = 1126 },
    { key = "kings", label = "Kings", long = "Blessing of Kings", classes = { PALADIN = true }, blessing = true, minLevel = 20,
      ids = { 20217, 25898 }, probe = { 20217, 25898 },
      camp = "fish_bowl", core = true, who = "all", icon = 20217 },
    { key = "intellect", label = "Intellect", long = "Arcane Intellect / Brilliance", classes = { MAGE = true },
      ids = { 1459, 1460, 1461, 10156, 10157, 23028 }, probe = { 1459, 23028 },
      camp = "incense_candle", core = true, who = "mana", icon = 1459 },
    { key = "spirit", label = "Spirit", long = "Divine Spirit", classes = { PRIEST = true }, minLevel = 30,
      ids = { 14752, 14818, 14819, 27841, 27681 }, probe = { 14752, 27681 },
      camp = "faction_banner", core = true, who = "mana", icon = 14752 },
    { key = "wisdom", label = "Wisdom", long = "Blessing of Wisdom", classes = { PALADIN = true }, blessing = true,
      ids = { 19742, 19850, 19852, 19853, 19854, 25290, 25894, 25918 }, probe = { 19742, 25894 },
      camp = "mana_well", core = true, who = "mana", icon = 19742 },
    { key = "might", label = "Might", long = "Blessing of Might", classes = { PALADIN = true }, blessing = true,
      ids = { 19740, 19834, 19835, 19836, 19837, 19838, 25291, 25782, 25916 }, probe = { 19740, 25782 },
      camp = "lodestone", core = true, who = "physical", icon = 19740 },
    { key = "strength", label = "Strength of Earth", long = "Strength of Earth Totem", classes = { SHAMAN = true },
      ids = { 8075, 8160, 8161, 10442, 25361, 8076, 8162, 8163, 10441, 25362 }, probe = { 8075 },
      camp = "sharpening_wheel", core = true, who = "physical", icon = 8075 },
    { key = "crit", label = "Crit Aura", long = "Moonkin Aura (spell crit)", classes = { DRUID = true }, talent = true,
      ids = { 24907, 24858 }, probe = { 24858, 24907 },
      camp = "camp_chair", core = true, who = "mana", icon = 24858 },

    -- class-only buffs (no camp substitute)
    { key = "lotp", label = "Leader of the Pack", long = "Leader of the Pack (melee/ranged crit)", classes = { DRUID = true }, talent = true,
      ids = { 17007, 24932 }, probe = { 17007 }, who = "physical", icon = 17007 },
    { key = "battleshout", label = "Battle Shout", long = "Battle Shout", classes = { WARRIOR = true },
      ids = { 6673, 5242, 6192, 11549, 11550, 11551, 25289 }, probe = { 6673 }, who = "physical", icon = 6673 },
    { key = "trueshot", label = "Trueshot Aura", long = "Trueshot Aura", classes = { HUNTER = true }, talent = true,
      ids = { 19506, 20905, 20906 }, probe = { 19506 }, who = "physical", icon = 19506 },
    { key = "grace", label = "Grace of Air", long = "Grace of Air Totem", classes = { SHAMAN = true },
      ids = { 8835, 10627, 25359, 8836, 10626, 25360 }, probe = { 8835 }, who = "physical", icon = 8835 },
    { key = "windfury", label = "Windfury", long = "Windfury Totem", classes = { SHAMAN = true }, weapon = true,
      ids = { 8512, 10613, 10614 }, probe = { 8512 }, who = "physical", icon = 8512 },
    { key = "manaspring", label = "Mana Spring", long = "Mana Spring Totem", classes = { SHAMAN = true },
      ids = { 5675, 10495, 10496, 10497, 5677, 10491, 10493, 10494 }, probe = { 5675 }, who = "mana", icon = 5675 },
    { key = "bloodpact", label = "Blood Pact", long = "Blood Pact (Imp)", classes = { WARLOCK = true },
      ids = { 6307, 7804, 7805, 11766, 11767 }, probe = { 688 }, who = "all", icon = 6307 },
    { key = "salvation", label = "Salvation", long = "Salvation (threat)", classes = { PALADIN = true },
      ids = { 1038, 25895 }, probe = { 1038 }, who = "all", icon = 1038 },
    { key = "light", label = "Light", long = "Blessing of Light", classes = { PALADIN = true }, blessing = true,
      ids = { 19977, 19978, 19979, 25890 }, probe = { 19977 }, who = "all", icon = 19977 },
    { key = "shadowprot", label = "Shadow Prot", long = "Shadow Protection", classes = { PRIEST = true },
      ids = { 976, 10957, 10958, 27683 }, probe = { 976 }, who = "all", icon = 976 },
    { key = "aura", label = "Paladin Aura", long = "Devotion / Retribution / Concentration / Resistance Aura", classes = { PALADIN = true },
      ids = { 465, 10290, 643, 10291, 1032, 10292, 10293, 7294, 10298, 10299, 10300, 10301, 19746,
              19891, 19899, 19900, 19888, 19897, 19898, 19876, 19895, 19896 }, probe = { 465 }, who = "all", icon = 465 },
    { key = "wildres", label = "Aspect of the Wild", long = "Aspect of the Wild (nature res)", classes = { HUNTER = true },
      ids = { 20043, 20190 }, probe = { 20043 }, who = "all", icon = 20043 },
}

D.byKey = {}
for i, c in ipairs(D.categories) do
    c.order = i
    D.byKey[c.key] = c
end

-- Profession skill lines on Forever (12 professions; no Jewelcrafting/Inscription)
D.professions = {
    [171] = { name = "Alchemy", icon = "Interface\\Icons\\Trade_Alchemy" },
    [164] = { name = "Blacksmithing", icon = "Interface\\Icons\\Trade_BlackSmithing" },
    [333] = { name = "Enchanting", icon = "Interface\\Icons\\Trade_Engraving" },
    [202] = { name = "Engineering", icon = "Interface\\Icons\\Trade_Engineering" },
    [182] = { name = "Herbalism", icon = "Interface\\Icons\\Trade_Herbalism" },
    [165] = { name = "Leatherworking", icon = "Interface\\Icons\\Trade_LeatherWorking" },
    [186] = { name = "Mining", icon = "Interface\\Icons\\Trade_Mining" },
    [393] = { name = "Skinning", icon = "Interface\\Icons\\INV_Misc_Pelt_Wolf_01" },
    [197] = { name = "Tailoring", icon = "Interface\\Icons\\Trade_Tailoring" },
    [129] = { name = "First Aid", icon = "Interface\\Icons\\Spell_Holy_SealOfSacrifice", secondary = true },
    [185] = { name = "Cooking", icon = "Interface\\Icons\\INV_Misc_Food_15", secondary = true },
    [356] = { name = "Fishing", icon = "Interface\\Icons\\Trade_Fishing", secondary = true },
}
D.professionOrder = { 171, 164, 333, 202, 165, 197, 182, 186, 393, 185, 129, 356 }

-- Child skill lines (expansion-style sub-lines) map back to their parent.
D.childSkillLines = { [2937] = 164, [2938] = 165, [2939] = 171, [2940] = 333, [2941] = 202, [2942] = 197,
                      [2943] = 182, [2944] = 186, [2945] = 393, [2946] = 185, [2947] = 129, [2948] = 356 }

--- Camp objects. recipes/items are listed tier 1, tier 2, tier 3 (every tier also grants the
-- tier-1 buff). `aura` is the hidden component aura inside "Camp Benefits".
D.camp = {
    { key = "first_aid_kit", name = "First Aid Kit", prof = 129, buff = "stamina", aura = 1230124,
      recipes = { 1230117, 1262996, 1263001 }, items = { 279968, 279940 } },
    { key = "enchanted_lute", name = "Enchanted Lute", prof = 333, buff = "wild", aura = 1230653,
      recipes = { 1230643, 1263056, 1263082 }, items = { 279976, 279985, 279987 } },
    { key = "fish_bowl", name = "Fish Bowl", prof = 356, buff = "kings", aura = 1230098,
      recipes = { 1229745, 1262990, 1262998 }, items = { 279967, 279965, 279966 } },
    { key = "incense_candle", name = "Incense Candle", prof = 182, buff = "intellect", aura = 1229513,
      recipes = { 1229705, 1262980, 1263070 }, items = { 279962, 279964, 279947 } },
    { key = "faction_banner", name = "Faction Banner", prof = 197, buff = "spirit", aura = 1229718,
      recipes = { 1229504, 1263425, 1263032, 1263080 }, items = { 279972, 279973, 279943, 279959 },
      note = "Own faction only" },
    { key = "mana_well", name = "Mana Well", prof = 171, buff = "wisdom", aura = 1230587,
      recipes = { 1230564, 1263005, 1263078 }, items = { 279956, 279970, 279990 } },
    { key = "lodestone", name = "Lodestone", prof = 186, buff = "might", aura = 1230164,
      recipes = { 1230161, 1262975, 1263071 }, items = { 279960, 279948, 279952 } },
    { key = "sharpening_wheel", name = "Sharpening Wheel", prof = 164, buff = "strength", aura = 1230172,
      recipes = { 1230171, 1263041, 1263073 }, items = { 279944, 279988, 279955 } },
    { key = "camp_chair", name = "Camp Chair", prof = 393, buff = "crit", aura = 1229519, useSpell = 1307229,
      recipes = { 1229517, 1262985, 1262982 }, items = { 279979, 279969, 279938 },
      note = "Exclusive with Moonkin Aura (Leader of the Pack unconfirmed)" },
    { key = "camp_tent", name = "Camp Tent", prof = 165, aura = 1229451, useSpell = 1307230,
      recipes = { 1229432, 1263031, 1263079 }, items = { 279978, 279941, 279945 },
      note = "Rested XP, then Boosted Rest" },
    { key = "reagent_bot", name = "Reagent Bot", prof = 202,
      recipes = { 1230656, 1263034, 1263083 }, items = { 279950, 279949, 279989 },
      note = "Sells class reagents" },
}
D.campByKey = {}
D.campByBuff = {}
for _, o in ipairs(D.camp) do
    D.campByKey[o.key] = o
    if o.buff then D.campByBuff[o.buff] = o end
end

-- Campfires (Cooking). Objects held: 3 / 5 / 10. Use-level for higher tiers is uncertain.
D.campfires = {
    { key = "basic", name = "Basic Campfire", recipe = 1229737, item = 279981, cooking = 1, slots = 3, useSpells = { 818, 1307227 } },
    { key = "journeyman", name = "Journeyman Campfire", recipe = 1283400, item = 279961, cooking = 140, slots = 5, useSpells = { 1307252 } },
    { key = "expert", name = "Expert Campfire", recipe = 1291341, item = 279974, cooking = 220, slots = 10, useSpells = { 1307237 } },
}

D.CAMP_BENEFITS = 1229741
D.WELCOMING_CAMPFIRE = 1289723
D.CAMPFIRE_NEARBY = 1283391
D.CAMP_COOLDOWN = 3600
D.FIRE_LIFETIME = 600
D.CAMP_PLACE_SPELLS = { 818, 1307227, 1307252, 1307237, 1307229, 1307230, 465447 }

--- Resolves localized names for every category at runtime (one name covers all ranks).
function D:BuildNameSets()
    -- spell names can be uncached at login; rebuild (at most once a minute) until complete
    local now = GF.API.Time()
    if self.names and (self.namesComplete or now - (self.namesBuilt or 0) < 60) then return end
    self.names = {}
    self.idToCat = {}
    self.namesBuilt = now
    local complete = true
    for _, c in ipairs(self.categories) do
        local set = {}
        for _, id in ipairs(c.ids) do
            self.idToCat[id] = c.key
            local n = GF.API.CleanString(GF.API.SpellName(id))
            if n then set[n] = true else complete = false end
        end
        self.names[c.key] = set
    end
    self.namesComplete = complete
    self.campAuraToBuff = {}
    for _, o in ipairs(self.camp) do
        if o.aura and o.buff then self.campAuraToBuff[o.aura] = o.buff end
    end
end

--- CategoryOf(spellId, name) -> category key for a buff seen on a unit, or nil
function D:CategoryOf(spellId, name)
    self:BuildNameSets()
    if spellId and self.idToCat[spellId] then return self.idToCat[spellId] end
    if name and GF.API.Readable(name) then
        for key, set in pairs(self.names) do
            if set[name] then return key end
        end
    end
    return nil
end
