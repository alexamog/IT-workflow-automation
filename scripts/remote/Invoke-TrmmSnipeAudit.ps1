<#
.SYNOPSIS
    Cross-check Tactical RMM against Snipe-IT: computers missing from Snipe-IT,
    and serial/hostname mismatches.

.DESCRIPTION
    A small menu that launches the two audit scripts. They also still run on
    their own; this just keeps the Remote menu tidy by grouping them behind one
    entry.

    Needs TRMM (TRMM_APIKEY / TRMM_URL) AND Snipe-IT (SNIPEIT_TOKEN) - each audit
    checks for the credentials it needs and tells you if one is missing.

.EXAMPLE
    .\Invoke-TrmmSnipeAudit.ps1
#>

[CmdletBinding()]
param()

. "$PSScriptRoot\..\..\lib\Common.ps1"

if (-not (Test-TrmmConfigured)) { return }

$here = $PSScriptRoot

while ($true) {
    Write-ToolHeader 'TRMM vs Snipe-IT audit'
    Write-ToolMenuItem -Key 1 -Label 'Computers in TRMM missing from Snipe-IT'
    Write-ToolMenuItem -Key 2 -Label 'Match serials to Snipe-IT' -Note 'hostname check; can fix'
    Write-ToolMenuItem -Key 0 -Label 'Back'
    Write-Host ''

    switch ((Read-Host '  Select').Trim()) {
        '1'     { & (Join-Path $here 'Compare-TrmmToSnipe.ps1') }
        '2'     { & (Join-Path $here 'Compare-TrmmSerialToSnipe.ps1') }
        '0'     { return }
        default { Write-Host 'Unknown option.' -ForegroundColor DarkGray; continue }
    }
    Write-Host ''
    Read-Host '  Press ENTER to return to the audit menu' | Out-Null
}
