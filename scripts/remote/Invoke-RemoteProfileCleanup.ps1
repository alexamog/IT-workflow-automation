<#
.SYNOPSIS
    Run the profile-cleanup script (Remove-UnlistedProfiles.ps1) on a remote
    computer through Tactical RMM, using just the computer name.

.DESCRIPTION
    Two-phase, so the safety of the local script is kept:
      Phase 1  Runs the cleanup script remotely with -WhatIf and shows you
               the preview (KEEP / DELETE lists, keyword warnings) here.
      Phase 2  Only after you type YES locally does it run for real
               (with -Force, since the remote machine cannot show prompts).

    The local copy of Remove-UnlistedProfiles.ps1 is uploaded to the Tactical
    RMM script library automatically (created or updated), so the remote
    machine always runs the same version you have here.

    Needs TRMM_APIKEY and TRMM_URL - run ..\..\setup\Set-TacticalCredentials.ps1 once.

.EXAMPLE
    .\Invoke-RemoteProfileCleanup.ps1 ITLAPSPARE-11 -Keep alex.amog, john.smith

.EXAMPLE
    # Keep list from a text file of full names, plus disk cleanup + health check:
    .\Invoke-RemoteProfileCleanup.ps1 ITLAPSPARE-11 -KeepFile .\keep-list.txt -Cleanup -HealthCheck

.EXAMPLE
    # No profile deletion - just remote disk cleanup and health check:
    .\Invoke-RemoteProfileCleanup.ps1 ITLAPSPARE-11 -Cleanup -HealthCheck
#>

[CmdletBinding()]
param(
    # The remote computer's hostname as it appears in Tactical RMM.
    # If omitted (e.g. launched from the AD-Toolkit menu), you'll be prompted.
    [Parameter(Position = 0)]
    [string]$ComputerName,

    # Usernames to KEEP on the remote machine.
    [string[]]$Keep,

    # Local text file of people to keep ("First Last" per line -> first.last).
    [string]$KeepFile,

    # OPPOSITE MODE: delete ONLY these named profiles, leave everything else.
    [string[]]$DeleteOnly,

    # Also run disk cleanup / health check remotely (same as the local switches).
    [switch]$Cleanup,
    [switch]$HealthCheck
)

if ($DeleteOnly -and ($Keep -or $KeepFile)) {
    Write-Host "ERROR: -DeleteOnly and -Keep/-KeepFile are opposite modes - use one." -ForegroundColor Red
    return
}

# --- Prompt for anything missing (menu mode) ---------------------------------
if (-not $ComputerName) {
    $ComputerName = Read-Host "Remote computer name (as shown in Tactical RMM, e.g. ITLAPSPARE-11)"
    if (-not $ComputerName) { Write-Host "No computer name - cancelled." -ForegroundColor Yellow; return }
}
if (-not $Keep -and -not $KeepFile -and -not $DeleteOnly -and -not $Cleanup -and -not $HealthCheck) {
    Write-Host ""
    Write-Host "  Which kind of profile cleanup?" -ForegroundColor Cyan
    Write-Host "    [K] KEEP LIST    - delete EVERY profile EXCEPT the ones you name  (mass cleanup)" -ForegroundColor Yellow
    Write-Host "    [D] DELETE LIST  - delete ONLY the profiles you name              (surgical)" -ForegroundColor Magenta
    Write-Host "    [N] Neither      - just disk cleanup / health check" -ForegroundColor Gray
    $mode = (Read-Host "  Choose K, D or N").Trim().ToUpper()

    if ($mode -eq 'K') {
        Write-Host "  KEEP LIST mode: everything NOT on this list gets deleted." -ForegroundColor Yellow
        $answer = Read-Host "  Usernames to KEEP (comma-separated), or path to a names .txt file"
        if ($answer -like '*.txt') { $KeepFile = $answer }
        elseif ($answer) { $Keep = @($answer -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }) }
    }
    elseif ($mode -eq 'D') {
        Write-Host "  DELETE LIST mode: ONLY these profiles get deleted; everything else is untouched." -ForegroundColor Magenta
        $answer = Read-Host "  Usernames to DELETE (comma-separated)"
        if ($answer) { $DeleteOnly = @($answer -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }) }
    }

    if ((Read-Host "  Also run disk cleanup? (y/N)") -eq 'y')                         { $Cleanup = $true }
    if ((Read-Host "  Also run health check (DISM + sfc, 15-30 min)? (y/N)") -eq 'y') { $HealthCheck = $true }
}

# --- Tactical RMM plumbing -------------------------------------------------
# Invoke-TrmmRequest and the credential check both live in the shared library.
# (The "show the API's real error" handling this script used to do on its own is
# now built into Invoke-TrmmRequest, so every feature gets it.)
. "$PSScriptRoot\..\..\lib\Common.ps1"

if (-not (Test-TrmmConfigured)) { return }

# --- Find the agent by computer name ----------------------------------------
$ComputerName = $ComputerName.Trim()
Write-Host "Looking up '$ComputerName' in Tactical RMM..."
$agents = @(Invoke-TrmmRequest GET 'agents/')
$agent  = @($agents | Where-Object { $_.hostname -eq $ComputerName })

if ($agent.Count -eq 0) {
    Write-Host "No agent named '$ComputerName' found." -ForegroundColor Red
    $close = @($agents | Where-Object { $_.hostname -match [regex]::Escape($ComputerName) })
    if ($close.Count -gt 0) {
        Write-Host "Did you mean:" -ForegroundColor Yellow
        $close | ForEach-Object { Write-Host "  - $($_.hostname) ($($_.client_name) / $($_.site_name))" }
    }
    return
}
if ($agent.Count -gt 1) {
    Write-Host "More than one agent is named '$ComputerName':" -ForegroundColor Red
    $agent | ForEach-Object { Write-Host "  - $($_.hostname)  client: $($_.client_name)  site: $($_.site_name)" }
    Write-Host "Rename one in TRMM, or run the cleanup from the TRMM UI instead." -ForegroundColor Yellow
    return
}
$agent = $agent[0]

Write-Host ("Found: {0}  (client: {1}, site: {2}, status: {3}, user: {4})" -f `
    $agent.hostname, $agent.client_name, $agent.site_name, $agent.status, $agent.logged_username) -ForegroundColor Green

if ($agent.status -ne 'online') {
    Write-Host "'$ComputerName' is $($agent.status) - it must be online. Try again when it is." -ForegroundColor Red
    return
}

# --- Build the keep list locally --------------------------------------------
# -KeepFile is parsed HERE (the file lives on your machine, not the remote one),
# using the same rules as the cleanup script: "First Last" -> first.last.
if ($KeepFile) {
    if (-not (Test-Path -Path $KeepFile)) {
        Write-Host "ERROR: Keep file not found: $KeepFile" -ForegroundColor Red
        return
    }
    $rawNames = Get-Content -Path $KeepFile |
        ForEach-Object { $_ -split ',' } |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne '' -and -not $_.StartsWith('#') }

    $guessed = @()
    foreach ($name in $rawNames) {
        $parts = $name -split '\s+'
        if ($parts.Count -eq 1) { $username = $name.ToLower() }
        else {
            $username = ('{0}.{1}' -f $parts[0], $parts[-1]).ToLower()
            if ($parts.Count -gt 2) {
                Write-Host "CHECK  : '$name' has $($parts.Count) words - guessed '$username'." -ForegroundColor Yellow
                $guessed += ("'{0}' -> {1}" -f $name, $username)
            }
        }
        Write-Host ("File   : {0,-30} -> {1}" -f "'$name'", $username)
        if ($Keep -notcontains $username) { $Keep += $username }
    }
}

# --- Show the resolved KEEP list explicitly, and confirm any guesses ---------
if ($Keep) {
    Write-Host "`n==================================================" -ForegroundColor Cyan
    Write-Host "Profiles that will be KEPT on ${ComputerName}:" -ForegroundColor Cyan
    foreach ($k in ($Keep | Sort-Object -Unique)) { Write-Host "   KEEP : $k" -ForegroundColor Green }
    Write-Host "   KEEP : protected accounts (PROTECTED_ACCOUNTS, default 'adm-*')" -ForegroundColor Green
    Write-Host "Every other profile on the machine is a candidate for deletion." -ForegroundColor Yellow
    Write-Host "==================================================" -ForegroundColor Cyan

    if ($guessed.Count -gt 0) {
        Write-Host "`n$($guessed.Count) name(s) were GUESSED from 3+ words - verify before continuing:" -ForegroundColor Yellow
        foreach ($g in $guessed) { Write-Host "   $g" -ForegroundColor Yellow }
        $ok = Read-Host "Are these guessed usernames correct? (y/n)"
        if ($ok.Trim().ToUpper() -ne 'Y') {
            Write-Host "Stopped. Fix the exact username(s) in the keep file, then re-run." -ForegroundColor Yellow
            return
        }
    }
}

# Delete-list mode: show exactly what will be removed - opposite of keep mode.
if ($DeleteOnly) {
    Write-Host "`n==================================================" -ForegroundColor Magenta
    Write-Host "DELETE-LIST MODE on ${ComputerName}" -ForegroundColor Magenta
    Write-Host "ONLY these profiles will be deleted:" -ForegroundColor Magenta
    foreach ($d in ($DeleteOnly | Sort-Object -Unique)) { Write-Host "   DELETE : $d" -ForegroundColor Red }
    Write-Host "Every other profile on the machine is left alone." -ForegroundColor Magenta
    Write-Host "(protected accounts - PROTECTED_ACCOUNTS, default adm-* - are skipped.)" -ForegroundColor DarkGray
    Write-Host "==================================================" -ForegroundColor Magenta
}

if (-not $Keep -and -not $DeleteOnly -and -not $Cleanup -and -not $HealthCheck) {
    Write-Host "Nothing to do: give -Keep/-KeepFile, -DeleteOnly, or -Cleanup / -HealthCheck." -ForegroundColor Yellow
    return
}

# --- Upload our local script to the TRMM script library ---------------------
$scriptName = 'Toolkit - Remove-UnlistedProfiles'
$localPath  = Join-Path -Path $PSScriptRoot -ChildPath '..\maintenance\Remove-UnlistedProfiles.ps1'
# ReadAllText, NOT Get-Content -Raw: Get-Content attaches hidden metadata to
# its strings, which makes ConvertTo-Json send {"value": "..."} instead of a
# plain string - the TRMM API rejects that as "Not a valid string".
$scriptBody = [System.IO.File]::ReadAllText($localPath)

Write-Host "`nSyncing the cleanup script to the TRMM script library..."
$payload = @{
    name            = $scriptName
    shell           = 'powershell'
    script_type     = 'userdefined'
    script_body     = $scriptBody
    category        = 'Desk Side Toolkit'
    description     = 'Deletes user profiles not on the keep list. Managed by the Desk Side toolkit - do not edit here.'
    default_timeout = 3600
    args            = @()
}
$existing = @(Invoke-TrmmRequest GET 'scripts/') | Where-Object { $_.name -eq $scriptName } | Select-Object -First 1
if ($existing) {
    Invoke-TrmmRequest PUT "scripts/$($existing.id)/" $payload | Out-Null
    $scriptId = $existing.id
}
else {
    $created  = Invoke-TrmmRequest POST 'scripts/' $payload
    $scriptId = $created.id
    if (-not $scriptId) {
        # Some TRMM versions return only a message on create - look the id up.
        $scriptId = (@(Invoke-TrmmRequest GET 'scripts/') | Where-Object { $_.name -eq $scriptName } | Select-Object -First 1).id
    }
}
if (-not $scriptId) {
    Write-Host "Could not create or find the script library entry - stopping here." -ForegroundColor Red
    return
}
Write-Host "Script library entry ready (id $scriptId)." -ForegroundColor Green

# --- Logging -----------------------------------------------------------------
# One row per action in output\AD-Toolkit-Actions.csv (the toolkit's shared
# audit log) + a full transcript of the remote output for each run.
$outputDir = Get-ADToolOutputDir
$runLog    = Join-Path -Path $outputDir -ChildPath ("RemoteCleanup-{0}-{1}.log" -f $ComputerName, (Get-Date -Format 'yyyyMMdd-HHmmss'))

# Audit rows go through Write-ActionLog in the shared library, so every feature
# writes the same columns to the same file. This wrapper just saves repeating
# the Action name and target machine on all four call sites below.
function Write-RemoteActionLog ($Result, $Details) {
    Write-ActionLog -Action 'Remote Profile Cleanup (TRMM)' -Target $ComputerName -Result $Result -Details $Details
}

$optionSummary = "keep=[$($Keep -join ',')] deleteonly=[$($DeleteOnly -join ',')] cleanup=$([bool]$Cleanup) healthcheck=$([bool]$HealthCheck)"

# --- Shared argument list ----------------------------------------------------
# The keep list travels as ONE comma-joined argument; the cleanup script
# splits it back apart (that is what its comma-split block is for).
$baseArgs = @()
if ($Keep)       { $baseArgs += @('-Keep', ($Keep -join ',')) }
if ($DeleteOnly) { $baseArgs += @('-DeleteOnly', ($DeleteOnly -join ',')) }

function Invoke-Remote ($runArgs, $timeout) {
    # TRMM's runscript endpoint requires ALL of these fields to be present -
    # leaving any out causes a Server Error (500).
    Invoke-TrmmRequest POST "agents/$($agent.agent_id)/runscript/" @{
        script          = $scriptId
        output          = 'wait'
        args            = $runArgs
        timeout         = $timeout
        run_as_user     = $false
        env_vars        = @()
        custom_field    = $null
        save_all_output = $true
        email           = @()
        emailMode       = 'default'
    }
}

# --- Phase 1: remote preview (-WhatIf) ---------------------------------------
if ($Keep -or $DeleteOnly) {
    Write-ToolHeader "Remote preview on $ComputerName (nothing deleted yet)"
    $preview = Invoke-Remote ($baseArgs + '-WhatIf') 300
    $preview
    "===== PREVIEW $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') on $ComputerName =====`r`n$preview" |
        Add-Content -Path $runLog -Encoding UTF8

    # --- Phase 2: confirm locally, then run for real -------------------------
    # Different confirmation word per mode so they can't be confused.
    $word = if ($DeleteOnly) { 'DELETE LIST' } else { 'YES' }
    Write-Host ""
    if (-not (Confirm-DeskSideWord "run this FOR REAL on $ComputerName" -Word $word -CancelNote "nothing was changed on $ComputerName")) {
        Write-RemoteActionLog 'Cancelled' "$optionSummary log=$(Split-Path $runLog -Leaf)"
        return
    }
}

$realArgs = $baseArgs + '-Force'
if ($Cleanup)     { $realArgs += '-Cleanup' }
if ($HealthCheck) { $realArgs += '-HealthCheck' }
$timeout = if ($HealthCheck) { 3600 } elseif ($Cleanup) { 1800 } else { 600 }

# Long runs cannot use 'wait' mode - the TRMM server's proxy cuts the held
# connection after a few minutes (502 Bad Gateway) even though the script
# keeps running. So: dispatch fire-and-forget, then follow the log file the
# cleanup script writes on the remote machine. Bonus: live progress updates.
function Invoke-RemoteCmd ($command) {
    Invoke-TrmmAgentCommand -AgentId $agent.agent_id -Command $command -TimeoutSec 60
}

$remoteLogPath = Join-Path (Get-DeskSideProgramDataDir) 'ProfileCleanup.log'

# Note how many log lines exist BEFORE we start, so we only show new ones.
$shown = 0
try {
    $shown = [int]("$(Invoke-RemoteCmd "if (Test-Path '$remoteLogPath') { @(Get-Content '$remoteLogPath').Count } else { 0 }")".Trim())
} catch { $shown = 0 }

Write-ToolHeader "Running on $ComputerName"
try {
    Invoke-TrmmRequest POST "agents/$($agent.agent_id)/runscript/" @{
        script          = $scriptId
        output          = 'forget'
        args            = $realArgs
        timeout         = $timeout
        run_as_user     = $false
        env_vars        = @()
        custom_field    = $null
        save_all_output = $true
        email           = @()
        emailMode       = 'default'
    } | Out-Null
}
catch {
    Write-RemoteActionLog 'Failed' "$optionSummary error=$($_.Exception.Message)"
    throw
}
Write-Host "Dispatched. Following the remote log (checks every 20 seconds; Ctrl+C stops watching, NOT the remote run)." -ForegroundColor Yellow
if ($HealthCheck) { Write-Host "DISM + sfc take 15-30 minutes; expect long quiet stretches between updates." -ForegroundColor DarkGray }

$deadline = (Get-Date).AddSeconds($timeout + 120)
$done     = $false
while (-not $done -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 20
    $tailCmd = "if (Test-Path '$remoteLogPath') { (Get-Content '$remoteLogPath' | Select-Object -Skip $shown) -join [char]10 }"
    try {
        $chunk = "$(Invoke-RemoteCmd $tailCmd)"
    }
    catch { continue }   # a hiccup while polling is not fatal - try again

    $newLines = @($chunk -split "[`r`n]+" | Where-Object { $_.Trim() -ne '' })
    if ($newLines.Count -gt 0) {
        $newLines | ForEach-Object { Write-Host "  $_" }
        $newLines | Add-Content -Path $runLog -Encoding UTF8
        $shown += $newLines.Count
        if (@($newLines | Where-Object { $_ -match '\]\s+END\s*$' }).Count -gt 0) { $done = $true }
    }
    else {
        Write-Host ("  ... still running ({0:HH:mm:ss})" -f (Get-Date)) -ForegroundColor DarkGray
    }
}

if ($done) {
    Write-RemoteActionLog 'Success' "$optionSummary log=$(Split-Path $runLog -Leaf)"
    Write-Host "`nDone. Remote log lines saved to: $runLog" -ForegroundColor Green
}
else {
    Write-RemoteActionLog 'Unknown' "$optionSummary timed out watching after $timeout sec - check TRMM history or $remoteLogPath on the machine"
    Write-Host "`nStopped watching (timeout) but the remote run may still be going." -ForegroundColor Yellow
    Write-Host "Check the TRMM history Output link, or $remoteLogPath on $ComputerName." -ForegroundColor Yellow
}
