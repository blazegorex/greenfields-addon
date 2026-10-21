# Releasing Greenfields (and how guildies get updates)

## How updating works

WoW addons can't download or write files, so updates arrive from outside the game.

```
 you (tools/release.py --publish)            GitHub release (the one trust root)
   checks -> zip -> sha256 -> manifest  --->   Greenfields-x.y.z.zip
                                               latest.json  (version, url, sha256, notes)
                                               GreenfieldsUpdater.zip / .ps1
                                                        |
 guildie's PC:  "Update Greenfields"  <-----------------+  (or automatically every 6h)
                finds WoW -> compares versions -> downloads -> verifies SHA-256 ->
                backs up -> installs into _forever_ -> "/reload in game"

 in game:  guildies running the new version say so in their HELLO; everyone older
           gets a yellow UPDATE pill + toast, and "What's new" after they update.
```

Addon apps work too: anyone using WowUp can track the GitHub repo, which has `release.json` in it. CurseForge would need a separate (public) project.

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
   5. packages the files;
   6. commits, tags and pushes;
   7. creates the GitHub release and uploads `latest.json` last, so updaters never see a half-uploaded release.
3. Tell the guild: "New Greenfields is out, run Update Greenfields and /reload." The in-game pill tells everyone else as soon as one updated guildie logs in.

| Kind of change | Command |
|---|---|
| Bug fix | `--bump patch` (1.0.1 → 1.0.2) |
| New feature | `--bump minor` (1.0.2 → 1.1.0) |
| Packages only, nothing published | omit `--publish`; files land in `dist/<version>/` |
| Re-package the current version | `--rebuild` |
| Finish a release that stopped half way (e.g. the network dropped during upload) | `--rebuild --publish`: reuses the existing tag and release |
| Add a release note from the command line | `--note "..."` (repeatable; adds to the Unreleased notes, doesn't replace them) |

If anything fails before the release commit, the version bump, the CHANGELOG and Changelog.lua are restored exactly as they were, so you can fix the problem and run the same command again.

## First-time install for a guildie

Send them `GreenfieldsUpdater.zip` from the latest release page. Then they:
1. right-click the zip > Properties > Unblock (Windows tags internet downloads);
2. unzip it somewhere permanent;
3. double-click **Update Greenfields**. It installs the addon.

Optional: double-click **Turn On Auto Updates**. It checks at Windows login and every 6 hours, quietly.
- It runs from its own copy in `%LOCALAPPDATA%\GreenfieldsUpdater\app`, so tidying away the unzipped folder doesn't break it.
- To stop it, double-click **Turn Off Auto Updates**.

## If a release is bad

- **Fastest fix:** ship a new patch with the fix. Every updater picks it up within 6 hours, or immediately when run by hand.
- **Rolling back a single PC:** the updater keeps the last 3 installs per WoW folder in `%LOCALAPPDATA%\GreenfieldsUpdater\backup\<flavor>\`. Copy one back into `World of Warcraft\_forever_\Interface\AddOns\Greenfields`.
- **Pulling a release:** delete it on GitHub. `releases/latest` then points at the previous one. Anyone already on the bad version stays on it until a newer one ships, because updaters only ever move forward.

## Security notes

- The updater only accepts `https://` addresses from its `updater.json`. Local paths are allowed only when passed on the command line, for testing.
- Every download must match the SHA-256 in the release manifest. A mismatch changes nothing.
- The zip is extracted entry by entry and anything outside a single `Greenfields/` folder is refused, so a crafted zip can't write elsewhere on disk.
- Nothing downloaded is ever run, except the updater's own `.ps1`. That only happens through self-update, which is hash-checked against the same manifest.
- Whoever controls the GitHub repo controls what guildies install. Keep that account protected with two-factor authentication.
