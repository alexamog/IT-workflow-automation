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
. "$src\lib\Common.ps1"   # for Test-DeskSidePathExcluded / Get-ADToolOutputDir

# Stage the project into $StageRoot, applying the shared exclusion rule. Returns
# the number of files copied.
function New-DeskSideStage {
    param([string]$SourceRoot, [string]$StageRoot)
    if (Test-Path $StageRoot) { Remove-Item $StageRoot -Recurse -Force }
    New-Item -ItemType Directory -Path $StageRoot -Force | Out-Null

    $count = 0
    # No -Force: Windows marks the .git folder hidden, so it is skipped here and
    # we never even walk it. Everything else we want is visible.
    foreach ($f in Get-ChildItem $SourceRoot -Recurse -File) {
        $rel = $f.FullName.Substring($SourceRoot.Length).TrimStart('\', '/')
        if (Test-DeskSidePathExcluded -RelativePath $rel) { continue }
        $target = Join-Path $StageRoot $rel
        $dir = Split-Path $target -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Copy-Item -Path $f.FullName -Destination $target -Force
        $count++
    }
    return $count
}

# Refuse to ship if anything private slipped into staging. Returns the offending
# items (empty = clean).
function Get-DeskSidePrivacyLeak {
    param([string]$StageRoot)
    @(Get-ChildItem $StageRoot -Recurse | Where-Object {
        $rel = $_.FullName.Substring($StageRoot.Length)
        (($rel -split '[\\/]') -contains 'output') -or ($_.Name -like 'My-Completed-Tickets*')
    })
}

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
