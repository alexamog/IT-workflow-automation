<#
.SYNOPSIS
    Launch AD-Toolkit.ps1 as your AD admin account using runas /savecred, so the
    password is typed only ONCE and cached in Windows Credential Manager.

.DESCRIPTION
    The first run prompts for your admin password (runas saves it). Every run
    after that starts without prompting. Your admin USERNAME is remembered in the
    DESKSIDE_ADMIN_USER environment variable (a username is not secret).

    SECURITY: with /savecred, the saved password can be reused by anything that
    runs 'runas /savecred' for this account on this machine. Lock your screen
    (Win+L) when you step away, and only do this if your organization allows
    caching admin credentials.

    To view or remove the saved password later:
        cmdkey /list                 # find the entry (target starts with Domain:)
        cmdkey /delete:<target>      # remove it
#>

$toolkit = Join-Path $PSScriptRoot 'AD-Toolkit.ps1'

# The admin account to run as. Remembered after the first time (username only).
$adminUser = [Environment]::GetEnvironmentVariable('DESKSIDE_ADMIN_USER', 'User')
if (-not $adminUser) {
    $adminUser = Read-Host "Your AD admin account (e.g. CONTOSO\admin.you)"
    if (-not $adminUser) { Write-Host "Cancelled." -ForegroundColor Yellow; return }
    [Environment]::SetEnvironmentVariable('DESKSIDE_ADMIN_USER', $adminUser, 'User')
}

# Build the command runas will launch. -EncodedCommand avoids any quoting issues
# with the spaces in the folder path.
$launch = "Set-Location '$PSScriptRoot'; & '$toolkit'"
$enc    = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($launch))
$inner  = "powershell.exe -NoExit -ExecutionPolicy Bypass -EncodedCommand $enc"

Write-Host "Starting the toolkit as $adminUser ..." -ForegroundColor Cyan
Write-Host "(First time only: enter the password when runas asks - it is then saved.)" -ForegroundColor DarkGray

# /savecred caches the password after the first successful entry.
runas /savecred /user:$adminUser $inner
