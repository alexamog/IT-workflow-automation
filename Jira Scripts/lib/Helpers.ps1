<#
    Helpers.ps1
    -----------
    Small, self-contained utilities with no Jira API calls:
    ticket sorting, time formatting, table cell formatting, multi-line input,
    and HTML-to-text conversion. Everything here is pure (input -> output) and
    easy to test in isolation.
#>

function ConvertTo-TicketJql {
    <#
    .SYNOPSIS
        Assembles a JQL query string from search criteria. Pure - no API calls.
    .DESCRIPTION
        Every parameter is optional; whichever ones are supplied are ANDed
        together. String values are escaped and quoted so a keyword like
        O'Brien or a name with quotes cannot break the query. Returns the JQL
        string (always ending with ORDER BY). With no criteria it returns just
        the ORDER BY clause, which matches every ticket - callers should confirm
        before running that.
    .PARAMETER Project
        Project key to scope to (e.g. ITSD). Blank = all projects.
    .PARAMETER ReporterAccountId
        Atlassian accountId to match as the reporter.
    .PARAMETER AssigneeMode
        'Me' (current user), 'Unassigned', or 'User' (use -AssigneeAccountId).
        Blank = no assignee filter.
    .PARAMETER AssigneeAccountId
        Atlassian accountId to match as the assignee (when AssigneeMode = 'User').
    .PARAMETER SummaryKeyword
        Word/phrase to match in the summary (subject line) via the ~ operator.
    .PARAMETER TextKeyword
        Word/phrase to match anywhere in the ticket text via the ~ operator.
    .PARAMETER Statuses
        One or more exact status names (e.g. 'Resolved','Closed'). Emitted as
        status in (...). Takes precedence over -StatusCategory.
    .PARAMETER StatusCategory
        'Open' (anything not Done) or 'Done' (resolved/closed/canceled). Ignored
        if -Statuses is given.
    .PARAMETER Priority
        Exact priority name (e.g. 'High').
    .PARAMETER CreatedWithinDays
        Only tickets created within this many days.
    .PARAMETER UpdatedWithinDays
        Only tickets updated within this many days.
    .PARAMETER OrderBy
        The ORDER BY clause body (default 'updated DESC').
    .OUTPUTS
        System.String - the JQL query.
    .EXAMPLE
        ConvertTo-TicketJql -Project ITSD -SummaryKeyword 'vpn' -Statuses 'Resolved'
        # project = ITSD AND summary ~ "vpn" AND status in ("Resolved") ORDER BY updated DESC
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Project,
        [string]$ReporterAccountId,
        [ValidateSet('', 'Me', 'Unassigned', 'User')][string]$AssigneeMode = '',
        [string]$AssigneeAccountId,
        [string]$SummaryKeyword,
        [string]$TextKeyword,
        [string[]]$Statuses,
        [ValidateSet('', 'Open', 'Done')][string]$StatusCategory = '',
        [string]$Priority,
        [int]$CreatedWithinDays,
        [int]$UpdatedWithinDays,
        [string]$OrderBy = 'updated DESC'
    )

    # Escape a value for use inside a JQL double-quoted string: backslash first,
    # then the double quote itself.
    $q = { param($v) '"' + ($v -replace '\\', '\\' -replace '"', '\"') + '"' }

    $clauses = @()

    if (-not [string]::IsNullOrWhiteSpace($Project)) { $clauses += "project = $Project" }

    if (-not [string]::IsNullOrWhiteSpace($ReporterAccountId)) {
        $clauses += "reporter = $(& $q $ReporterAccountId)"
    }

    switch ($AssigneeMode) {
        'Me'         { $clauses += "assignee = currentUser()" }
        'Unassigned' { $clauses += "assignee is EMPTY" }
        'User'       { if ($AssigneeAccountId) { $clauses += "assignee = $(& $q $AssigneeAccountId)" } }
    }

    if (-not [string]::IsNullOrWhiteSpace($SummaryKeyword)) { $clauses += "summary ~ $(& $q $SummaryKeyword)" }
    if (-not [string]::IsNullOrWhiteSpace($TextKeyword))    { $clauses += "text ~ $(& $q $TextKeyword)" }

    if ($Statuses -and @($Statuses).Count -gt 0) {
        $list = (@($Statuses) | ForEach-Object { & $q $_ }) -join ', '
        $clauses += "status in ($list)"
    }
    elseif ($StatusCategory -eq 'Open') { $clauses += "statusCategory != Done" }
    elseif ($StatusCategory -eq 'Done') { $clauses += "statusCategory = Done" }

    if (-not [string]::IsNullOrWhiteSpace($Priority)) { $clauses += "priority = $(& $q $Priority)" }

    if ($CreatedWithinDays -gt 0) { $clauses += "created >= -${CreatedWithinDays}d" }
    if ($UpdatedWithinDays -gt 0) { $clauses += "updated >= -${UpdatedWithinDays}d" }

    $jql = ($clauses -join ' AND ')
    if ($jql) { "$jql ORDER BY $OrderBy" } else { "ORDER BY $OrderBy" }
}

function Sort-TicketForDisplay {
    <#
    .SYNOPSIS
        Orders tickets for a list view: by status priority ($script:StatusOrder),
        then oldest-updated first within each status.
    .DESCRIPTION
        Statuses listed in $script:StatusOrder come first, in that order. Any
        status not in the list is placed after them and grouped alphabetically.
        Within a single status, the longest-waiting (oldest 'updated') is on top.
    .PARAMETER Issues
        The issues to order.
    .OUTPUTS
        System.Object[] - the same issues, sorted for display.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([object[]]$Issues)

    @($Issues | Sort-Object `
        @{ Expression = {
                $i = [array]::IndexOf($script:StatusOrder, $_.fields.status.name)
                if ($i -lt 0) { [int]::MaxValue } else { $i }     # unknown statuses last
            } },
        @{ Expression = { $_.fields.status.name } },              # group unknowns alphabetically
        @{ Expression = { [datetime]$_.fields.updated } })        # oldest first within a status
}

function Get-TimeAgo {
    <#
    .SYNOPSIS
        Returns a human-friendly "time ago" string for a date.
    .PARAMETER Date
        The point in time to compare against now.
    .OUTPUTS
        System.String, e.g. "just now", "30 min ago", "2 hr ago", "3 day(s) ago",
        or an absolute yyyy-MM-dd date once older than ~30 days.
    .EXAMPLE
        Get-TimeAgo ([datetime]'2026-07-02 09:00')
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][datetime]$Date)

    $span = (Get-Date) - $Date
    if     ($span.TotalSeconds -lt 60) { return "just now" }
    elseif ($span.TotalMinutes -lt 60) { return "$([int]$span.TotalMinutes) min ago" }
    elseif ($span.TotalHours   -lt 24) { return "$([int]$span.TotalHours) hr ago" }
    elseif ($span.TotalDays    -lt 30) { return "$([int]$span.TotalDays) day(s) ago" }
    else   { return $Date.ToString("yyyy-MM-dd") }
}

function Get-JiraErrorBody {
    <#
    .SYNOPSIS
        Returns the raw response body from a failed Invoke-RestMethod, or ''.
    .DESCRIPTION
        On a non-2xx response the useful detail is in the response body, not
        $_.Exception.Message. PowerShell usually stashes that body in
        $_.ErrorDetails.Message; if not, we read it off the response stream.
    .PARAMETER ErrorRecord
        The caught error object (`$_` inside a catch block).
    .OUTPUTS
        System.String - the raw body text (possibly JSON), or '' if none.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$ErrorRecord)

    # 1) PowerShell normally puts the response body here for REST failures.
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        return [string]$ErrorRecord.ErrorDetails.Message
    }
    # 2) Fallback: read it straight off the HTTP response stream.
    $resp = $ErrorRecord.Exception.Response
    if ($resp) {
        try {
            $stream = $resp.GetResponseStream()
            try { $stream.Position = 0 } catch { }
            $reader = New-Object System.IO.StreamReader($stream)
            return [string]$reader.ReadToEnd()
        } catch { }
    }
    return ''
}

function Get-JiraErrorMessage {
    <#
    .SYNOPSIS
        Extracts Jira's real error text from a failed Invoke-RestMethod.
    .DESCRIPTION
        Reads the response body (see Get-JiraErrorBody) and, when it is the usual
        {errorMessages, errors} JSON, flattens it to a readable one-liner. Falls
        back to the raw body, then to the generic exception message.
    .PARAMETER ErrorRecord
        The caught error object (`$_` inside a catch block).
    .OUTPUTS
        System.String - the best available explanation of the failure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$ErrorRecord)

    $body = Get-JiraErrorBody $ErrorRecord
    if (-not [string]::IsNullOrWhiteSpace($body)) {
        try {
            $j = $body | ConvertFrom-Json
            $parts = @()
            if ($j.errorMessages) { $parts += @($j.errorMessages) }
            if ($j.errors) { foreach ($p in $j.errors.PSObject.Properties) { $parts += "$($p.Name): $($p.Value)" } }
            if ($parts.Count -gt 0) { return ($parts -join '; ') }
        } catch { }
        return $body.Trim()
    }
    return $ErrorRecord.Exception.Message
}


function Format-Cell {
    <#
    .SYNOPSIS
        Pads or truncates a string to a fixed width for aligned table columns.
    .PARAMETER Text
        The value to fit. $null is treated as an empty string.
    .PARAMETER Width
        The target column width in characters. Values longer than this are
        truncated and an ellipsis is appended.
    .OUTPUTS
        System.String of exactly $Width characters.
    .EXAMPLE
        Format-Cell "Waiting for support" 12   # -> "Waiting for" + ellipsis
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][string]$Text,
        [Parameter(Mandatory)][int]$Width
    )

    if ($null -eq $Text) { $Text = "" }
    if ($Text.Length -gt $Width) { return $Text.Substring(0, $Width - 1) + [char]0x2026 }
    return $Text.PadRight($Width)
}

function Read-MultiLine {
    <#
    .SYNOPSIS
        Reads a multi-line block of text from the console.
    .DESCRIPTION
        Prompts the user, then collects lines until they enter an empty line.
        Used for composing customer replies and internal notes.
    .PARAMETER Prompt
        The heading shown above the input.
    .OUTPUTS
        System.String - the entered lines joined with newlines (may be empty).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Prompt)

    Write-Host $Prompt -ForegroundColor Cyan
    Write-Host "(Type your message. Press Enter on an empty line to finish.)" -ForegroundColor DarkGray
    $lines = @()
    while ($true) {
        $line = Read-Host
        if ([string]::IsNullOrEmpty($line)) { break }
        $lines += $line
    }
    return ($lines -join "`n")
}

function Convert-HtmlToText {
    <#
    .SYNOPSIS
        Converts Jira's rendered HTML comment body into clean, readable text.
    .DESCRIPTION
        Jira comments come back as rendered HTML (and sometimes contain large
        email-signature "expand" blocks or inline images). This strips tags,
        decodes entities, collapses signatures, and flags inline images so the
        thread is readable in a terminal.
    .PARAMETER Html
        The renderedBody HTML of a single comment.
    .OUTPUTS
        System.String - plain text, or "" for empty/whitespace input.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string]$Html)

    if ([string]::IsNullOrWhiteSpace($Html)) { return "" }

    $t = $Html
    $t = [regex]::Replace($t, '(?is)<(script|style).*?</\1>', '')
    # Collapse email-signature "expand" blocks - they are usually huge.
    $t = [regex]::Replace($t, '(?is)<div class="expand-content".*?</div>', ' [signature hidden] ')
    $t = [regex]::Replace($t, '(?i)<br\s*/?>', "`n")
    $t = [regex]::Replace($t, '(?i)</(p|div|li|tr|h[1-6])>', "`n")
    $t = [regex]::Replace($t, '(?i)<li[^>]*>', " - ")
    # Note inline images before stripping tags, so they aren't silently dropped.
    $t = [regex]::Replace($t, '(?i)<img[^>]*>', ' [inline image - open ticket in browser to view] ')
    $t = [regex]::Replace($t, '(?s)<[^>]+>', '')
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    $t = $t -replace "`r", ""
    $t = [regex]::Replace($t, '[ \t]+', ' ')
    $t = [regex]::Replace($t, ' *\n *', "`n")

    # --- Strip email-signature / footer noise so tickets read clean ----------
    # 1. Outlook "safelinks" URLs (never useful in a terminal), incl. angle-bracketed.
    $t = [regex]::Replace($t, '(?i)<?https?://\S*safelinks\.protection\.outlook\.com\S*>?', '')
    # 2. Collapse runs of the inline-image placeholder into one.
    $t = [regex]::Replace($t, '(?i)(\[inline image - open ticket in browser to view\]\s*){2,}', '[inline images] ')
    # 3. Drop whole lines that are social links or standard org footer boilerplate.
    $footer = '(?i)(Like Us on Facebook|Follow Us on (Twitter|Instagram)|Connect with Us on LinkedIn|' +
              'Your donation has a direct impact|unceded and traditional lands|' +
              'recognizes and acknowledges|Confidentiality notice)'
    $t = ($t -split "`n" | Where-Object { $_ -notmatch $footer }) -join "`n"

    $t = [regex]::Replace($t, '[ \t]+', ' ')
    $t = [regex]::Replace($t, "\n{3,}", "`n`n")
    return $t.Trim()
}

function Get-AdfText {
    <#
    .SYNOPSIS
        Flattens an Atlassian Document Format (ADF) node tree to plain text.
    .DESCRIPTION
        The search API returns issue descriptions as ADF (nested {type, content,
        text} nodes). This walks the tree and concatenates every text node so the
        description can be scanned for keywords. A plain string is returned as-is.
    .PARAMETER Node
        The ADF root (issue.fields.description) or any child node. $null -> "".
    .OUTPUTS
        System.String - space-joined text, or "".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param($Node)

    if ($null -eq $Node)      { return "" }
    if ($Node -is [string])   { return $Node }
    $parts = @()
    if ($Node.text)    { $parts += [string]$Node.text }
    if ($Node.content) { foreach ($child in $Node.content) { $parts += (Get-AdfText $child) } }
    return ($parts -join ' ')
}

function Get-TicketKeywordOrg {
    <#
    .SYNOPSIS
        Finds an organization whose distinctive name-word appears in ticket text.
    .DESCRIPTION
        Tickets often name their site in the summary/description (e.g. "...free up
        - Russell" points to "Russell Residence and Housing Centre"). This tokenizes
        each organization name, drops generic words (Shelter, Housing, Centre, ...),
        and returns the first org whose distinctive token appears as a whole word in
        the text. The reporter's own candidate orgs are checked before the full list.
    .PARAMETER Text
        The ticket text to scan (summary + description), any case.
    .PARAMETER CandidateOrgs
        Organization names to prefer (from history / department), in priority order.
    .PARAMETER AllOrgs
        All organization names, checked only if no candidate matched.
    .OUTPUTS
        PSCustomObject { Org; Keyword } for the match, or $null.
    #>
    [CmdletBinding()]
    param(
        [string]$Text,
        [string[]]$CandidateOrgs = @(),
        [string[]]$AllOrgs = @()
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $lower = $Text.ToLower()

    # Generic org-name words that don't identify a specific site - ignored so only
    # the distinctive part (a place/person name) is matched.
    $stop = @(
        'shelter','house','houses','housing','residence','residences','centre','center',
        'building','lodge','program','programs','service','services','hotel','society',
        'inn','place','manor','hall','room','rooms','wellness','recovery','health','community',
        'supportive','head','office','home','homes','care','unit','units','support','clinic',
        'project','hostel','court','village','tower','towers','plaza','block','apartments',
        'apartment','transitional','emergency','the','and','for'
    )

    foreach ($list in @($CandidateOrgs, $AllOrgs)) {
        foreach ($org in $list) {
            if (-not $org) { continue }
            $tokens = @(($org.ToLower() -split '[^a-z0-9]+') | Where-Object { $_.Length -ge 3 -and $stop -notcontains $_ })
            foreach ($tok in $tokens) {
                if ($lower -match "\b$([regex]::Escape($tok))\b") {
                    return [pscustomobject]@{ Org = $org; Keyword = $tok }
                }
            }
        }
    }
    return $null
}
