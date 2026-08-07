<#
.SYNOPSIS
    Scan every computer in Tactical RMM for low disk space, then (after you
    confirm) run the disk cleanup on the ones that need it.

.DESCRIPTION
    Checks the C: drive of every ONLINE workstation in Tactical RMM and lists
    the ones with less free space than -MinFreeGB (default 15 GB). You see
    the full list first and must type YES before anything runs.

    The cleanup dispatched to each machine is the toolkit's standard one
    (temp folders, recycle bin, Windows Update cache, DISM component cleanup).
    It does NOT delete any user profiles - profile deletion needs a per-machine
    keep list, so use Invoke-RemoteProfileCleanup.ps1 for that.

    After dispatching, the script waits and collects each machine's result,
    showing and logging the BEFORE and AFTER free space per machine (one row
    each in output\AD-Toolkit-Actions.csv), plus a totals table at the end.
    Use -NoWait to dispatch and exit immediately instead.

    Servers are skipped unless you pass -IncludeServers.

    Needs TRMM_APIKEY and TRMM_URL - run ..\..\setup\Set-TacticalCredentials.ps1 once.

.EXAMPLE
    # Report only - see who is low, run nothing:
    .\Invoke-FleetDiskCleanup.ps1 -ScanOnly

.EXAMPLE
    # Flag machines with under 25 GB free, offer to clean them:
    .\Invoke-FleetDiskCleanup.ps1 -MinFreeGB 25
#>

[CmdletBinding()]
param(
    # Machines with LESS than this many GB free on C: are flagged.
    [double]$MinFreeGB = 15,

    # Only show the report - never offer to run the cleanup.
    [switch]$ScanOnly,

    # Also scan (and offer to clean) servers, not just workstations.
    [switch]$IncludeServers,

    # Dispatch the cleanups and exit immediately instead of waiting to collect
    # each machine's before/after result.
    [switch]$NoWait
)

# --- Tactical RMM plumbing -------------------------------------------------
# Invoke-TrmmRequest and the credential check both live in the shared library.
. "$PSScriptRoot\..\..\lib\Common.ps1"

if (-not (Test-TrmmConfigured)) { return }

# Turn TRMM's human-readable size ("89.1 GB", "512 MB") into GB as a number.
function ConvertTo-GB ($text) {
    if ("$text" -match '([\d\.]+)\s*(TB|GB|MB)') {
        $n = [double]$Matches[1]
        switch ($Matches[2]) {
            'TB' { return $n * 1024 }
            'GB' { return $n }
            'MB' { return [math]::Round($n / 1024, 2) }
        }
    }
    return $null
}

# --- Scan the fleet ----------------------------------------------------------
Write-Host "Getting the agent list from Tactical RMM..."
$agents = @(Invoke-TrmmRequest GET 'agents/') | Where-Object { $_.status -eq 'online' }
if (-not $IncludeServers) {
    $agents = @($agents | Where-Object { $_.monitoring_type -ne 'server' })
}
Write-Host "Checking C: free space on $($agents.Count) online $(if ($IncludeServers) { 'machines' } else { 'workstations' }) (one lookup per machine)..."

$low  = @()
$done = 0
foreach ($a in $agents) {
    $done++
    Write-Progress -Activity 'Checking disk space' -Status "$done of $($agents.Count): $($a.hostname)" -PercentComplete (100 * $done / $agents.Count)
    try {
        $detail = Invoke-TrmmRequest GET "agents/$($a.agent_id)/"
    }
    catch { continue }   # unreachable mid-scan - skip it

    $c = @($detail.disks | Where-Object { $_.device -eq 'C:' }) | Select-Object -First 1
    if (-not $c) { continue }
    $freeGB = ConvertTo-GB $c.free
    if ($null -eq $freeGB) { continue }

    if ($freeGB -lt $MinFreeGB) {
        $low += [PSCustomObject]@{
            Hostname  = $a.hostname
            'FreeGB'  = $freeGB
            'Used%'   = $c.percent
            Total     = $c.total
            Site      = $a.site_name
            User      = $a.logged_username
            agent_id  = $a.agent_id
        }
    }
}
Write-Progress -Activity 'Checking disk space' -Completed

if ($low.Count -eq 0) {
    Write-Host "`nNo machine is below $MinFreeGB GB free. Fleet looks healthy." -ForegroundColor Green
    return
}

# --- Report ------------------------------------------------------------------
Write-Host "`n$($low.Count) machine(s) under $MinFreeGB GB free on C: (lowest first):" -ForegroundColor Yellow
$low = @($low | Sort-Object FreeGB)
$low | Format-Table Hostname, FreeGB, 'Used%', Total, Site, User -AutoSize | Out-String | Write-Host

if ($ScanOnly) { return }

# --- Confirm and dispatch ------------------------------------------------------
Write-Host "The disk cleanup (temp files, recycle bin, update cache, DISM) can be dispatched"
Write-Host "to ALL machines listed above. No user profiles are deleted." -ForegroundColor Yellow
$answer = Read-Host "`nType YES (in capitals) to dispatch the cleanup to these $($low.Count) machine(s), or anything else to stop"
if ($answer -cne 'YES') {
    Write-Host "Nothing dispatched." -ForegroundColor Yellow
    return
}

# Make sure the cleanup script is in the TRMM library (same entry the
# remote profile cleanup uses - created or refreshed from our local copy).
$scriptName = 'Toolkit - Remove-UnlistedProfiles'
$localPath  = Join-Path -Path $PSScriptRoot -ChildPath '..\maintenance\Remove-UnlistedProfiles.ps1'
$payload = @{
    name            = $scriptName
    shell           = 'powershell'
    script_type     = 'userdefined'
    script_body     = [System.IO.File]::ReadAllText($localPath)
    category        = 'Desk Side Toolkit'
    description     = 'Deletes user profiles not on the keep list. Managed by the Desk Side toolkit - do not edit here.'
    default_timeout = 3600
    args            = @()
}
$existing = @(Invoke-TrmmRequest GET 'scripts/') | Where-Object { $_.name -eq $scriptName } | Select-Object -First 1
if ($existing) { Invoke-TrmmRequest PUT "scripts/$($existing.id)/" $payload | Out-Null; $scriptId = $existing.id }
else {
    $created  = Invoke-TrmmRequest POST 'scripts/' $payload
    $scriptId = $created.id
    if (-not $scriptId) {
        $scriptId = (@(Invoke-TrmmRequest GET 'scripts/') | Where-Object { $_.name -eq $scriptName } | Select-Object -First 1).id
    }
}
if (-not $scriptId) { Write-Host "Could not create/find the script library entry - stopping." -ForegroundColor Red; return }

# Audit log (one CSV row per dispatched machine).
# Audit rows go through Write-ActionLog in the shared library, so every feature
# writes the same columns to the same file. This wrapper just saves repeating
# the Action name on all five call sites below.
function Write-FleetLog ($target, $result, $details) {
    Write-ActionLog -Action 'Fleet Disk Cleanup (TRMM)' -Target $target -Result $result -Details $details
}

$dispatchTime = Get-Date
$pending      = New-Object System.Collections.Generic.List[object]
foreach ($m in $low) {
    try {
        Invoke-TrmmRequest POST "agents/$($m.agent_id)/runscript/" @{
            script          = $scriptId
            output          = 'forget'
            args            = @('-Force', '-Cleanup')
            timeout         = 1800
            run_as_user     = $false
            env_vars        = @()
            custom_field    = $null
            save_all_output = $true
            email           = @()
            emailMode       = 'default'
        } | Out-Null
        Write-Host ("Dispatched : {0}  ({1} GB free)" -f $m.Hostname, $m.FreeGB) -ForegroundColor Green
        $pending.Add($m)
        if ($NoWait) { Write-FleetLog $m.Hostname 'Success' "cleanup dispatched, not waited on (free at scan=$($m.FreeGB) GB, threshold=$MinFreeGB GB)" }
    }
    catch {
        Write-Host ("FAILED     : {0} - {1}" -f $m.Hostname, $_.Exception.Message) -ForegroundColor Red
        Write-FleetLog $m.Hostname 'Failed' "cleanup dispatch error: $($_.Exception.Message)"
    }
}

if ($NoWait) {
    Write-Host "`nDispatched to $($pending.Count) of $($low.Count) machine(s). -NoWait: not collecting results." -ForegroundColor Green
    Write-Host "Re-run  .\Invoke-FleetDiskCleanup.ps1 -ScanOnly  in half an hour to see the improvement." -ForegroundColor DarkGray
    return
}

# --- Collect before/after results from each machine ---------------------------
# Each machine's cleanup writes a line like
#   2026-07-09 12:10:00  [PC$]  CLEANUP freed 4.67 GB (free space 123.44 GB -> 128.11 GB)
# to its own C:\ProgramData\DeskSideToolkit\ProfileCleanup.log. Poll for that
# line (newer than our dispatch) and log the before/after per machine.
Write-Host "`nWaiting for results (checked every 60 seconds; cleanups take 5-15 min each)." -ForegroundColor Cyan
Write-Host "Ctrl+C stops the waiting only - the cleanups keep running on the machines." -ForegroundColor DarkGray

# The first line resolves the folder ON THE MACHINE, exactly as the cleanup
# script did when it WROTE this log. Resolving it here instead would send this
# operator's path to a machine that never used it.
# The rest is a single-quoted here-string, so its $ signs stay literal and are
# evaluated at the far end.
$readCmd = (Get-DeskSideRemoteProgramDataLine) + @'

$log = Join-Path $DeskSideData 'ProfileCleanup.log'
if (Test-Path $log) { Get-Content $log | Select-String -Pattern 'CLEANUP freed' | Select-Object -Last 1 }
'@
$deadline = (Get-Date).AddMinutes(40)
$results  = @()

while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 60
    # Snapshot with ToArray() (a real copy) and defer removals - mutating the
    # List while foreach enumerates it throws "Argument types do not match".
    $finished = New-Object System.Collections.Generic.List[object]
    foreach ($m in $pending.ToArray()) {
        try {
            $line = "$(Invoke-TrmmAgentCommand -AgentId $m.agent_id -Command $readCmd -TimeoutSec 60)".Trim()
        }
        catch { continue }

        if ($line -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}).*CLEANUP freed ([\-\d\.]+) GB \(free space ([\d\.]+) GB -> ([\d\.]+) GB\)') {
            # Only accept a result newer than our dispatch (5 min clock slack).
            $lineTime = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $null)
            if ($lineTime -lt $dispatchTime.AddMinutes(-5)) { continue }

            $r = [PSCustomObject]@{
                Hostname = $m.Hostname
                BeforeGB = [double]$Matches[3]
                AfterGB  = [double]$Matches[4]
                FreedGB  = [double]$Matches[2]
            }
            $results += $r
            $finished.Add($m)
            Write-Host ("Finished   : {0}  {1} GB -> {2} GB (freed {3} GB)" -f $r.Hostname, $r.BeforeGB, $r.AfterGB, $r.FreedGB) -ForegroundColor Green
            Write-FleetLog $m.Hostname 'Success' ("cleanup done: before={0} GB after={1} GB freed={2} GB (threshold={3} GB)" -f $r.BeforeGB, $r.AfterGB, $r.FreedGB, $MinFreeGB)
        }
    }
    foreach ($d in $finished) { [void]$pending.Remove($d) }
    if ($pending.Count -gt 0) {
        Write-Host ("  ... {0} of {1} still running ({2:HH:mm:ss})" -f $pending.Count, $low.Count, (Get-Date)) -ForegroundColor DarkGray
    }
}

# Anything still pending after the deadline gets logged as such.
foreach ($m in $pending) {
    Write-Host ("No result  : {0} - still running or unreachable; check its ProfileCleanup.log later" -f $m.Hostname) -ForegroundColor Yellow
    Write-FleetLog $m.Hostname 'Unknown' "cleanup dispatched but no result within 40 min (free at scan=$($m.FreeGB) GB)"
}

if ($results.Count -gt 0) {
Write-ToolHeader 'Results'
    $results | Sort-Object FreedGB -Descending | Format-Table Hostname, BeforeGB, AfterGB, FreedGB -AutoSize | Out-String | Write-Host
    Write-Host ("Total freed across {0} machine(s): {1} GB" -f $results.Count, [math]::Round(($results | Measure-Object FreedGB -Sum).Sum, 2)) -ForegroundColor Green
}
Write-Host "Every machine is also logged in output\AD-Toolkit-Actions.csv with its before/after." -ForegroundColor DarkGray