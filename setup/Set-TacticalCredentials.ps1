<#
.SYNOPSIS
    Store the Tactical RMM API key and URL as user environment variables,
    so the toolkit can read them without the key living in source.

.DESCRIPTION
    Sets TRMM_APIKEY and TRMM_URL for the current user (persisted) and in
    the current session. Run once per machine / per user.

    To create an API key in Tactical RMM (needs an admin account):
      1. Log into the TRMM web UI.
      2. Settings (gear icon) > Global Settings > API Keys > Add Key.
      3. Give it a name, pick the user it acts as, set an expiry (or leave blank).
      4. Copy the generated key - it is only shown once.

.EXAMPLE
    .\setup\Set-TacticalCredentials.ps1
#>

# Prompt for the API key (masked) and convert back to plain text to store.
$secure = Read-Host "Paste the Tactical RMM API key" -AsSecureString
$apiKey = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)).Trim()

if (-not $apiKey) { Write-Host "No key entered. Nothing changed." -ForegroundColor Yellow; return }

# The API URL is the api. subdomain of your TRMM install, no trailing slash.
# NOTE: this is the api. address, NOT the rmm. web UI address you log into.
$url = Read-Host "Tactical RMM API URL (e.g. https://api.contoso.com - ENTER to keep existing '$env:TRMM_URL')"
if (-not $url) { $url = $env:TRMM_URL }
if (-not $url) { Write-Host "No URL entered and none saved previously. Nothing changed." -ForegroundColor Yellow; return }

# Persist for this user and apply to the current session.
[Environment]::SetEnvironmentVariable('TRMM_APIKEY', $apiKey, 'User')
[Environment]::SetEnvironmentVariable('TRMM_URL',    $url,    'User')
$env:TRMM_APIKEY = $apiKey
$env:TRMM_URL    = $url

Write-Host "`nSaved." -ForegroundColor Green
Write-Host "  TRMM_URL    = $url"
Write-Host "  TRMM_APIKEY = set ($($apiKey.Length) chars)"
Write-Host "`nOpen a new PowerShell window for other sessions to pick up the change." -ForegroundColor DarkGray

# Quick connectivity test so you know right away if the key works.
$test = Read-Host "`nTest the connection now? (Y/n)"
if ($test -ne 'n') {
    try {
        $clients = Invoke-RestMethod -Uri "$($url.TrimEnd('/'))/clients/" -Headers @{ 'X-API-KEY' = $apiKey }
        Write-Host "Connected. $(@($clients).Count) client(s) visible." -ForegroundColor Green
    }
    catch {
        Write-Host "Connection FAILED: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Check the URL (must be the api. subdomain) and that the key was copied fully." -ForegroundColor Yellow
    }
}
