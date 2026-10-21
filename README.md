# Greenfields

The guild addon for **Greenfields** on WoW: Forever. Est. Mandurah, WA 6210.

Rostering and raid signups, soft reserves with a loot desk, attendance, a Hall of Fame (and Shame) with 32 titles, a guild profession browser, a raid buff and camp planner, and the Neighbourhood Watch feed.

## Install (guildies)

1. Download **`GreenfieldsUpdater.zip`** from the [latest release](https://github.com/blazegorex/greenfields-addon/releases/latest).
2. Unblock the zip: right-click it > Properties > tick **Unblock** > OK. Then right-click > **Extract All**.
3. Double-click **Update Greenfields**. It finds WoW, downloads the latest version, checks it's genuine and installs it.
4. Optional: double-click **Turn On Auto Updates** to have it check quietly at login and every 6 hours.

In game, type `/gf`. The full guide is in [Greenfields/README.md](Greenfields/README.md).

Using an addon manager instead? WowUp can track this repo, or you can download `Greenfields-x.y.z.zip` from the release and unzip it into `World of Warcraft\_forever_\Interface\AddOns`.

## For maintainers

- `Greenfields/` is the addon.
- `updater/` is the guild's Windows updater.
- `tools/` holds:
  - the release script
  - the headless WoW test harness
  - the syntax check
  - the media generators
- `docs/` has the Forever API fact sheet, the module contract and [RELEASING.md](docs/RELEASING.md).

To ship a fix, add a line to `CHANGELOG.md`, then run:

```
python tools/release.py --bump patch --publish
```
