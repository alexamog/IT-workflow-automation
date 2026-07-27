<#
.SYNOPSIS
    Desk Side Toolkit - an auto-discovering menu launcher.

.DESCRIPTION
    This launcher builds its menu by SCANNING the project for feature
    "manifests": small <Name>.tool.psd1 files that sit next to each feature
    script. Nothing about the menu is hard-coded here, so adding, updating, or
    removing a feature never means editing this file - you only touch that
    feature's own files.

    Each feature is self-contained and can also be run on its own, e.g.
        .\scripts\accounts\Reset-UserPassword.ps1 alex.amog

    This launcher intentionally does NOT require the ActiveDirectory module:
    only the AD features need it, and each of those scripts declares its own
    "#Requires -Modules ActiveDirectory". So the Jira, Snipe-IT, and Tactical
    RMM features work on a machine without RSAT; the AD ones fail cleanly if
    RSAT is missing.

    ---------------------------------------------------------------------------
    HOW TO ADD A NEW FEATURE  (full walkthrough: documentation\DEVELOPER-GUIDE.md)
      1. Write the script in a category subfolder under scripts\
         (e.g. scripts\reporting\Get-StaleAccounts.ps1). If it needs the shared
         config/helpers, start it with:
             . "$PSScriptRoot\..\..\lib\Common.ps1"
      2. Drop a manifest next to it, SAME base name plus .tool.psd1
         (e.g. scripts\reporting\Get-StaleAccounts.tool.psd1):
             @{
                 Category = 'Reporting'
                 Label    = 'Show stale accounts'
                 Order    = 63
             }
      3. Done. The launcher discovers it automatically. A new Category value
         makes a new menu section; Order sets the position (lower = higher up).

    OPTIONAL: a manifest may add  Audience = 'Admin' | 'Standard' | 'Both'.
      'Admin'    - AD / Microsoft tools; only usable when running as SYSTEM.
      'Standard' - Jira / Snipe-IT / Tactical RMM; only from a normal login.
      'Both' (or omitted) - always usable.
    The launcher greys out and blocks the ones that do not match how it is being
    run, so a normal login and a SYSTEM run see two different sets of tools.
    ---------------------------------------------------------------------------
#>

$root = $PSScriptRoot

# Shared look-and-feel (banner / headers / menu rows) and the sign-off quote all
# live in lib\Common.ps1. Loading it needs no ActiveDirectory module, so the
# launcher stays usable without RSAT - only the AD feature scripts require it.
. "$root\lib\Common.ps1"

# Optional edition title: a standalone edition drops a toolkit.psd1 at the root
# (e.g. @{ Title = 'Snipe-IT Tool' }). The main project has none, so it
# falls back to the default. (toolkit.psd1 does NOT match the *.tool.psd1 feature
# glob, so it is never mistaken for a feature.)
$editionTitle = if ($env:DESKSIDE_TITLE) { $env:DESKSIDE_TITLE } else { 'Desk Side Toolkit' }
$titleFile = Join-Path $root 'toolkit.psd1'
if (Test-Path $titleFile) {
    # A malformed title file should never stop the launcher - fall back to the default.
    try { $t = (Import-PowerShellDataFile -Path $titleFile).Title; if ($t) { $editionTitle = [string]$t } } catch { }
}

# --- Discover features from *.tool.psd1 manifests ----------------------------
# Import-PowerShellDataFile only PARSES data (it does not execute code), so a
# manifest can declare a feature's menu entry without any security risk.
function Get-DeskSideFeature {
    $features = @()
    foreach ($manifest in Get-ChildItem -Path $root -Recurse -Filter *.tool.psd1 -File -ErrorAction SilentlyContinue) {
        try { $data = Import-PowerShellDataFile -Path $manifest.FullName -ErrorAction Stop }
        catch { Write-Host "Skipping unreadable manifest $($manifest.Name): $($_.Exception.Message)" -ForegroundColor DarkYellow; continue }

        if (-not $data.Category -or -not $data.Label) {
            Write-Host "Skipping manifest missing Category/Label: $($manifest.Name)" -ForegroundColor DarkYellow
            continue
        }

        # The feature script sits next to the manifest with the same base name:
        #   Reset-UserPassword.tool.psd1  ->  Reset-UserPassword.ps1
        $scriptPath = Join-Path $manifest.DirectoryName (($manifest.BaseName -replace '\.tool$', '') + '.ps1')
        if (-not (Test-Path $scriptPath)) {
            Write-Host "Skipping manifest with no matching script: $($manifest.Name)" -ForegroundColor DarkYellow
            continue
        }

        $order = 100
        if ($data.ContainsKey('Order')) { [void][int]::TryParse("$($data.Order)", [ref]$order) }

        # Audience: who may run it. Unknown / missing values fall back to 'Both'.
        $audience = 'Both'
        if ($data.ContainsKey('Audience') -and ([string]$data.Audience) -in 'Admin', 'Standard', 'Both') {
            $audience = [string]$data.Audience
        }

        $features += [pscustomobject]@{
            Category = [string]$data.Category
            Label    = [string]$data.Label
            Order    = $order
            Audience = $audience
            Path     = $scriptPath
        }
    }
    @($features | Sort-Object Order, Label)
}

$features = Get-DeskSideFeature
if ($features.Count -eq 0) {
    Write-Host "No features found (no *.tool.psd1 manifests under $root)." -ForegroundColor Red
    return
}

# Category display order = the order categories first appear once features are
# sorted by Order. So Order controls both the section order and the item order.
$categories = @()
foreach ($f in $features) { if ($categories -notcontains $f.Category) { $categories += $f.Category } }

# --- Who is signed in --------------------------------------------------------
# Running as the local SYSTEM account gets the AD / Microsoft tools; any normal
# login gets the rest. Features tagged for the other kind are greyed out and
# cannot be run.
function Test-RunningAsSystem {
    # Definitive: the well-known LocalSystem SID. Fall back to a plain username.
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        if ($id.User -and $id.User.Value -eq 'S-1-5-18') { return $true }
    } catch { }
    return ($env:USERNAME -eq 'SYSTEM')
}

$accountKind  = if (Test-RunningAsSystem) { 'Admin' } else { 'Standard' }
$accountBlurb = if ($accountKind -eq 'Admin') { 'AD / Microsoft tools (SYSTEM)' } else { 'Jira / Snipe-IT / RMM tools' }

function Test-FeatureAllowed { param($Feature) $Feature.Audience -eq 'Both' -or $Feature.Audience -eq $accountKind }

# The greyed-out note for a feature the current account may not run.
function Get-FeatureBlockNote {
    param($Audience)
    switch ($Audience) {
        'Admin'    { '(SYSTEM only)' }
        'Standard' { '(standard login only)' }
        default    { '' }
    }
}

# A category is usable if it holds at least one feature this account may run.
function Test-CategoryAllowed { param($Category) @($features | Where-Object { $_.Category -eq $Category -and (Test-FeatureAllowed $_) }).Count -gt 0 }

# Note shown on a whole category that is off-limits (from the audiences inside).
function Get-CategoryBlockNote {
    param($Category)
    $auds = @($features | Where-Object { $_.Category -eq $Category } | Select-Object -ExpandProperty Audience -Unique)
    if ($auds.Count -eq 1) { return (Get-FeatureBlockNote $auds[0]) }
    '(not for this login)'
}

# Run one feature script. Each prompts for its own input when run with no args.
function Invoke-Feature {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path $Path) { & $Path }
    else { Write-Host "Script not found: $Path" -ForegroundColor Red }
}

# Second level: list the options in one category and run the chosen script.
function Show-CategoryMenu {
    param([string]$Category)
    # Runnable options first, greyed-out ones after (each group keeps its Order).
    # Fixed order (by Order); greyed items stay in place, not sorted to the bottom.
    $items = @($features | Where-Object { $_.Category -eq $Category })
    do {
        Clear-Host
        Write-ToolBanner $editionTitle
        Write-ToolHeader $Category
        for ($i = 0; $i -lt $items.Count; $i++) {
            if (Test-FeatureAllowed $items[$i]) { Write-ToolMenuItem -Key ($i + 1) -Label $items[$i].Label }
            else { Write-ToolMenuItem -Key ($i + 1) -Label $items[$i].Label -Disabled -Note (Get-FeatureBlockNote $items[$i].Audience) }
        }
        Write-ToolMenuItem -Key '0' -Label 'Back'

        Write-Host ''
        $sel = Read-Host "  Select an option"
        if ($sel -eq '0') { return }
        if (($sel -as [int]) -and [int]$sel -ge 1 -and [int]$sel -le $items.Count) {
            $picked = $items[[int]$sel - 1]
            if (-not (Test-FeatureAllowed $picked)) {
                Write-Host "  That tool needs a different login $(Get-FeatureBlockNote $picked.Audience)." -ForegroundColor Yellow; Start-Sleep -Seconds 1; continue
            }
            Write-Host ""
            Invoke-Feature -Path $picked.Path
            Write-Host ""
            Read-Host "  Press ENTER to return" | Out-Null
        }
        else { Write-Host "Invalid option." -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
    } while ($true)
}

# First level: pick a category. Fixed order (by Order) - the same for everyone;
# categories the current login can't use are greyed in place, not reordered.
do {
    Clear-Host
    Write-ToolBanner $editionTitle
    Write-Host ("  Signed in as {0} - {1}" -f $env:USERNAME, $accountBlurb) -ForegroundColor DarkGray
    Write-ToolHeader 'Menu'
    for ($i = 0; $i -lt $categories.Count; $i++) {
        if (Test-CategoryAllowed $categories[$i]) { Write-ToolMenuItem -Key ($i + 1) -Label $categories[$i] }
        else { Write-ToolMenuItem -Key ($i + 1) -Label $categories[$i] -Disabled -Note (Get-CategoryBlockNote $categories[$i]) }
    }
    Write-ToolMenuItem -Key '0' -Label 'Exit'

    Write-Host ''
    $choice = Read-Host "  Select a category"
    if ($choice -eq '0') { break }
    if (($choice -as [int]) -and [int]$choice -ge 1 -and [int]$choice -le $categories.Count) {
        $chosen = $categories[[int]$choice - 1]
        if (-not (Test-CategoryAllowed $chosen)) {
            Write-Host "  Not available for your login $(Get-CategoryBlockNote $chosen)." -ForegroundColor Yellow; Start-Sleep -Seconds 1; continue
        }
        $items  = @($features | Where-Object { $_.Category -eq $chosen })
        if ($items.Count -eq 1) {
            # Only one option in this category - run it directly, no submenu.
            Write-Host ""
            Invoke-Feature -Path $items[0].Path
            Write-Host ""
            Read-Host "  Press ENTER to return" | Out-Null
        }
        else {
            Show-CategoryMenu -Category $chosen
        }
    }
    else { Write-Host "Invalid option." -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
} while ($true)

# Sign off with a random quote. The quotes live once in lib\Quotes.psd1; this
# reads from there so they are never maintained in two places.
Show-DeskSideSignoff
