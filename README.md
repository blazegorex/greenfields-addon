# Greenfields

The guild addon for **Greenfields** on WoW: Forever. Est. Mandurah, WA 6210.

Rostering and raid signups, soft reserves with a loot desk, attendance, a Hall of Fame (and Shame) with 32 titles, Most Wanted (posters and bounties on the Alliance who do us over), a guild profession browser, a raid buff and camp planner, and the Neighbourhood Watch feed.

## Install (guildies)

1. Download **[`GreenfieldsSetup.msi`](https://github.com/blazegorex/greenfields-addon/releases/latest/download/GreenfieldsSetup.msi)** and double-click it.
2. If Windows says "Windows protected your PC", click **More info**, then **Run anyway**. It isn't signed.
3. Click **Next**, check the WoW folder it found, and click **Install**. Leave the updater and auto updates ticked to get new versions by themselves.

No installer? Download **`GreenfieldsUpdater.zip`** from the [latest release](https://github.com/blazegorex/greenfields-addon/releases/latest), unblock it (right-click > Properties > **Unblock**), **Extract All**, then double-click **Update Greenfields**. **Turn On Auto Updates** has it check quietly at login and every 6 hours.

In game, type `/gf`. The full guide is in [Greenfields/README.md](Greenfields/README.md).

Using an addon manager instead? WowUp can track this repo, or you can download `Greenfields-x.y.z.zip` from the release and unzip it into `World of Warcraft\_forever_\Interface\AddOns`.

## For maintainers

- `Greenfields/` is the addon.
- `updater/` is the guild's Windows updater.
- `installer/` is the Windows installer (`GreenfieldsSetup.msi`); build it with `python tools/build_msi.py` (see [installer/README.md](installer/README.md)).
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
