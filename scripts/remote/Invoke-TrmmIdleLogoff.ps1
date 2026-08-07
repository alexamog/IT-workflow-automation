<#
.SYNOPSIS
    Sign off users who have been idle for N hours or more (default 8), on one
    computer or across every computer matching a hostname keyword.

.DESCRIPTION
    Reads each machine's sessions with "quser", works out how long each user has
    been idle, and lists the ones at or over the threshold. Nothing is signed off
    until you confirm. Logging off an idle session frees the machine and its
    memory, and lets profile cleanups run (a loaded profile cannot be deleted).

    Sessions with an idle time under the threshold, and sessions that are not
    logged in, are left alone.

    Needs TRMM_APIKEY / TRMM_URL - run ..\..\setup\Set-TacticalCredentials.ps1 once.

.PARAMETER IdleHours
    Minimum idle hours to qualify for sign-off. Default 8.

.EXAMPLE
    .\Invoke-TrmmIdleLogoff.ps1
.EXAMPLE
    .\Invoke-TrmmIdleLogoff.ps1 -IdleHours 4
#>

[CmdletBinding()]
param([double]$IdleHours = 8)

. "$PSScriptRoot\..\..\lib\Common.ps1"

if (-not (Test-TrmmConfigured)) { return }

# Thin wrapper over the shared helper: output is compared as text here, so it
# is flattened to a string once rather than at every call.
function Invoke-AgentCmd ($agentId, $command, [int]$TimeoutSec = 60) {
    "$(Invoke-TrmmAgentCommand -AgentId $agentId -Command $command -TimeoutSec $TimeoutSec)"
}

$kw = (Read-Host "Hostname keyword (e.g. ITDESSPARE), a full computer name, or * for ALL").Trim()

Write-Host "Getting the agent list from Tactical RMM..."
try { $agents = @(Invoke-TrmmRequest GET 'agents/') }
catch { Write-Host "TRMM lookup failed: $($_.Exception.Message)" -ForegroundColor Red; return }
if ($kw -and $kw -ne '*') { $agents = @($agents | Where-Object { $_.hostname -match [regex]::Escape($kw) }) }
$targets = @($agents | Where-Object { $_.status -eq 'online' })
Write-Host "Checking sessions on $($targets.Count) online computer(s) (idle >= $IdleHours h)..." -ForegroundColor Cyan
if ($targets.Count -eq 0) { Write-Host "Nothing online to check." -ForegroundColor Yellow; return }

# Remote: parse quser into USER|SESSIONID|STATE|IDLEMINUTES.
# quser idle column is "." or "none" (active), "MM", "H:MM", or "D+H:MM".
$scanCmd = @'
$ErrorActionPreference = 'SilentlyContinue'
$out = quser 2>$null
if (-not $out) { 'NOSESSIONS'; exit }
foreach ($line in ($out | Select-Object -Skip 1)) {
    $l = $line -replace '^>', ''
    # user [sessionname] id state idle logontime
    if ($l -match '^\s*(?<user>\S+)\s+(?:(?<sess>\S+)\s+)?(?<id>\d+)\s+(?<state>\S+)\s+(?<idle>\S+)\s+(?<logon>.+)$') {
        $idleRaw = $Matches['idle']
        $mins = 0
        if ($idleRaw -match '^(\d+)\+(\d+):(\d+)$') { $mins = ([int]$Matches[1] * 1440) + ([int]$Matches[2] * 60) + [int]$Matches[3] }
        elseif ($idleRaw -match '^(\d+):(\d+)$')    { $mins = ([int]$Matches[1] * 60) + [int]$Matches[2] }
        elseif ($idleRaw -match '^\d+$')            { $mins = [int]$idleRaw }
        else                                        { $mins = 0 }   # "." or "none" = active
        '{0}|{1}|{2}|{3}' -f $Matches['user'], $Matches['id'], $Matches['state'], $mins
    }
}
'@

$found = @()
$i = 0
foreach ($a in $targets) {
    $i++
    Write-Progress -Activity 'Checking idle sessions' -Status "$i of $($targets.Count): $($a.hostname)" -PercentComplete (100 * $i / $targets.Count)
    try { $out = Invoke-AgentCmd $a.agent_id $scanCmd } catch { continue }
    foreach ($line in ($out -split "`r?`n")) {
        if ($line -notmatch '^\S+\|\d+\|') { continue }
        $p = $line -split '\|'
        $mins = [int]$p[3]
        if ($mins -lt ($IdleHours * 60)) { continue }
        $found += [PSCustomObject]@{
            Hostname  = $a.hostname
            User      = $p[0]
            SessionId = $p[1]
            State     = $p[2]
            IdleHours = [math]::Round($mins / 60, 1)
            AgentId   = $a.agent_id
        }
    }
}
Write-Progress -Activity 'Checking idle sessions' -Completed

if ($found.Count -eq 0) { Write-Host "`nNo sessions idle for $IdleHours hours or more." -ForegroundColor Green; return }

$found = @($found | Sort-Object -Property @{ E = 'IdleHours'; Descending = $true }, Hostname)
Write-Host "`n$($found.Count) session(s) idle >= $IdleHours h:" -ForegroundColor Yellow
$found | Format-Table Hostname, User, SessionId, State, IdleHours -AutoSize | Out-String | Write-Host

Write-Host "Signing off closes their apps - unsaved work in that session is lost." -ForegroundColor Yellow
Write-Host "[A] sign off ALL listed   [#] pick one   [B] back" -ForegroundColor White
$choice = (Read-Host "Choose").Trim().ToUpper()

$toLogoff = @()
if ($choice -eq 'B' -or $choice -eq '') { return }
elseif ($choice -eq 'A') { $toLogoff = $found }
else {
    for ($j = 0; $j -lt $found.Count; $j++) { Write-Host ("  {0,2}) {1} on {2} ({3} h idle)" -f ($j + 1), $found[$j].User, $found[$j].Hostname, $found[$j].IdleHours) }
    $n = 0
    if ([int]::TryParse((Read-Host "Number"), [ref]$n) -and $n -ge 1 -and $n -le $found.Count) { $toLogoff = @($found[$n - 1]) }
    else { Write-Host "Cancelled." -ForegroundColor DarkGray; return }
}

if (-not (Confirm-DeskSideWord "sign off $($toLogoff.Count) session(s)" -CancelNote 'nobody was signed off')) { return }

$outputDir = Join-Path -Path $PSScriptRoot -ChildPath '..\..\output'
if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }
$csv = Join-Path $outputDir 'AD-Toolkit-Actions.csv'

foreach ($s in $toLogoff) {
    try { $res = (Invoke-AgentCmd $s.AgentId "logoff $($s.SessionId); 'LOGGEDOFF'").Trim() }
    catch { $res = "ERROR $($_.Exception.Message)" }
    $ok = $res -match 'LOGGEDOFF'
    Write-Host ("  {0} @ {1}: {2}" -f $s.User, $s.Hostname, $(if ($ok) { 'signed off' } else { $res })) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
    [PSCustomObject]@{
        Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); Operator = $env:USERNAME
        Action = 'Sign Off Idle User (TRMM)'; Target = $s.Hostname
        Result = $(if ($ok) { 'Success' } else { 'Failed' })
        Details = "user=$($s.User); session=$($s.SessionId); idleHours=$($s.IdleHours); threshold=$IdleHours"
    } | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8 -Append
}
Write-Host "`nDone. Logged to $csv" -ForegroundColor Green
