--[[ tools/harness/wow_mock_data.lua  --  static data for the mock client.

       * MOCK.validEvents: the event whitelist (registering anything else raises)
       * MOCK.secretArgs: which event payload arguments turn secret per secret category
       * MOCK.items / MOCK.spells / MOCK.atlases: fake game databases
       * MOCK.fontFiles: font paths the client can load
     run.py adds every spell ID referenced by Greenfields/Data/Buffs.lua via MOCK.AddSpell. ]]

local MOCK = ...
local R = MOCK.R

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------
local EVENTS = [[
ADDON_LOADED ADDONS_UNLOADING VARIABLES_LOADED PLAYER_LOGIN PLAYER_LOGOUT PLAYER_ENTERING_WORLD
PLAYER_LEAVING_WORLD SPELLS_CHANGED UI_SCALE_CHANGED DISPLAY_SIZE_CHANGED CVAR_UPDATE SETTINGS_LOADED
FIRST_FRAME_RENDERED LOADING_SCREEN_ENABLED LOADING_SCREEN_DISABLED ZONE_CHANGED ZONE_CHANGED_NEW_AREA
ZONE_CHANGED_INDOORS PLAYER_GUILD_UPDATE GUILD_ROSTER_UPDATE GUILD_RANKS_UPDATE GUILD_MOTD
GUILD_PARTY_STATE_UPDATED GROUP_ROSTER_UPDATE GROUP_JOINED GROUP_LEFT GROUP_FORMED PARTY_LEADER_CHANGED
PARTY_LOOT_METHOD_CHANGED PARTY_INVITE_REQUEST PARTY_MEMBER_ENABLE PARTY_MEMBER_DISABLE READY_CHECK
READY_CHECK_CONFIRM READY_CHECK_FINISHED ROLE_CHANGED_INFORM PLAYER_ROLES_ASSIGNED
INSTANCE_GROUP_SIZE_CHANGED UPDATE_INSTANCE_INFO PLAYER_DIFFICULTY_CHANGED ENCOUNTER_START ENCOUNTER_END
BOSS_KILL ENCOUNTER_LOOT_RECEIVED INSTANCE_ENCOUNTER_ENGAGE_UNIT RAID_TARGET_UPDATE
PLAYER_REGEN_DISABLED PLAYER_REGEN_ENABLED PLAYER_DEAD PLAYER_ALIVE PLAYER_UNGHOST RESURRECT_REQUEST
PLAYER_SKINNED PLAYER_FLAGS_CHANGED PLAYER_UPDATE_RESTING PLAYER_CONTROL_LOST PLAYER_CONTROL_GAINED
PLAYER_STARTED_MOVING PLAYER_STOPPED_MOVING PLAYER_MOUNT_DISPLAY_CHANGED PLAYER_LEVEL_UP
PLAYER_LEVEL_CHANGED PLAYER_XP_UPDATE PLAYER_MONEY PLAYER_TRADE_MONEY TRADE_MONEY_CHANGED
PLAYER_TARGET_CHANGED PLAYER_FOCUS_CHANGED PLAYER_EQUIPMENT_CHANGED PLAYER_TALENT_UPDATE
TRAIT_CONFIG_UPDATED ACTIVE_TALENT_GROUP_CHANGED CHARACTER_POINTS_CHANGED PLAYER_PVP_KILLS_CHANGED
PLAYER_PVP_RANK_CHANGED PARTY_KILL HEARTHSTONE_BOUND PLAYER_CAMPING PLAYER_QUITING TIME_PLAYED_MSG
UNIT_AURA UNIT_HEALTH UNIT_MAXHEALTH UNIT_POWER_UPDATE UNIT_POWER_FREQUENT UNIT_MAXPOWER UNIT_DISPLAYPOWER
UNIT_LEVEL UNIT_NAME_UPDATE UNIT_FLAGS UNIT_CONNECTION UNIT_PHASE UNIT_INVENTORY_CHANGED
UNIT_MODEL_CHANGED UNIT_PORTRAIT_UPDATE UNIT_TARGET UNIT_PET UNIT_THREAT_LIST_UPDATE UNIT_COMBAT
UNIT_SPELLCAST_START UNIT_SPELLCAST_STOP UNIT_SPELLCAST_SUCCEEDED UNIT_SPELLCAST_FAILED
UNIT_SPELLCAST_FAILED_QUIET UNIT_SPELLCAST_INTERRUPTED UNIT_SPELLCAST_CHANNEL_START
UNIT_SPELLCAST_CHANNEL_STOP UNIT_SPELLCAST_CHANNEL_UPDATE UNIT_SPELLCAST_DELAYED UNIT_SPELLCAST_SENT
UNIT_ENTERED_VEHICLE UNIT_EXITED_VEHICLE SPELL_UPDATE_COOLDOWN SPELL_UPDATE_USABLE SPELL_UPDATE_CHARGES
ACTIONBAR_UPDATE_COOLDOWN ACTIONBAR_SLOT_CHANGED LEARNED_SPELL_IN_TAB LEARNED_SPELL_IN_SKILL_LINE
SKILL_LINES_CHANGED NEW_RECIPE_LEARNED TRADE_SKILL_SHOW TRADE_SKILL_CLOSE TRADE_SKILL_DATA_SOURCE_CHANGED
TRADE_SKILL_DATA_SOURCE_CHANGING TRADE_SKILL_LIST_UPDATE TRADE_SKILL_ITEM_CRAFTED_RESULT
TRADE_SKILL_CRAFT_BEGIN UPDATE_TRADESKILL_CAST_STOPPED BAG_UPDATE BAG_UPDATE_DELAYED BAG_UPDATE_COOLDOWN
BAG_NEW_ITEMS_UPDATED ITEM_LOCK_CHANGED ITEM_PUSH ITEM_DATA_LOAD_RESULT GET_ITEM_INFO_RECEIVED
SPELL_DATA_LOAD_RESULT UPDATE_INVENTORY_DURABILITY MERCHANT_SHOW MERCHANT_CLOSED MERCHANT_UPDATE
BANKFRAME_OPENED BANKFRAME_CLOSED MAIL_SHOW MAIL_CLOSED MAIL_INBOX_UPDATE TRADE_SHOW TRADE_CLOSED
TRADE_ACCEPT_UPDATE TRADE_REQUEST AUCTION_HOUSE_SHOW AUCTION_HOUSE_CLOSED GUILDBANKFRAME_OPENED
GUILDBANKFRAME_CLOSED PLAYER_INTERACTION_MANAGER_FRAME_SHOW PLAYER_INTERACTION_MANAGER_FRAME_HIDE
GOSSIP_SHOW GOSSIP_CLOSED QUEST_ACCEPTED QUEST_TURNED_IN QUEST_COMPLETE QUEST_DETAIL QUEST_LOG_UPDATE
QUEST_REMOVED LOOT_READY LOOT_OPENED LOOT_CLOSED LOOT_SLOT_CLEARED LOOT_SLOT_CHANGED START_LOOT_ROLL
CANCEL_LOOT_ROLL LOOT_ROLLS_COMPLETE CONFIRM_LOOT_ROLL CONFIRM_DISENCHANT_ROLL LOOT_BIND_CONFIRM
OPEN_MASTER_LOOT_LIST UPDATE_MASTER_LOOT_LIST CHAT_MSG_ADDON CHAT_MSG_ADDON_LOGGED CHAT_MSG_SAY
CHAT_MSG_YELL CHAT_MSG_EMOTE CHAT_MSG_TEXT_EMOTE CHAT_MSG_GUILD CHAT_MSG_OFFICER CHAT_MSG_PARTY
CHAT_MSG_PARTY_LEADER CHAT_MSG_RAID CHAT_MSG_RAID_LEADER CHAT_MSG_RAID_WARNING CHAT_MSG_INSTANCE_CHAT
CHAT_MSG_INSTANCE_CHAT_LEADER CHAT_MSG_WHISPER CHAT_MSG_WHISPER_INFORM CHAT_MSG_CHANNEL CHAT_MSG_SYSTEM
CHAT_MSG_LOOT CHAT_MSG_MONEY CHAT_MSG_SKILL CHAT_MSG_TRADESKILLS CHAT_MSG_COMBAT_XP_GAIN
CHAT_MSG_COMBAT_HONOR_GAIN CHAT_MSG_COMBAT_FACTION_CHANGE CHAT_MSG_MONSTER_SAY CHAT_MSG_MONSTER_YELL
CHAT_MSG_MONSTER_EMOTE CHAT_MSG_RAID_BOSS_EMOTE CHAT_MSG_RAID_BOSS_WHISPER CHAT_MSG_BN_WHISPER
CHAT_MSG_IGNORED CHAT_MSG_AFK CHAT_MSG_DND CHAT_MSG_CHANNEL_NOTICE MIRROR_TIMER_START MIRROR_TIMER_STOP
MIRROR_TIMER_PAUSE DUEL_REQUESTED DUEL_FINISHED DUEL_INBOUNDS DUEL_OUTOFBOUNDS UPDATE_MOUSEOVER_UNIT
MODIFIER_STATE_CHANGED GLOBAL_MOUSE_DOWN GLOBAL_MOUSE_UP CURSOR_CHANGED UPDATE_BINDINGS UI_ERROR_MESSAGE
UI_INFO_MESSAGE ADDON_ACTION_BLOCKED ADDON_ACTION_FORBIDDEN TAXIMAP_OPENED TAXIMAP_CLOSED
UPDATE_BATTLEFIELD_STATUS UPDATE_FACTION UPDATE_SHAPESHIFT_FORM UPDATE_SHAPESHIFT_FORMS COMPANION_UPDATE
NAME_PLATE_UNIT_ADDED NAME_PLATE_UNIT_REMOVED CALENDAR_UPDATE_EVENT_LIST CALENDAR_UPDATE_INVITE_LIST
CINEMATIC_START CINEMATIC_STOP PLAY_MOVIE EQUIPMENT_SETS_CHANGED SPELL_CONFIRMATION_PROMPT
COMBAT_LOG_EVENT_UNFILTERED COMBAT_LOG_EVENT COMBAT_TEXT_UPDATE
]]
for ev in R.gmatch(EVENTS, "%S+") do MOCK.validEvents[ev] = true end

-------------------------------------------------------------------------------
-- Event payload secrecy: event -> { category = {argIndex, ...} }
-------------------------------------------------------------------------------
local CHAT = { 1, 2, 5, 12 }   -- text, playerName, playerName2, guid
for _, ev in R.ipairs({ "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_EMOTE", "CHAT_MSG_TEXT_EMOTE", "CHAT_MSG_GUILD",
    "CHAT_MSG_OFFICER", "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER", "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER",
    "CHAT_MSG_RAID_WARNING", "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER", "CHAT_MSG_WHISPER",
    "CHAT_MSG_WHISPER_INFORM", "CHAT_MSG_CHANNEL", "CHAT_MSG_SYSTEM", "CHAT_MSG_LOOT", "CHAT_MSG_MONEY",
    "CHAT_MSG_SKILL", "CHAT_MSG_TRADESKILLS", "CHAT_MSG_COMBAT_XP_GAIN", "CHAT_MSG_COMBAT_HONOR_GAIN",
    "CHAT_MSG_MONSTER_SAY", "CHAT_MSG_MONSTER_YELL", "CHAT_MSG_MONSTER_EMOTE", "CHAT_MSG_RAID_BOSS_EMOTE",
    "CHAT_MSG_RAID_BOSS_WHISPER" }) do
    MOCK.secretArgs[ev] = { chat = CHAT }
end
MOCK.secretArgs.CHAT_MSG_ADDON = { addon = { 2, 4 } }
MOCK.secretArgs.CHAT_MSG_ADDON_LOGGED = { addon = { 2, 4 } }
for _, ev in R.ipairs({ "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP",
    "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_CHANNEL_START",
    "UNIT_SPELLCAST_CHANNEL_STOP", "UNIT_SPELLCAST_SENT" }) do
    MOCK.secretArgs[ev] = { spell = { 2, 3 } }
end
MOCK.secretArgs.UNIT_AURA = { auras = { 2 } }
-- FACTS A.8: whether encounter payloads are secret is UNKNOWN -> the strict mode hides them all
MOCK.secretArgs.ENCOUNTER_START = { encounter = { 1, 2, 3, 4 } }
MOCK.secretArgs.ENCOUNTER_END = { encounter = { 1, 2, 3, 4, 5 } }
MOCK.secretArgs.BOSS_KILL = { encounter = { 1, 2 } }
MOCK.secretArgs.ENCOUNTER_LOOT_RECEIVED = { names = { 5 }, encounter = { 1 } }
MOCK.secretArgs.PARTY_KILL = { guids = { 1, 2 } }
MOCK.secretArgs.READY_CHECK = { names = { 1 } }
MOCK.secretArgs.RESURRECT_REQUEST = { names = { 1 } }
MOCK.secretArgs.DUEL_REQUESTED = { names = { 1 } }

-------------------------------------------------------------------------------
-- Fonts the client can load (lower-cased, forward slashes)
-------------------------------------------------------------------------------
MOCK.fontFiles = {}
for _, p in R.ipairs({ "Fonts\\FRIZQT__.TTF", "Fonts\\ARIALN.TTF", "Fonts\\MORPHEUS.TTF", "Fonts\\SKURRI.TTF",
    "Fonts\\FRIZQT___CYR.TTF", "Fonts\\2002.TTF", "Fonts\\2002B.TTF", "Fonts\\ARHei.ttf", "Fonts\\bLEI00D.ttf",
    "Fonts\\K_Damage.TTF", "Fonts\\K_Pagetext.TTF", "Fonts\\MORPHEUS_CYR.TTF", "Fonts\\NIM_____.ttf" }) do
    MOCK.fontFiles[R.lower(R.gsub(p, "\\", "/"))] = true
end

-------------------------------------------------------------------------------
-- Items. quality: 0 poor .. 5 legendary. icon: fileID. spell: use spell id.
-------------------------------------------------------------------------------
MOCK.items = {}
local function item(id, name, q, ilvl, minLevel, itype, sub, stack, equip, icon, sell, classID, subID, bind, spell)
    MOCK.items[id] = { name = name, quality = q, ilvl = ilvl or 1, minLevel = minLevel or 0, type = itype or "Miscellaneous",
        subType = sub or "Junk", stack = stack or 1, equipLoc = equip or "", icon = icon or 134400, sell = sell or 0,
        classID = classID or 15, subclassID = subID or 0, bind = bind or 0, spell = spell }
end
item(6948, "Hearthstone", 1, 1, 0, "Miscellaneous", "Junk", 1, "", 134414, 0, 15, 0, 1, 8690)
item(2589, "Linen Cloth", 1, 5, 0, "Tradeskill", "Cloth", 20, "", 132889, 13, 7, 5)
item(2592, "Wool Cloth", 1, 15, 0, "Tradeskill", "Cloth", 20, "", 132911, 33, 7, 5)
item(4306, "Silk Cloth", 1, 25, 0, "Tradeskill", "Cloth", 20, "", 132905, 150, 7, 5)
item(14047, "Runecloth", 1, 50, 0, "Tradeskill", "Cloth", 20, "", 132903, 400, 7, 5)
item(4470, "Simple Wood", 1, 5, 0, "Tradeskill", "Other", 20, "", 134435, 9, 7, 11)
item(4471, "Flint and Tinder", 1, 5, 0, "Tradeskill", "Other", 1, "", 135237, 37, 7, 11)
item(11291, "Star Wood", 1, 40, 0, "Tradeskill", "Other", 20, "", 134436, 1125, 7, 11)
item(272941, "Thick Logs", 1, 50, 0, "Tradeskill", "Other", 20, "", 134435, 500, 7, 11)
item(2318, "Light Leather", 1, 10, 0, "Tradeskill", "Leather", 20, "", 134252, 15, 7, 6)
item(17056, "Light Feather", 1, 10, 0, "Reagent", "Reagent", 20, "", 132917, 1, 5, 0)
item(277651, "Bundle of Scrolls", 2, 20, 0, "Miscellaneous", "Other", 20, "", 134943, 0, 15, 4)
item(13446, "Major Healing Potion", 1, 55, 45, "Consumable", "Potion", 5, "", 134834, 1000, 0, 1, 0, 17534)
item(13444, "Major Mana Potion", 1, 59, 49, "Consumable", "Potion", 5, "", 134854, 1200, 0, 1, 0, 17531)
item(13510, "Flask of the Titans", 1, 60, 50, "Consumable", "Flask", 1, "", 134842, 0, 0, 3, 0, 17626)
item(13512, "Flask of Supreme Power", 1, 60, 50, "Consumable", "Flask", 1, "", 134821, 0, 0, 3, 0, 17628)
item(12404, "Dense Sharpening Stone", 1, 45, 35, "Consumable", "Item Enhancement", 20, "", 135252, 100, 0, 8, 0, 16138)
item(20748, "Brilliant Mana Oil", 1, 55, 45, "Consumable", "Item Enhancement", 5, "", 134723, 1000, 0, 8, 0, 25123)
item(21023, "Dirge's Kickin' Chimaerok Chops", 1, 55, 45, "Consumable", "Food & Drink", 20, "", 134021, 300, 0, 5, 0, 25661)
item(8932, "Alterac Swiss", 1, 55, 45, "Consumable", "Food & Drink", 20, "", 133948, 200, 0, 5, 0, 18234)
item(14530, "Heavy Runecloth Bandage", 1, 58, 0, "Consumable", "Bandage", 20, "", 133682, 400, 0, 7, 0, 18610)
item(21151, "Rumsey Rum Black Label", 1, 25, 0, "Consumable", "Food & Drink", 20, "", 132791, 5, 0, 5, 0, 25804)
item(6657, "Savory Deviate Delight", 1, 18, 10, "Consumable", "Food & Drink", 10, "", 133952, 50, 0, 5, 0, 8212)
item(17202, "Snowball", 1, 1, 0, "Consumable", "Other", 20, "", 132387, 0, 0, 8, 0, 21343)
-- camp objects and kits (Forever)
item(279981, "Basic Campfire Kit", 1, 5, 5, "Miscellaneous", "Other", 5, "", 135805, 50, 15, 4, 0, 1307227)
item(279961, "Journeyman Campfire Kit", 1, 30, 25, "Miscellaneous", "Other", 5, "", 135805, 150, 15, 4, 0, 1307252)
item(279974, "Expert Campfire Kit", 2, 50, 45, "Miscellaneous", "Other", 5, "", 135805, 400, 15, 4, 0, 1307237)
item(279979, "Camp Chair", 1, 10, 5, "Miscellaneous", "Other", 1, "", 132242, 50, 15, 4, 0, 1307229)
item(279978, "Camp Tent", 1, 10, 5, "Miscellaneous", "Other", 1, "", 134427, 50, 15, 4, 0, 1307230)
-- raid loot (fabricated for the harness; Forever's tables are unpublished)
item(281001, "Bark of Bandalar", 4, 66, 60, "Armor", "Cloth", 1, "INVTYPE_CLOAK", 133762, 22000, 4, 1, 1)
item(281002, "Gloomlurker's Lure", 4, 66, 60, "Armor", "Miscellaneous", 1, "INVTYPE_TRINKET", 133434, 25000, 4, 0, 1)
item(281003, "Band of the Wild King", 3, 63, 58, "Armor", "Miscellaneous", 1, "INVTYPE_FINGER", 133345, 9000, 4, 0, 1)
item(281004, "Dreambound Vestments", 4, 70, 60, "Armor", "Cloth", 1, "INVTYPE_ROBE", 132666, 30000, 4, 1, 1)
item(281005, "Chillwind Edge", 4, 68, 60, "Weapon", "Swords", 1, "INVTYPE_WEAPON", 135349, 41000, 2, 7, 1)
item(281006, "Nythus' Dreamthread", 5, 75, 60, "Armor", "Miscellaneous", 1, "INVTYPE_NECK", 133294, 0, 4, 0, 1)
-- crafted gear
item(12360, "Arcanite Bar", 2, 55, 0, "Tradeskill", "Metal & Stone", 20, "", 134459, 2500, 7, 7)
item(14342, "Mooncloth", 2, 55, 0, "Tradeskill", "Cloth", 20, "", 132895, 1000, 7, 5)
item(12359, "Thorium Bar", 1, 50, 0, "Tradeskill", "Metal & Stone", 20, "", 134581, 600, 7, 7)
item(3576, "Tin Bar", 1, 20, 0, "Tradeskill", "Metal & Stone", 20, "", 133217, 25, 7, 7)
item(2840, "Copper Bar", 1, 10, 0, "Tradeskill", "Metal & Stone", 20, "", 133216, 10, 7, 7)
item(1251, "Linen Bandage", 1, 5, 0, "Consumable", "Bandage", 20, "", 133688, 10, 0, 7, 0, 746)
item(3220, "Blood Sausage", 1, 15, 5, "Consumable", "Food & Drink", 20, "", 133972, 30, 0, 5, 0, 433)
item(2681, "Roasted Boar Meat", 1, 5, 1, "Consumable", "Food & Drink", 20, "", 133974, 6, 0, 5, 0, 433)
item(6888, "Herb Baked Egg", 1, 5, 1, "Consumable", "Food & Drink", 20, "", 132834, 6, 0, 5, 0, 433)
item(2862, "Rough Sharpening Stone", 1, 5, 1, "Consumable", "Item Enhancement", 20, "", 135248, 3, 0, 8, 0, 2828)
item(118, "Minor Healing Potion", 1, 5, 1, "Consumable", "Potion", 5, "", 134829, 5, 0, 1, 0, 2370)
item(2455, "Minor Mana Potion", 1, 5, 1, "Consumable", "Potion", 5, "", 134851, 5, 0, 1, 0, 437)
item(4343, "Brown Linen Pants", 2, 10, 5, "Armor", "Cloth", 1, "INVTYPE_LEGS", 134586, 40, 4, 1, 2)
item(11287, "Lesser Magic Wand", 2, 23, 18, "Weapon", "Wands", 1, "INVTYPE_RANGEDRIGHT", 135139, 300, 2, 19, 2)

--- Synthesised item for IDs not in the table (the real client knows every item).
function MOCK.ItemRecord(id)
    local it = MOCK.items[id]
    if it then return it end
    if R.type(id) ~= "number" or id <= 0 or id > 400000 or id ~= R.floor(id) then return nil end
    local q = (id * 7919) % 5
    it = { name = "Item " .. id, quality = q, ilvl = 1 + id % 70, minLevel = 0, type = "Miscellaneous", subType = "Junk",
        stack = 1, equipLoc = "", icon = 134400 + id % 997, sell = id % 1000, classID = 15, subclassID = 0, bind = 0,
        synthetic = true }
    MOCK.items[id] = it
    return it
end

-------------------------------------------------------------------------------
-- Spells
-------------------------------------------------------------------------------
MOCK.spells = {}
function MOCK.AddSpell(id, name, icon)
    if R.type(id) ~= "number" or not name then return end
    local cur = MOCK.spells[id]
    if cur and not cur.generic then return end
    MOCK.spells[id] = { name = name, icon = icon or (136000 + id % 3000) }
end
local function spells(name, ...)
    for i = 1, R.select("#", ...) do MOCK.AddSpell((R.select(i, ...)), name) end
end
spells("Power Word: Fortitude", 1243, 1244, 1245, 2791, 10937, 10938)
spells("Prayer of Fortitude", 21562, 21564)
spells("Mark of the Wild", 1126, 5232, 6756, 5234, 8907, 9884, 9885)
spells("Gift of the Wild", 21849, 21850)
spells("Blessing of Kings", 20217)
spells("Greater Blessing of Kings", 25898)
spells("Arcane Intellect", 1459, 1460, 1461, 10156, 10157)
spells("Arcane Brilliance", 23028)
spells("Divine Spirit", 14752, 14818, 14819, 27841)
spells("Prayer of Spirit", 27681)
spells("Blessing of Wisdom", 19742, 19850, 19852, 19853, 19854, 25290)
spells("Greater Blessing of Wisdom", 25894, 25918)
spells("Blessing of Might", 19740, 19834, 19835, 19836, 19837, 19838, 25291)
spells("Greater Blessing of Might", 25782, 25916)
spells("Strength of Earth Totem", 8075, 8160, 8161, 10442, 25361)
spells("Strength of Earth", 8076, 8162, 8163, 10441, 25362)
spells("Moonkin Aura", 24907)
spells("Moonkin Form", 24858)
spells("Leader of the Pack", 17007, 24932)
spells("Battle Shout", 6673, 5242, 6192, 11549, 11550, 11551, 25289)
spells("Trueshot Aura", 19506, 20905, 20906)
spells("Grace of Air Totem", 8835, 10627, 25359)
spells("Grace of Air", 8836, 10626, 25360)
spells("Windfury Totem", 8512, 10613, 10614)
spells("Mana Spring Totem", 5675, 10495, 10496, 10497)
spells("Mana Spring", 5677, 10491, 10493, 10494)
spells("Blood Pact", 6307, 7804, 7805, 11766, 11767)
spells("Summon Imp", 688)
spells("Salvation", 1038)
spells("Greater Blessing of Salvation", 25895)
spells("Blessing of Light", 19977, 19978, 19979)
spells("Greater Blessing of Light", 25890)
spells("Shadow Protection", 976, 10957, 10958)
spells("Prayer of Shadow Protection", 27683)
spells("Devotion Aura", 465, 10290, 643, 10291, 1032, 10292, 10293)
spells("Retribution Aura", 7294, 10298, 10299, 10300, 10301)
spells("Concentration Aura", 19746)
spells("Fire Resistance Aura", 19891, 19899, 19900)
spells("Frost Resistance Aura", 19888, 19897, 19898)
spells("Shadow Resistance Aura", 19876, 19895, 19896)
spells("Aspect of the Wild", 20043, 20190)
spells("Hearthstone", 8690)
spells("Basic Campfire", 818, 1307227, 1229737)
spells("Journeyman Campfire", 1307252, 1283400)
spells("Expert Campfire", 1307237, 1291341)
spells("Camp Chair", 1307229, 1229517)
spells("Camp Tent", 1307230, 1229432)
spells("Create Campsite", 465447)
spells("Camp Benefits", 1229741)
spells("Welcoming Campfire", 1289723)
spells("Campfire Nearby", 1283391)
spells("Boosted Rest", 1229451)
spells("Resurrection", 2006, 2010, 10880, 10881, 20770)
spells("Redemption", 7328, 10322, 10324, 20772, 20773)
spells("Ancestral Spirit", 2008, 20609, 20610, 20776, 20777)
spells("Rebirth", 20484, 20739, 20742, 20747, 20748)
spells("Fishing", 7620, 7731, 7732, 18248)
spells("Alchemy", 2259, 3101, 3464, 11611)
spells("Blacksmithing", 2018, 3100, 3538, 9785)
spells("Enchanting", 7411, 7412, 7413, 13920)
spells("Engineering", 4036, 4037, 4038, 12656)
spells("Herb Gathering", 2366, 2368, 3570, 11993)
spells("Leatherworking", 2108, 3104, 3811, 10662)
spells("Mining", 2575, 2576, 3564, 10248)
spells("Smelting", 2656)
spells("Skinning", 8613, 8617, 8618, 10768)
spells("Tailoring", 3908, 3909, 3910, 12180)
spells("First Aid", 3273, 3274, 7924, 10846)
spells("Cooking", 2550, 3102, 3413, 18260)
spells("Linen Bandage", 3275)
spells("Heavy Runecloth Bandage", 18630)
spells("Herb Baked Egg", 8604)
spells("Charred Wolf Meat", 2538)
spells("Roasted Boar Meat", 2540)
spells("Light Armor Kit", 2152)
spells("Embossed Leather Vest", 2160)
spells("Embossed Leather Gloves", 3756)
spells("Rough Sharpening Stone", 2660)
spells("Smelt Copper", 2657)
spells("Smelt Tin", 3304)
spells("Smelt Thorium", 16153)
spells("Brown Linen Pants", 3914)
spells("Linen Cloak", 2387)
spells("Minor Healing Potion", 2330)
spells("Minor Mana Potion", 2331)
spells("Enchant Bracer - Minor Health", 7418)
spells("Lesser Magic Wand", 14293)
spells("Transmute: Arcanite", 17187)
spells("Transmute: Legionite", 1317279)
spells("Transmute: Iron to Gold", 11479)
spells("Transmute: Mithril to Truesilver", 11480)
spells("Transmute: Elemental Fire", 25146)
spells("Transmute: Earth to Water", 17561)
spells("Transmute: Fire to Earth", 17560)
spells("Transmute: Water to Air", 17562)
spells("Transmute: Undeath to Water", 17563)
spells("Transmute: Water to Undeath", 17564)
spells("Transmute: Life to Earth", 17565)
spells("Transmute: Earth to Life", 17566)
spells("Transmute: Air to Fire", 17559)
spells("Refined Scale of Onyxia", 22430)
spells("Mooncloth", 18560)
spells("Salt Shaker", 19566)
spells("Study", 1302508)
spells("Heroic Strike", 78)
spells("Battle Stance", 2457)
spells("Lesser Heal", 2050)
spells("Fireball", 133)
spells("Polymorph", 118)
spells("Frost Armor", 168)
spells("Inner Fire", 588)
spells("Healing Potion", 17534, 2370)
spells("Restore Mana", 17531, 437)
spells("Flask of the Titans", 17626)
spells("Supreme Power", 17628)
spells("Sharpen Weapon - Critical", 16138)
spells("Brilliant Mana Oil", 25123)
spells("Well Fed", 25661, 18234, 8212)
spells("First Aid", 18610, 746)
spells("Food", 433)
spells("Rumsey Rum Black Label", 25804)
spells("Snowball", 21343)
spells("Sharpen Blade", 2828)
spells("Find Herbs", 2383)
spells("Find Minerals", 2580)

--- Spell record, synthesising names for plausible IDs (the client knows every spell).
function MOCK.SpellRecord(id)
    local s = MOCK.spells[id]
    if s then return s end
    if R.type(id) ~= "number" or id <= 0 or id > 1400000 or id ~= R.floor(id) then return nil end
    s = { name = "Spell " .. id, icon = 136000 + id % 3000, generic = true }
    MOCK.spells[id] = s
    return s
end

-------------------------------------------------------------------------------
-- Atlases (C_Texture.GetAtlasInfo)
-------------------------------------------------------------------------------
MOCK.atlases = {}
for _, c in R.ipairs({ "warrior", "paladin", "hunter", "rogue", "priest", "shaman", "mage", "warlock", "druid" }) do
    MOCK.atlases["classicon-" .. c] = { width = 64, height = 64, file = 4720454, filename = "Interface/Glues/CharacterCreate/ClassIcons", leftTexCoord = 0, rightTexCoord = 1, topTexCoord = 0, bottomTexCoord = 1, tilesHorizontally = false, tilesVertically = false }
end
for _, a in R.ipairs({ "UI-HUD-ActionBar-IconFrame", "common-search-magnifyingglass", "Waypoint-MapPin-ChatIcon",
    "groupfinder-icon-role-large-tank", "groupfinder-icon-role-large-heal", "groupfinder-icon-role-large-dps",
    "UI-LFG-RoleIcon-Tank", "UI-LFG-RoleIcon-Healer", "UI-LFG-RoleIcon-DPS", "communities-icon-chat",
    "Professions-Icon-Quality-Tier1", "loottoast-arrow-green", "ui-hud-minimap-tracking-mouseover" }) do
    MOCK.atlases[a] = { width = 32, height = 32, file = 4000000, filename = "Interface/Atlas/" .. a, leftTexCoord = 0, rightTexCoord = 1, topTexCoord = 0, bottomTexCoord = 1, tilesHorizontally = false, tilesVertically = false }
end
