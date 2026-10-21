# Greenfields — Core API & Module Contract

Greenfields is a guild addon for **World of Warcraft: Forever** (client 1.60.1, TOC Interface 16001, a Classic-content game on a Midnight-era API).
The guild is *Greenfields*, named after a rough suburb of Mandurah, WA 6210, where the members met.
The voice is edgy, larrikin Aussie humour (servo, bin chicken, Centrelink, Bunnings snag, "yeah nah"): cheeky, never hateful. No slurs and no jokes about real private people.

**Required reading before writing code:**
- this file
- `docs/FOREVER_FACTS.md`: the authoritative client API fact sheet. Its §0.4 rulings are binding.
- the core sources in `Greenfields/Core`, `Greenfields/UI` and `Greenfields/Data`. They are short and commented, and they are the API.

---

## 0. Hard rules (violations are bugs)

1. **Lua 5.1 only.** No `goto`, `//`, bitwise operators or `<const>`. `unpack` is a global.
   - `#t` on a table with holes is undefined, so use explicit counts.
   - Run `tools\.venv\Scripts\python.exe tools\syntax_check.py` until it reports 0 problems.
2. **No combat log.** Never register `COMBAT_LOG_EVENT_UNFILTERED` and never call `CombatLogGetCurrentEventInfo` or `C_CombatLog*`; both are restricted on Forever. Use the event map in FOREVER_FACTS §B.2.
3. **Secret values.** Any value that comes from the client (event payloads, unit names, GUIDs, aura fields, chat text, roster fields) can be "secret" in combat, instances or encounters.
   - Run it through `GF.API.Readable(v)` / `GF.API.Clean(v)` / `GF.API.CleanString(v)` / `GF.API.CleanNumber(v)` before you compare it, concatenate it, use it as a key, store it or send it.
   - If it's secret, skip it.
4. **Never call a client API directly when `GF.API` wraps it.**
   - When you need something `GF.API` lacks, write a local helper in your own file.
   - That helper must use `rawget(_G, "Name")`, type-check its arguments (C APIs throw on nil or wrong types), use `pcall`, and Clean the results.
   - Missing classic globals (GetItemInfo, GetSpellInfo, UnitAura, GetTalentInfo, GetNumSkillLines...) are ABSENT on Forever.
5. **Register events only via `GF:RegisterEvent` / `GF:RegisterUnitEvent`.** These are pcall'd, because unknown events raise on Forever.
6. **No global leaks.** Everything is `local`. The only allowed globals are named frames prefixed `Greenfields` (only when a name is truly needed, e.g. for `UISpecialFrames`) and the ones core already defines.
7. **Never pass a filter argument** (e.g. `"TRILINEAR"`) to `SetTexture`/`SetAtlas`; it crashes the client.
8. **Chat sends:**
   - Automatic sends go only to GUILD, PARTY, RAID or WHISPER, and only through `GF.API.SendChat`, which checks the lockdown.
   - Never auto-send SAY, YELL or CHANNEL.
   - Anything posted to raid or guild chat must be opt-in via a setting or a button click.
9. **Work with an empty DB.** SavedVariables may not restore on the beta, so everything must still work from empty.
10. **File ownership:** you may only create or modify the files assigned to you under `Greenfields/Modules/`.
    - Do **not** edit Core, UI, Data or the TOC.
    - Put the TOC lines you need (in load order) and any requested core changes in your final report.
11. **Performance:**
    - No per-frame OnUpdate work except short-lived drags and animations.
    - Throttle scans, debounce refreshes with `GF:Debounce`, and build pages lazily (the `build` callback).
    - Lists over ~30 rows must use `UI:List` (virtual).
12. **Errors:** wrap callbacks you hand to Blizzard (hooks, tooltip post-calls) in `GF:Safe`. Core already wraps events, timers, comm handlers, page builds and button clicks.
13. **No emoji or exotic Unicode in UI text.** WoW's fonts lack those glyphs and draw empty boxes. Use the media icons instead. Plain ASCII plus common Latin punctuation is safe.
14. **Only one client announces.** When every client could see the same thing (a boss kill, a title changing hands, a member joining), only one client posts to the feed or chat:
    - for title changes, the new holder's client;
    - for kills and joins, the raid leader's or an officer's client;
    - always with a dedupe `key`.

---

## 1. Module skeleton

```lua
--[[ Greenfields - Modules/Example.lua
     One-paragraph description of what this file does and why. ]]
local _, GF = ...
local API, U, UI, T = GF.API, GF.Util, GF.UI, GF.Theme
local C = T.c

local Example = GF:NewModule("Example")   -- optional lifecycle: OnInit / OnLogin / OnEnterWorld
GF.Example = Example                       -- public API table (see §7 for required names)

function Example:OnLogin() ... end
GF:RegisterEvent("ENCOUNTER_END", function(event, encounterID, encounterName, difficultyID, groupSize, success) ... end)
GF:On("GF_GUILD_READY", function(guildKey) ... end)
```

The load order is the TOC order. Core, Data and UI load before every module. Modules must not depend on each other at load time; touch other modules only at runtime, behind a guard: `if GF.SR and GF.SR.ReservesFor then ... end`.

---

## 2. Core reference

### 2.1 GF (Core/Init.lua)

| Call | What it does |
|---|---|
| `GF:Print(fmt, ...)` / `GF:Debug(fmt, ...)` | Chat output. Debug output only appears with `/gf debug`. |
| `GF:Safe(label, fn, ...)` → `ok, ...` | Protected call. Errors are recorded and listed by `/gf errors`. |
| `GF:Wrap(label, fn)` → fn | Returns a protected wrapper around `fn`. |
| `GF:RegisterEvent(event, fn(event, ...), owner)` → bool | Several handlers per event are fine. Returns false if the event doesn't exist. |
| `GF:UnregisterEvent(event, owner)` | |
| `GF:RegisterUnitEvent(event, unit, fn)` | |
| `GF:On(msg, fn)` → token, `GF:Off(msg, token)`, `GF:Fire(msg, ...)` | Internal messages. |
| `GF:After(sec, fn)`, `GF:Ticker(sec, fn)` → handle with `:Cancel()`, `GF:Debounce(key, sec, fn)` | Timers. |
| `GF:NewModule(name)`, `GF:GetModule(name)` | |
| `GF:RegisterSlash(cmd, fn(args), help)` | Adds `/gf <cmd>`. Work is already deferred a tick. |
| `GF.VERSION`, `GF.PROTOCOL` | |

`GF.db`, `GF.gdb` and `GF.cdb` are the SavedVariables partitions; see §2.4.

**Built-in messages**

| Message | Payload |
|---|---|
| `GF_INIT` | |
| `GF_LOGIN` | |
| `GF_ENTER_WORLD` | `(isInitialLogin, isReload)` |
| `GF_GUILD_CHANGED` | `(guildKey)` |
| `GF_GUILD_READY` | `(guildKey)`: fires once the real guild partition is active. Publish your own docs only after this. |
| `GF_STORE_CHANGED` | `(datasetName, id, data, record, isRemote)` |
| `GF_ROSTER_UPDATED` | |
| `GF_GROUP_UPDATED` | |
| `GF_MEMBER_JOINED` | `(key)` |
| `GF_MEMBER_LEFT` | `(key)` |
| `GF_PEER_SEEN` | `(key, peer)` |

### 2.2 GF.Util (U) — pure helpers

**Strings:** `Trim`, `Split(s, sep)`, `StartsWith`, `Truncate(s, n)`, `Capitalize`, `Matches(haystack, needle)` (plain, case-insensitive), `StripCodes`, `ChatSafe`.

**Numbers:** `Round`, `Clamp`, `Commas`, `Short` (1.2k, 34k), `Pct(part, whole)`.

**Tables:** `Copy`, `Defaults(dst, src)`, `Count`, `Keys(t, cmp)`, `Values`, `Contains`, `Filter`, `Map`, `Wipe`, `CapList(list, n)`, `SortBy(list, keyFn, desc)`, `Pick(list)`.

**Time** (server epoch seconds):

| Function | Output |
|---|---|
| `U.Now()` | |
| `U.Ago(ts)` | "5m ago" |
| `U.Duration(sec)` | "2h 05m" |
| `U.DateTime(ts)` | "Wed 13 Nov, 7:30pm" |
| `U.DateShort(ts)` | |
| `U.WeekKey(ts)` | YYYYMMDD of the Wednesday the week starts on. Use it for all "this week" buckets. |

**Colour:** `U.Hex(r, g, b)`, `U.Color(text, hexOrRGB)`, `U.ClassColorHex(class)`, `U.ClassName(key, classFile)` (class-coloured short name), `U.Plural`.

**Names:** `U.ShortName(key)` (display form).

### 2.3 GF.API — the only door to the client (Core/Compat.lua)

Read the file; every function is documented there. The most used:

| Group | Functions |
|---|---|
| Secret-value checks | `Readable`, `Clean`, `CleanString`, `CleanNumber` |
| Clocks | `ServerTime()`, `Time()` (GetTime), `InCombat()` |
| Identity | `Key(rawName)`, `MyKey()`, `UnitKey(unit)`, `UniqueNames()`, `IsForever()` |
| Units | `UnitName`, `UnitClassFile`, `UnitLevel`, `UnitRace`, `UnitFaction`, `UnitGUID`, `UnitIsConnected`, `UnitIsDead`, `UnitIsAFK`, `UnitExists`, `IsFalling`, `IsGroupLeader`, `IsGroupAssistant` |
| Classes | `CLASSES`, `ClassColor(class)`, `ClassName(class)`, `SetClassIcon(tex, class)` |
| Items | `ItemInfo`, `ItemInfoInstant`, `ItemName`, `ItemIcon`, `ItemQuality`, `ItemLink`, `ItemID(linkOrId)`, `RequestItem(id)`, `QualityColor(q)`, `ItemCount(id)`, `ItemCooldownLeft(id)`, `ItemSpell(item)` |
| Spells | `SpellName(id)`, `SpellIcon(id)`, `Knows(spellId)` (IsPlayerSpell chain; works for recipe spells with the window shut) |
| Auras | `AurasSecret()`, `ForEachBuff(unit, fn(spellId, name, aura) -> stop?)`, `PlayerHasAura(id)` |
| Group and instance | `InstanceInfo()` → `{name, type, difficulty, maxPlayers, id}`, `InRaidInstance()`, `InRaid()`, `InGroup()`, `GroupChannel()`, `NumGroupMembers()`, `GroupMembers()` (list of `{unit, name, key, class, level, subgroup, rank, online, dead, isML, role}`), `CanLeadGroup()`, `Invite(name)`, `ConvertToRaid()`, `SetRaidSubgroup(i, g)`, `SwapRaidSubgroup(a, b)` |
| Guild | `InGuild()`, `GuildInfo()` → `name, rankName, rankIndex`, `RequestGuildRoster()`, `GuildMembers()` |
| Other | `Professions()` → `{skillLine, name, rank, max, icon}`, `Money()`, `ChatLockdown()`, `SendChat(text, chatType, target)`, `PlaySound(kit)`, `TooltipPostCall("Item" or "Unit", fn(tooltip, data))`, `IsShiftKeyDown()`, `IsControlKeyDown()` |

**Player keys.** A player is always identified by a **key**: a bare name on Forever (names are region-unique), or Ambiguate's "Name-Realm" for foreign realms elsewhere.
- Get one with `API.Key(rawName)`, `API.UnitKey(unit)` or `API.MyKey()`.
- Never key data by GUID or by "Name-Realm" yourself.

### 2.4 SavedVariables (Core/DB.lua)

- **`GF.db.settings`:** account-wide toggles. Existing keys: `toasts`, `toastSounds`, `feedToasts`, `welcome`, `minimap`, `shareWealth`, `wipeRoastsLocal`, `wipeRoastsRaid`, `srAutoAnnounce`, `srPopups`, `campPings`, `tooltipSR`, `tooltipCrafters`, `tooltipTitles`, `scale`, `debug`.
  - Read them with `GF.db.settings.X ~= false` for default-on toggles.
  - If you need a new toggle, keep it inside your own table: `GF.db.settings.myModule = GF.db.settings.myModule or {}`.
- **`GF.gdb`:** per-guild partition. Holds `store` (replicated), `feed`, and `local`. Use `GF.DB:Local("ModuleName")` for a per-guild, non-replicated scratch table.
- **`GF.cdb`:** per-character. Holds `stats` and `weekly` (reserved for the Stats module), `track` (tracker scratch), and `main`. Other modules use `GF.cdb.<moduleName> = GF.cdb.<moduleName> or {}`.

### 2.5 GF.Comm — addon messages (Core/Comm.lua)

| Call | Notes |
|---|---|
| `Comm:Register(op, fn(payload, senderKey, channel), {self = bool})` | Your own echoes are ignored unless `self = true`. |
| `Comm:Send(op, payload, channel, target, prio)` | channel: `GUILD`, `GROUP` (auto RAID/PARTY/INSTANCE_CHAT), `RAID`, `PARTY` or `WHISPER`. prio: `ALERT`, `NORMAL` or `BULK`. |
| `Comm:Guild(op, payload, prio)`, `Comm:Group(op, payload, prio)`, `Comm:Whisper(targetKey, op, payload, prio)` | Shortcuts. |
| `Comm:HasAddon(key)` → version or nil | |
| `Comm:OnlinePeers()` → number | |

- Payloads can be any Lua table, string, number or boolean; they are serialized, deflated when worth it, chunked and throttled for you.
- Keep them compact: short keys, IDs not names.
- Throughput is about 2 messages/s at ~250 bytes. Design for that: never broadcast per-jump or per-tick.
- **Reserved ops:**

| Owner | Ops |
|---|---|
| Core | `HI`, `SU`, `SD`, `SQ`, `SX`, `SG` |
| Feed | `FD` |
| Stats | `DW` |
| SR / Loot | `SR`, `LR`, `LW`, `LX` |
| Buffs | `CP`, `CA`, `BQ` |
| Raids | `RQ` |
| Attendance | `AQ` |

  Use only your own ops. Ask in your report if you need another.

### 2.6 GF.Store — replicated datasets (Core/Store.lua)

Prefer the Store over raw comms for anything that should persist and sync.

```lua
GF.Store:Define({ name = "events", code = "ev", owner = "shared",
                  canWrite = function(authorKey, id, newData, oldData) return GF.Roster:IsOfficer(authorKey) end,
                  lazy = nil,           -- seconds: batch & broadcast local changes at most this often (high-churn data)
                  mirrorGroup = false,  -- also broadcast updates to the current group (non-guild raiders)
                  keepDays = 120,       -- prune docs older than this
                  keep = function(id, rec) return true end,   -- optional veto on pruning
                  validate = function(id, data) return type(data) == "table" end,
                  onChange = function(id, data, rec, isRemote) end })
GF.Store:Get(name, id)  GF.Store:All(name)  GF.Store:Put(name, id, data)  GF.Store:Delete(name, id)
GF.Store:Mine(name)  GF.Store:PutMine(name, data)  GF.Store:CanWrite(name, id, data)  GF.Store:Count(name)
```

- `owner = "player"` datasets are keyed by player key, and only that player may write their doc.
- **Treat data as immutable:** to change a doc, copy it (`U.Copy`), edit the copy and `Put` it.
- Docs must be plain serializable tables: no functions, no secret values, no frames.
- Keep docs small (under ~2 KB each when serialized). Split big things across several docs.
- **Reserved dataset names and codes** (define your own in your module file; never re-define someone else's):

| Owner | Datasets |
|---|---|
| Core | `config`/`cf`, `profile`/`pl` |
| Raids | `events`/`ev`, `signups`/`su` |
| SR / Loot | `srsessions`/`ss`, `reserves`/`sr`, `loot`/`lt`, `catalog`/`ct` |
| Attendance | `attendance`/`at` |
| Stats | `stats`/`st` |
| Professions | `recipes`/`rc`, `crafts`/`cr` |
| Buffs | `camp`/`cm` |
| Feed | none (ephemeral) |

### 2.7 GF.Roster (Core/Roster.lua)

| Call | Notes |
|---|---|
| `Get(key)` | Member table: `{name, key, rankName, rankIndex, level, class, zone, note, officerNote, online, guid, mobile}` |
| `All()`, `List(filterFn, sortKey)`, `Count()`, `OnlineCount()` | sortKey: name, rank, level, online or class |
| `IsMember(key)`, `InGroup(key)`, `Group()` | `Group()` is the `API.GroupMembers()` list |
| `GroupEntry(key)`, `IsOnline(key)`, `Class(key)`, `Level(key)` | |
| `RankIndex(key)`, `IsGM(key)`, `IsOfficer(key)` | |
| `CanManage(key)` | Officer, or leader/assist of the current group. Use it to gate raid-time tools. |
| `MainOf(key)`, `IsAlt(key)`, `AltsOf(mainKey)` | Roll alt data up to mains for attendance and leaderboards. |
| `Colored(key)` | Class-coloured short name. |
| `Config()` | `{officerRank, srLimit, raidDays, motd}` |
| `Refresh()` | Asks the server for a roster update. |

### 2.8 GF.Profile (Core/Profile.lua)

- Everyone publishes a small `profile` doc: `{class, level, race, faction, v, main, profs = {[skillLine] = rank}, t, ...}`.
- Modules add fields with `GF.Profile:Contribute("field", fn() -> value)` and call `GF.Profile:Touch()` when the value changes. Contributions are debounced and published lazily.
- Keep contributed fields tiny.
- `GF.Profile:Get(key)` returns anyone's profile.
- Reserved fields:

| Owner | Fields |
|---|---|
| Buffs | `caps`, `camp` |
| Stats | `wealth` |
| Professions | `pv` (recipe digest) |

### 2.9 Data

- `GF.Titles`, `GF.TitlesByKey`, `GF.WealthScore(copper)`: Data/Titles.lua, the Hall of Fame catalogue.
- `GF.BuffData` (Data/Buffs.lua):
  - `categories` / `byKey`: buff categories with spell IDs, class providers, camp substitutes and `who`.
  - `camp` / `campByKey` / `campByBuff`: camp objects with profession, recipe spells, kit items and hidden aura.
  - `campfires`, `professions`, `professionOrder`, `childSkillLines`.
  - `CAMP_BENEFITS` and the other constants.
  - `BuildNameSets()`, `CategoryOf(spellId, name)`.
- `GF.Flavor` (Data/Flavor.lua): `taglines`, `greetings`, `wipes`, `kills`, `deaths.{fire, falling, drowning, pvp, generic}`, `campPing`, `emptyStates`, `Fill(line, vars)`, `Random(list, vars)`.

---

## 3. UI kit (UI/Widgets.lua, UI/Theme.lua, UI/MainFrame.lua, UI/Toast.lua)

The window is a dark charcoal panel under a green Australian road sign. Pages live in the content area, which is about 800×560 at the default size and resizable, so **anchor to both edges and fill the height**.

### 3.1 Pages

```lua
UI:RegisterPage({ key = "softres", title = "Soft Res", subtitle = "Call dibs before the bin chickens do.",
                  icon = "dice", group = "raid", order = 20,
                  build = function(page) ... end,     -- once, lazily
                  onShow = function(page, arg) ... end,
                  onHide = function(page) end,
                  badge = function() return nil end, -- sidebar bubble (number or short string)
                  hidden = function() return false end })
UI:ShowPage(key, arg)  UI:OpenMain(key, arg)  UI:ToggleMain()  UI:RefreshPage(key)  UI:RefreshNav()  UI:CurrentPage()
```

- **Nav groups:** `street` (The Street), `raid` (Raid Nights), `community` (The Locals), `tools`.
- `UI:RefreshPage(key)` re-runs `onShow` only if that page is visible. Call it from your data-change handlers, and debounce.

### 3.2 Widgets

Read the header of UI/Widgets.lua. Summary:
- **Structure:** `UI:Panel`, `UI:Card(parent, {title, icon, accent, subtitle})` (use `card.body` and `card.right`), `UI:PageHeader(page, title, subtitle)` (`header:AddAction(btn)`).
- **Text and icons:** `UI:Text(parent, size, color, kind, flags)`, `UI:Icon`, `UI:SetIcon`.
- **Buttons:** `UI:Button(parent, text, {style = primary|secondary|ghost|danger|warn|sign, icon, width, height, onClick, tooltip})`, `UI:IconButton`.
- **Inputs:** `UI:Input`, `UI:Search`, `UI:Toggle`, `UI:Dropdown`, `UI:OpenMenu`.
- **Lists:** `UI:List(parent, {rowHeight, createRow, updateRow, onClick, isSelected})` (virtual), `UI:Scroll(parent)` → `scroll, content` (call `scroll:SetContentHeight(h)`).
- **Small parts:** `UI:Pill(parent, text, color, {icon})`, `UI:Bar(parent, {height, color, text})`, `UI:ItemButton(parent, size)` (`:SetItem(idOrLink)`; tooltip and shift-link built in), `UI:ClassIcon`, `UI:Avatar(parent, size)` (`:SetClass`), `UI:Tabs(parent, items, onSelect)`, `UI:Empty(parent, text, icon)`, `UI:Divider`.
- **Chat:** `UI:Whisper(name)` opens a whisper to that player, ready to type.
- **Modals:** `UI:Modal`, `UI:Confirm(title, text, onYes, yesText, style)`, `UI:Prompt(title, text, default, onAccept)`, `UI:CopyBox(title, text[, onImport])`.
- **Feedback:** `UI:Toast{title, text, icon, style = green|yellow|red|blue, duration, onClick, key}`, `UI:Tip(owner, title, lines)`, `UI:FadeIn`, `UI:Pulse`, `UI:Shadow`, `UI:EnableLinks(frame)`, `UI:InsertLink(link)`.

### 3.3 Theme (GF.Theme)

| Item | Values |
|---|---|
| Colours `T.c` | `bg0` (window), `bg1` (sidebar and header), `bg2` (cards), `bg3` (hover and inputs), `bg4`, `line`, `lineSoft`, `text`, `dim`, `faint`, `green` (neon accent), `greenDim`, `sign` (road-sign green), `yellow`, `yellowDim`, `red`, `redDim`, `pink`, `blue`, `blueDim`, `gold`, `purple` |
| Hex `T.hex` | `T:Wrap(colorName, s)` |
| Fonts `T.fonts` | `body` (FRIZQT), `head` (ARIALN; use it for headers, labels and numbers), `num`, `fancy`. Set them via `T:Font(fs, kind, size, flags)` or `UI:Text`. **Never SetText a FontString with no font** (it raises on Forever). |
| Textures `T.tex` | `white`, `glow`, `shadow`, `noise`, `hazard` (tileable yellow/black stripes), `bar`, `round6`, `round10`, `circle`, `pill`, `logo`, `welcome` (512×256 "Welcome to Greenfields" sign), `minimap`, `signGreen`, `signYellow`, `signRed`, `signBlue` (512×128 blank signs) |
| Icons `T.Icon(name)` | White 32px line icons, tinted with SetVertexColor. Pass the bare name to `UI:Icon` / `UI:SetIcon`. Available: `roster calendar dice check clipboard trophy hammer flame campfire eye gear close search chevron_down chevron_right chevron_left plus minus star star_fill crown skull coin sync bubble bell warning shield cross sword bow home filter trash megaphone clock lock export import heart bolt dot ring bag pin` |
| Game icons | Pass a full path (`"Interface\\Icons\\INV_Misc_Bag_10"`) or a fileID; they are trimmed automatically. |
| Roles `T.roles[role]` | `{label, icon, color}` for `tank`, `healer`, `melee`, `ranged`; order in `T.roleOrder` |
| Signup status `T.status[s]` | `{label, long, color, icon}` for `yes`, `late`, `maybe`, `bench`, `no`; order in `T.statusOrder` |

### 3.4 Visual quality bar ("it should look amazing")

**Layout and spacing**
- Every page starts with `UI:PageHeader`, puts its actions in the header via `header:AddAction`, and content goes in Cards.
- 16px gutters between cards; cards pad 12px.
- Use a two- or three-column layout where it reads well. Anchor columns to both edges so the page survives resizing.
- Row height: lists 28–36px, people rows 32–40px.

**Text**
- Section titles: uppercase `head` font.
- Body: sentence case.
- Names are always class-coloured.
- Numbers use the `head`/`num` font.

**Colour and icons**
- Use colour sparingly: green = good or primary, yellow = attention, red = bad.
- Icons are the media line icons. Game icons only for items, spells and professions.

**States and polish**
- Every list has an empty state with personality (`GF.Flavor.emptyStates` or your own line).
- Hover states on every interactive row. Tooltips explain anything non-obvious.
- No raw IDs or debug text on screen. Don't show anything the user can't act on.
- Keep the humour in subtitles, empty states, toasts and titles. Functional labels stay clear.

---

## 4. Testing

- **Syntax:** `tools\.venv\Scripts\python.exe tools\syntax_check.py`. It must report 0 problems for your files.
- **Harness:** a headless WoW-API mock harness is being built at `tools/harness/` (in parallel with the modules). Once it exists, `tools\.venv\Scripts\python.exe tools\harness\run.py` loads the whole addon into 3 simulated clients. Write code that a strict mock can run: real widget method names, real event names.

---

## 5. Cross-module public APIs (MUST implement exactly; other modules call these)

Every function must return safe defaults (an empty table, nil or 0) when there is no data, and must never error. Callers guard with `if GF.X and GF.X.Fn then`.

### GF.Raids (Modules/Raids*.lua)
- `GF.Raids:Upcoming(n)` → array of event docs, each with `.id`, sorted by `time` ascending. Includes events where `time > now - 3h`.
  - Fields: `{id, title, instance, size, time, duration, notes, leader, srLimit, created, lineup}`.
- `GF.Raids:Get(id)` → event doc (with `.id`) or nil.
- `GF.Raids:SignupsFor(id)` → array of `{player, char, class, role, status, note, t}`.
- `GF.Raids:MySignup(id)` → signup or nil.
- `GF.Raids:Lineup(id)` → `{groups = {[1] = {keys...}, ...}, bench = {keys...}}` or nil.
- `GF.Raids:Current()` → the event happening now (start − 30m to start + duration), or nil.
- `GF.Raids:SetSignup(eventId, status, role, note)` → ok, err. Signs the current player (or their main) up; `status` is one of `T.statusOrder`. Used by the Home dashboard's quick buttons.

### GF.SR (Modules/SoftRes*.lua)
- `GF.SR:ActiveSession()` → session doc (with `.id`) or nil.
- `GF.SR:ReservesFor(itemID)` → array of `{player, class, plus}` for the active session.
- `GF.SR:MyReserves()` → array of itemIDs in the active session.

### GF.Loot (Modules/Loot.lua)
- `GF.Loot:History(n)` → array, newest first: `{itemID, link, winner, t, instance, boss, how}`. `how` is `SR`, `MS`, `OS`, `ROLL` or `FREE`.
- `GF.Loot:CountFor(key)` → number of items awarded to that player (alts roll up to their main).
- `GF.Loot:SRWins(key)` → number of SR rolls won.

### GF.Attendance (Modules/Attendance.lua)
- `GF.Attendance:Percent(key, weeks)` → 0–100, or nil when there is no data. Alts roll up to their main.
- `GF.Attendance:Summary(key)` → `{attended, total, pct, streak, late, flakes, lastSeen}` or nil.
- `GF.Attendance:Raids(n)` → recent raid records, newest first.

### GF.Stats (Modules/Stats.lua, Modules/HallOfFame.lua)
- `GF.Stats:Value(key, statKey, scope)` → number. scope is `"all"` (default) or `"week"`.
- `GF.Stats:Leader(statKey, scope)` → `key, value`. For `rank` stats, the value is nil (amounts are never exposed).
- `GF.Stats:TitlesOf(key)` → array of title defs from GF.Titles that `key` currently holds (all-time), in catalogue order.
- `GF.Stats:Badges(key)` → array of `{stat, n, name}` milestone badges earned.

### GF.Profs (Modules/Professions.lua)
- `GF.Profs:CraftersOf(itemID)` → array of player keys that can craft an item with that output itemID.
- `GF.Profs:Skill(key, skillLine)` → rank, or 0.
- `GF.Profs:Recipes(key, skillLine)` → array of recipe spell IDs.

### GF.Buffs (Modules/Buffs*.lua)
- `GF.Buffs:Analyze(members)` → report.
  - `members` is an array of `{key, class, level}`.
  - Report: `{ cats = { [catKey] = { status = "class"|"camp"|"missing"|"na", providers = {keys}, camp = {keys} } }, plan = { fire = campfireKey, cook = key, assignments = { {player=, object=, buff=} } }, score = 0..100, missing = {catKeys}, notes = {strings} }`.
- `GF.Buffs:Providers(key)` → array of category keys that player can provide.

### GF.Feed (Modules/Feed.lua)
- `GF.Feed:Post(kind, text, opts)` broadcasts to the guild and records the post locally.
  - `kind` is one of: `level`, `loot`, `kill`, `wipe`, `title`, `badge`, `join`, `leave`, `death`, `camp`, `sr`, `raid`, `prof`, `misc`.
  - `opts`: `{icon, toast = bool, localOnly = bool, key = dedupeKey}`.
  - The text is plain and may contain item links and colour codes.
- `GF.Feed:Recent(n)` → array, newest first: `{kind, text, t, from, icon}`.

### GF.UI (Modules/Residents.lua)
- `GF.UI:OpenProfile(key)` opens the profile view for a player.
- The Residents agent implements it by registering a hidden page `profile` and calling `UI:ShowPage("profile", key)`.
