<#
.SYNOPSIS
    List Active Directory accounts that are currently locked out.
#>

#Requires -Modules ActiveDirectory

. "$PSScriptRoot\..\..\lib\Common.ps1"     # load the toolbox (keep the habit even if unused)

# Search-ADAccount is the fast, built-in way to find locked accounts domain-wide.
$locked = @(Search-ADAccount -LockedOut -UsersOnly)

if ($locked.Count -eq 0) {
    Write-Host "No accounts are currently locked out." -ForegroundColor Green
    return
}

$locked |
    Select-Object Name, SamAccountName, UserPrincipalName |
    Sort-Object Name |
    Format-Table -AutoSize

Write-Host ("`nLocked-out accounts: {0}" -f $locked.Count) -ForegroundColor Cyan
