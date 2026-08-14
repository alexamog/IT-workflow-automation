<#
.SYNOPSIS
    Audit: which Tactical RMM computers are NOT recorded in Snipe-IT assets.

.DESCRIPTION
    For every agent in Tactical RMM, searches Snipe-IT for its hostname. A
    hostname counts as FOUND when a Snipe asset's name, asset tag, or serial
    matches it. The ones with no match are the gaps - machines you may have
    missed adding to Snipe-IT.

    Writes the missing list to JSON (parse) and HTML (read) in
    output\SnipeAudit\.

    Needs TRMM (TRMM_APIKEY / TRMM_URL) AND Snipe-IT (SNIPEIT_TOKEN). Set both
    once with ..\..\setup\Set-TacticalCredentials.ps1 and Set-SnipeCredentials.ps1.

.EXAMPLE
    .\Compare-TrmmToSnipe.ps1
#>

# NOT ON THE MAIN MENU, and that is deliberate - there is no .tool.psd1
# manifest beside this file, so the launcher never lists it. It is opened
# from Invoke-TrmmSnipeAudit.ps1, which collects the answers it needs first.
# It still runs on its own if you want to use it directly.

[CmdletBinding()]
param()

. "$PSScriptRoot\..\..\lib\Common.ps1"

if (-not (Test-TrmmConfigured)) { return }
if (-not $ADTool.SnipeIT.Token) {
    Write-Host "SNIPEIT_TOKEN is not set. Run setup\Set-SnipeCredentials.ps1 first." -ForegroundColor Red
    return
}

# Is this hostname recorded in Snipe-IT?
#   $true   found
#   $false  genuinely not there - this is a real gap to report
#   $null   the lookup FAILED, so we do not know either way. The caller keeps
#           these separate from the misses; reporting "not in Snipe-IT" because
#           the search timed out would send somebody hunting for nothing.
#
# Snipe's search is fuzzy, so a match is confirmed in two passes: first an exact
# match on name, asset tag or serial, then a looser "the name contains it".
# Exact wins, so a machine is never mistaken for a similarly-named one when a
# real match exists.
function Test-InSnipe ($hostname) {
    # Retry a few times so a transient Snipe-IT hiccup isn't logged as an error.
    $rows = $null
    for ($try = 1; $try -le 3; $try++) {
        try { $rows = @((Invoke-SnipeRequest -Path 'hardware' -Query @{ search = $hostname; limit = 10 }).rows); break }
        catch { if ($try -eq 3) { return $null }; Start-Sleep -Seconds 2 }
    }
    foreach ($r in $rows) {
        foreach ($v in @($r.name, $r.asset_tag, $r.serial)) {
            if ($v -and ($v -ieq $hostname)) { return $true }              # exact match
        }
    }
    foreach ($r in $rows) {
        if ($r.name -and ($r.name -match [regex]::Escape($hostname))) { return $true }  # name contains it
    }
    return $false
}

Write-Host "Getting the agent list from Tactical RMM..."
$lookup = Get-TrmmAgent
if (-not $lookup.Ok) { return }        # the message was already printed
$agents = $lookup.Agents
Write-Host "Checking $($agents.Count) agent(s) against Snipe-IT (one search each)..." -ForegroundColor DarkGray

$missing = @()
$errors  = @()
$found   = 0
$i = 0
foreach ($a in $agents) {
    $i++
    Write-Progress -Activity 'Checking Snipe-IT' -Status "$i of $($agents.Count): $($a.hostname)" -PercentComplete (100 * $i / $agents.Count)
    $res = Test-InSnipe $a.hostname
    if ($res -eq $true) { $found++; continue }

    $row = [PSCustomObject][ordered]@{
        Hostname = $a.hostname
        Client   = $a.client_name
        Site     = $a.site_name
        Status   = $a.status
        LastSeen = $a.last_seen
        User     = $a.logged_username
    }
    if ($null -eq $res) { $errors += $row } else { $missing += $row }
}
Write-Progress -Activity 'Checking Snipe-IT' -Completed

$missing = @($missing | Sort-Object Hostname)
Write-Host ""
Write-Host ("In Snipe-IT: {0}   Missing: {1}   Lookup errors: {2}" -f $found, $missing.Count, $errors.Count) -ForegroundColor Cyan
if ($missing.Count -eq 0 -and $errors.Count -eq 0) { Write-Host "Every TRMM computer is in Snipe-IT." -ForegroundColor Green; return }

# --- Write JSON + HTML -------------------------------------------------------
$dir = Get-ADToolOutputDir -Category 'Audits\SnipeAudit'
$stamp = Get-Date -Format 'yyyy-MM-dd HHmmss'
$json  = Join-Path $dir "TRMM-Snipe Audit - $stamp.json"
$html  = Join-Path $dir "TRMM-Snipe Audit - $stamp.html"
$when  = Get-Date -Format 'yyyy-MM-dd HH:mm'

[ordered]@{
    generatedAt   = (Get-Date -Format 'o')
    generatedBy   = $env:USERNAME
    totalAgents   = $agents.Count
    inSnipe       = $found
    missingCount  = $missing.Count
    lookupErrors  = @($errors)
    missing       = @($missing)
} | ConvertTo-Json -Depth 6 | Out-File -FilePath $json -Encoding UTF8

$meta = "$($missing.Count) missing of $($agents.Count) agent(s) &middot; $found in Snipe-IT &middot; " +
        "$($errors.Count) lookup error(s) &middot; generated $when by $(ConvertTo-HtmlEncodedText $env:USERNAME)"

Write-Host "Report written to:" -ForegroundColor Green
Write-Host "  $json"
Write-Host "  $html"

# The page itself (and the offer to open it) comes from the shared writer, so
# every report in the toolkit looks the same and escapes its values the same.
Write-DeskSideHtmlReport -Rows $missing -Columns 'Hostname', 'Client', 'Site', 'Status', 'LastSeen', 'User' `
    -Title 'TRMM computers not in Snipe-IT' -Path $html -MetaHtml $meta | Out-Null
