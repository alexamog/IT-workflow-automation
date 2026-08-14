<#
.SYNOPSIS
    An interactive remote PowerShell prompt on any machine, through Tactical
    RMM - just give the computer name.

.DESCRIPTION
    Every line you type is executed on the remote machine (as SYSTEM) and the
    output is printed here. Type 'exit' to leave.

    How it works / limits:
      - Each command runs in a fresh PowerShell process on the machine, so
        variables do NOT carry over between commands. Your working directory
        IS carried over (the shell tracks it for you), so 'cd' works normally.
      - No interactive programs (nothing that asks questions or opens windows).
      - Default per-command timeout is 90 seconds (-TimeoutSec to change).

    Every command and its output is saved to output\RemoteShell-<pc>-<date>.log.

    Needs TRMM_APIKEY and TRMM_URL - run ..\..\setup\Set-TacticalCredentials.ps1 once.

.EXAMPLE
    .\Enter-TrmmShell.ps1 ITLAPSPARE-11

.EXAMPLE
    # Longer timeout for slow commands:
    .\Enter-TrmmShell.ps1 ITLAPSPARE-11 -TimeoutSec 300
#>

# NOT ON THE MAIN MENU, and that is deliberate - there is no .tool.psd1
# manifest beside this file, so the launcher never lists it. It is opened
# from Start-TrmmConsole.ps1, which collects the answers it needs first.
# It still runs on its own if you want to use it directly.

[CmdletBinding()]
param(
    # The remote computer's hostname as it appears in Tactical RMM.
    # If omitted (e.g. launched from the AD-Toolkit menu), you'll be prompted.
    [Parameter(Position = 0)]
    [string]$ComputerName,

    # Seconds each single command may run before TRMM gives up on it.
    [int]$TimeoutSec = 90
)

# --- Tactical RMM plumbing -------------------------------------------------
# Invoke-TrmmRequest and the credential check both live in the shared library.
. "$PSScriptRoot\..\..\lib\Common.ps1"

if (-not (Test-TrmmConfigured)) { return }

# --- Find the agent ----------------------------------------------------------
if (-not $ComputerName) { $ComputerName = Read-Host "Remote computer name (as shown in Tactical RMM)" }
if (-not $ComputerName) { Write-Host "No computer name - cancelled." -ForegroundColor Yellow; return }
$ComputerName = $ComputerName.Trim()

Write-Host "Looking up '$ComputerName' in Tactical RMM..."
$agent = Find-TrmmAgentByName -Hostname $ComputerName
if (-not $agent) { return }        # the reason was already printed
if ($agent.status -ne 'online') {
    Write-Host "'$ComputerName' is $($agent.status) - it must be online." -ForegroundColor Red
    return
}

# --- Session log -------------------------------------------------------------
$outputDir = Get-ADToolOutputDir -Category 'Logs\RemoteSessions'
$shellLog = Join-Path -Path $outputDir -ChildPath ("RemoteShell-{0}-{1}.log" -f $ComputerName, (Get-Date -Format 'yyyy-MM-dd HHmmss'))

# --- The shell loop ----------------------------------------------------------
Write-Host ""
Write-Host "Connected: $ComputerName  (client: $($agent.client_name), user logged in: $($agent.logged_username))" -ForegroundColor Green
Write-Host "Commands run as SYSTEM on the remote machine. Type 'exit' to leave." -ForegroundColor Yellow
Write-Host "Variables do not persist between commands; your working directory does." -ForegroundColor DarkGray
Write-Host "Session transcript: $shellLog" -ForegroundColor DarkGray
Write-Host ""

$marker    = '#__TRMMSHELL_PWD__#'
$remotePwd = $null
$cmdCount  = 0

while ($true) {
    $prompt  = if ($remotePwd) { "[$ComputerName] PS $remotePwd" } else { "[$ComputerName] PS" }
    $command = Read-Host $prompt
    if (-not "$command".Trim())               { continue }
    if ($command.Trim() -in @('exit','quit')) { break }

    # Re-enter the tracked working directory, run the command, then report the
    # (possibly changed) directory back on a marker line we strip from output.
    $wrapped = ''
    if ($remotePwd) { $wrapped += "Set-Location -LiteralPath '$($remotePwd.Replace("'","''"))' -ErrorAction SilentlyContinue; " }
    $wrapped += $command
    $wrapped += "; Write-Output ('$marker' + (Get-Location).Path)"

    try {
        $raw = "$(Invoke-TrmmAgentCommand -AgentId $agent.agent_id -Command $wrapped -TimeoutSec $TimeoutSec)"
    }
    catch {
        $msg = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        Write-Host "Command did not reach the machine: $msg" -ForegroundColor Red
        continue
    }
    $cmdCount++

    # Split output, harvest the pwd marker line, show the rest.
    $display = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($raw -split "`r?`n")) {
        if ($line.StartsWith($marker)) { $remotePwd = $line.Substring($marker.Length) }
        else                           { $display.Add($line) }
    }
    $text = ($display -join "`n").TrimEnd()
    if ($text) { Write-Host $text }

    # Transcript: the command and its output.
    "### $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  PS> $command`r`n$text`r`n" |
        Add-Content -Path $shellLog -Encoding UTF8
}

# One audit row for the whole session.
Write-ActionLog -Action 'Remote Shell (TRMM)' -Target $ComputerName `
    -Details "commands=$cmdCount log=$(Split-Path $shellLog -Leaf)"

Write-Host "`nDisconnected from $ComputerName ($cmdCount command(s) run). Transcript: $shellLog" -ForegroundColor Green
