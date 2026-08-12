<#
.SYNOPSIS
    Automated checks for the monthly reporting pack in
    Jira Scripts\lib\Reports.ps1.

.DESCRIPTION
    Run these with:  .\Run-Tests.ps1     (from the project root)

    WHAT THIS IS FOR
    The monthly reports replace two runbooks that used to be done by hand:
    "Monthly Ticket Numbers" and "Monthly IT Metrics". The numbers they produce
    get pasted into a report and emailed out, so a quiet mistake here is a
    mistake somebody else acts on. These tests cover the parts that decide those
    numbers: which month is being reported on, and how the maths rounds.

    NOTHING HERE TOUCHES JIRA. There is no network call and no credential. Only
    the pure functions are exercised - the ones that take values in and give
    values back. The functions that fetch from Jira are covered by running the
    report for a real month, not from here.

    HOW TO ADD A TEST
    Copy the closest 'It' block below and change it. The pattern is always:
      1. set up the situation
      2. call the helper
      3. say what you expected with 'Should'
#>

BeforeAll {
    # Load the reporting library. $PSScriptRoot is the tests folder.
    . "$PSScriptRoot\..\Jira Scripts\lib\Reports.ps1"
    . "$PSScriptRoot\..\Jira Scripts\lib\Context.ps1"
}

Describe 'Get-ReportMonth' {

    It 'defaults to last month, which is what both runbooks ask for' {
        $expected = (Get-Date -Day 1).AddMonths(-1)
        $m = Get-ReportMonth
        $m.Start.Year  | Should -Be $expected.Year
        $m.Start.Month | Should -Be $expected.Month
    }

    It 'starts at midnight on the first of the month' {
        $m = Get-ReportMonth
        $m.Start.Day    | Should -Be 1
        $m.Start.Hour   | Should -Be 0
        $m.Start.Minute | Should -Be 0
    }

    It 'ends on the last second of the last day, so nothing is missed' {
        $m = Get-ReportMonth
        # One second later must already be the next month.
        $m.End.AddSeconds(1).Day   | Should -Be 1
        $m.End.AddSeconds(1).Month | Should -Be $m.Start.AddMonths(1).Month
    }

    It 'covers the whole of a 31-day month' {
        # July has 31 days. Ask for it explicitly by counting back from today.
        $monthsBack = ((Get-Date).Year - 2026) * 12 + (Get-Date).Month - 7
        if ($monthsBack -ge 0) {
            $m = Get-ReportMonth -MonthsBack $monthsBack
            $m.Start | Should -Be ([datetime]'2026-07-01 00:00:00')
            $m.End.Day | Should -Be 31
        }
    }

    It 'handles February without inventing a 30th day' {
        $monthsBack = ((Get-Date).Year - 2026) * 12 + (Get-Date).Month - 2
        $m = Get-ReportMonth -MonthsBack $monthsBack
        $m.Start.Month | Should -Be 2
        $m.End.Day     | Should -Be 28   # 2026 is not a leap year
    }

    It 'gives the current month to date when asked for 0 back' {
        $m = Get-ReportMonth -MonthsBack 0
        $m.Start.Month | Should -Be (Get-Date).Month
        $m.Start.Year  | Should -Be (Get-Date).Year
    }

    It 'formats the JQL strings the way Jira expects' {
        $m = Get-ReportMonth
        $m.JqlStart | Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$'
        $m.JqlEnd   | Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$'
    }

    It 'produces a file-safe slug and a readable label' {
        $m = Get-ReportMonth
        $m.Slug  | Should -Match '^\d{4}-\d{2}$'
        $m.Label | Should -Match '^[A-Za-z]+ \d{4}$'
    }
}

Describe 'Get-MedianValue' {

    It 'returns the middle value of an odd-sized set' {
        Get-MedianValue -Values @(1, 5, 3) | Should -Be 3
    }

    It 'averages the two middle values of an even-sized set' {
        Get-MedianValue -Values @(1, 2, 3, 4) | Should -Be 2.5
    }

    It 'does not assume the input is already sorted' {
        Get-MedianValue -Values @(9, 1, 8, 2, 7) | Should -Be 7
    }

    It 'returns 0 for an empty set instead of dividing by nothing' {
        Get-MedianValue -Values @() | Should -Be 0
    }

    It 'copes with a single value' {
        Get-MedianValue -Values @(4.2) | Should -Be 4.2
    }

    It 'ignores an outlier that would drag the average up' {
        # This is the whole reason the report shows a median next to the
        # average: one ticket left over a weekend must not move the headline.
        $withOutlier = @(0.2, 0.3, 0.4, 0.5, 200)
        Get-MedianValue -Values $withOutlier | Should -Be 0.4
        (($withOutlier | Measure-Object -Average).Average) | Should -BeGreaterThan 40
    }
}

Describe 'Get-SafePercent' {

    It 'works out a plain percentage' {
        Get-SafePercent -Part 25 -Whole 100 | Should -Be 25
    }

    It 'rounds to one decimal place by default' {
        Get-SafePercent -Part 1 -Whole 3 | Should -Be 33.3
    }

    It 'returns 0 rather than blowing up when the total is zero' {
        # A month with no surveys must not crash the report.
        Get-SafePercent -Part 0 -Whole 0 | Should -Be 0
    }

    It 'returns 0 for a negative total' {
        Get-SafePercent -Part 5 -Whole -1 | Should -Be 0
    }

    It 'gives 100 when everything counted' {
        Get-SafePercent -Part 293 -Whole 293 | Should -Be 100
    }
}

Describe 'Format-DurationHours' {

    It 'keeps a short duration in hours' {
        Format-DurationHours 0.5 | Should -Be '0.5 h'
    }

    It 'still uses hours just under the two-day mark' {
        Format-DurationHours 47.9 | Should -Be '47.9 h'
    }

    It 'switches to days at 48 hours' {
        Format-DurationHours 48 | Should -Be '2 days'
    }

    It 'rounds days to one decimal' {
        Format-DurationHours 73.4 | Should -Be '3.1 days'
    }

    It 'renders a very long-running ticket readably' {
        # ITSD-1231 really did run this long; "2479 h" tells nobody anything.
        Format-DurationHours 2479.2 | Should -Be '103.3 days'
    }

    It 'handles zero' {
        Format-DurationHours 0 | Should -Be '0 h'
    }
}

Describe 'ConvertTo-JqlList' {

    It 'quotes a single status' {
        ConvertTo-JqlList @('Canceled') | Should -Be '"Canceled"'
    }

    It 'quotes and comma-separates several statuses' {
        ConvertTo-JqlList @('Canceled', 'Closed') | Should -Be '"Canceled","Closed"'
    }

    It 'keeps a status that contains a space in one piece' {
        ConvertTo-JqlList @('Waiting for support') | Should -Be '"Waiting for support"'
    }
}

Describe 'Get-ReportFolder' {

    BeforeAll {
        # Write into a scratch folder, never the console's real output\.
        $script:ReportOutputDir = Join-Path ([IO.Path]::GetTempPath()) "DeskSideReportTests-$(Get-Random)"
    }

    AfterAll {
        if ($script:ReportOutputDir -and (Test-Path $script:ReportOutputDir)) {
            Remove-Item $script:ReportOutputDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'gives each month its own folder under Reports\Monthly' {
        $m = Get-ReportMonth
        $dir = Get-ReportFolder -Month $m
        $dir | Should -BeLike "*Reports\Monthly\$($m.Slug)"
    }

    It 'creates the folder so the export can write straight into it' {
        $dir = Get-ReportFolder -Month (Get-ReportMonth)
        Test-Path $dir | Should -BeTrue
    }

    It 'keeps two different months apart' {
        $a = Get-ReportFolder -Month (Get-ReportMonth -MonthsBack 1)
        $b = Get-ReportFolder -Month (Get-ReportMonth -MonthsBack 2)
        $a | Should -Not -Be $b
    }

    It 'is safe to call twice for the same month' {
        $m = Get-ReportMonth
        $first  = Get-ReportFolder -Month $m
        $second = Get-ReportFolder -Month $m
        $second | Should -Be $first
    }
}

Describe 'Get-JiraFieldId' {

    BeforeEach {
        # Stand in for what Initialize-JiraContext caches. A flat list of
        # field objects, exactly as the report code expects to find it.
        $script:AllFields = @(
            [pscustomobject]@{ id = 'customfield_10002'; name = 'Organizations' }
            [pscustomobject]@{ id = 'customfield_10025'; name = 'Satisfaction' }
            [pscustomobject]@{ id = 'customfield_10026'; name = 'Satisfaction date' }
            [pscustomobject]@{ id = 'customfield_10043'; name = 'Time to first response' }
        )
    }

    It 'finds a field by the name shown in Jira' {
        Get-JiraFieldId -Name 'Satisfaction' | Should -Be 'customfield_10025'
    }

    It 'tells apart two fields whose names share a prefix' {
        # 'Satisfaction' must not match 'Satisfaction date'.
        Get-JiraFieldId -Name 'Satisfaction date' | Should -Be 'customfield_10026'
    }

    It 'returns exactly ONE id, never a collection' {
        # This is the bug that made the first run of the report come back empty:
        # when the cached field list was nested, every lookup returned all 170
        # ids at once, which were then pasted into the fields= query and
        # silently ignored by Jira. A field id must always be a single string.
        $id = Get-JiraFieldId -Name 'Organizations'
        @($id).Count | Should -Be 1
        $id          | Should -BeOfType [string]
        $id          | Should -Not -Match '\s'
    }

    It 'returns nothing when this Jira has no such field' {
        # A site without CSAT must skip that metric, not error.
        Get-JiraFieldId -Name 'Not A Real Field' | Should -BeNullOrEmpty
    }

    It 'returns nothing when the field list was never loaded' {
        $script:AllFields = @()
        Get-JiraFieldId -Name 'Satisfaction' | Should -BeNullOrEmpty
    }
}
