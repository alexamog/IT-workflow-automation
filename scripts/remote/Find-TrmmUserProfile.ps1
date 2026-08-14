<#
.SYNOPSIS
    Find a user's Windows profile across Tactical RMM computers (by hostname
    keyword), check if it exists / is loaded / is corrupt, and optionally delete
    it on the machines where it is found.

.DESCRIPTION
    You give a username (e.g. alex.amog) and a hostname keyword
    (e.g. ITDESSPARE, or * for every computer). It searches each matching ONLINE
    agent for that profile and reports:
        Found / Loaded (someone signed in) / Corrupt
    Corrupt = Win32_UserProfile Status has the corrupt bit, OR a ".bak" registry
    key exists for it, OR its C:\Users folder is missing.

    Then you can delete the profile on the machines where it exists. Deletion:
      - skips machines where the profile is currently loaded (log the user off),
      - refuses protected names (PROTECTED_ACCOUNTS, default adm-*),
      - removes both the folder and the registry entry (Remove-CimInstance),
      - is confirmed once and logged to output\AD-Toolkit-Actions.csv and to
        C:\ProgramData\DeskSideToolkit\ProfileCleanup.log on each machine.

    Needs TRMM_APIKEY / TRMM_URL - run ..\..\setup\Set-TacticalCredentials.ps1 once.

.EXAMPLE
    .\Find-TrmmUserProfile.ps1
#>

# NOT ON THE MAIN MENU, and that is deliberate - there is no .tool.psd1
# manifest beside this file, so the launcher never lists it. It is opened
# from Manage-TrmmProfiles.ps1, which collects the answers it needs first.
# It still runs on its own if you want to use it directly.

[CmdletBinding()]
param()

. "$PSScriptRoot\..\..\lib\Common.ps1"

if (-not (Test-TrmmConfigured)) { return }

# --- Inputs ------------------------------------------------------------------
$user = (Read-Host "Username whose profile to find (e.g. alex.amog)").Trim()
if (-not $user) { Write-Host "No username - cancelled." -ForegroundColor Yellow; return }
# Allow letters, digits, dot, hyphen and apostrophe - real names include
# caitlin.o'sullivan. Anything else (spaces, pipes, quotes-that-are-not-')
# is refused so nothing strange reaches the remote command.
if ($user -notmatch "^[\w.\-']+$") { Write-Host "Username has odd characters - stopping." -ForegroundColor Red; return }

# The name is pasted into a single-quoted string on the remote machine, so
# double any apostrophe (o'sullivan) or it closes the quote and the command
# fails to parse. Escape once here; every remote use below is $safeUser.
$safeUser = ConvertTo-RemoteLiteral $user

$kw = (Read-Host "Hostname keyword to search (e.g. ITDESSPARE), or * for ALL computers").Trim()

Write-Host "Getting the agent list from Tactical RMM..."
$lookup = Get-TrmmAgent -HostnameLike $kw
if (-not $lookup.Ok) { return }        # the message was already printed
$agents = $lookup.Agents

$offline = @($agents | Where-Object { $_.status -ne 'online' })
$targets = @($agents | Where-Object { $_.status -eq 'online' })

Write-Host ("Matched {0} computer(s): {1} online, {2} offline (offline are skipped)." -f ($targets.Count + $offline.Count), $targets.Count, $offline.Count) -ForegroundColor Cyan
if ($targets.Count -eq 0) { Write-Host "Nothing online to check." -ForegroundColor Yellow; return }

# --- Check each machine for the profile --------------------------------------
$checkCmd = @"
`$u = '$safeUser'
`$p = Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { (Split-Path `$_.LocalPath -Leaf) -ieq `$u }
if (-not `$p) { 'NOTFOUND' }
else {
    `$bak = Test-Path ("HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\" + `$p.SID + ".bak")
    `$missing = -not (Test-Path `$p.LocalPath)
    `$corruptBit = [bool](`$p.Status -band 8)
    'FOUND loaded={0} corrupt={1} path={2}' -f `$p.Loaded, (`$bak -or `$missing -or `$corruptBit), `$p.LocalPath
}
"@

$found = @()
$i = 0
foreach ($a in $targets) {
    $i++
    Write-Progress -Activity "Searching for '$user'" -Status "$i of $($targets.Count): $($a.hostname)" -PercentComplete (100 * $i / $targets.Count)
    try { $out = (Invoke-TrmmAgentText -AgentId $a.agent_id -Command $checkCmd).Trim() } catch { continue }
    if ($out -match '^FOUND') {
        $found += [PSCustomObject]@{
            Hostname = $a.hostname
            Loaded   = ($out -match 'loaded=True')
            Corrupt  = ($out -match 'corrupt=True')
            Path     = (($out -split 'path=')[1])
            AgentId  = $a.agent_id
            Client   = $a.client_name
        }
    }
}
Write-Progress -Activity "Searching for '$user'" -Completed

if ($found.Count -eq 0) { Write-Host "`nProfile '$user' not found on any matched online computer." -ForegroundColor Green; return }

Write-Host "`n'$user' profile found on $($found.Count) computer(s):" -ForegroundColor Cyan
$found | Sort-Object Hostname | Format-Table Hostname, Loaded, Corrupt, Client, Path -AutoSize | Out-String | Write-Host

# --- Protected-name guard ----------------------------------------------------
if (Test-DeskSideProtectedAccount $user) {
    Write-Host "'$user' is a protected account - not offering deletion." -ForegroundColor Yellow
    return
}

# --- Delete option -----------------------------------------------------------
$deletable = @($found | Where-Object { -not $_.Loaded })
$loaded    = @($found | Where-Object { $_.Loaded })
if ($loaded.Count -gt 0) { Write-Host "$($loaded.Count) skipped for deletion (user logged in): $(($loaded.Hostname) -join ', ')" -ForegroundColor DarkGray }
if ($deletable.Count -eq 0) { Write-Host "Nothing deletable (all loaded)." -ForegroundColor Yellow; return }

Write-Host "`nDelete the '$user' profile on these $($deletable.Count) computer(s)?" -ForegroundColor Yellow
$deletable | ForEach-Object { Write-Host ("   {0}{1}" -f $_.Hostname, $(if ($_.Corrupt) { '  (corrupt)' } else { '' })) -ForegroundColor Red }
Write-Host "[A] delete on ALL listed   [#] pick one   [B] back" -ForegroundColor White
$choice = (Read-Host "Choose").Trim().ToUpper()

$toDelete = @()
if ($choice -eq 'B' -or $choice -eq '') { return }
elseif ($choice -eq 'A') { $toDelete = $deletable }
else {
    for ($j = 0; $j -lt $deletable.Count; $j++) { Write-Host ("  {0}) {1}" -f ($j + 1), $deletable[$j].Hostname) }
    $n = 0
    if ([int]::TryParse((Read-Host "Number"), [ref]$n) -and $n -ge 1 -and $n -le $deletable.Count) { $toDelete = @($deletable[$n - 1]) }
    else { Write-Host "Cancelled." -ForegroundColor DarkGray; return }
}

if (-not (Confirm-DeskSideWord "permanently delete '$user' on $($toDelete.Count) machine(s)")) { return }

# Audit log (operator side).
# Audit rows go through Write-ActionLog in the shared library, so every feature
# writes the same columns to the same file.
$csv = Join-Path (Get-ADToolOutputDir -Category 'Logs') 'AD-Toolkit-Actions.csv'

$delCmd = @"
`$u = '$safeUser'
`$p = Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { (Split-Path `$_.LocalPath -Leaf) -ieq `$u -and -not `$_.Special }
if (-not `$p) { 'NOTFOUND' }
elseif (`$p.Loaded) { 'SKIP-LOADED' }
else {
    try {
        Remove-CimInstance -InputObject `$p -ErrorAction Stop
        $(Get-DeskSideRemoteProgramDataLine)
        `$d = `$DeskSideData; if (-not (Test-Path `$d)) { New-Item -ItemType Directory -Path `$d -Force | Out-Null }
        Add-Content (Join-Path `$d 'ProfileCleanup.log') ('{0}  [remote-find]  DELETED profile {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), `$u)
        'DELETED'
    } catch { 'FAIL ' + `$_.Exception.Message }
}
"@

foreach ($m in $toDelete) {
    try { $res = (Invoke-TrmmAgentText -AgentId $m.AgentId -Command $delCmd).Trim() } catch { $res = "ERROR $($_.Exception.Message)" }
    $colour = if ($res -eq 'DELETED') { 'Green' } else { 'Red' }
    Write-Host ("  {0}: {1}" -f $m.Hostname, $res) -ForegroundColor $colour
    $result = if ($res -eq 'DELETED') { 'Success' } else { 'Failed' }
    Write-ActionLog -Action 'Delete Remote Profile (TRMM)' -Target $m.Hostname -Result $result -Details "profile=$user; corrupt=$($m.Corrupt); remote=$res"
}
Write-Host "`nDone. Logged to $csv" -ForegroundColor Green
