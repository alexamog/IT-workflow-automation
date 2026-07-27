<#
.SYNOPSIS
    Repair CORRUPT user profiles on Tactical RMM computers WITHOUT deleting them,
    so the user keeps their files, desktop and settings.

.DESCRIPTION
    This is the non-destructive answer to the sign-in error:

        "The group policy client service failed the sign-in. Access is denied."
        "The User Profile Service failed the sign-in."

    Almost always that error is a corrupt entry in the profile registry, not a
    corrupt profile FOLDER. The folder - the user's actual data - is usually
    fine. Deleting the whole profile fixes the error but throws the data away
    and makes the user set the machine up again. This script fixes the registry
    entry and leaves the folder alone.

    WHAT "CORRUPT" MEANS HERE, and what this repairs:
      - a ".bak" key exists under ProfileList\<SID>.bak (the classic "you're
        logged on with a temporary profile" leftover). Fix: drop the broken
        <SID> key and rename <SID>.bak back to <SID>.
      - the <SID> key has the corrupt State bit set. Fix: clear State/RefCount.
    In both cases the profile FOLDER must still exist - that is the whole point.

    WHAT IT WILL NOT TOUCH (use Find-TrmmCorruptProfile.ps1 for these):
      - profiles whose folder is already GONE - there is no data to save, so the
        stale registry key should just be removed, which the finder does.
      - profiles currently loaded (someone signed in on them right now).
      - protected profiles (PROTECTED_ACCOUNTS, default adm-*).

    SAFETY
      - The whole ProfileList key is exported to a .reg backup on the machine
        BEFORE any change (C:\ProgramData\DeskSideToolkit\ProfileListBackups).
        To undo by hand: double-click that .reg on the machine, or reg import.
      - Nothing changes until you review the list and type YES.
      - Every repair is re-checked on the machine right before it runs, so a
        profile that came into use since the scan is skipped, not touched.

    LIMITATION: this fixes the common registry-state corruption. A rarer kind
    caused by broken folder PERMISSIONS is not covered - if a profile still
    fails to load after a clean repair here, fall back to deleting it with
    Find-TrmmCorruptProfile.ps1.

    Needs TRMM_APIKEY / TRMM_URL - run ..\..\setup\Set-TacticalCredentials.ps1 once.

.EXAMPLE
    .\Repair-TrmmCorruptProfile.ps1
#>

[CmdletBinding()]
param()

. "$PSScriptRoot\..\..\lib\Common.ps1"

if (-not (Test-TrmmConfigured)) { return }

# Thin wrapper over the shared helper: output is compared as text, so it is
# flattened to a string here rather than at every call.
function Invoke-AgentCmd ($agentId, $command, [int]$TimeoutSec = 90) {
    "$(Invoke-TrmmAgentCommand -AgentId $agentId -Command $command -TimeoutSec $TimeoutSec)"
}

$kw = (Read-Host "Hostname keyword to scan (e.g. ITDESSPARE), a full name, or * for ALL").Trim()

Write-Host "Getting the agent list from Tactical RMM..."
try { $agents = @(Invoke-TrmmRequest GET 'agents/') }
catch { Write-Host "TRMM lookup failed: $($_.Exception.Message)" -ForegroundColor Red; return }
if ($kw -and $kw -ne '*') { $agents = @($agents | Where-Object { $_.hostname -match [regex]::Escape($kw) }) }
$targets = @($agents | Where-Object { $_.status -eq 'online' })
$offline = @($agents).Count - $targets.Count
Write-Host "Scanning $($targets.Count) online computer(s) ($offline offline skipped)..." -ForegroundColor Cyan
if ($targets.Count -eq 0) { Write-Host "Nothing online to scan." -ForegroundColor Yellow; return }

# Remote scan. Mirrors Find-TrmmCorruptProfile's detection, but also reports
# whether the profile FOLDER is present, because we only repair when it is (that
# is the data we are trying to keep). Single-quoted here-string so all $ are the
# remote script's own.
$scanCmd = @'
$ErrorActionPreference = 'SilentlyContinue'
$base = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
$seen = @{}
Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special } | ForEach-Object {
    $name   = Split-Path $_.LocalPath -Leaf
    $bak    = Test-Path ("$base\" + $_.SID + ".bak")
    $folder = Test-Path $_.LocalPath
    $cb     = [bool]($_.Status -band 8)
    if ($bak -or -not $folder -or $cb) {
        $r = @(); if ($cb) { $r += 'status-bit' }; if ($bak) { $r += 'bak-key' }; if (-not $folder) { $r += 'folder-missing' }
        # Repairable only when the folder is still there.
        $type = if ($folder -and ($bak -or $cb)) { 'REPAIRABLE' }
                elseif (-not $folder)             { 'NO-DATA' }
                else                              { 'REPAIRABLE' }
        "PROFILE|$type|$name|$($_.Loaded)|$folder|$($r -join ',')"
        $seen[$name.ToLower()] = $true
    }
}
# A .bak key whose live profile WMI object is gone, but the folder may still be
# on disk - check the folder directly so we can still offer to repair it.
Get-ChildItem $base | Where-Object { $_.PSChildName -like '*.bak' } | ForEach-Object {
    $ip = (Get-ItemProperty $_.PSPath).ProfileImagePath
    if (-not $ip) { return }
    $name = Split-Path $ip -Leaf
    if ($seen[$name.ToLower()]) { return }
    $folder = Test-Path $ip
    $type   = if ($folder) { 'REPAIRABLE' } else { 'NO-DATA' }
    "PROFILE|$type|$name|False|$folder|orphaned-bak-key"
}
'@

$rows = @()
$i = 0
foreach ($a in $targets) {
    $i++
    Write-Progress -Activity 'Scanning for corrupt profiles' -Status "$i of $($targets.Count): $($a.hostname)" -PercentComplete (100 * $i / $targets.Count)
    try { $out = Invoke-AgentCmd $a.agent_id $scanCmd } catch { continue }
    foreach ($line in ($out -split "`r?`n")) {
        if ($line -notmatch '^PROFILE\|') { continue }
        $p = $line -split '\|'
        $rows += [PSCustomObject]@{
            Hostname   = $a.hostname
            Type       = $p[1]
            Profile    = $p[2]
            Loaded     = ($p[3] -eq 'True')
            HasFolder  = ($p[4] -eq 'True')
            Reason     = $p[5]
            AgentId    = $a.agent_id
        }
    }
}
Write-Progress -Activity 'Scanning for corrupt profiles' -Completed

if ($rows.Count -eq 0) { Write-Host "`nNo problem profiles found on any scanned computer." -ForegroundColor Green; return }

$rows = @($rows | Sort-Object Type, Hostname, Profile)
Write-Host ""
$rows | Format-Table Hostname, Type, Profile, Loaded, HasFolder, Reason -AutoSize | Out-String -Width 160 | Write-Host

# --- What can be repaired ----------------------------------------------------
# Repairable = the folder still exists, nobody is on it, and it is not a
# protected admin profile.
$repairable = @($rows | Where-Object { $_.Type -eq 'REPAIRABLE' -and $_.HasFolder -and -not $_.Loaded -and -not (Test-DeskSideProtectedAccount $_.Profile) })

# Explain everything that is NOT repairable, so it is clear why.
$noData  = @($rows | Where-Object { -not $_.HasFolder })
$loaded  = @($rows | Where-Object { $_.HasFolder -and $_.Loaded })
$admin   = @($rows | Where-Object { $_.HasFolder -and -not $_.Loaded -and (& $protected $_.Profile) })

if ($noData.Count) { Write-Host "$($noData.Count) have no folder left (nothing to save) - clear these with Find-TrmmCorruptProfile.ps1: $((@($noData | ForEach-Object { "$($_.Profile)@$($_.Hostname)" })) -join ', ')" -ForegroundColor DarkGray }
if ($loaded.Count) { Write-Host "$($loaded.Count) are in use right now (user signed in) - repair once they sign out: $((@($loaded | ForEach-Object { "$($_.Profile)@$($_.Hostname)" })) -join ', ')" -ForegroundColor DarkGray }
if ($admin.Count)  { Write-Host "$($admin.Count) are protected admin profiles - left alone." -ForegroundColor DarkGray }

if ($repairable.Count -eq 0) { Write-Host "`nNothing to repair." -ForegroundColor Yellow; return }

Write-Host "`nRepairable (folder kept, only the registry entry is fixed):" -ForegroundColor Cyan
for ($j = 0; $j -lt $repairable.Count; $j++) {
    Write-Host ("  {0,2}) {1}  on  {2}  ({3})" -f ($j + 1), $repairable[$j].Profile, $repairable[$j].Hostname, $repairable[$j].Reason)
}
Write-Host "[A] all   [#] one   [B] back" -ForegroundColor White
$choice = (Read-Host "Choose").Trim().ToUpper()

$toRepair = @()
if ($choice -eq 'B' -or $choice -eq '') { return }
elseif ($choice -eq 'A') { $toRepair = $repairable }
else {
    $n = 0
    if ([int]::TryParse($choice, [ref]$n) -and $n -ge 1 -and $n -le $repairable.Count) { $toRepair = @($repairable[$n - 1]) }
    else { Write-Host "Invalid." -ForegroundColor DarkGray; return }
}
if ($toRepair.Count -eq 0) { Write-Host "Nothing chosen." -ForegroundColor Yellow; return }

Write-Host ""
Write-Host "This edits the profile registry on the machine. A backup is saved first." -ForegroundColor Yellow
Write-Host "The user must sign out and back in for the repair to take effect." -ForegroundColor Yellow
if ((Read-Host "Type YES to repair $($toRepair.Count) profile(s)").Trim() -cne 'YES') {
    Write-Host "Cancelled - nothing changed." -ForegroundColor Yellow; return
}

# --- Repair ------------------------------------------------------------------
foreach ($d in $toRepair) {
    # Double any apostrophe so a name like caitlin.o'sullivan cannot break out of
    # the single-quoted string it is pasted into on the remote machine.
    $safeProfile = ConvertTo-RemoteLiteral $d.Profile
    # Double-quoted here-string: $u is filled in here; the remote script's own
    # variables are escaped with a backtick so they survive to the machine.
    $repairCmd = @"
`$ErrorActionPreference = 'Stop'
`$u = '$safeProfile'
`$base = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'

# 1. Back up the whole ProfileList key before touching anything.
`$bdir = 'C:\ProgramData\DeskSideToolkit\ProfileListBackups'
if (-not (Test-Path `$bdir)) { New-Item -ItemType Directory -Path `$bdir -Force | Out-Null }
`$bfile = Join-Path `$bdir ('ProfileList-{0}-{1}.reg' -f `$u, (Get-Date -Format 'yyyyMMdd-HHmmss'))
& reg.exe export 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' `$bfile /y | Out-Null
"BACKUP|`$bfile"

try {
    # 2. Find the registry key(s) for this profile folder.
    `$keys = @(Get-ChildItem `$base | Where-Object {
        `$ip = (Get-ItemProperty `$_.PSPath -ErrorAction SilentlyContinue).ProfileImagePath
        `$ip -and ((Split-Path `$ip -Leaf) -ieq `$u)
    })
    if (`$keys.Count -eq 0) { 'NOKEY'; return }

    `$plain = `$keys | Where-Object { `$_.PSChildName -notlike '*.bak' } | Select-Object -First 1
    `$bak   = `$keys | Where-Object { `$_.PSChildName -like  '*.bak' } | Select-Object -First 1

    # 3. Never touch a profile that is loaded right now.
    if (`$plain) {
        `$sidCheck = `$plain.PSChildName
        `$live = Get-CimInstance Win32_UserProfile -Filter "SID='`$sidCheck'" -ErrorAction SilentlyContinue
        if (`$live -and `$live.Loaded) { 'SKIP-LOADED'; return }
    }

    # 4. Fix the key.
    if (`$bak) {
        # Classic .bak case: the .bak is the good hive. Drop the broken plain
        # key and rename .bak back to the real SID.
        `$sid = (`$bak.PSChildName -replace '\.bak$','')
        if (Test-Path "`$base\`$sid") { Remove-Item "`$base\`$sid" -Recurse -Force }
        Rename-Item -Path "`$base\`$sid.bak" -NewName `$sid
        `$target = "`$base\`$sid"
        `$mode = 'RENAME'
    }
    elseif (`$plain) {
        `$sid = `$plain.PSChildName
        `$target = `$plain.PSPath
        `$mode = 'STATE'
    }
    else { 'NOKEY'; return }

    # 5. The folder must still be there - that is the data we are keeping.
    `$ip = (Get-ItemProperty `$target -ErrorAction SilentlyContinue).ProfileImagePath
    if (-not (`$ip -and (Test-Path `$ip))) { 'NOFOLDER'; return }

    # 6. Clear the corrupt-state values so Windows loads it normally next time.
    New-ItemProperty -Path `$target -Name 'State'    -Value 0 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path `$target -Name 'RefCount' -Value 0 -PropertyType DWord -Force | Out-Null

    `$logd = 'C:\ProgramData\DeskSideToolkit'
    if (-not (Test-Path `$logd)) { New-Item -ItemType Directory -Path `$logd -Force | Out-Null }
    Add-Content (Join-Path `$logd 'ProfileRepair.log') ('{0}  repaired profile {1} ({2}), backup {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), `$u, `$mode, `$bfile)

    "REPAIRED-`$mode|`$sid|`$ip"
}
catch { 'FAIL ' + `$_.Exception.Message }
"@

    try { $res = (Invoke-AgentCmd $d.AgentId $repairCmd -TimeoutSec 120).Trim() }
    catch { $res = "ERROR $($_.Exception.Message)" }

    $lines  = @($res -split "`r?`n")
    $backup = ($lines | Where-Object { $_ -match '^BACKUP\|' } | Select-Object -First 1) -replace '^BACKUP\|', ''
    $status = ($lines | Where-Object { $_ -match '^(REPAIRED|SKIP-LOADED|NOFOLDER|NOKEY|FAIL|ERROR)' } | Select-Object -First 1)
    if (-not $status) { $status = $res }

    if ($status -match '^REPAIRED') {
        Write-Host ("  {0} @ {1}: repaired - tell the user to sign out and back in." -f $d.Profile, $d.Hostname) -ForegroundColor Green
        Write-ActionLog -Action 'Repair Corrupt Profile (TRMM)' -Target $d.Hostname `
            -Details "profile=$($d.Profile); reason=$($d.Reason); remote=$status; backup=$backup"
    }
    else {
        Write-Host ("  {0} @ {1}: NOT repaired - {2}" -f $d.Profile, $d.Hostname, $status) -ForegroundColor Red
        Write-ActionLog -Action 'Repair Corrupt Profile (TRMM)' -Target $d.Hostname -Result 'Failed' `
            -Details "profile=$($d.Profile); reason=$($d.Reason); remote=$status; backup=$backup"
    }
}

Write-Host "`nDone. If a profile still fails to load after signing out and in, delete it with Find-TrmmCorruptProfile.ps1." -ForegroundColor Cyan
