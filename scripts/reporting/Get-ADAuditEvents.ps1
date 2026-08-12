<#
.SYNOPSIS
    Show recent AD account activity - lockouts, password resets, account
    enable/disable, group changes - over a time range you choose.

.DESCRIPTION
    Reads the SECURITY event log on the domain controller(s) and turns the raw
    events into a plain table: when it happened, what happened, to whom, and who
    did it. Use it to answer "who reset Jane's password yesterday?", "when did
    this account keep locking out?", or "what changed on the admins group this
    week?".

    WHERE THE EVENTS LIVE
    Lockouts (4740) are always written on the PDC emulator, so the PDC alone
    catches every lockout. Password resets and most other changes are written on
    whichever DC handled them - so to be sure you see ALL resets, use -AllDcs to
    sweep every domain controller (a little slower).

    WHAT IT LOOKS FOR (the usual account-admin events)
        Locked out (4740)            Unlocked (4767)
        Password reset by admin (4724)   Password changed by user (4723)
        Account disabled (4725)      Account enabled (4722)
        Account created (4720)       Account deleted (4726)
        Account changed (4738)       Name change (4781)
        Added to / removed from a group (4728/4729, 4732/4733, 4756/4757)

    REPEATED LOCKOUTS - WHY 4740 ALONE ISN'T ENOUGH
    A lockout (4740) is only written ONCE, each time the account trips the
    threshold, and only on the PDC. It does not show every bad attempt. When
    someone "keeps locking out", what you actually want is the failed sign-ins
    behind it - a stale phone, a mapped drive, an old RDP session - each of which
    records WHERE it came from:
        Failed logon (4625)   Kerberos pre-auth failed (4771)   NTLM failed (4776)
    Those are written on whichever DC handled the attempt, so pair them with
    -AllDcs. They are included automatically when you name an -Identity (you are
    investigating one person); add -IncludeSignInFailures to see them across
    everyone (noisy). Each shows the source IP / computer in the Detail column.

    You need rights to read the DC Security log (a domain admin, or run as
    SYSTEM via RMM on a DC). It only READS - it changes nothing.

.PARAMETER Identity
    Limit to one account (SAM or UPN). Omit to see everyone.

.PARAMETER Hours
    How far back, in hours. Ignored if -Days or -Start is given.

.PARAMETER Days
    How far back, in days.

.PARAMETER Start
    Explicit start time (any date PowerShell understands). Pairs with -End.

.PARAMETER End
    Explicit end time. Defaults to now.

.PARAMETER AllDcs
    Query every domain controller, not just the PDC. Needed to be sure you catch
    password resets, which can be written on any DC.

.PARAMETER Server
    Query one named DC instead of the PDC.

.PARAMETER IncludeSignInFailures
    Include failed sign-in events (4625/4771/4776) even when no -Identity is
    given. Automatically on when you name an -Identity. Best with -AllDcs.

.PARAMETER Csv
    Also save the results to a CSV in output\.

.EXAMPLE
    .\Get-ADAuditEvents.ps1 -Hours 24

.EXAMPLE
    .\Get-ADAuditEvents.ps1 alex.amog -Days 7 -AllDcs

.EXAMPLE
    .\Get-ADAuditEvents.ps1 -Start '2026-07-20' -End '2026-07-24' -Csv
#>

#Requires -Modules ActiveDirectory
param(
    [string]$Identity,
    [int]$Hours,
    [int]$Days,
    [datetime]$Start,
    [datetime]$End,
    [switch]$AllDcs,
    [string]$Server,
    [switch]$IncludeSignInFailures,
    [switch]$Csv
)

. "$PSScriptRoot\..\..\lib\Common.ps1"

Write-ToolHeader 'AD security events'

# --- The events we care about, with a plain-English name ---------------------
$eventName = @{
    4740 = 'Locked out'
    4767 = 'Unlocked'
    4724 = 'Password reset (by admin)'
    4723 = 'Password changed (by user)'
    4725 = 'Account disabled'
    4722 = 'Account enabled'
    4726 = 'Account deleted'
    4720 = 'Account created'
    4738 = 'Account changed'
    4781 = 'Account renamed'
    4728 = 'Added to global group'
    4729 = 'Removed from global group'
    4732 = 'Added to local group'
    4733 = 'Removed from local group'
    4756 = 'Added to universal group'
    4757 = 'Removed from universal group'
}
# Group-membership events name the GROUP in TargetUserName and the affected
# account in MemberName - so they read the other way round from the rest.
$groupEvents = @(4728, 4729, 4732, 4733, 4756, 4757)

# Failed sign-ins: the events behind a "keeps locking out" complaint. Each one
# carries the source IP / computer, which is what you actually chase down. Off by
# default (noisy across a whole domain), but on automatically when investigating
# one -Identity.
$failureName = @{
    4625 = 'Failed logon'
    4771 = 'Kerberos pre-auth failed'
    4776 = 'NTLM logon failed'
}
$failureEvents = @($failureName.Keys)
$showFailures  = [bool]$Identity -or $IncludeSignInFailures
if ($showFailures) { foreach ($k in $failureName.Keys) { $eventName[$k] = $failureName[$k] } }

# --- Work out the time window ------------------------------------------------
if (-not $End) { $End = Get-Date }

if (-not $Start) {
    if ($Days)      { $Start = (Get-Date).AddDays(-$Days) }
    elseif ($Hours) { $Start = (Get-Date).AddHours(-$Hours) }
    else {
        # Ask, with friendly presets.
        Write-Host "  How far back?" -ForegroundColor Cyan
        Write-Host "    1  Last 24 hours"
        Write-Host "    2  Last 7 days"
        Write-Host "    3  Last 30 days"
        Write-Host "    4  Custom (type something like 48h, 14d, or a start date)"
        $pick = Read-Host "  Choose"
        switch ($pick) {
            '1' { $Start = (Get-Date).AddHours(-24) }
            '2' { $Start = (Get-Date).AddDays(-7) }
            '3' { $Start = (Get-Date).AddDays(-30) }
            default {
                $txt = Read-Host "  How far back (e.g. 48h, 14d) or a start date"
                if ($txt -match '^\s*(\d+)\s*([hdw])?\s*$') {
                    $n = [int]$Matches[1]
                    switch ($Matches[2]) {
                        'd'     { $Start = (Get-Date).AddDays(-$n) }
                        'w'     { $Start = (Get-Date).AddDays(-7 * $n) }
                        default { $Start = (Get-Date).AddHours(-$n) }   # bare number or 'h' = hours
                    }
                }
                else {
                    $parsed = Get-Date
                    if ([datetime]::TryParse($txt, [ref]$parsed)) { $Start = $parsed }
                }
            }
        }
    }
}

if (-not $Start) { Write-Host "  No time range given - nothing to do." -ForegroundColor Yellow; return }
if ($Start -ge $End) { Write-Host "  The start time is not before the end time." -ForegroundColor Yellow; return }

# --- Resolve the account filter (optional) -----------------------------------
$sam = $null
if ($Identity) {
    $user = Resolve-ADToolUser -Identity $Identity
    if (-not $user) { return }
    $sam = $user.SamAccountName
    Write-Host ("  Filtering to: {0} ({1})" -f $user.Name, $sam) -ForegroundColor DarkGray
}

# --- Which DCs to read -------------------------------------------------------
$targets = @()
if ($Server)      { $targets = @($Server) }
elseif ($AllDcs)  {
    try { $targets = @(Get-ADDomainController -Filter * | Select-Object -ExpandProperty HostName) }
    catch { Write-Host "  Could not list domain controllers: $($_.Exception.Message)" -ForegroundColor Red; return }
}
else {
    try { $targets = @((Get-ADDomain).PDCEmulator) }
    catch { Write-Host "  Could not find the PDC emulator: $($_.Exception.Message)" -ForegroundColor Red; return }
}

Write-Host ("  Reading Security log from {0}: {1}" -f $targets.Count, ($targets -join ', ')) -ForegroundColor DarkGray
Write-Host ("  Window: {0:g}  ->  {1:g}" -f $Start, $End) -ForegroundColor DarkGray
if ($showFailures) { Write-Host "  Including failed sign-ins (4625/4771/4776)." -ForegroundColor DarkGray }
if ($showFailures -and -not $AllDcs -and -not $Server) {
    Write-Host "  Tip: failed sign-ins land on the DC that handled them - add -AllDcs to catch them all." -ForegroundColor DarkYellow
}
Write-Host "" -ForegroundColor DarkGray

# --- Read and parse ----------------------------------------------------------
$filter = @{ LogName = 'Security'; Id = @($eventName.Keys); StartTime = $Start; EndTime = $End }
$rows = New-Object System.Collections.Generic.List[object]

foreach ($dc in $targets) {
    try {
        $events = Get-WinEvent -ComputerName $dc -FilterHashtable $filter -ErrorAction Stop
    }
    catch {
        # "No events were found" is a normal, expected outcome - not an error.
        if ($_.Exception.Message -match 'No events were found') { continue }
        Write-Host "  Could not read events from $dc : $($_.Exception.Message)" -ForegroundColor Red
        continue
    }

    foreach ($e in $events) {
        $xml  = [xml]$e.ToXml()
        $data = @{}
        foreach ($d in $xml.Event.EventData.Data) { $data[$d.Name] = $d.'#text' }

        if ($groupEvents -contains $e.Id) {
            $target = $data['MemberName']; if (-not $target) { $target = $data['MemberSid'] }
            $detail = "group: $($data['TargetUserName'])"
        }
        elseif ($failureEvents -contains $e.Id) {
            # Failed sign-in: the prize is the source. Prefer the IP, fall back to
            # the workstation name; tidy the IPv6-mapped-IPv4 and empty forms.
            $target = $data['TargetUserName']
            $src = $data['IpAddress']
            if (-not $src -or $src -in '-', '::1', '127.0.0.1') { $src = $data['WorkstationName'] }
            if (-not $src) { $src = $data['Workstation'] }
            if ($src) { $src = $src -replace '^::ffff:', '' }
            $detail = if ($src) { "from: $src" } else { '(source not recorded)' }
        }
        else {
            $target = $data['TargetUserName']
            $detail = switch ($e.Id) {
                4740    { "from: $($data['TargetDomainName'])" }   # lockout source computer
                4781    { "new name: $($data['NewTargetUserName'])" }
                default { '' }
            }
        }

        # Account filter: match the affected account.
        if ($sam -and ($target -ne $sam)) { continue }

        # Skip machine accounts (end in $) unless a specific user was asked for -
        # they are almost always noise for this kind of question.
        if (-not $sam -and $target -like '*$') { continue }

        $rows.Add([PSCustomObject]@{
            Time   = $e.TimeCreated
            Event  = $eventName[[int]$e.Id]
            Target = $target
            By     = $data['SubjectUserName']
            Detail = $detail
            DC     = ($dc -split '\.')[0]
        })
    }
}

if ($rows.Count -eq 0) {
    Write-Host "  No matching events in that window." -ForegroundColor Yellow
    return
}

$sorted = @($rows | Sort-Object Time -Descending)

$sorted | Format-Table -AutoSize `
    @{ N = 'Time'; E = { $_.Time.ToString('yyyy-MM-dd HH:mm:ss') } }, Event, Target, By, Detail, DC

# --- Summary -----------------------------------------------------------------
Write-Host ("`n  {0} event(s)." -f $sorted.Count) -ForegroundColor Green
$sorted | Group-Object Event | Sort-Object Count -Descending |
    ForEach-Object { Write-Host ("    {0,-28} {1}" -f $_.Name, $_.Count) -ForegroundColor DarkGray }

# --- Optional CSV ------------------------------------------------------------
if ($Csv) {
    $stamp = (Get-Date).ToString('yyyy-MM-dd HHmmss')
    $file  = Join-Path (Get-ADToolOutputDir -Category 'Reports\AD-Security-Events') "$stamp.csv"
    $sorted | Export-Csv -Path $file -NoTypeInformation -Encoding UTF8
    Write-Host "`n  Saved: $file" -ForegroundColor Green
}
