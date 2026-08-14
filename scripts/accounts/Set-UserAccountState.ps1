<#
.SYNOPSIS
    Lock/unlock an AD account (by SAM or UPN): unlock, disable, or enable.

.DESCRIPTION
    "Unlock" clears a lockout from bad password attempts. AD has no manual
    "lock", so to lock someone out of the domain you "Disable" the account
    (and "Enable" to restore access).

.PARAMETER Identity
    SamAccountName or UPN. If omitted, you'll be prompted.

.EXAMPLE
    .\Set-UserAccountState.ps1 alex.amog
#>

#Requires -Modules ActiveDirectory
param([string]$Identity)

. "$PSScriptRoot\..\..\lib\Common.ps1"

if (-not $Identity) { $Identity = Read-Host "Enter SAM or UPN" }

$user = Resolve-ADToolUser -Identity $Identity -Properties LockedOut, Enabled
if (-not $user) { return }
$sam = $user.SamAccountName

Write-Host "`nUser     : $($user.Name)  ($sam)" -ForegroundColor Cyan
Write-Host "Enabled  : $($user.Enabled)"
Write-Host "LockedOut: $($user.LockedOut)"

Write-Host ""
Write-Host "  1. Unlock account (clear lockout)"
Write-Host "  2. Disable account (lock out of domain)"
Write-Host "  3. Enable account"
Write-Host "  0. Cancel"

# Map each choice to its cmdlet + log label so the logic stays uniform.
$actions = @{
    '1' = @{ Label = 'Unlock Account';  Do = { Unlock-ADAccount  -Identity $sam -ErrorAction Stop } }
    '2' = @{ Label = 'Disable Account'; Do = { Disable-ADAccount -Identity $sam -ErrorAction Stop } }
    '3' = @{ Label = 'Enable Account';  Do = { Enable-ADAccount  -Identity $sam -ErrorAction Stop } }
}

$choice = Read-Host "Choose an action"
if (-not $actions.ContainsKey($choice)) { Write-Host "No change made." -ForegroundColor Yellow; return }

$action = $actions[$choice]
try {
    & $action.Do
    Write-Host "$($action.Label) - done." -ForegroundColor Green
    Write-ActionLog -Action $action.Label -Target $sam
}
catch {
    Write-DeskSideFailure "Failed" $action.Label $sam $_
}
