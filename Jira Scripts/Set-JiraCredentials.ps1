<#
    Set-JiraCredentials.ps1
    ------------------------
    Run this ONCE to store your Jira credentials as user environment variables.
    Nothing is written into the other scripts, and the token is not saved in
    plain text anywhere in this folder.

    After running it, CLOSE and REOPEN PowerShell so the new variables load,
    then run Get-MyJiraTickets.ps1.
#>

Write-Host "Setting up Jira credentials (stored as user environment variables)..." -ForegroundColor Cyan
Write-Host ""

$email   = Read-Host "Your Atlassian email"
$baseUrl = Read-Host "Your Jira base URL (e.g. https://contoso.atlassian.net)"

# Read the token as a secure string so it isn't echoed to the screen
$secureToken = Read-Host "Your Jira API token" -AsSecureString
$token = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
)

# Trim any trailing slash from the base URL
$baseUrl = $baseUrl.TrimEnd('/')

[System.Environment]::SetEnvironmentVariable('JIRA_EMAIL',   $email,   'User')
[System.Environment]::SetEnvironmentVariable('JIRA_BASEURL', $baseUrl, 'User')
[System.Environment]::SetEnvironmentVariable('JIRA_API_TOKEN', $token, 'User')

Write-Host ""
Write-Host "Saved. Close and reopen PowerShell, then run Get-MyJiraTickets.ps1" -ForegroundColor Green
