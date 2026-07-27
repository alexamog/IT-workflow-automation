<#
.SYNOPSIS
    Return the full OU path a user lives in (by SAM or UPN), copied to the
    clipboard ready to paste.

.PARAMETER Identity
    SamAccountName or UPN. If omitted, you'll be prompted.

.EXAMPLE
    .\Get-UserOUPath.ps1 alex.amog
#>

#Requires -Modules ActiveDirectory
param([string]$Identity)

. "$PSScriptRoot\..\..\lib\Common.ps1"

if (-not $Identity) { $Identity = Read-Host "Enter SAM or UPN" }

$user = Resolve-ADToolUser -Identity $Identity -Properties CanonicalName
if (-not $user) { return }

# Parent OU = DN with the leading "CN=<name>," removed.
$parentOU        = ($user.DistinguishedName -split ',', 2)[1]
# Readable path = canonical without the trailing user name.
$parentCanonical = ($user.CanonicalName -replace '/[^/]+$', '')

$parentOU | Set-Clipboard

Write-Host "`nUser : $($user.Name)  ($($user.SamAccountName))" -ForegroundColor Cyan
Write-Host "Path : $parentCanonical"          -ForegroundColor DarkCyan
Write-Host "OU   : $parentOU"                 -ForegroundColor Green
Write-Host "`n(OU path copied to clipboard)"  -ForegroundColor Yellow
