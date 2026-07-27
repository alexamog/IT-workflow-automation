<#
.SYNOPSIS
    Store the Snipe-IT API token (and optional URL) as user environment
    variables, so the toolkit can read them without the token living in source.

.DESCRIPTION
    Sets SNIPEIT_TOKEN and SNIPEIT_URL for the current user (persisted) and in
    the current session. Run once per machine / per user.

.EXAMPLE
    .\setup\Set-SnipeCredentials.ps1
#>

# Prompt for the token (masked) and convert back to plain text to store.
$secure = Read-Host "Paste the Snipe-IT API token (no 'Bearer ' prefix)" -AsSecureString
$token  = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)).Trim()

if (-not $token) { Write-Host "No token entered. Nothing changed." -ForegroundColor Yellow; return }

# Base URL (press ENTER to keep whatever is already set).
$url = Read-Host "Snipe-IT API base URL (e.g. https://assets.contoso.com/api/v1 - ENTER to keep existing '$env:SNIPEIT_URL')"
if (-not $url) { $url = $env:SNIPEIT_URL }
if (-not $url) { Write-Host "No Snipe-IT URL set yet - re-run this and enter one before using the asset tools." -ForegroundColor Yellow }

# Persist for this user and apply to the current session.
[Environment]::SetEnvironmentVariable('SNIPEIT_TOKEN', $token, 'User')
[Environment]::SetEnvironmentVariable('SNIPEIT_URL',   $url,   'User')
$env:SNIPEIT_TOKEN = $token
$env:SNIPEIT_URL   = $url

Write-Host "`nSaved." -ForegroundColor Green
Write-Host "  SNIPEIT_URL   = $url"
Write-Host "  SNIPEIT_TOKEN = set ($($token.Length) chars)"
Write-Host "`nOpen a new PowerShell window for other sessions to pick up the change." -ForegroundColor DarkGray
