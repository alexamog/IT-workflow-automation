<#
.SYNOPSIS
    Copy a local file to a remote computer through Tactical RMM, using just
    the computer name.

.DESCRIPTION
    Encodes the file as base64, sends it through a temporary TRMM script that
    decodes and writes it on the remote machine, then verifies the copy by
    comparing SHA256 hashes. The temporary script is deleted from the TRMM
    library afterwards.

    Size limit: 10 MB. For bigger files use MeshCentral's file transfer
    (in TRMM: right-click the agent > Remote Background > Files).

    Needs TRMM_APIKEY and TRMM_URL - run ..\..\setup\Set-TacticalCredentials.ps1 once.

.EXAMPLE
    .\Send-TrmmFile.ps1 ITLAPSPARE-11 -Path .\keep-list.txt -Destination C:\Temp\keep-list.txt

.EXAMPLE
    # Destination ending in \ keeps the original file name:
    .\Send-TrmmFile.ps1 ITLAPSPARE-11 -Path '..\maintenance\Remove-UnlistedProfiles.ps1' -Destination C:\Temp\
#>

[CmdletBinding()]
param(
    # The remote computer's hostname as it appears in Tactical RMM.
    # If omitted (e.g. launched from the AD-Toolkit menu), you'll be prompted.
    [Parameter(Position = 0)]
    [string]$ComputerName,

    # The local file to send.
    [string]$Path,

    # Where to put it on the remote machine. End with \ to keep the file name.
    [string]$Destination
)

# The shared library has to load first: the file picker below comes from it, and
# so do Invoke-TrmmRequest and the credential check further down.
# (The "show the API's real error" handling this script used to do on its own is
# now built into Invoke-TrmmRequest, so every feature gets it.)
. "$PSScriptRoot\..\..\lib\Common.ps1"

# --- Prompt for anything missing (menu mode) ---------------------------------
if (-not $ComputerName) { $ComputerName = Read-Host "Remote computer name (as shown in Tactical RMM)" }
if (-not $ComputerName) { Write-Host "No computer name - cancelled." -ForegroundColor Yellow; return }

if (-not $Path) {
    Write-Host "Opening the file picker (check behind this window if you don't see it)..." -ForegroundColor DarkGray
    $Path = Select-LocalFilePath -Title 'Choose the file to send' -Prompt '  Local file to send (full path)'
    if (-not $Path) { Write-Host "No file chosen - cancelled." -ForegroundColor Yellow; return }
    Write-Host "  File: $Path" -ForegroundColor Green
}

if (-not $Destination) {
    $Destination = Read-Host "Destination folder on the remote machine (ENTER for C:\Temp\)"
    if (-not $Destination) { $Destination = 'C:\Temp\' }
}

# --- Tactical RMM plumbing -------------------------------------------------
if (-not (Test-TrmmConfigured)) { return }

$ComputerName = $ComputerName.Trim()

# --- Check the local file ----------------------------------------------------
if (-not (Test-Path -Path $Path)) {
    Write-Host "ERROR: local file not found: $Path" -ForegroundColor Red
    return
}
$file      = Get-Item -Path $Path
$sizeMB    = [math]::Round($file.Length / 1MB, 1)
$directMax = 10          # one-shot base64 ceiling

if ($Destination.EndsWith('\') -or $Destination.EndsWith('/')) {
    $Destination = $Destination.TrimEnd('\', '/') + '\' + $file.Name
}

# The destination path is pasted into single-quoted strings in the remote
# commands below. A path like C:\Users\o'brien\Desktop\ would close the quote
# early, so escape the apostrophe once here and use $safeDest in remote commands.
$safeDest = ConvertTo-RemoteLiteral $Destination

$localHash = (Get-FileHash -Path $file.FullName -Algorithm SHA256).Hash
Write-Host ("File: {0}  ({1} MB)  ->  {2} on {3}" -f $file.Name, $sizeMB, $Destination, $ComputerName) -ForegroundColor Cyan

# --- Find the agent ----------------------------------------------------------
$agents = @(Invoke-TrmmRequest GET 'agents/')
$agent  = @($agents | Where-Object { $_.hostname -eq $ComputerName })
if ($agent.Count -ne 1) {
    Write-Host "ERROR: found $($agent.Count) agent(s) named '$ComputerName' (need exactly 1)." -ForegroundColor Red
    if ($agent.Count -eq 0) {
        @($agents | Where-Object { $_.hostname -match [regex]::Escape($ComputerName) }) |
            ForEach-Object { Write-Host "  Did you mean: $($_.hostname)" -ForegroundColor Yellow }
    }
    return
}
$agent = $agent[0]
if ($agent.status -ne 'online') {
    Write-Host "'$ComputerName' is $($agent.status) - it must be online." -ForegroundColor Red
    return
}

# --- Logging -----------------------------------------------------------------
# One row per transfer in output\AD-Toolkit-Actions.csv (the toolkit's shared audit log).
# Audit rows go through Write-ActionLog in the shared library, so every feature
# writes the same columns to the same file. This wrapper just saves repeating
# the Action name and target machine on all nine call sites below.
function Write-SendFileLog ($Result, $Details) {
    Write-ActionLog -Action 'Send File (TRMM)' -Target $ComputerName -Result $Result -Details $Details
}

# Run a PowerShell command on the agent and return its output.
function Invoke-AgentCmd ($command, [int]$TimeoutSec = 300) {
    "$(Invoke-TrmmAgentCommand -AgentId $agent.agent_id -Command $command -TimeoutSec $TimeoutSec)"
}

# Ask the machine for the file's hash so we can prove the copy is intact.
function Test-RemoteHash {
    $out = Invoke-AgentCmd "if (Test-Path '$safeDest') { (Get-FileHash -Path '$safeDest' -Algorithm SHA256).Hash } else { 'MISSING' }" 120
    $h = if ("$out" -match '([0-9A-Fa-f]{64})') { $Matches[1] } else { $null }
    if ($h -eq $localHash) {
        Write-Host "Delivered and verified (SHA256 match): $Destination" -ForegroundColor Green
        Write-SendFileLog 'Success' "$($file.FullName) -> $Destination ($sizeMB MB, SHA256 verified)"
        return $true
    }
    Write-Host "Could NOT verify the file on the far end (hash mismatch or file missing)." -ForegroundColor Red
    Write-SendFileLog 'Failed' "$($file.FullName) -> $Destination ($sizeMB MB, hash mismatch)"
    return $false
}

# =====================================================================
# METHOD 1 - DIRECT (one-shot base64 through a temp TRMM script)
# Best for SMALL files (<= 10 MB). Fast, works anywhere the agent works.
# =====================================================================
function Send-Direct {
    $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($file.FullName))
    $remoteScript = @"
`$dest = '$safeDest'
`$dir  = Split-Path -Path `$dest -Parent
if (-not (Test-Path -Path `$dir)) { New-Item -ItemType Directory -Path `$dir -Force | Out-Null }
[System.IO.File]::WriteAllBytes(`$dest, [Convert]::FromBase64String('$b64'))
'HASH=' + (Get-FileHash -Path `$dest -Algorithm SHA256).Hash
"@
    $tempName = "TEMP - file upload $([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $created  = Invoke-TrmmRequest POST 'scripts/' @{
        name            = $tempName
        shell           = 'powershell'
        script_type     = 'userdefined'
        script_body     = $remoteScript
        category        = 'Desk Side Toolkit'
        description     = 'Temporary file-transfer script - safe to delete.'
        default_timeout = 300
        args            = @()
    }
    $scriptId = $created.id
    if (-not $scriptId) { $scriptId = (@(Invoke-TrmmRequest GET 'scripts/') | Where-Object { $_.name -eq $tempName } | Select-Object -First 1).id }

    try {
        Write-Host "DIRECT transfer ($sizeMB MB)..." -ForegroundColor Cyan
        $output = Invoke-TrmmRequest POST "agents/$($agent.agent_id)/runscript/" @{
            script          = $scriptId
            output          = 'wait'
            args            = @()
            timeout         = 300
            run_as_user     = $false
            env_vars        = @()
            custom_field    = $null
            save_all_output = $true
            email           = @()
            emailMode       = 'default'
        }
        $remoteHash = if ("$output" -match 'HASH=([0-9A-Fa-f]{64})') { $Matches[1] } else { $null }
        if ($remoteHash -eq $localHash) {
            Write-Host "Delivered and verified (SHA256 match): $Destination" -ForegroundColor Green
            Write-SendFileLog 'Success' "$($file.FullName) -> $Destination ($sizeMB MB, direct, SHA256 verified)"
        }
        else {
            Write-Host "Upload may have FAILED - could not verify the hash. Remote output:" -ForegroundColor Red
            $output
            Write-SendFileLog 'Failed' "$($file.FullName) -> $Destination (direct, hash mismatch)"
        }
    }
    catch { Write-SendFileLog 'Failed' "$($file.FullName) -> $Destination (direct, error: $($_.Exception.Message))"; throw }
    finally { if ($scriptId) { Invoke-TrmmRequest DELETE "scripts/$scriptId/" | Out-Null } }
}

# =====================================================================
# METHOD 2 - CHUNKED (base64 in pieces through the agent)
# For LARGE files. Works anywhere the agent works, no network line of
# sight needed - but slow: roughly 1 MB per 2-4 seconds.
# =====================================================================
function Send-Chunked {
    param([int]$ChunkKB = 512)

    $b64      = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($file.FullName))
    $chunkLen = $ChunkKB * 1024
    $total    = [math]::Ceiling($b64.Length / $chunkLen)
    $stage    = "C:\Windows\Temp\trmmsend_$([guid]::NewGuid().ToString('N').Substring(0,8)).b64"

    Write-Host "CHUNKED transfer: $sizeMB MB in $total piece(s) of $ChunkKB KB. This takes a while." -ForegroundColor Cyan
    Write-Host "Ctrl+C aborts; the part-file on the machine is cleaned up on the next run." -ForegroundColor DarkGray

    try {
        for ($i = 0; $i -lt $total; $i++) {
            $part = $b64.Substring($i * $chunkLen, [math]::Min($chunkLen, $b64.Length - ($i * $chunkLen)))
            # First chunk creates the staging file, the rest append to it.
            $op = if ($i -eq 0) { "Set-Content -Path '$stage' -Value '$part' -NoNewline -Encoding Ascii" }
                  else          { "Add-Content -Path '$stage' -Value '$part' -NoNewline -Encoding Ascii" }
            Write-Progress -Activity "Sending $($file.Name)" -Status "chunk $($i+1) of $total" -PercentComplete (100 * ($i + 1) / $total)
            $r = Invoke-AgentCmd $op 300
            if ("$r" -match '(?i)error|exception') { throw "chunk $($i+1) failed: $r" }
        }
        Write-Progress -Activity "Sending $($file.Name)" -Completed

        Write-Host "All chunks sent - reassembling on the machine..." -ForegroundColor DarkGray
        $assemble = @"
`$dest = '$safeDest'
`$dir  = Split-Path -Path `$dest -Parent
if (-not (Test-Path -Path `$dir)) { New-Item -ItemType Directory -Path `$dir -Force | Out-Null }
[System.IO.File]::WriteAllBytes(`$dest, [Convert]::FromBase64String((Get-Content -Path '$stage' -Raw)))
Remove-Item -Path '$stage' -Force -ErrorAction SilentlyContinue
'DONE'
"@
        Invoke-AgentCmd $assemble 300 | Out-Null
        [void](Test-RemoteHash)
    }
    catch {
        Write-Progress -Activity "Sending $($file.Name)" -Completed
        Write-Host "Chunked transfer failed: $($_.Exception.Message)" -ForegroundColor Red
        Invoke-AgentCmd "Remove-Item -Path '$stage' -Force -ErrorAction SilentlyContinue" 60 | Out-Null
        Write-SendFileLog 'Failed' "$($file.FullName) -> $Destination (chunked, $($_.Exception.Message))"
    }
}

# =====================================================================
# METHOD 3 - ADMIN SHARE (\\host\C$)  - fastest, but only when your PC
# can reach the machine directly on the network and you have admin rights.
# =====================================================================
function Send-AdminShare {
    $unc = '\\' + $agent.hostname + '\' + ($Destination -replace '^([A-Za-z]):', '$1$')
    Write-Host "ADMIN SHARE transfer to $unc ..." -ForegroundColor Cyan
    $dir = Split-Path -Path $unc -Parent
    if (-not (Test-Path -Path $dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
        catch {
            Write-Host "Cannot reach $dir - the machine is not reachable over the network (VPN/remote site?) or you lack admin rights." -ForegroundColor Red
            Write-Host "Use CHUNKED or MESHCENTRAL instead." -ForegroundColor Yellow
            return
        }
    }
    try {
        Copy-Item -Path $file.FullName -Destination $unc -Force -ErrorAction Stop
        [void](Test-RemoteHash)
    }
    catch {
        Write-Host "Copy failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-SendFileLog 'Failed' "$($file.FullName) -> $Destination (admin share, $($_.Exception.Message))"
    }
}

# =====================================================================
# METHOD 4 - MESHCENTRAL (manual drag-and-drop, any size)
# We open the right file-manager page for THIS agent so you don't hunt for it.
# =====================================================================
function Open-MeshFileManager {
    try { $mesh = Invoke-TrmmRequest GET "agents/$($agent.agent_id)/meshcentral/" }
    catch { Write-Host "Could not get the MeshCentral link: $($_.Exception.Message)" -ForegroundColor Red; return }
    if (-not $mesh.file) { Write-Host "No MeshCentral file URL returned for this agent." -ForegroundColor Yellow; return }
    Write-Host "Opening MeshCentral file manager for $($agent.hostname)..." -ForegroundColor Green
    Write-Host "Drag $($file.FullName) into the folder you want, then close the tab." -ForegroundColor Yellow
    Start-Process $mesh.file
    Write-SendFileLog 'Manual' "$($file.FullName) -> $Destination ($sizeMB MB, opened MeshCentral file manager)"
}

# --- Pick the method ----------------------------------------------------------
if ($file.Length -le $directMax * 1MB) {
    Send-Direct
}
else {
    Write-Host ""
    Write-Host "$sizeMB MB is over the $directMax MB direct limit. Choose how to send it:" -ForegroundColor Yellow
    Write-Host "  [C] CHUNKED      - through the TRMM agent in pieces. Works anywhere, no" -ForegroundColor White
    Write-Host "                     network access needed. Slow (~1 MB per 2-4 sec)." -ForegroundColor DarkGray
    Write-Host "  [S] ADMIN SHARE  - copy over \\$($agent.hostname)\C`$. Fastest by far, but only" -ForegroundColor White
    Write-Host "                     if you can reach the machine on the network as admin." -ForegroundColor DarkGray
    Write-Host "  [M] MESHCENTRAL  - opens the file manager for this machine in your browser;" -ForegroundColor White
    Write-Host "                     you drag the file in. Any size, but manual." -ForegroundColor DarkGray
    Write-Host "  [B] Back" -ForegroundColor White
    switch ((Read-Host "Choose").Trim().ToUpper()) {
        'C' { Send-Chunked }
        'S' { Send-AdminShare }
        'M' { Open-MeshFileManager }
        default { Write-Host "Cancelled." -ForegroundColor Yellow }
    }
}
