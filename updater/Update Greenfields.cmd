@echo off
rem Greenfields Updater - double-click to install or update the Greenfields WoW addon.
rem Extra options are passed through, e.g.:  "Update Greenfields.cmd" -WowPath "D:\Games\World of Warcraft"
rem No ( ) blocks below on purpose: folder names like "Program Files (x86)" would break them.
setlocal
set "GF_SCRIPT=%~dp0GreenfieldsUpdater.ps1"
if not exist "%GF_SCRIPT%" goto missing
rem We pause here instead of the updater, so even PowerShell failing to start stays on screen.
set "GREENFIELDS_UPDATER_CMD=1"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%GF_SCRIPT%" %*
set "GF_EXIT=%ERRORLEVEL%"
echo.
pause
exit /b %GF_EXIT%

:missing
echo.
echo   GreenfieldsUpdater.ps1 isn't next to this file.
echo   Unzip the whole GreenfieldsUpdater.zip first - right-click it, Extract All -
echo   then double-click "Update Greenfields" in the extracted folder.
echo.
pause
exit /b 1
