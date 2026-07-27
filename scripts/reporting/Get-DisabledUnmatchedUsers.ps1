<#
.SYNOPSIS
    List all disabled user accounts in the Initial Import - Unmatched Accounts
    OU (path configured in lib\Common.ps1).
#>

#Requires -Modules ActiveDirectory

. "$PSScriptRoot\..\..\lib\Common.ps1"

if (-not $ADTool.SourceOU) {
    Write-Host "No 'unmatched accounts' OU is configured." -ForegroundColor Yellow
    Write-Host "Set AD_SOURCE_OU with .\setup\Set-ToolConfig.ps1 and try again." -ForegroundColor Yellow
    return
}

# Disabled accounts under the configured source OU (Subtree includes nested OUs).
$disabledUsers = Get-ADUser -SearchBase $ADTool.SourceOU -SearchScope Subtree -Filter 'Enabled -eq $false' `
    -Properties DisplayName, whenCreated, LastLogonDate |
    Select-Object DisplayName, SamAccountName, UserPrincipalName, whenCreated, LastLogonDate, DistinguishedName

$disabledUsers | Sort-Object SamAccountName | Format-Table -AutoSize
Write-Host ("`nTotal disabled users found: {0}" -f @($disabledUsers).Count) -ForegroundColor Cyan
