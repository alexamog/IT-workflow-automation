<#
.SYNOPSIS
    Scan one or more subnets for IP printers/print servers and save the list
    to a text file in output\.

.DESCRIPTION
    There is no "ask the network who the printers are" broadcast that works
    across a routed network, so this does the only thing that reliably does:
    probes every address in range for the ports printers actually listen on
    (9100 = raw/JetDirect printing, 631 = IPP - ordinary workstations and
    servers don't listen there), then asks SNMP for a make/model string from
    whatever answered. A host with 9100 or 631 open is listed even if it never
    answers SNMP; SNMP is only there to add a label.

    MULTIPLE RANGES / "the whole company": a single site is usually one CIDR,
    but an organisation's printers are almost never on one contiguous block -
    they're spread across a VLAN per site. Pass every site's range at once
    (-Cidr 10.10.0.0/24,10.11.0.0/24,... or one per line in -CidrListFile) and
    this scans them all and merges the results into one list. There's no way
    for this script to discover site subnets it hasn't been told about - it
    can only probe ranges you (or your network team) give it, so building that
    range list the first time is a one-off "what subnets do we have" question
    for whoever owns the network documentation / DHCP scopes / firewall.

    This is a READ-ONLY network scan - a handful of TCP connection attempts and
    one SNMP query per responding host. It changes nothing on any device.

.PARAMETER Cidr
    One or more ranges to scan, e.g. 10.10.4.0/24 or 10.10.4.0/24,10.20.0.0/16.
    If omitted (and -CidrListFile isn't given either), this machine's own
    IPv4 subnet(s) are offered as a starting point.

.PARAMETER CidrListFile
    A text file with one CIDR range per line (# comments and blank lines are
    skipped) - the way to hand this a whole company's worth of site subnets in
    one go without typing them every time.

.PARAMETER OutFile
    Where to save the text list. Defaults to a timestamped file in output\.

.EXAMPLE
    .\Find-NetworkPrinters.ps1 10.10.4.0/24

.EXAMPLE
    .\Find-NetworkPrinters.ps1 -Cidr 10.10.4.0/24,10.11.4.0/24,10.12.4.0/24

.EXAMPLE
    .\Find-NetworkPrinters.ps1 -CidrListFile .\data\site-subnets.txt

.EXAMPLE
    .\Find-NetworkPrinters.ps1
    Offers this machine's own subnet(s) to scan, then asks.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string[]]$Cidr,

    [string]$CidrListFile,

    [string]$OutFile
)

. "$PSScriptRoot\..\..\lib\Common.ps1"

# --- Work out what to scan ----------------------------------------------------
$ranges = @()
if ($Cidr) {
    $ranges = @($Cidr)
}
elseif ($CidrListFile) {
    if (-not (Test-Path $CidrListFile)) { Write-Host "File not found: $CidrListFile" -ForegroundColor Red; return }
    $ranges = @(Get-Content -Path $CidrListFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^#' })
}
else {
    $local = @(Get-DeskSideLocalIPv4Cidr)
    if ($local.Count -eq 1) {
        Write-Host "This machine's subnet: $($local[0])" -ForegroundColor Cyan
        $typed = if ((Read-Host "Scan it? (Y/n, or type range(s) instead, comma-separated)").Trim() -match '^(n|N).*') {
            (Read-Host "Range(s) to scan, comma-separated (e.g. 10.10.4.0/24,10.20.0.0/16)").Trim()
        } else { $local[0] }
        $ranges = @($typed -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    elseif ($local.Count -gt 1) {
        Write-Host "This machine has more than one subnet:" -ForegroundColor Cyan
        $pick = Select-FromList -Items $local -Label { param($c) $c } -Prompt 'Which one (or 0 to type your own)'
        $typed = if ($pick) { $pick } else { (Read-Host "Range(s) to scan, comma-separated").Trim() }
        $ranges = @($typed -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    else {
        $typed = (Read-Host "Range(s) to scan, comma-separated (e.g. 10.10.4.0/24,10.20.0.0/16)").Trim()
        $ranges = @($typed -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
}
if ($ranges.Count -eq 0) { Write-Host "No range given - cancelled." -ForegroundColor Yellow; return }

# Expand every range and merge, deduplicating addresses that appear in more
# than one range (overlapping ranges are easy to hand in by mistake when
# pasting a list of site subnets).
$addrSeen = New-Object System.Collections.Generic.HashSet[string]
$addresses = New-Object System.Collections.Generic.List[string]
foreach ($r in $ranges) {
    try { $expanded = @(ConvertTo-DeskSideIpRange -Cidr $r) }
    catch { Write-Host "Skipping '$r': $($_.Exception.Message)" -ForegroundColor Red; continue }
    foreach ($a in $expanded) { if ($addrSeen.Add($a)) { $addresses.Add($a) } }
}
$addresses = @($addresses)
if ($addresses.Count -eq 0) { Write-Host "Nothing left to scan - every range was invalid." -ForegroundColor Red; return }

$rangeLabel = if ($ranges.Count -eq 1) { $ranges[0] } else { "$($ranges.Count) ranges" }
Write-ToolHeader "Scanning $rangeLabel ($($addresses.Count) address$(if ($addresses.Count -ne 1) { 'es' }))"
if ($ranges.Count -gt 1) { $ranges | ForEach-Object { Write-Host "  - $_" -ForegroundColor DarkGray } }

if ($addresses.Count -gt 4096) {
    Write-Host "  That's a lot of addresses - this could take a while (roughly 1-2 minutes per 1,000) and is a fair" -ForegroundColor Yellow
    Write-Host "  amount of network noise across however many sites those ranges cover." -ForegroundColor Yellow
    if (-not (Confirm-DeskSideAction 'Continue?' -Indent '  ')) { return }
}

# --- Scan ----------------------------------------------------------------
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$found = @(Find-NetworkPrinter -Addresses $addresses -OnProgress {
    param($done, $total)
    Write-Progress -Activity "Scanning $rangeLabel" -Status "$done / $total addresses" -PercentComplete ([Math]::Min(100, [int](100 * $done / $total)))
})
Write-Progress -Activity "Scanning $rangeLabel" -Completed
$sw.Stop()

Write-Host ""
if ($found.Count -eq 0) {
    Write-Host "No printers found responding on port 9100 or 631 in $rangeLabel." -ForegroundColor Yellow
    Write-Host "(Took $([Math]::Round($sw.Elapsed.TotalSeconds, 1))s. A firewall between here and those subnets can hide real printers from this scan.)" -ForegroundColor DarkGray
    return
}

$found = @($found | Sort-Object { [version]$_.IPAddress })

Write-Host "Found $($found.Count) device(s) in $([Math]::Round($sw.Elapsed.TotalSeconds, 1))s:" -ForegroundColor Green
foreach ($p in $found) {
    Write-Host ("  {0,-16} ports {1,-10} {2}" -f $p.IPAddress, ($p.Ports -join ','), (Get-NetworkPrinterLabel $p))
}

# --- Save --------------------------------------------------------------------
if (-not $OutFile) {
    $safeLabel = ($rangeLabel -replace '[\\/:]', '-')
    $OutFile = Join-Path (Get-ADToolOutputDir) ("Printer Scan - $safeLabel - {0}.txt" -f (Get-Date -Format 'yyyy-MM-dd HHmmss'))
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("Printer scan of: $($ranges -join ', ')")
$lines.Add("Run: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') by $env:USERNAME")
$lines.Add("Addresses scanned: $($addresses.Count)   Found: $($found.Count)   Duration: $([Math]::Round($sw.Elapsed.TotalSeconds, 1))s")
$lines.Add('')
foreach ($p in $found) { $lines.Add((ConvertTo-NetworkPrinterScanLine $p)) }
$lines | Out-File -FilePath $OutFile -Encoding UTF8

Write-Host "`nList saved to: $OutFile" -ForegroundColor Cyan
