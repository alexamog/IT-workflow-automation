<#
.SYNOPSIS
    Show a full detail card for a user (by SAM or UPN): identity, contact,
    org, account status, password info, and current OU.

.PARAMETER Identity
    SamAccountName or UPN. If omitted, you'll be prompted.

.EXAMPLE
    .\Get-UserDetails.ps1 alex.amog
#>

#Requires -Modules ActiveDirectory
param([string]$Identity)

. "$PSScriptRoot\..\..\lib\Common.ps1"

if (-not $Identity) { $Identity = Read-Host "Enter SAM or UPN" }

$props = 'DisplayName','EmailAddress','OfficePhone','MobilePhone','Title','Department',
         'Office','Manager','Enabled','LockedOut','LastLogonDate','PasswordLastSet',
         'PasswordExpired','PasswordNeverExpires','whenCreated','CanonicalName'

$user = Resolve-ADToolUser -Identity $Identity -Properties $props
if (-not $user) { return }

# Manager is stored as a DN; show just the name if set.
$managerName = if ($user.Manager) { (Get-ADUser -Identity $user.Manager).Name } else { '(none)' }
# Current OU = canonical path without the trailing user name.
$currentOU = ($user.CanonicalName -replace '/[^/]+$', '')

    Write-ToolHeader 'User Details'
[PSCustomObject][ordered]@{
    'Display Name'           = $user.DisplayName
    'SAM Account'            = $user.SamAccountName
    'UPN'                    = $user.UserPrincipalName
    'Email'                  = $user.EmailAddress
    'Office Phone'           = $user.OfficePhone
    'Mobile'                 = $user.MobilePhone
    'Title'                  = $user.Title
    'Department'             = $user.Department
    'Office (location)'      = $user.Office
    'Manager'                = $managerName
    'Enabled'                = $user.Enabled
    'Locked Out'             = $user.LockedOut
    'Last Logon'             = $user.LastLogonDate
    'Password Last Set'      = $user.PasswordLastSet
    'Password Expired'       = $user.PasswordExpired
    'Password Never Expires' = $user.PasswordNeverExpires
    'Created'                = $user.whenCreated
    'Current OU'             = $currentOU
} | Format-List

# Member Of: the groups this user belongs to.
Write-Host "Member Of (groups):" -ForegroundColor Cyan
try {
    $groups = Get-ADPrincipalGroupMembership -Identity $user.SamAccountName | Sort-Object Name
    if ($groups) { $groups | ForEach-Object { Write-Host "  - $($_.Name)" } }
    else         { Write-Host "  (none)" }
}
catch {
    Write-Host "  (could not retrieve groups: $($_.Exception.Message))" -ForegroundColor Yellow
}
