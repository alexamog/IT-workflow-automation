<#
.SYNOPSIS
    One setup screen for the whole toolkit. Shows what is configured, lets you
    fill in each area, and skip anything you can't do right now.

.DESCRIPTION
    A single menu that dispatches to the individual setup scripts. Each row shows
    its status:
        [configured]  everything for this area is set
        [partial]     some of it is set
        [not set]     nothing set yet
    An area you can't do on this machine is greyed out with the reason (usually a
    missing PowerShell module, or a feature that isn't part of this edition).

    You do NOT have to finish it all in one go. Configure what you can, skip the
    rest, and RE-RUN this script any time to fill in what you left out - it always
    reflects the current state.

    After setting anything, open a NEW PowerShell window so other sessions pick up
    the saved values.

.EXAMPLE
    .\setup\Setup-DeskSide.ps1
#>

[CmdletBinding()]
param()

# Shared look-and-feel (Write-ToolHeader / Write-ToolMenuItem). Loading Common is
# harmless here - it only reads env vars and defines helpers.
. "$PSScriptRoot\..\lib\Common.ps1"

$jiraSetup = Join-Path $PSScriptRoot '..\Jira Scripts\Set-JiraCredentials.ps1'

# Read a persisted (User-scope) value, falling back to this process.
function Get-CfgVal ($Name) {
    $v = [Environment]::GetEnvironmentVariable($Name, 'User')
    if (-not $v) { $v = [Environment]::GetEnvironmentVariable($Name, 'Process') }
    $v
}
function Test-Cfg ($Name) { [bool](Get-CfgVal $Name) }
function Test-ModuleAvailable ($Name) { [bool](Get-Module -ListAvailable -Name $Name) }

# Status tag from how many of an area's variables are set.
function Get-Status ($Names) {
    $set = @($Names | Where-Object { Test-Cfg $_ }).Count
    if ($set -eq 0) { return @{ Tag = '[not set]'; Colour = 'DarkGray' } }
    if ($set -eq $Names.Count) { return @{ Tag = '[configured]'; Colour = 'Green' } }
    @{ Tag = "[partial $set/$($Names.Count)]"; Colour = 'Yellow' }
}

# --- Area definitions --------------------------------------------------------
# Each: Label, the setup script to run, the env vars that make up its status,
# and an optional prerequisite (module) that greys it out when missing.
$areas = @(
    [ordered]@{
        Label = 'General settings'
        Extra = 'URLs, domain/OUs, onboarding, time-zone (all optional)'
        Script = Join-Path $PSScriptRoot 'Set-ToolConfig.ps1'
        Vars = @('SNIPEIT_URL','AD_DOMAIN_DN','AD_SOURCE_OU','AD_REGIONS','ONBOARDING_GROUP','EMAIL_DOMAIN','SPO_TIMEZONE')
        NeedsModule = $null
    }
    [ordered]@{
        Label = 'Snipe-IT (assets)'
        Extra = 'API token + URL'
        Script = Join-Path $PSScriptRoot 'Set-SnipeCredentials.ps1'
        Vars = @('SNIPEIT_TOKEN')
        NeedsModule = $null
    }
    [ordered]@{
        Label = 'Tactical RMM (remote)'
        Extra = 'API key + URL'
        Script = Join-Path $PSScriptRoot 'Set-TacticalCredentials.ps1'
        Vars = @('TRMM_APIKEY','TRMM_URL')
        NeedsModule = $null
    }
    [ordered]@{
        Label = 'Exchange Online admin'
        Extra = 'your admin address (EXO_ADMIN_UPN)'
        Script = Join-Path $PSScriptRoot 'Set-ExchangeAdmin.ps1'
        Vars = @('EXO_ADMIN_UPN')
        NeedsModule = 'ExchangeOnlineManagement'
    }
    [ordered]@{
        Label = 'Microsoft 365 / SharePoint'
        Extra = 'admin URL, usage location, E1 SKU'
        Script = Join-Path $PSScriptRoot 'Set-M365Config.ps1'
        Vars = @('SPO_ADMIN_URL','M365_USAGE_LOCATION')
        NeedsModule = 'Microsoft.Online.SharePoint.PowerShell'
    }
    [ordered]@{
        Label = 'Jira service desk'
        Extra = 'base URL, email, API token'
        Script = $jiraSetup
        Vars = @('JIRA_BASEURL','JIRA_EMAIL','JIRA_API_TOKEN')
        NeedsModule = $null
    }
)

# Why an area can't be done now (missing module / not in this edition), or $null.
function Get-BlockReason ($Area) {
    if (-not (Test-Path $Area.Script)) { return '(not in this edition)' }
    if ($Area.NeedsModule -and -not (Test-ModuleAvailable $Area.NeedsModule)) { return "(needs $($Area.NeedsModule) - use option M)" }
    $null
}

# --- Optional-module installer (option M) ------------------------------------
function Install-OptionalModules {
    $mods = @(
        @{ Name = 'ExchangeOnlineManagement'; For = 'Exchange Online' }
        @{ Name = 'Microsoft.Graph'; For = 'Microsoft 365 licences' }
        @{ Name = 'Microsoft.Online.SharePoint.PowerShell'; For = 'SharePoint' }
    )
    foreach ($m in $mods) {
        if (Test-ModuleAvailable $m.Name) { Write-Host ("  {0} - already installed." -f $m.Name) -ForegroundColor DarkGray; continue }
        if ((Read-Host ("  Install {0} (for {1})? (y/n)" -f $m.Name, $m.For)).Trim().ToUpper() -eq 'Y') {
            try {
                Install-Module $m.Name -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
                Write-Host "    Installed." -ForegroundColor Green
            }
            catch { Write-Host "    Failed: $($_.Exception.Message)" -ForegroundColor Red }
        }
    }
    Write-Host "  Open a NEW PowerShell window, then re-run this so the new modules are seen." -ForegroundColor Yellow
}

# --- Menu loop ---------------------------------------------------------------
while ($true) {
    Clear-Host
    Write-ToolHeader 'Desk Side - setup'
    Write-Host "  Configure what you can now; skip the rest and re-run any time to finish." -ForegroundColor DarkGray
    Write-Host ""

    for ($i = 0; $i -lt $areas.Count; $i++) {
        $a      = $areas[$i]
        $block  = Get-BlockReason $a
        $status = Get-Status $a.Vars
        $label  = "{0,-28} {1}" -f $a.Label, $status.Tag
        if ($block) {
            Write-ToolMenuItem -Key ($i + 1) -Label $label -Disabled -Note $block
        }
        else {
            Write-ToolMenuItem -Key ($i + 1) -Label $label -Note $a.Extra
        }
    }
    Write-Host ""
    Write-ToolMenuItem -Key 'M' -Label 'Install optional PowerShell modules' -Note 'Exchange / Graph / SharePoint'
    Write-ToolMenuItem -Key '0' -Label 'Done / exit'
    Write-Host ""

    $choice = (Read-Host "  Select").Trim()
    if ($choice -eq '0') { break }
    if ($choice -match '^[Mm]$') { Install-OptionalModules; Read-Host "  Press ENTER to continue" | Out-Null; continue }

    $n = 0
    if (-not ([int]::TryParse($choice, [ref]$n)) -or $n -lt 1 -or $n -gt $areas.Count) {
        Write-Host "  Unknown option." -ForegroundColor DarkGray; Start-Sleep -Seconds 1; continue
    }

    $area  = $areas[$n - 1]
    $block = Get-BlockReason $area
    if ($block) {
        Write-Host "  Can't do that here $block." -ForegroundColor Yellow
        if ($area.NeedsModule) { Write-Host "  Install its module with option M, then re-run this setup." -ForegroundColor Yellow }
        Start-Sleep -Seconds 2; continue
    }

    Write-Host ""
    & $area.Script
    Write-Host ""
    Read-Host "  Press ENTER to return to the menu" | Out-Null
}

Write-Host "`nSetup closed. Open a NEW PowerShell window so saved settings are picked up." -ForegroundColor Cyan
Write-Host "Anything you skipped: just run .\setup\Setup-DeskSide.ps1 again to finish it." -ForegroundColor DarkGray
