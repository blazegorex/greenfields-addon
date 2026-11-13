# Releasing Greenfields (and how guildies get updates)

## How updating works

WoW addons can't download or write files, so updates arrive from outside the game.

```
 you (tools/release.py --publish)            GitHub release (the one trust root)
   checks -> zip -> sha256 -> manifest  --->   Greenfields-x.y.z.zip
                                               Greenfields.zip  (same bytes, a name that never changes)
                                               latest.json  (version, url, sha256, notes)
                                               GreenfieldsUpdater.zip / .ps1
                                               GreenfieldsSetup.msi  (first install, Windows)
                                                        |
 guildie's PC:  "Update Greenfields"  <-----------------+  (or automatically every 6h)
                finds WoW -> compares versions -> downloads -> verifies SHA-256 ->
                backs up -> installs into _forever_ -> "restart WoW"

 in game:  guildies running the new version say so in their HELLO; everyone older
           gets a yellow UPDATE pill + toast, and "What's new" after they update.
```

Addon apps should work too: every release has a `release.json` attached, pointing WowUp at the versioned zip for both the `forever` and `mainline` flavours, so someone can track the GitHub repo. Nobody has tried it yet. CurseForge would need a separate (public) project.

## One-time setup

1. **Pick a permanent folder for the project** (not the temp scratch folder) and make it a git repo.
2. **Create a GitHub repo**, e.g. `greenfields-addon`.
   - Public is simplest: the updater can download releases without a login.
   - Private repos would need every guildie to hold a token, so don't.
3. Put the repo name in `tools/release_config.json`: `{ "repo": "yourname/greenfields-addon" }`.
4. **Create a fine-grained GitHub token:**
   - Settings > Developer settings > Fine-grained tokens.
   - Scope: only this repo. Permissions: Contents = Read and write.
   - Store it as the `GITHUB_TOKEN` environment variable. Never commit it.
5. Push the source once: `git remote add origin https://github.com/yourname/greenfields-addon.git`, then `git push -u origin main`.
6. **Install the .NET SDK** once, for the Windows installer (`GreenfieldsSetup.msi`): `winget install Microsoft.DotNet.SDK.8`. Everything else it needs downloads by itself on the first build. See `installer/README.md`.

## Shipping a fix

1. Fix the bug, then add a line under `## Unreleased` in `CHANGELOG.md`, for example: `- Fixed SR popup not showing for pugs.`
2. Release:
   ```
   python tools/release.py --bump patch --publish
   ```
   This does the following, in order:
   1. bumps the version in the TOC;
   2. moves the Unreleased notes under the new version;
   3. regenerates the in-game changelog;
   4. runs the syntax check and the full headless harness (any failure stops the release);
   5. packages the files, including the Windows installer `GreenfieldsSetup.msi`;
   6. commits, tags and pushes;
   7. creates the GitHub release and uploads `latest.json` last, so updaters never see a half-uploaded release.
3. Tell the guild: "New Greenfields is out, run Update Greenfields and restart WoW." A /reload may not find brand-new art files. The in-game pill tells everyone else as soon as one updated guildie logs in.

| Kind of change | Command |
|---|---|
| Bug fix | `--bump patch` (1.0.1 → 1.0.2) |
| New feature | `--bump minor` (1.0.2 → 1.1.0) |
| Packages only, nothing published | omit `--publish`; files land in `dist/<version>/` |
| Re-package the current version | `--rebuild` |
| Finish a release that stopped half way (e.g. the network dropped during upload) | `--rebuild --publish`: reuses the existing tag and release |
| Add a release note from the command line | `--note "..."` (repeatable; adds to the Unreleased notes, doesn't replace them) |
| Release without the Windows installer (no .NET SDK on this PC) | `--no-msi` |
| Build just the installer | `python tools/build_msi.py` (into `dist/<version>/`) |

`release.py` refuses any version at or below the highest git tag, including one that's only on GitHub. `--rebuild` can meet the highest tag, because that's how a half-finished release gets finished, but it can't go below it.

If anything fails before the release commit, the version bump, the CHANGELOG and Changelog.lua are restored exactly as they were, so you can fix the problem and run the same command again.

The push uses your saved git login, not the token, which only does the GitHub release. If the push fails after the commit, `release.py` says to rerun with `--rebuild --publish`.

## First-time install for a guildie

In game, `/gf install` gives anyone the links and a ready-made Discord post to copy, even on a character the guild lock has shut. The links never change, because they point at whichever release is latest:

- Windows: `https://github.com/blazegorex/greenfields-addon/releases/latest/download/GreenfieldsUpdater.zip`
- Mac, or by hand: `https://github.com/blazegorex/greenfields-addon/releases/latest/download/Greenfields.zip`

If the repo ever moves, change `REPO` at the top of `Greenfields/Core/Update.lua`. The harness fails if it stops matching `tools/release_config.json`.

**On Windows, the easy way,** send them the installer: `https://github.com/blazegorex/greenfields-addon/releases/latest/download/GreenfieldsSetup.msi`. They:
1. download it and double-click it;
2. if Windows says "Windows protected your PC", click **More info**, then **Run anyway** (it isn't signed);
3. click **Next**, check the WoW folder it found (or **Browse...** to it), and click **Install**.

It can also install the updater, with **Update Greenfields** in the Start menu and auto updates. Uninstalling it from Settings > Apps leaves their settings (the `WTF` folder) alone. `/gf install` doesn't mention the installer yet.

**On Windows, without the installer,** send them `GreenfieldsUpdater.zip`. Then they:
1. right-click the zip > Properties > Unblock (Windows tags internet downloads);
2. unzip it somewhere permanent;
3. double-click **Update Greenfields**. It installs the addon.

Optional: double-click **Turn On Auto Updates**. It checks at Windows login and every 6 hours, quietly.
- It runs from its own copy in `%LOCALAPPDATA%\GreenfieldsUpdater\app`, so tidying away the unzipped folder doesn't break it.
- To stop it, double-click **Turn Off Auto Updates**.

**On a Mac,** the updater won't run, so they do it by hand each time:
1. download `Greenfields.zip`, which the Mac unzips into a `Greenfields` folder;
2. drag that folder into `World of Warcraft/_forever_/Interface/AddOns`, replacing the old one;
3. quit and reopen WoW.

No Mac has tried this yet.

## If a release is bad

**Never delete a release, and always ship a higher version.**

- Updaters only move forward. Deleting a release doesn't take the bad version off anyone's PC, so they sit on it until something newer ships.
- The rollback below needs the old releases to still be there, and so do the links in anything already shared.
- A panicked revert under a lower number can end up as "latest" and reaches nobody. `release.py` refuses to do it.

**To undo a bad release for everyone:** ship a higher version, either with the fix or with the old code put back.

```
python tools/release.py --bump patch --publish
```

Every updater picks it up within 6 hours, or straight away when run by hand. Then tell the guild outside the game. Rollback doesn't undo data the bad version has already shared around.

**To roll back one PC while you sort it out:** `-Force` installs a release whatever version is there now, older ones included. From a Command Prompt in the updater's folder, naming the good version:

```
"Update Greenfields.cmd" -Force -ManifestUrl https://github.com/blazegorex/greenfields-addon/releases/download/v1.2.3/latest.json
```

- **Not tried on a real release yet.** It's only been run against a local manifest and zip, so try the command above once on your own PC after Release 1 is up, before you need it in a hurry.
- Run **Turn Off Auto Updates** first, or that PC moves back up to the bad version within 6 hours. Turn it back on once the fixed version is out.
- With no `-ManifestUrl`, `-Force` just reinstalls the latest, which fixes a damaged install and nothing else.
- **On a Mac, or without the updater:** download `Greenfields-1.2.3.zip` from that release page and install it by hand.
- The updater also keeps the last 3 installs per WoW folder in `%LOCALAPPDATA%\GreenfieldsUpdater\backup\<flavor>\`. Copying one back into `World of Warcraft\_forever_\Interface\AddOns\Greenfields` works too.

## Security notes

- The updater only accepts `https://` addresses from its `updater.json`. Local paths are allowed only when passed on the command line, for testing.
- Every download must match the SHA-256 in the release manifest. A mismatch changes nothing.
- The zip is extracted entry by entry and anything outside a single `Greenfields/` folder is refused, so a crafted zip can't write elsewhere on disk.
- Nothing downloaded is ever run, except the updater's own `.ps1`. That only happens through self-update, which is hash-checked against the same manifest.
- Whoever controls the GitHub repo controls what guildies install. Keep that account protected with two-factor authentication.

## The guild lock

`Greenfields/Core/Gate.lua` shuts the addon for characters outside the guild, starting when Forever goes live. Any guild with "greenfield" in its name counts, ignoring capitals and spaces, so "The Greenfields", "Green Fields WA" and "Greenfield" all work.

- **If the guild ends up with a name that doesn't contain that word:** change `OURS` at the top of that file and ship a patch. The updater runs outside the game, so the lock can't stop anyone getting the fix. A shut copy can't hear about the patch in game, so tell people outside the game to run the updater. It only edits an existing file, so a `/reload` is enough.
- **To check it:** `/gf gate` says whether it's open and which guild it sees. `/gf gate test` shows what people outside the guild get, and running it again opens it back up.
- **What it isn't:** a real lock. Blizzard's addon policy says code can't be hidden, the repo is public, and older releases don't have the check, so anyone handy can get around it. It stops casual use of a copy that gets passed around.
