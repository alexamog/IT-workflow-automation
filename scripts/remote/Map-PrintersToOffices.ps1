<#
.SYNOPSIS
    Work out which office each network printer physically sits in, by looking
    at who has recently printed on it and where THEY are in AD - then save the
    map as a JSON file.

.DESCRIPTION
    There's no field on a printer that says "I'm in the Springfield office" -
    but the people printing to it are almost always sitting near it. So for
    each printer this:
      1. Reads its job queue + history (IPP - see Get-CanonPrinterJobs) and
         takes up to -MaxUsersPerPrinter distinct usernames that printed there.
      2. Looks each one up in AD and reads their Office field.
      3. Whichever office comes up most often among those sampled users
         becomes the printer's office. A tie, or nobody resolving to an
         office at all, is reported honestly rather than guessed at.

    This is [[prefer-history-over-category]] applied to printers: the office
    comes from real people's own AD record (their history), never from a
    broad IP-range-to-site guess.

    NOTHING IS CHANGED on any printer or any AD account - this only reads.

.PARAMETER PrinterAddress
    One or more printer IPs to map. Skips the input file entirely.

.PARAMETER InputFile
    A "Printer Scan - ....txt" file from Find-NetworkPrinters.ps1. If neither
    this nor -PrinterAddress is given, the newest scan file in output\ is
    offered automatically.

.PARAMETER MaxUsersPerPrinter
    How many distinct recent users to sample per printer before deciding its
    office. Default 5 - more gives a steadier majority vote, at the cost of
    more AD lookups.

.PARAMETER Server
    DC to read from. Defaults to the PDC emulator (see Get-ADToolDC).

.EXAMPLE
    .\Map-PrintersToOffices.ps1
    Offers the newest printer scan in output\, then maps every printer in it.

.EXAMPLE
    .\Map-PrintersToOffices.ps1 -PrinterAddress 10.113.17.88, 10.113.17.226
#>

#Requires -Modules ActiveDirectory

[CmdletBinding()]
param(
    [string[]]$PrinterAddress,
    [string]$InputFile,
    [int]$MaxUsersPerPrinter = 5,
    [string]$Server,
    [string]$OutFile
)

. "$PSScriptRoot\..\..\lib\Common.ps1"

# --- Parse a Find-NetworkPrinters.ps1 scan file (IP<TAB>ports=...<TAB>label) -
# the header lines it also writes don't start with an IP, so they're skipped
# automatically rather than matched by position.
function Read-DeskSidePrinterScanFile {
    param([Parameter(Mandatory)][string]$Path)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($line in (Get-Content -Path $Path -ErrorAction Stop)) {
        if ($line -notmatch '^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\t') { continue }
        $fields = $line -split "`t"
        $rows.Add([pscustomobject]@{
            IPAddress = $fields[0]
            Model     = if ($fields.Count -ge 3) { $fields[2] } else { $null }
        })
    }
    $rows.ToArray()
}

# --- Work out what to map -----------------------------------------------------
$scanRows = @()
if ($PrinterAddress) {
    $scanRows = @($PrinterAddress | ForEach-Object { [pscustomobject]@{ IPAddress = $_; Model = $null } })
}
else {
    if (-not $InputFile) {
        $latest = Get-ChildItem -Path (Get-ADToolOutputDir) -Filter 'Printer Scan - *.txt' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latest) {
            Write-Host "Newest printer scan: $($latest.Name)" -ForegroundColor Cyan
            if ((Read-Host "Use it? (Y/n)").Trim().ToUpper() -ne 'N') { $InputFile = $latest.FullName }
        }
    }
    if (-not $InputFile) {
        $InputFile = (Read-Host "Path to a printer scan .txt (ENTER to type addresses instead)").Trim()
    }
    if ($InputFile) {
        try { $scanRows = @(Read-DeskSidePrinterScanFile -Path $InputFile) }
        catch { Write-Host "Could not read '$InputFile': $($_.Exception.Message)" -ForegroundColor Red; return }
        if ($scanRows.Count -eq 0) { Write-Host "No printer rows found in '$InputFile'." -ForegroundColor Yellow; return }
    }
    else {
        $typed = (Read-Host "Printer IP(s), comma-separated").Trim()
        if (-not $typed) { Write-Host "Nothing to map - cancelled." -ForegroundColor Yellow; return }
        $scanRows = @($typed -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } |
            ForEach-Object { [pscustomobject]@{ IPAddress = $_; Model = $null } })
    }
}
if ($scanRows.Count -eq 0) { Write-Host "Nothing to map - cancelled." -ForegroundColor Yellow; return }

$Server = Get-ADToolDC -Server $Server
Write-ToolHeader "Mapping $($scanRows.Count) printer(s) to offices"
Write-Host "Reading AD from DC: $Server" -ForegroundColor DarkGray

# --- Map each printer ---------------------------------------------------------
# Cache AD lookups - the same person often prints to more than one printer, and
# there is no reason to ask AD about them twice.
$officeCache = @{}
function Get-DeskSideUserOffice {
    param([string]$Username)
    if ($officeCache.ContainsKey($Username)) { return $officeCache[$Username] }
    $user = Resolve-ADToolUser -Identity $Username -Properties Office, DisplayName -Server $Server
    $result = if ($user) {
        [pscustomobject]@{ Resolved = $true; Office = $user.Office; DisplayName = $user.DisplayName }
    } else {
        [pscustomobject]@{ Resolved = $false; Office = $null; DisplayName = $null }
    }
    $officeCache[$Username] = $result
    $result
}

$results = New-Object System.Collections.Generic.List[object]
$i = 0
foreach ($row in $scanRows) {
    $i++
    Write-Host ("`n[{0}/{1}] {2}" -f $i, $scanRows.Count, $row.IPAddress) -ForegroundColor DarkGray

    $model = $row.Model
    if (-not $model) {
        $descr = Get-SnmpValue -PrinterAddress $row.IPAddress -Oid '1.3.6.1.2.1.1.1.0' -TimeoutMs 1500
        if ($descr -and $descr.Value) { $model = [string]$descr.Value }
    }

    $jobs = $null
    try { $jobs = @(Get-CanonPrinterJobs -PrinterAddress $row.IPAddress -Which All) }
    catch { Write-Host "  Could not read jobs: $($_.Exception.Message)" -ForegroundColor Yellow }

    $usernames = @($jobs | Where-Object { $_.User } | Select-Object -ExpandProperty User -Unique | Select-Object -First $MaxUsersPerPrinter)

    if ($usernames.Count -eq 0) {
        $results.Add([pscustomobject]@{
            IPAddress    = $row.IPAddress
            Model        = $model
            Office       = $null
            Ambiguous    = $false
            Confidence   = $null
            Note         = 'No job history available to sample (no jobs, or the printer could not be reached).'
            SampledUsers = @()
        })
        Write-Host "  No usable job history - Office left blank." -ForegroundColor Yellow
        continue
    }

    $sampled = foreach ($u in $usernames) {
        $office = Get-DeskSideUserOffice -Username $u
        Write-Host ("  {0,-20} -> {1}" -f $u, ($(if ($office.Resolved) { if ($office.Office) { $office.Office } else { '(no Office set in AD)' } } else { '(not found in AD)' }))) -ForegroundColor DarkGray
        [pscustomobject]@{ Username = $u; DisplayName = $office.DisplayName; Office = $office.Office; Resolved = $office.Resolved }
    }
    $sampled = @($sampled)

    # Majority vote among sampled users who both resolved in AD AND have an
    # Office value set. A tie for first place is reported, not guessed at.
    $withOffice = @($sampled | Where-Object { $_.Office })
    $office = $null; $ambiguous = $false; $confidence = $null; $note = $null

    if ($withOffice.Count -eq 0) {
        $note = if (($sampled | Where-Object Resolved).Count -eq 0) {
            'None of the sampled usernames matched an AD account.'
        } else {
            'Sampled users matched in AD, but none has an Office value set.'
        }
    }
    else {
        $groups = @($withOffice | Group-Object Office | Sort-Object Count -Descending)
        $top = @($groups | Where-Object { $_.Count -eq $groups[0].Count })
        if ($top.Count -gt 1) {
            $ambiguous = $true
            $note = "Tied between: $($top.Name -join ', ')."
        }
        else {
            $office = $groups[0].Name
            $confidence = "$($groups[0].Count)/$($withOffice.Count) sampled user(s) agree"
        }
    }

    $results.Add([pscustomobject]@{
        IPAddress    = $row.IPAddress
        Model        = $model
        Office       = $office
        Ambiguous    = $ambiguous
        Confidence   = $confidence
        Note         = $note
        SampledUsers = $sampled
    })
    Write-Host ("  => {0}" -f $(if ($ambiguous) { "AMBIGUOUS - $note" } elseif ($office) { "$office  ($confidence)" } else { "Unknown - $note" })) `
        -ForegroundColor $(if ($ambiguous) { 'Yellow' } elseif ($office) { 'Green' } else { 'DarkYellow' })
}

# --- Summary + save ------------------------------------------------------------
$results = @($results | Sort-Object { if ($_.Office) { $_.Office } else { 'zzz_Unknown' } }, IPAddress)

Write-Host "`n`nSummary by office:" -ForegroundColor Cyan
foreach ($g in ($results | Group-Object { if ($_.Ambiguous) { '(Ambiguous)' } elseif ($_.Office) { $_.Office } else { '(Unknown)' } } | Sort-Object Name)) {
    Write-Host ("`n=== {0}  ({1} printer(s)) ===" -f $g.Name, $g.Count) -ForegroundColor Green
    $g.Group | ForEach-Object { Write-Host ("  {0,-16} {1}" -f $_.IPAddress, $_.Model) }
}

if (-not $OutFile) {
    $OutFile = Join-Path (Get-ADToolOutputDir) ("Printer-Office-Map-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$results | ConvertTo-Json -Depth 5 | Out-File -FilePath $OutFile -Encoding UTF8
Write-Host "`nJSON written to: $OutFile" -ForegroundColor Cyan
