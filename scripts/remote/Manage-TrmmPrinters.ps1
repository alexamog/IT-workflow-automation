<#
.SYNOPSIS
    Add, remove and copy printers on remote computers through Tactical RMM.

.DESCRIPTION
    Shows what printers a machine currently has, then lets you remove the ones
    that should not be there, add a new one pointing at a printer's IP address,
    or COPY one of its printers onto a different computer (carrying the name,
    driver and IP). Everything is done over Tactical RMM, so the machines only
    have to be online - nobody needs to be sitting at them.

    COPYING needs the printer's driver ALREADY on the target machine (Windows
    can't fetch a driver on its own). Printers whose driver is missing on the
    target are reported and skipped - install the driver there first, then copy.

    ADDING A PRINTER NEEDS A DRIVER THAT IS ALREADY ON THE MACHINE.
    Windows will not install a driver out of thin air. This script lists the
    drivers the machine already has and you pick one. If the right driver is not
    there, install it first (send the vendor package with 'Send a file' and run
    it, or add the printer once by hand) and then come back.

    WHAT GETS CREATED
    Adding a printer creates a standard TCP/IP port named IP_<address> if one
    does not exist yet, then attaches the printer to it. Both are machine-wide,
    because Tactical RMM runs as the SYSTEM account - so every user who logs
    into that computer sees the printer.

    ONE THING THIS CANNOT DO: set somebody's DEFAULT printer. The default is a
    per-user setting and SYSTEM cannot reach into a logged-in user's profile to
    change it. The user picks their own default, or you do it over a remote
    control session.

.PARAMETER ComputerName
    The remote computer's hostname as it appears in Tactical RMM.
    If omitted (e.g. launched from the AD-Toolkit menu), you'll be prompted.

.EXAMPLE
    .\Manage-TrmmPrinters.ps1 ITDESSPARE-04

.EXAMPLE
    .\Manage-TrmmPrinters.ps1
    Asks for the computer name, then shows the menu.
#>

[CmdletBinding()]
param(
    # The remote computer's hostname as it appears in Tactical RMM.
    [Parameter(Position = 0)]
    [string]$ComputerName
)

# --- Tactical RMM plumbing -------------------------------------------------
. "$PSScriptRoot\..\..\lib\Common.ps1"

if (-not (Test-TrmmConfigured)) { return }

# Printer work can be slow: the spooler has to talk to the driver store.
$TimeoutSec = 120

# --- Find the agent ----------------------------------------------------------
if (-not $ComputerName) { $ComputerName = Read-Host "Remote computer name (as shown in Tactical RMM)" }
if (-not $ComputerName) { Write-Host "No computer name - cancelled." -ForegroundColor Yellow; return }
$ComputerName = $ComputerName.Trim()

Write-Host "Looking up '$ComputerName' in Tactical RMM..."
try { $agents = @(Invoke-TrmmRequest GET 'agents/') }
catch { Write-Host "TRMM lookup failed: $($_.Exception.Message)" -ForegroundColor Red; return }

$agent = @($agents | Where-Object { $_.hostname -eq $ComputerName })
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
    Write-Host "$($agent.hostname) is $($agent.status). It must be online to change printers." -ForegroundColor Yellow
    return
}

# --- Read what the machine has today ----------------------------------------
# One trip fetches printers, their ports, and the installed drivers. The output
# is split into labelled sections so it can be parsed back into objects here.
# "~|~" separates fields because a printer name can easily contain a space, a
# dash, or a comma, but never that.
$inventoryCmd = @'
$ErrorActionPreference = 'SilentlyContinue'
'###PRINTERS###'
foreach ($p in Get-Printer) {
    $port = Get-PrinterPort -Name $p.PortName -ErrorAction SilentlyContinue
    '{0}~|~{1}~|~{2}~|~{3}' -f $p.Name, $p.DriverName, $p.PortName, $port.PrinterHostAddress
}
'###DRIVERS###'
foreach ($d in Get-PrinterDriver) { $d.Name }
'###END###'
'@

function Get-RemotePrinterState ($Agent = $agent) {
    Write-Host "Reading printers from $($Agent.hostname)..." -ForegroundColor DarkGray
    try { $raw = "$(Invoke-TrmmAgentCommand -AgentId $Agent.agent_id -Command $inventoryCmd -TimeoutSec $TimeoutSec)" }
    catch { Write-Host "Could not read printers: $($_.Exception.Message)" -ForegroundColor Red; return $null }

    if ($raw -notmatch '###END###') {
        Write-Host "The machine did not answer properly. Raw reply:" -ForegroundColor Red
        Write-Host $raw
        return $null
    }

    $section  = ''
    $printers = New-Object System.Collections.Generic.List[object]
    $drivers  = New-Object System.Collections.Generic.List[string]

    foreach ($line in ($raw -split "`r?`n")) {
        $t = $line.Trim()
        if (-not $t) { continue }
        switch ($t) {
            '###PRINTERS###' { $section = 'P'; continue }
            '###DRIVERS###'  { $section = 'D'; continue }
            '###END###'      { $section = '';  continue }
        }
        if ($section -eq 'P') {
            $f = $t -split '~\|~'
            if ($f.Count -ge 3) {
                $printers.Add([pscustomobject]@{
                    Name   = $f[0]
                    Driver = $f[1]
                    Port   = $f[2]
                    Ip     = if ($f.Count -ge 4) { $f[3] } else { '' }
                })
            }
        }
        elseif ($section -eq 'D' -and $t -notmatch '^###') { $drivers.Add($t) }
    }

    # .ToArray() rather than @( ): on PowerShell 5.1, wrapping a generic List in
    # @( ) inside a [pscustomobject] literal throws "Argument types do not match".
    [pscustomobject]@{ Printers = $printers.ToArray(); Drivers = $drivers.ToArray() }
}

function Show-Printers ($printers) {
    if ($printers.Count -eq 0) {
        Write-Host "`n  (this machine has no printers installed)" -ForegroundColor Yellow
        return
    }
    Write-Host "`n  Printers on $($agent.hostname):" -ForegroundColor Cyan
    for ($i = 0; $i -lt $printers.Count; $i++) {
        $p = $printers[$i]
        Write-Host ("   {0,2}. {1}" -f ($i + 1), $p.Name)
        Write-Host ("       driver: {0}" -f $p.Driver) -ForegroundColor DarkGray
        Write-Host ("       port  : {0}{1}" -f $p.Port, $(if ($p.Ip) { "   ->  $($p.Ip)" } else { '' })) -ForegroundColor DarkGray
    }
}

# Create the printer on one agent: make the IP_<address> port if needed, then
# attach the printer to it. Returns @{ Ok; Note }. The driver must already be on
# that machine. Used by both the interactive add and the copy-to-another-machine.
function Add-PrinterOnAgent ($Agent, $Name, $Driver, $Ip) {
    $portName   = "IP_$Ip"
    $safeName   = ConvertTo-RemoteLiteral $Name
    $safeDriver = ConvertTo-RemoteLiteral $Driver
    $safePort   = ConvertTo-RemoteLiteral $portName
    $safeIp     = ConvertTo-RemoteLiteral $Ip

    # Double-quoted here-string: the values above are filled in here, while the
    # remote script's own variables are escaped with a backtick so they survive.
    $cmd = @"
`$ErrorActionPreference = 'Stop'
try {
    if (Get-PrinterPort -Name '$safePort' -ErrorAction SilentlyContinue) { 'PORT-EXISTS' }
    else { Add-PrinterPort -Name '$safePort' -PrinterHostAddress '$safeIp'; 'PORT-CREATED' }
    Add-Printer -Name '$safeName' -DriverName '$safeDriver' -PortName '$safePort'
    'PRINTER-ADDED'
}
catch { 'ERROR: ' + `$_.Exception.Message }
"@
    try { $out = "$(Invoke-TrmmAgentCommand -AgentId $Agent.agent_id -Command $cmd -TimeoutSec $TimeoutSec)".Trim() }
    catch { return [pscustomobject]@{ Ok = $false; Note = "could not reach the machine: $($_.Exception.Message)"; Port = $portName } }

    if ($out -match 'PRINTER-ADDED') {
        $note = if ($out -match 'PORT-EXISTS') { 'existing port reused' } else { 'port created' }
        return [pscustomobject]@{ Ok = $true; Note = $note; Port = $portName }
    }
    [pscustomobject]@{ Ok = $false; Note = $out; Port = $portName }
}

# --- Add a printer by IP address --------------------------------------------
function Add-RemotePrinter ($state) {
    Write-Host ""
    $ip = (Read-Host "  Printer IP address (ENTER to cancel)").Trim()
    if (-not $ip) { return $false }

    # An IP is what this is for, but a DNS name works too - just make sure the
    # operator meant it rather than mistyping an address.
    $parsed = [ref]$null
    if (-not [System.Net.IPAddress]::TryParse($ip, $parsed)) {
        Write-Host "  '$ip' is not an IP address. It will be used as a host name instead." -ForegroundColor Yellow
        if ((Read-Host "  Continue? (y/n)").Trim().ToUpper() -ne 'Y') { return $false }
    }

    $name = (Read-Host "  Name for the printer (what users will see)").Trim()
    if (-not $name) { Write-Host "  No name - cancelled." -ForegroundColor Yellow; return $false }

    if ($state.Printers | Where-Object { $_.Name -eq $name }) {
        Write-Host "  A printer called '$name' is already on this machine." -ForegroundColor Yellow
        return $false
    }

    # Pick the driver from what the machine already has.
    $drivers = @($state.Drivers)
    if ($drivers.Count -eq 0) {
        Write-Host "  This machine has no printer drivers installed at all - install one first." -ForegroundColor Red
        return $false
    }

    # Real machines carry a lot of drivers, so allow narrowing the list first.
    $filter = (Read-Host "  Filter the driver list (e.g. HP, Brother) or ENTER for all").Trim()
    $shown  = if ($filter) { @($drivers | Where-Object { $_ -match [regex]::Escape($filter) }) } else { $drivers }
    if ($shown.Count -eq 0) {
        Write-Host "  No driver on this machine matches '$filter'." -ForegroundColor Yellow
        return $false
    }

    $driver = Select-FromList -Items $shown -Label { param($d) $d } -Prompt '  Driver number'
    if (-not $driver) { return $false }

    $portName = "IP_$ip"

    Write-Host ""
    Write-Host "  About to add on $($agent.hostname):" -ForegroundColor Cyan
    Write-Host ("    printer : {0}" -f $name)
    Write-Host ("    driver  : {0}" -f $driver)
    Write-Host ("    port    : {0}  ->  {1}" -f $portName, $ip)
    if ((Read-Host "  Go ahead? (y/n)").Trim().ToUpper() -ne 'Y') { Write-Host "  Cancelled." -ForegroundColor DarkGray; return $false }

    Write-Host "  Adding..." -ForegroundColor DarkGray
    $r = Add-PrinterOnAgent -Agent $agent -Name $name -Driver $driver -Ip $ip
    if ($r.Ok) {
        Write-Host "  Added '$name' ($($r.Note))." -ForegroundColor Green
        Write-ActionLog -Action 'Printer: Add' -Target $agent.hostname `
            -Details "$name -> $ip via $($r.Port), driver '$driver' ($($r.Note))"
        return $true
    }
    Write-Host "  Did not add: $($r.Note)" -ForegroundColor Red
    Write-ActionLog -Action 'Printer: Add' -Target $agent.hostname -Result 'Failed' -Details "$name ($ip) - $($r.Note)"
    return $false
}

# --- Remove printers ---------------------------------------------------------
function Remove-RemotePrinter ($state) {
    $printers = @($state.Printers)
    if ($printers.Count -eq 0) { Write-Host "  Nothing to remove." -ForegroundColor Yellow; return $false }

    Show-Printers $printers
    Write-Host ""
    $sel = (Read-Host "  Numbers to REMOVE, separated by commas (ENTER to cancel)").Trim()
    if (-not $sel) { return $false }

    # Parse the numbers, ignoring anything that is not a printer on the list.
    $chosen = New-Object System.Collections.Generic.List[object]
    foreach ($part in ($sel -split ',')) {
        $n = 0
        if ([int]::TryParse($part.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $printers.Count) {
            if (-not $chosen.Contains($printers[$n - 1])) { $chosen.Add($printers[$n - 1]) }
        }
        else { Write-Host "  Ignoring '$($part.Trim())' - not a number on the list." -ForegroundColor DarkYellow }
    }
    if ($chosen.Count -eq 0) { Write-Host "  Nothing selected." -ForegroundColor Yellow; return $false }

    Write-Host ""
    Write-Host "  These printers will be REMOVED from $($agent.hostname):" -ForegroundColor Yellow
    $chosen | ForEach-Object { Write-Host ("    - {0}   (port {1})" -f $_.Name, $_.Port) }
    Write-Host "  Anyone printing to them will need them added back." -ForegroundColor Yellow
    if (-not (Confirm-DeskSideWord 'remove' -CancelNote 'nothing removed' -Indent '  ')) { return $false }

    $alsoPort = (Read-Host "  Also remove each printer's port? (y/n)").Trim().ToUpper() -eq 'Y'

    $any = $false
    foreach ($p in $chosen) {
        $safeName = ConvertTo-RemoteLiteral $p.Name
        $safePort = ConvertTo-RemoteLiteral $p.Port

        # Only ever remove a port we could have created - one pointing at an
        # address. LPT1:, COM1:, FILE: and friends are built into Windows; they
        # are not ours to delete and trying only produces a confusing error.
        $removeThisPort = $alsoPort -and $p.Ip

        # The port is removed only after the printer, and only if nothing else
        # is still using it - otherwise the other printer breaks.
        $portBlock = if ($removeThisPort) { @"

    `$others = @(Get-Printer | Where-Object { `$_.PortName -eq '$safePort' })
    if (`$others.Count -eq 0) { Remove-PrinterPort -Name '$safePort' -ErrorAction Stop; 'PORT-REMOVED' }
    else { 'PORT-IN-USE' }
"@ } else { '' }

        $cmd = @"
`$ErrorActionPreference = 'Stop'
try {
    Remove-Printer -Name '$safeName'
    'PRINTER-REMOVED'$portBlock
}
catch { 'ERROR: ' + `$_.Exception.Message }
"@

        Write-Host "  Removing '$($p.Name)'..." -ForegroundColor DarkGray
        try { $out = "$(Invoke-TrmmAgentCommand -AgentId $agent.agent_id -Command $cmd -TimeoutSec $TimeoutSec)".Trim() }
        catch {
            Write-Host "    Failed to reach the machine: $($_.Exception.Message)" -ForegroundColor Red
            Write-ActionLog -Action 'Printer: Remove' -Target $agent.hostname -Result 'Failed' `
                -Details "$($p.Name) - $($_.Exception.Message)"
            continue
        }

        if ($out -match 'PRINTER-REMOVED') {
            $portNote = switch -Regex ($out) {
                'PORT-REMOVED' { 'port removed too'; break }
                'PORT-IN-USE'  { 'port kept - another printer still uses it'; break }
                default        {
                    if ($alsoPort -and -not $p.Ip) { "port '$($p.Port)' kept - built into Windows, not an IP port" }
                    else                           { 'port left in place' }
                }
            }
            Write-Host "    Removed ($portNote)." -ForegroundColor Green
            Write-ActionLog -Action 'Printer: Remove' -Target $agent.hostname `
                -Details "$($p.Name) on port $($p.Port) - $portNote"
            $any = $true
        }
        else {
            Write-Host "    Did not remove. The machine said:" -ForegroundColor Red
            Write-Host "      $out"
            Write-ActionLog -Action 'Printer: Remove' -Target $agent.hostname -Result 'Failed' `
                -Details "$($p.Name) - $out"
        }
    }
    return $any
}

# --- Copy printer(s) to another computer -------------------------------------
# Recreates one or more of THIS machine's network printers on a different
# machine, carrying the name, driver and IP. The driver must already be on the
# target (Windows can't fetch it) - printers whose driver is missing there are
# reported and skipped, not guessed at.
function Copy-RemotePrinter ($SourceAgent, $SourceState) {
    # Only network printers (ones with an IP) can be copied this way.
    $copyable = @($SourceState.Printers | Where-Object { $_.Ip })
    if ($copyable.Count -eq 0) {
        Write-Host "  No network (IP) printers on $($SourceAgent.hostname) to copy." -ForegroundColor Yellow
        return $false
    }

    Write-Host "`n  Printers on $($SourceAgent.hostname) that can be copied:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $copyable.Count; $i++) {
        Write-Host ("   {0,2}. {1}" -f ($i + 1), $copyable[$i].Name)
        Write-Host ("       driver: {0}" -f $copyable[$i].Driver) -ForegroundColor DarkGray
        Write-Host ("       IP    : {0}" -f $copyable[$i].Ip) -ForegroundColor DarkGray
    }
    Write-Host ""
    $sel = (Read-Host "  Numbers to COPY, separated by commas (ENTER to cancel)").Trim()
    if (-not $sel) { return $false }

    $chosen = New-Object System.Collections.Generic.List[object]
    foreach ($part in ($sel -split ',')) {
        $n = 0
        if ([int]::TryParse($part.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $copyable.Count) {
            if (-not $chosen.Contains($copyable[$n - 1])) { $chosen.Add($copyable[$n - 1]) }
        }
        else { Write-Host "  Ignoring '$($part.Trim())' - not a number on the list." -ForegroundColor DarkYellow }
    }
    if ($chosen.Count -eq 0) { Write-Host "  Nothing selected." -ForegroundColor Yellow; return $false }

    # Target machine.
    $targetName = (Read-Host "`n  Copy to which computer? (hostname in Tactical RMM)").Trim()
    if (-not $targetName) { Write-Host "  Cancelled." -ForegroundColor Yellow; return $false }
    if ($targetName -eq $SourceAgent.hostname) { Write-Host "  That's the same machine." -ForegroundColor Yellow; return $false }

    $target = @($agents | Where-Object { $_.hostname -eq $targetName })
    if ($target.Count -ne 1) {
        Write-Host "  Found $($target.Count) agent(s) named '$targetName' (need exactly 1)." -ForegroundColor Red
        if ($target.Count -eq 0) {
            @($agents | Where-Object { $_.hostname -match [regex]::Escape($targetName) }) |
                ForEach-Object { Write-Host "    Did you mean: $($_.hostname)" -ForegroundColor Yellow }
        }
        return $false
    }
    $target = $target[0]
    if ($target.status -ne 'online') { Write-Host "  $($target.hostname) is $($target.status) - it must be online." -ForegroundColor Yellow; return $false }

    # Read the target so we can check its drivers and skip duplicates.
    $targetState = Get-RemotePrinterState -Agent $target
    if (-not $targetState) { return $false }

    Write-Host ""
    Write-Host "  Copying to $($target.hostname):" -ForegroundColor Cyan
    $chosen | ForEach-Object { Write-Host ("    - {0}   driver '{1}'   -> {2}" -f $_.Name, $_.Driver, $_.Ip) }
    if ((Read-Host "  Go ahead? (y/n)").Trim().ToUpper() -ne 'Y') { Write-Host "  Cancelled." -ForegroundColor DarkGray; return $false }

    $any = $false
    foreach ($p in $chosen) {
        Write-Host "`n  $($p.Name)..." -ForegroundColor DarkGray
        if ($targetState.Printers | Where-Object { $_.Name -eq $p.Name }) {
            Write-Host "    Already on $($target.hostname) - skipped." -ForegroundColor DarkGray
            continue
        }
        if ($targetState.Drivers -notcontains $p.Driver) {
            Write-Host "    Driver '$($p.Driver)' is NOT installed on $($target.hostname)." -ForegroundColor Yellow
            Write-Host "    Install it there first (send the vendor package and run it), then copy again." -ForegroundColor DarkGray
            Write-ActionLog -Action 'Printer: Copy' -Target $target.hostname -Result 'Failed' `
                -Details "$($p.Name) from $($SourceAgent.hostname) - driver '$($p.Driver)' not on target"
            continue
        }

        $r = Add-PrinterOnAgent -Agent $target -Name $p.Name -Driver $p.Driver -Ip $p.Ip
        if ($r.Ok) {
            Write-Host "    Copied ($($r.Note))." -ForegroundColor Green
            Write-ActionLog -Action 'Printer: Copy' -Target $target.hostname `
                -Details "$($p.Name) from $($SourceAgent.hostname) -> $($p.Ip), driver '$($p.Driver)' ($($r.Note))"
            $any = $true
        }
        else {
            Write-Host "    Did not copy: $($r.Note)" -ForegroundColor Red
            Write-ActionLog -Action 'Printer: Copy' -Target $target.hostname -Result 'Failed' `
                -Details "$($p.Name) from $($SourceAgent.hostname) - $($r.Note)"
        }
    }
    # The copy changed the TARGET, not this (source) machine, so report no change
    # here - the source list on screen is still accurate.
    return $false
}

# --- Menu --------------------------------------------------------------------
Write-ToolHeader "Printers on $($agent.hostname)"

$state = Get-RemotePrinterState
if (-not $state) { return }

while ($true) {
    Show-Printers $state.Printers

    Write-Host ""
    Write-Host "  1) Add a printer by IP address"
    Write-Host "  2) Remove printer(s)"
    Write-Host "  3) Copy printer(s) to another computer"
    Write-Host "  R) Re-read the machine     B) Back"

    $changed = $false
    switch ((Read-Host "Select").Trim().ToUpper()) {
        '1'     { $changed = Add-RemotePrinter    $state }
        '2'     { $changed = Remove-RemotePrinter $state }
        '3'     { $changed = Copy-RemotePrinter   $agent $state }
        'R'     { $changed = $true }
        'B'     { return }
        default { Write-Host "Unknown option." -ForegroundColor DarkGray }
    }

    # After anything that changed the machine, read it back so the list on
    # screen is what is really there rather than what we think we did.
    if ($changed) {
        $fresh = Get-RemotePrinterState
        if ($fresh) { $state = $fresh }
    }
}
