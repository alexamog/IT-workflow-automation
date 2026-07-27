<#
.SYNOPSIS
    Group users in the Initial Import - Unmatched Accounts OU by Office, print
    them on screen, and write a JSON report to the output folder.

.PARAMETER Server
    DC to read from. Defaults to the PDC emulator (see Get-ADToolDC).

.EXAMPLE
    .\Group-UnmatchedUsersByOffice.ps1
#>

#Requires -Modules ActiveDirectory
param([string]$Server)

. "$PSScriptRoot\..\..\lib\Common.ps1"

if (-not $ADTool.SourceOU) {
    Write-Host "No 'unmatched accounts' OU is configured." -ForegroundColor Yellow
    Write-Host "Set AD_SOURCE_OU with .\setup\Set-ToolConfig.ps1 and try again." -ForegroundColor Yellow
    return
}

$Server   = Get-ADToolDC -Server $Server
$jsonPath = Join-Path (Get-ADToolOutputDir) ("Users-ByOffice-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Write-Host "Reading from DC: $Server" -ForegroundColor DarkGray

$users = Get-ADUser -Server $Server -SearchBase $ADTool.SourceOU -SearchScope Subtree -Filter * `
    -Properties Office, DisplayName, Description, Enabled
if (-not $users) { Write-Host "No users found in the source OU." -ForegroundColor Yellow; return }

# Group by Office; blank/missing Office becomes one named bucket.
$groups = $users |
    Group-Object { if ($_.Office) { $_.Office } else { '(No Office Set)' } } |
    Sort-Object Name

Write-Host ("`nTotal users: {0}  |  Offices: {1}" -f $users.Count, $groups.Count) -ForegroundColor Cyan
foreach ($g in $groups) {
    Write-Host ("`n=== {0}  ({1} user(s)) ===" -f $g.Name, $g.Count) -ForegroundColor Green
    $g.Group | Sort-Object SamAccountName |
        Select-Object SamAccountName, DisplayName, Description, Enabled, DistinguishedName |
        Format-Table -AutoSize -Wrap | Out-Host
}

# JSON report grouped by office.
$report = foreach ($g in $groups) {
    [PSCustomObject]@{
        Office    = $g.Name
        UserCount = $g.Count
        Users     = @($g.Group | Sort-Object SamAccountName |
                        Select-Object SamAccountName, DisplayName, Description, Enabled, DistinguishedName)
    }
}
$report | ConvertTo-Json -Depth 4 | Out-File -FilePath $jsonPath -Encoding UTF8
Write-Host "`nJSON written to: $jsonPath" -ForegroundColor Cyan
