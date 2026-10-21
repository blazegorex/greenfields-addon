# Greenfields: WoW Forever (Interface 16001) Engineering Fact Sheet

**Version 1.0, consolidated 2026-10-20.**
- Evidence comes from beta builds 1.60.1.70009 to 70425. The client reports itself as 1.60.1, Interface 16001.
- Launch is 2026-11-04. Raids unlock 2026-12-09. Leatrix already gates code for patch 1.60.2 (TOC 16002).
- Engineers code against this document. If something here conflicts with a single recon report, the ruling in §0.3 applies.

---

## 0. Ground rules

### 0.1 How to read this document

**Status tags**

| Tag | Meaning |
|---|---|
| **CONFIRMED** | Called unguarded on a Forever or Camelot load path, or tested in game by a Forever-only addon. |
| **LIKELY** | Reached only behind a pcall, an existence guard, a fallback or an option gate. Also used for things cited from Forever-branch Blizzard docs or UI source, or backed by strong third-party evidence. |
| **UNKNOWN** | No evidence either way. Feature-detect it and keep it off critical paths. |
| **ABSENT** | Evidence that it is missing, removed, or forbidden to addons. Do not call it. |
| **[SUPP]** | A value that is not in any recon report (it comes from Classic Era or retail knowledge). Verify it in game before relying on it. |

**Evidence root:** `C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns\`

**Abbreviations used in evidence references**

| Abbreviation | Path or source |
|---|---|
| LP | Leatrix_Plus\Leatrix_Plus.lua |
| LPB | Leatrix_Plus\Bindings.xml |
| LPL | Leatrix_Plus_Library.lua |
| LPM | Leatrix_Plus_Minimap.lua |
| RS | RareScanner\Core\Service\RSEventHandler.lua (other RareScanner files are named in full) |
| SF | Shadowflare\Core.lua |
| SFA | Shadowflare\AuraShow.lua |
| IT | ItemTree\… |
| ITP | ItemTree_Professions\… |
| ITD | ItemTree_Data\Data\generated\… |
| PL | Plater\Plater.lua |
| PLA | Plater\Plater_Auras.lua |
| PLC | Plater\Plater_Comms.lua |
| RXP | RXPGuides\… |
| FDJ | ForeverDungeonJournal\… |
| OM | OpenMap\… |
| AU | Aureus\… |
| BB | BagBrother\… |
| AUC | Auctionator\… |
| CF | ChatForever\… |
| PD | PortraitDock\… |
| TT | TomTom\TomTom.lua |
| SC | BagBrother\libs\StaleCheck-1.0\StaleCheck-1.0.lua |
| CTL | ChatThrottleLib v32 (RXPGuides copy) |
| ACE | AceComm-3.0 v14 r1333 (RXPGuides copy) |
| WEB | The web research report. Its sources are Blizzard posts and dev notes, Wowhead Forever, and third-party sites. |

### 0.2 Platform ground truth

1. **Detect Forever by TOC number.**
   - Use `select(4, GetBuildInfo())`. Forever is `>= 16000 and < 20000` (AUC Source/Constants/Main.lua:56-57; PL libs/DF/fw.lua:264).
   - `WOW_PROJECT_ID == WOW_PROJECT_CAMELOT == 18` on build 70338 and later (BB core/core.lua:11). Build 69913 reported 1 (WEB), so use it only as a secondary signal.
2. **The API surface is retail (Midnight/12.x) shaped.**
   - Mainline files with a thin Camelot layer (IT UI/Sound.lua:7-9).
   - The TOC load-type tag is `camelot` (RXP.toc:24; AUC.toc:51).
   - Plater treats Forever as Midnight: `IsAddonApocalypseWow`, `IsForeverWow` and `IsMidnightWowAPI` are all true (PL fw.lua:260-269).
   - The reference for Blizzard UI code is the `forever` branch of github.com/Gethe/wow-ui-source.
3. **Secret values are active.**
   - Addon code receives "secret" values in combat, in instances, during encounters, during chat lockdown, and for non-player units.
   - This covers aura fields, UNIT_AURA payloads, UnitName, UnitGUID, the UnitClass token, chat text and senders, roster fields, spellIDs in UNIT_SPELLCAST_SUCCEEDED, GetLootSourceInfo, CHAT_MSG_SKILL and CHAT_MSG_LOOT text, and C_Spell.GetSpellCooldown results.
   - Evidence: IT Core/Util.lua:158-176; SFA:3; SF:398,1444-1452; RS:43,607,772,935; LP:1183,10359; FDJ Core/Journal.lua:491,1999-2001; CF Native.lua:28-38.
4. **An addon-restriction framework exists.**
   - CVars: `addonMapRestrictionsForced`, `addonChatRestrictionsForced`, `addonCombatRestrictionsForced`, `addonPvPMatchRestrictionsForced`, `addonEncounterRestrictionsForced`, `addonChallengeModeRestrictionsForced` (LP:14476-14483).
   - Leatrix notes that some settings "do not apply during instanced combat encounters" (LP:9734-9738).
5. **C APIs throw on nil or wrongly typed arguments** (AU Core/Compat.lua:2-6). Type-check before calling.
6. **Registering an unknown event raises** (AU Core/Namespace.lua:152-157; FDJ Systems/VersionCheck.lua:165-167). Register every event inside pcall.
7. **SavedVariables may not be restored on the beta client** (AU Core/DB.lua:6-9; WEB). The addon must be fully usable with an empty database.
8. **The second return of UnitName and UnitFullName is a surname, not a realm** (LP:10210; BB core/api/owners.lua:51-58). Realm strings are unstable between sessions (AU Compat.lua:243-245).

### 0.3 Mandatory helpers

Every module uses these. Do not re-implement them.

```lua
local _, _, _, TOC = GetBuildInfo()
local IS_FOREVER = TOC >= 16000 and TOC < 20000

local issecretvalue, canaccessvalue = _G.issecretvalue, _G.canaccessvalue
-- true => v must not be compared, indexed, used as a key, persisted, concatenated into persisted/sent data
local function IsSecret(v)
  if issecretvalue and issecretvalue(v) then return true end
  if canaccessvalue and not canaccessvalue(v) then return true end
  return false
end
local function Clean(v) if IsSecret(v) then return nil end return v end   -- usable value or nil

local function Try(fn, ...)                       -- API may be missing or throw on bad args
  if type(fn) ~= "function" then return false end
  return pcall(fn, ...)
end

local function SafeRegister(frame, event, ...)    -- ... = optional units for RegisterUnitEvent
  local EU = C_EventUtils
  if EU and EU.IsEventValid then
    local ok, valid = pcall(EU.IsEventValid, event)
    if ok and valid == false then return false end
  end
  if select("#", ...) > 0 then return (pcall(frame.RegisterUnitEvent, frame, event, ...)) end
  return (pcall(frame.RegisterEvent, frame, event))
end

-- kind: "Chat" (CONFIRMED); "Combat","Encounter","Map","PvPMatch","ChallengeMode" (LIKELY, inferred from the CVar names)
local function RestrictionActive(kind)
  local R, E = C_RestrictedActions, Enum and Enum.AddOnRestrictionType
  if not (R and R.IsAddOnRestrictionActive and E and E[kind] ~= nil) then return false end
  local ok, active = pcall(R.IsAddOnRestrictionActive, E[kind])
  return ok and active == true
end

local function AurasSecret()
  local S = C_Secrets
  if S and S.ShouldAurasBeSecret then
    local ok, r = pcall(S.ShouldAurasBeSecret)
    if ok then return r == true end
  end
  return InCombatLockdown()
end
```

### 0.4 Contradiction rulings

These rulings are binding.

| # | Topic | Conflict | Ruling |
|---|---|---|---|
| R1 | Classic globals: GetSpellInfo, UnitAura, UnitBuff, UnitDebuff, GetTalentInfo, GetNumTalentTabs, GetTalentTabInfo, GetNumSkillLines, GetSkillLineInfo, GetItemInfo | Local addons always guard them (UNKNOWN). IT UI/PlayerSkills.lua:248 says the skill sheet "reads empty". WEB says they were removed. | Treat as **ABSENT**. Use the C_* replacements. If a global exists at runtime it may be a stub, so never trust an empty answer from it. |
| R2 | What a secret value does | IT Util.lua:158-170: raises on compare, concat, length, match, or use as a table key. ForeverBotTelemetry Telemetry.lua:5-8: format and `..` pass silently, and the error comes at C boundaries such as table.concat. | Both are true: some operations raise and others silently produce a secret result. Call `IsSecret()` before any operation. Treat anything derived from a secret as secret. Never persist it, use it as a key, or send it. |
| R3 | When values are secret | FDJ: UnitName and UnitGUID are secret "in this build". LP: UnitName(target) "can be secret". AU and LP: non-player GUIDs. | It depends on context (combat, instance, encounter, lockdown, non-player unit). Check each value. Group players read out of combat are LIKELY readable, but still check. |
| R4 | WOW_PROJECT_ID | 18 on build 70338 (BB) vs 1 on build 69913 (WEB). | Gate on the TOC number (see §0.2). |
| R5 | C_AddOns.GetAddOnMetadata | Comms report: CONFIRMED (SC:96, unguarded). UI report: LIKELY (AU Compat.lua:127-130). | **CONFIRMED**. |
| R6 | Addon-message delivery | IT Core/Share.lua:2 says the "hidden channel does not carry addon messages on the beta". FDJ, OpenMap, RXP and Plater send on GUILD, PARTY, RAID and WHISPER. WEB says addon messages are "restricted or queued inside instances". | The IT claim is about a custom CHANNEL. GUILD, PARTY, RAID, INSTANCE_CHAT and WHISPER are LIKELY delivered when no restriction is active. Never use CHANNEL-type addon messages. Run the self-echo probe (§D). Expect loss or delay inside instances and encounters. |
| R7 | Master loot | Local: no API references, and the Mainline loot UI has no master-looter frame. WEB: "Forever Loot Manager" (Interface 16001) requires master loot, and beta players report the option. | The feature is LIKELY present, but the API names and signatures are UNKNOWN. Master-loot features are optional and feature-detected. |
| R8 | Guild bank | Local: UNKNOWN. WEB: it exists in beta and costs 100g to unlock (player reports; the Forever Guild Bank addon exists). | LIKELY exists; the API is UNKNOWN. Build it as an optional module. |
| R9 | "Camp Benefits" spell 1229741 | No match in any local file vs Wowhead Forever datamine. | Use 1229741 and also match by the name read at runtime with `C_Spell.GetSpellName(1229741)`, falling back to the localized "Camp Benefits". |
| R10 | Camp object spell IDs | WEB's tier-1 "placement spell" column vs ITD recipe data. ITD shows 1229432 (Camp Tent, Recipes_165) and 1229517 (Camp Chair, Recipes_393) are **Create-Item recipe spells**, and their item-use spells are 1307230 and 1307229. | WEB's tier-1 spell column lists **crafting recipe spell IDs**. Item-use (placement) spells are known only for the five in §F.4. |
| R11 | Campfire placement spell | 818 (Wowhead: summons GO 29784, lasts 10 min, 5-min cooldown) vs 1307227 (ITD item-use spell of the Basic Campfire Kit). | Watch both, plus 1307252 and 1307237. The 5-minute cooldown is corroborated twice: 818 has ccd 300000 ms and the kit item cooldown is 300000 ms. |
| R12 | Fire lifetime | 10 min (Greenfield interview; spell 818) vs 15 min (Wowhead beta DB). | Default to 600 s and display it as approximate. |
| R13 | Campfire tier skill levels | WEB: learn 90/200, use 140/220. Other guides: 90/200 for both. | The learn rank is 90 and 200 (ITD r=90 and r=200 agree). Use-levels are uncertain. |
| R14 | What Camp Chair (+2% spell and attack crit) excludes | Moonkin Aura vs Leader of the Pack. | Since the Oct 16 aura split, sources list Moonkin Aura. A conflict with Leader of the Pack is uncertain. Never predict exclusivity: show the auras actually present. Keep the rule as a data flag (§F.3). |
| R15 | Sharpening Wheel stat | Strength vs attack power. | **Strength**, which is why it is exclusive with Strength of Earth Totem. "Attack power" was wording in an early recap. |
| R16 | Faction Banner spell | 1229504 vs 1263425. | Accept both. They may be per-faction versions. |
| R17 | Edit Mode | IT UI/EditMode.lua:22: "no Blizzard_EditMode". PD PortraitDock.lua:104: "C_EditMode is native", plus Logs/EditMode.log. | Do not integrate with Edit Mode. |
| R18 | TRILINEAR texture filter | SF Display.lua:38-42: fatal crash at launch that pcall cannot catch. OM passes TRILINEAR at runtime. | **Never pass a filter argument.** |
| R19 | GetProfessions slot 3 | Forever: First Aid (IT reading the Camelot ProfessionsBook). Retail: Archaeology. | Identify professions by skillLine (7th return), never by slot. |
| R20 | Profession list | WEB: 12 professions. ITD also has 40 Poisons, 142 Survival, 633 Lockpicking and 3012 Comprehension. RXP's DB lists Jewelcrafting and Inscription. | There are 12 professions. 40 and 633 are Rogue class tradeskills. 3012 is a Mage class skill. The status of 142 is uncertain. There is no Jewelcrafting or Inscription (RXP copied that table from other versions). |
| R21 | Boss names | Barrow Deeps: Chillhowl (achievement 62035) vs Deepscar Matriarch (BlizzCon/wiki). Hyjal spelling variants. | Use an alias table and learn encounterID → name at runtime. |
| R22 | Buff magnitudes | For example, Trueshot Aura +30 vs Classic +50. | Never hard-code magnitudes. Display them from the tooltip if they are needed at all. |
| R23 | Profession cooldowns | ITD (ms) and Wowhead agree: Arcanite 169200000 ms ≈ 47 h, elemental 82800000 ms = 23 h, Mooncloth 342000000 ms = 95 h. | No conflict. Use §F.7. |
| R24 | GetGuildRosterInfo layout | LP uses fields 1, 9, 14 and 17, which matches the retail 17-return layout. | Fields 1, 9, 14 and 17 are CONFIRMED; the rest are LIKELY. |
| R25 | "Party and raid" group buffs | Whether one cast covers the whole raid is uncertain. | Detect actual coverage per unit. Never assume it. |
| R26 | Camp buffs in instances | Player reports say the buff persists into dungeons and fires are not usable in raids. No blue post. | Fires cannot be placed in instances. Whether the buff persists into raids is unknown until Dec 9; detect it at runtime. |
| R27 | Opening the settings page | IT calls `Settings.OpenToCategory(category:GetID())`. FDJ assigns `category.ID`. | Use `category:GetID()`. |

---

## A. API availability

### A.1 Environment, secrets, restrictions

| API or event | Status | Signature and returns | Evidence | Safe use |
|---|---|---|---|---|
| GetBuildInfo() | CONFIRMED | → version, build, date, tocVersion | PL fw.lua:260-267; AUC Constants/Main.lua:56 | Gate Forever on toc 16000–19999. |
| WOW_PROJECT_CAMELOT / WOW_PROJECT_ID | CONFIRMED (build 70338+) | 18 | BB core/core.lua:11 | Secondary signal only (R4). |
| issecretvalue(v) | CONFIRMED | → bool | RS:43,780,935; SF:290-303 | Use through `IsSecret`. |
| canaccessvalue(v) | CONFIRMED | → bool | LP:137,1183,7812,7826,10068 | Use through `IsSecret`. |
| scrubsecretvalues(...) | CONFIRMED | Returns its arguments with secrets removed. RS applies it to the UNIT_AURA updateInfo table. Whether it scrubs fields inside a table is UNKNOWN. | RS:935 | Still `Clean()` each field. |
| C_Secrets.ShouldAurasBeSecret() | CONFIRMED | → bool | LP:7807,7839,14253; PLA:1977,2017 | Gate every aura read. |
| C_Secrets.CanCompareUnitTokens() | CONFIRMED | → bool | LP:10362; PLA:1977,2017 | Gate UnitIsUnit and token comparisons. |
| C_RestrictedActions.IsAddOnRestrictionActive(Enum.AddOnRestrictionType.Chat) | CONFIRMED for `.Chat`; other members LIKELY | → bool | LPB:20 | `RestrictionActive()` |
| addon*RestrictionsForced CVars | CONFIRMED (they exist) | | LP:14476-14483 | Read-only. Never set them (system setting). |
| C_EventUtils.IsEventValid(event) | LIKELY | → bool | RXP functions.lua:210-215; PL LibRangeCheck-3.0.lua:4622 | Used in `SafeRegister`. |
| InCombatLockdown() | LIKELY (universal; no explicit citation) | → bool | | |
| C_ChatInfo.InChatMessagingLockdown() | CONFIRMED | → bool | LP:13718 | Check before every send. |
| C_GameRules.IsGameRuleActive(Enum.GameRule.PvPRuleset, RPRuleset or HardcoreRuleset) | CONFIRMED | → bool | RXP libs/AceDB-3.0:266-272 | Part of the SavedVariables partition key. |
| RegionalUniqueNamesEnabled() | LIKELY | → bool | PL AceDB-3.0:263; AUC ModernAH Variables/Main.lua:14 | |

### A.2 Addon management and time

| API | Status | Signature | Evidence | Notes |
|---|---|---|---|---|
| C_AddOns.IsAddOnLoaded(name) | CONFIRMED | → loadedOrLoading, loaded | LP:49 | |
| C_AddOns.LoadAddOn(name) | CONFIRMED (by comment) | | IT Core/Modules.lua:171-183; PD:749,759 | Wrap in pcall. |
| C_AddOns.GetAddOnMetadata(name, field) | CONFIRMED (R5) | → string | SC:96 | |
| C_AddOns.EnableAddOn | CONFIRMED | | LP:393 | Never call it (user configuration). |
| Global LoadAddOn, IsAddOnLoaded, GetAddOnMetadata | UNKNOWN | | Fallback only | Do not use. |
| hooksecurefunc | CONFIRMED | | LP:829,854; CTL:245 | |
| C_Timer.After(s, fn), NewTimer(s, fn), NewTicker(s, fn[, iterations]) | CONFIRMED | | LP:38,6693,10875; OM Map/Nav.lua:299; PD:880; SF:1253 | AU Core/Scheduler.lua:5 claims (unverified) a cap of about 500 timers per addon. Keep 50 or fewer live timers and use one shared scheduler. |
| GetTime(), GetServerTime(), time(), date(), date("*t") | CONFIRMED | | AU Core/Util.lua:21-22; LP:5466; OM Pins.lua:296; RS RSEntityStateHandler.lua:54,58; AU UI/Chart.lua:102-121 | Persist timestamps as GetServerTime() epoch values. |
| C_DateAndTime.GetSecondsUntilWeeklyReset, GetCurrentCalendarTime, GetServerTimeLocal | CONFIRMED | | RS RSEntityStateHandler.lua:58; RS RSTelemetryEngine.lua:17; RS MidnightPrePatch.lua:46 | |
| GetQuestResetTime() | CONFIRMED | → seconds | RS RSEntityStateHandler.lua:54 | |
| C_Calendar.* | UNKNOWN | | WEB: the Calendar UI exists (build 70374) | Optional only. |

### A.3 Units, names, GUIDs, classes

| API | Status | Signature and returns | Evidence | Notes |
|---|---|---|---|---|
| UnitName(unit) | CONFIRMED | → name, **surname** (not a realm) | LP:10210,10359 | Can be secret. |
| UnitFullName(unit) | CONFIRMED | → name, surname or nil | LP:5462,5493; BB owners.lua:52 | |
| UnitNameUnmodified(unit) | LIKELY | | PL AceDB-3.0:273 | |
| GetUnitName(unit, showServer) | CONFIRMED | | OM Pins.lua:172-183 | |
| Ambiguate(name, "none") | CONFIRMED | | ACE:244; OM Pins.lua:286 | |
| GetRealmName(), GetNormalizedRealmName() | CONFIRMED | Unstable between sessions | LP:13708,8070; AU Compat.lua:243-245 | Never use as a key. |
| GetRealmID() | LIKELY | | AU Compat.lua:247; IT Core/Collector.lua:4454-4461 | |
| GetAutoCompleteRealms(), C_AutoComplete.GetAutoCompleteRealms() | CONFIRMED | | BB owners.lua:55; LP:13615 | |
| UnitGUID(unit) | CONFIRMED | Player GUIDs match `^Player%-%d+%-%x+$` | ForeverBotTelemetry Telemetry.lua:106; PLC:60; CF Native.lua:283 | Non-player GUIDs can be secret (AU DB.lua:486-488; LP:2702). **Primary identity key.** |
| GetPlayerInfoByGUID(guid) | LIKELY | 2nd return = class file | CF Native.lua:289-290 | Type-check the argument and use pcall. |
| UnitClass(unit) | CONFIRMED | → localized, classFile, classID | OM Nav.lua:388; LP:10199 | The token can be secret. |
| RAID_CLASS_COLORS | CONFIRMED | | LP:59,4108 | |
| C_ClassColor.GetClassColor(classFile) | LIKELY | | OM Nav.lua:391; CF Native.lua:270 | |
| GetClassColor (global) | UNKNOWN | | | Do not use. |
| CLASS_ICON_TCOORDS | LIKELY | | FDJ Journal.lua:3372; FDJ LootFilter.lua:533 | |
| LOCALIZED_CLASS_NAMES_MALE | LIKELY | | SF Options.lua:108 | |
| UnitIsDeadOrGhost(unit) | CONFIRMED | | LP:10194 | |
| UnitIsInMyGuild(unit) | CONFIRMED | | LP:10254 | |
| C_CreatureInfo.GetCreatureID(guid) | CONFIRMED | → npcID | RS | Check the GUID with IsSecret first. |
| UnitIsAFK, UnitIsDND, PLAYER_FLAGS_CHANGED | UNKNOWN | | | Feature-detect. |
| UnitExists, UnitIsConnected, UnitIsVisible | UNKNOWN (retail-standard, expected present) | | | Call through `Try`. |

### A.4 Combat-log family (details in §B)

| API or event | Status | Evidence |
|---|---|---|
| COMBAT_LOG_EVENT_UNFILTERED | **ABSENT for addons.** Marked HasRestrictions; registering it from an addon is the forbidden taint case. | IT UI/CollectorHooks.lua:3388-3396,3417-3426,3441; PL:11104-11107; Plater_AnimationEditor.lua:111 |
| CombatLogGetCurrentEventInfo, C_CombatLog.GetCurrentEventInfo | **ABSENT.** Lives in C_CombatLogSecure (SecureOnly) and C_CombatLogInternal; not in the public docs. | Same |
| COMBAT_LOG_MESSAGE | Exists; Blizzard_CombatLog listens to it. Addon use UNKNOWN. **Do not use.** | Same |
| UNIT_DIED, ENVIRONMENTAL_DAMAGE, SPELL_* subevents | ABSENT (they were CLEU subevents) | |
| PARTY_KILL (attackerGUID, targetGUID) | CONFIRMED (standalone event; targetGUID can be secret) | RS:975, handler 199-201 |
| UNIT_SPELLCAST_SUCCEEDED (unit, castGUID, spellID) | CONFIRMED (spellID can be secret) | RS:607-608; SF:1382,1395-1397 |
| UNIT_SPELLCAST_START, _STOP, _CHANNEL_* | UNKNOWN | |
| PLAYER_DEAD | CONFIRMED | LP:4383 |
| PLAYER_REGEN_ENABLED, PLAYER_REGEN_DISABLED | LIKELY | IT UI/Options.lua:4292-4299 |
| C_DamageMeter | UNKNOWN. Blizzard's damage meter is present (Blizzard_DamageMeter SavedVariables exist). | WTF SavedVariables |

### A.5 Auras (details in §B.3)

| API | Status | Signature and returns | Evidence |
|---|---|---|---|
| C_UnitAuras.GetBuffDataByIndex(unit, index[, filter]) | CONFIRMED | → AuraData or nil | LP:7809,7841,14255 |
| C_UnitAuras.GetDebuffDataByIndex(unit, index[, filter]) | CONFIRMED | → AuraData or nil | Same |
| C_UnitAuras.GetPlayerAuraBySpellID(spellID) | CONFIRMED | → AuraData or nil | RareScanner Core/Service/POI/RSNpcPOI.lua:107 |
| C_UnitAuras.GetAuraDataByAuraInstanceID(unit, auraInstanceID) | CONFIRMED (Camelot branch) | → AuraData or nil | PLA:681 |
| C_UnitAuras.GetAuraDataBySlot(unit, slot) | CONFIRMED (Camelot branch) | | PLA:686 |
| C_UnitAuras.GetUnitAuras(unit, filter, maxCount, Enum.UnitAuraSortRule…) | CONFIRMED (exact parameter list LIKELY) | → array of AuraData | PLA:2761,2778,2799 |
| C_UnitAuras.IsAuraFilteredOutByInstanceID(unit, auraInstanceID, filter) | CONFIRMED | → bool | PLA:2665-2666,2711-2712 |
| C_UnitAuras.GetAuraDuration(unit, auraInstanceID) | CONFIRMED | Duration object (shape LIKELY Midnight-style) | PLA:4045 |
| C_UnitAuras.GetAuraDispelTypeColor | CONFIRMED | | PLA:3928 |
| C_UnitAuras.GetAuraDataByIndex(unit, index, filter) | LIKELY | | SF:441-442; SFA:136; IT Core/Keep.lua:11241-11243 |
| C_UnitAuras.GetAuraDataBySpellName | UNKNOWN (existence probe only) | | SF:1025 |
| AuraUtil.UnpackAuraData | LIKELY | | RXP functions.lua:48-80; PLA:44 |
| AuraUtil.ForEachAura | UNKNOWN | | |
| UnitAura, UnitBuff, UnitDebuff | **ABSENT** (R1) | | SF:438-451; IT Keep.lua:11251; RXP functions.lua:48 polyfill |
| UNIT_AURA (unit, updateInfo) | LIKELY (registered via pcall RegisterUnitEvent "player") | updateInfo.isFullUpdate, addedAuras, … can all be secret | SF:1379,1444-1452; RS:772,935 |

AuraData fields:
- **CONFIRMED readable when not secret:** spellId, name, expirationTime, duration, auraInstanceID, applications (LP:7811; SF:444; SFA:161-162).
- **icon:** LIKELY.
- **sourceUnit:** treat as **unusable**. Plater hard-codes `sourceIsSelf = false` on Midnight (PLA:668-672).

### A.6 Spells

| API | Status | Signature and returns | Evidence |
|---|---|---|---|
| C_Spell.GetSpellName(spellID) | CONFIRMED | → string or nil | RareScanner Core/Libs/RSTooltipScanners.lua:322 |
| C_Spell.GetSpellInfo(spellID) | LIKELY | → table {name, iconID, castTime, …} | RXP RXPGuides.lua:37-47,331-336; SF:379-381; RSTooltipScanners.lua:324 |
| C_Spell.GetSpellTexture(spellID) | LIKELY | | SF:337 |
| C_Spell.GetSpellCooldown(spellID) | LIKELY | → {startTime, duration, isEnabled, modRate or isActive}; can be secret | SF:1590-1611; RXP RXPGuides.lua:52-66 |
| C_Spell.IsSpellUsable, C_Spell.GetSpellPowerCost | LIKELY | | SF:1590-1605,621 |
| IsPlayerSpell(spellID) | **CONFIRMED (tested in game)** | → bool | LP:6969; ITP Core/Craft.lua:765-770 |
| C_SpellBook.IsSpellKnown(spellID) | **CONFIRMED (tested in game)** | → bool | ITP Craft.lua:765-770 |
| IsSpellKnown(spellID[, isPet]) | LIKELY | → bool | RXP RXPGuides.lua:73,316; ITP Craft.lua:810 |
| C_Spell.IsSpellKnown | UNKNOWN | | RXP fallback chain |
| GetSpellInfo (global) | **ABSENT** (R1) | | PL:56; SF:331,373-377; IT UI/Client.lua:226 (all guarded) |
| GetSpellCooldown (global) | UNKNOWN | | RXP shim |

### A.7 Talents

| API or event | Status | Notes and evidence |
|---|---|---|
| IsPlayerSpell(talentSpellID) | CONFIRMED | **Primary talent check** (SF:386-394). Forever has per-spec talent rows with Forever spell IDs (SF:96,119,188,204; for example talent 415405). |
| C_ClassTalents.GetActiveConfigID() | LIKELY | IT Core/Gear.lua:2846-2857,2919-3085 |
| C_Traits.GetConfigInfo(configID).treeIDs | LIKELY | Same |
| C_Traits.GetTreeNodes(treeID) | LIKELY | Same |
| C_Traits.GetNodeInfo(configID, nodeID) → .entryIDs, .ranksPurchased, .activeRank | LIKELY | Same |
| C_Traits.GetEntryInfo(configID, entryID).definitionID | LIKELY | Same |
| C_Traits.GetDefinitionInfo(definitionID).spellID | LIKELY | Same |
| C_SpecializationInfo.GetTalentInfo({specializationIndex=, talentIndex=}) → spellID, rank | LIKELY | Same |
| C_SpecializationInfo.GetActiveSpecGroup, GetCombatConfigIDForSpecGroup, GetSpecialization, GetSpecializationInfo | LIKELY | Gear.lua; LP:14360-14400 |
| C_ClassTalents.GetConfigIDsBySpecID, ImportLoadout, DeleteConfig | LIKELY | **Never call ImportLoadout or DeleteConfig.** |
| PLAYER_TALENT_UPDATE, TRAIT_CONFIG_UPDATED, ACTIVE_TALENT_GROUP_CHANGED, CHARACTER_POINTS_CHANGED | LIKELY | Gear.lua:2868-2872; SF:1367-1377,1520 (pcall) |
| GetTalentInfo(tab, i), GetNumTalentTabs, GetTalentTabInfo | **ABSENT** (R1) | RXP disables its talent features on Forever (RXP Guides/Talents/classic-druid.lua:2; ItemUpgrades.lua:6) |

Read talents out of combat only, because the values can be secret.

### A.8 Encounters and instances

| API or event | Status | Signature and payload | Evidence |
|---|---|---|---|
| ENCOUNTER_START | CONFIRMED | (encounterID, encounterName, difficultyID[, groupSize]). The first three are CONFIRMED; groupSize is LIKELY (retail order). | PL:4989-4990,2513-2516; DF loadconditions.lua:148 |
| ENCOUNTER_END | CONFIRMED | (encounterID, encounterName, difficultyID, groupSize, success). The first three are CONFIRMED; groupSize and success are LIKELY (retail: success is 1 or 0). | Same |
| BOSS_KILL | LIKELY | (encounterID, encounterName) | LP:2842-2845 (unregistered from BossBanner) |
| ENCOUNTER_LOOT_RECEIVED | LIKELY (exists) | | LP:2842-2845 |
| GetInstanceInfo() | CONFIRMED | → name, instanceType, difficultyID, difficultyName, maxPlayers, dynamicDifficulty, isDynamic, **instanceID (8th)**, … | FDJ Systems/ScarletWing.lua:76,248; FDJ Journal.lua:857 |
| GetSavedInstanceInfo, GetNumSavedInstances, RequestRaidInfo, UPDATE_INSTANCE_INFO | UNKNOWN | | Needed for lockouts. Feature-detect. |

Whether encounter payloads are secret during an encounter is UNKNOWN. Check every argument.

### A.9 Group and raid

| API or event | Status | Signature | Evidence |
|---|---|---|---|
| IsInRaid([category]), IsInGroup([category]) | CONFIRMED | LE_PARTY_CATEGORY_HOME and LE_PARTY_CATEGORY_INSTANCE are CONFIRMED | OM Map/Pins.lua:174-175; OM Nav.lua:408-410; LP:13989,14235-14239 |
| GetNumGroupMembers(), GetNumSubgroupMembers() | CONFIRMED | | LP:13990-13993,12794; RXP Communications.lua:29,219 |
| GetRaidRosterInfo(i) | CONFIRMED (exists) | Returns LIKELY in retail order: name, rank, subgroup, level, class, fileName, zone, online, isDead, role, isML, combatRole | LP:14009-14012 |
| UnitInRaid(unit) | CONFIRMED | | LP:139; PLC:438; RXP RXPGuides.lua:1979 |
| UnitIsGroupLeader, UnitIsGroupAssistant | CONFIRMED | | LP:1184,14006; PLC:414 |
| IsEveryoneAssistant | UNKNOWN | | |
| C_PartyInfo.InviteUnit(name), C_PartyInfo.UninviteUnit(name) | CONFIRMED | | LP:1199,13995 |
| GROUP_ROSTER_UPDATE | UNKNOWN (retail-standard) | | Register via SafeRegister and fall back to polling. |

Roster names may be secret during encounters (UNKNOWN; the restriction system makes it possible).

### A.10 Loot and rolls

| API or event | Status | Signature | Evidence |
|---|---|---|---|
| LOOT_OPENED | CONFIRMED | (autoLoot, isFromItem) | RS:952; IT Core/Ledger.lua:1189 |
| LOOT_READY, LootSlot(slot) | CONFIRMED | | LP:2781-2791; RXP InventoryManager.lua:104 |
| LOOT_CLOSED | UNKNOWN | | |
| GetNumLootItems(), LootSlotHasItem(slot), GetLootSlotLink(slot) | CONFIRMED | | RS:266,281,288,289 |
| GetLootSlotInfo(slot) | LIKELY | Forever branch: name is 2nd, quantity 3rd, isCoin 10th | IT Ledger.lua:1140-1142,1189-1205 |
| GetLootSlotType(slot) | LIKELY | Compare against Enum.LootSlotType.Money (2) | Same |
| GetLootSourceInfo(slot) | CONFIRMED | → guid1, qty1, guid2, qty2, …; values can be secret | RS; IT Ledger.lua:1100-1113; IT CollectorHooks.lua:1344 |
| Master loot: GetLootMethod, C_PartyInfo.GetLootMethod, GetMasterLootCandidate, GiveMasterLoot, PARTY_LOOT_METHOD_CHANGED, OPEN_MASTER_LOOT_LIST | UNKNOWN; feature LIKELY (R7) | | Forever uses the Mainline LootFrame and GroupLootFrame (IT UI/Keybind.lua:239-245,256-262) |
| START_LOOT_ROLL, GetLootRollItemLink(rollID), GetLootRollItemInfo(rollID) | LIKELY | | FDJ Systems/ItemIdLearner.lua:277-279,308-309; AUC Source/Tooltips/Hooks.lua:153-156 |
| CONFIRM_LOOT_ROLL, CONFIRM_DISENCHANT_ROLL, ConfirmLootRoll, LOOT_BIND_CONFIRM | LIKELY (option-gated) | | LP:1467-1499 |
| RollOnLoot | UNKNOWN | | |
| CHAT_MSG_LOOT | CONFIRMED | (text, …). Text can be secret: there is no NeverSecret mark (ChatInfoDocumentation.lua:1820). | DF loadconditions.lua:152; IT CollectorHooks.lua:3673,3703 |
| LOOT_ITEM_SELF* global strings | CONFIRMED (used as prefixes) | | IT CollectorHooks.lua:209-216 |
| CHAT_MSG_SYSTEM | LIKELY | | RXP functions.lua:147; LP:8146 |
| RANDOM_ROLL_RESULT (global string), RandomRoll | UNKNOWN | | No addon parses rolls. |
| C_Item.RequestLoadItemDataByID(itemID) + ITEM_DATA_LOAD_RESULT | LIKELY | | IT UI/Client.lua:533-541. ContinueOnItemLoad callbacks are dropped when a load fails. |
| C_TooltipInfo.GetItemByID(itemID) | CONFIRMED | | LP:3034 |

### A.11 Guild

| API or event | Status | Signature | Evidence |
|---|---|---|---|
| IsInGuild() | CONFIRMED | | OM Pins.lua:177; RXP Communications.lua:35; SC:140; PLC:900 |
| GetGuildInfo(unit) | CONFIRMED | → guildName, rankName, rankIndex, guildRealm (guildRealm can be secret) | LP:10249-10251; BB owners.lua:70; PL:1402,4143 |
| GetNumGuildMembers() | CONFIRMED | → total, online, onlineAndMobile (order LIKELY) | LP:531-533 |
| GetGuildRosterInfo(i) | CONFIRMED (fields 1, 9, 14, 17) / LIKELY (the rest) | 1 name ("Name-…"; LP strips after "-"), 2 rankName, 3 rankIndex, 4 level, 5 class display name, 6 zone, 7 public note, 8 officer note, 9 isOnline, 10 status, 11 class file, 12 achievement points, 13 achievement rank, 14 isMobile, 15 canSoR, 16 reputation standing, **17 guid** | LP:529-533 |
| GUILD_ROSTER_UPDATE | CONFIRMED | | SC:25; BB caching.lua:34; BB owners.lua:65 |
| C_GuildInfo.GuildRoster(), GuildRoster() | UNKNOWN | | No addon calls either. LP:529 says "new members may need to press J to refresh roster". |
| C_Club.GetSubscribedClubs, Enum.ClubType.Character, CommunitiesUtil.GetMemberIdsSortedByName, CommunitiesUtil.GetMemberInfo | CONFIRMED | | LP:546-549 |
| C_Club.GetGuildClubId | UNKNOWN | | |
| CHAT_MSG_GUILD, CHAT_MSG_OFFICER | LIKELY | | FDJ ItemIdLearner.lua:258-260; CF Model.lua:209 |
| CanEditOfficerNote, C_GuildInfo.CanEditOfficerNote, CanViewOfficerNote, C_GuildInfo.IsGuildOfficer, GuildRosterSetPublicNote, GuildRosterSetOfficerNote, GetGuildRosterLastOnline, GetGuildRosterMOTD, GUILD_MOTD, GetGuildRosterShowOffline, SetGuildRosterShowOffline | UNKNOWN | | Zero references anywhere. |
| Guild bank APIs | UNKNOWN; feature LIKELY (R8) | | BB core/api/frames.lua:11 (behind GuildBankFrame_LoadUI) |

### A.12 Addon messages (constraints in §D)

| API or event | Status | Signature | Evidence |
|---|---|---|---|
| C_ChatInfo.RegisterAddonMessagePrefix(prefix) | CONFIRMED | Prefix of 16 characters or fewer. Return value ignored. | TT:178; AUC Source/Initialize/Main.lua:13; SC:29; ACE:61,65; FDJ VersionCheck.lua:176-177; OM Pins.lua:683 |
| RegisterAddonMessagePrefix (global) | UNKNOWN | | |
| C_ChatInfo.IsAddonMessagePrefixRegistered | UNKNOWN | | |
| C_ChatInfo.SendAddonMessage(prefix, text, chatType[, target]) | CONFIRMED | Return value UNKNOWN on Forever: an enum (LIKELY) or a boolean | TT:763; SC:164; CTL:245,349-378 |
| SendAddonMessage (global) | UNKNOWN | | |
| C_ChatInfo.SendAddonMessageLogged | CONFIRMED | | CTL:253 |
| CHAT_MSG_ADDON | CONFIRMED | (prefix, text, channel, sender, …); text and sender can be secret | TT:766; SC:122; OM Pins.lua:283-287; ACE:242-244 |
| Enum.SendAddonMessageResult | LIKELY | CTL fallback values: Success=0, AddonMessageThrottle=3, NotInGroup=5, ChannelThrottle=8, GeneralError=9 | CTL:349-378 |

### A.13 Chat

| API | Status | Evidence and notes |
|---|---|---|
| C_ChatInfo.SendChatMessage(msg, chatType[, language, target]) | CONFIRMED | LP:13764,14243-14247; RareScanner RSHyperlinks.lua:169 |
| SendChatMessage (global) | UNKNOWN (fallback only) | RXP Communications.lua:11; CTL:235-243,558 |
| Automatic sends without a hardware event, on GUILD, PARTY or EMOTE | LIKELY | RXP sends these from PLAYER_LEVEL_UP (RXP Communications.lua:26-36,147-149). |
| Automatic sends on RAID, WHISPER or RAID_WARNING | UNKNOWN | Send only from a button click. |
| Automatic sends on SAY, YELL or CHANNEL | UNKNOWN | Only ever from a hardware event. |
| Sending RAID_WARNING | UNKNOWN | |
| RaidNotice_AddMessage(RaidWarningFrame, msg, ChatTypeInfo["RAID_WARNING"], seconds) | CONFIRMED (local display) | RareScanner RareScanner.lua:515 |
| CHAT_MSG_RAID_WARNING | LIKELY | CF Model.lua:212 |
| ChatFrameUtil.AddMessageEventFilter(event, fn), ChatFrameUtil.RemoveMessageEventFilter | CONFIRMED | `fn(self, event, msg, sender, …)`; return true to hide the line (LP:8087,8125-8148). Check every argument for secrecy first (CF Native.lua:375-385). |
| ChatFrame_AddMessageEventFilter (global) | UNKNOWN | CF Native.lua:403 |
| ChatFrameUtil.ChooseBoxForSend, ChatFrameUtil.ActivateChat | CONFIRMED | LP:215-216 |
| ChatFrameUtil.InsertLink | LIKELY | AUC Source/Shopping/Hooks.lua:51-52 |
| C_ChatInfo.IsChatLineCensored | LIKELY | CF Native.lua:319-320 |
| CHAT_FRAMES | LIKELY (includes runtime whisper windows) | CF Native.lua:425-426 |

Received chat lines and links can be secret inside instances (IT UI/Keybind.lua:404; IT UI/Tooltip.lua:81 "SecretInChatMessagingLockdown"). Leatrix locks its "Filter chat messages" option on Forever because of a game bug (LP:11837-11839).

### A.14 Encoding and serialization

| API or library | Status | Evidence | Use |
|---|---|---|---|
| C_EncodingUtil.CompressString(s, Enum.CompressionMethod.Deflate[, Enum.CompressionLevel.OptimizeForSize]) | LIKELY | AU Compat.lua:163-180; IT Core/Share.lua:907-931,1591-1606; PLC:181-193 | Only after a successful round-trip self-test. |
| C_EncodingUtil.DecompressString(s[, method]) | LIKELY | PLC:73 calls it with no method argument | Same. |
| C_EncodingUtil.EncodeBase64, DecodeBase64 | LIKELY | Same | Same. |
| C_EncodingUtil.SerializeCBOR, DeserializeCBOR | LIKELY | AUC Source/Variables/Main.lua:113-118,135-136,154-155,190-191; PLC:182 | Self-test first. |
| SerializeJSON, DeserializeJSON | UNKNOWN | | |
| LibDeflate 1.0.2 (CompressDeflate, EncodeForWoWAddonChannel) | CONFIRMED working on Forever | RXP libs/LibDeflate/LibDeflate.lua:95; PL libs/LibDeflate/LibDeflate.lua:92; PLC:192 | **Embed as the fallback.** |
| AceSerializer-3.0, AceComm-3.0 v14 r1333, ChatThrottleLib v32 | CONFIRMED running on the Forever path | RXP embeds_Mainline.xml:12,13,23; RXP RXPGuides.lua:202-203,1567; PLC:106-111 | **Embed these.** |

### A.15 Money, death, PvP, misc

| API or event | Status | Evidence |
|---|---|---|
| GetMoney(), PLAYER_MONEY, GetMoneyString(copper) | CONFIRMED | AUC Source_ModernAH (Commodity Mixins/Main.lua:209; ComposeAuctionPostedMessage.lua:12); BB caching.lua:30 |
| C_CurrencyInfo.GetCoinTextureString, C_CurrencyInfo.GetCoinText | CONFIRMED | LP:7968,3727 |
| GetCoinTextureString (global) | Present but "answered nothing on the beta". Treat as ABSENT and use the C_ version or your own formatter. | IT UI/InfoPanel.lua:146-150 |
| C_CurrencyInfo.GetCurrencyInfo | LIKELY | IT Core/Sources.lua:1296-1307 |
| C_DeathInfo.GetSelfResurrectOptions | CONFIRMED | LP:8511 |
| GetPVPLifetimeStats, UnitHonor, GetHonor*, GetPVPRankInfo, UnitPVPRank | UNKNOWN | |
| C_PvP.GetZonePVPInfo | LIKELY | PL:2546 |

### A.16 Professions (full recipe in §C)

| API or event | Status | Signature | Evidence |
|---|---|---|---|
| GetProfessions() | CONFIRMED | → prof1, prof2, firstAid, fishing, cooking (any slot can be nil; read every return with `select("#")`) | RareScanner Core/Data/RSProfessionDB.lua:23; IT DisenchantValue.lua:300-305 |
| GetProfessionInfo(index) | CONFIRMED (1–7) | → name, texture, rank, maxRank, numSpells, spellOffset, **skillLine (7th)**; 8–10 LIKELY (retail: modifier, specializationIndex, specializationOffset) | RSProfessionDB.lua:15; IT DisenchantValue.lua:300-327; IT Keep.lua:9813-9838 |
| GetNumSkillLines, GetSkillLineInfo (global) | **ABSENT** (they read empty; R1) | | IT PlayerSkills.lua:203-248 |
| C_SpellBook.GetNumSkillLines, C_SpellBook.GetSkillLineInfo | UNKNOWN | | IT PlayerSkills.lua:208-215 |
| C_SkillInfo.GetNumSkillLines, C_SkillInfo.GetSkillLineInfo | LIKELY | May return a table {name, rank, maxRank} | RXP RXPGuides.lua:402-434 |
| C_TradeSkillUI.GetAllProfessionTradeSkillLines() | LIKELY | → array of skillLineIDs | IT PlayerSkills.lua:276-304 |
| C_TradeSkillUI.GetTradeSkillLineInfoByID(line) | LIKELY | Table (.skillLevel or .rank, .maxSkillLevel or .maxRank), or [SUPP] retail multi-return name, rank, maxRank, modifier, parentSkillLineID. Handle both. | Same |
| C_TradeSkillUI.GetBaseProfessionInfo(), GetChildProfessionInfo() | CONFIRMED | → {professionID, parentProfessionID, skillLevel, …}. Describes the line whose data the client currently holds. | RXP Guides/Forever/RestedXP-Skyborne.lua:1809; ITP Craft.lua:837-891,950-959 |
| C_TradeSkillUI.IsTradeSkillReady() | CONFIRMED | → bool | Skyborne.lua:1809 |
| C_TradeSkillUI.OpenTradeSkill(skillLineID) | CONFIRMED | Shows UI | Skyborne.lua:1808-1809; ITP Craft.lua:1284-1290 |
| C_TradeSkillUI.GetCraftableCount(recipeID) | CONFIRMED | → number | Skyborne.lua:1809 |
| C_TradeSkillUI.CraftRecipe(recipeID, count) | CONFIRMED | Needs the window open; calling it from an event gives ADDON_ACTION_BLOCKED | Skyborne.lua:1378,1808; ITP Craft.lua:50-52,1039-1043 |
| C_TradeSkillUI.GetRecipeInfo(recipeID) | CONFIRMED (exists) | → .learned, .relativeDifficulty (0 Optimal, 1 Medium, 2 Easy, 3 Trivial), .numSkillUps, .name, .recipeID. `.learned` is stale unless the window is open on that line. | ITP Craft.lua:16-24,239-241; ITP UI/Queue.lua:1226-1241 |
| C_TradeSkillUI.GetRecipeRequirements(recipeID) | LIKELY | → { {name, met, type} }; type 0 SpellFocus, 1 Totem, 2 Area | ITP Craft.lua:1163-1170,1226-1262 |
| C_TradeSkillUI.GetRecipeSchematic(recipeID, isRecraft[, recipeLevel]) | LIKELY | → .reagentSlotSchematics[i] {reagentType, reagents[1].itemID, quantityRequired, dataSlotIndex}, .quantityMin | AUC Source_Mainline/CraftingInfo/Professions.lua:24,60-70 |
| C_TradeSkillUI.GetRecipeOutputItemData(recipeID, reagents, allocGUID, qualityID) | LIKELY | → {hyperlink}; hyperlink is nil for enchants | Same, :35-50 |
| C_TradeSkillUI.GetRecipesTracked(bool), GetRemainingRecasts(), StopRecipeRepeat() | LIKELY | StopTradeSkillRepeat is not in the binary | ITP Craft.lua:1061-1083 |
| C_TradeSkillUI.GetAllRecipeIDs, GetFilteredRecipeIDs, GetCategories, GetProfessionInfoBySkillLineID, GetRecipeCooldown | UNKNOWN | | Zero call sites |
| Legacy GetNumTradeSkills, GetTradeSkillInfo, GetTradeSkillRecipeLink, DoTradeSkill | LIKELY absent or unused (UNKNOWN) | | Do not use. |
| Craft API: GetNumCrafts, GetCraftInfo, GetCraftItemLink, CRAFT_SHOW, CRAFT_UPDATE | UNKNOWN; treat as ABSENT | Enchanting is an ordinary tradeskill line (333) | |
| `\|Htrade:` links, GetTradeSkillListLink, IsTradeSkillLinked, IsTradeSkillGuild | UNKNOWN | | Zero matches. Do not rely on them. |
| Events: TRADE_SKILL_SHOW, TRADE_SKILL_CLOSE, TRADE_SKILL_DATA_SOURCE_CHANGED, TRADE_SKILL_LIST_UPDATE, TRADE_SKILL_ITEM_CRAFTED_RESULT, TRADE_SKILL_CRAFT_BEGIN, UPDATE_TRADESKILL_CAST_STOPPED, NEW_RECIPE_LEARNED | LIKELY | | ITP Craft.lua:56-57,567-578; ITP Queue.lua:4206-4217 |
| Events: SKILL_LINES_CHANGED, LEARNED_SPELL_IN_TAB, CHAT_MSG_SKILL (payload not NeverSecret), PLAYER_ENTERING_WORLD | LIKELY / CONFIRMED (PLAYER_ENTERING_WORLD) | | IT UI/Frame.lua:450; ITP Core/Professions.lua:1086; ITP Queue.lua:4051-4058 |

---

## B. Combat log and auras

### B.1 Rules

1. Never register `COMBAT_LOG_EVENT_UNFILTERED`. Never call `CombatLogGetCurrentEventInfo`, `C_CombatLog*` or `C_CombatLogSecure*`, and never parse `COMBAT_LOG_MESSAGE`.
   - The old "spellId 0 in CLEU" problem and its workarounds (a name → ID map, `select(7, GetSpellInfo(name))`) are moot. Do not port them.
2. Greenfields ships no damage or healing meter. Blizzard_DamageMeter exists, but its API is UNKNOWN.
3. Every payload below is checked with `IsSecret` before it is compared or stored.

### B.2 Replacement event map

| Need | Use | Payload | Secret risk | Notes |
|---|---|---|---|---|
| Boss pull | ENCOUNTER_START | encounterID, encounterName, difficultyID, groupSize | UNKNOWN | Learn encounterID → name at runtime (§F.1) and look the name up in the alias table. |
| Boss kill or wipe | ENCOUNTER_END | …, success (retail: 1 = kill) | UNKNOWN | Primary kill signal. Store `success == 1` only if the value is not secret. |
| Kill (second source) | BOSS_KILL (LIKELY) | encounterID, encounterName | UNKNOWN | Deduplicate against ENCOUNTER_END by encounterID within 10 s. |
| Mob, rare or boss NPC kill | PARTY_KILL | attackerGUID, targetGUID | targetGUID can be secret | npcID = `C_CreatureInfo.GetCreatureID(targetGUID)`, only when the GUID is not secret. |
| Who cast what | UNIT_SPELLCAST_SUCCEEDED | unit, castGUID, spellID | spellID can be secret | Register for "player" via RegisterUnitEvent. Group units are UNKNOWN: prefer self-reports over comms. |
| Own death | PLAYER_DEAD | | | |
| Other players' deaths | Poll `UnitIsDeadOrGhost(unit)` out of encounters | | Roster may be secret in an encounter | No UNIT_DIED exists. |
| Combat edges | PLAYER_REGEN_DISABLED / PLAYER_REGEN_ENABLED | | | On ENABLED, do every deferred re-read: auras, roster, talents, comms flush. |
| Loot | LOOT_READY, LOOT_OPENED, CHAT_MSG_LOOT | | CHAT_MSG_LOOT text can be secret | See §D.6 for loot self-reporting. |

### B.3 Aura read pattern

```lua
-- Snapshot one unit's buffs; returns false (keep last snapshot, mark stale) if auras are secret.
local function ScanBuffs(unit, out)
  if AurasSecret() then return false end
  local get = C_UnitAuras and C_UnitAuras.GetBuffDataByIndex
  if not get then return false end
  for i = 1, 40 do
    local ok, a = pcall(get, unit, i, "HELPFUL")
    if not ok or type(a) ~= "table" then break end
    local id, name = Clean(a.spellId), Clean(a.name)
    if id or name then
      out[#out + 1] = { id = id, name = name, exp = Clean(a.expirationTime),
                        dur = Clean(a.duration), iid = Clean(a.auraInstanceID),
                        stacks = Clean(a.applications) }
    end
  end
  return true
end
-- Fast single check on self:
local function PlayerHas(spellID)
  if AurasSecret() then return nil end           -- nil = unknown
  local ok, a = Try(C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID, spellID)
  if not ok then return nil end
  return a ~= nil
end
```

**Auras are hidden in combat.** Forever hides the player's buffs from addons in combat (SFA:3, tested in game 16 Oct 2026). Outside combat they are readable (SF:398). The UI must show a "stale (in combat)" state rather than "missing".

**UNIT_AURA:**
- Register it with `SafeRegister(f, "UNIT_AURA", "player")`.
- Use it only as a dirty flag. Never parse updateInfo; `isFullUpdate` and `addedAuras` can be secret.
- Debounce a rescan by 0.5 s, and skip the rescan while `AurasSecret()`.
- For the whole group, rescan on demand (ready check, button, or when opening the panel) plus at most every 10 s out of combat. Spread the work so no frame scans more than 10 units.

**Matching:**
- Build `nameSet[category]` at PLAYER_LOGIN with `C_Spell.GetSpellName(id)` for every ID in §F.2. One name covers all ranks.
- Match an aura by `spellId` first, then by `name`.
- Never compute expiry from a base duration: the Legacy perk "Permanence" adds 50% per rank (2 ranks), so it varies by caster. Use `expirationTime`.

**Attribution:** `sourceUnit` is unusable, so "who buffed whom" comes only from self-reports. Each Greenfields client reports its own player's buff casts (UNIT_SPELLCAST_SUCCEEDED on "player", out of combat) over comms.

**Unit tokens:** comparing them (UnitIsUnit and similar) is allowed only when `C_Secrets.CanCompareUnitTokens()` returns true.

### B.4 Camp buff detection

Camp buffs belong to the player's own client:

1. Check whether "Camp Benefits" is present: `PlayerHas(1229741)`, or a name match (R9).
2. Check the components: `PlayerHas(id)` for each hidden aura in §F.4. These are tooltip conditional IDs; whether the client exposes them as auras is UNKNOWN.
3. If the components are not readable, report "Camp Benefits (components unknown)".
4. Also track:
   - 1289723 "Welcoming Campfire" (a 1-minute countdown that converts into Camp Benefits)
   - 1283391 "Campfire Nearby"
   - 1229451 "Boosted Rest"
5. Other raid members' camp state comes from **comms self-reports** (the hidden auras may not appear in index scans of other units).

### B.5 Talent reads

- **Primary:** `IsPlayerSpell(talentSpellID)` on a shipped list.
- **Full export:** out of combat only, walk the C_Traits tree under pcall:
  `C_ClassTalents.GetActiveConfigID → C_Traits.GetConfigInfo.treeIDs → GetTreeNodes → GetNodeInfo (activeRank, entryIDs) → GetEntryInfo.definitionID → GetDefinitionInfo.spellID`
  - Fallback: `C_SpecializationInfo.GetTalentInfo({specializationIndex, talentIndex})`.
- **Refresh events:** PLAYER_TALENT_UPDATE, TRAIT_CONFIG_UPDATED, ACTIVE_TALENT_GROUP_CHANGED, CHARACTER_POINTS_CHANGED (each via SafeRegister).

---

## C. Trade skill scanning

**Summary:** read skill levels with GetProfessions/GetProfessionInfo. Read known recipes with `IsPlayerSpell` against a shipped recipe list; this needs no window. C_TradeSkillUI is read opportunistically, and only while the window is open.

1. **When to scan.**
   - First scan 2–5 s after the first PLAYER_ENTERING_WORLD, out of combat.
   - Re-scan, debounced to 2 s and out of combat, on: SKILL_LINES_CHANGED, LEARNED_SPELL_IN_TAB, CHAT_MSG_SKILL (do not parse its payload; it may be secret), NEW_RECIPE_LEARNED, and PLAYER_ENTERING_WORLD.
   - **Never cache an empty answer.** At login the client can answer before its data is ready (IT UI/Frame.lua:4794-4799). If a scan returns zero professions, retry at 5, 15 and 60 s.
2. **Ranks.**
   ```lua
   local slots = { GetProfessions() }                       -- read ALL returns: n = select("#", GetProfessions())
   for i = 1, select("#", GetProfessions()) do
     local idx = slots[i]
     if idx then
       local ok, name, tex, rank, maxRank, nSpells, off, skillLine = pcall(GetProfessionInfo, idx)
       if ok and skillLine then prof[PARENT[skillLine] or skillLine] = { rank = rank, max = maxRank, name = name } end
     end
   end
   ```
   - Key professions by skillLine (R19). Map child lines to their parent; the parent comes from `GetChildProfessionInfo().parentProfessionID` when the window is open, or from your shipped child → parent map.
3. **Lines GetProfessions may not cover** (Poisons 40, Lockpicking 633, Survival 142):
   - First, under pcall: `C_TradeSkillUI.GetAllProfessionTradeSkillLines()` → `GetTradeSkillLineInfoByID(line)`. Handle a table or multiple returns.
   - Then `C_SkillInfo.GetNumSkillLines` / `GetSkillLineInfo` if present (may return a table).
   - Never use the global GetNumSkillLines.
4. **Known recipes** (no window needed). Ship `RecipeDB[skillLine] = { recipeSpellID, … }`, covering all 12 profession lines including the gathering lines (Herbalism, Mining, Skinning and Fishing now have crafts) and 40 Poisons.
   For each ID, the first definite answer wins (from ITP Craft.lua:777-814):
   1. `IsPlayerSpell(id)` returns true → known.
   2. `C_SpellBook.IsSpellKnown(id)` returns true → known.
   3. If the profession window is open and showing this line (`IsTradeSkillReady()`, and `GetBaseProfessionInfo()` or `GetChildProfessionInfo()` professionID or parentProfessionID matches), `GetRecipeInfo(id).learned` decides it, false included.
   4. A "not known" answer from step 3, remembered for this session.
   5. `IsSpellKnown(id)` returns true → known. Its false is not trusted.
   6. Otherwise: not known (store as false; do not treat it as an error).

   Time-slice the scan at about 200 IDs per `C_Timer.After(0)` tick. Store the results as a bitset per skillLine, indexed by position in the shipped list.
   - Proven in game on 1.60.1.70124 with every window shut: 2152 and 2160 returned true, 3756 returned false (ITP Craft.lua:765-768).
   - Recipe IDs are spell IDs, for example 8604 Herb Baked Egg, 3275 Linen Bandage, 2538 Charred Wolf Meat.
5. **Opportunistic harvest** (finds recipes your DB is missing). On TRADE_SKILL_SHOW, TRADE_SKILL_LIST_UPDATE or TRADE_SKILL_DATA_SOURCE_CHANGED, once `IsTradeSkillReady()` is true:
   - Read `GetBaseProfessionInfo()` and `GetChildProfessionInfo()`.
   - Probe `C_TradeSkillUI.GetAllRecipeIDs` under pcall (UNKNOWN). If it returns IDs, read `GetRecipeInfo(id)` for each and record new IDs with `.learned`.
   - **Never call OpenTradeSkill automatically** (it shows UI) and never chain CraftRecipe from events (ADDON_ACTION_BLOCKED).
6. **Specializations:** check with `IsPlayerSpell`.

   | Profession | Spell IDs |
   |---|---|
   | Blacksmithing | 9788 [SUPP Armorsmith], 9787 [SUPP Weaponsmith], 17039, 17040, 17041 [SUPP Master Sword/Hammer/Axesmith] |
   | Leatherworking | 10656 [SUPP Dragonscale], 10658 [SUPP Elemental], 10660 [SUPP Tribal] |
   | Engineering | 20219 [SUPP Gnomish], 20222 [SUPP Goblin] |

   Source: IT Core/Skills.lua:26-46; IT PlayerSkills.lua:156-167.
7. **Cooldowns.**
   - Call `pcall(C_Spell.GetSpellCooldown, spellID)`. Remaining time = `startTime + duration - GetTime()` when no field is secret and `duration > 0`.
   - Store the absolute end time as `GetServerTime() + remaining`.
   - Transmutes share a category cooldown, so probe one representative spell per category.
   - Whether the API reports tradeskill category cooldowns is UNKNOWN. Fall back to recording the cast time from UNIT_SPELLCAST_SUCCEEDED on "player" plus the §F.7 table.
   - GetTradeSkillCooldown and C_TradeSkillUI.GetRecipeCooldown are UNKNOWN; do not use them.
8. **Sharing:** no tradeskill links exist. Send `{skillLine, rank, maxRank, dbVersion, bitset}` over comms (§D), with the bitset encoded through the §D.5 pipeline.
9. **Do not copy third-party data.** Do not ship ItemTree_Data files verbatim (licence unknown). Build the recipe DB from your own harvest (step 5) or from a datamine you are licensed to use. Version the DB and send its hash in the hello message.

**Skill lines**

| Group | Lines |
|---|---|
| Primary professions | 164 Blacksmithing, 165 Leatherworking, 171 Alchemy, 182 Herbalism, 186 Mining, 197 Tailoring, 202 Engineering, 333 Enchanting, 393 Skinning |
| Secondary professions | 129 First Aid, 185 Cooking, 356 Fishing |
| Class tradeskills | 40 Poisons (Rogue), 633 Lockpicking (Rogue), 3012 Comprehension (Mage; its one recipe is 1302508 "Study": 17056 Light Feather → 277651 Bundle of Scrolls) |
| Uncertain | 142 Survival |
| Child lines | 2937–2948 (for example 2940 → 333), and 2988 → 40. Match professionID **or** parentProfessionID. |

There is no Jewelcrafting or Inscription.

---

## D. Comms constraints

### D.1 Transport

- **Library stack:** embed AceComm-3.0 (v14 r1333) and ChatThrottleLib v32. Both are proven on Forever: CTL hooks `C_ChatInfo.SendAddonMessage` and `SendAddonMessageLogged` unguarded.
- **Prefix:** 16 characters or fewer. Use `"Greenfields"` (11). Register it at PLAYER_LOGIN with `pcall(C_ChatInfo.RegisterAddonMessagePrefix, "Greenfields")`.
- **Message size:** 255 bytes or fewer per raw message. Bytes past 255 are silently truncated (ACE:95; CTL:636-637). AceComm splits larger payloads using control bytes \001–\004 (ACE:41-44). If you truncate yourself, never cut a UTF-8 character in half (OM Pins.lua:146,167).
- **Channels with evidence:** GUILD, PARTY, RAID, INSTANCE_CHAT and WHISPER (FDJ VersionCheck.lua:84-98; OM Pins.lua:172-183; SC:148-151).
  - Use INSTANCE_CHAT when `IsInGroup(LE_PARTY_CATEGORY_INSTANCE)`.
  - OFFICER as an addon channel is UNKNOWN: detect it at runtime from the send result.
  - **Never use CHANNEL** (R6).
- **Receiving:** `CHAT_MSG_ADDON(prefix, text, channel, sender, …)`.
  - Drop the message if `IsSecret(text)` or `IsSecret(sender)`.
  - Normalise the sender with `Ambiguate(sender, "none")`.
  - Your own GUILD and group messages echo back to you; ignore your own echoes except in the delivery probe.

### D.2 Throttling

**CTL v32 defaults:** MAX_CPS 800, MSG_OVERHEAD 40, BURST 4000, MIN_FPS 20. It throttles hard for 5 s after login and after zoning (CTL:60-65,321-324,436-442). On a throttle result it moves the queue to a blocked list and retries every 0.35 s (CTL:396-406,462-469).

**Greenfields application-level limits**, matching what Forever-only addons do:
- At most one message every 0.3 s per channel; "the game holds back a burst" (OM Pins.lua:26,155-162).
- Hello/version broadcasts at most once every 10 s per channel. Replies are delayed by a random 1–5 s (FDJ VersionCheck.lua:15,72-74,111).
- No sends in the first 5 s after PLAYER_ENTERING_WORLD.
- Bulk sync (recipes, roster data) goes out at CTL "BULK" priority. One full recipe sync per member per session, plus deltas.

### D.3 Send gating

```lua
local function CanSend()
  if InCombatLockdown() then return false end
  if RestrictionActive("Chat") or RestrictionActive("Encounter") or RestrictionActive("Combat") then return false end
  local ok, locked = Try(C_ChatInfo.InChatMessagingLockdown)
  if ok and locked == true then return false end
  return true
end
local function SendOK(r)          -- handles enum, boolean or nil
  if r == nil or r == true then return true end        -- nil: legacy/no return => assume queued
  if r == false then return false end
  local E = Enum and Enum.SendAddonMessageResult
  return r == ((E and E.Success) or 0)
end
```

- While `CanSend()` is false, queue outgoing messages. Flush the queue on PLAYER_REGEN_ENABLED, ENCOUNTER_END, or a 5 s poll.
- Treat any non-Success result as a failure. Back off when it is AddonMessageThrottle (3) or ChannelThrottle (8).
- Retail also has 1 InvalidPrefix, 2 InvalidMessage, 4 InvalidChatType, 6 TargetRequired and 7 InvalidChannel [SUPP]. Map names through a reverse lookup of `Enum.SendAddonMessageResult` when it exists.
- **Instances:** WEB reports addon messaging "restricted or queued inside instances", and chat payloads can be secret there. Design every protocol for loss and delay: idempotent messages, version numbers on each record, periodic anti-entropy (hash compare, then delta pull).

### D.4 Delivery probe

Run this once per session and again after each zone change into the open world.

- At PLAYER_LOGIN + 15 s, if `IsInGuild()`, send `PING <nonce>` on GUILD and wait 10 s for your own echo.
  - Echo received: comms status = OK.
  - No echo: status = DEGRADED. Show it in the UI and offer the manual export/import string path (same encoding as §D.5, shown in an edit box).
- Run the same probe on the group channel when you join a group.

### D.5 Payload pipeline

1. **Serialize** with AceSerializer-3.0 (CBOR only after a self-test).
2. **Compress:**
   - C_EncodingUtil.CompressString(…, Deflate), only if the self-test `DecompressString(CompressString(x)) == x` passed at login under pcall.
   - Otherwise LibDeflate:CompressDeflate.
3. **Channel-safe encoding:** `LibDeflate:EncodeForWoWAddonChannel` (PLC:192), or Base64 when C_EncodingUtil passed its self-test.
4. **Split:** AceComm splits the result.

Carry a 1-byte protocol version and the message type in front of the payload.

### D.6 Identity and keys

**Key members by GUID** (roster field 17, or `UnitGUID`), never by "Name-Realm":
- The second name part is a surname.
- Realm strings are unstable.
- The format of the CHAT_MSG_ADDON sender and of roster names on Forever is UNKNOWN.

Rules:
- The hello message carries the sender's `UnitGUID("player")`. Keep a map from `Ambiguate(sender,"none")` to GUID. When no GUID is known, fall back to a name match.
- Store the raw roster name as well as the normalised one.
- **SavedVariables partition:** guild name + ruleset (`C_GameRules`; `RegionalUniqueNamesEnabled` → the realm key becomes the ruleset, as in the AceDB copies at PL AceDB-3.0:263-277 and RXP AceDB-3.0:264-276). Do not use GetRealmName.
- Guilds are single-faction and cross-ruleset grouping is unsupported, so faction need not be part of the key. Do not infer class from faction (Alliance can have Shaman, Horde can have Paladin).
- **Loot and buff truth comes from self-reports:** each client reports its own loot (LOOT_OPENED/LOOT_READY and GetLootSlotLink, out of encounter), its own buffs, camp state and professions. CHAT_MSG_LOOT parsing is a best-effort supplement; skip it when the text is secret.

### D.7 Chat (non-addon) sends

- Use `C_ChatInfo.SendChatMessage`.
- Automatic sends (no hardware event) only on GUILD or PARTY (LIKELY).
- RAID, WHISPER, RAID_WARNING, SAY, YELL and CHANNEL are sent only from a click.
- Check `InChatMessagingLockdown` first. If locked, show "Chat messages are restricted right now." (the same behaviour as LP:13718-13721).
- Roll parsing: CHAT_MSG_SYSTEM, only when `not IsSecret(msg)`. Build the pattern from the `RANDOM_ROLL_RESULT` global string (UNKNOWN; feature-detect it).

---

## E. UI kit

### E.1 Frames and templates

**BackdropTemplate**
- **Required.** Frames have no SetBackdrop unless they inherit `"BackdropTemplate"`.
- Evidence: FDJ Journal.lua:528-529,2490; LP:6315; FDJ Systems/Favourites.lua:529-537 (with SetBackdropColor and SetBackdropBorderColor).
- `BackdropTemplateMixin` is a global (SF Display.lua:4).
- Retrofitting an existing frame is LIKELY: `Mixin(f, BackdropTemplateMixin); f:SetScript("OnSizeChanged", f.OnSizeChanged)` (PLA:527-528).
- Probe `type(f.SetBackdrop) == "function"` before use.

**CONFIRMED templates:**
- UIPanelButtonTemplate
- UICheckButtonTemplate (create your own label; whether `.Text` exists is UNKNOWN)
- InputBoxTemplate
- SearchBoxTemplate
- UIPanelScrollFrameTemplate (scroll bar field: `scroll.ScrollBar or scroll.scrollBar`)
- ScrollFrameTemplate with `scrollBarTemplate="MinimalScrollBar"` (Leatrix_Plus.xml:2-7)
- UIPanelCloseButton

**LIKELY templates:**
- PortraitFrameTemplate: a "grey translucent wash" background on the beta (IT Frame.lua:4879-4881,8769).
- ButtonFrameTemplate, with `ButtonFrameTemplate_HidePortrait` behind a guard.
- NineSlicePanelTemplate with the NineSliceUtil layout "ButtonFrameTemplateNoPortrait", drawn "in bronze" (OM Core.lua:242-251).
- BasicFrameTemplateWithInset: fallback only.
- PanelTopTabButtonTemplate: on Forever the art is flipped to the bottom and the text is offset by Y −7 when selected and −6 when deselected (IT Frame.lua:140-172).

Template chain for the main window: ButtonFrameTemplate → PortraitFrameTemplate → BasicFrameTemplateWithInset, each under pcall.

**CONFIRMED frame methods:** SetResizeBounds, StartSizing, SetToplevel, SetClampedToScreen, SetClipsChildren, SetObeyStepOnDrag (AU UI/Main.lua:600-607,789; AU Chart.lua:233; AU Kit.lua:984).

GetMouseFoci is LIKELY. Do not use GetMouseFocus.

### E.2 Scroll system

All CONFIRMED (RareScanner ExplorerPlugin, Forever-only TOC). Evidence: RSExplorerListTemplate.xml:16,22; RSExplorerMixin.lua:654-661; LP:1943.

```lua
local box = CreateFrame("Frame", nil, parent, "WowScrollBoxList")
local bar = CreateFrame("EventFrame", nil, parent, "MinimalScrollBar")
local view = CreateScrollBoxListLinearView()
view:SetElementInitializer("BackdropTemplate", function(row, data) --[[ build row ]] end) -- SetElementInitializer: LIKELY (retail-standard)
ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
local dp = CreateDataProvider(); box:SetDataProvider(dp)
-- optional: ScrollUtil.AddSelectionBehavior(box), ScrollUtil.AddAcquiredFrameCallback(box, fn, owner)
```

Using "BackdropTemplate" as the row template means no XML is needed (IT UI/Sidebar.lua:94-96,850-900).

### E.3 Dropdowns and menus

**Use (CONFIRMED):**
- `CreateFrame("DropdownButton", nil, p, "WowStyle1DropdownTemplate")` with `dd:SetupMenu(function(owner, root) … end)` (LP:12553-12575; RareScanner RSExplorerMixin.lua:560,567).
- `MenuUtil.CreateRadioMenu`, `MenuUtil.CreateRadio`, `menu:EnumerateElementDescriptions`, `DropdownButtonMixin.Event.OnMenuClose`, `MenuResponse.Refresh`, and `WowStyle1FilterDropdownTemplate`.
- Context menus: `MenuUtil.CreateContextMenu(owner, generator)` (CONFIRMED on the Camelot path: BB sortButton.lua:49; TT:791).
- `root:CreateButton`, `CreateCheckbox` and `CreateRadio` on the description object are LIKELY (retail-standard).

**Do not use:**
- UIDropDownMenu_Initialize or EasyMenu: UNKNOWN, and they taint shared client menus (IT UI/Chain.lua:1988-1990).
- UIDropDownMenuTemplate does exist (via AceGUI), but avoid it.
- **Custom menus must select on mouse-down.** Blizzard_Menu uses OnMouseDown with no OnClick, and menus close on mouse-down before a click callback would fire (IT UI/Map.lua:2920-2928; FDJ Favourites.lua:361-365).

### E.4 Backdrop, textures, fonts

- **Textures:**
  - `Interface\\Buttons\\WHITE8X8`, SetColorTexture, `SetGradient(orient, CreateColor(...), CreateColor(...))`, CreateMaskTexture/AddMaskTexture, SetTextureSliceMargins, CreateLine, SetAtlas, SetHorizTile and SetVertTile are all CONFIRMED.
  - SetGradientAlpha is **ABSENT** (LIKELY).
  - Check `C_Texture.GetAtlasInfo` before using uncommon atlases.
  - Masks: `Interface\\Masks\\CircleMaskScalable`, falling back to `Interface\\CharacterFrame\\TempPortraitAlphaMask`.
  - **Never pass a filter argument to SetTexture or SetAtlas** (R18).
- **Fonts:**
  - `Fonts\\FRIZQT__.TTF` is CONFIRMED. ARIALN.TTF and MORPHEUS.TTF are LIKELY. SKURRI is UNKNOWN.
  - Locale fallbacks: STANDARD_TEXT_FONT for koKR, zhCN and zhTW; `Fonts\\FRIZQT___CYR.TTF` for ruRU.
  - `SetFont` returns a boolean; check it.
  - **Call SetFont before SetText**, otherwise it raises "Font not set" (IT UI/Badges.lua:48).
  - Game fonts lack some glyphs (for example ⚠); use inline textures instead.
- **TGA format**, safe on Forever:
  - Type 2 (uncompressed truecolor), 32 bpp, 8-bit alpha. Descriptor 0x08 (bottom-left origin).
  - **Power-of-two** dimensions.
  - An optional 26-byte TGA 2.0 footer is fine.
  - Header layout: ImageType at byte 2, width and height at bytes 12–15, bpp at byte 16, descriptor at byte 17.
  - Reference files without the extension: `"Interface\\AddOns\\Greenfields\\Media\\icon"`.
  - Custom TGAs work for `## IconTexture`.
  - RLE (type 10) and non-power-of-two files appear on Forever paths but are not verified; avoid them.
  - Typical sizes: 32×32 icons, 64×64 emblems, 8×64 gradients.

### E.5 Settings, compartment, minimap

**Settings** (CONFIRMED):
```lua
local cat = Settings.RegisterCanvasLayoutCategory(canvasFrame, "Greenfields")
Settings.RegisterAddOnCategory(cat)
-- open:
Settings.OpenToCategory(cat:GetID())
```
- Evidence: LP:11415-11416; IT Options.lua:4278-4307.
- **Canvas only.** A vertical layout leaks taint into Blizzard rows, for example "Execution tainted … tooltipFunc" and a blocked IsUserOAuthed (IT Options.lua:1890-1898).
- Build the canvas at PLAYER_LOGIN while it is hidden, never in OnShow.
- Do not open Settings in combat (ShowUIPanel is blocked); queue the call for PLAYER_REGEN_ENABLED.
- InterfaceOptions_AddCategory is UNKNOWN; do not use it.

**Addon compartment** (CONFIRMED):
- TOC fields `## AddonCompartmentFunc`, `## AddonCompartmentFuncOnEnter` and `## AddonCompartmentFuncOnLeave` name global functions.
- Click handler: `(addonName, mouseButton)`. Enter handler: `(addonName, ownerFrame)`; use ownerFrame as the tooltip owner. Leave hides GameTooltip. The argument shape is LIKELY.
- Defer the click work with `C_Timer.After(0, …)` to avoid gamepad taint (IT UI/Slash.lua:2329-2333).
- `AddonCompartmentFrame` exists (`:RegisterAddon`, `.registeredAddons`, `:UpdateDisplay`).

**Minimap:**
- LibDBIcon-1.0 (minor 56) with LibDataBroker-1.1 is CONFIRMED working.
- `GetMinimapShape` is not defined by the client: guard it with a type check and default to "ROUND".
- The radius is `Minimap:GetWidth()/2 + 10`; the Forever minimap is larger than 140 px.
- The default button angle is 225° (LibDBIcon). Avoid 310–320°, where the zoom buttons sit.

### E.6 Other UI facts

- **Animations** (CONFIRMED): Alpha, Translation, Scale, Rotation, Path (CreateControlPoint, SetCurveType) and VertexColor animations. SetLooping "REPEAT"/"BOUNCE", SetSmoothing "IN_OUT", SetStartDelay, OnFinished.
  - FlipBook: LIKELY.
  - UIFrameFadeIn: CONFIRMED. UIFrameFadeOut, UIFrameFlash and ShakeFrame: UNKNOWN; use animation groups instead.
- **Sound:**
  - `PlaySound(SOUNDKIT.X, "SFX")`. Known IDs: IG_MAINMENU_OPTION_CHECKBOX_ON 856, _OFF 857, IG_CHARACTER_INFO_TAB 841, _OPEN 839, _CLOSE 840, IG_MAINMENU_OPTION 852, IG_ABILITY_PAGE_TURN 836.
  - UIPanelButtonTemplate, UIPanelCloseButton and PanelTabButtonTemplate play **no** click sound on Forever, so play your own.
- **Tooltips:**
  - Use `TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit or .Item, fn)` (CONFIRMED). Keep the handler cheap and wrapped in pcall.
  - **Do not HookScript "OnTooltipSetUnit"**; it raises (ABSENT).
  - Call SetOwner before SetHyperlink, and do not set the owner again afterwards (doing so clears the tooltip).
- **Popups:** StaticPopupDialogs and StaticPopup_Show are CONFIRMED, including `hasEditBox`. Access the edit box as `self.editBox or self.EditBox`.
- **UISpecialFrames:** `tinsert(UISpecialFrames, "GreenfieldsMainFrame")` (CONFIRMED). Never call table.remove on it.
- **Slash commands:** `SLASH_GREENFIELDS1 = "/gf"; SlashCmdList.GREENFIELDS = fn`.
  - Inside the handler, defer all work with `C_Timer.After(0, …)` and never call SetFocus. Otherwise the gamepad navigation hits ADDON_ACTION_FORBIDDEN and the client freezes.
- **Strata:** main windows use HIGH plus SetToplevel; overlays use DIALOG. The personal resource bar draws through MEDIUM.
  - SettingsPanel closes every UISpecialFrames window when it closes.
  - Detect it opening through the EventRegistry callbacks "UIParentPanelManager.ShowUIPanel" and "SettingsPanel.OnHide", never by HookScript on the panel.
- **Gamepad SmartNavigation hooks CreateFrame.** Pre-create every frame hidden around PLAYER_LOGIN (or one tick after the first PLAYER_ENTERING_WORLD). Never create frames parented inside an open Blizzard panel.
- **UIPanelCloseButton in combat** calls HideUIPanel, which is blocked. Override its OnClick with `function() frame:Hide() end`, and make no protected calls while opening or closing windows in combat.
- **Creature portraits** draw as a black square until the model loads. Render them off-screen first.
- **Edit Mode:** do not integrate (R17).
- **Strings:** `string.lower` is ASCII-only, so search on the raw UTF-8 string as well.
- **Event order:**
  - ADDON_LOADED: the saved tables are assigned to their globals at this point; tables created at file scope get replaced.
  - PLAYER_LOGIN: build UI and register Settings here.
  - PLAYER_ENTERING_WORLD(isInitialLogin, isReloadingUi): CONFIRMED.
- **TOC:**
  ```
  ## Interface: 16001
  ## Title: Greenfields
  ## SavedVariables: GreenfieldsDB
  ## SavedVariablesPerCharacter: GreenfieldsCharDB      (LIKELY)
  ## IconTexture: Interface\AddOns\Greenfields\Media\icon
  ## AddonCompartmentFunc: Greenfields_OnCompartmentClick
  ## AddonCompartmentFuncOnEnter: Greenfields_OnCompartmentEnter
  ## AddonCompartmentFuncOnLeave: Greenfields_OnCompartmentLeave
  ## Category: Guild                                    (LIKELY honored)
  ```
  - `## LoadSavedVariablesFirst: true` is optional (it appears in 3 addons; LIKELY lets you read SavedVariables at file scope).
  - Bindings.xml is auto-discovered, so do not list it.
  - Per-file `[AllowLoadGameType camelot]` is CONFIRMED.
  - Multi-version `## Interface: 16001, 16002` is UNKNOWN. Plan a TOC bump for 1.60.2.

---

## F. Game data

### F.1 Raids at launch (unlock Dec 9 2026; fixed sizes, one difficulty, no Raid Finder)

| Raid | Size | Location | Bosses (achievement order, **not** a confirmed kill order) |
|---|---|---|---|
| Barrow Deeps | 10 | Mount Hyjal (3 entrances across Azeroth) | 8: Chillhowl (alias **Deepscar Matriarch**, R21), Khalith the Dreadspinner, Amethrax, Ravus and Darlissa, Elder Tangleclaw, Well of Sorrow, Del'lynar Songwood, Sonya Darkhallow (end boss) |
| Hyjal Summit | 20 | Mount Hyjal | 13: Bandalar, Time-Lost Battalion, Old Gloomlurker, Kathris the Haunted, Elder Minderel (alias Minderei), Council of Thorns, The Wild King, Ancient of Decay, Sylvestris Dusksong (alias Sylvesteris), Gharalis the Abyssal, Anara Chillwind, Tracker Stillwind, Nythus the Dreambound (alias Dreadbound; end boss) |
| Onyxia's Lair | 40 | Dustwallow Marsh | 1: Onyxia. Whether the Drakefire Amulet attunement remains is not announced. The loot table shown on sites is Classic Era's, unconfirmed. |

- **IDs:** encounterIDs, instanceIDs and map IDs are **not published**.
  - Learn them at runtime: ENCOUNTER_START gives (encounterID, name); GetInstanceInfo gives instanceID as its 8th return. Persist the map.
  - Match names case-insensitively through the alias table.
  - Blizzard's running text says "the Barrow Deeps"; the wiki uses "Barrow Deeps".
- **Legacy Challenges** (there is no Achievements tab):
  - "Defeat Onyxia", "Defeat all 13 Hyjal Summit bosses" and "Defeat all 8 Barrow Deeps bosses", 1 point each.
  - Wowhead achievement 62035 "Conqueror of the Deeps". Hyjal: "Conqueror of the Wilds" [3P].
- **Not confirmed for Forever:** Molten Core, Blackwing Lair, Zul'Gurub, AQ20, AQ40, Naxxramas.
- **Roadmap:** 2 new raids in spring 2027; then 1 new raid plus 1 revamped iconic raid in summer 2027. The stated direction is a 10-player and a 20-player raid each tier.
- **Lockouts:** not announced. Do not hard-code 7- or 5-day resets. Read them at runtime (GetSavedInstanceInfo is UNKNOWN; feature-detect) and fall back to "unknown".
- **Loot:**
  - No official loot method has been stated.
  - Beta reports: group loot (Need/Greed), master loot probably available (R7), and no personal loot.
  - GDKP is banned on NA/EU realms only.
  - Item stats stay hidden until the item has dropped on the server. There is no dungeon journal at launch.
  - Every boss has a low-drop-rate "chase" item.
  - An epic's appearance goes only to the player it binds to. Uncommon and rare BoP dungeon drops give the appearance to all eligible looters.
  - There are new tier sets and 1 unnamed legendary.
- **Datamined tier sets** (uncertain):
  - 18 sets tagged "Tier 1"/Hyjal, 6 pieces each, with bonuses at 2/3/4/5 pieces.
  - Warrior: Battlegear of Glory (damage), Battleplate of Glory (tank).
  - Paladin: Justice Armor (holy), Justice Battlegear (ret), Justice Battleplate (prot).
  - Hunter: Wildstalker Armor. Rogue: Grimstitch Armor.
  - Priest: Vestments of Conviction (heal), Raiments of Conviction (shadow).
  - Shaman: The Spiritcaller (resto), The Spiritcaller's Rage (enh), The Spiritcaller's Storm (ele).
  - Mage: Manaflare Regalia. Warlock: Demonheart Raiment.
  - Druid: Grovekeeper Raiment (resto), Grovekeeper Rage (bear), Grovekeeper Eclipse (balance), Grovekeeper Ferocity (feral).
  - How they are obtained is unclear: Icy Veins calls them "crafted".

### F.2 Class buff matrix for Forever

**General rules**
- Long buffs last 1 hr. Group buffs now read "party and raid"; whether one cast covers the whole raid is uncertain (R25).
- The Legacy perk **Permanence** adds 50% per rank (2 ranks) to party, raid and camping buffs.
- The Legacy perk **Reagent Economy** removes purchasable reagent costs and makes tier-1 camp items free.

**Spell IDs**
- IDs marked (R) come from the reports. WEB says existing spells keep their Classic IDs.
- [SUPP] IDs are Classic Era rank IDs: verify them with `C_Spell.GetSpellName` and match by name.

| Category | Class: single / group | Forever change | Duration | Scope | Spell IDs | Exclusive camp object |
|---|---|---|---|---|---|---|
| Stamina | Priest: Power Word: Fortitude / Prayer of Fortitude | Duration raised to 1 hr | 1 hr / 1 hr | Group version: party and raid | PW:F 1243 (R); [SUPP] 1244, 1245, 2791, 10937, 10938; PoF [SUPP] 21562, 21564 | First Aid Kit |
| Spirit | Priest: Divine Spirit / Prayer of Spirit | **Baseline at level 30** | 1 hr | Party and raid | DS 14752 (R); [SUPP] 14818, 14819, 27841; PoS [SUPP] 27681 | Faction Banner |
| Shadow resistance | Priest: Shadow Protection / Prayer of Shadow Protection | | 10 min / 20 min | Party and raid | [SUPP] 976, 10957, 10958; PoSP 27683 | none |
| Spirit (short proc) | Priest (Shadow, row-4 talent): Dark Inspiration | NEW: Mind Blast or a full Mind Flay gives you and your party +3–15% Spirit | 10 s | Party | Unknown | none |
| Intellect | Mage: Arcane Intellect / Arcane Brilliance | | 1 hr | Party and raid | AI 1459 (R); [SUPP] 1460, 1461, 10156, 10157; AB [SUPP] 23028 | Incense Candle |
| Amplify / Dampen Magic | Mage | Values buffed | 10 min | | | none |
| Stats, armor, resists | Druid: Mark of the Wild / Gift of the Wild | Improved MotW folded into baseline | 1 hr | Party and raid | MotW 1126 (R); [SUPP] 5232, 6756, 5234, 8907, 9884, 9885; GotW [SUPP] 21849, 21850 | Enchanted Lute |
| Melee and ranged crit | Druid: Leader of the Pack | Now crit only, **raid-wide**, +3%, 45 yd | Aura | Raid | [SUPP] talent 17007, aura 24932 | Camp Chair? (uncertain, R14) |
| Spell crit | Druid: Moonkin Aura | Now spell crit only, **raid-wide**, +3%, 45 yd. Stacks with Leader of the Pack. | Aura | Raid | 24907 (R) | **Camp Chair** |
| Thorns | Druid | Scales with spell power | | | | none |
| % all stats | Paladin: Blessing of Kings / Greater Blessing of Kings | **Baseline at level 20** | 1 hr / 1 hr (greater stays class-targeted) | | BoK 20217 (R); GBoK [SUPP] 25898 | Fish Bowl |
| Attack power | Paladin: Blessing of Might / Greater Blessing of Might | | 1 hr | | BoM 19740 (R); [SUPP] 19834–19838, 25291; GBoM 25782, 25916 | Lodestone |
| Mana regen | Paladin: Blessing of Wisdom / Greater Blessing of Wisdom | Improved BoW folded into baseline | 1 hr | | BoW 19742 (R); [SUPP] 19850, 19852, 19853, 19854, 25290; GBoW 25894, 25918 | Mana Well |
| Healing received | Paladin: Blessing of Light / Greater Blessing of Light | | 1 hr | | [SUPP] 19977, 19978, 19979; GBoL 25890 | none |
| Threat | Paladin: **Salvation** / **Mass Salvation** | Replace BoS and GBoS. **Not exclusive with blessings.** New "Revoke" removes them. | 1 hr | | Salvation 1038 (R; renamed). Mass Salvation and Revoke: IDs unknown | none |
| (removed) | Paladin: Blessing of Sanctuary, Sanctity Aura | **Removed** | | | ([SUPP] 20911 / 25899; do not track) | |
| Auras | Paladin: Devotion, Retribution, Concentration | Unchanged | | | [SUPP] Devotion 465 | none |
| Resist auras | Paladin: Fire, Frost, Shadow Resistance Aura | Now cover all raid members within 30 yd | | Raid | | none |
| Tank seal (not a group buff) | Paladin: Seal of Fury | NEW: learned at 10, rank 3 at 26. Its Judgement taunts. Not overwritten by PW:Shield. | | | Unknown | |
| Strength | Shaman: Strength of Earth Totem | **Raid-wide** | Totem 5 min, 30 yd | Raid | 8075 (R); [SUPP] 8160, 8161, 10442, 25361 (cast IDs; the player aura ID differs, so match by name) | **Sharpening Wheel** |
| Agility | Shaman: Grace of Air Totem | **Raid-wide**; no longer exclusive with Windfury or Flametongue | 5 min | Raid | [SUPP] 8835, 10627, 25359 | none |
| Weapon procs | Shaman: Windfury Totem / Flametongue Totem | **Raid-wide**, players only; still mutually exclusive. Tranquil Air does not stack with Windfury or Grace of Air. | 5 min | Raid | [SUPP] WF 8512, 10613, 10614; FT 8227, 8249, 10526, 16387 | none |
| Other totems | Shaman: Mana Spring, Healing Stream, Stoneskin, Windwall, Tremor, cleansing | No raid-wide note; presumably still party-only (uncertain). Resistance totems now cover party and raid. Mana Tide gained a rank at 38. | 5 min | | [SUPP] Mana Spring 5675 | none |
| Melee AP | Warrior: Battle Shout | **Raid-wide.** Improved Battle Shout removed as a talent (baseline is uncertain). Booming Voice +10% AoE. No Commanding Shout. | **3 min** | Raid | [SUPP] 6673, 5242, 6192, 11549, 11550, 11551, 25289 | none |
| Ranged and melee AP | Hunter: Trueshot Aura (Marksmanship tier-4 talent) | **Raid-wide**, 45 yd. Value +30 per datamine vs +50 in Classic (R22). | Aura | Raid | [SUPP] 19506, 20905, 20906 | none |
| Nature resistance | Hunter: Aspect of the Wild | Now covers party and raid | | Raid | [SUPP] 20043, 20190 | none |
| Stamina (imp) | Warlock: Blood Pact | No change; Improved Imp no longer boosts it | | Party | [SUPP] 6307, 7804, 7805, 11766, 11767 | none |
| Rogue | none | No group buffs | | | | |

Other changes with no group-buff effect:
- **Priest:** Fear Ward is baseline for all races at level 20. Power Infusion is unchanged.
- **Druid:** Innervate has a 6-minute cooldown.
- **Paladin:** the Ret talent Sacred Arbiter keeps Judgements of Light, Wisdom and Crusader refreshed. Judgements of Light, Wisdom and Crusader now last 40 s.
- **Shaman:** Call of the Elements, Ancestors and Spirits drop up to 4 totems at once. New: Totemic Recall and Totemic Projection. Totems share a 1-second GCD. Weapon imbues last 60 min.
- **Hunter:** Hunter's Mark gives attackers +26 ranged AP.
- **Warlock:** Curse of Agony and Curse of Doom are now Banes (one per Warlock per target), and there is a new Bane of Havoc. Curse of the Elements: −30 magic resistances and +4% magic damage. Curse of Recklessness: −175 armor and no AP gain. Healthstone is a single spell. Demonic Sacrifice lasts 2 hr. New talent: Demonic Pact.
- **Rogue:** Expose Armor removes 450 armor at 5 combo points. Poisons have more charges and stack with stones.

Races and factions:
- New combinations: Gnome Priest, Human Hunter, Dwarf Shaman (Alliance); Orc Mage, Troll Warlock, Undead Paladin (Horde).
- **Skyborne** (both factions): Warrior, Hunter, Rogue, Druid. Alliance High Order Skyborne can also be Mage; Horde Windshaper Skyborne can also be Shaman.
- Skyborne racials: Wind Blessed (3% haste), Walk on Air (90-second cooldown), Elemental Insight, Read Leyline (Alliance), Skysight (Horde).
- Dwarf: Mace Specialization replaced by Earth Fury (+2% crit damage and healing).
- **Never infer class from faction.**

### F.3 Camping: object → profession → buff → exclusive class buff

Tier-1 objects need skill 20 and come from the trainer. Buff values scale with level and are shown as low-level start → level 60. Spell IDs here are **recipe (Create-Item) spells** (R10).

| Object | Recipe spell | Item | Item-use spell | Hidden aura inside Camp Benefits | Profession | Buff at 60 | Exclusive with |
|---|---|---|---|---|---|---|---|
| Mana Well | 1230564 | 279956 | ? | 1230587 | Alchemy 171 | 10–29 mp5 | Blessing of Wisdom / Greater |
| Sharpening Wheel | 1230171 | 279944 | ? | 1230172 | Blacksmithing 164 | +6–34 Strength (R15) | Strength of Earth Totem |
| Enchanted Lute | 1230643 | 279976 | ? | 1230653 | Enchanting 333 | +28–308 armor, +2–13 all stats, +6–22 all resists | Mark / Gift of the Wild |
| Incense Candle | 1229705 | 279962 | ? | 1229513 | Herbalism 182 | +2–25 Int | Arcane Intellect / Brilliance |
| Lodestone | 1230161 | 279960 | ? | 1230164 | Mining 186 | +12–90 melee AP | Blessing of Might / Greater |
| Camp Chair | 1229517 (ITD: 2318 ×3, 4470 ×2) | 279979 | 1307229 | 1229519 | Skinning 393 | +2% crit (spells and attacks) | Moonkin Aura (Leader of the Pack uncertain, R14) |
| Faction Banner | 1229504 or 1263425 (R16) | 279972 | ? | 1229718 | Tailoring 197 | +14–32 Spirit, own faction only | Divine Spirit / Prayer of Spirit |
| First Aid Kit | 1230117 | 279968 | ? | 1230124 | First Aid 129 | +3–56 Stamina | PW:Fortitude / Prayer of Fortitude |
| Fish Bowl | 1229745 | 279967 | ? | 1230098 | Fishing 356 | +8% all stats | Blessing of Kings / Greater |
| Camp Tent | 1229432 (ITD: 2318 ×5) | 279978 | 1307230 | 1229451 (Boosted Rest) | Leatherworking 165 | Rested XP up to 5% of a level, then "Boosted Rest" for 1 hr | none |
| Reagent Bot | 1230656 | 279950 | ? | none | Engineering 202 | Vendor for class reagents | none |

Blizzard's wording (Oct 1) is that camp buffs are "weaker versions" of class buffs and "mutually exclusive" with them. Implement exclusivity as a data table `CAMP_EXCLUSIVE[hiddenAuraID] = {category…}` with a `confirmed` flag, and always show the auras actually present (R14).

**Tier 2 (skill 140) and tier 3 (skill 300) objects** need blueprints, and each also grants its profession's tier-1 buff [3P]. Format: tier 2 (spell ID, blueprint source) / tier 3 (spell ID).

| Profession | Tier 2 | Tier 3 |
|---|---|---|
| Alchemy | Fermenter (1263005, Rath'mael) | Alchemy Laboratory (1263078) |
| Blacksmithing | Anvil (1263041, Gilnid in Deadmines) | Master Forge (1263073) |
| Enchanting | Arcane Salvager (1263056, Shade of the Archmage in Dalaran) | Arcane Forge (1263082) |
| Engineering | Repair Bot (1263034, Sneed) | Anarchist's Workbench (1263083) |
| Leatherworking | Tanning Rack (1263031, Razorclaw) | Sewing Machine (1263079) |
| Tailoring | Spinning Wheel (1263032, Unstable Sentinel) | Loom (1263080) |
| Herbalism | Greenhouse (1262980) | Seed Hybridizer (1263070) |
| Mining | Rock Garden (1262975) | Molten Foundry (1263071) |
| Skinning | Field Guide (1262985; teaches Track Beasts) | Trapper's Workbench (1262982) |
| First Aid | Toxin Study (1262996) | Plague Doctor's Laboratory (1263001) |
| Fishing | Fishing Rack (1262990, Gelihast) | Fishing Hut (1262998) |
| Cooking | Cookie's Feast (1262978, Cookie in Deadmines; Stamina food) | Iron Oven (1263067) |

ITD recipe counts agree: Skinning, Herbalism and Fishing have 3 crafts each, and Mining has 18.

### F.4 Campfire and camping spell IDs

| ID | What it is | Source |
|---|---|---|
| 1229737 | Recipe "Basic Campfire" (Cooking 185, r1, tl1, th5). Tool 4471 Flint and Tinder; reagent 4470 Simple Wood ×1 → item **279981** Basic Campfire Kit. 10 s cast. | ITD Recipes_185; Wowhead |
| 1283400 | Recipe "Journeyman Campfire" (r90; taught by Blueprint 273087, which drops from Lord Serpentis in Wailing Caverns). Reagent 11291 Star Wood → item **279961**. | ITD; Wowhead |
| 1291341 | Recipe "Expert Campfire" (r200; Blueprint 273101, source unknown). Reagent 272941 Thick Logs → item **279974**. | ITD; Wowhead |
| 818 | "Basic Campfire" placement spell. Summons GO 29784; lasts 10 min; **5-minute cooldown** (ccd 300000); 10 s cast; not usable in combat or shapeshifted. | Wowhead; ITD |
| 1307227 / 1307252 / 1307237 | Item-use spells of the Basic, Journeyman and Expert Campfire kits (kit item cooldown 300000 ms) | ITD SpellNames.lua, Items_0.lua |
| 1307229 / 1307230 | Item-use spells of Camp Chair and Camp Tent (item cooldown 3600000 ms) | ITD |
| 465447 | "Create Campsite" (purpose unknown) | ITD SpellNames.lua |
| 1289723 | Aura "Welcoming Campfire": 1-minute countdown that converts into Camp Benefits | WEB |
| 1283391 | Aura "Campfire Nearby" | WEB |
| **1229741** | Aura **"Camp Benefits"**: the single combined buff. 1 hr (extended by Permanence), 20 yd, cannot be cancelled, server-scripted (R9). | Wowhead DM |
| 1229451 | "Boosted Rest" (from the Camp Tent) | WEB |

For placement detection, watch UNIT_SPELLCAST_SUCCEEDED on "player" for `{818, 1307227, 1307252, 1307237, 1307229, 1307230, 465447}`, and also match by name against the recipe and object names (R11). ItemTree uses CAMP_KIND = 62 internally.

**Campfire tiers (Cooking skill)**

| Tier | Learn at | Use at | Objects held | Blueprint |
|---|---|---|---|---|
| Basic | 1 | 1 | 3 | none |
| Journeyman | 90 | 140 (uncertain, R13) | 5 | 273087 |
| Expert | 200 | 220 (uncertain) | 10 | 273101 |

**Rules**
- Camping unlocks at level 5 with the quest "The Great Outdoors" (quest ID unknown).
- Sit, sleep, lie down, kneel or craft near the fire for about 1 minute to get the buff. Since Sept 24 you can buff, cast and craft during the countdown. RXP's Forever guides also describe /sitting at a campfire for a minute.
- Each player places 1 object per fire.
- All of a player's camp objects share **one 1-hour (3600 s) cooldown**. The Field Guide Legacy perk reduces it by 8% per rank.
- A higher-tier object can replace a lower one, ignoring the cooldown.
- The fire and its fixtures last about 10 minutes (R12).
- No group is needed to receive the buffs.
- No fires in cities. Fires must be about 100 yd apart. Camps are **not** sanctuaries.
- Fires cannot be placed in instances. The camp buff is reported to persist into dungeons; raids are unverified (R26).

**Quests**
- 96101 "Gain the Boosted Rest buff".
- "Camping 101: <Profession>": 97970 Mining, 97971 Skinning, 96646 Cooking, 97968 Herbalism, 97965 First Aid, 97967 Fishing, 97963 Alchemy, 97964 Blacksmithing, 97973 Tailoring, 98286 Enchanting, 97969 Leatherworking.

### F.5 World buffs

Policy: world buffs stay in the open world, but "tedious world buff farming for raiding is being removed" (a paraphrase of an interview). The mechanism is uncertain, so detect the auras and do not assume they are suppressed.

| Buff | ID | Duration | Notes |
|---|---|---|---|
| Rallying Cry of the Dragonslayer | 22888 | 2 hr | Persists through death |
| Warchief's Blessing | 16609 | 1 hr | Persists through death |
| Songflower Serenade | 15366 | 1 hr | |
| Spirit of Zandalar | 24425 | 2 hr | +16% stats, +11% speed. Zul'Gurub is not confirmed. |
| Mol'dar's Moxie (Dire Maul) | 22818 | 2 hr | Persists through death. The DM tribute run exists in Forever guides. |
| [SUPP] Fengus' Ferocity / Slip'kik's Savvy | 22817 / 22820 | 2 hr | |
| [SUPP] Sayge's Dark Fortunes (Darkmoon Faire) | 23735 Str, 23736 Agi, 23737 Sta, 23738 Spi, 23766 Int, 23767 Armor, 23768 Damage, 23769 Resistance | 2 hr | DMF data exists (faction 909), but the beta calendar showed no Faire in Oct or Nov. |

### F.6 Guild features

- Guild bank: exists in beta and costs 100g to unlock (player reports). Tab count and prices are not published. Its log keeps the last 25 entries per tab, timestamped to the hour [3P].
- Calendar: exists. Guild-event support is undocumented.
- No achievements, so no guild achievements. Guild levels and perks are not mentioned anywhere.
- The Guild & Communities dialogs are the modern retail UI and are now gamepad-usable (Oct 16).
- Guilds are single-faction. Cross-ruleset grouping is not supported.
- **Beta characters, names and guilds are wiped after the Oct 21 stress test.** Never treat beta data as migratable.

### F.7 Profession cooldowns (ITD build 1.60.1.70425 data, ms; agrees with Wowhead, R23)

| Recipe | Spell | Cooldown | Note |
|---|---|---|---|
| Transmute: Arcanite | 17187 | ccd 169200000 (47 h) | |
| Transmute: Legionite | 1317279 | ccd 169200000 | New |
| Elemental transmutes | 17559–17566 | ccd 82800000 (23 h) | |
| Transmute: Elemental Fire | 25146 | ccd 600000 (10 min) | |
| Transmute: Iron to Gold | 11479 | cd 3600000 (1 h) | |
| Transmute: Mithril to Truesilver | 11480 | cd 3600000 (1 h) | |
| Refined Scale of Onyxia | 22430 | ccd 7200000 (2 h) | |
| Mooncloth | 18560 | cd 342000000 (95 h) | No moonwell requirement shown |
| Salt Shaker | 19566 | ≈71 h (2.958 days; Wowhead only) | |
| Study (Comprehension) | 1302508 | cd 3600000 (1 h) | |

Other cooldowns [3P]:
- Enchanting shard transmutes: 20 h, shared.
- Legacy perk Dedicated Study: 23 h.
- Blacksmithing Repair All: 8 h at rank 1, 4 h at rank 2.

Other profession facts:
- "Over 600 new recipes."
- Legacy points: 1 each at skill 150, 225 and 300 in each of the 6 crafting professions (18 total).
- Healing potions moved to First Aid.
- Alchemy: elixirs and flasks last twice as long and are 25% stronger.
- Cooking: food gives about 5% bonus XP.

---

## G. Open risks and defensive handling

| # | Risk | Defensive handling |
|---|---|---|
| G1 | Secret values in any payload or API result (R2, R3) | Use `IsSecret`/`Clean` on every external value. Read auras, roster and talents only out of combat and outside encounters, and re-read on PLAYER_REGEN_ENABLED and ENCOUNTER_END. The UI shows "stale" rather than "missing". Never persist, key, concatenate into stored or sent data, or compare an unchecked value. |
| G2 | An API or event is missing, or throws on bad arguments | Call C APIs through `Try` and register events through `SafeRegister`. Type-check arguments. Each feature module declares its required APIs and disables itself with a visible "unavailable on this client" note. |
| G3 | SavedVariables not restored on the beta | Work fully with an empty DB. On an empty or new DB, pull state from guildmates over comms (anti-entropy). Offer an export/import string backup. Never treat an empty DB as "the guild has no data". |
| G4 | Addon messages not delivered, throttled, or locked down (R6) | Delivery probe (§D.4); a send queue gated by `CanSend()`; idempotent versioned records; jittered replies; a manual export/import fallback; never CHANNEL-type addon messages. |
| G5 | Name and realm formats (surname, unstable realm, unknown sender format) | Key by GUID; map sender → GUID through hello messages; store raw names; partition SavedVariables by ruleset and guild. |
| G6 | No roster-refresh API (C_GuildInfo.GuildRoster and GuildRoster are UNKNOWN) | `local fn = (C_GuildInfo and C_GuildInfo.GuildRoster) or GuildRoster`, called through `Try` no more than once per 15 s. If the roster is empty or stale, show a "Press J to refresh the guild roster" hint (LP:529). |
| G7 | Officer notes, MOTD, last-online and rank-permission APIs are UNKNOWN | Feature-detect each one. Never store Greenfields data in notes on the critical path. Officer-only features are gated on `GetGuildInfo("player")` rankIndex (CONFIRMED) plus a configurable rank threshold. |
| G8 | Master-loot API is UNKNOWN (R7) | Loot logging rests on self-reports and CHAT_MSG_LOOT. Master-loot assignment UI loads only if `GetLootMethod` (or `C_PartyInfo.GetLootMethod`), `GetMasterLootCandidate` and `GiveMasterLoot` all exist. Never automate handover; Forever Loot Manager says it is unverified in a live raid. |
| G9 | Lockouts are UNKNOWN | Show lockouts only if GetSavedInstanceInfo exists; otherwise show "unknown". Never compute resets from assumed 7- or 5-day intervals. `C_DateAndTime.GetSecondsUntilWeeklyReset` is CONFIRMED and may be shown as "weekly reset" (with no claim that it is the raid reset). |
| G10 | Encounter and instance IDs unknown; boss name variants (R21) | Learn IDs at runtime and persist the mapping; use the alias table; tolerate unknown encounters by logging them under their name. |
| G11 | Camp aura IDs are datamine-only (R9, R10, R16); exclusivity uncertain (R14) | Build name sets from IDs at login; detect presence; show actual auras; keep the exclusivity table as data with a `confirmed` flag; make adding IDs a data-only change. |
| G12 | Raid buffs: whether one cast covers the whole raid, plus values and ranks (R22, R25) | Per-unit detection only. Match by spellId and then by name (covers ranks). Use expirationTime from the aura (Permanence). |
| G13 | Combat log absent | Never register CLEU. Kills from ENCOUNTER_END, BOSS_KILL and PARTY_KILL; deaths by polling out of encounter; no damage, heal or interrupt tracking. |
| G14 | Taint, gamepad and freeze traps | Pre-create frames hidden; never parent into Blizzard panels; canvas Settings; no UIDropDownMenu or EasyMenu; slash handlers defer with `C_Timer.After(0)` and never SetFocus; close-button OnClick override; no protected calls in combat; Settings opening deferred out of combat. |
| G15 | TRILINEAR crash (R18) | Never pass a filter argument. Code review rule: grep for "TRILINEAR" and "LINEAR". |
| G16 | WOW_PROJECT_ID inconsistent (R4) | TOC-number gate. |
| G17 | Patch 1.60.2 (TOC 16002) | Gate on ranges (`>= 16000`), never on equality. Bump the TOC on patch day. |
| G18 | Timer cap of about 500 | One scheduler with one OnUpdate or ticker; at most 50 live C_Timer handles. |
| G19 | Item data loads fail silently | `C_Item.RequestLoadItemDataByID` plus ITEM_DATA_LOAD_RESULT with a timeout; never rely on ContinueOnItemLoad alone. |
| G20 | Tooltip post-call crashes | Wrap the handler in pcall; no heavy work; no OnTooltipSetUnit hooks. |
| G21 | Money formatting (global GetCoinTextureString answers nothing) | `C_CurrencyInfo.GetCoinTextureString`, else your own formatter. |
| G22 | Guild bank API unknown (R8) | Optional module, feature-detected; no dependency from core features. |
| G23 | Recipe enumeration without the window is UNKNOWN | Ship a recipe DB, harvest more when the window opens, version the DB, include its hash in comms. |
| G24 | Third-party data licensing | Do not copy ItemTree_Data or other addons' generated tables or art verbatim. Use them only as cross-check references. |
| G25 | Beta wipe and changing data | Tag every stored record with its build (`GetBuildInfo` build). Wipe or migrate when crossing the launch build. |
| G26 | Chat automation restrictions | Automatic chat only on GUILD and PARTY, behind CanSend; everything else only on click. |
| G27 | Glyphs and locale | Use inline textures for symbols; locale font fallback; case-insensitive search must also search the raw UTF-8 string. |

---

## H. Day-one in-game verification checklist

Run these out of combat in the open world, then again inside a dungeon and a raid. Record the results in this document.

```
/dump C_GuildInfo and C_GuildInfo.GuildRoster, GuildRoster
/dump GetGuildRosterInfo(1)                                   -- confirm 17-return layout, name format
/dump GetLootMethod, C_PartyInfo and C_PartyInfo.GetLootMethod, GetMasterLootCandidate, GiveMasterLoot
/dump GetSavedInstanceInfo, GetNumSavedInstances, RequestRaidInfo
/dump C_TradeSkillUI.GetAllRecipeIDs, C_TradeSkillUI.GetRecipeCooldown, GetTradeSkillCooldown
/dump C_Spell.GetSpellName(1229741), C_Spell.GetSpellName(1289723), C_Spell.GetSpellName(818)
/dump C_UnitAuras.GetPlayerAuraBySpellID(1229741)            -- at a campfire; then each hidden aura ID in §F.4
/dump Enum.SendAddonMessageResult, Enum.AddOnRestrictionType
/dump C_ChatInfo.SendAddonMessage("Greenfields","ping","GUILD")   -- observe return type + echo
/dump C_EncodingUtil and C_EncodingUtil.CompressString
/dump GetSpellInfo, UnitAura, UnitBuff, GetNumSkillLines, GetTalentInfo   -- expect nil (R1)
/dump GetProfessions()                                        -- confirm slot order prof1, prof2, firstAid, fishing, cooking
/dump C_SkillInfo, C_SpellBook.GetNumSkillLines
/dump GetGuildRosterMOTD, CanEditOfficerNote, C_GuildInfo and C_GuildInfo.CanEditOfficerNote
/dump UnitIsAFK, IsEveryoneAssistant, RandomRoll, RANDOM_ROLL_RESULT
```

Also check:
- The ENCOUNTER_END argument count and secrecy during a real kill.
- CHAT_MSG_ADDON sender format.
- Whether the Camp Benefits hidden auras appear in `GetBuffDataByIndex` scans of other units.
- Whether Camp Benefits persists into raids (Dec 9).