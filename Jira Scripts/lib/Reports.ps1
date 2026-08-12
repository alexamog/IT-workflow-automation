<#
    Reports.ps1
    -----------
    The monthly reporting pack. Replaces two manual runbooks:

      "Monthly Ticket Numbers" - was: search in Jira, filter dates, exclude
        cancelled/closed, export CSV, open Excel, build a pivot table by
        Organization. Now: one menu option that counts tickets per site.

      "Monthly IT Metrics" - was: open the Jira CSAT report, set a custom date
        range, read the average; open the Time to First Response report, set the
        range; then open security.microsoft.com for the phishing simulation
        percentages. Now: the two Jira halves are pulled directly. The phishing
        half needs Microsoft Graph (see Get-PhishingSummary) and falls back to
        typing in the two percentages.

    Everything here is READ-ONLY against Jira. No ticket is ever modified.

    Custom field ids are resolved by NAME via Get-JiraFieldId, because
    customfield_ numbers differ between Jira sites. A site missing a field
    simply skips that metric instead of erroring.
#>

# ===========================================================================
# CONFIG
# ===========================================================================
# Statuses excluded from the ticket-count report: tickets that were never
# really worked. Names that do not exist in this Jira are dropped automatically,
# so it is safe to list both spellings of "cancelled".
$script:ReportExcludedStatuses = @('Canceled', 'Cancelled', 'Closed')

# The first-response target the metrics report grades against, in hours. The
# runbook's question is "are we responding to each new ticket within 24 hours".
$script:FirstResponseTargetHours = 24

# Root of the console's output folder. Resolved to a clean absolute path rather
# than one containing "lib\..\", so the paths printed to the operator are
# readable. This console also ships as a standalone edition without the main
# toolkit's lib\, so it keeps its own output root rather than calling
# Get-ADToolOutputDir - but it uses the same "sort by kind, then date" shape.
$script:ReportOutputDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'output'

function Get-ReportFolder {
    <#
    .SYNOPSIS
        Returns (creating if needed) the folder for one month's report files.
    .DESCRIPTION
        One folder per run, e.g. output\Reports\Monthly\2026-07\. A monthly run
        produces three files that belong together; keeping them in a dated folder
        means finding last month's report is one click rather than picking three
        files out of a long list.
    .PARAMETER Month
        A range object from Get-ReportMonth.
    .OUTPUTS
        System.String - the absolute folder path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Month)

    $dir = Join-Path $script:ReportOutputDir (Join-Path 'Reports\Monthly' $Month.Slug)
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

# ===========================================================================
# SHARED HELPERS
# ===========================================================================
function Get-ReportMonth {
    <#
    .SYNOPSIS
        Builds the date range for a reporting month.
    .DESCRIPTION
        Both runbooks say "pick the 1st and last day of the previous month", so
        that is the default. The returned object carries the range in the two
        shapes needed: real DateTimes for arithmetic, and JQL-safe strings.
    .PARAMETER MonthsBack
        How many months to go back. 1 (the default) is last month, 0 is the
        current month-to-date.
    .OUTPUTS
        PSCustomObject with Start, End, Label, Slug, JqlStart, JqlEnd.
    .EXAMPLE
        $m = Get-ReportMonth            # last month
        $m = Get-ReportMonth -MonthsBack 3
    #>
    [CmdletBinding()]
    param([int]$MonthsBack = 1)

    $firstOfThisMonth = Get-Date -Day 1 -Hour 0 -Minute 0 -Second 0 -Millisecond 0
    $start = $firstOfThisMonth.AddMonths(-$MonthsBack)
    $end   = $start.AddMonths(1).AddSeconds(-1)

    return [pscustomobject]@{
        Start    = $start
        End      = $end
        Label    = $start.ToString('MMMM yyyy')
        Slug     = $start.ToString('yyyy-MM')
        JqlStart = $start.ToString('yyyy-MM-dd HH:mm')
        JqlEnd   = $end.ToString('yyyy-MM-dd HH:mm')
    }
}

function Get-ProjectStatusName {
    <#
    .SYNOPSIS
        Returns every status name used by the reporting project.
    .DESCRIPTION
        Used to filter the configured exclusion list down to statuses that
        actually exist. Naming a status that does not exist makes the whole JQL
        query fail, which would take the report down with it.
    .OUTPUTS
        System.String[] - distinct status names (empty on failure).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    try {
        $resp = Invoke-RestMethod -Method Get -Headers $script:Headers `
            -Uri "$script:BaseUrl/rest/api/3/project/$script:ProjectKey/statuses"
    } catch {
        Write-Host "  Could not read project statuses: $($_.Exception.Message)" -ForegroundColor DarkYellow
        return @()
    }
    return @($resp.statuses | ForEach-Object { $_.name } | Sort-Object -Unique)
}

function Get-ReportExcludedStatus {
    <#
    .SYNOPSIS
        The configured exclusion list, narrowed to statuses this Jira has.
    .OUTPUTS
        System.String[] - status names safe to use in JQL.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $existing = Get-ProjectStatusName
    if (-not $existing -or $existing.Count -eq 0) { return @() }
    return @($script:ReportExcludedStatuses | Where-Object { $existing -contains $_ })
}

function ConvertTo-JqlList {
    <#
    .SYNOPSIS
        Formats string values as a quoted, comma-separated JQL list.
    .EXAMPLE
        ConvertTo-JqlList @('Canceled','Closed')   # -> "Canceled","Closed"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string[]]$Values)

    return (($Values | ForEach-Object { '"' + $_ + '"' }) -join ',')
}

function Get-MedianValue {
    <#
    .SYNOPSIS
        Median of a set of numbers. Returns 0 for an empty set.
    .DESCRIPTION
        The average time to first response is skewed badly by one ticket that
        sat over a weekend, so the median is reported alongside it.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param([double[]]$Values)

    if (-not $Values -or $Values.Count -eq 0) { return 0 }
    $sorted = @($Values | Sort-Object)
    $n = $sorted.Count
    if ($n % 2 -eq 1) { return [double]$sorted[[int](($n - 1) / 2)] }
    return ([double]$sorted[[int]($n / 2) - 1] + [double]$sorted[[int]($n / 2)]) / 2
}

function Get-SafePercent {
    <#
    .SYNOPSIS
        Percentage of Part out of Whole, rounded, with divide-by-zero guarded.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param([double]$Part, [double]$Whole, [int]$Decimals = 1)

    if ($Whole -le 0) { return 0 }
    return [math]::Round(($Part / $Whole) * 100, $Decimals)
}

# ===========================================================================
# REPORT 1 - MONTHLY TICKET NUMBERS (tickets per site)
# ===========================================================================
function Get-TicketNumberReport {
    <#
    .SYNOPSIS
        Counts the month's tickets grouped by Organization (site).
    .DESCRIPTION
        The automated equivalent of the "Monthly Ticket Numbers" runbook:
        filter to tickets created in the month, drop the ones that were never
        worked (cancelled/closed), and total them per site - the pivot table
        that document builds by hand in Excel.

        Tickets carrying more than one organization are counted once, against
        their first one, so the site totals always add up to the ticket total.
        The count of such tickets is reported separately.
    .PARAMETER Month
        A range object from Get-ReportMonth.
    .OUTPUTS
        PSCustomObject with Month, Jql, Total, Rows, NoOrgCount, MultiOrgCount,
        ExcludedStatuses and Issues.
    .EXAMPLE
        $r = Get-TicketNumberReport -Month (Get-ReportMonth)
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Month)

    $excluded = Get-ReportExcludedStatus

    $jql = "project = $script:ProjectKey" +
           " AND created >= `"$($Month.JqlStart)`"" +
           " AND created <= `"$($Month.JqlEnd)`""
    if ($excluded.Count -gt 0) {
        $jql += " AND status NOT IN (" + (ConvertTo-JqlList $excluded) + ")"
    }
    $jql += " ORDER BY created ASC"

    $fields = "summary,status,created,resolutiondate,reporter,assignee,priority"
    if ($script:OrgFieldId) { $fields += ",$script:OrgFieldId" }

    Write-Host "  Fetching tickets created in $($Month.Label)..." -ForegroundColor DarkGray
    $issues = @(Get-IssueByJql -Jql $jql -Fields $fields)

    $noOrgLabel = '(no organization)'
    $counts     = @{}
    $multiOrg   = 0
    $detail     = @()

    foreach ($issue in $issues) {
        $orgNames = @()
        if ($script:OrgFieldId) {
            $orgNames = @($issue.fields.$($script:OrgFieldId) | ForEach-Object { $_.name } | Where-Object { $_ })
        }
        if ($orgNames.Count -gt 1) { $multiOrg++ }

        $site = if ($orgNames.Count -gt 0) { $orgNames[0] } else { $noOrgLabel }
        if ($counts.ContainsKey($site)) { $counts[$site]++ } else { $counts[$site] = 1 }

        $detail += [pscustomobject]@{
            Key      = $issue.key
            Site     = $site
            Summary  = $issue.fields.summary
            Status   = $issue.fields.status.name
            Priority = $issue.fields.priority.name
            Reporter = $issue.fields.reporter.displayName
            Assignee = $issue.fields.assignee.displayName
            Created  = $issue.fields.created
        }
    }

    $total = $issues.Count
    # Sites first (largest to smallest); the "no organization" bucket is not a
    # site, so it is pinned to the bottom rather than ranked among them.
    $rows = @($counts.GetEnumerator() |
        Where-Object { $_.Key -ne $noOrgLabel } |
        Sort-Object -Property @{Expression = 'Value'; Descending = $true}, @{Expression = 'Name'} |
        ForEach-Object {
            [pscustomobject]@{
                Site    = $_.Key
                Count   = $_.Value
                Percent = Get-SafePercent -Part $_.Value -Whole $total
            }
        })
    if ($counts.ContainsKey($noOrgLabel)) {
        $rows += [pscustomobject]@{
            Site    = $noOrgLabel
            Count   = $counts[$noOrgLabel]
            Percent = Get-SafePercent -Part $counts[$noOrgLabel] -Whole $total
        }
    }

    return [pscustomobject]@{
        Month             = $Month
        Jql               = $jql
        Total             = $total
        Rows              = $rows
        SiteCount         = @($rows | Where-Object { $_.Site -ne $noOrgLabel }).Count
        NoOrgCount        = $(if ($counts.ContainsKey($noOrgLabel)) { $counts[$noOrgLabel] } else { 0 })
        MultiOrgCount     = $multiOrg
        ExcludedStatuses  = $excluded
        Issues            = $detail
    }
}

function Show-TicketNumberReport {
    <#
    .SYNOPSIS
        Prints the tickets-per-site table to the console.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Report)

    Write-Host ""
    Write-Host "  TICKETS BY SITE - $($Report.Month.Label)" -ForegroundColor Cyan
    Write-Host ("  " + ("-" * 62)) -ForegroundColor DarkGray

    if ($Report.Total -eq 0) {
        Write-Host "  No tickets found for this month." -ForegroundColor Yellow
        return
    }

    $maxCount = ($Report.Rows | Measure-Object -Property Count -Maximum).Maximum
    foreach ($row in $Report.Rows) {
        $bar = ""
        if ($maxCount -gt 0) { $bar = "#" * [math]::Max(1, [int](($row.Count / $maxCount) * 22)) }
        $color = if ($row.Site -eq '(no organization)') { 'DarkYellow' } else { 'Gray' }
        Write-Host ("  {0} {1,4}  {2,5}%  {3}" -f (Format-Cell $row.Site 30), $row.Count, $row.Percent, $bar) -ForegroundColor $color
    }

    Write-Host ("  " + ("-" * 62)) -ForegroundColor DarkGray
    Write-Host ("  {0} {1,4}" -f (Format-Cell 'TOTAL' 30), $Report.Total) -ForegroundColor White
    Write-Host ""
    Write-Host "  $($Report.SiteCount) site(s). Excluded statuses: $(($Report.ExcludedStatuses -join ', '))" -ForegroundColor DarkGray
    if ($Report.NoOrgCount -gt 0) {
        Write-Host "  $($Report.NoOrgCount) ticket(s) have no organization set - menu option 4 can fix those." -ForegroundColor DarkYellow
    }
    if ($Report.MultiOrgCount -gt 0) {
        Write-Host "  $($Report.MultiOrgCount) ticket(s) had multiple organizations; each counted once, against the first." -ForegroundColor DarkGray
    }
}

# ===========================================================================
# REPORT 2a - CSAT (satisfaction surveys)
# ===========================================================================
function Get-CsatReport {
    <#
    .SYNOPSIS
        Summarises the month's satisfaction surveys.
    .DESCRIPTION
        The automated equivalent of the CSAT half of "Monthly IT Metrics":
        the average rating, how many surveys came back, the spread of scores,
        a per-agent breakdown, and any comments staff left.

        Surveys are selected by "Satisfaction date" (when the rating was given),
        which is what the Jira report's date range filters on.
    .PARAMETER Month
        A range object from Get-ReportMonth.
    .OUTPUTS
        PSCustomObject with Available, Count, Average, Distribution, ByAgent,
        Comments, ResolvedInMonth and ResponseRate.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Month)

    $satId     = Get-JiraFieldId -Name 'Satisfaction'
    $satDateId = Get-JiraFieldId -Name 'Satisfaction date'

    if (-not $satId -or -not $satDateId) {
        return [pscustomobject]@{
            Available = $false
            Reason    = "This Jira has no 'Satisfaction' field - CSAT is not enabled on the service desk."
        }
    }

    $jql = "project = $script:ProjectKey" +
           " AND `"Satisfaction date`" >= `"$($Month.JqlStart)`"" +
           " AND `"Satisfaction date`" <= `"$($Month.JqlEnd)`"" +
           " ORDER BY `"Satisfaction date`" ASC"

    Write-Host "  Fetching satisfaction surveys..." -ForegroundColor DarkGray
    $issues = @(Get-IssueByJql -Jql $jql -Fields "summary,assignee,resolutiondate,$satId,$satDateId")

    $ratings = @()
    $byAgent = @{}
    $comments = @()

    foreach ($issue in $issues) {
        $sat = $issue.fields.$satId
        # The field comes back as an object with .rating on JSM; guard for a
        # bare number in case a site stores it differently.
        $rating = $null
        if ($null -ne $sat) {
            if ($null -ne $sat.rating) { $rating = [int]$sat.rating }
            elseif ($sat -is [int] -or $sat -is [double]) { $rating = [int]$sat }
        }
        if ($null -eq $rating) { continue }

        $ratings += $rating
        $agent = $issue.fields.assignee.displayName
        if (-not $agent) { $agent = '(unassigned)' }
        if (-not $byAgent.ContainsKey($agent)) { $byAgent[$agent] = @() }
        $byAgent[$agent] += $rating

        if ($sat.comment) {
            $comments += [pscustomobject]@{
                Key     = $issue.key
                Rating  = $rating
                Agent   = $agent
                Comment = ($sat.comment -replace '\s+', ' ').Trim()
            }
        }
    }

    # Response rate needs a denominator. Surveys are sent when a ticket is
    # resolved, so tickets resolved in the month is the closest figure the API
    # exposes. It is an approximation, and is labelled as one in the output.
    $resolvedJql = "project = $script:ProjectKey" +
                   " AND resolutiondate >= `"$($Month.JqlStart)`"" +
                   " AND resolutiondate <= `"$($Month.JqlEnd)`""
    $resolvedCount = @(Get-IssueByJql -Jql $resolvedJql -Fields "summary").Count

    $distribution = @{}
    foreach ($r in 1..5) { $distribution[$r] = @($ratings | Where-Object { $_ -eq $r }).Count }

    $agentRows = @($byAgent.GetEnumerator() | ForEach-Object {
        [pscustomobject]@{
            Agent   = $_.Key
            Surveys = $_.Value.Count
            Average = [math]::Round(($_.Value | Measure-Object -Average).Average, 2)
        }
    } | Sort-Object -Property @{Expression = 'Surveys'; Descending = $true}, 'Agent')

    $average = 0
    if ($ratings.Count -gt 0) { $average = [math]::Round(($ratings | Measure-Object -Average).Average, 2) }

    return [pscustomobject]@{
        Available       = $true
        Month           = $Month
        Jql             = $jql
        Count           = $ratings.Count
        Average         = $average
        Distribution    = $distribution
        ByAgent         = $agentRows
        Comments        = $comments
        ResolvedInMonth = $resolvedCount
        ResponseRate    = Get-SafePercent -Part $ratings.Count -Whole $resolvedCount
    }
}

function Show-CsatReport {
    <#
    .SYNOPSIS
        Prints the CSAT summary to the console.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Report)

    Write-Host ""
    Write-Host "  SATISFACTION (CSAT)" -ForegroundColor Cyan
    Write-Host ("  " + ("-" * 62)) -ForegroundColor DarkGray

    if (-not $Report.Available) {
        Write-Host "  $($Report.Reason)" -ForegroundColor Yellow
        return
    }
    if ($Report.Count -eq 0) {
        Write-Host "  No surveys were returned in this month." -ForegroundColor Yellow
        return
    }

    $avgColor = if ($Report.Average -ge 4.5) { 'Green' } elseif ($Report.Average -ge 3.5) { 'Yellow' } else { 'Red' }
    Write-Host ("  Average rating   : {0} / 5" -f $Report.Average) -ForegroundColor $avgColor
    Write-Host ("  Surveys returned : {0}" -f $Report.Count) -ForegroundColor White
    Write-Host ("  Response rate    : {0}% (of {1} tickets resolved in the month - approximate)" -f $Report.ResponseRate, $Report.ResolvedInMonth) -ForegroundColor DarkGray
    Write-Host ""
    foreach ($r in 5..1) {
        $n = $Report.Distribution[$r]
        $bar = ""
        if ($n -gt 0) { $bar = "#" * [math]::Max(1, [int](($n / $Report.Count) * 30)) }
        Write-Host ("    {0} star {1,4}  {2}" -f $r, $n, $bar) -ForegroundColor Gray
    }

    if ($Report.ByAgent.Count -gt 0) {
        Write-Host ""
        Write-Host "  By agent:" -ForegroundColor DarkCyan
        foreach ($a in $Report.ByAgent) {
            Write-Host ("    {0} {1,3} survey(s)   avg {2}" -f (Format-Cell $a.Agent 26), $a.Surveys, $a.Average) -ForegroundColor Gray
        }
    }

    if ($Report.Comments.Count -gt 0) {
        Write-Host ""
        Write-Host "  Comments left by staff:" -ForegroundColor DarkCyan
        foreach ($c in $Report.Comments) {
            $text = $c.Comment
            if ($text.Length -gt 90) { $text = $text.Substring(0, 90) + "..." }
            Write-Host ("    [{0} star] {1} ({2}): {3}" -f $c.Rating, $c.Key, $c.Agent, $text) -ForegroundColor Gray
        }
    }
}

# ===========================================================================
# REPORT 2b - TIME TO FIRST RESPONSE
# ===========================================================================
function Get-FirstResponseReport {
    <#
    .SYNOPSIS
        Summarises how quickly the month's new tickets got a first reply.
    .DESCRIPTION
        The automated equivalent of the "Time to First Response" half of
        "Monthly IT Metrics". Reads the JSM SLA field, which already knows each
        ticket's goal and whether it was breached, and additionally grades every
        ticket against the plain-English target in the runbook: did we respond
        within $script:FirstResponseTargetHours hours.

        Tickets in the excluded statuses (cancelled/closed) are left out, so a
        ticket nobody ever worked does not drag the numbers down.
    .PARAMETER Month
        A range object from Get-ReportMonth.
    .OUTPUTS
        PSCustomObject with Available, Total, Responded, Pending, MetGoal,
        Breached, WithinTarget, AverageHours, MedianHours and Slowest.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Month)

    $slaId = Get-JiraFieldId -Name 'Time to first response'
    if (-not $slaId) {
        return [pscustomobject]@{
            Available = $false
            Reason    = "This Jira has no 'Time to first response' SLA field."
        }
    }

    $excluded = Get-ReportExcludedStatus
    $jql = "project = $script:ProjectKey" +
           " AND created >= `"$($Month.JqlStart)`"" +
           " AND created <= `"$($Month.JqlEnd)`""
    if ($excluded.Count -gt 0) {
        $jql += " AND status NOT IN (" + (ConvertTo-JqlList $excluded) + ")"
    }
    $jql += " ORDER BY created ASC"

    Write-Host "  Fetching first-response times..." -ForegroundColor DarkGray
    $issues = @(Get-IssueByJql -Jql $jql -Fields "summary,created,status,assignee,$slaId")

    $hours       = @()
    $metGoal     = 0
    $breached    = 0
    $withinTarget = 0
    $pending     = 0
    $detail      = @()

    foreach ($issue in $issues) {
        $sla = $issue.fields.$slaId
        $cycle = $null
        if ($sla -and $sla.completedCycles -and @($sla.completedCycles).Count -gt 0) {
            $cycle = @($sla.completedCycles)[0]
        }

        if (-not $cycle) {
            # Never got a first response inside the SLA clock (still ongoing).
            $pending++
            continue
        }

        $elapsedHours = [math]::Round($cycle.elapsedTime.millis / 3600000, 2)
        $hours += $elapsedHours
        if ($cycle.breached) { $breached++ } else { $metGoal++ }
        if ($elapsedHours -le $script:FirstResponseTargetHours) { $withinTarget++ }

        $detail += [pscustomobject]@{
            Key          = $issue.key
            Summary      = $issue.fields.summary
            Assignee     = $issue.fields.assignee.displayName
            Created      = $issue.fields.created
            ElapsedHours = $elapsedHours
            GoalHours    = [math]::Round($cycle.goalDuration.millis / 3600000, 2)
            Breached     = [bool]$cycle.breached
        }
    }

    $responded = $hours.Count
    return [pscustomobject]@{
        Available     = $true
        Month         = $Month
        Jql           = $jql
        Total         = $issues.Count
        Responded     = $responded
        Pending       = $pending
        MetGoal       = $metGoal
        MetGoalPct    = Get-SafePercent -Part $metGoal -Whole $responded
        Breached      = $breached
        BreachedPct   = Get-SafePercent -Part $breached -Whole $responded
        TargetHours   = $script:FirstResponseTargetHours
        WithinTarget  = $withinTarget
        WithinTargetPct = Get-SafePercent -Part $withinTarget -Whole $responded
        AverageHours  = $(if ($responded -gt 0) { [math]::Round(($hours | Measure-Object -Average).Average, 2) } else { 0 })
        MedianHours   = [math]::Round((Get-MedianValue -Values $hours), 2)
        Slowest       = @($detail | Sort-Object ElapsedHours -Descending | Select-Object -First 5)
        Detail        = $detail
    }
}

function Show-FirstResponseReport {
    <#
    .SYNOPSIS
        Prints the first-response summary to the console.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Report)

    Write-Host ""
    Write-Host "  TIME TO FIRST RESPONSE" -ForegroundColor Cyan
    Write-Host ("  " + ("-" * 62)) -ForegroundColor DarkGray

    if (-not $Report.Available) {
        Write-Host "  $($Report.Reason)" -ForegroundColor Yellow
        return
    }
    if ($Report.Responded -eq 0) {
        Write-Host "  No tickets with a completed first response this month." -ForegroundColor Yellow
        return
    }

    $targetColor = if ($Report.WithinTargetPct -ge 90) { 'Green' } elseif ($Report.WithinTargetPct -ge 75) { 'Yellow' } else { 'Red' }
    Write-Host ("  Tickets created    : {0}" -f $Report.Total) -ForegroundColor White
    Write-Host ("  Answered           : {0}" -f $Report.Responded) -ForegroundColor White
    Write-Host ("  Within {0}h target  : {1} ({2}%)" -f $Report.TargetHours, $Report.WithinTarget, $Report.WithinTargetPct) -ForegroundColor $targetColor
    Write-Host ("  Met the Jira SLA   : {0} ({1}%)" -f $Report.MetGoal, $Report.MetGoalPct) -ForegroundColor Gray
    Write-Host ("  Breached SLA       : {0} ({1}%)" -f $Report.Breached, $Report.BreachedPct) -ForegroundColor $(if ($Report.Breached -gt 0) { 'DarkYellow' } else { 'Gray' })
    Write-Host ("  Median response    : {0} h" -f $Report.MedianHours) -ForegroundColor Gray
    Write-Host ("  Average response   : {0} h" -f $Report.AverageHours) -ForegroundColor DarkGray
    if ($Report.Pending -gt 0) {
        Write-Host ("  Still awaiting a first response: {0}" -f $Report.Pending) -ForegroundColor DarkYellow
    }

    if ($Report.Slowest.Count -gt 0) {
        Write-Host ""
        Write-Host "  Slowest to answer:" -ForegroundColor DarkCyan
        foreach ($s in $Report.Slowest) {
            Write-Host ("    {0}  {1}  {2} h" -f (Format-Cell $s.Key 12), (Format-Cell $s.Summary 34), $s.ElapsedHours) -ForegroundColor Gray
        }
    }
}

# ===========================================================================
# REPORT 2c - TIME TO RESOLUTION
# ===========================================================================
function Format-DurationHours {
    <#
    .SYNOPSIS
        Renders a number of hours the way a person would say it.
    .DESCRIPTION
        Resolution times run much longer than first-response times, and
        "73.4 h" is harder to read at a glance than "3.1 days". Anything under
        two days stays in hours.
    .EXAMPLE
        Format-DurationHours 0.5    # -> 0.5 h
        Format-DurationHours 73.4   # -> 3.1 days
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([double]$Hours)

    if ($Hours -lt 48) { return ("{0} h" -f [math]::Round($Hours, 2)) }
    return ("{0} days" -f [math]::Round($Hours / 24, 1))
}

function Get-ResolutionTimeReport {
    <#
    .SYNOPSIS
        Summarises how long the month's tickets took to resolve.
    .DESCRIPTION
        Companion to Get-FirstResponseReport, reading the JSM "Time to
        resolution" SLA field. Answering fast is not the same as finishing fast,
        and this is the half the old runbooks never covered.

        NOTE the different population. First response is measured on tickets
        CREATED in the month, because that is the question being asked ("did we
        answer the new ones"). Resolution time is measured on tickets RESOLVED in
        the month, because a ticket created in July and closed in August belongs
        to August's throughput - and counting by creation date would leave the
        most recent month permanently understated as its slow tickets are still
        open.
    .PARAMETER Month
        A range object from Get-ReportMonth.
    .OUTPUTS
        PSCustomObject with Available, Resolved, MetGoal, Breached,
        AverageHours, MedianHours and Slowest.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Month)

    $slaId = Get-JiraFieldId -Name 'Time to resolution'
    if (-not $slaId) {
        return [pscustomobject]@{
            Available = $false
            Reason    = "This Jira has no 'Time to resolution' SLA field."
        }
    }

    $jql = "project = $script:ProjectKey" +
           " AND resolutiondate >= `"$($Month.JqlStart)`"" +
           " AND resolutiondate <= `"$($Month.JqlEnd)`"" +
           " ORDER BY resolutiondate ASC"

    Write-Host "  Fetching resolution times..." -ForegroundColor DarkGray
    $issues = @(Get-IssueByJql -Jql $jql -Fields "summary,created,status,assignee,resolutiondate,$slaId")

    $hours    = @()
    $metGoal  = 0
    $breached = 0
    $noData   = 0
    $detail   = @()

    foreach ($issue in $issues) {
        $sla = $issue.fields.$slaId
        $cycle = $null
        if ($sla -and $sla.completedCycles -and @($sla.completedCycles).Count -gt 0) {
            # Last completed cycle: a reopened ticket runs the clock more than
            # once, and the final pass is the one that actually finished it.
            $cycles = @($sla.completedCycles)
            $cycle  = $cycles[$cycles.Count - 1]
        }
        if (-not $cycle) { $noData++; continue }

        $elapsedHours = [math]::Round($cycle.elapsedTime.millis / 3600000, 2)
        $hours += $elapsedHours
        if ($cycle.breached) { $breached++ } else { $metGoal++ }

        $detail += [pscustomobject]@{
            Key          = $issue.key
            Summary      = $issue.fields.summary
            Assignee     = $issue.fields.assignee.displayName
            Resolved     = $issue.fields.resolutiondate
            ElapsedHours = $elapsedHours
            GoalHours    = [math]::Round($cycle.goalDuration.millis / 3600000, 2)
            Breached     = [bool]$cycle.breached
        }
    }

    $measured = $hours.Count
    return [pscustomobject]@{
        Available    = $true
        Month        = $Month
        Jql          = $jql
        Resolved     = $issues.Count
        Measured     = $measured
        NoData       = $noData
        MetGoal      = $metGoal
        MetGoalPct   = Get-SafePercent -Part $metGoal -Whole $measured
        Breached     = $breached
        BreachedPct  = Get-SafePercent -Part $breached -Whole $measured
        AverageHours = $(if ($measured -gt 0) { [math]::Round(($hours | Measure-Object -Average).Average, 2) } else { 0 })
        MedianHours  = [math]::Round((Get-MedianValue -Values $hours), 2)
        Slowest      = @($detail | Sort-Object ElapsedHours -Descending | Select-Object -First 5)
        Detail       = $detail
    }
}

function Show-ResolutionTimeReport {
    <#
    .SYNOPSIS
        Prints the resolution-time summary to the console.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Report)

    Write-Host ""
    Write-Host "  TIME TO RESOLUTION" -ForegroundColor Cyan
    Write-Host ("  " + ("-" * 62)) -ForegroundColor DarkGray

    if (-not $Report.Available) {
        Write-Host "  $($Report.Reason)" -ForegroundColor Yellow
        return
    }
    if ($Report.Measured -eq 0) {
        Write-Host "  No tickets with a completed resolution clock this month." -ForegroundColor Yellow
        return
    }

    $goalColor = if ($Report.MetGoalPct -ge 90) { 'Green' } elseif ($Report.MetGoalPct -ge 75) { 'Yellow' } else { 'Red' }
    Write-Host ("  Tickets resolved   : {0}" -f $Report.Resolved) -ForegroundColor White
    Write-Host ("  Met the Jira SLA   : {0} ({1}%)" -f $Report.MetGoal, $Report.MetGoalPct) -ForegroundColor $goalColor
    Write-Host ("  Breached SLA       : {0} ({1}%)" -f $Report.Breached, $Report.BreachedPct) -ForegroundColor $(if ($Report.Breached -gt 0) { 'DarkYellow' } else { 'Gray' })
    Write-Host ("  Median to resolve  : {0}" -f (Format-DurationHours $Report.MedianHours)) -ForegroundColor Gray
    Write-Host ("  Average to resolve : {0}" -f (Format-DurationHours $Report.AverageHours)) -ForegroundColor DarkGray
    if ($Report.NoData -gt 0) {
        Write-Host ("  {0} resolved ticket(s) had no resolution clock and were left out." -f $Report.NoData) -ForegroundColor DarkGray
    }

    if ($Report.Slowest.Count -gt 0) {
        Write-Host ""
        Write-Host "  Longest running:" -ForegroundColor DarkCyan
        foreach ($s in $Report.Slowest) {
            Write-Host ("    {0}  {1}  {2}" -f (Format-Cell $s.Key 12), (Format-Cell $s.Summary 34), (Format-DurationHours $s.ElapsedHours)) -ForegroundColor Gray
        }
    }
}

# ===========================================================================
# REPORT 2d - PHISHING SIMULATION
# ===========================================================================
function Get-PhishingReport {
    <#
    .SYNOPSIS
        Gets the month's phishing simulation percentages.
    .DESCRIPTION
        The runbook reads these from security.microsoft.com by hand: the percent
        of users compromised (clicked the link, opened the attachment, or
        entered credentials) and the percent who reported the mail.

        Microsoft exposes the same data through Graph at
        /security/attackSimulation, but that needs the Microsoft.Graph module
        installed AND an administrator to consent to AttackSimulation.Read.All
        for the Graph PowerShell app. Neither is set up on this machine yet, so
        this function tries Graph first and falls back to asking for the two
        numbers, keeping the rest of the report automatic either way.
    .PARAMETER Month
        A range object from Get-ReportMonth.
    .PARAMETER NoPrompt
        Skip the manual fallback and just report that it is unavailable. Used
        when generating a report unattended.
    .OUTPUTS
        PSCustomObject with Available, Source, SimulationName, CompromisedPct,
        ReportedPct.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Month,
        [switch]$NoPrompt
    )

    $unavailable = [pscustomobject]@{
        Available      = $false
        Source         = 'none'
        SimulationName = $null
        CompromisedPct = $null
        ReportedPct    = $null
        Reason         = $null
    }

    $haveGraph = [bool](Get-Module -ListAvailable -Name Microsoft.Graph.Authentication -ErrorAction SilentlyContinue)
    if ($haveGraph) {
        try {
            if (-not (Get-MgContext -ErrorAction SilentlyContinue)) {
                Write-Host "  Connecting to Microsoft Graph for phishing results..." -ForegroundColor DarkGray
                Connect-MgGraph -Scopes 'AttackSimulation.Read.All' -NoWelcome -ErrorAction Stop
            }
            $sims = Invoke-MgGraphRequest -Method GET `
                -Uri 'https://graph.microsoft.com/beta/security/attackSimulation/simulations' -ErrorAction Stop

            $match = @($sims.value | Where-Object {
                $_.completionDateTime -and
                ([datetime]$_.completionDateTime) -ge $Month.Start -and
                ([datetime]$_.completionDateTime) -le $Month.End
            }) | Select-Object -First 1

            if ($match) {
                $overview = Invoke-MgGraphRequest -Method GET `
                    -Uri "https://graph.microsoft.com/beta/security/attackSimulation/simulations/$($match.id)/report/overview" -ErrorAction Stop
                $resolved    = [double]$overview.resolvedTargetsCount
                $compromised = [double]$overview.simulationEventsContent.compromisedUserCount
                $reported    = [double]$overview.simulationEventsContent.reportedUserCount
                return [pscustomobject]@{
                    Available      = $true
                    Source         = 'graph'
                    SimulationName = $match.displayName
                    CompromisedPct = Get-SafePercent -Part $compromised -Whole $resolved
                    ReportedPct    = Get-SafePercent -Part $reported -Whole $resolved
                    Reason         = $null
                }
            }
            $unavailable.Reason = "No phishing simulation completed in $($Month.Label)."
            return $unavailable
        }
        catch {
            $unavailable.Reason = "Graph lookup failed: $($_.Exception.Message)"
        }
    }
    else {
        $unavailable.Reason = "Microsoft.Graph is not installed, so the phishing numbers cannot be pulled automatically."
    }

    if ($NoPrompt) { return $unavailable }

    Write-Host ""
    Write-Host "  Phishing simulation - $($unavailable.Reason)" -ForegroundColor DarkYellow
    Write-Host "  Read the two percentages from security.microsoft.com" -ForegroundColor DarkGray
    Write-Host "  (Email & collaboration > Attack simulation training > Simulations)," -ForegroundColor DarkGray
    Write-Host "  or press Enter twice to leave them out of the report." -ForegroundColor DarkGray

    $name = (Read-Host "    Simulation name (optional)").Trim()
    $comp = (Read-Host "    Percent of compromised users").Trim() -replace '%', ''
    $rept = (Read-Host "    Percent of reporting users").Trim() -replace '%', ''

    $compVal = 0.0
    $reptVal = 0.0
    if (-not [double]::TryParse($comp, [ref]$compVal) -or -not [double]::TryParse($rept, [ref]$reptVal)) {
        Write-Host "  Skipping the phishing section." -ForegroundColor DarkGray
        return $unavailable
    }

    return [pscustomobject]@{
        Available      = $true
        Source         = 'manual'
        SimulationName = $(if ($name) { $name } else { "$($Month.Label) simulation" })
        CompromisedPct = $compVal
        ReportedPct    = $reptVal
        Reason         = $null
    }
}

function Show-PhishingReport {
    <#
    .SYNOPSIS
        Prints the phishing simulation percentages to the console.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Report)

    Write-Host ""
    Write-Host "  PHISHING SIMULATION" -ForegroundColor Cyan
    Write-Host ("  " + ("-" * 62)) -ForegroundColor DarkGray

    if (-not $Report.Available) {
        Write-Host "  Not included. $($Report.Reason)" -ForegroundColor Yellow
        return
    }

    $compColor = if ($Report.CompromisedPct -le 5) { 'Green' } elseif ($Report.CompromisedPct -le 15) { 'Yellow' } else { 'Red' }
    $reptColor = if ($Report.ReportedPct -ge 50) { 'Green' } elseif ($Report.ReportedPct -ge 25) { 'Yellow' } else { 'Red' }
    Write-Host ("  Simulation       : {0}" -f $Report.SimulationName) -ForegroundColor White
    Write-Host ("  Compromised users: {0}%" -f $Report.CompromisedPct) -ForegroundColor $compColor
    Write-Host ("  Reporting users  : {0}%" -f $Report.ReportedPct) -ForegroundColor $reptColor
    if ($Report.Source -eq 'manual') {
        Write-Host "  (entered by hand from security.microsoft.com)" -ForegroundColor DarkGray
    }
}

# ===========================================================================
# EXPORT
# ===========================================================================
function Export-MonthlyReport {
    <#
    .SYNOPSIS
        Writes the month's reports to CSV and to a pasteable HTML summary.
    .DESCRIPTION
        Three files land in output\Reports\Monthly\<YYYY-MM>\ - one folder per
        month, so a run's files stay together:
          Summary.html  a formatted summary to paste into the monthly report
                        or an email to Accounts Payable
          Sites.csv     the tickets-per-site table (the pivot table's result)
          Tickets.csv   every ticket counted, so the numbers can be checked

        The HTML is deliberately plain with inline styles, because Outlook and
        Word strip stylesheets when you paste into them.
    .PARAMETER TicketReport
        Output of Get-TicketNumberReport.
    .PARAMETER CsatReport
        Output of Get-CsatReport (optional).
    .PARAMETER ResponseReport
        Output of Get-FirstResponseReport (optional).
    .PARAMETER ResolutionReport
        Output of Get-ResolutionTimeReport (optional).
    .PARAMETER PhishingReport
        Output of Get-PhishingReport (optional).
    .OUTPUTS
        PSCustomObject with the three file paths.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$TicketReport,
        $CsatReport,
        $ResponseReport,
        $ResolutionReport,
        $PhishingReport
    )

    $dir      = Get-ReportFolder -Month $TicketReport.Month
    $sitesCsv = Join-Path $dir 'Sites.csv'
    $tickCsv  = Join-Path $dir 'Tickets.csv'
    $htmlPath = Join-Path $dir 'Summary.html'

    $TicketReport.Rows   | Export-Csv -Path $sitesCsv -NoTypeInformation -Encoding UTF8
    $TicketReport.Issues | Export-Csv -Path $tickCsv  -NoTypeInformation -Encoding UTF8

    $th = 'style="text-align:left;padding:6px 10px;border:1px solid #ccc;background:#f2f2f2;font-family:Segoe UI,Arial,sans-serif;font-size:13px"'
    $td = 'style="padding:6px 10px;border:1px solid #ccc;font-family:Segoe UI,Arial,sans-serif;font-size:13px"'

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("<div style='font-family:Segoe UI,Arial,sans-serif'>")
    [void]$sb.AppendLine("<h2>IT Monthly Report - $($TicketReport.Month.Label)</h2>")

    # --- metrics summary ---
    [void]$sb.AppendLine("<h3>Metrics</h3><table style='border-collapse:collapse'>")
    if ($CsatReport -and $CsatReport.Available -and $CsatReport.Count -gt 0) {
        [void]$sb.AppendLine("<tr><td $td>Average satisfaction</td><td $td><b>$($CsatReport.Average) / 5</b> (from $($CsatReport.Count) surveys)</td></tr>")
    }
    if ($ResponseReport -and $ResponseReport.Available -and $ResponseReport.Responded -gt 0) {
        [void]$sb.AppendLine("<tr><td $td>Answered within $($ResponseReport.TargetHours)h</td><td $td><b>$($ResponseReport.WithinTargetPct)%</b> of $($ResponseReport.Responded) tickets</td></tr>")
        [void]$sb.AppendLine("<tr><td $td>Median first response</td><td $td>$($ResponseReport.MedianHours) hours</td></tr>")
    }
    if ($ResolutionReport -and $ResolutionReport.Available -and $ResolutionReport.Measured -gt 0) {
        [void]$sb.AppendLine("<tr><td $td>Resolved within SLA</td><td $td><b>$($ResolutionReport.MetGoalPct)%</b> of $($ResolutionReport.Resolved) tickets</td></tr>")
        [void]$sb.AppendLine("<tr><td $td>Median time to resolve</td><td $td>$(Format-DurationHours $ResolutionReport.MedianHours)</td></tr>")
    }
    if ($PhishingReport -and $PhishingReport.Available) {
        [void]$sb.AppendLine("<tr><td $td>Phishing - compromised</td><td $td><b>$($PhishingReport.CompromisedPct)%</b></td></tr>")
        [void]$sb.AppendLine("<tr><td $td>Phishing - reported</td><td $td><b>$($PhishingReport.ReportedPct)%</b></td></tr>")
    }
    [void]$sb.AppendLine("<tr><td $td>Tickets handled</td><td $td><b>$($TicketReport.Total)</b> across $($TicketReport.SiteCount) sites</td></tr>")
    [void]$sb.AppendLine("</table>")

    # --- per-site table ---
    [void]$sb.AppendLine("<h3>Tickets by site</h3><table style='border-collapse:collapse'>")
    [void]$sb.AppendLine("<tr><th $th>Site</th><th $th>Tickets</th><th $th>Share</th></tr>")
    foreach ($row in $TicketReport.Rows) {
        $site = [System.Net.WebUtility]::HtmlEncode($row.Site)
        [void]$sb.AppendLine("<tr><td $td>$site</td><td $td>$($row.Count)</td><td $td>$($row.Percent)%</td></tr>")
    }
    [void]$sb.AppendLine("<tr><td $td><b>Total</b></td><td $td><b>$($TicketReport.Total)</b></td><td $td></td></tr>")
    [void]$sb.AppendLine("</table>")

    if ($CsatReport -and $CsatReport.Available -and $CsatReport.Comments.Count -gt 0) {
        [void]$sb.AppendLine("<h3>Survey comments</h3><ul>")
        foreach ($c in $CsatReport.Comments) {
            $txt = [System.Net.WebUtility]::HtmlEncode($c.Comment)
            [void]$sb.AppendLine("<li style='font-size:13px'><b>$($c.Rating)/5</b> ($($c.Key), $([System.Net.WebUtility]::HtmlEncode($c.Agent))): $txt</li>")
        }
        [void]$sb.AppendLine("</ul>")
    }

    [void]$sb.AppendLine("<p style='color:#777;font-size:11px'>Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') from Jira. Excluded statuses: $(($TicketReport.ExcludedStatuses -join ', ')).</p>")
    [void]$sb.AppendLine("</div>")

    $sb.ToString() | Out-File -FilePath $htmlPath -Encoding utf8

    return [pscustomobject]@{
        Folder     = $dir
        SitesCsv   = $sitesCsv
        TicketsCsv = $tickCsv
        Html       = $htmlPath
    }
}

# ===========================================================================
# MENU
# ===========================================================================
function Invoke-MonthlyReports {
    <#
    .SYNOPSIS
        Interactive menu for the monthly reporting pack.
    .DESCRIPTION
        Wraps the two runbooks. Everything is read-only; the only thing written
        is the report files in output\.
    #>
    [CmdletBinding()]
    param()

    $monthsBack = 1
    :reportMenu while ($true) {
        $month = Get-ReportMonth -MonthsBack $monthsBack

        if (Get-Command Write-ToolHeader -ErrorAction SilentlyContinue) {
            Write-ToolHeader "Monthly reports - $($month.Label)"
        } else {
            Write-Host "`n=== MONTHLY REPORTS - $($month.Label) ===" -ForegroundColor Cyan
        }
        Write-Host "  1) Ticket numbers by site      (Monthly Ticket Numbers)" -ForegroundColor Gray
        Write-Host "  2) IT metrics                  (CSAT + first response + phishing)" -ForegroundColor Gray
        Write-Host "  3) Full pack + export files    (everything, written to output\)" -ForegroundColor Gray
        Write-Host "  4) Change month                (currently $($month.Label))" -ForegroundColor DarkGray
        Write-Host "  B) Back" -ForegroundColor DarkGray
        Write-Host ""

        $choice = (Read-Host "  Select").Trim().ToUpper()
        switch ($choice) {
            "1" {
                $t = Get-TicketNumberReport -Month $month
                Show-TicketNumberReport -Report $t
                Read-Host "`n  Enter to continue" | Out-Null
            }
            "2" {
                $c = Get-CsatReport -Month $month
                Show-CsatReport -Report $c
                $f = Get-FirstResponseReport -Month $month
                Show-FirstResponseReport -Report $f
                $r = Get-ResolutionTimeReport -Month $month
                Show-ResolutionTimeReport -Report $r
                $p = Get-PhishingReport -Month $month
                Show-PhishingReport -Report $p
                Read-Host "`n  Enter to continue" | Out-Null
            }
            "3" {
                $t = Get-TicketNumberReport -Month $month
                Show-TicketNumberReport -Report $t
                $c = Get-CsatReport -Month $month
                Show-CsatReport -Report $c
                $f = Get-FirstResponseReport -Month $month
                Show-FirstResponseReport -Report $f
                $r = Get-ResolutionTimeReport -Month $month
                Show-ResolutionTimeReport -Report $r
                $p = Get-PhishingReport -Month $month
                Show-PhishingReport -Report $p

                $out = Export-MonthlyReport -TicketReport $t -CsatReport $c -ResponseReport $f -ResolutionReport $r -PhishingReport $p
                Write-Host ""
                Write-Host "  Saved to $($out.Folder)" -ForegroundColor Green
                Write-Host "    Summary.html   paste this into the monthly report or an email" -ForegroundColor DarkCyan
                Write-Host "    Sites.csv      tickets per site" -ForegroundColor DarkCyan
                Write-Host "    Tickets.csv    every ticket counted, to check the numbers" -ForegroundColor DarkCyan
                Read-Host "`n  Enter to continue" | Out-Null
            }
            "4" {
                $answer = (Read-Host "  How many months back? (1 = last month)").Trim()
                $parsed = 0
                if ([int]::TryParse($answer, [ref]$parsed) -and $parsed -ge 0 -and $parsed -le 120) {
                    $monthsBack = $parsed
                } else {
                    Write-Host "  Enter a whole number between 0 and 120." -ForegroundColor DarkGray
                }
            }
            "B" { break reportMenu }
            default { Write-Host "  Unknown option." -ForegroundColor DarkGray }
        }
    }
}

