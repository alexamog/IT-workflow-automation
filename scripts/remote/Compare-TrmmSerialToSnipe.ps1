<#
.SYNOPSIS
    Audit by SERIAL: take each Tactical RMM computer's serial number, look it up
    in Snipe-IT, and check the Snipe-IT hostname matches the TRMM hostname.

.DESCRIPTION
    Serial numbers are unique, so this catches problems a hostname search can't:
      - NoSerial          TRMM has no serial for the machine
      - NotInSnipe        the serial is not in Snipe-IT (missing asset)
      - HostnameMismatch  the serial IS in Snipe-IT but under a different name
                          (e.g. renamed machine, wrong asset, swapped tag)
    Machines whose serial is found AND the name matches are fine and omitted.

    Writes the problems to JSON (parse) and HTML (read) in output\SnipeAudit\.

    Needs TRMM (TRMM_APIKEY / TRMM_URL) AND Snipe-IT (SNIPEIT_TOKEN).

.EXAMPLE
    .\Compare-TrmmSerialToSnipe.ps1
#>

[CmdletBinding()]
param()

. "$PSScriptRoot\..\..\lib\Common.ps1"

if (-not (Test-TrmmConfigured)) { return }
if (-not $ADTool.SnipeIT.Token) {
    Write-Host "SNIPEIT_TOKEN is not set. Run setup\Set-SnipeCredentials.ps1 first." -ForegroundColor Red
    return
}

# Find the Snipe asset whose serial equals $serial (exact, case-insensitive).
function Get-SnipeBySerial ($serial) {
    $rows = @((Invoke-SnipeRequest -Path 'hardware' -Query @{ search = $serial; limit = 10 }).rows)
    foreach ($r in $rows) { if ($r.serial -and ($r.serial -ieq $serial)) { return $r } }
    return $null
}

Write-Host "Getting the agent list from Tactical RMM..."
try { $agents = @(Invoke-TrmmRequest GET 'agents/') }
catch { Write-Host "TRMM lookup failed: $($_.Exception.Message)" -ForegroundColor Red; return }
Write-Host "Checking $($agents.Count) serial(s) against Snipe-IT..." -ForegroundColor DarkGray

$problems = @()
$ok = 0
$i = 0
foreach ($a in $agents) {
    $i++
    Write-Progress -Activity 'Serial audit' -Status "$i of $($agents.Count): $($a.hostname)" -PercentComplete (100 * $i / $agents.Count)

    $serial = "$($a.serial_number)".Trim()
    $result = $null; $tag = ''; $snipeName = ''; $snipeId = ''

    if (-not $serial) { $result = 'NoSerial' }
    else {
        # Retry a few times so a transient Snipe-IT hiccup isn't logged as an error.
        $asset = $null; $err = $null
        for ($try = 1; $try -le 3; $try++) {
            try { $asset = Get-SnipeBySerial $serial; $err = $null; break }
            catch { $err = $_; Start-Sleep -Seconds 2 }
        }
        if ($err) { $result = 'LookupError' }

        if (-not $result) {
            if (-not $asset) { $result = 'NotInSnipe' }
            elseif ($asset.name -ieq $a.hostname) { $ok++; continue }   # serial found + name matches = fine
            else { $result = 'HostnameMismatch'; $tag = $asset.asset_tag; $snipeName = $asset.name; $snipeId = $asset.id }
        }
    }

    $problems += [PSCustomObject][ordered]@{
        Hostname  = $a.hostname
        Serial    = $serial
        Result    = $result
        SnipeTag  = $tag
        SnipeName = $snipeName
        SnipeId   = $snipeId
        MakeModel = $a.make_model
        Client    = $a.client_name
        Site      = $a.site_name
    }
}
Write-Progress -Activity 'Serial audit' -Completed

$problems = @($problems | Sort-Object Result, Hostname)
$by = $problems | Group-Object Result | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-Host ""
Write-Host ("Matched OK: {0}   Problems: {1}   ({2})" -f $ok, $problems.Count, ($by -join '  ')) -ForegroundColor Cyan
if ($problems.Count -eq 0) { Write-Host "Every TRMM serial is in Snipe-IT under the right hostname." -ForegroundColor Green; return }

# --- Write JSON + HTML -------------------------------------------------------
$dir = Join-Path (Get-ADToolOutputDir) 'SnipeAudit'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$stamp = Get-Date -Format 'yyyy-MM-dd HHmmss'
$json  = Join-Path $dir "Serial Audit - $stamp.json"
$html  = Join-Path $dir "Serial Audit - $stamp.html"
$when  = Get-Date -Format 'yyyy-MM-dd HH:mm'

[ordered]@{
    generatedAt  = (Get-Date -Format 'o')
    generatedBy  = $env:USERNAME
    totalAgents  = $agents.Count
    matchedOk    = $ok
    problemCount = $problems.Count
    problems     = @($problems)
} | ConvertTo-Json -Depth 6 | Out-File -FilePath $json -Encoding UTF8

function Enc($v) { ([string]$v) -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;' }
$cols = 'Hostname', 'Serial', 'Result', 'MakeModel', 'SnipeTag', 'SnipeName', 'Client', 'Site'
$head = ($cols | ForEach-Object { "<th>$(Enc $_)</th>" }) -join ''
$rowsHtml = foreach ($r in $problems) {
    "<tr>$(($cols | ForEach-Object { "<td>$(Enc $r.$_)</td>" }) -join '')</tr>"
}
$htmlDoc = @"
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>TRMM serial audit vs Snipe-IT</title>
<style>
 body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#222}
 h1{font-size:20px;margin:0 0 6px}
 .meta{color:#666;font-size:13px;margin-bottom:16px}
 table{border-collapse:collapse;width:100%;font-size:13px}
 th,td{border:1px solid #ddd;padding:6px 8px;text-align:left;vertical-align:top}
 th{background:#f4f6f8;position:sticky;top:0}
 tr:nth-child(even){background:#fafafa}
</style></head><body>
<h1>TRMM serial audit vs Snipe-IT</h1>
<div class="meta">$($problems.Count) problem(s) of $($agents.Count) agent(s) &middot; $ok matched OK &middot; generated $when by $(Enc $env:USERNAME)<br>
NoSerial = TRMM has no serial &middot; NotInSnipe = serial missing from Snipe-IT &middot; HostnameMismatch = serial found under a different name</div>
<table><thead><tr>$head</tr></thead><tbody>
$($rowsHtml -join "`n")
</tbody></table></body></html>
"@
$htmlDoc | Out-File -FilePath $html -Encoding UTF8

Write-Host "Report written to:" -ForegroundColor Green
Write-Host "  $json"
Write-Host "  $html"
if ((Read-Host "Open the HTML report now? (y/n)").Trim().ToUpper() -eq 'Y') { Start-Process $html }

# ============================================================================
# OPTIONAL FIXES - both confirm first, both log to Snipe-Asset-Changes.json
# (via Write-SnipeAssetLog) so a change can be traced / reverted.
# ============================================================================

# --- Fix HostnameMismatch: set Snipe-IT name to the TRMM hostname ------------
$mismatch = @($problems | Where-Object { $_.Result -eq 'HostnameMismatch' })
if ($mismatch.Count -gt 0) {
    Write-ToolHeader 'HostnameMismatch: update Snipe-IT name to match TRMM'
    foreach ($p in $mismatch) {
        Write-Host ("  {0}  '{1}' -> '{2}'   (serial {3})" -f $p.SnipeTag, $p.SnipeName, $p.Hostname, $p.Serial) -ForegroundColor Yellow
    }
    if ((Read-Host "Update these $($mismatch.Count) name(s) in Snipe-IT? (y/n)").Trim().ToUpper() -eq 'Y') {
        foreach ($p in $mismatch) {
            try { $resp = Invoke-SnipeRequest -Path "hardware/$($p.SnipeId)" -Method PATCH -Body (@{ name = $p.Hostname } | ConvertTo-Json) }
            catch { Write-Host "  FAIL $($p.SnipeTag): $($_.Exception.Message)" -ForegroundColor Red; continue }
            if ($resp.status -eq 'success') {
                Write-Host "  Updated $($p.SnipeTag): '$($p.SnipeName)' -> '$($p.Hostname)'" -ForegroundColor Green
                Write-SnipeAssetLog -Action 'Update' -AssetTag $p.SnipeTag -AssetId $p.SnipeId -Field 'name' -OldValue $p.SnipeName -NewValue $p.Hostname -Details 'TRMM serial audit: hostname fix'
            }
            else { Write-Host "  FAIL $($p.SnipeTag): $($resp.messages | ConvertTo-Json -Compress)" -ForegroundColor Red }
        }
    }
}

# --- Fix NotInSnipe: create the asset, model matched to an existing Snipe model
$notin = @($problems | Where-Object { $_.Result -eq 'NotInSnipe' })
if ($notin.Count -gt 0) {
    Write-ToolHeader 'NotInSnipe: create missing assets in Snipe-IT'
    $models = @((Invoke-SnipeRequest -Path 'models' -Query @{ limit = 500 }).rows)
    $status = @((Invoke-SnipeRequest -Path 'statuslabels' -Query @{ limit = 100 }).rows)
    $statusId = ($status | Where-Object { $_.name -ieq 'Ready to Deploy' } | Select-Object -First 1).id
    if (-not $statusId) { $statusId = ($status | Where-Object { $_.type -eq 'deployable' } | Select-Object -First 1).id }

    # Ignore manufacturer/filler words so "Dell Inc. OptiPlex 5060" matches on the
    # distinctive tokens (optiplex, 5060), not on "dell".
    $stop = 'dell', 'hp', 'hewlett', 'packard', 'lenovo', 'microsoft', 'samsung', 'inc',
            'corporation', 'corp', 'co', 'ltd', 'technologies', 'computer', 'system', 'systems'
    function Find-Model ($mk) {
        $t = @(($mk.ToLower() -replace '[^\w\s]', ' ') -split '\s+' | Where-Object { $_.Length -ge 3 -and $stop -notcontains $_ })
        $best = $null; $bs = 0
        foreach ($m in $models) {
            $nt = @(($m.name.ToLower() -replace '[^\w\s]', ' ') -split '\s+' | Where-Object { $_.Length -ge 3 -and $stop -notcontains $_ })
            $c = @($t | Where-Object { $nt -contains $_ }).Count
            if ($c -gt $bs) { $bs = $c; $best = $m }
        }
        if ($bs -ge 1) { $best } else { $null }
    }

    $plan = foreach ($p in $notin) {
        $mk  = "$($p.MakeModel)".Trim()
        $mdl = if ($mk) { Find-Model $mk } else { $null }
        $txt = if ($mdl) { "$($mdl.name) (id $($mdl.id))" } else { 'NO MODEL MATCH - skip, add manually' }
        Write-Host ("  {0}  serial {1}  [{2}]  -> {3}" -f $p.Hostname, $p.Serial, $mk, $txt) -ForegroundColor Yellow
        [PSCustomObject]@{ P = $p; Model = $mdl }
    }
    $creatable = @($plan | Where-Object { $_.Model })
    Write-Host ("{0} creatable, {1} without a model match (skipped)." -f $creatable.Count, ($plan.Count - $creatable.Count)) -ForegroundColor DarkCyan

    if (-not $statusId) { Write-Host "No usable status label found - cannot create." -ForegroundColor Red }
    elseif ($creatable.Count -gt 0 -and (Read-Host "Create these $($creatable.Count) asset(s) in Snipe-IT? (y/n)").Trim().ToUpper() -eq 'Y') {
        foreach ($item in $creatable) {
            $p = $item.P
            $body = @{ model_id = $item.Model.id; status_id = $statusId; name = $p.Hostname; serial = $p.Serial } | ConvertTo-Json
            try { $resp = Invoke-SnipeRequest -Path 'hardware' -Method POST -Body $body }
            catch { Write-Host "  FAIL $($p.Hostname): $($_.Exception.Message)" -ForegroundColor Red; continue }
            if ($resp.status -eq 'success') {
                $newTag = $resp.payload.asset_tag; $newId = $resp.payload.id
                Write-Host "  Created $($p.Hostname) -> tag $newTag ($($item.Model.name))" -ForegroundColor Green
                Write-SnipeAssetLog -Action 'Create' -AssetTag $newTag -AssetId $newId -Field 'name' -NewValue $p.Hostname -Details "TRMM serial audit: created; serial=$($p.Serial); model=$($item.Model.name)"
            }
            else { Write-Host "  FAIL $($p.Hostname): $($resp.messages | ConvertTo-Json -Compress)" -ForegroundColor Red }
        }
    }
}
