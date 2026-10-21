# Greenfields

The guild addon for **Greenfields** on WoW: Forever. Est. Mandurah, WA 6210.

Type `/gf` to open it, or click the green road sign on the minimap.

Everything is shared between guildies who run the addon, so get the whole street to install it. Stats, professions and buff info only exist for people running Greenfields.

---

## The pages

### The Street (home)
- What's on tonight, with your signup status and one-click Yeah / Maybe / Nah.
- Who wears the crowns right now.
- The latest gossip from the Watch, who's online, and a quick camp check for your group.

### Neighbourhood Watch
A guild news feed. It posts things like dings (10, 20 ... 60), epics looted, boss kills, titles changing hands, badges, new residents and 300 professions.

### Raid Nights
- **Officers:** create raids for Barrow Deeps (10), Hyjal Summit (20), Onyxia's Lair (40) or "Other". You can repeat them weekly.
- **Everyone:** sign up as **Yeah / Late / Maybe / Bench / Nah**, pick a role and character, and add a note.
- **Roster builder (officers):**
  - Click a signed-up player, then a group slot to place them.
  - **Auto-fill** balances roles for you.
  - A buff-coverage strip shows what that lineup will be missing.
- **Raid time:**
  - **Invite signed** invites everyone who said Yeah or Late.
  - **Apply groups** sorts the raid into your lineup.
  - **Post lineup** posts the groups to raid chat.
- You get reminders 30 and 5 minutes before raids you're signed up for.

### Soft Res
- The host (an officer or the raid lead) starts a session. Everyone reserves up to the limit, which defaults to 2.
- **Adding a reserve:** pick from loot the guild has seen drop, paste an item link or ID, or shift-click an item into the box.
- **Guildies without the addon:** whisper the host `!sr [item link]`.
- **Import / export:** softres.it-style CSV import and export.
- **+N:** how many weeks in a row someone has reserved the same item without winning it.
- **Loot time:**
  - In group loot you get a popup: "You SR'd this, smash NEED" or "X reserved it, pass".
  - The host gets a **Loot Desk**: announce, run SR / MS / OS rolls, see live rolls, award.

### Loot Log
Who got what, how (SR / MS / OS / roll) and from which boss, plus a **Bin Chicken Watch** leaderboard.

### Roll Call (attendance)
- Recorded automatically when the guild raids. The raid leader's addon records; if the leader doesn't run it, an officer's does.
- Snapshots are taken every 5 minutes and after every boss.
- Tracks attendance %, streaks, late arrivals (15+ minutes after the start time) and flakes (said Yeah, never showed).
- Officers can mark bench players, who count as attended.
- CSV export.

### Hall of Fame (and Shame)
32 titles that change hands as the numbers move. The current leader wears the title; check the "This week" tab too. Some highlights:

| Title | Awarded for |
|---|---|
| **Stands In Fire** | most raid deaths |
| **Bin Chicken** | biggest loot whore |
| **Mandurah Millionaire** / **Centrelink's Favourite** | richest / poorest. Only the order is shown, never the amount, and you can opt out in Settings. |
| **Eshay Brah** | most PvP killing blows |
| **Gravity Tester** | deaths from falling |
| **Opening Act** | first to die on a wipe |
| **Durry Break Champion** | most time AFK |
| **Skippy** | most jumps |
| **Ride Or Die** | best attendance |
| **Said Yeah, Meant Nah** | most flakes |
| **Chemist Warehouse Loyalty Card** | potions and flasks drunk |

The rest include **Uber Eats Driver**, **Mummy's Boy**, **Absolutely Rotten**, **Blue Manna Crabber** and **Happy Camper**.

Every stat also has milestone badges.

### Residents
- The guild roster: mains and alts, who's online, rank, titles, attendance, professions, and who runs the addon.
- Click anyone to open their **resident file**: titles, badges, stats, roll call, trades, loot and the buffs they bring.

### Tradies (professions)
- Search "who can make X?" across the whole guild and whisper them in one click.
- Also shows everyone's profession levels and transmute / Mooncloth cooldowns.
- Open each of your profession windows once so your recipes get shared.

### Buff Check
- Shows which raid buffs your group has and which it's missing.
- For each missing buff it works out **who should drop which camp object**, which campfire tier you need, and who should cook it.
  - Example: with one paladin, the paladin does Might and Wisdom, and someone with Fishing drops a Fish Bowl for Kings.
- **Ping** buttons pop a road sign on that person's screen telling them to get their object down.
- A live scan shows who is actually missing what. It only works out of combat, because Forever hides buffs from addons in combat.
- Camp objects can't go down inside instances, so set up camp at the raid entrance.

---

## Updating
WoW won't let addons update themselves, so use the **Greenfields Updater**. It's in `GreenfieldsUpdater.zip` on the release page; your officers will send it to you.

1. Unblock the zip: right-click > Properties > Unblock.
2. Unzip it somewhere permanent.
3. Double-click **Update Greenfields**. It finds WoW, downloads the latest release, checks it's genuine, and installs it.

**Turn On Auto Updates** keeps it current in the background: it checks at login and every 6 hours. **Turn Off Auto Updates** stops it.

In game, a yellow **UPDATE** pill and a toast appear when a guildie is running a newer version. After you update, type `/reload` and you'll get a "What's new" popup.

## Slash commands
| Command | What it does |
|---|---|
| `/gf` | open / close |
| `/gf show <page>` | open a page (home, raids, softres, loot, attendance, fame, roster, tradies, buffs, feed, settings) |
| `/gf profile <name>` | open someone's resident file |
| `/gf main <name>` | mark this character as an alt of `<name>` (blank = this is a main) |
| `/gf sync` | force a data sync with guildies |
| `/gf stats` | print your own stats |
| `/gf doctor` | check what this game client supports (run this on launch day) |
| `/gf update` | is there a newer Greenfields, and how to get it |
| `/gf changelog` | what changed in each version |
| `/gf errors` | list any Lua errors the addon caught |
| `/gf comm` | addon-message diagnostics |
| `/gf reset` | reset the window position |
| `/gf servo`, `/gf roast <name>`, `/gf yeahnah` | you'll see |

## Limits worth knowing
- **No damage, healing or fire-damage meters.** Forever blocks addons from reading the combat log, so "stands in fire" is measured by raid deaths.
- **Self-reported.** Stats, professions and buff abilities only exist for people running Greenfields.
- **Not yet verifiable:**
  - Master loot handover: the Loot Desk feature-detects it, and without it the desk announces and records instead.
  - Camp buffs inside raids.
  - Raid lockouts.
  These depend on Forever details that weren't public before launch. Run `/gf doctor` once raids open on Dec 9.
- **Secret values.** In combat and boss encounters the game hides some info from addons, such as names and buffs. Greenfields waits until combat ends rather than guessing.
