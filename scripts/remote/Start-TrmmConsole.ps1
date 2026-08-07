<#
.SYNOPSIS
    Tactical RMM console: find a machine (by computer name OR by logged-in user),
    then pick what to do to it - clean profiles, send a file, remote PowerShell,
    or take control (remote desktop).

.DESCRIPTION
    Machine-first workflow. You search once, then act as many times as you like
    on that machine. The individual actions are the same standalone scripts in
    this folder; this console just finds the machine for you and hands the
    computer name to them.

    Needs TRMM_APIKEY and TRMM_URL - run ..\..\setup\Set-TacticalCredentials.ps1 once.

.EXAMPLE
    .\Start-TrmmConsole.ps1
#>

[CmdletBinding()]
param()

. "$PSScriptRoot\..\..\lib\Common.ps1"

if (-not (Test-TrmmConfigured)) { return }

# Run a PowerShell command on the agent and return its output text.
# -AsUser runs it in the logged-in user's session (needed to lock the screen).
# This script passes whole agent OBJECTS around, so this wrapper pulls the id
# out of the object for the shared helper.
function Invoke-AgentCmd ($agent, $command, [switch]$AsUser, [int]$TimeoutSec = 60) {
    Invoke-TrmmAgentCommand -AgentId $agent.agent_id -Command $command -AsUser:$AsUser -TimeoutSec $TimeoutSec
}

# --- Pick a machine ----------------------------------------------------------
# Returns one agent object, or $null if the user backed out.
function Select-Agent {
    while ($true) {
        Write-Host ""
        $mode = (Read-Host "Find machine by [C]omputer name or [U]ser?  (B = back)").Trim().ToUpper()
        if ($mode -eq 'B' -or $mode -eq '') { return $null }
        if ($mode -notin 'C', 'U') { Write-Host "Enter C or U." -ForegroundColor Yellow; continue }

        $term = (Read-Host $(if ($mode -eq 'C') { "  Computer name (whole or part)" } else { "  User name (whole or part)" })).Trim()
        if (-not $term) { continue }

        Write-Host "  Searching Tactical RMM..." -ForegroundColor DarkGray
        try { $agents = @(Invoke-TrmmRequest GET 'agents/') }
        catch { Write-Host "  Lookup failed: $($_.Exception.Message)" -ForegroundColor Red; continue }

        if ($mode -eq 'C') {
            # Exact hostname first; fall back to a contains match.
            $hits = @($agents | Where-Object { $_.hostname -eq $term })
            if ($hits.Count -eq 0) { $hits = @($agents | Where-Object { $_.hostname -match [regex]::Escape($term) }) }
        }
        else {
            $hits = @($agents | Where-Object { $_.logged_username -and $_.logged_username -match [regex]::Escape($term) })
        }

        if ($hits.Count -eq 0) { Write-Host "  No machine matched '$term'." -ForegroundColor Yellow; continue }

        if ($hits.Count -eq 1) { return $hits[0] }

        Write-Host "  $($hits.Count) matches:" -ForegroundColor Cyan
        $hits = @($hits | Sort-Object hostname)
        for ($i = 0; $i -lt $hits.Count; $i++) {
            Write-Host ("    {0,2}) {1,-18} user: {2,-18} {3}  ({4} / {5})" -f `
                ($i + 1), $hits[$i].hostname, ("$($hits[$i].logged_username)"), $hits[$i].status, $hits[$i].client_name, $hits[$i].site_name)
        }
        $sel = (Read-Host "  Number (or ENTER to search again)").Trim()
        $n = 0
        if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $hits.Count) { return $hits[$n - 1] }
    }
}

# --- Take control (MeshCentral remote desktop) -------------------------------
function Invoke-TakeControl ($agent) {
    try { $mesh = Invoke-TrmmRequest GET "agents/$($agent.agent_id)/meshcentral/" }
    catch { Write-Host "Could not get a remote-control link: $($_.Exception.Message)" -ForegroundColor Red; return }

    if ($mesh.control) {
        Write-Host "Opening remote desktop for $($agent.hostname) in your browser..." -ForegroundColor Green
        Start-Process $mesh.control
    }
    else { Write-Host "No control URL returned for this agent." -ForegroundColor Yellow }
}

# --- Power actions (confirm first - they interrupt the logged-in user) -------
function Invoke-Restart ($agent) {
    Write-Host "Restart $($agent.hostname)? Any logged-in user loses unsaved work." -ForegroundColor Yellow
    if (-not (Confirm-DeskSideWord 'restart')) { return }
    try { Invoke-TrmmRequest POST "agents/$($agent.agent_id)/reboot/" @{} | Out-Null; Write-Host "Restart sent to $($agent.hostname)." -ForegroundColor Green }
    catch { Write-Host "Restart failed: $($_.Exception.Message)" -ForegroundColor Red }
}

function Invoke-Lock ($agent) {
    if (-not $agent.logged_username) { Write-Host "No user is logged in - nothing to lock." -ForegroundColor Yellow; return }
    if ((Read-Host "Lock the screen on $($agent.hostname) (user $($agent.logged_username))? (y/n)").Trim().ToUpper() -ne 'Y') { return }
    try { Invoke-AgentCmd $agent 'rundll32.exe user32.dll,LockWorkStation' -AsUser | Out-Null; Write-Host "Lock sent." -ForegroundColor Green }
    catch { Write-Host "Lock failed: $($_.Exception.Message)" -ForegroundColor Red }
}

function Invoke-Sleep ($agent) {
    if ((Read-Host "Put $($agent.hostname) to sleep? (y/n)").Trim().ToUpper() -ne 'Y') { return }
    # Suspend (S3). If hibernate is enabled the machine hibernates instead.
    try { Invoke-AgentCmd $agent 'rundll32.exe powrprof.dll,SetSuspendState 0,1,0' | Out-Null; Write-Host "Sleep sent to $($agent.hostname)." -ForegroundColor Green }
    catch { Write-Host "Sleep failed: $($_.Exception.Message)" -ForegroundColor Red }
}

# --- Installed applications (read from the registry uninstall keys) ----------
function Get-InstalledApp ($agent) {
    $cmd = @'
$keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
Get-ItemProperty $keys -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName } |
    Select-Object DisplayName, DisplayVersion, Publisher |
    Sort-Object DisplayName |
    Format-Table -AutoSize | Out-String -Width 200
'@
    Write-Host "Reading installed applications from $($agent.hostname)..." -ForegroundColor DarkGray
    try { $out = "$(Invoke-AgentCmd $agent $cmd -TimeoutSec 90)" }
    catch { Write-Host "Failed: $($_.Exception.Message)" -ForegroundColor Red; return }

    Write-Host $out
    if ((Read-Host "Save this list to a file? (y/n)").Trim().ToUpper() -eq 'Y') {
        $outputDir = Join-Path -Path $PSScriptRoot -ChildPath '..\..\output'
        if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }
        $file = Join-Path $outputDir ("Installed Apps - {0} - {1}.txt" -f $agent.hostname, (Get-Date -Format 'yyyy-MM-dd HHmmss'))
        $out | Out-File -FilePath $file -Encoding UTF8
        Write-Host "Saved: $file" -ForegroundColor Green
    }
}

# --- Main loop ---------------------------------------------------------------
$here = $PSScriptRoot
Write-ToolBanner 'Tactical RMM Console'

$agent = Select-Agent
while ($agent) {
    # Refresh from the agent LIST, not the detail endpoint - the detail endpoint
    # returns blank logged_username / client_name. Keep the same agent by id.
    try {
        $fresh = @(Invoke-TrmmRequest GET 'agents/') | Where-Object { $_.agent_id -eq $agent.agent_id } | Select-Object -First 1
        if ($fresh) { $agent = $fresh }
    } catch { }

    # TRMM's logged_username can lag or be blank; ask the machine directly. Owner
    # of explorer.exe catches console AND RDP users; fall back to the console user.
    if ($agent.status -eq 'online') {
        $liveUserCmd = @'
$who = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
    $o = Invoke-CimMethod -InputObject $_ -MethodName GetOwner -ErrorAction SilentlyContinue
    if ($o.User) { "$($o.Domain)\$($o.User)" }
}) | Select-Object -Unique
if ($who) { $who -join ', ' } else { (Get-CimInstance Win32_ComputerSystem).UserName }
'@
        try {
            $live = (Invoke-AgentCmd $agent $liveUserCmd -TimeoutSec 40).Trim()
            if ($live) { $agent | Add-Member -NotePropertyName logged_username -NotePropertyValue $live -Force }
        } catch { }
    }

    Write-ToolHeader ("{0}  [{1}]" -f $agent.hostname, $agent.status)
    Write-Host ("     Client: {0}   Site: {1}" -f $agent.client_name, $agent.site_name) -ForegroundColor DarkGray
    Write-Host ("     Logged-in user: {0}" -f ("$($agent.logged_username)")) -ForegroundColor DarkGray
    if ($agent.status -ne 'online') { Write-Host "     (Offline - actions need it online; you can still change machine.)" -ForegroundColor Yellow }
    Write-Host ''

    Write-ToolMenuItem -Key 1 -Label 'Clean up user profiles (remote)'
    Write-ToolMenuItem -Key 2 -Label 'Send a file'
    Write-ToolMenuItem -Key 3 -Label 'Remote PowerShell prompt'
    Write-ToolMenuItem -Key 4 -Label 'Take control (remote desktop)'
    Write-ToolMenuItem -Key 5 -Label 'Restart'
    Write-ToolMenuItem -Key 6 -Label 'Lock screen'
    Write-ToolMenuItem -Key 7 -Label 'Sleep'
    Write-ToolMenuItem -Key 8 -Label 'Installed applications'
    Write-ToolMenuItem -Key 9 -Label 'Printers (add by IP / remove)'
    Write-ToolMenuItem -Key 'M' -Label 'Pick a different machine'
    Write-ToolMenuItem -Key 'B' -Label 'Back'

    Write-Host ''
    $choice = (Read-Host "  Select").Trim().ToUpper()
    switch ($choice) {
        '1' { & (Join-Path $here 'Invoke-RemoteProfileCleanup.ps1') $agent.hostname }
        '2' { & (Join-Path $here 'Send-TrmmFile.ps1') $agent.hostname }
        '3' { & (Join-Path $here 'Enter-TrmmShell.ps1') $agent.hostname }
        '4' { Invoke-TakeControl $agent }
        '5' { Invoke-Restart $agent }
        '6' { Invoke-Lock $agent }
        '7' { Invoke-Sleep $agent }
        '8' { Get-InstalledApp $agent }
        '9' { & (Join-Path $here 'Manage-TrmmPrinters.ps1') $agent.hostname }
        'M' { $agent = Select-Agent }
        'B' { return }
        default { Write-Host "Unknown option." -ForegroundColor DarkGray }
    }
}
