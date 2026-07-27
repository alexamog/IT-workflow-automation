@echo off
REM Double-click me to launch Desk Side Toolkit.
REM This just runs Start-DeskSide.ps1 with the right PowerShell options so you
REM never have to fiddle with execution policy. It updates from the shared drive
REM (if reachable) and then opens the menu.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-DeskSide.ps1"
