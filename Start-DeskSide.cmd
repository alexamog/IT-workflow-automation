@echo off
REM ===========================================================================
REM  Desk Side Toolkit - double-click this file.
REM
REM  This is the only file anyone needs to run. It handles the three things that
REM  normally stop a PowerShell script working on a fresh machine:
REM
REM    1. Execution policy blocking scripts       -> -ExecutionPolicy Bypass
REM    2. The "downloaded from another computer"  -> Unblock-File on the scripts
REM       mark Windows puts on files out of a zip
REM    3. The window vanishing before an error    -> pause when it exits badly
REM       can be read
REM
REM  One PowerShell start, not two: launching PowerShell is the slow part, so
REM  the unblock and the menu run in the same session. The unblock skips .git
REM  and output\ - nothing there is executed, and .git can hold thousands of
REM  files on an older copy.
REM ===========================================================================

title Desk Side Toolkit

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
 "Get-ChildItem -Path '%~dp0' -Recurse -Include *.ps1,*.psd1,*.cmd -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\(\.git|output)\\' } | Unblock-File -ErrorAction SilentlyContinue; & '%~dp0AD-Toolkit.ps1'"

REM A non-zero exit means it stopped on an error rather than the user quitting.
if errorlevel 1 (
    echo.
    echo ---------------------------------------------------------------
    echo  The toolkit stopped unexpectedly. The message above says why.
    echo ---------------------------------------------------------------
    echo.
    pause
)
