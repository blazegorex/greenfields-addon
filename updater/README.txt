GREENFIELDS UPDATER
===================

Installs the Greenfields guild addon and keeps it up to date.

1. Right-click GreenfieldsUpdater.zip > Properties > tick "Unblock" if you see it > OK.
   Then right-click it > Extract All. Don't run it from inside the zip: it needs all its files.
2. Open the extracted folder and double-click "Update Greenfields". It finds World of Warcraft,
   downloads the latest Greenfields, checks it's the genuine release (SHA-256), and installs it.
   If Windows says "Windows protected your PC", click "More info" > "Run anyway".
   If it can't find WoW, a window opens: pick your "World of Warcraft" folder.
3. Want it hands-free? Double-click "Turn On Auto Updates" once. It then checks quietly when you
   log in to Windows and every 6 hours (a window may flash up for a moment).
   It keeps its own copy in %LOCALAPPDATA%\GreenfieldsUpdater, so this folder can be tidied away.
   To stop it: double-click "Turn Off Auto Updates".

In game, Greenfields tells you when a guildie has a newer version (yellow UPDATE pill and a
toast). Run the updater, then type /reload.

Trouble?
- "Windows won't let the updater write to ...": right-click "Update Greenfields" >
  Run as administrator.
- "... is in use": close WoW, then run "Update Greenfields" again.
- Picked the wrong WoW folder? Open a Command Prompt in this folder and run:
      "Update Greenfields.cmd" -WowPath "D:\Games\World of Warcraft"
- Something broke? Your last 3 versions are kept in %LOCALAPPDATA%\GreenfieldsUpdater\backup
  and the log is %LOCALAPPDATA%\GreenfieldsUpdater\update.log (send it to your officer).
