<#
.SYNOPSIS
    Check toner/status and manage the job queue on a network printer -
    directly over the network, no web browser needed.

.DESCRIPTION
    Talks straight to the printer's IP address using two standard protocols
    every network printer (Canon imageCLASS included) supports:
      - SNMP (UDP 161) for toner/drum levels, device status, and the
        operator-panel message.
      - IPP  (TCP 631) for the live job queue, job history (completed /
        canceled / aborted jobs - however much of it the printer keeps),
        and cancelling a job.

    RESTART uses the standard Printer-MIB "reset" object over SNMP, which
    needs SNMP write access enabled on the printer. Most printers ship with
    that switched off for security. If the printer refuses it, this tool
    says so plainly and tells you to flip that setting on (or restart it
    from the Remote UI by hand) - it will NOT try to fake a restart by
    guessing at the web interface's buttons.

    NOTHING HERE CHANGES PRINTER CONFIGURATION. Only readable status/queue
    (SNMP GET, IPP Get-Jobs), cancelling a job (IPP Cancel-Job), and the
    restart trigger described above. Any other change stays a manual job in
    the printer's own Remote UI, on purpose - the menu's last option opens
    that Remote UI in the default browser (plain HTTP port 80 unless
    PRINTER_WEB_PORT/PRINTER_WEB_HTTPS say otherwise) for exactly that.

.PARAMETER PrinterAddress
    The printer's IP address or hostname. If omitted you'll be prompted.

.EXAMPLE
    .\Monitor-CanonPrinter.ps1 10.10.4.21

.EXAMPLE
    .\Monitor-CanonPrinter.ps1
    Asks for the printer's address, then shows the menu.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$PrinterAddress
)

. "$PSScriptRoot\..\..\lib\Common.ps1"

if (-not $PrinterAddress) { $PrinterAddress = Read-Host "Printer IP address or hostname" }
if (-not $PrinterAddress) { Write-Host "No address - cancelled." -ForegroundColor Yellow; return }
$PrinterAddress = $PrinterAddress.Trim()

# --- Status screen ------------------------------------------------------------
function Show-PrinterStatus {
    Write-Host "`n  Reading status from $PrinterAddress (SNMP)..." -ForegroundColor DarkGray
    $status = Get-CanonPrinterStatus -PrinterAddress $PrinterAddress
    if (-not $status) {
        Write-Host "  No SNMP reply from $PrinterAddress." -ForegroundColor Red
        Write-Host "  Either it's offline, the address is wrong, or SNMP is disabled on it." -ForegroundColor DarkGray
        return $null
    }

    Write-Host "`n  $($status.SysDescr)" -ForegroundColor Cyan
    $devColor = if ($status.DeviceStatus -eq 'Down') { 'Red' } elseif ($status.DeviceStatus -eq 'Warning') { 'Yellow' } else { 'Green' }
    $deviceLabel  = if ($status.DeviceStatus)  { $status.DeviceStatus }  else { 'unknown' }
    $printerLabel = if ($status.PrinterStatus) { $status.PrinterStatus } else { 'unknown' }
    Write-Host ("  Device status : {0}" -f $deviceLabel) -ForegroundColor $devColor
    Write-Host ("  Printer status: {0}" -f $printerLabel)
    if ($status.ConsoleMessage) {
        Write-Host ("  Panel message : {0}" -f $status.ConsoleMessage) -ForegroundColor Yellow
    }

    if ($status.Supplies.Count -eq 0) {
        Write-Host "`n  (this printer did not report any supply levels over SNMP)" -ForegroundColor DarkGray
    }
    else {
        Write-Host "`n  Supplies:" -ForegroundColor Cyan
        foreach ($s in $status.Supplies) {
            $line = if ($null -ne $s.Percent) { "{0,3}%" -f $s.Percent } elseif ($s.Note) { $s.Note } else { 'n/a' }
            $color = if ($null -ne $s.Percent -and $s.Percent -le 10) { 'Red' } elseif ($null -ne $s.Percent -and $s.Percent -le 25) { 'Yellow' } else { 'Gray' }
            Write-Host ("    {0,-28} {1}" -f $s.Name, $line) -ForegroundColor $color
        }
    }
    return $status
}

# --- Job queue ------------------------------------------------------------
function Show-PrinterJobs {
    Write-Host "`n  Reading job queue from $PrinterAddress (IPP)..." -ForegroundColor DarkGray
    try { $jobs = @(Get-CanonPrinterJobs -PrinterAddress $PrinterAddress -Which Active) }
    catch { Write-Host "  Could not read the job queue: $($_.Exception.Message)" -ForegroundColor Red; return @() }

    if ($jobs.Count -eq 0) { Write-Host "`n  (no jobs in the queue)" -ForegroundColor DarkGray; return @() }

    Write-Host "`n  Job queue:" -ForegroundColor Cyan
    foreach ($j in $jobs) {
        $color = switch ($j.State) { 'Stopped' { 'Red' } 'Held' { 'Yellow' } 'Processing' { 'Green' } default { 'Gray' } }
        Write-Host ("    #{0,-6} {1,-12} {2,-20} {3}" -f $j.JobId, $j.State, $j.User, $j.Name) -ForegroundColor $color
        if ($j.StateReasons -and $j.StateReasons -ne '') {
            Write-Host ("           reason: {0}" -f ($j.StateReasons -join ', ')) -ForegroundColor DarkGray
        }
    }
    return $jobs
}

# Job history - completed/canceled/aborted jobs. How far back this reaches is
# entirely up to the printer (some keep dozens, some keep almost nothing); this
# just asks for whatever it still has, newest information included when the
# device reports it (CompletedAt is $null if the printer didn't say).
function Show-PrinterJobHistory {
    Write-Host "`n  Reading job history from $PrinterAddress (IPP)..." -ForegroundColor DarkGray
    try { $jobs = @(Get-CanonPrinterJobs -PrinterAddress $PrinterAddress -Which Completed) }
    catch { Write-Host "  Could not read job history: $($_.Exception.Message)" -ForegroundColor Red; return @() }

    if ($jobs.Count -eq 0) {
        Write-Host "`n  (no job history reported - the printer may not keep one, or it's empty)" -ForegroundColor DarkGray
        return @()
    }

    # Newest first when the printer told us completion times; otherwise leave
    # the order the printer sent, which is usually already newest-first too.
    $ordered = if ($jobs | Where-Object { $_.CompletedAt }) { $jobs | Sort-Object CompletedAt -Descending } else { $jobs }

    Write-Host "`n  Job history:" -ForegroundColor Cyan
    foreach ($j in $ordered) {
        $color = switch ($j.State) { 'Completed' { 'Gray' } 'Canceled' { 'Yellow' } 'Aborted' { 'Red' } default { 'Gray' } }
        $when = if ($j.CompletedAt) { $j.CompletedAt.ToString('yyyy-MM-dd HH:mm') } else { 'time unknown' }
        Write-Host ("    #{0,-6} {1,-10} {2,-16} {3,-20} {4}" -f $j.JobId, $j.State, $when, $j.User, $j.Name) -ForegroundColor $color
    }
    return $ordered
}

function Invoke-CancelJob {
    $jobs = Show-PrinterJobs
    if ($jobs.Count -eq 0) { return }

    Write-Host ""
    $sel = (Read-Host "  Job number to CANCEL (ENTER to cancel this menu)").Trim()
    if (-not $sel) { return }
    $n = 0
    if (-not [int]::TryParse($sel, [ref]$n)) { Write-Host "  Not a job number." -ForegroundColor Yellow; return }
    $job = $jobs | Where-Object { $_.JobId -eq $n }
    if (-not $job) { Write-Host "  #$n is not in the queue." -ForegroundColor Yellow; return }

    Write-Host "`n  About to cancel job #$($job.JobId) ($($job.Name), owner $($job.User))." -ForegroundColor Yellow
    if ((Read-Host "  Go ahead? (y/n)").Trim().ToUpper() -ne 'Y') { Write-Host "  Cancelled - nothing done." -ForegroundColor DarkGray; return }

    try { $r = Stop-CanonPrinterJob -PrinterAddress $PrinterAddress -JobId $job.JobId }
    catch {
        Write-Host "  Could not reach the printer: $($_.Exception.Message)" -ForegroundColor Red
        Write-ActionLog -Action 'Printer: Cancel Job' -Target $PrinterAddress -Result 'Failed' -Details "#$($job.JobId) $($job.Name) - $($_.Exception.Message)"
        return
    }

    if ($r.Ok) {
        Write-Host "  Job #$($job.JobId) cancelled." -ForegroundColor Green
        Write-ActionLog -Action 'Printer: Cancel Job' -Target $PrinterAddress -Details "#$($job.JobId) $($job.Name) (owner $($job.User))"
    }
    else {
        Write-Host "  Printer did not cancel it: $($r.Status)" -ForegroundColor Red
        Write-ActionLog -Action 'Printer: Cancel Job' -Target $PrinterAddress -Result 'Failed' -Details "#$($job.JobId) $($job.Name) - $($r.Status)"
    }
}

# --- Restart ---------------------------------------------------------------
function Invoke-Restart {
    Write-Host ""
    Write-Host "  This restarts the printer. Anything mid-print will be interrupted," -ForegroundColor Yellow
    Write-Host "  and it will be unreachable for a minute or two while it comes back up." -ForegroundColor Yellow
    if (-not (Confirm-DeskSideWord "restart $PrinterAddress" -CancelNote 'nothing done' -Indent '  ')) { return }

    Write-Host "  Sending the restart command..." -ForegroundColor DarkGray
    $r = Restart-CanonPrinter -PrinterAddress $PrinterAddress
    if ($r.Ok) {
        Write-Host "  Restart command accepted - the printer is rebooting." -ForegroundColor Green
        Write-ActionLog -Action 'Printer: Restart' -Target $PrinterAddress -Details 'accepted via SNMP'
    }
    else {
        Write-Host "  Not restarted: $($r.Reason)" -ForegroundColor Red
        Write-ActionLog -Action 'Printer: Restart' -Target $PrinterAddress -Result 'Failed' -Details $r.Reason
    }
}

# --- Web interface -----------------------------------------------------------
# Config stays a manual job done here, by hand, on purpose - this just saves
# typing the address in by opening it in the default browser.
function Open-WebInterface {
    $url = Get-CanonPrinterWebUrl -PrinterAddress $PrinterAddress
    Write-Host "  Opening $url in the default browser..." -ForegroundColor DarkGray
    try { Start-Process $url }
    catch { Write-Host "  Could not open a browser: $($_.Exception.Message)" -ForegroundColor Red }
}

# --- Menu --------------------------------------------------------------------
Write-ToolHeader "Printer: $PrinterAddress"

while ($true) {
    Write-Host ""
    Write-Host "  1) Status & toner"
    Write-Host "  2) Job queue"
    Write-Host "  3) Job history (completed/canceled)"
    Write-Host "  4) Cancel a job"
    Write-Host "  5) Restart printer"
    Write-Host "  6) Open web interface (Remote UI)"
    Write-Host "  B) Back"

    switch ((Read-Host "`nSelect").Trim().ToUpper()) {
        '1'     { [void](Show-PrinterStatus) }
        '2'     { [void](Show-PrinterJobs) }
        '3'     { [void](Show-PrinterJobHistory) }
        '4'     { Invoke-CancelJob }
        '5'     { Invoke-Restart }
        '6'     { Open-WebInterface }
        'B'     { return }
        default { Write-Host "Unknown option." -ForegroundColor DarkGray }
    }
}
