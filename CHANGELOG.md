# Greenfields changelog

Add notes under **Unreleased** as you go; `tools/release.py` moves them under the new version.

## Unreleased

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
