# Greenfields changelog

Add notes under **Unreleased** as you go; `tools/release.py` moves them under the new version. The in-game What's new shows the first 12 notes of a version, so merge rather than go over: the harness fails if you do.

## Unreleased

## 1.2.1 - 2026-11-03

- Pixel-art street: every page banner, all 32 Hall of Fame portraits, the crest and the minimap button are redrawn as pixel art. The window, signs and menus stay as they were.
- Small touches: buttons and the sidebar light up and fade smoothly, Soft Res and Roll Call glow when they want you, saying Yeah gets a green burst, and crowns and boss kills go off in gold on their sign.
- The soft-res sign's item name is easier to read (an epic's purple was lost on the green), and the 25-deaths badge is now Graveyard Regular, so Frequent Flyer only means flight paths.

## 1.2.0 - 2026-11-02

- New look, after dark: a new painted night on every page and a new crest, and the art and the jokes moved closer to where we actually came from. Three titles got new names to match: Been Up Since Tuesday, Loot Fiend and On The Gear.
- Residents only: from the moment Forever goes live, Greenfields only runs for characters in the Greenfields guild. On any other character it stays quiet and the window says why. It opens by itself when you join, with nothing to reload. It also only listens to people who've been on the guild roster, and only hands guild data to people on it.
- The richest and poorest boards now share a much rougher score. The amount stays hidden on screen, and the score only gives your gold away to within about double. Same-band ties go by name.
- First login on a character prints three lines on what the addon needs from you: open your profession windows, set a main, and how the wealth boards work.
- Who's Home now lists people near your level first, then people in your zone. Right-click anyone on it for the full menu, including invite.
- New installs learn who has the addon within seconds, not half an hour: hello replies now reach people. Invites now go to the full name, and Invite the signed says invites are on the way, not that anyone's in.
- Opening the world map no longer counts as an emote, one death can't count twice, and the weekly boards turn over at the same moment for everyone: Wednesday midnight in Mandurah.
- Crown changes now go in the Watch without a sign, and a crown takes a small score to claim, so launch night doesn't hand them round for one jump. Parties under 60 aren't marked out of 100 any more, and buffs nobody can learn yet don't count as missing. Raids are graded as before.
- Two guildies with the same first name: the addon can't tell them apart, so that name gets no officer or GM rights, whispers or invites until one of them's gone. The GM gets told in chat and `/gf doctor` warns about it.
- New `/gf install`: the download links and a post to paste in Discord, for getting a mate set up. It works on any character, and the links always get the newest version. On a Mac, or don't want the updater? `/gf update` and the README now have steps for doing it by hand.
- New `/gf report`: errors now survive a /reload, and it puts them in a box with everything else Spencer needs, ready to copy and paste. `/gf doctor` no longer gives up halfway and answers more questions, and new `/gf mic` posts one test line to your group and reads one /roll back.
- Smaller things: jokes go through the whole pile before repeating, even across logins, and the Watch's loot, moving-in and moving-out reports have a few lines each. Roll call no longer sticks on "still loading" after being kicked and reinvited. The addon keeps working if Blizzard renames the client, and through the next small patch (1.60.2).

## 1.1.2 - 2026-10-22

- Sidebar back to the clean line icons (gold for the page you're on): the painted pictures were too loud for a menu. The painted art stays on the page banners, header, crest and Hall of Fame.

## 1.1.1 - 2026-10-22

- Bigger sidebar icons: the menu rows now grow to fill the sidebar (icons up to 34px, sharper textures), shrinking only when the window is small.
- Fixed the changelog / What's New box not fitting its text (it measured the text before the box had a width, so the words could spill out past the edges).

## 1.1.0 - 2026-10-22

- Painted art everywhere: a hand-painted banner for every page, a Mandurah-at-dusk header, 32 custom Hall of Fame/Shame title portraits (Stands In Fire, Durry Break Champion, the loot-raiding ibis and the rest), new sidebar icons, and the Greenfields crest on the window, minimap button and addon list.

## 1.0.4 - 2026-10-21

- Fixed "No player named ... is currently playing" spam in chat: Forever needs the full "Name Surname" to whisper someone, so the addon's whispers (sync, `!sr` replies, camp pings and the Whisper buttons) now use it, skip offline guildies, and quietly hide any bounce from the addon's own whispers.

## 1.0.3 - 2026-10-21

- Fixed guild syncing on WoW Forever: the guild roster names people with their surname ("Kaghul Doomskull") but addon messages don't ("Kaghul"), so guildies' professions, stats and profiles were being ignored.

## 1.0.2 - 2026-10-21

- /gf doctor now reports guild and sync details (how the game names addon senders, which guildies' data arrived or was ignored) to track down profession sync.

## 1.0.1 - 2026-10-21

- Built-in update checks: a yellow UPDATE pill and toast when a guildie runs a newer version, /gf update, and a "What's new" popup after updating.
- Wider sidebar so long page names no longer clip.
- Warcraft makeover: gold-framed window with ornate corners, leather and slate textures, Morpheus and Friz Quadrata fonts in game gold, gold-rimmed buttons, and real game icons in the sidebar.
- Hall of Fame titles now look like achievements: framed title art, a shine on hover, and gems on the titles you hold.
- Framed icons and bronze-rimmed panels across Buff Check, Tradies, Raid Nights, Roll Call, Soft Res and the Loot Desk.

## 1.0.0 - 2026-10-21

- First release. Welcome to the neighbourhood.
