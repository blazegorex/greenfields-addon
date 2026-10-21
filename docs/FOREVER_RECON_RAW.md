
FOREVER CLIENT (1.60.1, Interface 16001, WOW_PROJECT_CAMELOT): HOW TO READ PROFESSIONS AND KNOWN RECIPES
Root path: C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns\ (all paths below are relative to it). Nothing in that folder was modified.

Summary: read skill levels with GetProfessions/GetProfessionInfo. Check known recipes with IsPlayerSpell(recipeSpellID) against a recipe-ID list you ship yourself; this works with the window shut. Read C_TradeSkillUI only while the profession window is open. No addon here uses the Craft API, GetAllRecipeIDs, a recipe-cooldown API or |Htrade: links.

== 0. CLIENT SHAPE ==
- The client uses the retail-style Professions UI. Its window is ProfessionsFrame, with side tabs ProfessionsOverviewTab and Professions1Tab..Professions7Tab. CONFIRMED.
  - ItemTree_Professions/UI/Queue.lua:5693-5697 cites Blizzard_Professions/Camelot/Blizzard_ProfessionsFrame.xml.
  - Queue.lua:330-332.
  - ItemTree_Professions/Core/Craft.lua:10-14 cites the forever branch: CraftRecipe in Blizzard_ProfessionsTransaction.lua, OpenTradeSkill in ProfessionsUtil.lua.
  - Craft.lua:582: `Craft.WINDOWS = { "ProfessionsFrame", "TradeSkillFrame" }`.
- Auctionator on 16001 loads Source_Mainline, not Source_Classic. LIKELY.
  - Auctionator.toc:42 `Source_Mainline\Manifest.xml [AllowLoadGameType mainline]`; :43 `Source_Classic [AllowLoadGameType classic]`; :51 `Source_Forever [AllowLoadGameType camelot][ExcludeLoadGameType classic, standard]`. The exclusion suggests camelot is not "classic".
  - Code inside Source_Mainline checks for Forever: Source_Mainline/CraftingInfo/Professions.lua:12 `if not Auctionator.Constants.IsForever`.
  - Source/Constants/Main.lua:56-57: `IsRetail = ...MAINLINE or WOW_PROJECT_ID == WOW_PROJECT_CAMELOT`, `IsForever = build >= 16000 and build < 20000`.
- Secret values: in combat, the client hands addon code "secret" values that raise an error on compare. ItemTree/Core/Util.lua:158-176 (1.60.1.70205) uses canaccessvalue / issecretvalue. Shadowflare/Core.lua:1608 returns "secret". The CHAT_MSG_SKILL payload is not marked NeverSecret (ItemTree_Professions/UI/Queue.lua:4051-4058). CONFIRMED. Scan out of combat.

== 1. SKILL LEVELS ==
GetProfessions() + GetProfessionInfo(index): CONFIRMED. This is the path to use.
- RareScanner/Core/Data/RSProfessionDB.lua:23 calls `local p1,p2,p3,p4,p5,_ = GetProfessions()` with no guard (Forever-only addon). Line 15: `local _,_,_,_,_,_, skillLine,_,_,_ = GetProfessionInfo(index)`.
- Return order, ItemTree/Core/DisenchantValue.lua:300-305, read from the forever branch at 1.60.1.70205 (Blizzard_ProfessionsBook/Camelot/Blizzard_ProfessionsBook.lua):
  - GetProfessions() â†’ prof1, prof2, firstAid, fishing, cooking. Any slot can be nil.
  - GetProfessionInfo(i) â†’ name, texture, rank, maxRank, numSpells, spellOffset, skillLine, ...
  - The skill-line ID is the 7th return, so no name lookup is needed. Enchanting = 333.
- ItemTree reads every return it gets (Core/Keep.lua:9813-9838, DisenchantValue.lua:315-327) rather than assuming 5. RareScanner only reads 5. Read all of them.
- ItemTree/UI/PlayerSkills.lua:244-271 does the same read under pcall. Line 248: "The Forever client answers here while its skill sheet reads empty."
- ItemTree/UI/Frame.lua:4788-4793 order: gatherProfessions first, the skill sheet only if that found nothing, then C_TradeSkillUI.

Other skill APIs:
- GetNumSkillLines / GetSkillLineInfo (global): reads empty on Forever per PlayerSkills.lua:248; only a fallback (PlayerSkills.lua:203-242). Do not use.
- C_SpellBook.GetNumSkillLines / GetSkillLineInfo: UNKNOWN. Only a rawget-guarded alternative (PlayerSkills.lua:208-215).
- C_SkillInfo.GetNumSkillLines / GetSkillLineInfo: LIKELY.
  - RXPGuides/RXPGuides.lua:402-403 uses them if present; its fallback `_G.SkillLineInfo` is a typo, so it reads nothing otherwise.
  - Lines 427-434 handle a table return: `if type(skillName)=="table" then name=t.name rank=t.rank maxRank=t.maxRank`.
  - DisenchantValue.lua:306 mentions a probe printing "what C_SkillInfo answers".
- C_TradeSkillUI.GetAllProfessionTradeSkillLines() â†’ array of skill-line IDs, then C_TradeSkillUI.GetTradeSkillLineInfoByID(line) â†’ table with .skillLevel or .rank and .maxSkillLevel or .maxRank: LIKELY (guarded, PlayerSkills.lua:276-304).
- C_TradeSkillUI.GetBaseProfessionInfo() / GetChildProfessionInfo() â†’ table {professionID, parentProfessionID, skillLevel}: CONFIRMED.
  - RXPGuides/Guides/Forever/RestedXP-Skyborne.lua:1809 calls `t.GetBaseProfessionInfo().professionID~=185` unguarded, after `t.IsTradeSkillReady()`.
  - ItemTree_Professions/Core/Craft.lua:874-891 and 950-959.
  - It only describes the line currently loaded. Craft.lua:864-866: it "names the line whose data the client holds, which outlives the window". It is not a list of professions.
- C_TradeSkillUI.GetProfessionInfoBySkillLineID: no call sites. UNKNOWN.

Child skill lines exist: ItemTree_Data/Data/generated/Skills.lua:13 lists 2937-2948 (each with p=parent, for example 2940 Enchanting p=333) and 2988 Poisons p=40. The professionID you get back may be a child ID, so match on professionID OR parentProfessionID (Craft.lua:837-842).

Refresh events:
- SKILL_LINES_CHANGED, LEARNED_SPELL_IN_TAB, PLAYER_ENTERING_WORLD (ItemTree/UI/Frame.lua:450).
- Plus CHAT_MSG_SKILL (ItemTree_Professions/Core/Professions.lua:1086, UI/Pane.lua:267).
- Don't cache an empty answer; at login the client can answer before its data is ready (Frame.lua:4794-4799).

Specializations: IsSpellKnown / IsPlayerSpell on the spec spell IDs: 9788 / 9787 / 17039-17041 (Blacksmithing), 10656 / 10658 / 10660 (Leatherworking), 20219 / 20222 (Engineering). ItemTree/Core/Skills.lua:26-46, PlayerSkills.lua:156-167.

== 2. RECIPE LISTS ==
Modern C_TradeSkillUI (recipeID = recipe spell ID):
- C_TradeSkillUI.OpenTradeSkill(skillLineID): CONFIRMED. Skyborne.lua:1808 `t.OpenTradeSkill(129)`, :1809 OpenTradeSkill(185); Craft.lua:1284-1290.
- C_TradeSkillUI.IsTradeSkillReady() â†’ bool: CONFIRMED (Skyborne.lua:1809).
- C_TradeSkillUI.GetCraftableCount(recipeID) â†’ number: CONFIRMED (Skyborne.lua:1809).
- C_TradeSkillUI.CraftRecipe(recipeID, count): CONFIRMED (Skyborne.lua:1378, 1808; Craft.lua:1039-1043).
  - Recipe IDs are spell IDs: 8604 Herb Baked Egg, 3275 Linen Bandage, 2538 Charred Wolf Meat.
  - Proven in game: it starts nothing with the window shut, and chaining it from an event is ADDON_ACTION_BLOCKED (Craft.lua:50-52).
- C_TradeSkillUI.GetRecipeInfo(recipeID) â†’ TradeSkillRecipeInfo: the function exists (CONFIRMED by an observed Forever bug); the flag is only reliable with the window open on that line.
  - Fields read: .learned, .relativeDifficulty (0 Optimal, 1 Medium, 2 Easy, 3 Trivial; Craft.lua:239-241), .numSkillUps (Queue.lua:1226-1241), .name, .recipeID (Auctionator ObjectiveTracker.lua:37).
  - Observed on Forever (Craft.lua:16-24): .learned keeps answering after the window closes, or before the line loads, and can be stale. Believe a false only with the window open on that line.
- C_TradeSkillUI.GetRecipeRequirements(recipeID) â†’ { {name, met, type} }, type 0 SpellFocus / 1 Totem / 2 Area: LIKELY. Craft.lua:1163-1170 cites the forever-branch docs; read at 1240-1262. Craft.lua:1226-1227: a Cooking Fire is only known while the Cooking window is the open one.
- C_TradeSkillUI.GetRecipeSchematic(recipeID, isRecraft[, recipeLevel]) â†’ .reagentSlotSchematics[i] {reagentType, reagents[1].itemID, quantityRequired, dataSlotIndex}, .quantityMin: LIKELY (Camelot branch). Auctionator Source_Mainline/CraftingInfo/Professions.lua:24, 60-70; Source/Tooltips/Hooks.lua:77-97.
- C_TradeSkillUI.GetRecipeOutputItemData(recipeID, reagentsTbl, allocGUID, qualityID) â†’ {hyperlink}: LIKELY. Professions.lua:35 and Hooks.lua:93. For enchants hyperlink is nil; Auctionator uses its own table instead (Professions.lua:41-50).
- C_TradeSkillUI.GetRecipesTracked(bool): LIKELY (ObjectiveTracker.lua:65, 70).
- C_TradeSkillUI.GetRemainingRecasts() and the undocumented StopRecipeRepeat(): LIKELY. Craft.lua:1061-1083 cites the 1.60.1.70009 binary strings; StopTradeSkillRepeat is not in the binary.
- C_TradeSkillUI.GetAllRecipeIDs / GetFilteredRecipeIDs / GetCategories / GetProfessionInfoBySkillLineID: zero call sites in any installed addon. UNKNOWN.

Events:
- Registered under pcall (Craft.lua:567-578, Queue.lua:4206-4217): TRADE_SKILL_SHOW, TRADE_SKILL_CLOSE, TRADE_SKILL_DATA_SOURCE_CHANGED, TRADE_SKILL_LIST_UPDATE, TRADE_SKILL_ITEM_CRAFTED_RESULT, TRADE_SKILL_CRAFT_BEGIN, UPDATE_TRADESKILL_CAST_STOPPED, NEW_RECIPE_LEARNED. LIKELY.
- Craft.lua:56-57 cites forever-branch docs for CRAFT_BEGIN, ITEM_CRAFTED_RESULT and CAST_STOPPED.
- TRADE_SKILL_SHOW is also used by Auctionator Source_Mainline/Initialize/Main.lua:4, 32-33. LIKELY.

Legacy TradeSkill API: not the Forever path. LIKELY absent or unused; UNKNOWN if present.
- ItemTree reaches GetNumTradeSkills, GetTradeSkillRecipeLink (parsed with "enchant:(%d+)"), GetTradeSkillLine and DoTradeSkill only through rawget-guarded "classic" fallbacks (Craft.lua:703-724, 893-897, 1045-1054). These only run when C_TradeSkillUI is missing.
- GetTradeSkillInfo and GetTradeSkillItemLink appear only in Auctionator Source_Classic (not loaded on 16001) and in Hooks.lua:111-122, guarded by GameTooltip.SetTradeSkillItem ("-- Classic").
- BagBrother uses them only behind TradeSkillFrame.

Craft API (GetNumCrafts, GetCraftInfo, GetCraftItemLink, GetCraftDisplaySkillLine, CRAFT_SHOW / CRAFT_UPDATE): no Forever evidence. UNKNOWN; don't use.
- It appears only in Auctionator Source_Vanilla/EnchantInfo/Main.lua:19 (TOC `[AllowLoadGameType vanilla, tbc, wrath]`) and Hooks.lua:125-136, guarded by SetCraftItem ("TBC classic and earlier").
- Enchanting is an ordinary tradeskill line 333 in the Professions UI. LIKELY:
  - ItemTree has a 333 track crafted through CraftRecipe (ItemTree_Professions/Data/generated/ProfessionTracks.lua:2452).
  - Child line 2940 exists.
  - RXP's Forever guide has `/cast Enchanting\n/run C_TradeSkillUI.CraftRecipe(7421,1)`, but that step is commented out (Skyborne.lua:1103).

What each addon does on 16001:
- ItemTree / ItemTree_Professions never list the client's recipes. They ship their own recipe database:
  - ItemTree_Data/Data/generated/Recipes_<skillLine>.lua: n, sl, r, tl, th, re, out, cd, ccd, toolItems, by.
  - RecipeIndex.lua: spell â†’ skill line.
  - ItemTree_Professions/Data/generated/ProfessionTracks.lua (build 1.60.1.70425).
  - For each candidate spell they ask Craft.KnowsRecipe (Craft.lua:777-814), first definite answer wins:
    1. IsPlayerSpell(spell)
    2. C_SpellBook.IsSpellKnown(spell)
    3. C_TradeSkillUI.GetRecipeInfo(spell).learned (a false only counts with the window open)
    4. "not learnt" answers remembered this session
    5. IsSpellKnown, true only
    6. nil
- RareScanner (RSProfessionDB.lua): GetProfessions / GetProfessionInfo only. No recipes.
- Auctionator (Source_Mainline): hooks ProfessionsFrame.CraftingPage.SchematicForm after TRADE_SKILL_SHOW, then uses GetRecipeSchematic and GetRecipeOutputItemData for the selected recipe. No scanning.

== 3. WITHOUT OPENING THE WINDOW; COOLDOWNS ==
- IsPlayerSpell(recipeSpellID) â†’ bool, with every profession window shut: CONFIRMED. The call is pcall-guarded, but ItemTree tested it in game. Craft.lua:765-768: "Proven in game (Forever 1.60.1.70124, 2026-10-02, every profession window shut): IsPlayerSpell answers a recipe's learnt status at any time (2152 and 2160 true, 3756 false), and C_SpellBook.IsSpellKnown the same."
- So known recipes can be read with no window, but only by checking a recipe-spell-ID list you ship yourself. Enumerating everything without the window: UNKNOWN (no GetAllRecipeIDs evidence).
- With the window open: GetBaseProfessionInfo / GetChildProfessionInfo plus GetRecipeInfo(id). Treat GetAllRecipeIDs as guarded and UNKNOWN. Re-read on TRADE_SKILL_LIST_UPDATE / TRADE_SKILL_DATA_SOURCE_CHANGED. CraftRecipe needs the window open, and opening it shows UI.
- Recipe cooldowns:
  - GetTradeSkillCooldown and C_TradeSkillUI.GetRecipeCooldown have zero call sites. UNKNOWN.
  - C_Spell.GetSpellCooldown(spellID) â†’ {startTime, duration, isEnabled, modRate/isActive}: LIKELY. Used by Forever-only Shadowflare/Core.lua:1603-1611 (pcall; its result can be secret) and by the RXPGuides.lua:52-66 shim (prefers _G.GetSpellCooldown).
  - Whether it reports tradeskill category cooldowns such as transmutes: UNKNOWN.
- Cooldown data, ms, from ItemTree_Data generated build 1.60.1.70425 (data only, not an API):

| Recipe | Spell | Cooldown (ms) | Note |
|---|---|---|---|
| Transmute: Arcanite | 17187 | ccd 169200000 | |
| Transmute: Legionite | 1317279 | ccd 169200000 | new |
| Elemental transmutes | 17559-17566 | ccd 82800000 | |
| Transmute: Elemental Fire | 25146 | ccd 600000 | |
| Transmute: Iron to Gold | 11479 | cd 3600000 | |
| Transmute: Mithril to Truesilver | 11480 | cd 3600000 | |
| Refined Scale of Onyxia | 22430 | ccd 7200000 | |
| Mooncloth | 18560 | cd 342000000 | Recipes_197 |
| Study | 1302508 | cd 3600000 | Recipes_3012 |

== 4. PROFESSION NAMES; CAMPING ==
Skill lines (ItemTree_Data/Data/generated/Skills.lua:13; track lines at ProfessionTracks.lua:15-2754):
- Primary (category 11): 164 Blacksmithing, 165 Leatherworking, 171 Alchemy, 182 Herbalism, 186 Mining, 197 Tailoring, 202 Engineering, 333 Enchanting, 393 Skinning.
- Secondary (category 9): 129 First Aid, 185 Cooking, 356 Fishing, 40 Poisons, 142 Survival, 633 Lockpicking.
- New: 3012 "Comprehension" (category 9). It is a Mage class skill ("Class: Mage (Comprehension 1)", ItemTree/Core/Keep.lua:8099), not a profession. Its one recipe is 1302508 "Study": 17056 Light Feather â†’ 277651 Bundle of Scrolls.
- There is no Jewelcrafting or Inscription line. RXPGuides/DB/forever/db.lua:235-252 lists them, but that table is copied from other versions. It does add `poisons = {2842}` (line 251).

Gathering professions now have crafts (Recipes_*.lua counts): Skinning 3 (Camp Chair, Trapper's Workbench, Field Guide), Herbalism 3 (Incense Candle, Greenhouse, Seed Hybridizer), Fishing 3 (Fish Bowl, Fishing Rack, Fishing Hut), Mining 18. Include these lines in the scan.

Camping: there is no "Camping" skill line and no camp or campfire API in any addon. It is a family of items spread across professions:

| Recipe | Spell | Profession | Requirement | Reagents | Makes |
|---|---|---|---|---|---|
| Basic Campfire | 1229737 | Cooking (185) | r=1, tl=1, th=5, tool 4471 Flint and Tinder | 4470 Simple Wood x1 | 279981 Basic Campfire Kit |
| Basic Campfire (classic) | 818 | Cooking | still present, ccd 300000 | | |
| Journeyman Campfire | 1283400 | Cooking | r=90, taught by 273087 Blueprint | 11291 | 279961 |
| Expert Campfire | 1291341 | Cooking | r=200, taught by 273101 Blueprint | 272941 | 279974 |
| Camp Tent | 1229432 | Leatherworking | | 2318 x5 | 279978 |
| Camp Chair | 1229517 | Skinning | | 2318 x3, 4470 x2 | 279979 |

- Sources: Recipes_185/165/393.lua; ProfessionTracks.lua:1570 and :3689 (`[-1229737] = "Basic Campfire"`).
- Item-use spells (SpellNames.lua): 1307227 Basic Campfire, 1307252 Journeyman, 1307237 Expert, 1307229 Camp Chair, 1307230 Camp Tent; also 465447 "Create Campsite".
- Item cooldowns (Items_0.lua): 300000 ms for the campfire kits, 3600000 ms for Tent and Chair. ItemTree/Core/Consumables.lua:676-679 describes them as "Forever's camping family ... a buff at a campfire, the shared camping cooldown, a profession requirement" (CAMP_KIND = 62).
- "Camp Benefits" buff: /sit at a campfire for one minute (RXPGuides/Guides/Forever/Horde-01-12_Durotar.lua:1610, Horde-1-12_Mulgore.lua:497, Horde-01-14_Undead.lua:778). Quest 96101 "Gain the Boosted Rest buff" (Skyborne.lua:1794, 1807).
- "Camping 101: <Profession>" quests (Skyborne.lua:1838-1952): 97970 Mining, 97971 Skinning, 96646 Cooking, 97968 Herbalism, 97965 First Aid, 97967 Fishing, 97963 Alchemy, 97964 Blacksmithing, 97973 Tailoring, 98286 Enchanting, 97969 Leatherworking.
- 1229741: no match in any file. UNKNOWN.

== 5. TRADESKILL LINKS ==
- Zero matches across all addons for "|Htrade", "trade:", GetTradeSkillListLink, C_TradeSkillUI.GetTradeSkillListLink, IsTradeSkillLinked, or IsTradeSkillGuild. UNKNOWN.
- ChatForever has no hyperlink handling.
- Don't rely on linking a whole profession. Sync recipe IDs through addon messages instead.

== WHAT TO BUILD ON ==
- Ranks: GetProfessions(), reading every return with select('#'), then GetProfessionInfo(i), with returns 3 = rank, 4 = max, 7 = skillLine. Refresh on SKILL_LINES_CHANGED, LEARNED_SPELL_IN_TAB, CHAT_MSG_SKILL and PLAYER_ENTERING_WORLD, out of combat.
- Recipes: a shipped list of recipe spell IDs per skill line (including children 2937-2948 mapped to parents, and the gathering lines), each checked with IsPlayerSpell(id), with C_SpellBook.IsSpellKnown as backup. No window needed.
- Optional: with the window open (TRADE_SKILL_SHOW / LIST_UPDATE), read C_TradeSkillUI.GetBaseProfessionInfo / GetChildProfessionInfo and GetRecipeInfo(id) under pcall to catch recipes your list doesn't have. Treat GetAllRecipeIDs as UNKNOWN and guard it.
- Cooldowns: pcall(C_Spell.GetSpellCooldown, spellID) and check for secret values (LIKELY).
- Wrap every C_* call in pcall and type-check its arguments, since C APIs throw on nil or wrong types.



FOREVER (Interface 16001 / WOW_PROJECT_CAMELOT): API capability report, based on the installed addons
Root: C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns\ (written as AO\ below). Read-only; no files were changed.
Tags: CONFIRMED = called unguarded on a Forever or Camelot path, or a Forever addon documents it from in-game testing. LIKELY = guarded fallback chain, option-gated, or cited from Blizzard API docs. UNKNOWN = no evidence.

== 0. Main finding: Forever has Midnight's "secret value" and addon-restriction system ==
- CONFIRMED: issecretvalue, canaccessvalue and scrubsecretvalues exist.
  - AO\Leatrix_Plus\Leatrix_Plus.lua:7812,7826 (canaccessvalue, unguarded)
  - AO\RareScanner\Core\Service\RSEventHandler.lua:43,780,935 (issecretvalue and scrubsecretvalues, unguarded)
  - AO\Shadowflare\Core.lua:290-303
  - AO\ItemTree\Core\Util.lua:158-173: "The Forever client (1.60.1.70205) hands addon code 'secret' values in combat."
- CONFIRMED: C_Secrets.ShouldAurasBeSecret() and C_Secrets.CanCompareUnitTokens() exist. Leatrix_Plus.lua:7807,7839,14253,10362 and Plater_Auras.lua:1977,2017, all unguarded.
- CONFIRMED: there is an addon-restriction framework with these CVars: addonMapRestrictionsForced, addonChatRestrictionsForced, addonCombatRestrictionsForced, addonPvPMatchRestrictionsForced, addonEncounterRestrictionsForced, addonChallengeModeRestrictionsForced (Leatrix_Plus.lua:14476-14483).
  - C_RestrictedActions.IsAddOnRestrictionActive(Enum.AddOnRestrictionType.Chat) is called unguarded (AO\Leatrix_Plus\Bindings.xml:20).
  - Leatrix warns that some settings "do not apply during instanced combat encounters" (Leatrix_Plus.lua:9734-9738). It also notes that UnitName(target) "can be secret" (Leatrix_Plus.lua:10359).
- CONFIRMED: Plater treats Forever as Midnight. AO\Plater\libs\DF\fw.lua:260-267 has `IsAddonApocalypseWow() = buildInfo>=120000 or IsForeverWow()`, with IsForeverWow being 16001 â‰¤ toc < 20000. This flag drives every IS_WOW_PROJECT_MIDNIGHT branch in Plater on Forever.
- LIKELY: Blizzard's built-in damage meter is present. SavedVariables WTF\Account\...\SavedVariables\Blizzard_DamageMeter.lua exists for several characters. No addon calls a C_DamageMeter API (UNKNOWN).

== 1. Combat log ==
- CONFIRMED: addons cannot use COMBAT_LOG_EVENT_UNFILTERED or CombatLogGetCurrentEventInfo on Forever.
  - AO\ItemTree\UI\CollectorHooks.lua:3388-3396 (citing the Forever-branch Blizzard API documentation):
    - CLEU is "marked HasRestrictions".
    - GetCurrentEventInfo lives in C_CombatLogSecure (SecureOnly) and C_CombatLogInternal.
    - Deprecated_CombatLog.lua points CombatLogGetCurrentEventInfo at C_CombatLog.GetCurrentEventInfo, which the public documentation does not carry.
    - Blizzard_CombatLog now listens for COMBAT_LOG_MESSAGE instead.
    - "Registering a restricted event from an addon is exactly what the taint rule forbids."
  - Detection gate, CollectorHooks.lua:3417-3426: return nil if C_CombatLogSecure or C_CombatLogInternal exists. Line 3441: "the Forever client (the one with secret values) has [them]".
  - AO\Plater\Plater.lua:11104-11107: `--no longer in midnight... good bye...` followed by `if not IS_WOW_PROJECT_MIDNIGHT then RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")`. Not registered on Forever.
  - AO\Plater\Plater_AnimationEditor.lua:111: `if IS_WOW_PROJECT_MIDNIGHT then return end` before registering CLEU.
  - Leatrix_Plus.lua:13088 only filters the name out of a RegisterAllEvents debug trace. Shadowflare does not use CLEU at all.
- Subevents named in code (all dead on Forever):
  - Plater.lua:10885-11087: SPELL_DAMAGE, SPELL_SUMMON, SPELL_INTERRUPT, SPELL_CAST_SUCCESS, SPELL_CAST_START, SPELL_AURA_APPLIED, UNIT_DIED, and SPELL_AURA_REMOVED (non-mainline).
  - Plater_AnimationEditor.lua:67: SPELL_DAMAGE and SPELL_PERIODIC_DAMAGE.
  - CollectorHooks.lua:3412,3442: PARTY_KILL.
  - ENVIRONMENTAL_DAMAGE: no use anywhere.
- spellId 0 in the CLEU payload: moot, since CLEU is unreadable.
  - The only workarounds are Classic-Era code: LibClassicCasterino.lua:187-190 (`if spellID == 0 then spellNameToID[spellName]`) and Plater.lua:11059,11080 (`select(7, GetSpellInfo(spellName))`). Neither runs on Forever: LCC is disabled at AO\Plater\libs\DF\externals.lua:97 (`... and false`), and the Plater handlers belong to the unregistered CLEU parser.
- What replaces it:
  - CONFIRMED: there is a standalone PARTY_KILL event. RareScanner registers it unguarded (RSEventHandler.lua:975). The handler at 199-201 is OnPartyKill(attackerGUID, targetGUID); targetGUID can be secret and is checked with issecretvalue. It then calls C_CreatureInfo.GetCreatureID(guid), also CONFIRMED.
  - CONFIRMED: UNIT_SPELLCAST_SUCCEEDED (unit, castGUID, spellID). spellID can be secret: RSEventHandler.lua:607-608, Shadowflare\Core.lua:1382,1395-1397.
  - UNIT_DIED, ENVIRONMENTAL_DAMAGE and boss-death detection outside the encounter events: UNKNOWN.

== 2. Auras ==
- CONFIRMED (unguarded):
  - C_UnitAuras.GetBuffDataByIndex and GetDebuffDataByIndex: Leatrix_Plus.lua:7809,7841,14255.
  - C_UnitAuras.GetPlayerAuraBySpellID: AO\RareScanner\Core\Service\POI\RSNpcPOI.lua:107.
  - Camelot (Midnight) branch of Plater: C_UnitAuras.GetAuraDataByAuraInstanceID (Plater_Auras.lua:681), GetAuraDataBySlot (686), IsAuraFilteredOutByInstanceID (2665-2666, 2711-2712), GetUnitAuras with Enum.UnitAuraSortRule (2761, 2778, 2799), GetAuraDuration (4045), GetAuraDispelTypeColor (3928).
- LIKELY (guarded): C_UnitAuras.GetAuraDataByIndex (Shadowflare\Core.lua:441-442, AuraShow.lua:136; ItemTree\Core\Keep.lua:11241-11243). AuraUtil.UnpackAuraData (RXPGuides\functions.lua:48-80 polyfill; Plater_Auras.lua:44).
- UNKNOWN: GetAuraDataBySpellName (only an existence probe, Shadowflare\Core.lua:1025). AuraUtil.ForEachAura (no use anywhere).
- Global UnitAura, UnitBuff, UnitDebuff: UNKNOWN, probably absent.
  - Every Forever addon prefers C_UnitAuras and keeps the global only as a fallback (Shadowflare\Core.lua:438-451; ItemTree\Core\Keep.lua:11251).
  - RXPGuides\functions.lua:48 polyfills them when missing.
- Fields:
  - spellId: CONFIRMED present (Leatrix_Plus.lua:7811 BuffData.spellId; Shadowflare\Core.lua:444 a.spellId/a.name/a.expirationTime/a.duration/a.auraInstanceID; AuraShow.lua:161-162 also a.applications).
  - CONFIRMED that aura data and UNIT_AURA payloads are secret in combat:
    - AuraShow.lua:3: "In combat Forever hides the player's buffs from addons", checked in game 16 Oct 2026.
    - Core.lua:398: "readable out of combat only on Forever".
    - Core.lua:1444-1452: updateInfo.isFullUpdate can be secret.
    - RSEventHandler.lua:772,935: addedAuras secret, scrubsecretvalues(updateInfo).
    - Leatrix gates every read on `not C_Secrets.ShouldAurasBeSecret()`.
  - sourceUnit: UNKNOWN whether it can be read. On Camelot, Plater deliberately does not read it (Plater_Auras.lua:668-672 hard-codes sourceIsSelf=false on IS_WOW_PROJECT_MIDNIGHT), so treat it as unusable.
- UNIT_AURA with RegisterUnitEvent "player": LIKELY (Shadowflare\Core.lua:1379, under pcall).

== 3. Spells ==
- CONFIRMED (unguarded): C_Spell.GetSpellName (RareScanner\Core\Libs\RSTooltipScanners.lua:322) and IsPlayerSpell (Leatrix_Plus.lua:6969).
- CONFIRMED from in-game testing: AO\ItemTree_Professions\Core\Craft.lua:765-770 says "Proven in game (Forever 1.60.1.70124 ...): IsPlayerSpell answers ... and C_SpellBook.IsSpellKnown the same".
- LIKELY:
  - C_Spell.GetSpellInfo, returning a table (.name, .castTime, .iconID, ...): RXPGuides\RXPGuides.lua:37-47,331-336; Shadowflare\Core.lua:379-381; RSTooltipScanners.lua:324.
  - C_Spell.GetSpellTexture: Shadowflare\Core.lua:337.
  - C_Spell.GetSpellCooldown, IsSpellUsable, GetSpellPowerCost: Shadowflare\Core.lua:1590-1605,621.
- Global GetSpellInfo: UNKNOWN. Every user guards it (Plater.lua:56 `GetSpellInfo or <C_Spell wrapper>`; Shadowflare\Core.lua:331,373-377; ItemTree\UI\Client.lua:226). Use C_Spell.
- Global IsSpellKnown: LIKELY. RXPGuides.lua:73,316 calls `IsSpellKnown(id,true)` unguarded after `C_Spell.IsSpellKnown or _G.IsSpellKnown`. Craft.lua:810 has it as a last fallback.

== 4. Encounters, group, loot, rolls ==
- ENCOUNTER_START and ENCOUNTER_END: CONFIRMED.
  - Registered unguarded on every flavor (Plater.lua:4989-4990; DF\loadconditions.lua:148).
  - Handler payload: (encounterID, encounterName, difficultyID) at Plater.lua:2513-2516.
  - Whether the payload is secret during encounters: UNKNOWN.
- BOSS_KILL: LIKELY. BossBanner frame exists; Leatrix_Plus.lua:2842-2845 unregisters BOSS_KILL and ENCOUNTER_LOOT_RECEIVED from it when its option is on.
- GetInstanceInfo: CONFIRMED. ForeverDungeonJournal\Systems\ScarletWing.lua:76,248 (8th return = instanceID); Core\Journal.lua:857.
- IsInRaid and IsInGroup: CONFIRMED. OpenMap\Map\Pins.lua:174-175 and Nav.lua:408-410 (Forever-only); Leatrix_Plus.lua:13989, 14235-14239 (with LE_PARTY_CATEGORY_INSTANCE and LE_PARTY_CATEGORY_HOME).
- GetNumGroupMembers and GetRaidRosterInfo: CONFIRMED (Leatrix_Plus.lua:13990-13993,14009-14012, a slash path); RXPGuides\Communications.lua:29,219. Whether roster names are secret during encounters: UNKNOWN, but the restriction system makes it possible.
- UnitInRaid: CONFIRMED (Leatrix_Plus.lua:139; Plater_Comms.lua:438; RXPGuides.lua:1979).
- UnitIsGroupLeader and UnitIsGroupAssistant: CONFIRMED (Leatrix_Plus.lua:1184, 14006; Plater_Comms.lua:414). GetNumSubgroupMembers: CONFIRMED (Leatrix_Plus.lua:12794).
- C_PartyInfo.InviteUnit and UninviteUnit: CONFIRMED (Leatrix_Plus.lua:1199,13995).
- IsEveryoneAssistant: UNKNOWN (no use).
- Master loot: UNKNOWN. No addon references GetLootMethod, C_PartyInfo.GetLootMethod, GetMasterLootCandidate, GiveMasterLoot, or PARTY_LOOT_METHOD_CHANGED.
  - Possibly relevant: Forever uses the Mainline LootFrame and GroupLootFrame (ItemTree\UI\Keybind.lua:239-245,256-262), and the Mainline UI has no master-looter frame.
- Loot window: CONFIRMED.
  - RareScanner calls GetNumLootItems, LootSlotHasItem, GetLootSourceInfo and GetLootSlotLink unguarded on LOOT_OPENED (RSEventHandler.lua:266,281,288,289,952).
  - LOOT_READY plus LootSlot: Leatrix_Plus.lua:2781-2791; RXPGuides\InventoryManager.lua:104.
  - GetLootSlotInfo returns name 2nd, quantity 3rd, isCoin 10th "on the forever branch": ItemTree\Core\Ledger.lua:1140-1142,1189-1205. The fallback is GetLootSlotType against Enum.LootSlotType.Money (2).
  - LOOT_OPENED args are (autoLoot, isFromItem): Ledger.lua:1189.
  - GetLootSourceInfo returns (guid, qty) pairs that may be secret (Ledger.lua:1100-1113; CollectorHooks.lua:1344).
- Group loot rolls: LIKELY.
  - START_LOOT_ROLL and GetLootRollItemLink: ForeverDungeonJournal\Systems\ItemIdLearner.lua:277-279,308-309, under pcall.
  - GetLootRollItemInfo: Auctionator\Source\Tooltips\Hooks.lua:153-156 (tooltip SetLootRollItem).
  - CONFIRM_LOOT_ROLL, CONFIRM_DISENCHANT_ROLL, ConfirmLootRoll and LOOT_BIND_CONFIRM: Leatrix_Plus.lua:1467-1499, option-gated.
- CHAT_MSG_LOOT: CONFIRMED registered (DF\loadconditions.lua:152; ItemTree\UI\CollectorHooks.lua:3673). Its text can be secret: CollectorHooks.lua:3703 notes "no NeverSecret mark (ChatInfoDocumentation.lua:1820)" and checks canRead first. The LOOT_ITEM_SELF* globals are used as prefixes (CollectorHooks.lua:209-216).
- CHAT_MSG_SYSTEM: LIKELY. RXPGuides\functions.lua:147 registers it; Leatrix uses ChatFrameUtil.AddMessageEventFilter("CHAT_MSG_SYSTEM") at Leatrix_Plus.lua:8146.
  - Chat payloads can be secret: Leatrix_Plus.lua:1183 checks canaccessvalue on whisper arguments, and Leatrix_Plus.lua:11837-11839 locks "Filter chat messages" on Forever because of a game bug.
- RANDOM_ROLL_RESULT roll parsing: UNKNOWN (no addon parses rolls). Check canaccessvalue on the message before matching it.

== 5. Talents ==
- LIKELY: Forever's talents use the trait system.
  - ItemTree\Core\Gear.lua:2846-2857, reading the Forever-branch UI source: Blizzard_PlayerSpells loads Camelot/ClassTalents/Blizzard_ClassTalentsFrame.lua for the camelot game type.
  - That frame uses C_SpecializationInfo.GetCombatConfigIDForSpecGroup, C_SpecializationInfo.GetActiveSpecGroup and C_Traits.
  - The API docs list C_ClassTalents.GetActiveConfigID, C_Traits.GetConfigInfo (treeIDs), GetTreeNodes, GetNodeInfo (entryIDs, ranksPurchased, activeRank), GetEntryInfo (definitionID), GetDefinitionInfo (spellID), and C_SpecializationInfo.GetTalentInfo({specializationIndex, talentIndex}) returning spellID and rank.
  - Read order with pcall: Gear.lua:2919-3085. Read out of combat only, because the values can be secret.
- Events: PLAYER_TALENT_UPDATE, TRAIT_CONFIG_UPDATED, ACTIVE_TALENT_GROUP_CHANGED and CHARACTER_POINTS_CHANGED (Gear.lua:2868-2872). Shadowflare registers CHARACTER_POINTS_CHANGED and PLAYER_TALENT_UPDATE under pcall (Core.lua:1367-1377,1520).
- LIKELY (developer slash command): Leatrix_Plus.lua:14360-14400 uses PlayerSpellsFrame.TalentsFrame, C_ClassTalents.GetConfigIDsBySpecID, ImportLoadout and DeleteConfig, and C_SpecializationInfo.GetSpecialization and GetSpecializationInfo.
- Talent tree shape: per-spec rows with Forever spell IDs.
  - Shadowflare\Core.lua:96 ("Missile Barrage is a row 1 talent in Forever"), 119 ("Frost row 5"), 188 ("Assassination row 1"), 204 ("Marksmanship row 3, talent 415405").
  - Talent checks go through IsPlayerSpell or IsSpellKnown on spell IDs (Core.lua:386-394).
- Classic GetTalentInfo(tab, i), GetNumTalentTabs and GetTalentTabInfo: UNKNOWN. RXPGuides switches its talent features off on Forever:
  - RXPGuides\Guides\Talents\classic-druid.lua:2 returns unless the game is "CLASSIC" (Forever is "FOREVER", RXPGuides.lua:201-203).
  - RXPGuides\ItemUpgrades.lua:6 returns as well.
  - Plater registers no talent events for Camelot (Plater.lua:4981-4987).

== Practical guidance for the addon ==
- Do not register CLEU. For kills use the PARTY_KILL event; for bosses use ENCOUNTER_START, ENCOUNTER_END and BOSS_KILL; for casts use UNIT_SPELLCAST_SUCCEEDED; for loot use LOOT_OPENED and CHAT_MSG_LOOT.
- Check every value from these events and calls with canaccessvalue or issecretvalue before comparing or indexing: GUIDs, names, chat text, aura fields, roster data.
- Read auras, talents and roster details out of combat or outside encounters, and re-read on PLAYER_REGEN_ENABLED or ENCOUNTER_END.
- C_EventUtils.IsEventValid(name) can check whether an event exists at runtime (LIKELY: RXPGuides\functions.lua:210-215; Plater\libs\LibRangeCheck-3.0\LibRangeCheck-3.0.lua:4622).
- Wrap master-loot and roll-parsing code in existence checks and pcall, since none of it is confirmed.



ROOT = C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns (read only; nothing was modified). Every path below is relative to ROOT.
Status labels: C = CONFIRMED (called unguarded on a Forever-only addon or on a Camelot load path), L = LIKELY (only reached through a guard or fallback chain), U = UNKNOWN (no evidence in the folder).

=== 0. CLIENT FACTS THAT AFFECT EVERYTHING ===
- WOW_PROJECT_CAMELOT == 18. Evidence: BagBrother/core/core.lua:11 `IsForever = WOW_PROJECT_ID == 18`.
- The TOC load-type tag is "camelot", and it pulls the Mainline code paths:
  - RXPGuides.toc:24 loads `libs\embeds_Mainline.xml [AllowLoadGameType standard,camelot]`. That file includes AceComm, ChatThrottleLib (CTL) v32, AceSerializer and LibDeflate (embeds_Mainline.xml:12,13,23).
  - Auctionator.toc loads `Source_Forever\Constants.lua [AllowLoadGameType camelot]`.
  - Auctionator's "mainline" files also load on Forever: Source_Mainline/CraftingInfo/Professions.lua:12 branches on IsForever.
  - Auctionator/Source/Constants/Main.lua:56: `IsRetail = MAINLINE or CAMELOT`.
- The API surface is Midnight (12.x) era, including the 12.x addon restrictions. Plater/libs/DF/fw.lua:260 IsAddonApocalypseWow, :264 IsForeverWow and :269 IsMidnightWowAPI all return true for build 16001.
- Secret values exist. C, by unguarded use: canaccessvalue (Leatrix_Plus.lua:137, 1183, 10068), C_Secrets.ShouldAurasBeSecret (Leatrix:7807), C_Secrets.CanCompareUnitTokens (Leatrix:10362). Supporting notes:
  - OpenMap/Core.lua:32-40: "clients with secret values, e.g. WoW Forever".
  - ItemTree/Core/Util.lua:158-163: secret values raise on compare, join, length, match, or use as a table key.
  - ForeverBotTelemetry/Telemetry.lua:5-8: secrets pass silently through format and concatenation and only error at C boundaries such as table.concat.
  - Received chat lines and links can be secret inside instances: ItemTree/UI/Keybind.lua:404 and ItemTree/UI/Tooltip.lua:81 ("SecretInChatMessagingLockdown").
- C APIs throw on nil or wrongly typed arguments: Aureus/Core/Compat.lua:2-3.
- Registering an unknown event raises an error, so Aureus wraps each RegisterEvent in pcall: Aureus/Core/Namespace.lua:152-157. FDJ does the same (ForeverDungeonJournal/Systems/VersionCheck.lua:165-167).
- Names (high risk for a guild addon): the second return of UnitName/UnitFullName is a surname, not a realm.
  - C: Leatrix_Plus.lua:10210 says "realm returns surname".
  - BagBrother/core/api/owners.lua:51-58 puts every character in a 'forever' realm bucket and keys it as name .. " " .. that second return.
  - L: Plater/libs/AceDB-3.0/AceDB-3.0.lua:263-277. When RegionalUniqueNamesEnabled() is true, the realm key becomes the ruleset and the character key becomes "Name Surname" (from UnitNameUnmodified).
  - RXPGuides/libs/AceDB-3.0/AceDB-3.0.lua:264-276: on version > 16000 the realm key is the ruleset, taken from C_GameRules.
  - Auctionator/Source_ModernAH/Variables/Main.lua:1-16 also keys by ruleset when RegionalUniqueNamesEnabled is true.
  - Aureus/Core/Compat.lua:243-245: realm strings change between sessions for the same realm.
  - Leatrix_Plus.lua:5463 falls back to GetNormalizedRealmName when the second return of UnitFullName is nil.
  - U: the exact string format of guild roster names and of CHAT_MSG_ADDON senders on Forever.
- SavedVariables may not be restored on the beta client: Aureus/Core/DB.lua:6-9.
- Strongest single source: Leatrix_Plus is a Forever-only build, 1.60.20, dated 15 Oct 2026. It refuses to run below TOC 16000 (Leatrix_Plus.lua:2, 34-45).

=== 1. GUILD ROSTER ===
- IsInGuild: C. Unguarded at OpenMap/Map/Pins.lua:177, RXPGuides/Communications.lua:35, BagBrother/libs/StaleCheck-1.0/StaleCheck-1.0.lua:140 and Plater/Plater_Comms.lua:900. Guarded at FDJ VersionCheck.lua:84.
- GetGuildInfo(unit): C. Returns guildName, rankName, rankIndex, guildRealm.
  - Leatrix_Plus.lua:10249-10251. Leatrix passes guildRealm through canaccessvalue, so it can be secret.
  - BagBrother/core/api/owners.lua:70; Plater/Plater.lua:1402 and 4143 (Plater_Camelot.toc).
- UnitIsInMyGuild: C. Leatrix_Plus.lua:10254.
- GetNumGuildMembers / GetGuildRosterInfo(i): C. Leatrix_Plus.lua:531-533 (Forever-only; the calls are unguarded, behind a user option).
  - Fields Leatrix actually uses: 1 = name (it strips anything after "-"), 9 = isOnline, 14 = isMobile, 17 = guid.
  - That matches the retail 17-return order, so the remaining positions are L: 2 rankName, 3 rankIndex, 4 level, 5 class display name, 6 zone, 7 public note, 8 officer note, 10 status, 11 class file, 12 achievement points, 13 achievement rank, 15 canSoR, 16 reputation standing.
  - Leatrix_Plus.lua:529: "new members may need to press J to refresh roster". So Leatrix never requests a roster refresh, and J opens a retail-style Guild/Communities window.
- GUILD_ROSTER_UPDATE: C. Registered without a guard on code that loads on 16001 with no flavor branch: StaleCheck-1.0.lua:25, BagBrother/core/features/caching.lua:34, owners.lua:65. Since unknown events raise on this client, the registration succeeding is evidence the event exists.
- C_GuildInfo.GuildRoster versus global GuildRoster(): U. No addon calls either one. Plater/Plater.lua:13023-13025 lists C_GuildInfo.RemoveFromGuild only in a sandbox blocklist, which proves nothing.
- C_Club.GetSubscribedClubs, Enum.ClubType.Character, CommunitiesUtil.GetMemberIdsSortedByName and CommunitiesUtil.GetMemberInfo: C. Leatrix_Plus.lua:546-549. The retail Communities stack is present. C_Club.GetGuildClubId: U.
- CHAT_MSG_GUILD / CHAT_MSG_OFFICER events: L. Registered under pcall at FDJ/Systems/ItemIdLearner.lua:258-260; mapped at ChatForever/Model.lua:209.
- U (zero references anywhere in the folder): CanEditOfficerNote, C_GuildInfo.CanEditOfficerNote, CanViewOfficerNote, C_GuildInfo.IsGuildOfficer, GuildRosterSetPublicNote, GuildRosterSetOfficerNote, GetGuildRosterLastOnline, GetGuildRosterMOTD, the GUILD_MOTD event, GetGuildRosterShowOffline, SetGuildRosterShowOffline.
- Guild bank APIs: only used behind a GuildBankFrame_LoadUI check (BagBrother/core/api/frames.lua:11). Whether Forever has guild banks is U.

=== 2. ADDON COMMS ===
- C_ChatInfo.RegisterAddonMessagePrefix: C.
  - Unguarded: TomTom/TomTom.lua:178, Auctionator/Source/Initialize/Main.lua:13, StaleCheck-1.0.lua:29, RXPGuides/libs/AceComm-3.0/AceComm-3.0.lua:65.
  - Forever-only addons call it under pcall: FDJ VersionCheck.lua:176-177 (at PLAYER_LOGIN), OpenMap/Map/Pins.lua:683.
  - Prefix limit 16 characters (AceComm-3.0.lua:61).
  - Global RegisterAddonMessagePrefix: U (fallback only).
- C_ChatInfo.IsAddonMessagePrefixRegistered: U. Only iMorphNet uses it, and iMorphNet.toc has no 16001 entry.
- C_ChatInfo.SendAddonMessage: C.
  - Unguarded: TomTom.lua:763; StaleCheck-1.0.lua:164 (GUILD, PARTY, RAID, INSTANCE_CHAT).
  - ChatThrottleLib.lua:245 (RXPGuides copy) hooks it with hooksecurefunc and no guard; that would error if the function were missing.
  - Under pcall: FDJ VersionCheck.lua:76-80; OpenMap Pins.lua:161.
  - Global SendAddonMessage: U (FDJ fallback only, VersionCheck.lua:78).
- Return value: U on Forever, and no addon reads it directly.
  - CTL v32 accepts either an enum or a boolean: ChatThrottleLib.lua:349-378. Its fallback table is Success=0, AddonMessageThrottle=3, NotInGroup=5, ChannelThrottle=8, GeneralError=9, used when Enum.SendAddonMessageResult is missing.
  - An enum is L, given the Midnight-era API.
  - On a throttle result CTL moves the queue to a blocked list and retries it every 0.35 s: ChatThrottleLib.lua:396-406, 462-469.
- C_ChatInfo.SendAddonMessageLogged: C. Hooked without a guard at ChatThrottleLib.lua:253 (the v26 hook; Camelot embeds).
- CHAT_MSG_ADDON arguments: (prefix, text, channel, sender, ...): C. TomTom.lua:766, StaleCheck-1.0.lua:122, OpenMap Pins.lua:283, AceComm-3.0.lua:242.
  - Normalise the sender with Ambiguate(sender, "none") before comparing to UnitName("player"): AceComm-3.0.lua:244, OpenMap Pins.lua:286-287.
  - Your own GUILD and group messages echo back to you (Pins.lua:287).
  - text and sender can be secret: OpenMap checks both at Pins.lua:285, and CTL's hooks skip secret arguments at ChatThrottleLib.lua:282 and 292.
- Channels with evidence: GUILD, PARTY, RAID, INSTANCE_CHAT and WHISPER: C (FDJ VersionCheck.lua:84-98; OpenMap Pins.lua:172-183, where WHISPER targets GetUnitName("target", true); StaleCheck-1.0.lua:148-151).
  - INSTANCE_CHAT is chosen when IsInGroup(LE_PARTY_CATEGORY_INSTANCE) is true. LE_PARTY_CATEGORY_* is C (Leatrix_Plus.lua:13989).
  - OFFICER as an addon channel: U.
- Throttling:
  - CTL v32 settings: MAX_CPS 800, MSG_OVERHEAD 40, BURST 4000, MIN_FPS 20 (ChatThrottleLib.lua:60-65). It throttles hard for 5 s after login or zoning (:321-324, 436-442).
  - The RXPGuides and Plater copies of CTL and of AceComm-3.0 (v14, revision 1333) are byte-identical. Neither contains a Forever-specific throttle change.
  - Version notes: v26 added the SendAddonMessageLogged hook (:250); v29 added the BNSendGameData hook (:258).
  - Forever-only addons pace themselves: OpenMap sends one message per 0.3 s, "the game holds back a burst" (Pins.lua:26, 155-162). FDJ sends at most once per 10 s per channel and delays replies by a random 1-5 s (VersionCheck.lua:15, 72-74, 111).
- Maximum message length: 255 bytes. ChatThrottleLib.lua:636-637; AceComm-3.0.lua:95 says bytes past 255 are silently truncated. AceComm marks multipart messages with control bytes \001-\004 (:41-44). OpenMap trims a note to 255 bytes without splitting a UTF-8 character (Pins.lua:146, 167).
- AceComm runs on the Forever path:
  - RXPGuides sets addon.game = "FOREVER" (RXPGuides.lua:202-203). It calls comms:Setup unconditionally (:1567), which registers the prefix (Communications.lua:58), and it sends on PARTY (:342).
  - Plater (Camelot TOC) sends on RAID and PARTY (Plater_Comms.lua:106-111).
- C_ChatInfo.InChatMessagingLockdown: C (Leatrix_Plus.lua:13718). There are periods when the client blocks chat sending; whether addon messages are blocked too is U.
- Unverified conflicting claim: ItemTree/Core/Share.lua:2 says the hidden channel "does not carry addon messages on the beta". FDJ and OpenMap both rely on addon messages. Whether messages are actually delivered is U until tested in-game.

=== 3. CHAT ===
- C_ChatInfo.SendChatMessage: C.
  - Leatrix_Plus.lua:13764 sends on CHANNEL; :14243-14247 send on PARTY or INSTANCE_CHAT. Both run from slash commands.
  - RareScanner/Core/Libs/RSHyperlinks.lua:169 sends on CHANNEL from a link click.
  - Global SendChatMessage: U. It appears only as a fallback (RXPGuides/Communications.lua:11; ChatThrottleLib.lua:235-243, 558).
- Restrictions:
  - SAY, YELL and CHANNEL outside a hardware event: U. No Forever addon sends these without a user action.
  - GUILD, PARTY and EMOTE without a hardware event: L. RXPGuides sends them from its PLAYER_LEVEL_UP handler on the FOREVER path (Communications.lua:26-36, 147-149).
  - Leatrix checks InChatMessagingLockdown before sending and prints "Chat messages are restricted right now." (Leatrix_Plus.lua:13718-13721).
- Raid warning:
  - Sending the RAID_WARNING chat type: U.
  - Showing one locally: C. RaidNotice_AddMessage(RaidWarningFrame, msg, ChatTypeInfo["RAID_WARNING"], seconds) at RareScanner/RareScanner.lua:515.
  - CHAT_MSG_RAID_WARNING event: L (ChatForever/Model.lua:212).
- Chat filters:
  - ChatFrameUtil.AddMessageEventFilter and RemoveMessageEventFilter: C (Leatrix_Plus.lua:8125-8148). Filter signature is fn(self, event, msg, sender, ...); return true to hide the line (:8087).
  - Global ChatFrame_AddMessageEventFilter: U (fallback only, ChatForever/Native.lua:403).
  - ChatForever/Native.lua:5-7 says it was checked against Forever build 70245 (ChatFrameBase, ChatFrameFilters, ChatFrameUtil). Blizzard's own filters call canaccessvalue (ItemTree/Core/Util.lua:161-163).
  - Filters should check every argument for secrecy first (ChatForever/Native.lua:375-385).
- Other chat API:
  - C: ChatFrameUtil.ChooseBoxForSend and ChatFrameUtil.ActivateChat (Leatrix_Plus.lua:215-216).
  - L: ChatFrameUtil.InsertLink (Auctionator/Source/Shopping/Hooks.lua:51-52).
  - L: C_ChatInfo.IsChatLineCensored (ChatForever/Native.lua:319-320).
  - CHAT_FRAMES holds the whisper windows created at runtime (ChatForever/Native.lua:425-426).

=== 4. ENCODING / SERIALIZATION ===
- C_EncodingUtil CompressString, DecompressString, EncodeBase64, DecodeBase64 with Enum.CompressionMethod.Deflate: L. All uses are guarded.
  - Aureus/Core/Compat.lua:163-180 round-trip tests the codec once and falls back to plain text. The result on this client is not visible in the folder.
  - ItemTree/Core/Share.lua:907-931 and 1591-1606 do a pcall round trip.
  - Plater/Plater_Comms.lua:181-193 (Camelot TOC, only checks that C_EncodingUtil exists) calls CompressString(s, Enum.CompressionMethod.Deflate, Enum.CompressionLevel.OptimizeForSize), then EncodeBase64. :73 calls DecompressString with no method argument.
- SerializeCBOR / DeserializeCBOR: L. Auctionator/Source/Variables/Main.lua:113-118, 135-136, 154-155, 190-191; Plater_Comms.lua:182.
- SerializeJSON / DeserializeJSON: U (no references).
- Libraries present:
  - LibDeflate 1.0.2-release: RXPGuides/libs/LibDeflate/LibDeflate.lua:95 (Camelot embeds) and Plater/libs/LibDeflate/LibDeflate.lua:92.
  - Plater uses LibDeflate:EncodeForWoWAddonChannel for comms (Plater_Comms.lua:192).
  - AceSerializer-3.0 is in RXPGuides and Plater. Plater's LibCompress wraps C_EncodingUtil (LibCompress.lua:1145-1180). RXPGuides ships libs/plc/base64.lua.

=== 5. TIMERS AND MISC ===
- Timers:
  - C_Timer.After: C (Leatrix_Plus.lua:38, at file load).
  - C_Timer.NewTicker: C (PortraitDock/PortraitDock.lua:880 at file scope; Shadowflare/Core.lua:1253; Leatrix:6693 passes an iteration count).
  - C_Timer.NewTimer: C (OpenMap/Map/Nav.lua:299; Leatrix:10875).
  - Unverified claim of about 500 timers per addon: Aureus/Core/Scheduler.lua:5.
- Clocks:
  - GetServerTime: C (Aureus/Core/Util.lua:21; Leatrix:5466).
  - GetTime: C (Aureus/Core/Util.lua:22; OpenMap Pins.lua:296).
  - time(): C (RareScanner/Core/Service/RSEntityStateHandler.lua:54, 58).
  - date(), including date("*t"): C (Aureus/UI/Chart.lua:102-105, 121).
  - C_DateAndTime: C. GetSecondsUntilWeeklyReset (RSEntityStateHandler.lua:58), GetCurrentCalendarTime (RareScanner/Core/Plugins/TelemetryPlugin/RSTelemetryEngine.lua:17), GetServerTimeLocal (RareScanner/Core/SpecialEvents/MidnightPrePatch.lua:46).
  - GetQuestResetTime: C (RSEntityStateHandler.lua:54).
- Names and realms:
  - Ambiguate: C (OpenMap Pins.lua:286; AceComm-3.0.lua:244).
  - UnitFullName: C (Leatrix:5462, 5493; BagBrother owners.lua:52). Second return is the surname (see section 0) and can be nil.
  - UnitNameUnmodified: L (Plater AceDB-3.0.lua:273).
  - GetNormalizedRealmName: C (Leatrix:8070; Auctionator ModernAH Variables/Main.lua:23). Value is unstable (Aureus Compat.lua:243-245).
  - GetRealmName: C (Leatrix:13708; Plater_Comms.lua:60).
  - GetRealmID: L (Aureus Compat.lua:247; ItemTree/Core/Collector.lua:4454-4461).
  - GetAutoCompleteRealms: C (BagBrother owners.lua:55); C_AutoComplete.GetAutoCompleteRealms: C (Leatrix:13615).
  - RegionalUniqueNamesEnabled: L (guarded at Plater AceDB-3.0.lua:263 and Auctionator ModernAH Variables/Main.lua:14).
  - C_GameRules.IsGameRuleActive with Enum.GameRule.PvPRuleset, RPRuleset and HardcoreRuleset: C (RXPGuides AceDB-3.0.lua:266-272 on the 16001 branch).
- GUIDs:
  - UnitGUID: C (ForeverBotTelemetry/Telemetry.lua:106; Plater_Comms.lua:60). Non-player GUIDs can be secret (Aureus/Core/DB.lua:486-488; Leatrix:2702). Player GUIDs match "^Player%-%d+%-%x+$" (ChatForever/Native.lua:283).
  - GetPlayerInfoByGUID: L; second return is the class file (ChatForever/Native.lua:289-290, type check plus pcall).
- Class colors and icons:
  - RAID_CLASS_COLORS: C (Leatrix_Plus.lua:59, 4108).
  - C_ClassColor.GetClassColor: L (OpenMap/Map/Nav.lua:391; ChatForever/Native.lua:270-271).
  - Global GetClassColor: U.
  - CLASS_ICON_TCOORDS: L (FDJ/Core/Journal.lua:3372; FDJ/Systems/LootFilter.lua:533).
  - LOCALIZED_CLASS_NAMES_MALE: L (Shadowflare/Options.lua:108).
  - The class token from UnitClass can be secret (OpenMap Nav.lua:388; Leatrix:10199).
- Money:
  - GetMoney: C (Auctionator/Source_ModernAH/Tabs/Buying/Commodity/Mixins/Main.lua:209, on the Camelot load path).
  - PLAYER_MONEY event: C (BagBrother/core/features/caching.lua:30).
  - GetMoneyString: C (Auctionator/Source_ModernAH/Selling/ComposeAuctionPostedMessage.lua:12).
  - C_CurrencyInfo.GetCoinTextureString: C (Leatrix:7968). C_CurrencyInfo.GetCoinText: C (Leatrix:3727).
  - Global GetCoinTextureString: present, but ItemTree/UI/InfoPanel.lua:146-150 says it "answered nothing on the beta". Prefer the C_CurrencyInfo version or your own formatter.
  - C_CurrencyInfo.GetCurrencyInfo: L (ItemTree/Core/Sources.lua:1296-1307).
- Honor and PvP: GetPVPLifetimeStats, UnitHonor, GetHonor*, GetPVPRankInfo and UnitPVPRank are all U (zero references). C_PvP.GetZonePVPInfo is L (Plater.lua:2546, inside a fallback chain); COMBAT_HONOR_GAIN appears only in a ChatTypeInfo lookup list (ChatForever/Native.lua:19).
- UnitIsAFK, UnitIsDND, PLAYER_FLAGS_CHANGED: U (zero references).
- Death:
  - PLAYER_DEAD: C (Leatrix_Plus.lua:4383, registered without a guard).
  - UnitIsDeadOrGhost: C (Leatrix:10194).
  - C_DeathInfo.GetSelfResurrectOptions: C (Leatrix:8511).
- hooksecurefunc: C (Leatrix_Plus.lua:829, 854; ChatThrottleLib.lua:245).
- C_AddOns.GetAddOnMetadata: C (StaleCheck-1.0.lua:96).
- UI gotcha: calling FontString:SetText before a font is set raises "Font not set" (ItemTree/UI/Badges.lua:48).

=== IMPLICATIONS FOR THE GUILD ADDON ===
1. Call every API through a check that it exists plus pcall, and register every event inside pcall.
2. Key guild members by GUID (roster field 17), not "Name-Realm". Store the raw roster name, normalise it with Ambiguate(x, "none"), and check for secret values before comparing or using as a table key.
3. Request roster refreshes with (C_GuildInfo.GuildRoster or GuildRoster), guarded, and rate-limit the requests.
4. Comms: AceComm with CTL v32 already runs on Forever. Keep each message at or under 255 bytes and the prefix at or under 16 characters. Check InChatMessagingLockdown before sending, and handle both enum and boolean send results. Keep a fallback that does not depend on addon messages until delivery is confirmed in-game.
5. Chat: use C_ChatInfo.SendChatMessage. Send automatically only on GUILD, PARTY, RAID or WHISPER; send SAY, YELL and CHANNEL only from user actions.
6. Encoding: use C_EncodingUtil only after a round-trip self-test, with an embedded LibDeflate as the fallback.
7. Officer-note, MOTD, last-online, show-offline and PvP/AFK APIs have no evidence in the folder. Check each one in-game with /dump before building on it.



Base path: `C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns\`. All cites below are relative to it. Nothing in that folder was changed; the only file I wrote was a TGA header-reader script in my scratchpad.

Context found along the way:
- `_classic_beta_\.flavor.info` reads `wow_classic_beta`. A separate `_forever_` install (flavor `wowf`) also exists, and its only addon is Aureus.
- Several Forever addons check their Blizzard-code claims against the `forever` branch of github.com/Gethe/wow-ui-source. Sound.lua:7-9 describes that client as "retail shaped Mainline files with a thin Camelot layer over them" (ItemTree/UI/Sound.lua:7-9, Options.lua:1927-1930). Use that branch as the reference for Blizzard UI code.
- Leatrix plans for a 1.60.2 patch: it sets a NewPatch flag when the TOC version is â‰¥16002 (Leatrix_Plus.lua:34-45).

## 1. Frames and templates

**BackdropTemplate** â€” CONFIRMED required.
- Frames have no SetBackdrop until you inherit "BackdropTemplate". ItemTree probes `type(frame.SetBackdrop)` before use (ItemTree/UI/Report.lua:114-118).
- Unguarded uses: ForeverDungeonJournal/Core/Journal.lua:2490 and :528-529 (SetBackdrop helper), Leatrix_Plus.lua:6315, FDJ Systems/Favourites.lua:529-537 (with SetBackdropColor and SetBackdropBorderColor).
- `BackdropTemplateMixin` exists as a global (Shadowflare/Display.lua:4, Options.lua:11).
- Mixin onto an existing frame â€” LIKELY. Plater_Auras.lua:527-528 calls `Mixin(f, BackdropTemplateMixin)` and then `SetScript("OnSizeChanged", f.OnSizeChanged)`; that file is in Plater_Camelot.toc:53.

**Templates:**

| Template | Status | Evidence |
|---|---|---|
| UIPanelButtonTemplate | CONFIRMED | FDJ Journal.lua:2949, OpenMap Init.lua:75, Shadowflare Options.lua:82 |
| UICheckButtonTemplate | CONFIRMED | PortraitDock Settings.lua:111,136,175; FDJ LootFilter.lua:507 |
| InputBoxTemplate | CONFIRMED | OpenMap News.lua:277, Pins.lua:414; Shadowflare Profiles.lua:245 |
| SearchBoxTemplate | CONFIRMED | OpenMap Nav.lua:360 |
| UIPanelScrollFrameTemplate | CONFIRMED | FDJ Journal.lua:7816-7821; ChatForever UI.lua:205; PortraitDock Settings.lua:60 |
| ScrollFrameTemplate + scrollBarTemplate=MinimalScrollBar | CONFIRMED | Leatrix_Plus.xml:2-7 |
| UIPanelCloseButton | CONFIRMED | OpenMap Core.lua:276, Dungeons.lua:328 |

Notes on these:
- No Forever addon reads the label field of UICheckButtonTemplate; all of them create their own label. Whether `.Text` exists is UNKNOWN.
- The scroll-bar field name on UIPanelScrollFrameTemplate may differ, so FDJ hedges with `scroll.ScrollBar or scroll.scrollBar` (Favourites.lua:631-633).
- UIPanelCloseButton has a combat quirk; see section 6.

**ScrollBox family** â€” CONFIRMED.
- RareScanner (Forever-only TOC) uses, unguarded: `<Frame inherits="WowScrollBoxList">` and `<EventFrame inherits="MinimalScrollBar">` (Core/Plugins/ExplorerPlugin/RSExplorerListTemplate.xml:16,22).
- Same addon, Lua: CreateScrollBoxListLinearView, ScrollUtil.InitScrollBoxListWithScrollBar, ScrollUtil.AddSelectionBehavior and CreateDataProvider (RSExplorerMixin.lua:654-661). These files are loaded via Core/Plugins.xml.
- Leatrix calls ScrollUtil.AddAcquiredFrameCallback (Leatrix_Plus.lua:1943).
- ItemTree (pcall'd) uses "BackdropTemplate" as the ScrollBox row template so it can ship no XML (UI/Sidebar.lua:94-96, :850-900).

**New-style dropdowns and menus** â€” CONFIRMED.
- Unguarded `CreateFrame("DropdownButton", nil, p, "WowStyle1DropdownTemplate")` plus `MenuUtil.CreateRadioMenu` and `DropdownButtonMixin.Event.OnMenuClose` (Leatrix_Plus.lua:12553-12575).
- `MenuUtil.CreateRadio` and `menu:EnumerateElementDescriptions` (Leatrix_Plus.lua:5609-5615).
- `dd:SetupMenu(function(_, root) ...)`: Shadowflare Options.lua:117-147 (pcall), RareScanner RSExplorerMixin.lua:560,567 (unguarded). RareScanner also uses `MenuResponse.Refresh` and a WowStyle1FilterDropdownTemplate in XML (RSExplorerTemplate.xml:401).

**MenuUtil.CreateContextMenu** â€” CONFIRMED on the Camelot path. The calls are unbranched in multi-flavor addons that list 16001: BagBrother core/classes/sortButton.lua:49 and offlineSelector.lua:64, TomTom.lua:791. Auctionator treats Camelot as retail (Source/Constants/Main.lua:56).

**Old UIDropDownMenu:**
- UIDropDownMenu_Initialize â€” UNKNOWN. No Forever-only addon calls it, and ItemTree bans it as "global, shared with the client's own menus and taints easily" (UI/Chain.lua:1988-1990, UI/Map.lua:2919).
- UIDropDownMenuTemplate â€” LIKELY exists. AceGUI's DropDown constructor creates it unguarded (OpenMap/Libs/AceGUI-3.0/widgets/AceGUIWidget-DropDown.lua:648), and OpenMap's options window uses select widgets (Map/Nav.lua:467).
- EasyMenu â€” UNKNOWN; only reached through a guarded fallback (RXPGuides.lua:2747-2760). On Camelot, RXPGuides loads its own LibUIDropDownMenu (RXPGuides.toc:24).
- FDJ replaced EasyMenu because Blizzard menus close on mouse-down before the callback fires (Systems/Favourites.lua:361-365). ItemTree confirms the forever branch's Blizzard_Menu uses OnMouseDown with no OnClick, so a custom menu must pick on press (UI/Map.lua:2920-2928).

**Frame templates:**
- PortraitFrameTemplate â€” LIKELY, observed in use. It is ItemTree's first choice (pcall, UI/Frame.lua:8769), and ItemTree describes its beta look: a "grey translucent wash" background (Frame.lua:4879-4881).
- ButtonFrameTemplate â€” LIKELY. Tried first under pcall (Shadowflare Notes.lua:199; FDJ Favourites.lua:524, chain ButtonFrame â†’ PortraitFrame â†’ BasicFrameTemplateWithInset). `ButtonFrameTemplate_HidePortrait` is used with a guard (Notes.lua:225).
- NineSliceUtil layout "ButtonFrameTemplateNoPortrait" on NineSlicePanelTemplate â€” LIKELY. Guarded in OpenMap Core.lua:247-251, whose comment says Forever draws it "in bronze" (:242-244).
- BasicFrameTemplateWithInset â€” LIKELY; fallback only.
- Tab template â€” LIKELY. On forever, PanelTopTabButtonTemplate carries PanelTopTabButtonMixin, flips its art to the bottom and offsets the text Y by -7 selected / -6 deselected (ItemTree Frame.lua:140-147, :165-172).

**Other frame APIs** â€” CONFIRMED unguarded:
- SetResizeBounds, StartSizing, SetToplevel, SetClampedToScreen (Aureus UI/Main.lua:600-607, 789)
- SetClipsChildren (Aureus UI/Chart.lua:233)
- SetObeyStepOnDrag (Aureus UI/Kit.lua:984)

GetMouseFoci â€” LIKELY (guarded, Aureus Core/Compat.lua:90-96). No Forever-only addon references GetMouseFocus.

## 2. Settings, addon compartment, minimap

**Settings** â€” CONFIRMED: Settings.RegisterCanvasLayoutCategory + Settings.RegisterAddOnCategory, unguarded in Leatrix_Plus.lua:11415-11416. Also used in OpenMap Init.lua:70-83, FDJ Systems/OptionsPanel.lua:177-181 and Shadowflare Options.lua:591-595.
- Use a canvas, not a vertical layout. ItemTree found that the game's settings search walks a vertical layout's initializers and carried its taint into Blizzard rows: "Execution tainted by ItemTree while reading field tooltipFunc" and a blocked IsUserOAuthed (UI/Options.lua:1890-1898, enforced at :4239-4243).
- Build canvas rows at PLAYER_LOGIN while the page is hidden, never in OnShow (Options.lua:4084-4090).
- The page is opened with `Settings.OpenToCategory(category:GetID())` (Options.lua:4278-4307). FDJ instead sets `category.ID = "DungeonJournal"` (OptionsPanel.lua:179).
- In combat the panel will not open, because ShowUIPanel is blocked; queue the call for PLAYER_REGEN_ENABLED (Options.lua:4292-4299).
- InterfaceOptions_AddCategory â€” UNKNOWN. It appears only as a fallback when Settings is missing, which never happens here (FDJ OptionsPanel.lua:185, Shadowflare Options.lua:598).

**Addon compartment** â€” CONFIRMED.
- `## AddonCompartmentFunc`, `FuncOnEnter` and `FuncOnLeave` are declared in Aureus.toc:8-10, ForeverDungeonJournal.toc:7-9, OpenMap.toc:6-8, RareScanner.toc:34-36, ItemTree.toc:9 and Leatrix_Plus.toc:11.
- Handlers are plain globals:
  - Click `(addonName, mouseButton)`: FDJ SettingsPanel.lua:468, OpenMap Map/Launcher.lua:42.
  - Enter `(addonName, ownerFrame)`, used as the tooltip owner: Aureus Core/Slash.lua:511-528, FDJ :476.
  - Leave hides GameTooltip.
  - The exact argument shape is LIKELY.
- `AddonCompartmentFrame` exists: unguarded HookScript and Hide (Leatrix_Plus.lua:5721-5722) and SetFrameLevel (:6309). It has `.registeredAddons`, `:RegisterAddon(data)` and `:UpdateDisplay()` (Leatrix_Plus_Library.lua:1028-1076).
- ItemTree defers the click to the next tick for gamepad taint (UI/Slash.lua:2329-2333).

**LibDBIcon** â€” CONFIRMED working.
- LibDBIcon-1.0 minor 56 is embedded in Leatrix (Leatrix_Plus_Library.lua:407-413). Leatrix calls `:Register` (Leatrix_Plus.lua:5670) and SetButtonRadius (:5638-5642).
- RareScanner ships LibDBIcon 56 with LibDataBroker 1.1 (ExternalLibs/LibDBIcon-1.0/LibDBIcon-1.0.lua:8-9; Core/Service/RSMinimap.lua:15,50).
- LibDBIcon's `AddButtonToCompartment` uses AddonCompartmentFrame (Leatrix_Plus_Library.lua:1030-1060).
- FDJ prefers a shared LibDBIcon and otherwise fakes a `LibDBIcon10_*` button (Core/Journal.lua:9105-9184).

**GetMinimapShape** â€” LIKELY not defined by the client.
- Square-minimap addons define it; Leatrix sets `_G.GetMinimapShape` to "SQUARE" or "ROUND" (Leatrix_Plus.lua:5631-5634).
- Always guard it with a type check and default to "ROUND" (ItemTree UI/Minimap.lua:597-608, shape table :112-130; Aureus UI/Minimap.lua:34-50).

**Minimap layout** â€” LIKELY.
- The Forever minimap is larger than Classic's 140px: read `Minimap:GetWidth()`, then radius = w/2 + 10 (ItemTree Minimap.lua:104-110; Aureus Minimap.lua:38).
- Tracking, mail and the compartment sit in a strip above the map; zoom buttons sit at about 310-320Â°; LibDBIcon's default is 225Â°; ItemTree defaults to 160Â° (Minimap.lua:66-74).

## 3. Textures and fonts

| API | Status | Evidence |
|---|---|---|
| WHITE8X8 (`Interface\\Buttons\\WHITE8X8`) | CONFIRMED | Aureus UI/Kit.lua:32; Leatrix_Plus_Minimap.lua:17; FDJ Journal.lua:2474 |
| SetColorTexture | CONFIRMED | OpenMap Core.lua:259,265; Shadowflare Display.lua:772; ~200 uses |
| SetGradient(orient, ColorMixin, ColorMixin) + CreateColor | CONFIRMED | Leatrix_Plus.lua:4996,5021,5025; Leatrix_Plus_Minimap.lua:499; Aureus Main.lua:583-584, Table.lua:394 |
| SetGradientAlpha | LIKELY absent | only a pcall'd fallback after SetGradient (FDJ Systems/HomeBottomBand.lua:11-15; ItemTree Overlay.lua:2933-2948) |
| CreateMaskTexture / AddMaskTexture | CONFIRMED | OpenMap Map/Stitch.lua:304-306 with "CLAMPTOBLACKADDITIVE" wrap; Leatrix_Plus.lua:8334-8337 |
| SetTextureSliceMargins (native nine-slice) | CONFIRMED by comment | Aureus Kit.lua:113-115 "it does on 1.60.1", used at :190-194 |
| CreateLine + SetStartPoint/SetThickness | CONFIRMED | Leatrix_Plus_Minimap.lua:377-380 |
| SetAtlas | CONFIRMED | unguarded "bags-glow-white" (Leatrix_Plus.lua:2192), "UI-HUD-UnitFrame-Target-PortraitOn-Type" (:4103), "Fyrakk_Flame_FX" (Leatrix_Plus_Minimap.lua:236) |
| SetHorizTile/SetVertTile | CONFIRMED | Aureus Main.lua:618-619 |

More texture notes:
- Mask files used: Shadowflare tries `Interface\Masks\CircleMaskScalable` first and falls back to `Interface\CharacterFrame\TempPortraitAlphaMask` (Display.lua:207-214). FDJ uses TempPortraitAlphaMask directly (LFGButton.lua:374).
- Retail atlases are present, but check C_Texture.GetAtlasInfo first for less common ones (OpenMap Core.lua:229-231 "common-dropdown-bg"; Shadowflare Display.lua:438-454 "UI-HUD-ActionBar-Proc-Loop-Flipbook").
- `TextureKitConstants.UseAtlasSize` exists (Leatrix_Plus.lua:8335).

**Texture filter quirk.** Shadowflare Display.lua:38-42 says asking for "TRILINEAR" filtering crashes the game at launch with fatal error `flags.m_filter <= GxTex_Linear`, and pcall can't catch it.
- This conflicts with OpenMap, which passes TRILINEAR at runtime on its own TGAs (Map/Dungeons.lua:229 with Data/DungeonDrawn.lua:9-14) and on file IDs or BLPs (Stitch.lua:350, 2297; WorldMap.lua:679-681).
- Recommendation: never pass a filter argument to SetTexture or SetAtlas.

**Fonts.** The client Fonts folder holds only 9 `.slug` files; TTFs are inside the game archives. Modern `SetFont` returns a boolean and code relies on it (Aureus Theme.lua:233-235; OpenMap News.lua:39-40, Core.lua:198).
- `Fonts\\FRIZQT__.TTF` â€” CONFIRMED (RareScanner RSWorldMap.lua:123 unguarded; ChatForever Theme.lua:34).
- `Fonts\\ARIALN.TTF` â€” LIKELY (Aureus Theme.lua:190-193; ItemTree Theme.lua:265-267).
- `Fonts\\MORPHEUS.TTF` â€” LIKELY (OpenMap News.lua:23).
- `SKURRI.TTF` â€” UNKNOWN; no Forever addon references it.
- Locale fallback: STANDARD_TEXT_FONT for koKR, zhCN and zhTW, and `Fonts\\FRIZQT___CYR.TTF` for ruRU (Aureus Theme.lua:198-205).
- Game fonts lack some glyphs such as "âš ", so Aureus swaps them for inline icons (Kit.lua:58-60).

**Custom TGAs.** Read from the first 18 header bytes (ImageType at byte 2, width/height at 12-15, bits per pixel at 16, descriptor at 17). Paths are referenced without the extension, e.g. `"Interface\\AddOns\\Aureus\\Media\\emblem"` (Aureus Theme.lua:255-275). Custom TGAs also work as `## IconTexture` (Aureus.toc:7, ItemTree.toc:8).

| Addon | Count | Format | Sizes |
|---|---|---|---|
| Shadowflare/Art | 7 | type 2 (raw truecolor), 32bpp, 8-bit alpha, bottom-left origin, power of two; size = 18 + wÂ·hÂ·4 + 26-byte TGA 2.0 footer | arc 128x256, edge 128x256, corner 64x64, glow 128x128, ring 128x128, sigil 256x256, top 256x128 |
| Aureus/Media | 49 | type 2, 32bpp, alpha 8, bottom origin, power of two, no footer | icons and shapes 32x32; emblem, glow, halo, plate, shadow 64x64; grad_v 8x64; line 16x8 |
| ItemTree/Art | 20 | type 2, 32bpp, power of two | badges 64x64; 32x32 marks; logo and empty-sources 512x256; keep-tags 512x512; equip-tags 1024x512; worthless-tag 256x128 |
| ForeverDungeonJournal/Media | 76 | 32bpp with alpha and 24bpp with no alpha; 8 are RLE (type 10, 24bpp) | e.g. HallOfThanesMap 1024x1024 RLE, referenced at Core/Journal.lua:175; MapPatches 512x256 RLE, referenced at :391 |
| OpenMap/Media/Textures | 711 TGA + 207 BLP | 45 RLE; mostly 256 and 128 square | 2 non-power-of-two 768x512 (MapGapMask/1414, 1415) loaded as masks via Stitch.lua:1326 and :304-306 |

- So RLE and non-power-of-two TGAs are referenced on Forever paths. That they render correctly is LIKELY, not verified.
- ItemTree's tooling still assumes "a texture has to be a power of two" (UI/Assets.lua:446-449). Stay with power-of-two, 32-bit uncompressed.

## 4. Animations, sound, tooltips

**Animations** â€” CONFIRMED unguarded.
- CreateAnimationGroup with these animation types: Alpha, Translation and Scale (Aureus UI/Toast.lua:241-269), Path with CreateControlPoint and SetCurveType (Leatrix_Plus_Minimap.lua:27-31), VertexColor with SetStartColor/SetEndColor(CreateColor) (:465-468), and Rotation.
- Group methods used: SetLooping "REPEAT" or "BOUNCE", SetOrder, SetStartDelay, SetSmoothing "IN_OUT" (Leatrix_Plus.lua:6020-6033), and OnFinished.
- FlipBook (SetFlipBookRows/Columns/Frames) â€” LIKELY; pcall'd in Shadowflare Display.lua:452-459.

**UIFrameFadeIn** â€” CONFIRMED. Bagnon calls it unbranched (Bagnon/src/searchBar.lua:34). UIFrameFadeOut and UIFrameFlash have no evidence.

**ShakeFrame** â€” UNKNOWN; no addon uses it. Use a Translation animation instead.

**PlaySound with SOUNDKIT names.** These have ids from SoundKitConstants on the forever branch, listed in ItemTree UI/Sound.lua:11-33,56-70: IG_MAINMENU_OPTION_CHECKBOX_ON 856, IG_MAINMENU_OPTION_CHECKBOX_OFF 857, IG_CHARACTER_INFO_TAB 841, IG_CHARACTER_INFO_OPEN 839, IG_CHARACTER_INFO_CLOSE 840.
- Unguarded uses: RareScanner RSRoute.lua:771 (UI_MAP_WAYPOINT_REMOVE) and RSWorldMapButtonMixin.lua:56; Bagnon searchBar.lua:33.
- Guarded uses: IG_MAINMENU_OPEN, IG_MAINMENU_CLOSE, IG_MAINMENU_OPTION 852, IG_ABILITY_PAGE_TURN 836, IG_QUEST_LIST_SELECT, IG_QUEST_LOG_OPEN/CLOSE, RAID_WARNING, U_CHAT_SCROLL_BUTTON (Aureus Main.lua:836,848, Kit.lua:1493; OpenMap Map/Dungeons.lua:156-252).
- UIPanelButtonTemplate, UIPanelCloseButton and PanelTabButtonTemplate play no click sound on forever; the Settings controls play their own (Sound.lua:35-43).
- ItemTree plays on "SFX"; Aureus on "Master".

**Tooltips:**
- TooltipDataProcessor.AddTooltipPostCall with Enum.TooltipDataType.Item and .Unit â€” CONFIRMED unguarded (Leatrix_Plus.lua:3649, 10384).
- ItemTree's live trace on 1.60.1 shows the typed Item post call arriving with `data.id` already filled; the install result is "processor(item)" (UI/Tooltip.lua:5074-5098).
- C_TooltipInfo.GetItemByID â€” CONFIRMED (Leatrix_Plus.lua:3034).
- GameTooltip:HookScript('OnTooltipSetUnit') â€” UNKNOWN, LIKELY raises. ItemTree says clients with the data processor "dropped that script type altogether, and asking such a frame to hook it raises" (Tooltip.lua:5034-5036). Check HasScript first, or just use the processor.
- Basic GameTooltip calls (SetOwner, AddLine, AddDoubleLine, Show) â€” CONFIRMED (OpenMap Launcher.lua:30-36).
- Call SetOwner before SetHyperlink. Re-setting the owner afterwards clears the tooltip on Forever (FDJ Journal.lua:2417-2418).
- Keep post-calls cheap and wrapped in pcall. The beta client has crashed inside third-party AH item-key tooltip post-calls (Aureus Core/Compat.lua:132-135, UI/Tooltip.lua:9-13).

## 5. Commands, popups, addon loading, events, TOC

**Slash commands** â€” CONFIRMED: `SLASH_X1 = "/x"; SlashCmdList.X = fn` (Aureus Core/Slash.lua:499-500). Quirk: the handler runs inside the chat edit box's send path. ItemTree defers all work with `C_Timer.After(0)` and never calls SetFocus on open. Otherwise gamepad FrameControlsManager hits ADDON_ACTION_FORBIDDEN on SetPreferredGamepadInteractTarget and the client freezes (UI/Slash.lua:40-49, 2306-2322; UI/Share.lua:37).

**StaticPopupDialogs / StaticPopup_Show** â€” CONFIRMED (OpenMap Map/Pins.lua:244-264 with a data argument, Map/Report.lua:94-112 with hasEditBox, EditBoxOnEnterPressed and EditBoxOnEscapePressed). The edit-box field is hedged as `self.editBox or self.EditBox`, so which name is real is UNKNOWN.

**UISpecialFrames** â€” CONFIRMED (Aureus UI/Main.lua:608; Shadowflare Notes.lua:221).
- The Escape handler reads it through CloseSpecialWindows under securecallfunction.
- ItemTree never calls table.remove on it; it parks its own slot under a dummy name instead (UI/Frame.lua:4350-4400).

**Addon management:**
- C_AddOns.IsAddOnLoaded â€” CONFIRMED unguarded (Leatrix_Plus.lua:49).
- C_AddOns.LoadAddOn â€” CONFIRMED by comment, "C_AddOns.LoadAddOn on the Forever client" (ItemTree Core/Modules.lua:171-183, Core/Data.lua:4809); pcall'd in PortraitDock.lua:749,759.
- Global LoadAddOn, IsAddOnLoaded and GetAddOnMetadata â€” UNKNOWN; fallback only.
- C_AddOns.GetAddOnMetadata â€” LIKELY (Aureus Compat.lua:127-130).
- C_AddOns.EnableAddOn â€” CONFIRMED (Leatrix_Plus.lua:393).

**Event order.**
- ADDON_LOADED: the client puts the saved tables on their globals just before this event; tables made at file scope get replaced (ItemTree Core/Init.lua:1126-1135).
- PLAYER_LOGIN comes next, and is where to build UI and register Settings (Init.lua:1121-1138; ItemTree Options.lua:4310-4316; OpenMap Init.lua:60-89).
- PLAYER_ENTERING_WORLD carries (isInitialLogin, isReloadingUi) â€” CONFIRMED (Init.lua:1113-1118).
- ItemTree builds its hidden window a tick after the first PLAYER_ENTERING_WORLD, behind the loading screen (Frame.lua:8818-8824).

**SavedVariables.**
- `## LoadSavedVariablesFirst: true` appears in ChatForever.toc:7, PortraitDock.toc:7 and Leatrix_Plus.toc:9.
- What it does (LIKELY, from the retail TOC directive; no addon here documents it): the addon's SavedVariables are loaded before its Lua files run, so the SV globals can be read at file scope. Leatrix relies on this with `_G.LeaPlusDB = _G.LeaPlusDB or {}` at file scope (Leatrix_Plus.lua:19). ChatForever still initializes in ADDON_LOADED (Core.lua:165,191).
- All three addons write the value as "true"; whether "1" is also accepted is UNKNOWN.
- Aureus warns: "a third party reported the Forever beta client not restoring SavedVariables" (Aureus Core/DB.lua:6-9). Make the addon fully usable with an empty DB.

**TOC fields:**
- `## Category: Map` (OpenMap.toc:13); localized `## Category-deDE` and others (RareScanner.toc:14-24) â€” LIKELY honored. The forever-branch AddonList loads with the interface (ItemTree Frame.lua:10898-10900).
- `## Group` â€” only in multi-flavor Bagnon.toc:8; UNKNOWN.
- `## IconTexture` â€” CONFIRMED declared by every compartment addon; custom TGA paths work.
- Bindings.xml is auto-discovered, so don't list it in the TOC (ItemTree/Bindings.xml comment). Logs/FrameXML.log (10/18) shows "Unrecognized XML: Binding" errors for Aureus/Bindings.xml.
- Flavor TOC suffix `_Camelot` â€” LIKELY (Plater_Camelot.toc, Interface 16001, version "Plater-v661-Forever").
- Per-file load condition `[AllowLoadGameType camelot]` â€” CONFIRMED in use (RXPGuides.toc:24,43,63; Auctionator.toc:51).

## 6. Forever-specific quirks found in comments

1. **TRILINEAR crash:** see section 3 (Shadowflare Display.lua:38-39; OpenMap conflicts).
2. **Gamepad SmartNavigation post-hooks CreateFrame.** Creating a frame whose parent chain reaches an open Blizzard panel taints that panel's navigation, and its close then has SetPreferredGamepadInteractTarget refused. Pre-create every frame hidden at login, never inside an open panel (ItemTree Options.lua:4084-4090, Badges.lua:2125-2129, Frame.lua:8821-8823, Frame.lua:4523-4528).
3. **UIPanelCloseButton in combat.** It calls HideUIPanel(parent), which is blocked in combat for non-secure callers ("Interface action failed because of an AddOn"). Override its OnClick with a plain `frame:Hide()`, and make no protected calls on the way in or out of a window during combat (ItemTree Frame.lua:3918-3934).
4. **Strata.**
   - The personal resource bar draws through MEDIUM, between your panes. Use HIGH + SetToplevel, and DIALOG for overlays (Frame.lua:67-72, 465-474).
   - SettingsPanel is also HIGH + toplevel and is a managed "center" panel. Closing it runs CloseSpecialWindows, which hides every window in UISpecialFrames (Frame.lua:470-475, 10404-10412).
   - Listen for its open via the EventRegistry callbacks "UIParentPanelManager.ShowUIPanel" and "SettingsPanel.OnHide", never by HookScript on the panel (Frame.lua:4514, 4561-4590).
5. **Taint sources:** UIDropDownMenu (above); a vertical Settings layout (above). Leatrix disables taintLog because it "causes fake errors to show up" (Leatrix_Plus.lua:12-16).
6. **Secret values.**
   - In combat the client hands addon code "secret" values that raise on compare, concat, length, match or use as a table key (ItemTree Core/Util.lua:158-170).
   - UnitName and UnitGUID are secret in this build (FDJ Journal.lua:491, 1999-2001; MapMarkers.lua:161), and chat text can be secret (ChatForever Native.lua:28-38).
   - Guard with `issecretvalue` / `canaccessvalue` (Aureus DB.lua:487-488). This matters for any guild roster or chat UI.
7. **Creature portraits** are drawn as a solid black square until the model loads, and that square paints over every window. Render them off-screen first (FDJ Systems/PortraitPool.lua:1-7).
8. **Edit Mode evidence conflicts.** ItemTree says "the Forever beta ships no Blizzard_EditMode at all" (UI/EditMode.lua:22). PortraitDock says "C_EditMode is native on Forever" (PortraitDock.lua:104) and pcall-loads Blizzard_EditMode (:759). Logs/EditMode.log shows layout data saving. Don't register with Edit Mode.
9. **Limits and string handling:**
   - About 500 timers per addon cap (Aureus Core/Scheduler.lua:5).
   - `string.lower` is ASCII-only, so search also on the raw UTF-8 string (FDJ Journal.lua:6907-6909).
   - C APIs throw on nil or wrong-typed arguments (Aureus Compat.lua:2-6).
10. **Item data loading.** When an Item mixin load fails, its ContinueOnItemLoad callbacks are dropped without running. Use C_Item.RequestLoadItemDataByID with ITEM_DATA_LOAD_RESULT when you need to know about failures (ItemTree UI/Client.lua:533-541).



WORLD OF WARCRAFT: FOREVER â€“ RESEARCH DATA FOR A GUILD ADDON (as of 2026-10-20, during beta; launch Nov 4 2026, raids Dec 9 2026)

Tags: [BLIZZ] = official Blizzard post or dev notes. [DM] = datamined or Wowhead Forever DB. [3P] = third-party guide. [UNC] = uncertain or conflicting.

â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
## 1. RAIDS AT LAUNCH (all unlock Dec 9 2026)
â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
Only three raids are confirmed: Barrow Deeps (10), Hyjal Summit (20) and Onyxia's Lair (40). Molten Core, Blackwing Lair, Zul'Gurub, both Ahn'Qiraj raids and Naxxramas are not confirmed for Forever. [BLIZZ] https://news.blizzard.com/en-us/article/24303862/world-of-warcraft-forever-whats-next-panel-recap ; https://wowforevertools.com/raids
- Roadmap: 2 new raids in spring 2027, then 1 new raid plus 1 revamped iconic raid in summer 2027. [3P] https://conquestcapped.com/guides/wow-forever/wow-forever-raids-overview/
- Raid sizes are fixed, with one difficulty and no Raid Finder. Blizzard's stated direction is a 10-player and a 20-player raid every tier. [3P] https://leprestore.com/guides/world-of-warcraft-forever/raiding-in-forever-will-not-be-what-you-expect/

### A) Barrow Deeps
- 10-player, "maximum-level", level 60. Location is Mount Hyjal. It has 3 entrances across Azeroth; the other 2 are not revealed. [BLIZZ / 3P]
- Instance name [UNC]: Blizzard uses "the Barrow Deeps" in running text. The wiki page title is "Barrow Deeps". No zone or map ID is published. Read GetInstanceInfo() at runtime. https://warcraft.wiki.gg/wiki/Barrow_Deeps_(instance)
- Bosses: 8 total. The order below is the achievement order, which is NOT a confirmed kill order.
  - Live Wowhead Forever achievement "Conqueror of the Deeps" (id 62035) [DM]: Chillhowl, Khalith the Dreadspinner, Amethrax, Ravus and Darlissa, Elder Tangleclaw, Well of Sorrow, Del'lynar Songwood, Sonya Darkhallow. https://www.wowhead.com/forever/achievement=62035/conqueror-of-the-deeps
  - BlizzCon demo and wiki list "Deepscar Matriarch" in place of Chillhowl [UNC; possibly renamed]. The wiki marks Sonya Darkhallow as the end boss. https://warcraft.wiki.gg/wiki/Barrow_Deeps_(instance) ; https://quissy.tv/forever/raids/barrow-deeps/

### B) Hyjal Summit
- 20-player, level 60, Mount Hyjal. Blizzard calls it the largest raid. Legacy challenge name is "Conqueror of the Wilds" [3P].
- Bosses: 13 total, from the client's Legacy list and the BlizzCon demo [DM]. Order is not a confirmed kill order. https://warcraft.wiki.gg/wiki/Hyjal_Summit_(instance)
  1. Bandalar
  2. Time-Lost Battalion
  3. Old Gloomlurker
  4. Kathris the Haunted
  5. Elder Minderel
  6. Council of Thorns
  7. The Wild King
  8. Ancient of Decay
  9. Sylvestris Dusksong
  10. Gharalis the Abyssal
  11. Anara Chillwind
  12. Tracker Stillwind
  13. Nythus the Dreambound (end boss)
- Spelling variants [UNC]: "Elder Minderei", "Sylvesteris Dusksong" and "Nythus the Dreadbound" appear on https://www.warcrafttavern.com/forever/guides/raids/ and in the MrGM tweet.

### C) Onyxia's Lair
- 40-player, Dustwallow Marsh, 1 boss (Onyxia). Whether the Drakefire Amulet attunement stays is not announced [UNC]. https://wowforevercodex.com/raids/onyxias-lair
- The Forever loot table is not published. Sites show the Classic Era table: Ancient Cornerstone Grimoire, Bloodfang Hood, Deathbringer, Vis'kag the Bloodletter, Ring of Binding, Sapphiron Drape, Eskhandar's Collar, Shard of the Scale, the T2 helms, Head of Onyxia, Mature Black Dragon Sinew. [3P/UNC]

### Legacy raid challenges
"Defeat Onyxia", "Defeat all 13 Hyjal Summit bosses" and "Defeat all 8 Barrow Deeps bosses", worth 1 point each. Forever has no standard Achievements tab; Legacy Challenges replace it. [BLIZZ] https://news.blizzard.com/en-us/article/24307383/get-to-know-the-world-of-warcraft-forever-legacy-system ; https://www.wowhead.com/forever/achievements

### Lockouts
NOT ANNOUNCED. No source gives reset intervals. Do not hardcode 7-day or 5-day timers; read them at runtime (e.g. GetSavedInstanceInfo). [UNC] https://wowclassicforever.info/raids/barrow-deeps/ ; https://lfcarry.com/guides/wow-forever-raids

### Loot system
- No official statement on the loot method. [UNC]
- In beta, players describe free-for-all / Need>Greed group loot "with the option to Master Loot". Players also say personal loot "will not be present"; neither claim is from Blizzard. https://us.forums.blizzard.com/en/wow/t/personal-loot-on-raids/2382410 ; https://us.forums.blizzard.com/en/wow/t/personal-loot-in-forever/2383571
- The CurseForge addon "Forever Loot Manager" (Interface 16001) needs master loot with the raid leader as master looter. Its author says auto-handover under master loot has not been verified in a live raid. This is strong evidence that master loot exists in the client [3P]. https://www.curseforge.com/wow/addons/forever-loot-manager
- GDKP is banned. Josh Greenfield said so in the Sept 17 Q&A; Clay Stone later said the ban covers NA/EU only (4Gamers interview). [BLIZZ via press] https://www.wowhead.com/forever/news/gdkp-will-not-be-allowed-in-wow-forever-382968 ; https://www.wowhead.com/forever/news/gdkp-ban-only-applies-to-na-and-europe-realms-4gamers-interview-383345
- Item stats are hidden until the item drops for you or someone on your server. There is no dungeon journal at first, and boss identities are unknown until you go in (Greenfield). https://www.mmorpg.com/interviews/blizzcon-2026-interview-chatting-wow-forevers-campsites-horizontal-progression-and-more-with-blizzard-2000138932
- Every raid boss has a low-drop-rate "chase" item. https://www.wowhead.com/forever/news/chase-items-on-every-raid-boss-the-sun-interview-on-wow-forever-382892
- An epic raid drop grants its appearance only to the player it binds to. Uncommon and Rare BoP dungeon drops grant appearances to all eligible looters. [BLIZZ] https://news.blizzard.com/en-us/article/24303313/world-of-warcraft-forever-deep-dive-panel-recap
- New tier sets plus 1 legendary reward. The legendary is unnamed. [BLIZZ]

### Datamined tier sets
18 sets named "Tier 1", 6 pieces each, Hyjal-tagged. Bonuses are at 2/3/4/5 pieces, not Classic's 2/4/6/8. [DM/UNC] https://warcraftforever.games/guides/datamined-raid-tier-sets ; https://allthings.how/wow-forever-season-1-tier-sets-and-bonuses-for-every-class/
- Warrior: Battlegear of Glory (damage), Battleplate of Glory (tank)
- Paladin: Justice Armor (holy), Justice Battlegear (ret), Justice Battleplate (prot)
- Hunter: Wildstalker Armor
- Rogue: Grimstitch Armor
- Priest: Vestments of Conviction (heal), Raiments of Conviction (shadow)
- Shaman: The Spiritcaller (resto), The Spiritcaller's Rage (enh), The Spiritcaller's Storm (ele)
- Mage: Manaflare Regalia
- Warlock: Demonheart Raiment
- Druid: Grovekeeper Raiment (resto), Grovekeeper Rage (bear), Grovekeeper Eclipse (balance), Grovekeeper Ferocity (feral)
- Icy Veins titles its article "Crafted Tier Sets", so how the sets are obtained is unclear [UNC]. https://www.icy-veins.com/wow-forever/news/wow-forever-crafted-tier-sets-datamined-recipes-costs-and-set-bonuses/

â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
## 2. CLASS / RAID BUFFS IN FOREVER
â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
Main sources:
- Blizzard Beta Development Notes (updates Sept 24, Oct 1, Oct 8, Oct 16): https://us.forums.blizzard.com/en/wow/t/wow-forever-beta-development-notes-%E2%80%93-updated-october-15/2360696 (mirror https://www.bluetracker.gg/wow/topic/us-en/2360696-wow-forever-beta-development-notes-updated-october-15/)
- Spell-data diffs [DM]: https://foreverchanges.pro/class/<class>

Long buffs are generally 1 hour. Group buffs now read "party and raid" members [DM; the exact scope of single-cast group buffs is UNC].
Existing spells appear to keep their Classic spell IDs on Wowhead Forever (e.g. 20217 Kings, 1038 Salvation, 1459 AI, 1243 PW:F, 1126 MotW, 24907 Moonkin Aura, 14752 Divine Spirit, 19740 Might, 19742 Wisdom, 8075 SoE). https://conquestcapped.com/guides/wow-forever/wow-forever-camping/

### PRIEST [DM] https://foreverchanges.pro/class/priest
- Power Word: Fortitude: 1 hr (was 30 min).
- Prayer of Fortitude: 1 hr, party and raid.
- Divine Spirit: now BASELINE, trained at level 30, 1 hr. https://lfcarry.com/guides/wow-forever-class-changes
- Prayer of Spirit: 1 hr, party and raid.
- Shadow Protection: 10 min. Prayer of Shadow Protection: 20 min, party and raid.
- Fear Ward: baseline for all races at level 20.
- Power Infusion: unchanged.
- NEW talent Dark Inspiration (Shadow, row 4): Mind Blast or a full Mind Flay gives you and your party +3/6/9/12/15% Spirit for 10 sec. [BLIZZ Oct 16]

### MAGE [DM] https://foreverchanges.pro/class/mage
- Arcane Intellect: 1 hr.
- Arcane Brilliance: 1 hr, party and raid.
- Amplify Magic / Dampen Magic: buffed values, 10 min.
- No new group buffs.

### DRUID [DM] https://foreverchanges.pro/class/druid
- Mark of the Wild: 1 hr (was 30 min).
- Gift of the Wild: 1 hr, party and raid.
- Improved Mark of the Wild is gone as a talent; its bonus is folded into baseline values.
- Thorns: scales with spell power.
- Leader of the Pack: "now only increases Melee and Ranged Critical Strike chance, and is Raid wide" (+3%, 45 yd). [BLIZZ Oct 16]
- Moonkin Aura: "now only increases Spell Critical Strike chance, and is Raid wide" (+3%, 45 yd). The two auras now stack in one raid. [BLIZZ Oct 16]
- Innervate: 6 min cooldown.

### PALADIN [DM] https://foreverchanges.pro/class/paladin ; [BLIZZ] https://worldofwarcraft.blizzard.com/news/24302099
Blessings: all regular blessings last 1 hr; all Greater blessings last 1 hr and stay class-targeted.
- Blessing of Kings: BASELINE, trained at level 20 (was a Protection talent).
- Blessing of Might
- Blessing of Wisdom: Improved Blessing of Wisdom moved to baseline.
- Blessing of Light
- Greater Blessings of Might, Wisdom, Light and Kings
- Blessing of Sanctuary: REMOVED.

Salvation changes [BLIZZ Oct 16]:
- Blessing of Salvation and Greater Blessing of Salvation are replaced by "Salvation" (Wowhead Forever spell 1038 is now named "Salvation", 1 hr) and "Mass Salvation".
- They "are not exclusive with blessings", so a target can hold a blessing plus Salvation.
- NEW "Revoke" (learned with Salvation) removes Salvation or Mass Salvation from a party or raid member.

Auras:
- Devotion, Retribution and Concentration auras are unchanged.
- Fire, Frost and Shadow Resistance Auras now affect all raid members within 30 yd.
- Sanctity Aura is REMOVED.

NEW TANK SEAL â€“ Seal of Fury:
- Learned at level 10; rank 3 at level 26.
- Flat Holy damage per swing.
- With a shield equipped, each hit grants an absorb equal to 50% of that damage.
- Its Judgement taunts at 10 yd.
- It is not overwritten by Power Word: Shield (Oct 16).

Other:
- New talent Sacred Arbiter (Ret) keeps Judgements of Light, Wisdom and Crusader refreshed. https://lfcarry.com/guides/wow-forever-paladin
- Seals of Light, Wisdom and Crusader: Judgement duration is now 40 sec (was 10). [DM]

### SHAMAN
Oct 16 dev notes [BLIZZ]:
- "Grace of Air Totem, Strength of Earth Totem, Windfury Totem, and Flametongue Totem are now Raid wide."
- Grace of Air is no longer exclusive with Windfury or Flametongue.
- Windfury and Flametongue stay mutually exclusive and affect players only.
- Tranquil Air does not stack with Windfury or Grace of Air (Sept 24).

Other totem facts:
- Persistent totems last 5 min and have 30 yd range [DM]. Totems share a 1 sec GCD, and weapon imbues last 60 min.
- Mana Spring, Healing Stream, Stoneskin, Windwall, Tremor and the cleansing totems have no raid-wide note, so presumably they remain party-only [UNC].
- Resistance totems (Frost, Fire, Nature) now cover party and raid [DM].
- Mana Tide Totem gained an extra rank at level 38.
- New spells: Call of the Elements/Ancestors/Spirits (drop up to 4 totems), Totemic Recall, Totemic Projection. [DM] https://foreverchanges.pro/class/shaman

### WARRIOR
- Battle Shout: "now Raid wide" [BLIZZ Oct 16]. Lasts 3 min (was 2) [DM].
- Improved Battle Shout: removed as a talent. Its bonus is said to be baseline; the datamine shows only the talent's removal [UNC].
- Booming Voice: +10% shout AoE.
- No Commanding Shout. https://foreverchanges.pro/class/warrior

### HUNTER
- Trueshot Aura: "now Raid wide" [BLIZZ Oct 16]. It is a Marksmanship tier-4 talent, 45 yd, +30 ranged AP per the DM (Classic was +50) [UNC on value].
- Aspect of the Wild now covers party and raid.
- Aspect of the Pack: unchanged.
- Hunter's Mark: +26 ranged AP to attackers.
https://foreverchanges.pro/class/hunter

### WARLOCK
- Blood Pact: no data change shown; Improved Imp no longer boosts it.
- Soulstone: unchanged.
- Healthstone: reduced to one spell, with a higher heal value.
- Curse of Agony and Curse of Doom are now Banes (1 per Warlock per target). New Bane of Havoc.
- Curse of the Elements is now "magic resistances âˆ’30 / +4% magic damage" across schools.
- Curse of Recklessness: âˆ’175 armor, no AP gain.
- Demonic Sacrifice: 2 hr. New Demonic Pact talent.
https://foreverchanges.pro/class/warlock

### ROGUE
- No group buffs.
- Expose Armor is stronger: 450 armor at 5 combo points.
- Poisons have more charges, stack with sharpening stones and weightstones, and are now a secondary class skill.
https://foreverchanges.pro/class/rogue

### Legacy perks that affect buffs [BLIZZ]
- "Permanence": "increases the duration of party, raid, and camping buffs" (+50% per rank, 2 ranks). Buff durations can therefore vary by caster.
- "Reagent Economy": "class abilities [no longer] require purchasable reagents", and tier-1 camp items cost no materials.
https://news.blizzard.com/en-us/article/24307383/get-to-know-the-world-of-warcraft-forever-legacy-system

### Races and factions [BLIZZ]
New combinations: Gnome Priest, Human Hunter, Dwarf Shaman (Alliance), Orc Mage, Troll Warlock, Undead Paladin (Horde). Alliance gets Shaman totems and Horde gets Paladin blessings, so buff logic must not assume class by faction. https://news.blizzard.com/en-us/article/24303313/world-of-warcraft-forever-deep-dive-panel-recap
- Undead Paladins start at Bandarion Keep (Tirisfal). https://lfcarry.com/guides/wow-forever-class-changes
- Skyborne (new race, both factions):
  - Both factions: Warrior, Hunter, Rogue, Druid (with their own forms).
  - Alliance "High Order Skyborne": also Mage.
  - Horde "Windshaper Skyborne": also Shaman.
  - Racials: Walk on Air (90 sec cooldown), Wind Blessed (3% haste), Elemental Insight, Read Leyline (Alliance), Skysight (Horde). [BLIZZ Oct 16]
  - https://www.warcrafttavern.com/forever/guides/races/
- Dwarf: Mace Specialization replaced by Earth Fury (+2% crit damage and healing). [BLIZZ Oct 16]
- Factions stay separate on every ruleset. Cross-ruleset grouping is not supported. [BLIZZ]

â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
## 3. CAMPING SYSTEM
â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
### Spell and item IDs [DM, Wowhead Forever]
- 1229737 "Basic Campfire" is a crafting recipe: Create Item "Basic Campfire Kit" (item 279981). Reagent 1 Simple Wood (4470), tool Flint and Tinder, 10 sec cast. https://www.wowhead.com/forever/spell=1229737
- 1283400 "Journeyman Campfire" creates the Journeyman Campfire Kit (item 279961). Reagent 1 Star Wood (11291). https://www.wowhead.com/forever/spell=1283400
- 1291341 "Expert Campfire" creates the Expert Campfire Kit (item 279974). Reagent 1 Thick Logs (272941). https://www.wowhead.com/forever/spell=1291341
- 818 "Basic Campfire" is the placement spell. It summons gameobject 29784, lasts 10 min, has a 5 min COOLDOWN and a 10 sec cast, and cannot be used in combat or while shapeshifted. https://www.wowhead.com/forever/spell=818
- 1229741 "Camp Benefits": the single combined buff. 1 hour, 20 yd radius, cannot be cancelled, server-scripted dummy effects. https://www.wowhead.com/forever/spell=1229741
- Other auras [DM]: 1289723 "Welcoming Campfire" (1-minute countdown that converts to Camp Benefits); 1283391 "Campfire Nearby"; 1229451 "Boosted Rest" (debuff applied by the Camp Tent). https://wowforever.be/guides/camping/

### Hidden per-object auras inside Camp Benefits
These IDs come from the tooltip's $?a conditionals. They are useful for detecting which camp buffs a player has. https://github.com/Emyrk/chronicle/issues/1066
| Aura ID | Object |
|---|---|
| 1230587 | Mana Well |
| 1230172 | Sharpening Wheel |
| 1230653 | Enchanted Lute |
| 1230124 | First Aid Kit |
| 1230098 | Fish Bowl |
| 1229513 | Incense Candle |
| 1230164 | Lodestone |
| 1229519 | Camp Chair |
| 1229718 | Faction Banner |
| 1229451 | Tent / Boosted Rest |

### Campfire tiers (Cooking skill)
| Tier | Learn at | Use at | Objects held | Blueprint |
|---|---|---|---|---|
| Basic | 1 | 1 | 3 | none |
| Journeyman | 90 | 140 | 5 | 273087, drops from Lord Serpentis in Wailing Caverns |
| Expert | 200 | 220 | 10 | 273101, drop source unknown |
- Some guides give 90 and 200 as both the learn and use levels [UNC]. https://www.wow-professions.com/forever/camping-guide ; https://foreverchanges.pro/professions/camping

### Rules
- Camping unlocks at level 5 through the quest "The Great Outdoors".
- Sit (or sleep, lie down, kneel, craft) near the fire for about 1 minute to get the buff. Since Sept 24 you can buff, cast and craft during the countdown. [BLIZZ]
- Buffs last 1 hour; Permanence extends this.
- Each player places 1 object per fire. All of a player's camp objects share a 1 hour (3600 s) cooldown; the Field Guide Legacy perk cuts it by 8% per rank.
- The fire and its fixtures last about 10 min (Greenfield). Wowhead's beta DB lists 15 min [UNC].
- No group is required to receive the buffs.
- A higher-tier object can replace a lower one, and doing so ignores the cooldown.
- No fires in cities. Fires must be about 100 yd apart. Camps are NOT sanctuaries.
- Camp buffs are "weaker versions" of class buffs and are "mutually exclusive" with them. [BLIZZ wording, Oct 1]
- Sources: https://www.mmorpg.com/interviews/blizzcon-2026-interview-chatting-wow-forevers-campsites-horizontal-progression-and-more-with-blizzard-2000138932 ; https://classicwowforever.com/professions/camping/ ; https://hostedgg.com/blog/wow-forever-camping-system

### Tier-1 objects (skill 20, from trainer)
Format: Object (placement spell ID / item ID) â€“ profession â€“ buff at level 60 â€“ exclusive with.
Values scale with level; the low end shown is the starting value at low level.
- Mana Well (1230564 / 279956) â€“ Alchemy â€“ 10â€“29 mp5 â€“ Blessing of Wisdom
- Sharpening Wheel (1230171 / 279944) â€“ Blacksmithing â€“ +6â€“34 Str â€“ Strength of Earth Totem. Blizzard's recap originally said Attack Power [UNC].
- Enchanted Lute (1230643 / 279976) â€“ Enchanting â€“ +28â€“308 armor, +2â€“13 all stats, +6â€“22 all resists â€“ Mark/Gift of the Wild
- Incense Candle (1229705 / 279962) â€“ Herbalism â€“ +2â€“25 Int â€“ Arcane Intellect/Brilliance
- Lodestone (1230161 / 279960) â€“ Mining â€“ +12â€“90 melee AP â€“ Blessing of Might
- Camp Chair (1229517 / 279979) â€“ Skinning â€“ +2% crit (spells and attacks) â€“ Moonkin Aura. Some sites also list Leader of the Pack [UNC after the Oct 16 aura split].
- Faction Banner (1229504 per wow-professions, or 1263425 per warcrafttavern and forg.gg [UNC; may be separate Horde and Alliance versions] / item 279972) â€“ Tailoring â€“ +14â€“32 Spirit, own faction only â€“ Divine Spirit
- First Aid Kit (1230117 / 279968) â€“ First Aid â€“ +3â€“56 Stam â€“ Power Word: Fortitude
- Fish Bowl (1229745 / 279967) â€“ Fishing â€“ +8% all stats â€“ Blessing of Kings
- Camp Tent (1229432 / 279978) â€“ Leatherworking â€“ rested XP up to 5% of a level, then "Boosted Rest" for 1 hr â€“ no class equivalent
- Reagent Bot (1230656 / 279950) â€“ Engineering â€“ vendor for class reagents â€“ no buff
Sources: https://foreverchanges.pro/professions/camping ; https://classicwowforever.com/professions/camping/ ; https://www.warcrafttavern.com/forever/guides/camping-objects-buffs/ ; https://forg.gg/en/forever/campsite

### Tier-2 (skill 140) and tier-3 (skill 300) objects
Tier 2 and 3 need blueprints. Each also grants its profession's tier-1 buff [3P]. Format: tier 2 (spell ID, blueprint source) / tier 3 (spell ID).
- Alchemy: Fermenter (1263005, Rath'mael) / Alchemy Laboratory (1263078)
- Blacksmithing: Anvil (1263041, Gilnid in Deadmines) / Master Forge (1263073)
- Enchanting: Arcane Salvager (1263056, Shade of the Archmage in Dalaran) / Arcane Forge (1263082)
- Engineering: Repair Bot (1263034, Sneed) / Anarchist's Workbench (1263083)
- Leatherworking: Tanning Rack (1263031, Razorclaw) / Sewing Machine (1263079)
- Tailoring: Spinning Wheel (1263032, Unstable Sentinel) / Loom (1263080)
- Herbalism: Greenhouse (1262980) / Seed Hybridizer (1263070)
- Mining: Rock Garden (1262975) / Molten Foundry (1263071)
- Skinning: Field Guide (1262985, teaches Track Beasts) / Trapper's Workbench (1262982)
- First Aid: Toxin Study (1262996) / Plague Doctor's Laboratory (1263001)
- Fishing: Fishing Rack (1262990, Gelihast) / Fishing Hut (1262998)
- Cooking: Cookie's Feast (1262978, Cookie in Deadmines; Stamina food) / Iron Oven (1263067)
https://www.wow-professions.com/forever/camping-guide

### Instances and raids [UNC overall]
- Fires cannot be placed in instances. The Basic Campfire is reportedly flagged outdoor-only, excluding instances, raids and arenas [3P]. Groups leave dungeons to re-camp outside. https://classicwowforever.com/professions/camping/ ; https://us.forums.blizzard.com/en/wow/t/campfire-buffs-and-dungeonsraids/2359157
- The camp buff appears to persist into dungeons: "campfire buffs are currently available in dungeons" (player report). No blue post. https://us.forums.blizzard.com/en/wow/t/campfire-buffs-and-dungeonsraids/2359157
- Raids: "camp fires are not currently usable in raid" (player report, EU forum). Raids could not be tested in beta. No official ruling; verify on Dec 9. https://eu.forums.blizzard.com/en/wow/t/state-of-group-raid-buffs-in-wow-forever/632005

â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
## 4. WORLD BUFFS
â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
- Policy: world buffs stay in the open world but lose their raid value. This rests on Windows Central's paraphrase of a Sept 18 Ion Hazzikostas interview: "tedious world buff farming for raiding is being removed". No patch note confirms it, and the exact mechanic (suppressed on entry or not) is unknown [UNC]. Coverage of dungeons and battlegrounds is also unconfirmed. https://wowdee.com/articles/wow-forever-world-buffs ; https://leprestore.com/guides/world-of-warcraft-forever/raiding-in-forever-will-not-be-what-you-expect/
- Spells still in Forever data [DM]:
  - Rallying Cry of the Dragonslayer (22888): 2 hr, persists through death. https://www.wowhead.com/forever/spell=22888
  - Songflower Serenade (15366): 1 hr. https://www.wowhead.com/forever/spell=15366
  - Warchief's Blessing (16609): 1 hr, persists through death. https://www.wowhead.com/forever/spell=16609
  - Spirit of Zandalar (24425): 2 hr, 16% stats, 11% speed. Zul'Gurub is not confirmed for Forever. https://www.wowhead.com/forever/spell=24425
  - Mol'dar's Moxie (22818, Dire Maul): 2 hr, persists through death. https://www.wowhead.com/forever/spell=22818
- Dire Maul tribute run exists in Forever guides. https://conquestcapped.com/guides/wow-forever/wow-forever-dire-maul-guide/
- Darkmoon Faire: data exists (faction 909, 46 quests), but the beta calendar (build 70374, Oct 15) showed no Faire for Oct or Nov [UNC]. https://github.com/nazumods/wow/issues/964 ; https://www.wowhead.com/forever/faction=909/darkmoon-faire

â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
## 5. PROFESSIONS
â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
- 12 professions:
  - Gathering: Herbalism, Mining, Skinning
  - Crafting: Alchemy, Blacksmithing, Enchanting, Engineering, Leatherworking, Tailoring
  - Secondary: Cooking, First Aid, Fishing
- No new primary profession and no Jewelcrafting. Lockpicking and Poisons are Rogue class tradeskills. https://wowforevertierlist.com/professions
- "Over 600 new recipes across professions and level ranges." [BLIZZ] https://news.blizzard.com/en-us/article/24303313/world-of-warcraft-forever-deep-dive-panel-recap
- Notable changes:
  - Healing potions moved to First Aid.
  - Alchemy (Mixology): elixirs and flasks last 2x as long and are 25% stronger.
  - Blacksmithing: Repair All (8 hr cooldown at rank 1, 4 hr at rank 2), belt buckles.
  - Enchanting: ring enchants.
  - Engineering: Tinkerbox.
  - Leatherworking: bracer kits, saddle.
  - Tailoring: cloak embroidery, reagent bag.
  - Gathering perks: Natural Talent (Herbalism), Made of Metal +5% health (Mining), Beasts of the Wild (Skinning).
  - Cooking: food gives about 5% bonus XP.
  - https://wowforevertierlist.com/professions ; https://wowsod.pro/wow-forever/professions
- Cooldowns [DM, Wowhead Forever]. They appear to be 1 hour shorter than Classic.
  - Transmute: Arcanite (17187): 1.958 days, about 47 h. https://www.wowhead.com/forever/spell=17187
  - Elemental transmute, e.g. Air to Fire (17559): 23 h. https://www.wowhead.com/forever/spell=17559
  - Mooncloth (18560): 3.958 days, about 95 h. No moonwell requirement is shown. https://www.wowhead.com/forever/spell=18560
  - Salt Shaker (19566): 2.958 days, about 71 h. https://www.wowhead.com/forever/spell=19566
  - Enchanting shard transmutes: 20 h, shared [3P].
  - Legacy perk Dedicated Study: 23 h [3P].
- Legacy points: 1 point each at skill 150, 225 and 300 in each of the six crafting professions (18 total). [BLIZZ]

â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
## 6. GUILD FEATURES AND ADDON-ENVIRONMENT NOTES
â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
### Guild
- Guild bank exists in beta and costs 100g to unlock (player reports; no blue post). Tab count and prices are unpublished [UNC]. https://us.forums.blizzard.com/en/wow/t/cost-of-guild-bank/2363031
- The bank log keeps the last 25 entries per tab, with timestamps only to the hour [3P]. https://www.curseforge.com/wow/addons/forever-guild-bank
- An in-game Calendar exists; it was read in-game on build 70374. Guild-event support is not documented. https://github.com/nazumods/wow/issues/964
- No achievements tab, so no guild achievements; Legacy Challenges replace achievements. Guild levels and perks are not mentioned anywhere. https://www.wowhead.com/forever/achievements
- Oct 16 dev note: "Updated the Guild & Communities dialogs to be usable with a gamepad", so the modern Communities UI is present. [BLIZZ]
- Guilds are single-faction. Cross-ruleset grouping is not supported. Beta characters, names and guilds are wiped after the Oct 21 stress test. https://lfcarry.com/guides/wow-forever-guilds

### Client and API [3P/UNC, but critical for the addon]
- Version 1.60.1, Interface 16001.
- WOW_PROJECT_ID is 18 (WOW_PROJECT_CAMELOT) on build 70338. Older build 69913 reported 1.
- Midnight-style "secret values" are active. UnitHealth and UnitName can be secret in combat, and CombatLogGetCurrentEventInfo is reported unavailable.
- Classic globals were removed (GetSpellInfo, GetItemInfo, GetTalentInfo, GetNumSkillLines). Use C_Spell, C_Item and C_Traits instead.
- Addon messaging is restricted or queued inside instances.
- Beta bug: SavedVariables are written but not loaded back at login.
- Sources: https://wowforeverguides.com/addons/api-cheatsheet ; https://wowforeverbuilds.com/news/what-the-wow-forever-beta-breaks-for-addons-secret-health-values-dead-secure-sni ; https://www.curseforge.com/wow/addons/forever-guild-bank ; https://www.curseforge.com/wow/addons/forever-loot-manager

### Key uncertainties to verify after launch
1. Raid lockout durations.
2. Built-in loot methods (master loot almost certainly present but not officially stated).
3. Barrow Deeps first boss: Chillhowl or Deepscar Matriarch.
4. Client instance name strings and IDs.
5. Whether Camp Benefits work in raids.
6. Exact world-buff suppression mechanic.
7. Faction Banner spell ID.
8. Trueshot Aura value.
9. Whether "party and raid" group buffs reach the whole raid in one cast.


