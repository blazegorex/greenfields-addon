# The Greenfields installer (GreenfieldsSetup.msi)

A Windows installer for guildies who'd rather not unzip things. Double-click it, click **Next**, check the WoW folder it found, click **Install**.

What it does:

- **Finds WoW by itself.** It looks in this order:
  1. the folder it installed into last time;
  2. the updater's own saved folder;
  3. Blizzard's registry keys;
  4. Battle.net's install list (`C:\ProgramData\Battle.net\Agent\product.db`);
  5. the usual spots on every fixed drive, starting with `C:\Program Files (x86)\World of Warcraft`.

  It prefers a folder that has `_forever_`. If it finds nothing, **Browse...** lets the player pick the folder. Picking `_forever_`, `Interface`, `AddOns` or `Greenfields` by mistake is forgiven.
- **Installs the addon** into `_forever_\Interface\AddOns\Greenfields`, laid out exactly as in `Greenfields.zip`. The old Greenfields folder is emptied first, so no stale file from an older version survives.
- **Optionally installs the updater** into `%LOCALAPPDATA%\GreenfieldsUpdater\app` (the folder its auto-update task already uses), with a Start menu shortcut **Update Greenfields**. If **Turn on auto updates** is ticked, it runs the updater with `-InstallSchedule`, exactly as *Turn On Auto Updates* does.
- **Won't start while WoW or a File Explorer window has the folder.** It checks before touching anything, and says "Close WoW and any Explorer windows showing the Greenfields folder, then click Try again." Only a WoW started from *that* WoW folder counts.
- **Uninstalling** (Settings > Apps, or running the installer again > Remove) removes the addon folder and, if it was installed, the updater, its auto-update task and `%LOCALAPPDATA%\GreenfieldsUpdater`. It never touches `WTF` (SavedVariables) or any other addon.
- **Per-user:** no admin prompt. Blizzard gives every user full control of the WoW folder.
- **Running a newer installer** replaces the older install and keeps the same folder and choices. Running the same one again offers **Reinstall** or **Remove**. An older one says a newer Greenfields is already there.

It isn't signed, so Windows SmartScreen warns the first time: **More info**, then **Run anyway**.

## Building it

One-time: install the .NET SDK (6 or newer; WiX itself comes from NuGet on the first build, nothing else to install):

```
winget install Microsoft.DotNet.SDK.8
```

Then, from the repo folder:

```
python tools/build_msi.py
```

It writes `dist/<version>/GreenfieldsSetup.msi`. `tools/release.py` builds it as part of every release and uploads it with the other files (`--no-msi` skips it). Build files go in `dist/_msi_build/`.

- `--version 1.2.2 --out <folder>` builds a test installer with another version number, for trying upgrades. Greenfields.toc stays as it is.
- The toolchain is WiX v5 (`WixToolset.Sdk/5.0.2`) through `dotnet build`. WiX v6 and later need a paid-licence EULA accepted, so stay on v5.

## What's where

| File | What it is |
|---|---|
| `Strings.wxl` | **Every word players read.** Edit, then rebuild. |
| `Package.wxs` | What goes where, the remembered choices, and when the custom actions run |
| `UI.wxs` | The dialogs: positions, fonts, colours, which art each page uses |
| `GreenfieldsCA/CustomActions.cs` | Finding WoW, the "is anything holding the folder" check, auto updates on/off, removing the updater's data |
| `art/` | `crest.ico` plus the dialog backgrounds, made by `python -P tools/make_msi_art.py` from `tools/art/pixel/` |

## Gotchas

- **Text colour:** Windows Installer draws text black if its colour is close to the plain dialog grey (240,240,240). 244,239,227 came out black, so light text stays at 236,231,219 or pure white.
- **Icons:** the `.ico` frames must be plain bitmaps, PNG only at 256 px. `make_msi_art.py` writes them that way, because Pillow's own `.ico` writer makes every frame PNG and Windows Installer can't read those.
- **Dialog size:** 370 x 270 dialog units is 493 x 360 pixels at 100% scaling. The art is made at exactly that size, so the pixel art stays 1:1.
- **Screenshots:** a background capture (`PrintWindow`) sometimes misses see-through text that's really on screen. Wait a moment and force a repaint before capturing.

## Testing without touching the real WoW folder

Point it at a fake folder and stop it searching the PC:

```
msiexec /i dist\1.2.1\GreenfieldsSetup.msi WOWDIR="C:\temp\fakewow\World of Warcraft" GF_NOSEARCH=1 /l*v install.log
```

- A fake WoW folder needs a `_forever_` folder.
- To fake "WoW is running", copy any long-running exe into it as `_forever_\Wow.exe` and start it.
- Silent options: `/qn`, `INSTALL_UPDATER=0`, `AUTOUPDATE=0`.
- Silent uninstall: `msiexec /x GreenfieldsSetup.msi /qn`.
- Installing with the updater ticked writes to the real `%LOCALAPPDATA%\GreenfieldsUpdater` and creates the real "Greenfields Updater" task, and uninstalling deletes them. Back that folder up first on a PC that uses the updater.
