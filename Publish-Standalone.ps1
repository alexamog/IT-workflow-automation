<#
.SYNOPSIS
    Generate self-contained standalone editions of the toolkit (Snipe-IT,
    Tactical RMM) from this single source project.

.DESCRIPTION
    Each edition is its own folder containing only the feature(s) it needs, the
    generic auto-discovering launcher (copied in as Start-Toolkit.ps1), the
    shared lib\ if required, the relevant setup script(s), a toolkit.psd1 that
    sets the menu title, and an INSTRUCTIONS.txt. Because every edition is
    GENERATED from here, you edit a feature once in this project and re-run this
    script to refresh every edition - there is no manual copy to drift.

    Editions are written as SIBLING folders next to this project (same parent).
    Managed code in a target is replaced; an existing output\ or data\ folder
    (logs / local data) is preserved.

.PARAMETER Edition
    Which to publish: 'SnipeIT', 'TacticalRMM', or 'All' (default).

.PARAMETER Force
    Skip the confirmation prompt before replacing an existing edition folder.

.EXAMPLE
    .\Publish-Standalone.ps1
    Publishes both editions (asks before overwriting each existing folder).

.EXAMPLE
    .\Publish-Standalone.ps1 -Edition TacticalRMM -Force
#>

[CmdletBinding()]
param(
    [ValidateSet('All', 'SnipeIT', 'TacticalRMM', 'Core')][string]$Edition = 'All',
    [switch]$Force
)

$src    = $PSScriptRoot
$parent = Split-Path $src -Parent

# All standalone editions live inside one collection folder.
$collection = Join-Path $parent 'Standalone Editions'
if (-not (Test-Path $collection)) { New-Item -ItemType Directory -Path $collection -Force | Out-Null }

# --- Edition definitions ----------------------------------------------------
$editions = @(
    [pscustomobject]@{
        Key          = 'SnipeIT'
        FolderName   = 'Snipe-IT Tool'
        Title        = 'Snipe-IT Tool'
        ScriptItems  = @('scripts\assets')                 # whole folder (+ its manifests)
        NeedsCommon  = $true                               # uses Invoke-SnipeRequest etc.
        SetupScripts = @('Setup-DeskSide.ps1', 'Set-SnipeCredentials.ps1', 'Set-ToolConfig.ps1')
        SetupLines   = @(
            '    .\setup\Setup-DeskSide.ps1   (one setup screen - shows what is set,',
            '                                  greys out what this edition cannot do)'
        )
        Blurb        = 'Look up, edit, and create Snipe-IT hardware assets.'
        NeedsAdmin   = $false
    }
    [pscustomobject]@{
        Key          = 'TacticalRMM'
        FolderName   = 'Tactical RMM Tool'
        Title        = 'Tactical RMM Tool'
        ScriptItems  = @('scripts\remote', 'scripts\maintenance\Remove-UnlistedProfiles.ps1')
        NeedsCommon  = $true                               # Snipe audit uses Invoke-SnipeRequest
        SetupScripts = @('Setup-DeskSide.ps1', 'Set-TacticalCredentials.ps1', 'Set-SnipeCredentials.ps1', 'Set-ToolConfig.ps1')
        SetupLines   = @(
            '    .\setup\Setup-DeskSide.ps1   (one setup screen - shows what is set,',
            '                                  greys out what this edition cannot do)',
            '',
            '    Tactical RMM URL is the api. address, e.g. https://api.contoso.com',
            '    (NOT the rmm. website you log into).'
        )
        Blurb        = 'Remote machine tools via Tactical RMM - profile cleanup, file send, remote PowerShell prompt, and fleet disk cleanup - plus local profile cleanup on THIS PC.'
        NeedsAdmin   = $true
    }
)

# --- Helpers ----------------------------------------------------------------

# Files to copy for one script item (a folder copies recursively; a single .ps1
# also pulls its sibling .tool.psd1 so the feature still shows in the menu).
function Get-ItemFile ($item) {
    $full = Join-Path $src $item
    if (Test-Path $full -PathType Container) { return @(Get-ChildItem $full -Recurse -File) }
    if (Test-Path $full -PathType Leaf) {
        $files = @(Get-Item $full)
        if ($full -match '\.ps1$') {
            $man = $full -replace '\.ps1$', '.tool.psd1'
            if (Test-Path $man) { $files += Get-Item $man }
        }
        return $files
    }
    Write-Host "  WARNING: source item not found: $item" -ForegroundColor Yellow
    return @()
}

# Copy a source file into $dest, preserving its path relative to the project.
function Copy-Preserving ($file, $dest) {
    $rel    = $file.FullName.Substring($src.Length).TrimStart('\', '/')
    $target = Join-Path $dest $rel
    $dir    = Split-Path $target -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Copy-Item -Path $file.FullName -Destination $target -Force
}

function Format-InstructionsText ($ed) {
    $adminLine = if ($ed.NeedsAdmin) { "`n  - Run PowerShell 'as administrator' for profile cleanup on this PC" } else { '' }
    $setup = ($ed.SetupLines -join "`n")
    @"
$($ed.Title.ToUpper())
$('=' * $ed.Title.Length)

$($ed.Blurb)

This is a standalone edition generated from the main "Desk Side Tool" project.
Do not edit it here - change the feature in the main project and re-run its
Publish-Standalone.ps1 to refresh this folder.


BEFORE ANYTHING ELSE - ALLOW SCRIPTS TO RUN (once per machine / per person)
---------------------------------------------------------------------------
    Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned

Answer Y. If this arrived as a ZIP, also clear the "from the internet" mark:
    Get-ChildItem -Recurse | Unblock-File


FIRST-TIME SETUP (once per machine / per person)
------------------------------------------------
$setup

After running any setup script, open a NEW PowerShell window so the saved
settings are picked up.


DAILY USE
---------
Start the menu:

    .\Start-Toolkit.ps1

Pick a category, then an option. Everything asks questions as it goes, and
anything destructive shows the full list and asks you to confirm first.


NEEDS
-----
  - Windows PowerShell (already on every PC) - no extra modules needed$adminLine


LOGS
----
    output\  holds action logs and transcripts (created after the first action).
"@
}

# --- Publish each selected edition ------------------------------------------
foreach ($ed in $editions) {
    if ($Edition -ne 'All' -and $Edition -ne $ed.Key) { continue }

    $dest = Join-Path $collection $ed.FolderName
    Write-Host "`n=== Publishing '$($ed.FolderName)' ===" -ForegroundColor Cyan
    Write-Host "    -> $dest"

    if (Test-Path $dest) {
        if (-not $Force) {
            $ans = Read-Host "    '$($ed.FolderName)' exists. Replace its code (output\ and data\ are kept)? (y/n)"
            if ($ans.Trim().ToUpper() -ne 'Y') { Write-Host "    Skipped." -ForegroundColor Yellow; continue }
        }
        # Remove managed code; preserve output\ and data\. This clears ALL
        # root-level .ps1 (old launchers/setup scripts from a previous layout -
        # the only root script we want, Start-Toolkit.ps1, is re-created below),
        # plus the managed folders and doc files.
        Get-ChildItem -Path $dest -File -Filter *.ps1 -ErrorAction SilentlyContinue | Remove-Item -Force
        foreach ($m in @('toolkit.psd1', 'INSTRUCTIONS.txt', 'README.md', 'lib', 'scripts', 'setup')) {
            $p = Join-Path $dest $m
            if (Test-Path $p) { Remove-Item -Path $p -Recurse -Force }
        }
    }
    else { New-Item -ItemType Directory -Path $dest -Force | Out-Null }

    # 1. Feature scripts (+ their manifests), path-preserved.
    $count = 0
    foreach ($item in $ed.ScriptItems) {
        foreach ($f in Get-ItemFile $item) { Copy-Preserving -file $f -dest $dest; $count++ }
    }

    # 2. Shared library, if the edition needs it. Quotes.psd1 rides along so the
    #    launcher's sign-off (Show-DeskSideSignoff reads it) works in the edition.
    if ($ed.NeedsCommon) {
        Copy-Preserving -file (Get-Item (Join-Path $src 'lib\Common.ps1')) -dest $dest
        Copy-Preserving -file (Get-Item (Join-Path $src 'lib\Quotes.psd1')) -dest $dest
        Copy-Preserving -file (Get-Item (Join-Path $src 'lib\Ui.ps1'))      -dest $dest
    }

    # 3. Setup scripts.
    foreach ($s in $ed.SetupScripts) {
        $sp = Join-Path $src "setup\$s"
        if (Test-Path $sp) { Copy-Preserving -file (Get-Item $sp) -dest $dest }
        else { Write-Host "  WARNING: setup script not found: $s" -ForegroundColor Yellow }
    }

    # 4. The generic launcher (as Start-Toolkit.ps1) + the edition title.
    Copy-Item -Path (Join-Path $src 'AD-Toolkit.ps1') -Destination (Join-Path $dest 'Start-Toolkit.ps1') -Force
    "@{ Title = '$($ed.Title)' }" | Out-File -FilePath (Join-Path $dest 'toolkit.psd1') -Encoding UTF8

    # 5. Instructions.
    Format-InstructionsText $ed | Out-File -FilePath (Join-Path $dest 'INSTRUCTIONS.txt') -Encoding UTF8

    Write-Host "    Copied $count feature file(s) + launcher + setup + instructions." -ForegroundColor Green
}

# --- Core edition: whole runnable project, no documentation -----------------
# Everything needed to run, minus docs/dev/build files. Regenerated each time.
if ($Edition -eq 'All' -or $Edition -eq 'Core') {
    $coreDest = Join-Path $parent 'Desk Side Tool - Core'
    Write-Host "`n=== Publishing 'Desk Side Tool - Core' ===" -ForegroundColor Cyan
    Write-Host "    -> $coreDest"

    # Doc / dev / build items to EXCLUDE from core (name match, any depth).
    $excludeNames = @('documentation', 'docs', 'API-Examples', 'README.md', 'ARCHITECTURE.md',
        'DEVELOPER-GUIDE.md', 'DEPLOYMENT.md', 'Publish-Standalone.ps1',
        'output', 'logs', '.git', '.claude',
        # Developer tooling: the tests and the code checker are for working ON
        # the toolkit, not for running it.
        'tests', 'Run-Tests.ps1', 'PSScriptAnalyzerSettings.psd1', '.gitignore', '.gitattributes')
    $excludeExt   = @('.md', '.html', '.pdf')

    if (Test-Path $coreDest) {
        if (-not $Force) {
            $ans = Read-Host "    Core exists. Replace it? (y/n)"
            if ($ans.Trim().ToUpper() -ne 'Y') { Write-Host "    Skipped." -ForegroundColor Yellow; $coreDest = $null }
        }
        if ($coreDest) { Remove-Item -Path $coreDest -Recurse -Force }
    }

    if ($coreDest) {
        New-Item -ItemType Directory -Path $coreDest -Force | Out-Null
        $copied = 0
        foreach ($f in Get-ChildItem $src -Recurse -File) {
            $rel = $f.FullName.Substring($src.Length).TrimStart('\', '/')
            $parts = $rel -split '[\\/]'
            if ($parts | Where-Object { $excludeNames -contains $_ }) { continue }
            if ($excludeExt -contains $f.Extension.ToLower()) { continue }
            $target = Join-Path $coreDest $rel
            $dir = Split-Path $target -Parent
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            Copy-Item -Path $f.FullName -Destination $target -Force
            $copied++
        }
        # Minimal start guide (Core strips all docs, so ship one plain pointer).
        @"
DESK SIDE TOOLKIT - CORE

FIRST TIME ON THIS MACHINE (once):
    Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
    Get-ChildItem -Recurse | Unblock-File     (after unzip - clears 'from internet')

SET CREDENTIALS (once, per system used) - one screen for everything:
    .\setup\Setup-DeskSide.ps1
It shows what is set, greys out what you can't do here, and you can re-run it any
time to finish. Open a NEW PowerShell window after setting credentials.

RUN:
    .\AD-Toolkit.ps1

Needs RSAT ActiveDirectory module for the AD features. Run as administrator for
profile cleanup on this PC.
"@ | Out-File -FilePath (Join-Path $coreDest 'START-HERE.txt') -Encoding UTF8

        Write-Host "    Copied $copied file(s) (docs excluded) + START-HERE.txt." -ForegroundColor Green
    }
}

Write-Host "`nDone. Re-run this any time you change a feature to refresh the editions." -ForegroundColor Cyan
