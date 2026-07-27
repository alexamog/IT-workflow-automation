<#
.SYNOPSIS
    View and set the toolkit's configurable environment variables, so URLs,
    OUs, and the domain can be changed without editing any code.

.DESCRIPTION
    Shows the current value of each setting, then lets you update it (press
    ENTER to keep the current value). Values are saved for the current Windows
    user and applied to this session.

    Settings handled here (all non-secret):
      SNIPEIT_URL        - Snipe-IT API base URL
      AD_DOMAIN_DN  - AD domain DN (blank = auto-detected from the domain)
      AD_SOURCE_OU  - the "Unmatched Accounts" OU (for the reports)
      AD_REGIONS    - semicolon-separated list of region OUs
      ONBOARDING_GROUP   - group new users are added to (blank = skip that step)
      EMAIL_DOMAIN       - email domain for the onboarding message (blank = from UPN)
      SPO_TIMEZONE       - SharePoint site time-zone id (e.g. 13 = Pacific)

    Secret / system-specific values are set by their own scripts: the Snipe-IT
    token (Set-SnipeCredentials), Tactical RMM (Set-TacticalCredentials), Exchange
    admin (Set-ExchangeAdmin), SharePoint/Graph (Set-M365Config), and Jira
    (Jira Scripts\Set-JiraCredentials). Nothing here is organisation-specific in
    code - the examples below are just illustrations.

.EXAMPLE
    .\setup\Set-ToolConfig.ps1
#>

# name -> description + example (shown only as a hint; ENTER keeps the current
# value and never writes the example).
$settings = [ordered]@{
    'SNIPEIT_URL'       = @{ Desc = 'Snipe-IT API base URL';                Default = 'https://assets.contoso.com/api/v1' }
    'AD_DOMAIN_DN' = @{ Desc = 'AD domain DN (blank = auto-detect)';   Default = 'DC=contoso,DC=local' }
    'AD_SOURCE_OU' = @{ Desc = 'Unmatched Accounts OU';               Default = 'OU=Unmatched,OU=NewUsers,DC=contoso,DC=local' }
    'AD_REGIONS'   = @{ Desc = 'Region OUs (separate with ;)';         Default = 'OU=Region A,DC=contoso,DC=local;OU=Region B,DC=contoso,DC=local' }
    'ONBOARDING_GROUP'  = @{ Desc = 'Group new users join (blank = skip)';  Default = 'All Staff Distribution' }
    'EMAIL_DOMAIN'      = @{ Desc = 'Email domain (blank = from the UPN)';  Default = 'contoso.com' }
    'SPO_TIMEZONE'      = @{ Desc = 'SharePoint site time-zone id';         Default = '13' }
}

Write-Host "`nToolkit configuration" -ForegroundColor Cyan
Write-Host "Press ENTER at a prompt to keep the current value.`n" -ForegroundColor DarkGray

foreach ($name in $settings.Keys) {
    $current = [Environment]::GetEnvironmentVariable($name, 'User')
    $shown   = if ($current) { $current } else { "(not set; default: $($settings[$name].Default))" }

    Write-Host ("{0}" -f $name) -ForegroundColor Green
    Write-Host ("  {0}" -f $settings[$name].Desc)
    Write-Host ("  current: {0}" -f $shown)

    $new = Read-Host "  new value"
    if ($new) {
        [Environment]::SetEnvironmentVariable($name, $new, 'User')
        Set-Item -Path "Env:$name" -Value $new
        Write-Host "  saved." -ForegroundColor Green
    } else {
        Write-Host "  unchanged." -ForegroundColor DarkGray
    }
    Write-Host ""
}

Write-Host "Done. Open a new PowerShell window for other sessions to pick up changes." -ForegroundColor Cyan
Write-Host "To set the secret Snipe-IT token, run: .\setup\Set-SnipeCredentials.ps1" -ForegroundColor DarkGray
