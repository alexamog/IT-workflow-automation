<#
.SYNOPSIS
    Save your Exchange Online admin address so the toolkit can prefill the
    sign-in. Run once per machine / per user.

.DESCRIPTION
    Sets EXO_ADMIN_UPN (your admin user principal name, e.g.
    admin@contoso.com) for the current user and session. This is only a
    convenience - Exchange sign-in is still interactive (a Microsoft window),
    and no password is stored. Without it the tools just ask for the address.

    The Exchange features also need the ExchangeOnlineManagement module. If it
    is missing, install it once (no admin rights needed):
        Install-Module ExchangeOnlineManagement -Scope CurrentUser

.EXAMPLE
    .\setup\Set-ExchangeAdmin.ps1
#>

$upn = Read-Host "Your Exchange Online admin address (e.g. admin@contoso.com - ENTER to keep existing '$env:EXO_ADMIN_UPN')"
if (-not $upn) { $upn = $env:EXO_ADMIN_UPN }
if (-not $upn) { Write-Host "Nothing entered and none saved before. Nothing changed." -ForegroundColor Yellow; return }

[Environment]::SetEnvironmentVariable('EXO_ADMIN_UPN', $upn, 'User')
$env:EXO_ADMIN_UPN = $upn

Write-Host "`nSaved." -ForegroundColor Green
Write-Host "  EXO_ADMIN_UPN = $upn"
Write-Host "`nOpen a new PowerShell window for other sessions to pick up the change." -ForegroundColor DarkGray

# Check the module is there, and offer to install it if not.
if (Get-Module -ListAvailable -Name ExchangeOnlineManagement) {
    Write-Host "ExchangeOnlineManagement module: found." -ForegroundColor Green
}
else {
    Write-Host "ExchangeOnlineManagement module: NOT installed." -ForegroundColor Yellow
    if ((Read-Host "Install it now for your user? (Y/n)").Trim().ToUpper() -ne 'N') {
        try {
            Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force -ErrorAction Stop
            Write-Host "Installed." -ForegroundColor Green
        }
        catch { Write-Host "Install failed: $($_.Exception.Message)" -ForegroundColor Red }
    }
    else {
        Write-Host "Install it later with:  Install-Module ExchangeOnlineManagement -Scope CurrentUser" -ForegroundColor DarkGray
    }
}
