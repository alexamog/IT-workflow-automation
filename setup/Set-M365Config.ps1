<#
.SYNOPSIS
    Save the Microsoft 365 settings the licence tools use, and check the Graph
    module. Run once per machine / per user.

.DESCRIPTION
    Sets two optional environment variables for the current user and session:
      M365_USAGE_LOCATION  the two-letter country a licence is assigned in
                           (default CA). Microsoft requires a usage location
                           before a licence can be added.
      M365_E1_SKU          the licence part number treated as "Office 365 E1"
                           (default STANDARDPACK). Only change this if your
                           tenant's E1 has a different part number - the tools
                           list the available ones if the default isn't found.

    No password is stored. Microsoft Graph sign-in is interactive.

    The licence features need the Microsoft.Graph module. If it is missing,
    install it once (no admin rights needed):
        Install-Module Microsoft.Graph -Scope CurrentUser

.EXAMPLE
    .\setup\Set-M365Config.ps1
#>

$loc = Read-Host "Usage location (two-letter country, ENTER for 'CA' or to keep '$env:M365_USAGE_LOCATION')"
if (-not $loc) { $loc = if ($env:M365_USAGE_LOCATION) { $env:M365_USAGE_LOCATION } else { 'CA' } }
[Environment]::SetEnvironmentVariable('M365_USAGE_LOCATION', $loc, 'User')
$env:M365_USAGE_LOCATION = $loc

$sku = Read-Host "Office 365 E1 part number (ENTER for 'STANDARDPACK' or to keep '$env:M365_E1_SKU')"
if (-not $sku) { $sku = if ($env:M365_E1_SKU) { $env:M365_E1_SKU } else { 'STANDARDPACK' } }
[Environment]::SetEnvironmentVariable('M365_E1_SKU', $sku, 'User')
$env:M365_E1_SKU = $sku

# SharePoint tenant ADMIN url (the -admin host), used by the SharePoint tool.
$spo = Read-Host "SharePoint admin URL (e.g. https://contoso-admin.sharepoint.com - ENTER to keep '$env:SPO_ADMIN_URL')"
if (-not $spo) { $spo = $env:SPO_ADMIN_URL }
if ($spo) {
    [Environment]::SetEnvironmentVariable('SPO_ADMIN_URL', $spo, 'User')
    $env:SPO_ADMIN_URL = $spo
}

Write-Host "`nSaved." -ForegroundColor Green
Write-Host "  M365_USAGE_LOCATION = $loc"
Write-Host "  M365_E1_SKU         = $sku"
Write-Host "  SPO_ADMIN_URL       = $(if ($spo) { $spo } else { '(not set)' })"
Write-Host "`nOpen a new PowerShell window for other sessions to pick up the change." -ForegroundColor DarkGray

if (Get-Module -ListAvailable -Name Microsoft.Graph) {
    Write-Host "Microsoft.Graph module: found." -ForegroundColor Green
}
else {
    Write-Host "Microsoft.Graph module: NOT installed." -ForegroundColor Yellow
    if ((Read-Host "Install it now for your user? (Y/n)").Trim().ToUpper() -ne 'N') {
        try {
            Install-Module Microsoft.Graph -Scope CurrentUser -Force -ErrorAction Stop
            Write-Host "Installed." -ForegroundColor Green
        }
        catch { Write-Host "Install failed: $($_.Exception.Message)" -ForegroundColor Red }
    }
    else {
        Write-Host "Install it later with:  Install-Module Microsoft.Graph -Scope CurrentUser" -ForegroundColor DarkGray
    }
}

# The SharePoint tool needs the SharePoint Online Management Shell.
if (Get-Module -ListAvailable -Name Microsoft.Online.SharePoint.PowerShell) {
    Write-Host "SharePoint Online Management Shell: found." -ForegroundColor Green
}
else {
    Write-Host "SharePoint Online Management Shell: NOT installed." -ForegroundColor Yellow
    if ((Read-Host "Install it now for your user? (Y/n)").Trim().ToUpper() -ne 'N') {
        try {
            Install-Module Microsoft.Online.SharePoint.PowerShell -Scope CurrentUser -Force -ErrorAction Stop
            Write-Host "Installed." -ForegroundColor Green
        }
        catch { Write-Host "Install failed: $($_.Exception.Message)" -ForegroundColor Red }
    }
    else {
        Write-Host "Install it later with:  Install-Module Microsoft.Online.SharePoint.PowerShell -Scope CurrentUser" -ForegroundColor DarkGray
    }
}
