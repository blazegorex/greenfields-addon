@echo off
rem Stops the automatic Greenfields update checks (Greenfields itself stays installed).
rem No ( ) blocks below on purpose: folder names like "Program Files (x86)" would break them.
setlocal
set "GF_SCRIPT=%~dp0GreenfieldsUpdater.ps1"
if not exist "%GF_SCRIPT%" goto missing
set "GREENFIELDS_UPDATER_CMD=1"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%GF_SCRIPT%" -RemoveSchedule
set "GF_EXIT=%ERRORLEVEL%"
echo.
pause
exit /b %GF_EXIT%

:missing
echo.
echo   GreenfieldsUpdater.ps1 isn't next to this file.
echo   Unzip the whole GreenfieldsUpdater.zip first - right-click it, Extract All -
echo   then double-click "Turn Off Auto Updates" in the extracted folder.
echo.
pause
exit /b 1
