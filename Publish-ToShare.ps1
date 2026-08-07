<#
.SYNOPSIS
    Publish the current toolkit to the shared drive so everyone gets it.

.DESCRIPTION
    This is how you "release" a change. It:

      1. Stamps a fresh VERSION (the current UTC time).
      2. Copies the project to the shared drive, LEAVING OUT anything private or
         machine-local (same rule as the zip - Test-DeskSidePathExcluded in
         lib\Common.ps1).
      3. Runs the same privacy check the zip does, and refuses to publish if any
         output\ folder or exported ticket file slipped in.

    After this finishes, the next time anyone runs Start-DeskSide.cmd their copy
    sees the newer VERSION on the share and pulls it down. No zips to re-send.

    The share's own output\ and data\ (if anyone ran the toolkit straight from
    the share) are left untouched.

.PARAMETER ShareRoot
    The shared-drive master folder, e.g. \\server\share\DeskSideToolkit.
    Defaults to the DESKSIDE_SHARE environment variable; you are asked if neither
    is set.

.PARAMETER Force
    Do not ask before writing to the share.

.EXAMPLE
    .\Publish-ToShare.ps1 -ShareRoot \\fileserver\IT\DeskSideToolkit
#>

[CmdletBinding()]
param(
    [string]$ShareRoot,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
# Staging, the exclusion rule and the privacy gate all live in the library, so
# this script and Build-SharePackage.ps1 cannot disagree about what to leave out.
. "$src\lib\Common.ps1"   # New-DeskSideStage / Get-DeskSidePrivacyLeak

# --- Resolve the share -------------------------------------------------------
if (-not $ShareRoot) { $ShareRoot = [Environment]::GetEnvironmentVariable('DESKSIDE_SHARE', 'User') }
if (-not $ShareRoot) { $ShareRoot = $env:DESKSIDE_SHARE }
if (-not $ShareRoot) {
    $ShareRoot = (Read-Host "  Shared-drive master path (e.g. \\server\share\DeskSideToolkit)").Trim()
}
if (-not $ShareRoot) { Write-Host "  No share path given - nothing published." -ForegroundColor Yellow; return }

$shareParent = Split-Path $ShareRoot -Parent
if ($shareParent -and -not (Test-Path $shareParent)) {
    throw "Cannot reach $shareParent - is the shared drive connected?"
}

if (-not $Force) {
    $ans = Read-Host "  Publish this toolkit to '$ShareRoot'? (y/n)"
    if ($ans.Trim().ToUpper() -ne 'Y') { Write-Host "  Cancelled." -ForegroundColor Yellow; return }
}

# --- Stamp a fresh VERSION ---------------------------------------------------
$version = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
$version | Out-File -FilePath (Join-Path $src 'VERSION') -Encoding ascii -Force
Write-Host "`n=== Publishing $version to $ShareRoot ===" -ForegroundColor Cyan

# --- Stage + privacy gate ----------------------------------------------------
$stage = Join-Path ([IO.Path]::GetTempPath()) ("DeskSideToolkit-pub-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$copied = New-DeskSideStage -SourceRoot $src -StageRoot $stage
Write-Host "  Staged $copied file(s)."

$leak = Get-DeskSidePrivacyLeak -StageRoot $stage
if ($leak.Count -gt 0) {
    Write-Host "`n  ABORTING - private items reached staging:" -ForegroundColor Red
    $leak | ForEach-Object { Write-Host ("    {0}" -f $_.FullName.Substring($stage.Length).TrimStart('\')) -ForegroundColor Red }
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    throw "Privacy check failed - nothing published."
}

# --- Mirror to the share -----------------------------------------------------
# /XD output data: never disturb logs/data left by anyone running from the share.
if (-not (Test-Path $ShareRoot)) { New-Item -ItemType Directory -Path $ShareRoot -Force | Out-Null }
$roboArgs = @($stage, $ShareRoot, '/MIR', '/XD', 'output', 'data', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
& robocopy.exe @roboArgs | Out-Null
$code = $LASTEXITCODE
$global:LASTEXITCODE = 0
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue

if ($code -ge 8) { throw "robocopy failed (code $code) - the share may be incomplete." }

Write-Host "  Published. Everyone picks up $version next time they launch." -ForegroundColor Green
