<#
.SYNOPSIS
    Look up a user by SAM or UPN, show their Office and current OU, then
    optionally move the account to an OU path you paste in.

.PARAMETER Identity
    SamAccountName or UPN. If omitted, you'll be prompted.

.EXAMPLE
    .\Move-UserByOUPath.ps1 alex.amog
#>

#Requires -Modules ActiveDirectory
param([string]$Identity)

. "$PSScriptRoot\..\..\lib\Common.ps1"

if (-not $Identity) { $Identity = Read-Host "Enter SAM or UPN" }

$user = Resolve-ADToolUser -Identity $Identity -Properties Office, CanonicalName
if (-not $user) { return }

$currentOU = ($user.DistinguishedName -split ',', 2)[1]
$office    = if ($user.Office) { $user.Office } else { '(no office set)' }

Write-Host "`nUser    : $($user.Name)  ($($user.SamAccountName))" -ForegroundColor Cyan
Write-Host "Office  : $office"   -ForegroundColor Green
Write-Host "Current : $currentOU" -ForegroundColor DarkCyan

Write-Host ""
$target = Read-Host "Paste destination OU path to move to (or press ENTER to skip)"
if (-not $target) { Write-Host "No move performed." -ForegroundColor Yellow; return }

# Validate the destination OU before moving.
try { Get-ADOrganizationalUnit -Identity $target -ErrorAction Stop | Out-Null }
catch { Write-Host "Destination OU not found: $target" -ForegroundColor Red; return }

if (-not (Confirm-DeskSideAction "Move $($user.Name) to this OU?" -Quiet)) {
    Write-Host "Cancelled." -ForegroundColor Yellow
    return
}

try {
    Move-ADObject -Identity $user.DistinguishedName -TargetPath $target -ErrorAction Stop
    Write-Host "Moved successfully to: $target" -ForegroundColor Green
    Write-ActionLog -Action 'Move User' -Target $user.SamAccountName -Details "To $target"
}
catch {
    Write-DeskSideFailure "Move failed" 'Move User' $user.SamAccountName $_ -Context "$target"
}
