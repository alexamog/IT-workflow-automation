<#
.SYNOPSIS
    Turn data\UsersOU-Paths.json into a human-readable navigation reference
    (output\UsersOU-Navigation.md).

.DESCRIPTION
    Look up a user's office/location name and read off exactly where to
    navigate the object in Active Directory Users and Computers.
#>

. "$PSScriptRoot\..\..\lib\Common.ps1"

$jsonPath = Join-Path (Get-ADToolDataDir)   'UsersOU-Paths.json'
$mdPath   = Join-Path (Get-ADToolOutputDir) 'UsersOU-Navigation.md'

if (-not (Test-Path $jsonPath)) {
    Write-Host "Cannot find $jsonPath - run Get-UsersOUPaths.ps1 first." -ForegroundColor Red
    return
}

# One simple row per entry: location, region, click-path.
$data = ConvertFrom-Json (Get-Content $jsonPath -Raw)   # assign first (PS 5.1 pipeline quirk)
$rows = foreach ($item in $data) {
    $segments = $item.CanonicalPath -split '/'
    [PSCustomObject]@{
        Location = $segments[-2]                                       # OU that holds "Users"
        Region   = $item.Region
        Navigate = ($segments -join ' -> ')                            # full click-path, domain root first
    }
}

# Build the Markdown as lines, then write it.
$lines = @(
    '# "Users" OU Navigation Reference'
    ''
    "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')  |  $($rows.Count) locations"
    ''
    "Look up the user's **Office / location name** to see where to navigate the object in ADUC."
    ''
    '## Alphabetical (by location)'
    ''
    '| Location (Office) | Region | Navigate to |'
    '| --- | --- | --- |'
)
$lines += $rows | Sort-Object Location | ForEach-Object {
    "| **$($_.Location)** | $($_.Region) | $($_.Navigate) |"
}
$lines += '', '## By region'
foreach ($group in ($rows | Group-Object Region | Sort-Object Name)) {
    $lines += '', "### $($group.Name)  ($($group.Count) locations)", ''
    $lines += $group.Group | Sort-Object Location | ForEach-Object {
        "- **$($_.Location)** -> $($_.Navigate)"
    }
}

$lines | Out-File -FilePath $mdPath -Encoding UTF8
Write-Host "Wrote $($rows.Count) locations to: $mdPath" -ForegroundColor Green
