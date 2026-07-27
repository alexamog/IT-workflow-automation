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

function Invoke-FixMissingOrgs {
    <#
    .SYNOPSIS
        Finds tickets with no Organization and proposes one - first from the
        reporter's OWN past tickets, then (if they have none) from their AD
        department. Nothing is changed without your confirmation.
    .DESCRIPTION
        For every open ticket (optionally all tickets) whose Organizations field
        is empty:
          1. Looks at the reporter's own previous tickets that already have an
             organization and suggests the one they use most. Their own history is
             the strongest signal, so this is tried first.
          2. If the reporter has no org-assigned history, falls back to their AD
             "Department" and the correlation map in data\org-dept-map.json.
          3. Shows the suggestion plus any alternates. You choose to set the
             suggestion, pick an alternate, search all organizations, skip, or quit.
          4. If neither source yields a candidate, it notifies you and moves on
             WITHOUT changing anything.

        The AD fallback needs the ActiveDirectory module and the mapping file, but
        the history path works without them. The Jira organization list is fetched
        once to resolve names to ids for the update.
    #>
    [CmdletBinding()]
    param()

    # --- 1. Correlation map (Dept -> ranked orgs) for the FALLBACK path only
    $mapPath = Join-Path $PSScriptRoot "..\data\org-dept-map.json"
    $deptMap = $null
    if (Test-Path $mapPath) {
        $deptMap = (Get-Content $mapPath -Raw | ConvertFrom-Json).Departments
    } else {
        Write-Host "Note: correlation map not found at $mapPath - the AD-department fallback is disabled." -ForegroundColor DarkYellow
    }

    # --- 2. AD module (only needed for the fallback; warn but keep going if absent)
    $adReady = $true
    try { Import-Module ActiveDirectory -ErrorAction Stop }
    catch { $adReady = $false; Write-Host "Note: ActiveDirectory module not available - the department fallback is disabled." -ForegroundColor DarkYellow }

    # --- 3. Scope: open only (default) or everything
    $scopeAns = (Read-Host "Scan [O]pen tickets only (default) or [A]ll incl. closed?").Trim().ToUpper()
    $includeClosed = ($scopeAns -eq 'A')

    Write-Host "Finding tickets with no organization..." -ForegroundColor DarkGray
    $tickets = @(Get-TicketsWithoutOrg -IncludeClosed:$includeClosed)
    if ($tickets.Count -eq 0) { Write-Host "No tickets are missing an organization. Nice." -ForegroundColor Green; return }

    # --- 4. Jira org name -> id (once), for setting the field
    $orgIds = Get-JiraOrganizationMap

    Write-Host ""
    Write-Host "$($tickets.Count) ticket(s) with no organization. Nothing changes without your OK." -ForegroundColor Cyan

    $set = 0; $skipped = 0; $notified = 0
    :ticketLoop foreach ($t in $tickets) {
        $key      = $t.key
        $summary  = $t.fields.summary
        $reporter = $t.fields.reporter
        $email    = $reporter.emailAddress

        Write-Host ""
        Write-Host "----------------------------------------------------------------" -ForegroundColor DarkCyan
        Write-Host "$key : $summary" -ForegroundColor White
        Write-Host "   Reporter: $($reporter.displayName) <$email>" -ForegroundColor Gray

        # Build a ranked suggestion. Prefer the reporter's OWN history; if they
        # have none, fall back to their AD department via the correlation map.
        $ranked = @(); $source = $null; $note = $null

        # (a) Reporter's own previous org-assigned tickets - the strongest signal.
        if ($reporter.accountId) {
            $hist = Get-ReporterOrgHistory -AccountId $reporter.accountId
            if ($hist.Ranked.Count -gt 0) {
                $ranked  = @($hist.Ranked)
                $source  = "reporter's own history ($($hist.Total) past ticket(s) with an org)"
                if ($hist.MostRecent -and $hist.MostRecent -ne $ranked[0].Org) {
                    $note = "their most recent past ticket used '$($hist.MostRecent)'"
                }
            }
        }

        # (b) Fallback: AD department -> correlation map.
        if ($ranked.Count -eq 0) {
            if (-not $adReady -or -not $deptMap) {
                Write-Host "   NOTIFY: no ticket history and the AD-department fallback is unavailable - set it manually." -ForegroundColor Yellow
                $notified++; continue
            }
            if ([string]::IsNullOrWhiteSpace($email)) {
                Write-Host "   NOTIFY: no ticket history and reporter has no email for an AD lookup - skipping." -ForegroundColor Yellow
                $notified++; continue
            }
            $sam = ($email -split '@')[0]
            $adUser = Get-ADUser -Filter "EmailAddress -eq '$email' -or UserPrincipalName -eq '$email' -or SamAccountName -eq '$sam'" -Properties Department -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $adUser) {
                Write-Host "   NOTIFY: no ticket history and no AD account for this reporter - skipping." -ForegroundColor Yellow
                $notified++; continue
            }
            $dept = $adUser.Department
            if ([string]::IsNullOrWhiteSpace($dept)) {
                Write-Host "   NOTIFY: no ticket history and reporter's AD account has no Department - skipping." -ForegroundColor Yellow
                $notified++; continue
            }
            if ($deptMap.PSObject.Properties.Name -notcontains $dept) {
                Write-Host "   NOTIFY: no history; AD department '$dept' is not in the correlation map - set it manually." -ForegroundColor Yellow
                $notified++; continue
            }
            $entry   = $deptMap.$dept
            $ranked  = @($entry.Orgs)
            $confPct = [int]([double]$entry.Confidence * 100)
            $source  = "AD department '$dept' cheat sheet ($confPct% of $($entry.Total) tickets)"
        }

        # The ticket text often names the site (e.g. "...free up - Russell"). If a
        # distinctive word from an organization appears in the summary/description,
        # promote that org to the top suggestion - the reporter's most-frequent org
        # is often wrong when they raise a ticket for a different site.
        $ticketText = "$($t.fields.summary) " + (Get-AdfText $t.fields.description)
        $kw = Get-TicketKeywordOrg -Text $ticketText -CandidateOrgs @($ranked | ForEach-Object { $_.Org }) -AllOrgs @($orgIds.Keys)
        if ($kw) {
            $match = $ranked | Where-Object { $_.Org -eq $kw.Org } | Select-Object -First 1
            $rest  = @($ranked | Where-Object { $_.Org -ne $kw.Org })
            if ($match) { $ranked = @($match) + $rest }
            else        { $ranked = @([pscustomobject]@{ Org = $kw.Org; Count = 0 }) + $rest }
        }

        # --- Present the suggestion (shared by both sources)
        Write-Host "   Source: $source" -ForegroundColor DarkCyan
        if ($kw) { Write-Host "   Keyword in ticket: '$($kw.Keyword)' -> '$($kw.Org)' (used as the suggestion)" -ForegroundColor Green }
        Write-Host "   Suggested organization: $($ranked[0].Org)" -ForegroundColor Cyan
        if ($note) { Write-Host "   Note: $note" -ForegroundColor DarkYellow }
        if ($ranked.Count -gt 1) {
            Write-Host "   Options for this reporter/department:" -ForegroundColor DarkYellow
            for ($i = 0; $i -lt $ranked.Count; $i++) {
                $cnt = if ($ranked[$i].Count -gt 0) { "($($ranked[$i].Count))" } else { "(ticket keyword)" }
                Write-Host ("      {0}) {1} {2}" -f ($i + 1), $ranked[$i].Org, $cnt) -ForegroundColor DarkYellow
            }
        }

        # --- Decide what to set
        Write-Host "   [Y] set suggestion   [#] pick from list   [S] search all orgs   [N] skip   [Q] quit" -ForegroundColor White
        $ans = (Read-Host "   Choose").Trim()
        $ansUpper = $ans.ToUpper()

        if ($ansUpper -eq 'Q') { Write-Host "Stopped." -ForegroundColor DarkGray; break ticketLoop }
        if ($ansUpper -eq 'N' -or $ans -eq '') { Write-Host "   Skipped." -ForegroundColor DarkGray; $skipped++; continue }

        # Resolve the chosen organization name
        $chosenName = $null
        if ($ansUpper -eq 'Y') {
            $chosenName = $ranked[0].Org
        }
        elseif ($ansUpper -eq 'S') {
            $kw = (Read-Host "   Organization keyword").Trim()
            if ($kw) {
                $orgHits = @($orgIds.Keys | Where-Object { $_ -like "*$kw*" } | Sort-Object)
                if ($orgHits.Count -eq 0) { Write-Host "   No organization matched '$kw'. Skipped." -ForegroundColor Yellow; $skipped++; continue }
                for ($i = 0; $i -lt $orgHits.Count; $i++) { Write-Host ("      {0}) {1}" -f ($i + 1), $orgHits[$i]) }
                $pick = 0
                if ([int]::TryParse((Read-Host "   Number"), [ref]$pick) -and $pick -ge 1 -and $pick -le $orgHits.Count) {
                    $chosenName = $orgHits[$pick - 1]
                } else { Write-Host "   Cancelled. Skipped." -ForegroundColor DarkGray; $skipped++; continue }
            } else { Write-Host "   Skipped." -ForegroundColor DarkGray; $skipped++; continue }
        }
        else {
            # A number from the ranked list
            $pick = 0
            if ([int]::TryParse($ans, [ref]$pick) -and $pick -ge 1 -and $pick -le $ranked.Count) {
                $chosenName = $ranked[$pick - 1].Org
            } else { Write-Host "   Not a valid choice. Skipped." -ForegroundColor DarkGray; $skipped++; continue }
        }

        # Resolve name -> id and set (with a final confirm)
        if (-not $orgIds.ContainsKey($chosenName)) {
            Write-Host "   NOTIFY: '$chosenName' is not a current Jira organization - could not set." -ForegroundColor Yellow
            $notified++; continue
        }
        Write-Host "   Set organization on $key to '$chosenName'? (y/n)" -ForegroundColor Yellow
        if ((Read-Host).Trim().ToUpper() -ne 'Y') { Write-Host "   Skipped." -ForegroundColor DarkGray; $skipped++; continue }

        if (Set-TicketOrganization -Key $key -OrgName $chosenName -OrgId $orgIds[$chosenName] -Reporter "$($reporter.displayName) <$email>" -Source $source) { $set++ }
        else { $skipped++ }
    }

    Write-Host ""
    Write-Host "Done. Set: $set   Skipped: $skipped   Notified (no change): $notified" -ForegroundColor Cyan
    if ($set -gt 0) {
        $logPath = Join-Path $PSScriptRoot "..\logs\org-changes.json"
        Write-Host "Logged $set change(s) to $logPath (before/after, for backtracking)." -ForegroundColor DarkGray
    }
}

function Invoke-RevertOrgChanges {
    <#
    .SYNOPSIS
        Undoes organization changes recorded in logs\org-changes.json.
    .DESCRIPTION
        Lists the changes the "Fix missing organizations" tool has made (newest
        first, skipping any already reverted) and lets you undo one or all of them.
        Undoing sets the ticket's organization back to what it was before the
        change - or clears it if the ticket had none. Each undone change is stamped
        with revertedAt/revertedBy in the log so it is not offered again. Nothing
        is undone without your confirmation.
    #>
    [CmdletBinding()]
    param()

    $logFile = Join-Path $PSScriptRoot "..\logs\org-changes.json"
    if (-not (Test-Path $logFile)) {
        Write-Host "No change log found at $logFile - nothing to undo." -ForegroundColor Yellow
        return
    }

    # Assign FIRST, then wrap - ConvertFrom-Json does not enumerate in PS 5.1, so
    # @(Get-Content | ConvertFrom-Json) would collapse the whole array to one item.
    $loaded = Get-Content $logFile -Raw | ConvertFrom-Json
    $all = @($loaded)

    # Candidates: successful changes not already reverted.
    $candidates = @($all | Where-Object { $_.result -eq 'Success' -and -not $_.revertedAt })
    if ($candidates.Count -eq 0) {
        Write-Host "No changes are available to undo (none logged, or all already reverted)." -ForegroundColor Green
        return
    }
    $candidates = @($candidates | Sort-Object { [datetime]$_.timestamp } -Descending)   # newest first

    Write-Host ""
    Write-Host "Organization changes you can undo (newest first):" -ForegroundColor Cyan
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $c = $candidates[$i]
        $wasList = @($c.before)
        $was  = if ($wasList.Count -gt 0) { ($wasList | ForEach-Object { $_.name }) -join ', ' } else { 'none' }
        $when = try { ([datetime]$c.timestamp).ToString('yyyy-MM-dd HH:mm') } catch { "$($c.timestamp)" }
        Write-Host ("  {0}) {1,-11} now '{2}'  ->  undo to '{3}'   ({4})" -f ($i + 1), $c.issueKey, $c.after.name, $was, $when)
    }
    Write-Host "  [#] undo one   [A] undo ALL   [B] back" -ForegroundColor White
    $sel = (Read-Host "Choose").Trim()
    $selUpper = $sel.ToUpper()
    if ($selUpper -eq 'B' -or $sel -eq '') { return }

    # Decide which entries to undo
    $toUndo = @()
    if ($selUpper -eq 'A') {
        Write-Host "Undo ALL $($candidates.Count) change(s)? (y/n)" -ForegroundColor Yellow
        if ((Read-Host).Trim().ToUpper() -ne 'Y') { Write-Host "Cancelled." -ForegroundColor DarkGray; return }
        $toUndo = $candidates
    } else {
        $pick = 0
        if ([int]::TryParse($sel, [ref]$pick) -and $pick -ge 1 -and $pick -le $candidates.Count) {
            $toUndo = @($candidates[$pick - 1])
        } else { Write-Host "Invalid selection." -ForegroundColor DarkGray; return }
    }

    $undone = 0
    foreach ($c in $toUndo) {
        $wasList = @($c.before)
        $was = if ($wasList.Count -gt 0) { ($wasList | ForEach-Object { $_.name }) -join ', ' } else { 'none (clear it)' }
        Write-Host ""
        Write-Host "Undo $($c.issueKey): set organization back to '$was'? (y/n)" -ForegroundColor Yellow
        if ((Read-Host).Trim().ToUpper() -ne 'Y') { Write-Host "  Skipped." -ForegroundColor DarkGray; continue }

        # $c is the same object reference as in $all, so stamping it here updates
        # what we write back below.
        if (Restore-TicketOrganization -Key $c.issueKey -Before $c.before) {
            $c | Add-Member -NotePropertyName revertedAt -NotePropertyValue ((Get-Date).ToString('o')) -Force
            $c | Add-Member -NotePropertyName revertedBy -NotePropertyValue $script:MyDisplayName -Force
            $undone++
        }
    }

    if ($undone -gt 0) {
        ConvertTo-Json -InputObject ([object[]]$all) -Depth 8 | Out-File -FilePath $logFile -Encoding UTF8
    }
    Write-Host ""
    Write-Host "Undone: $undone   (log updated: $logFile)" -ForegroundColor Cyan
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
