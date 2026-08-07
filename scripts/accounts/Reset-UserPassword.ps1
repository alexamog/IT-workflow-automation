<#
.SYNOPSIS
    Reset a user's password (by SAM or UPN), optionally forcing a change at
    next logon.

.PARAMETER Identity
    SamAccountName or UPN. If omitted, you'll be prompted.

.EXAMPLE
    .\Reset-UserPassword.ps1 alex.amog
#>

#Requires -Modules ActiveDirectory
param([string]$Identity)

. "$PSScriptRoot\..\..\lib\Common.ps1"

if (-not $Identity) { $Identity = Read-Host "Enter SAM or UPN" }

$user = Resolve-ADToolUser -Identity $Identity
if (-not $user) { return }

Write-Host "`nResetting password for: $($user.Name)  ($($user.SamAccountName))" -ForegroundColor Cyan

# New password, entered twice (masked) and checked.
$pw1 = Read-Host "Enter new password"   -AsSecureString
$pw2 = Read-Host "Confirm new password" -AsSecureString
$plain1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw1))
$plain2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw2))

if ($plain1 -ne $plain2)                  { Write-Host "Passwords do not match. Aborted." -ForegroundColor Red; return }
if ([string]::IsNullOrWhiteSpace($plain1)){ Write-Host "Password cannot be empty. Aborted." -ForegroundColor Red; return }

# Reset.
try {
    Set-ADAccountPassword -Identity $user.SamAccountName -Reset -NewPassword $pw1 -ErrorAction Stop
    Write-Host "Password reset successfully." -ForegroundColor Green
    Write-ActionLog -Action 'Reset Password' -Target $user.SamAccountName
}
catch {
    Write-Host "Failed to reset password: $($_.Exception.Message)" -ForegroundColor Red
    Write-ActionLog -Action 'Reset Password' -Target $user.SamAccountName -Result 'Failed' -Details $_.Exception.Message
    return
}

# Optional: require change at next logon.
# -ErrorAction Stop matters here: without it Set-ADUser reports a failure
# without stopping, so the green line and the 'Success' audit row below would
# both be written for a change that never happened.
if ((Read-Host "Force the user to change password at next logon? (Y/N)") -match '^[Yy]') {
    try {
        Set-ADUser -Identity $user.SamAccountName -ChangePasswordAtLogon $true -ErrorAction Stop
        Write-Host "User must change password at next logon." -ForegroundColor Green
        Write-ActionLog -Action 'Force Password Change' -Target $user.SamAccountName
    }
    catch {
        Write-Host "Could not set the change-at-next-logon flag: $($_.Exception.Message)" -ForegroundColor Red
        Write-ActionLog -Action 'Force Password Change' -Target $user.SamAccountName -Result 'Failed' -Details $_.Exception.Message
    }
}
