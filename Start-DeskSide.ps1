<#
.SYNOPSIS
    Launch Desk Side Toolkit, pulling the newest copy from the shared drive first.

.DESCRIPTION
    This is the file people actually run day to day (usually by double-clicking
    Start-DeskSide.cmd). It keeps everyone on the latest version without anyone
    re-sending a zip:

      1. It finds the shared-drive copy of the toolkit (the "master").
      2. If the master is newer than the copy on THIS PC, it quietly copies the
         new files down to a folder under your profile.
      3. It runs the toolkit from that local copy.

    If the shared drive cannot be reached (working from home, VPN down, server
    off), it just runs the last copy you already have - so you are never stuck.

    WHERE THINGS LIVE
      - The master (everyone reads from it):  the shared drive, e.g.
            \\server\share\DeskSideToolkit
      - Your local copy (this PC only):       %LOCALAPPDATA%\DeskSideToolkit

    HOW IT FINDS THE SHARED DRIVE (first one that answers wins)
      1. The DESKSIDE_SHARE environment variable, if set.
      2. A share.txt file sitting next to this script (one line: the path).
      3. It asks you once, then remembers the answer in both places above.

    This script deliberately uses NOTHING from lib\ - it has to run before the
    copy step, i.e. before there is anything to load.

.PARAMETER NoRun
    Set up and sync, but do not launch the menu. Used by the tests.
#>

[CmdletBinding()]
param([switch]$NoRun)

$ErrorActionPreference = 'Stop'

# --- Is the master newer than our local copy? --------------------------------
# Versions are UTC stamps like 20260724204705, so a plain text comparison is
# also a date comparison (bigger string = later moment). A missing local
# version counts as "older than anything", so the first run always pulls.
function Test-DeskSideShareNewer {
    param([string]$ShareVersion, [string]$LocalVersion)
    if ([string]::IsNullOrWhiteSpace($ShareVersion)) { return $false }   # nothing to offer
    if ([string]::IsNullOrWhiteSpace($LocalVersion)) { return $true }    # nothing here yet
    return ([string]$ShareVersion).Trim() -gt ([string]$LocalVersion).Trim()
}

# Read a VERSION file's single line, or '' if it is not there.
function Get-DeskSideVersion {
    param([string]$Root)
    $vf = Join-Path $Root 'VERSION'
    if (Test-Path $vf) { return (Get-Content $vf -First 1 -ErrorAction SilentlyContinue) }
    return ''
}

# --- Find the shared-drive master --------------------------------------------
function Get-DeskSideShareRoot {
    param([string]$ScriptDir)

    # 1. Environment variable.
    $fromEnv = [Environment]::GetEnvironmentVariable('DESKSIDE_SHARE', 'User')
    if (-not $fromEnv) { $fromEnv = $env:DESKSIDE_SHARE }
    if ($fromEnv) { return $fromEnv.Trim() }

    # 2. share.txt next to this script (first non-blank, non-# line).
    $shareFile = Join-Path $ScriptDir 'share.txt'
    if (Test-Path $shareFile) {
        foreach ($line in (Get-Content $shareFile -ErrorAction SilentlyContinue)) {
            $t = $line.Trim()
            if ($t -and -not $t.StartsWith('#')) { return $t }
        }
    }

    # 3. Ask once, then remember (skip when non-interactive, e.g. the tests).
    if (-not $NoRun) {
        Write-Host ""
        Write-Host "  First run: where is the shared copy of Desk Side Toolkit?" -ForegroundColor Cyan
        Write-Host "  Example:   \\server\share\DeskSideToolkit   (or a mapped drive like Z:\DeskSideToolkit)" -ForegroundColor DarkGray
        $answer = (Read-Host "  Shared-drive path").Trim()
        if ($answer) {
            try { $answer | Out-File -FilePath $shareFile -Encoding UTF8 -Force } catch { }
            try { [Environment]::SetEnvironmentVariable('DESKSIDE_SHARE', $answer, 'User') } catch { }
            return $answer
        }
    }
    return ''
}

# --- Copy the master down to the local copy ----------------------------------
# Returns @{ Updated = <bool>; Reason = <text> }. Never throws for an ordinary
# "share not reachable" - that is a normal offline case handled by the caller.
function Sync-DeskSideCopy {
    param(
        [Parameter(Mandatory)][string]$ShareRoot,
        [Parameter(Mandatory)][string]$LocalRoot
    )

    if (-not (Test-Path $ShareRoot)) {
        return @{ Updated = $false; Reason = 'Shared drive not reachable' }
    }

    $shareVer = Get-DeskSideVersion $ShareRoot
    $localVer = Get-DeskSideVersion $LocalRoot

    if (-not (Test-DeskSideShareNewer -ShareVersion $shareVer -LocalVersion $localVer) -and (Test-Path $LocalRoot)) {
        return @{ Updated = $false; Reason = "Already up to date ($localVer)" }
    }

    if (-not (Test-Path $LocalRoot)) { New-Item -ItemType Directory -Path $LocalRoot -Force | Out-Null }

    # /MIR makes the local copy match the master. The /XD list is what keeps
    # THIS PC's own logs and settings safe: robocopy never touches those folders,
    # so mirroring cannot delete your output\ or data\. /XF protects a local
    # share.txt from being removed.
    $roboArgs = @(
        $ShareRoot, $LocalRoot, '/MIR',
        '/XD', 'output', 'data', '.git', '.claude',
        '/XF', 'share.txt',
        '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP'
    )
    & robocopy.exe @roboArgs | Out-Null
    $code = $LASTEXITCODE

    # Robocopy is odd: 0-7 are success (8+ is a real failure). Reset $LASTEXITCODE
    # so a "1 = files copied" does not look like an error to whatever runs next.
    $global:LASTEXITCODE = 0
    if ($code -ge 8) {
        return @{ Updated = $false; Reason = "Copy failed (robocopy code $code)" }
    }

    # Files that arrived over the network carry a "from another computer" mark
    # that makes PowerShell refuse or warn on them. Clear it on the local copy.
    try { Get-ChildItem -Path $LocalRoot -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue } catch { }

    return @{ Updated = $true; Reason = "Updated to $shareVer" }
}

# =============================================================================
# Main
# =============================================================================
if (-not $NoRun) {
    $scriptDir = $PSScriptRoot
    $localRoot = Join-Path $env:LOCALAPPDATA 'DeskSideToolkit'

    Write-Host ""
    Write-Host "  Desk Side Toolkit - starting up" -ForegroundColor Cyan

    $shareRoot = Get-DeskSideShareRoot -ScriptDir $scriptDir
    if ($shareRoot) {
        $result = Sync-DeskSideCopy -ShareRoot $shareRoot -LocalRoot $localRoot
        $colour = if ($result.Updated) { 'Green' } else { 'DarkGray' }
        Write-Host ("  {0}" -f $result.Reason) -ForegroundColor $colour
    }
    else {
        Write-Host "  No shared-drive path set - running the copy on this PC." -ForegroundColor DarkYellow
    }

    # Prefer the synced local copy; fall back to running in place (a freshly
    # unzipped copy that has never reached the share yet).
    $runRoot = $null
    if (Test-Path (Join-Path $localRoot 'AD-Toolkit.ps1')) { $runRoot = $localRoot }
    elseif (Test-Path (Join-Path $scriptDir 'AD-Toolkit.ps1')) { $runRoot = $scriptDir }

    if (-not $runRoot) {
        Write-Host ""
        Write-Host "  Could not find a copy to run." -ForegroundColor Red
        Write-Host "  The shared drive was unreachable and there is no local copy yet." -ForegroundColor Red
        Write-Host "  Connect to the network (or set the share path) and try again." -ForegroundColor Red
        Read-Host "  Press ENTER to close" | Out-Null
        return
    }

    Set-Location $runRoot
    & (Join-Path $runRoot 'AD-Toolkit.ps1')
}
