# Greenfields headless harness

A multi-client, deterministic, headless test bed for the Greenfields addon on
**WoW Forever 1.60.1 / TOC 16001** (retail-12.x-shaped API, secret values, no combat log).
Each simulated client is a real Lua 5.1 VM (`lupa.lua51`) that loads a strict WoW mock and
then the addon files in TOC order, exactly like the client: `chunk("Greenfields", ns)`.

```
tools\.venv\Scripts\python.exe tools\harness\run.py --scenario all ^
    --render tools\harness\out --json tools\harness\out\report.json
```

A full `all` run takes about 25 s (6 s without `--render`). The exit code is non-zero when
any Lua error was recorded (addon-captured or harness-caught) or the harness itself failed.

## Files

| File | What it is |
|---|---|
| `run.py` | Orchestrator (venv Python). Builds the world, the clients, the clock, the addon-message bus, the chat router and the "group server"; runs the scenarios; writes the report; calls `render.py`. |
| `wow_mock.lua` | Core: private stdlib references, PRNG, virtual clock (`time`/`date`, AWST), secret values + taint log, error recording, `C_Timer`, event registry and dispatch, strict globals, the `rawget(_G, ...)` probe, JSON. |
| `wow_mock_data.lua` | Event whitelist, secret-argument map per event, fake item/spell/atlas databases, loadable fonts. |
| `wow_mock_widgets.lua` | Widget system: every frame/region type and method, anchors/geometry, scripts, visibility, fonts and text measurement. A method the real widget lacks is simply absent, so calling it raises like WoW. |
| `wow_mock_anim.lua` | Animation groups, the per-tick driver (`MOCK.Tick`), user input helpers (`UserClick`, `UserEnter`, `UserType`, `UserKey`, `UserWheel`, `PressEscape`) and fuzz helpers. |
| `wow_mock_api.lua` | Non-game globals: Lua extensions, Mixins/ColorMixin, `BackdropTemplateMixin`, constants, GlobalStrings, `Enum`, font objects, root frames, templates, `GameTooltip`, `TooltipDataProcessor`, `Settings`, `C_AddOns`, `C_Texture`, `C_EncodingUtil`, `hooksecurefunc`. |
| `wow_mock_game.lua` | Game state (per client, from `CFG`): identity, guild roster, group/raid and unit tokens, `Unit*`, instances, professions/spellbook, `C_Spell`, `C_Item`, `C_Container`, `C_UnitAuras`, `C_Secrets`, `C_TradeSkillUI`, loot and rolls, money/merchant, `C_ChatInfo` (addon messages + chat), `C_PartyInfo`, modifiers, cursor, sounds, `ChatFrameUtil`; combat / encounter / chat-lockdown state; harness entry points `MOCK.Game.*`; `MOCK.Setup()`. |
| `wow_mock_scene.lua` | `MOCK.ExportScene()`, `MOCK.CheckLayout()`, `MOCK.SerializeSV()`, `MOCK.Report()`. |
| `render.py` | Scene JSON -> PNG (system Python + PIL). |
| `fonts.py`, `font_metrics.json` | WoW font -> Windows stand-in mapping, shared by the mock's text measurement and the renderer (`render.py --metrics` regenerates the metrics). |
| `luabc.py` | Static global scanner over Lua 5.1 bytecode (`python luabc.py file.lua ...`). |

## The world

* Realm `Arugal`, guild **Greenfields** (Alliance), ranks Guild Master / Officer / Veteran /
  Member / Initiate, 25 members covering all 9 classes with levels, zones, notes (`alt of
  Davo`, `Shazza's alt`, `alt: Gazza`, ...), online flags and GUIDs `Player-1-XXXXXXXX`.
* Clients (`--clients N`, default 3): **Spencer** (GM, Human Warrior 60), **Bazza** (Officer,
  Dwarf Priest 60), **Shazza** (Member, Gnome Mage 60); more clients come from a fixed list
  (Kev, Trish, Mick, Wayne, Gaz, Deb, then ClientN). Each has money, professions
  (`GetProfessions` slots), a known-spell set (class buffs + recipes), bags and PvP stats.
* Raid fillers: Davo, Kylie, Macca, Sheila, Gazza, Tazza (guildies) and a pug `Randy-Yojamba`.
* Clock: Wed 9 Dec 2026 19:00 AWST, `GetTime()` starts at 1000, 0.05 s ticks; PRNG seeded per
  client from its name. Runs are bit-for-bit deterministic for a given addon source
  (`--addon DIR` points the harness at a snapshot).

## Transport

* `C_ChatInfo.SendAddonMessage(prefix, text, chatType, target)` validates like the client
  (types; prefix 1-16 chars and registered; <= 255 bytes; no `\0`; chat type; guild/group
  membership; chat lockdown; a per-prefix throttle of 10 messages, +1/s) and returns
  `Enum.SendAddonMessageResult`. Accepted messages go to `MOCK.outbox`.
* The bus delivers them on the **next tick** as
  `CHAT_MSG_ADDON(prefix, text, channel, "Name-Realm", target, 0, 0, "", 0)` (or `_LOGGED`)
  to every client whose prefix is registered: GUILD -> all online guild clients incl. the
  sender (self echo), OFFICER -> officers, RAID/PARTY/INSTANCE_CHAT -> group clients incl.
  the sender, WHISPER -> the target (dropped if offline or not a client).
* `C_ChatInfo.SendChatMessage` is captured (`chatLog`) and echoed as `CHAT_MSG_GUILD`,
  `CHAT_MSG_RAID(_LEADER)`, `CHAT_MSG_PARTY(_LEADER)`, `CHAT_MSG_WHISPER` +
  `CHAT_MSG_WHISPER_INFORM`, ... SAY/YELL/CHANNEL without a hardware event are blocked
  (`ADDON_ACTION_BLOCKED`); automatic RAID/WHISPER/RAID_WARNING sends are flagged (FACTS D.7).
  The global `SendChatMessage` is absent, as on Forever.
* `RandomRoll`, `C_PartyInfo.InviteUnit/ConvertToRaid`, `SetRaidSubgroup/SwapRaidSubgroup`,
  `DoReadyCheck`, `LootSlot` etc. go through `MOCK.requests`; `run.py` plays the server and
  pushes the result (system lines, new group layout) to the clients.
* Combat/encounter state follows the events: `InCombatLockdown()` turns on after
  `PLAYER_REGEN_DISABLED` handlers ran and off before `PLAYER_REGEN_ENABLED`; an
  `ENCOUNTER_START` inside an instance starts a chat lockdown until `ENCOUNTER_END`.
  Auras are secret while in combat (Forever hides them).

## Scenarios

| Scenario | What happens |
|---|---|
| `selftest` | Loads deliberately broken addon code into a throw-away client and checks that every detector fires (handler error, `GF:Safe` capture, undefined global, leak, unknown/restricted event, C API type check, missing widget method, `SetText` before `SetFont`, missing media, inverted rect, secret misuse). Its errors are not counted against the addon; a detector that stays silent is a harness failure. |
| `boot` | Clients log in 7 s apart: `ADDON_LOADED`, `SPELLS_CHANGED`, `PLAYER_LOGIN`, `PLAYER_ENTERING_WORLD(true,false)`, roster 1 s later (`PLAYER_GUILD_UPDATE`, `GUILD_ROSTER_UPDATE`), "has come online" for the others; then 120 s. Verifies every client holds identical `profile` and `stats` docs in `GreenfieldsDB.guilds[*].store`. |
| `pages` | Each client opens the window; for every page in `UI.pageList` (hidden ones too; `profile` gets a member key): `ShowPage`, 1 s, layout check, scene export (+ PNG), then the fuzzer: hover + click every visible Button/CheckButton (right-click too where registered) in two passes, a shift-click pass, hover every mouse-aware frame, type into every EditBox + Enter/Escape, wheel every scrollable frame. Popups (UISpecialFrames other than the main window) are answered once (type + primary button for prompts, a cancel-ish button otherwise) and then escaped. Then the window is resized to 900x580 and 1400x900 and the page re-shown. The main-window chrome is fuzzed last. After `raid`, the same pass runs again with data (`pages-after-raid`). |
| `raid` | Raid-night prep through the addon's public APIs (Spencer creates a Hyjal event 10 minutes out, everyone signs up, Spencer opens an SR session, Bazza and Shazza reserve drops), then party -> raid of the clients + fillers, buffs on everyone, enter Hyjal Summit (raid, 20), ready check, pull 1 (Shazza dies, wipe `ENCOUNTER_END(...,0)`), release/resurrect, pull 2 (kill + `BOSS_KILL`), loot window on Spencer (3 rare/epic items + coin), `START_LOOT_ROLL` x3, roll lines (`RANDOM_ROLL_RESULT`), `CHAT_MSG_LOOT` lines, `ENCOUNTER_LOOT_RECEIVED`, `!sr` whispers to the host, leave, camp kit cast (`UNIT_SPELLCAST_SUCCEEDED` 1307227) + Camp Benefits auras, Hearthstone (8690), Bazza's Tailoring window (`TRADE_SKILL_SHOW`/`LIST_UPDATE`, a new recipe), money, level-up, merchant with repair, quest turn-in; then 360 s and every dataset is compared across clients. |
| `misc` | Duel, AFK, mirror timer, honor, party kill, fishing loot, falling death, emote/jump hooks, every `/gf` slash command, compartment callbacks, minimap button (click, right-click, drag), Settings, item/unit tooltips, combat + chat lockdown with the window open, and a logout -> SavedVariables round trip -> login of the last client. |
| `secrets` | Fresh clients; after boot every secret category is switched on (unit names, GUIDs, roster fields, aura fields, chat text, encounter arguments, spell cooldowns) and the raid scenario runs again, followed by a UI fuzz of the first client in combat (`secrets-ui`). Any Lua error fails the scenario. |

## Report (`--json`)

* `meta`: counts of Lua errors, harness errors, mock-origin errors.
* `scenarios`: status, notes, per-page fuzz statistics (`buttons`, `clicks`, `typed`,
  `wheels`, `newErrors`), dataset summaries and cross-client **mismatches**.
* `problems`: everything below, de-duplicated across clients with counts.
* `clients["<world>/<name>"]`:
  `errors` (harness-caught handler errors with tracebacks, deduplicated with counts, tagged
  `origin` addon/mock), `addonErrors` (`Greenfields.errors`), `globalReads` and `rawgetMisses`
  (classified: expected absent-on-Forever probe / real WoW API missing from the mock /
  probable typo), `globalWrites` + `leaks` (allowed: `Greenfields*`, `SLASH_GREENFIELDS*`,
  SavedVariables, `Greenfields_On*`), `namedGlobals` (named frames), `unknownEvents`,
  `forbidden` (restricted events, protected calls, blocked chat), `taint` (secret-value
  misuse), `warnings`, `layoutIssues` (regions whose anchors invert their rect), `chatLog`,
  `prints`, `sounds`, `commStats`, `timers` (live/peak C_Timer handles and where they come
  from), `sv` (serialized SavedVariables size + anything the client could not save).
* `comm`: addon-message stats per op (`HI`, `SU`, `SD`, `FD`, ...): logical messages, bytes,
  wire parts, per client and in total (decoded from the Greenfields wire format).

## Scene export and rendering

`MOCK.ExportScene()` returns every visible region **already sorted back to front** (strata,
frame level, draw layer, sublevel, creation order). **Coordinates are screen pixels with the
origin at the top-left and y pointing down** (`y = 1080 - (bottom + height)` from WoW's
bottom-left system); sizes are multiplied by the effective scale. Textures carry file /
fileID / atlas / colour / vertex colour / texcoords / gradient / rotation / slice margins /
tiling / masks; FontStrings carry raw text (with colour codes), font, size, flags, colour,
justification, wrap, shadow; frames carry backdrop info; clip rects come from
`SetClipsChildren` and ScrollFrame ancestors. Button state textures, StatusBar fill and
Slider thumbs are resolved; EditBox text becomes a font item.

`render.py` (system Python, `C:\Python313\python.exe -I`) draws it at 2x and downsamples.
Greenfields media come from `Greenfields\Media\*.tga`; WHITE8X8 is white; game icons, atlases
and fileIDs are tinted placeholder squares. With `--render OUT`, `run.py` writes
`OUT\<client>-<page>.png` (cropped to the main window + 30 px), `OUT\<client>-home-WxH.png` for
the two resize passes, `OUT\<client>-<page>-screen.png` (full screen) whenever a toast is up,
`OUT\<host>-<page>-data.png` for the host's second page pass (after the raid, with data),
and keeps the scene JSON in `OUT\scenes`.

```
C:\Python313\python.exe -I tools\harness\render.py OUT\scenes\Spencer-home.json home.png --crop 410,140,1100,740
```

## Strictness model (and its limits)

* Unknown events raise on registration; `COMBAT_LOG_EVENT_UNFILTERED` is forbidden.
* C APIs type-check their arguments and raise like the client; absent Forever APIs
  (`GetItemInfo`, `GetSpellInfo`, `UnitAura`, global `SendChatMessage`, `GuildRoster`, master
  loot, ...) are simply missing.
* Widgets only have real methods; setting a non-existent script raises; fonts must be set
  before `SetText`; texture filter arguments are fatal (FACTS R18); unknown templates raise;
  addon texture paths must exist on disk.
* Secret values are opaque userdata: arithmetic, concatenation, `#`, indexing, calling,
  secret-vs-secret comparison and the string inspection functions raise; `tostring`,
  `string.format` and friends return secrets; `type()` reports the underlying type (so
  `type(x) == "string"` is not a secret guard). Lua 5.1 cannot intercept comparing a secret
  with a plain value (`secret == "x"` is just false) or using a secret as a table key; the
  SavedVariables check reports secrets that reached storage.
* Layout follows WoW's anchor rules, including the classic trap that `LEFT`/`RIGHT` anchors
  pin the vertical centre: `TOPLEFT` + `RIGHT` derives the height from top and centre, so a
  region anchored below a sibling that way gets an inverted rect. `MOCK.CheckLayout()` flags
  those on settled pages.

## Extending

* A missing client API shows up as a `rawgetMisses`/`globalReads` entry classified
  "real WoW API missing from the mock". Add it to `wow_mock_game.lua` (game state) or
  `wow_mock_api.lua` (stateless), into the `G` table, and keep it strict (type checks,
  `nil` for unknown units, secrets via `MaybeSecret`).
* New events go into the whitelist in `wow_mock_data.lua` (and `MOCK.secretArgs` if any
  payload argument can be secret).
* New scenario steps: use `MOCK.Game.*` (state changes that fire the client's events) and
  `Client.fire(...)` for plain events; `Sim.advance(sec)` moves the shared clock.
