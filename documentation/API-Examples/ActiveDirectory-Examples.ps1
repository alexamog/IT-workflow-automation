<#
    ActiveDirectory-Examples.ps1  -  minimal AD skeletons (module, not REST).
    Needs the RSAT ActiveDirectory module and rights to read/modify the directory.
    Dot-source it, then call the functions. The write ones change real accounts -
    test on a lab user first.
#>

Import-Module ActiveDirectory -ErrorAction SilentlyContinue

# Find one user by SAM, UPN/email, or display name.
function Find-User ($id) {
    $sam = ($id -split '@')[0]
    Get-ADUser -Filter "SamAccountName -eq '$sam' -or UserPrincipalName -eq '$id' -or EmailAddress -eq '$id' -or DisplayName -eq '$id'" `
        -Properties DisplayName, EmailAddress, Department, Office, Enabled, LockedOut, MemberOf | Select-Object -First 1
}

# List everyone who is locked out.
function Get-LockedOut { Search-ADAccount -LockedOut -UsersOnly }

# Reset the password and force a change at next logon.
function Reset-Password ($id, $newPassword) {
    $u = Find-User $id
    Set-ADAccountPassword $u -Reset -NewPassword (ConvertTo-SecureString $newPassword -AsPlainText -Force)
    Set-ADUser $u -ChangePasswordAtLogon $true
}

# Unlock / enable / disable an account.
function Unlock-User  ($id) { Unlock-ADAccount  (Find-User $id) }
function Enable-User  ($id) { Enable-ADAccount  (Find-User $id) }
function Disable-User ($id) { Disable-ADAccount (Find-User $id) }

# Add to a group by group name.
function Add-ToGroup ($id, $groupName) { Add-ADGroupMember -Identity $groupName -Members (Find-User $id) }

# Move to a different OU (full distinguished name).
function Move-User ($id, $targetOu) { Move-ADObject (Find-User $id) -TargetPath $targetOu }

# --- examples ---
# Find-User 'firstname.lastname'
# Get-LockedOut
# Reset-Password 'firstname.lastname' 'ChangeMe123!'
# Add-ToGroup 'firstname.lastname' 'All Staff Distribution'
# Move-User 'firstname.lastname' 'OU=Disabled Users,OU=All Locations,DC=contoso,DC=local'
