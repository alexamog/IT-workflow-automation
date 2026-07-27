<#
.SYNOPSIS
    Find every "Users" OU (also matches the mis-spelled "User") within the
    configured regions, and save their full paths to data\UsersOU-Paths.json.

.DESCRIPTION
    Regions are defined in lib\Common.ps1 ($ADTool.Regions). One site spelled
    the OU "User" (singular), so both spellings are matched and the singular
    ones are flagged for cleanup.
#>

#Requires -Modules ActiveDirectory

. "$PSScriptRoot\..\..\lib\Common.ps1"

if (@($ADTool.Regions).Count -eq 0) {
    Write-Host "No region OUs are configured." -ForegroundColor Yellow
    Write-Host "Set AD_REGIONS (semicolon-separated OUs) with .\setup\Set-ToolConfig.ps1 and try again." -ForegroundColor Yellow
    return
}

$jsonPath = Join-Path (Get-ADToolDataDir) 'UsersOU-Paths.json'

$results = foreach ($region in $ADTool.Regions) {

    # Skip a region that doesn't resolve, with a warning.
    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$region'" -ErrorAction SilentlyContinue)) {
        Write-Host "Region OU not found (skipping): $region" -ForegroundColor Yellow
        continue
    }

    $regionName = ($region -split ',')[0] -replace '^OU='

    Get-ADOrganizationalUnit -SearchBase $region -SearchScope Subtree `
        -Filter "Name -eq 'Users' -or Name -eq 'User'" -Properties CanonicalName |
        ForEach-Object {
            [PSCustomObject]@{
                Region            = $regionName
                Name              = $_.Name            # "Users" or "User"
                CanonicalPath     = $_.CanonicalName
                DistinguishedName = $_.DistinguishedName
            }
        }
}

$results = @($results | Sort-Object Region, DistinguishedName)

Write-Host ("Found {0} user OU(s)." -f $results.Count) -ForegroundColor Cyan
$results | Format-Table Region, Name, DistinguishedName -AutoSize | Out-Host

# Flag any singular "User" OUs for renaming.
$singular = @($results | Where-Object Name -eq 'User')
if ($singular) {
    Write-Host "`nMis-spelled 'User' OU(s) found (consider renaming to 'Users'):" -ForegroundColor Yellow
    $singular | ForEach-Object { Write-Host ("  - {0}" -f $_.DistinguishedName) }
}

$results | ConvertTo-Json -Depth 3 | Out-File -FilePath $jsonPath -Encoding UTF8
Write-Host "`nJSON written to: $jsonPath" -ForegroundColor Cyan
