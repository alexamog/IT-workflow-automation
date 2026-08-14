<#
.SYNOPSIS
    Profile tools for Tactical RMM computers, in one place: find a user's
    profile, scan for corrupt ones, and repair corrupt ones without deleting.

.DESCRIPTION
    A small menu that launches the three profile scripts. They also still run on
    their own (e.g. .\Find-TrmmCorruptProfile.ps1); this just keeps the Remote
    menu tidy by grouping them behind one entry.

    Needs TRMM_APIKEY / TRMM_URL - run ..\..\setup\Set-TacticalCredentials.ps1 once.

.EXAMPLE
    .\Manage-TrmmProfiles.ps1
#>

[CmdletBinding()]
param()

. "$PSScriptRoot\..\..\lib\Common.ps1"

if (-not (Test-TrmmConfigured)) { return }

$here = $PSScriptRoot

# The :menu label lets the default branch below skip the "press ENTER" pause.
# A bare 'continue' inside a switch does NOT do that - it leaves the switch and
# carries straight on, so a mistyped option used to print "Unknown option." and
# then still make you press ENTER for a menu you never left.
:menu while ($true) {
    Write-ToolHeader 'TRMM Profiles'
    Write-ToolMenuItem -Key 1 -Label "Find a user's profile across computers"
    Write-ToolMenuItem -Key 2 -Label 'Scan computers for corrupt profiles'
    Write-ToolMenuItem -Key 3 -Label 'Repair corrupt profiles' -Note 'fix the registry, keep the data'
    Write-ToolMenuItem -Key 0 -Label 'Back'
    Write-Host ''

    switch ((Read-Host '  Select').Trim()) {
        '1'     { & (Join-Path $here 'Find-TrmmUserProfile.ps1') }
        '2'     { & (Join-Path $here 'Find-TrmmCorruptProfile.ps1') }
        '3'     { & (Join-Path $here 'Repair-TrmmCorruptProfile.ps1') }
        '0'     { return }
        default { Write-Host 'Unknown option.' -ForegroundColor DarkGray; continue menu }
    }
    Write-Host ''
    Read-Host '  Press ENTER to return to the profile menu' | Out-Null
}
