<#
    Interaction.ps1
    ---------------
    Interactive flow that ties data, display, and actions together:
    the single-ticket action menu, the ticket lookup, criteria search, and the
    list browser. These functions drive the console; they read input and call
    the lower layers.
#>

function Enter-Ticket {
    <#
    .SYNOPSIS
        Shows one ticket (header, attachments, thread) and its action menu.
    .DESCRIPTION
        Loops until the user goes back. Offers reply / internal note / assign /
        close / open-in-browser / refresh. Returns to the caller when the user
        presses [B] or after a successful close.
    .PARAMETER Issue
        The issue object to display (as returned by Get-Ticket / Get-*Tickets).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Issue)

    # Refetch the full issue so we have renderedFields (the description). Tickets
    # opened from a list only carry the search fields, not the rendered body.
    $full = Get-Ticket -Key $Issue.key
    if ($full) { $Issue = $full }
    $key = $Issue.key

    while ($true) {
        $assignee = if ($Issue.fields.assignee) { $Issue.fields.assignee.displayName } else { "Unassigned" }

        Write-Host ""
        # Organizations (JSM service-desk field). Blank on many tickets.
        $orgNames = ''
        if ($script:OrgFieldId) {
            $prop = $Issue.fields.PSObject.Properties[$script:OrgFieldId]
            if ($prop) { $orgNames = (@($prop.Value) | ForEach-Object { if ($_.name) { $_.name } else { $_ } }) -join ', ' }
        }
        $orgSet   = -not [string]::IsNullOrWhiteSpace($orgNames)
        if (-not $orgSet) { $orgNames = '(none set on this ticket)' }
        $orgColor = if ($orgSet) { 'DarkCyan' } else { 'Red' }   # red when no organization

        Write-Host "=== $key : $($Issue.fields.summary) ===" -ForegroundColor Cyan
        Write-Host "    Status: $($Issue.fields.status.name)   |   Assignee: $assignee" -ForegroundColor DarkCyan
        Write-Host "    Organizations: $orgNames" -ForegroundColor $orgColor
        Write-Host "    $script:BaseUrl/browse/$key" -ForegroundColor DarkCyan

        $attachments = @($Issue.fields.attachment)
        if ($attachments.Count -gt 0) {
            Write-Host "    ATTACHMENTS ($($attachments.Count)) - press [O] to open the ticket in your browser to view:" -ForegroundColor Magenta
            foreach ($a in $attachments) {
                $tag = if ($a.mimeType -like 'image/*') { "[image]" } else { "[file] " }
                Write-Host "      $tag $($a.filename)" -ForegroundColor Magenta
            }
        }

        $description = if ($Issue.renderedFields) { Convert-HtmlToText $Issue.renderedFields.description } else { "" }
        Write-Host ""
        Write-Host "----- Description -------------------------------------------------" -ForegroundColor Cyan
        if ([string]::IsNullOrWhiteSpace($description)) {
            Write-Host "    (No description provided.)" -ForegroundColor DarkGray
        } else {
            foreach ($line in ($description -split "`n")) {
                Write-Host "    $line" -ForegroundColor Gray
            }
        }

        Show-TicketComment -Key $key

        # Missing-organization reminder, repeated at the VERY BOTTOM (below all the
        # ticket details) so it can't be scrolled past. Easy to miss up in the
        # header; here it's the last thing before the actions prompt.
        if (-not $orgSet) {
            Write-Host ""
            Write-Host "  ****************************************************************" -ForegroundColor Red
            Write-Host "  *  NO ORGANIZATION SET ON $key" -ForegroundColor Red
            Write-Host "  *  Set it before closing (option 4 'Fix missing organizations'" -ForegroundColor Red
            Write-Host "  *  in the console menu, or set it in the browser with [O])." -ForegroundColor Red
            Write-Host "  ****************************************************************" -ForegroundColor Red
        }

        Write-Host ""
        Write-Host "Actions:  [R] Reply   [I] Internal note   [A] Assign to me   [T] Re-assign to teammate   [C] Close (Done/Resolved)   [O] Open in browser   [M] ManageEngine   [V] Refresh   [B] Back" -ForegroundColor White
        $choice = (Read-Host "Choose").Trim().ToUpper()

        switch ($choice) {
            "R" {
                $msg = Read-MultiLine "Reply to CUSTOMER (this is PUBLIC and visible to them):"
                if ([string]::IsNullOrWhiteSpace($msg)) { Write-Host "Empty - cancelled." -ForegroundColor DarkGray; continue }
                Write-Host ""
                Write-Host "This will be sent to the CUSTOMER on $key. Send it? (y/n)" -ForegroundColor Yellow
                if ((Read-Host).Trim().ToUpper() -eq "Y") { Add-JiraComment -Key $key -Body $msg -Public $true }
                else { Write-Host "Cancelled." -ForegroundColor DarkGray }
            }
            "I" {
                $msg = Read-MultiLine "Internal note (only staff can see this):"
                if ([string]::IsNullOrWhiteSpace($msg)) { Write-Host "Empty - cancelled." -ForegroundColor DarkGray; continue }
                Add-JiraComment -Key $key -Body $msg -Public $false
            }
            "A" {
                if (Set-TicketAssignedToMe -Key $key) {
                    $refreshed = Get-Ticket -Key $key
                    if ($refreshed) { $Issue = $refreshed }
                }
            }
            "T" {
                if (Set-TicketAssignee -Key $key) {
                    $refreshed = Get-Ticket -Key $key
                    if ($refreshed) { $Issue = $refreshed }
                }
            }
            "C" {
                if (Complete-Ticket -Key $key) {
                    Write-Host "Returning to the ticket list..." -ForegroundColor DarkGray
                    return   # back to the list, which re-fetches without this ticket
                }
                $refreshed = Get-Ticket -Key $key
                if ($refreshed) { $Issue = $refreshed }
            }
            "O" {
                $url = "$script:BaseUrl/browse/$key"
                Start-Process $url
                Write-Host "Opened $url in your browser." -ForegroundColor Green
            }
            "M" {
                if ($script:ManageEngineUrl) {
                    Start-Process $script:ManageEngineUrl
                    Write-Host "Opened ManageEngine remote control in your browser." -ForegroundColor Green
                }
                else {
                    Write-Host "No ManageEngine URL configured - set MANAGEENGINE_URL to enable this." -ForegroundColor Yellow
                }
            }
            "V" {
                $refreshed = Get-Ticket -Key $key
                if ($refreshed) { $Issue = $refreshed }
            }
            "B" { return }
            default { Write-Host "Unknown option." -ForegroundColor DarkGray }
        }
    }
}

function Invoke-TicketLookup {
    <#
    .SYNOPSIS
        Opens a single ticket by key or bare number.
    .DESCRIPTION
        A bare number is assumed to be in the configured project, so "5592"
        resolves to "ITSD-5592". A full key like "ITSD-5592" (any case) is used
        as-is. If the ticket loads, it opens in the single-ticket view.

        This is the direct-key fast path used by the search feature; pass -Query
        to skip the prompt (e.g. when the key was already typed elsewhere).
    .PARAMETER Query
        The key or number to open. If omitted, the user is prompted for it.
    #>
    [CmdletBinding()]
    param([string]$Query)

    $q = if ($PSBoundParameters.ContainsKey('Query')) { $Query } else { Read-Host "Enter ticket key or number (e.g. ITSD-5592 or 5592)" }
    $q = "$q".Trim().ToUpper()
    if ([string]::IsNullOrWhiteSpace($q)) { return }
    if ($q -match '^\d+$') { $q = "$script:ProjectKey-$q" }   # bare number -> PROJECT-number

    $issue = Get-Ticket -Key $q
    if ($issue) { Enter-Ticket -Issue $issue }
}

function Resolve-JiraUserAccount {
    <#
    .SYNOPSIS
        Searches Jira for a typed name/email and returns one accountId (or $null).
    .DESCRIPTION
        On a single match, uses it. On several, shows a numbered list to pick from.
        Returns $null if nothing matched or the user skipped. Does not prompt for
        the query itself - the caller passes what was typed.
    .PARAMETER Query
        The name or email the user typed.
    .OUTPUTS
        System.String accountId, or $null.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Query)

    $users = @(Find-JiraUser -Query $Query | Where-Object { $_.active -ne $false })
    if ($users.Count -eq 0) { Write-Host "  No Jira user matched '$Query' - filter ignored." -ForegroundColor Yellow; return $null }
    if ($users.Count -eq 1) {
        Write-Host "  Using $($users[0].displayName) <$($users[0].emailAddress)>" -ForegroundColor DarkGreen
        return $users[0].accountId
    }
    Write-Host "  Multiple matches for '$Query':" -ForegroundColor Cyan
    for ($i = 0; $i -lt $users.Count; $i++) {
        Write-Host ("    {0}) {1}  <{2}>" -f ($i + 1), $users[$i].displayName, $users[$i].emailAddress)
    }
    $p = 0
    if ([int]::TryParse((Read-Host "  Number (blank = skip)"), [ref]$p) -and $p -ge 1 -and $p -le $users.Count) {
        return $users[$p - 1].accountId
    }
    Write-Host "  Skipped." -ForegroundColor DarkGray
    return $null
}

function Invoke-TicketSearch {
    <#
    .SYNOPSIS
        Find tickets: open one directly by key/number, or search by any mix of
        criteria (summary/text keyword, reporter, assignee, status, priority,
        recency). Results open in the browser.
    .DESCRIPTION
        First offers a direct key/number lookup (the fast path for a known
        ticket). If that is left blank, it walks each filter in turn - press
        ENTER to skip any of them. The chosen
        filters are combined (AND) into a JQL query with ConvertTo-TicketJql, the JQL
        is shown for transparency, and the matches open in the normal ticket
        browser (so you can view/act on any result). Skipping everything with no
        project scope is allowed but confirmed first, since it matches every
        ticket in Jira.
    #>
    [CmdletBinding()]
    param()

    Write-Host ""
    Write-Host "SEARCH TICKETS - press ENTER to skip any field." -ForegroundColor Cyan

    # --- Fast path: a specific ticket key or number opens it directly, skipping
    # the rest of the criteria (this absorbs the old "look up a ticket" option).
    $keyLookup = (Read-Host "  Ticket key or number to open directly (e.g. ITSD-5592 or 5592), or ENTER to search").Trim()
    if ($keyLookup) { Invoke-TicketLookup -Query $keyLookup; return }

    # --- Keyword filters
    $summary = (Read-Host "  Keyword in the summary / subject line").Trim()
    $text    = (Read-Host "  Keyword anywhere in the ticket text").Trim()

    # --- Reporter
    $reporterInput = (Read-Host "  Reporter name or email").Trim()
    $reporterId = if ($reporterInput) { Resolve-JiraUserAccount -Query $reporterInput } else { $null }

    # --- Assignee (with shortcuts for me / unassigned)
    $assigneeAns  = (Read-Host "  Assignee: [M]e, [U]nassigned, a name/email, or ENTER for any").Trim()
    $assigneeMode = ''
    $assigneeId   = $null
    switch ($assigneeAns.ToUpper()) {
        ''  { }
        'M' { $assigneeMode = 'Me' }
        'U' { $assigneeMode = 'Unassigned' }
        default {
            $id = Resolve-JiraUserAccount -Query $assigneeAns
            if ($id) { $assigneeMode = 'User'; $assigneeId = $id }
        }
    }

    # --- Status: category shortcuts, or one/more specific statuses (comma list)
    Write-Host "  Status filter:" -ForegroundColor DarkCyan
    Write-Host "    1) Open  - anything not done"
    Write-Host "    2) Done  - resolved / closed / canceled"
    Write-Host "    --- or pick specific status(es) ---"
    for ($i = 0; $i -lt $script:StatusOrder.Count; $i++) {
        Write-Host ("    {0}) {1}" -f ($i + 3), $script:StatusOrder[$i])
    }
    $statusAns = (Read-Host "  Number(s), comma-separated (ENTER = any)").Trim()
    $statuses = @(); $statusCategory = ''
    if ($statusAns) {
        foreach ($pk in @($statusAns -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })) {
            $n = 0
            if ([int]::TryParse($pk, [ref]$n)) {
                if     ($n -eq 1) { $statusCategory = 'Open' }
                elseif ($n -eq 2) { $statusCategory = 'Done' }
                elseif ($n -ge 3 -and $n -le ($script:StatusOrder.Count + 2)) { $statuses += $script:StatusOrder[$n - 3] }
            }
        }
        if ($statuses.Count -gt 0) { $statusCategory = '' }   # specific statuses win over a category
    }

    # --- Priority
    Write-Host "  Priority filter:" -ForegroundColor DarkCyan
    $priorities = @('Highest', 'High', 'Medium', 'Low', 'Lowest')
    for ($i = 0; $i -lt $priorities.Count; $i++) { Write-Host ("    {0}) {1}" -f ($i + 1), $priorities[$i]) }
    $priority = ''
    $pn = 0
    if ([int]::TryParse((Read-Host "  Number (ENTER = any)").Trim(), [ref]$pn) -and $pn -ge 1 -and $pn -le $priorities.Count) {
        $priority = $priorities[$pn - 1]
    }

    # --- Recency
    $createdDays = 0; $updatedDays = 0
    [int]::TryParse((Read-Host "  Created within how many days? (ENTER = any)").Trim(), [ref]$createdDays) | Out-Null
    [int]::TryParse((Read-Host "  Updated within how many days? (ENTER = any)").Trim(), [ref]$updatedDays) | Out-Null

    # --- Project scope (defaults to the configured project)
    $projAns = (Read-Host "  Project key (ENTER = $script:ProjectKey, * = all projects)").Trim()
    $project =
        if ($projAns -eq '*' -or $projAns -match '^(?i:all)$') { '' }
        elseif ($projAns) { $projAns.ToUpper() }
        else { $script:ProjectKey }

    # --- Build the query
    $jql = ConvertTo-TicketJql -Project $project -ReporterAccountId $reporterId `
        -AssigneeMode $assigneeMode -AssigneeAccountId $assigneeId `
        -SummaryKeyword $summary -TextKeyword $text `
        -Statuses $statuses -StatusCategory $statusCategory -Priority $priority `
        -CreatedWithinDays $createdDays -UpdatedWithinDays $updatedDays

    # Guard the "matches everything" case (all projects, no other filter).
    $hasFilter = $reporterId -or $assigneeMode -or $summary -or $text -or `
                 $statuses.Count -gt 0 -or $statusCategory -or $priority -or `
                 $createdDays -gt 0 -or $updatedDays -gt 0
    if (-not $project -and -not $hasFilter) {
        Write-Host "No filters set - this matches EVERY ticket in Jira and may be slow." -ForegroundColor Yellow
        if ((Read-Host "Continue? (y/n)").Trim().ToUpper() -ne 'Y') { Write-Host "Cancelled." -ForegroundColor DarkGray; return }
    }

    Write-Host ""
    Write-Host "JQL: $jql" -ForegroundColor DarkGray

    # Stash the query so the browser's fetch scriptblock can re-run it on refresh.
    $script:SearchJql = $jql
    Invoke-TicketBrowser -Fetch { Get-IssueByJql -Jql $script:SearchJql } -Title "Search results - select to view"
}

function Read-InputWithTimeout {
    <#
    .SYNOPSIS
        Reads a typed line (you press Enter to confirm), but gives up after a
        timeout so the caller can auto-refresh. Returns the text, '' for a bare
        Enter, or $null if the timeout elapsed with no keypress. Falls back to a
        normal blocking read on hosts without a console.
    .PARAMETER TimeoutSeconds
        How long to wait for the first keypress before returning $null.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$TimeoutSeconds)

    try {
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            if ([Console]::KeyAvailable) {
                # A key is waiting. Hand the whole line to Read-Host (do NOT consume
                # the key first) so normal line editing - including Backspace over
                # every character - works. The buffered keypress starts the line.
                return (Read-Host)
            }
            Start-Sleep -Milliseconds 200
        }
        return $null   # timed out - caller should refresh
    }
    catch {
        return (Read-Host)   # no pollable console - fall back to a normal read
    }
}


function Invoke-TicketBrowser {
    <#
    .SYNOPSIS
        Lists tickets and lets the user open one. Type a number and press Enter
        to open it, R to refresh, or B to go back.
    .DESCRIPTION
        Calls the -Fetch scriptblock to (re)load issues every iteration, so the
        list stays current after actions like assigning or closing.

        With -RefreshSeconds greater than 0 the list also auto-refreshes on that
        interval while it waits for input (a "live" view), so new tickets appear
        on their own.
    .PARAMETER Fetch
        A scriptblock returning the issues to show, e.g. { Get-MyTicket }.
    .PARAMETER Title
        The heading passed to Show-TicketList.
    .PARAMETER RefreshSeconds
        Auto-refresh interval in seconds. 0 (default) = no auto-refresh.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Fetch,
        [Parameter(Mandatory)][string]$Title,
        [int]$RefreshSeconds = 0
    )

    $live = $RefreshSeconds -gt 0

    while ($true) {
        if ($live) { Clear-Host }                 # redraw in place for a live view
        $issues = @(& $Fetch)
        $issues = @(Sort-TicketForDisplay -Issues $issues)   # by status priority, then age
        Show-TicketList -Issues $issues -Title $Title

        if ($live) {
            # Say "1m30s" rather than "90s" once the interval passes a minute.
            $every = if ($RefreshSeconds -ge 60) {
                $m = [int][math]::Floor($RefreshSeconds / 60); $s = $RefreshSeconds % 60
                if ($s) { "{0}m{1}s" -f $m, $s } else { "{0}m" -f $m }
            } else { "{0}s" -f $RefreshSeconds }
            Write-Host ("Live: auto-refreshing every {0}.  Type a number to open, R to refresh, or B to back, then Enter." -f $every) -ForegroundColor DarkGray
            $sel = Read-InputWithTimeout -TimeoutSeconds $RefreshSeconds
            if ($null -eq $sel) { continue }      # idle -> auto refresh
            $sel = $sel.Trim()
        }
        elseif ($issues.Count -eq 0) {
            $sel = (Read-Host "No tickets. [R] refresh or [B] back").Trim()
            if ($sel.ToUpper() -eq "R") { continue }
            return
        }
        else {
            $sel = (Read-Host "Ticket number to open, [R] refresh, or [B] back").Trim()
        }

        $selUpper = $sel.ToUpper()
        if ($selUpper -eq "B") { return }
        if ($selUpper -eq "R" -or $sel -eq "") { continue }

        $index = 0
        if ([int]::TryParse($sel, [ref]$index) -and $index -ge 1 -and $index -le $issues.Count) {
            Enter-Ticket -Issue $issues[$index - 1]
            # Jira's JQL search index is eventually consistent - a status change
            # made in the ticket may not show on an immediate re-fetch. Let it
            # settle before the loop re-queries, so the list is fresh on return.
            Start-Sleep -Seconds 2
        } else {
            Write-Host "Invalid selection." -ForegroundColor DarkGray
        }
    }
}
