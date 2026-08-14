<#
.SYNOPSIS
    Build a clean zip of Desk Side Toolkit to hand to someone else.

.DESCRIPTION
    Copies the whole project into a staging folder, LEAVING OUT anything with
    real data or that only belongs on this machine (see Test-DeskSidePathExcluded
    in lib\Common.ps1 - the single rule shared with Publish-ToShare.ps1), then
    zips it.

    Before it zips, it double-checks the staged copy for privacy leaks - any
    output\ folder or exported ticket file - and REFUSES to build if it finds
    one. So a zip can never accidentally carry live hostnames, staff names, or
    ticket PII.

    The zip includes the auto-update launcher (Start-DeskSide.*) and a
    share.txt.template, so whoever unzips it gets an auto-updating install once
    they point it at the shared drive.

.PARAMETER DestinationDir
    Where to write the zip. Defaults to the project's output\ folder (gitignored).

.PARAMETER Force
    Overwrite an existing zip of the same name without asking.

.EXAMPLE
    .\Build-SharePackage.ps1
#>

[CmdletBinding()]
param(
    [string]$DestinationDir,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
# Staging, the exclusion rule and the privacy gate all live in the library, so
# this script and Publish-ToShare.ps1 cannot disagree about what to leave out.
. "$src\lib\Common.ps1"   # New-DeskSideStage / Get-DeskSidePrivacyLeak / Get-ADToolOutputDir

# --- Version + destination ---------------------------------------------------
$version = Get-Content (Join-Path $src 'VERSION') -First 1 -ErrorAction SilentlyContinue
if (-not $version) { $version = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss') }

if (-not $DestinationDir) { $DestinationDir = Get-ADToolOutputDir -Category 'Packages' }
if (-not (Test-Path $DestinationDir)) { New-Item -ItemType Directory -Path $DestinationDir -Force | Out-Null }
$zipPath = Join-Path $DestinationDir "DeskSideToolkit-$version.zip"

if ((Test-Path $zipPath) -and -not $Force) {
    $ans = Read-Host "  $zipPath exists. Overwrite? (y/n)"
    if ($ans.Trim().ToUpper() -ne 'Y') { Write-Host "  Cancelled." -ForegroundColor Yellow; return }
}

# --- Stage -------------------------------------------------------------------
$stage = Join-Path ([IO.Path]::GetTempPath()) ("DeskSideToolkit-pkg-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
Write-Host "`n=== Building share package $version ===" -ForegroundColor Cyan
$copied = New-DeskSideStage -SourceRoot $src -StageRoot $stage
Write-Host "  Staged $copied file(s)."

# --- Privacy gate ------------------------------------------------------------
$leak = Get-DeskSidePrivacyLeak -StageRoot $stage
if ($leak.Count -gt 0) {
    Write-Host "`n  ABORTING - private items reached staging:" -ForegroundColor Red
    $leak | ForEach-Object { Write-Host ("    {0}" -f $_.FullName.Substring($stage.Length).TrimStart('\')) -ForegroundColor Red }
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    throw "Privacy check failed - no zip written."
}

# Sanity: the things that MUST be in there.
foreach ($must in 'VERSION', 'Start-DeskSide.ps1', 'AD-Toolkit.ps1') {
    if (-not (Test-Path (Join-Path $stage $must))) {
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
        throw "Staging is missing $must - not building an incomplete zip."
    }
}

# --- Zip ---------------------------------------------------------------------
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zipPath -Force
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue

$sizeMB = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
Write-Host "  Wrote $zipPath ($sizeMB MB)." -ForegroundColor Green
Write-Host "  Privacy check passed - no output\ or ticket files inside." -ForegroundColor Green
$zipPath
