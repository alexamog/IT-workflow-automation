<#
.SYNOPSIS
    Scan Tactical RMM computers (by hostname keyword, or all) for CORRUPT user
    profiles, then optionally delete them.

.DESCRIPTION
    On each matching ONLINE machine it flags a profile as corrupt when any of:
      - Win32_UserProfile Status has the corrupt bit (Status -band 8),
      - a ".bak" registry key exists under ProfileList\<SID>.bak
        (the "temporary profile" leftover),
      - the profile's C:\Users folder is missing but the registry entry remains.

    You get one list across all machines. Deletion:
      - skips profiles currently loaded (user logged in),
      - refuses protected names (PROTECTED_ACCOUNTS, default adm-*),
      - removes the profile (folder + registry via Remove-CimInstance), or for an
        orphaned ".bak" with no live profile, removes the stale registry key,
      - is confirmed once and logged to output\AD-Toolkit-Actions.csv and each
        machine's C:\ProgramData\DeskSideToolkit\ProfileCleanup.log.

    Needs TRMM_APIKEY / TRMM_URL - run ..\..\setup\Set-TacticalCredentials.ps1 once.

.EXAMPLE
    .\Find-TrmmCorruptProfile.ps1
#>

# NOT ON THE MAIN MENU, and that is deliberate - there is no .tool.psd1
# manifest beside this file, so the launcher never lists it. It is opened
# from Manage-TrmmProfiles.ps1, which collects the answers it needs first.
# It still runs on its own if you want to use it directly.

[CmdletBinding()]
param()

. "$PSScriptRoot\..\..\lib\Common.ps1"

if (-not (Test-TrmmConfigured)) { return }

$kw = (Read-Host "Hostname keyword to scan (e.g. ITDESSPARE), or * for ALL computers").Trim()

Write-Host "Getting the agent list from Tactical RMM..."
$lookup = Get-TrmmAgent -HostnameLike $kw
if (-not $lookup.Ok) { return }        # the message was already printed
$agents = $lookup.Agents
$targets = @($agents | Where-Object { $_.status -eq 'online' })
$offline = @($agents).Count - $targets.Count
Write-Host "Scanning $($targets.Count) online computer(s) ($offline offline skipped)..." -ForegroundColor Cyan
if ($targets.Count -eq 0) { Write-Host "Nothing online to scan." -ForegroundColor Yellow; return }

# Remote scan: list corrupt profiles (active + orphaned .bak). Single-quoted
# here-string so all $ belong to the remote script.
$scanCmd = @'
$ErrorActionPreference = 'SilentlyContinue'
$base = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
$seen = @{}
Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special } | ForEach-Object {
    $name = Split-Path $_.LocalPath -Leaf
    $bak  = Test-Path ("$base\" + $_.SID + ".bak")
    $miss = -not (Test-Path $_.LocalPath)
    $cb   = [bool]($_.Status -band 8)
    if ($bak -or $miss -or $cb) {
        $r = @(); if ($cb) { $r += 'status-bit' }; if ($bak) { $r += 'bak-key' }; if ($miss) { $r += 'folder-missing' }
        # CORRUPT = Windows actually failed to load it (temp profile / .bak / status bit).
        # ORPHAN  = registry entry left behind, folder already gone (usually a
        #           hand-deleted C:\Users folder) - stale, not corrupt.
        $type = if ($bak -or $cb) { 'CORRUPT' } else { 'ORPHAN' }
        "PROFILE|$type|$name|$($_.Loaded)|$($r -join ',')"
        $seen[$name.ToLower()] = $true
    }
}
Get-ChildItem $base | Where-Object { $_.PSChildName -like '*.bak' } | ForEach-Object {
    $ip = (Get-ItemProperty $_.PSPath).ProfileImagePath
    $name = if ($ip) { Split-Path $ip -Leaf } else { $_.PSChildName }
    if (-not $seen[$name.ToLower()]) { "PROFILE|CORRUPT|$name|False|orphaned-bak-key" }
}
'@

$rows = @()
$i = 0
foreach ($a in $targets) {
    $i++
    Write-Progress -Activity 'Scanning for corrupt profiles' -Status "$i of $($targets.Count): $($a.hostname)" -PercentComplete (100 * $i / $targets.Count)
    try { $out = Invoke-TrmmAgentText -AgentId $a.agent_id -Command $scanCmd } catch { continue }
    foreach ($line in ($out -split "`r?`n")) {
        if ($line -notmatch '^PROFILE\|') { continue }
        $p = $line -split '\|'
        $rows += [PSCustomObject]@{
            Hostname = $a.hostname
            Type     = $p[1]
            Profile  = $p[2]
            Loaded   = ($p[3] -eq 'True')
            Reason   = $p[4]
            AgentId  = $a.agent_id
        }
    }
}
Write-Progress -Activity 'Scanning for corrupt profiles' -Completed

if ($rows.Count -eq 0) { Write-Host "`nNo problem profiles found on any scanned computer." -ForegroundColor Green; return }

$rows = @($rows | Sort-Object Type, Hostname, Profile)
$corruptCount = @($rows | Where-Object { $_.Type -eq 'CORRUPT' }).Count
$orphanCount  = @($rows | Where-Object { $_.Type -eq 'ORPHAN' }).Count
Write-Host ""
Write-Host "$($rows.Count) problem profile(s):  CORRUPT = $corruptCount   ORPHAN = $orphanCount" -ForegroundColor Yellow
Write-Host "  CORRUPT - Windows could not load it (temp profile / .bak key). The user hits this at logon." -ForegroundColor Red
Write-Host "  ORPHAN  - registry entry left behind, folder already gone. Stale, not corrupt;" -ForegroundColor DarkYellow
Write-Host "            usually from deleting a C:\Users folder by hand. Left alone, it BECOMES corrupt" -ForegroundColor DarkYellow
Write-Host "            the next time that user signs in." -ForegroundColor DarkYellow
Write-Host ""
$rows | Format-Table Hostname, Type, Profile, Loaded, Reason -AutoSize | Out-String -Width 160 | Write-Host

# --- Delete option -----------------------------------------------------------
# Deletable = not loaded and not a protected admin name.
$deletable = @($rows | Where-Object { -not $_.Loaded -and -not (Test-DeskSideProtectedAccount $_.Profile) })
$skipped   = @($rows | Where-Object { $_.Loaded -or (Test-DeskSideProtectedAccount $_.Profile) })
if ($skipped.Count -gt 0) { Write-Host "$($skipped.Count) not deletable (loaded or protected): $((@($skipped | ForEach-Object { "$($_.Profile)@$($_.Hostname)" })) -join ', ')" -ForegroundColor DarkGray }
if ($deletable.Count -eq 0) { Write-Host "Nothing deletable." -ForegroundColor Yellow; return }

$delCorrupt = @($deletable | Where-Object { $_.Type -eq 'CORRUPT' })
$delOrphan  = @($deletable | Where-Object { $_.Type -eq 'ORPHAN' })

Write-Host "`nDeletable:" -ForegroundColor Cyan
for ($j = 0; $j -lt $deletable.Count; $j++) {
    Write-Host ("  {0,2}) [{1,-7}] {2}  on  {3}  ({4})" -f ($j + 1), $deletable[$j].Type, $deletable[$j].Profile, $deletable[$j].Hostname, $deletable[$j].Reason)
}
Write-Host ("[C] all CORRUPT ({0})   [O] all ORPHAN ({1})   [A] all ({2})   [#] one   [B] back" -f $delCorrupt.Count, $delOrphan.Count, $deletable.Count) -ForegroundColor White
$choice = (Read-Host "Choose").Trim().ToUpper()

$toDelete = @()
if ($choice -eq 'B' -or $choice -eq '') { return }
elseif ($choice -eq 'A') { $toDelete = $deletable }
elseif ($choice -eq 'C') { $toDelete = $delCorrupt }
elseif ($choice -eq 'O') { $toDelete = $delOrphan }
else {
    $n = 0
    if ([int]::TryParse($choice, [ref]$n) -and $n -ge 1 -and $n -le $deletable.Count) { $toDelete = @($deletable[$n - 1]) }
    else { Write-Host "Invalid." -ForegroundColor DarkGray; return }
}
if ($toDelete.Count -eq 0) { Write-Host "Nothing in that group." -ForegroundColor Yellow; return }

if (-not (Confirm-DeskSideWord "permanently remove $($toDelete.Count) profile(s)/entry(ies)")) { return }

$csv = Join-Path (Get-ADToolOutputDir) 'AD-Toolkit-Actions.csv'

foreach ($d in $toDelete) {
    # Double any apostrophe so a name like caitlin.o'sullivan cannot break out of
    # the single-quoted string it is pasted into on the remote machine.
    $safeProfile = ConvertTo-RemoteLiteral $d.Profile
    $delCmd = @"
`$u = '$safeProfile'
`$base = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
`$p = Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { (Split-Path `$_.LocalPath -Leaf) -ieq `$u -and -not `$_.Special }
if (`$p) {
    if (`$p.Loaded) { 'SKIP-LOADED' }
    else { try { Remove-CimInstance -InputObject `$p -ErrorAction Stop; 'DELETED' } catch { 'FAIL ' + `$_.Exception.Message } }
} else {
    `$removed = `$false
    Get-ChildItem `$base | ForEach-Object {
        `$ip = (Get-ItemProperty `$_.PSPath -ErrorAction SilentlyContinue).ProfileImagePath
        if (`$ip -and ((Split-Path `$ip -Leaf) -ieq `$u)) { Remove-Item `$_.PSPath -Recurse -Force -ErrorAction SilentlyContinue; `$removed = `$true }
    }
    if (`$removed) { 'DELETED-REG' } else { 'NOTFOUND' }
}
$(Get-DeskSideRemoteProgramDataLine)
`$logd = `$DeskSideData; if (-not (Test-Path `$logd)) { New-Item -ItemType Directory -Path `$logd -Force | Out-Null }
Add-Content (Join-Path `$logd 'ProfileCleanup.log') ('{0}  [corrupt-scan]  removed corrupt profile {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), `$u)
"@
    try { $res = (Invoke-TrmmAgentText -AgentId $d.AgentId -Command $delCmd).Trim() } catch { $res = "ERROR $($_.Exception.Message)" }
    # The last line of output is the log Add-Content (no return) - take the first token line.
    $status = (@($res -split "`r?`n") | Where-Object { $_ -match '^(DELETED|DELETED-REG|SKIP-LOADED|NOTFOUND|FAIL|ERROR)' } | Select-Object -First 1)
    if (-not $status) { $status = $res }
    $colour = if ($status -match '^DELETED') { 'Green' } else { 'Red' }
    Write-Host ("  {0} @ {1}: {2}" -f $d.Profile, $d.Hostname, $status) -ForegroundColor $colour
    $result = if ($status -match '^DELETED') { 'Success' } else { 'Failed' }
    # Through the shared writer, so this feature cannot drift from the column
    # set every other feature writes into the same file.
    Write-ActionLog -Action 'Delete Corrupt Profile (TRMM)' -Target $d.Hostname -Result $result `
        -Details "profile=$($d.Profile); type=$($d.Type); reason=$($d.Reason); remote=$status"
}
Write-Host "`nDone. Logged to $csv" -ForegroundColor Green
