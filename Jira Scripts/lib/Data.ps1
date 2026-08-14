<#
    Data.ps1
    --------
    Read-only data access: JQL search and single-issue fetch.
    These functions only GET data; they never modify a ticket.
    All rely on $script:BaseUrl / $script:Headers from Initialize-JiraContext.
#>

# Fields requested for every ticket. Kept in one place so list and detail
# views stay consistent.
$script:TicketFields = "summary,status,priority,updated,created,reporter,assignee,attachment,description"

function Get-IssueByJql {
    <#
    .SYNOPSIS
        Runs a JQL search and returns all matching issues.
    .DESCRIPTION
        Handles pagination via the search endpoint's nextPageToken, accumulating
        every page. Returns an empty array on error (after printing the reason).
    .PARAMETER Jql
        A JQL query string, e.g. 'assignee = currentUser() AND statusCategory != Done'.
    .PARAMETER Fields
        Comma-separated list of fields to request. Defaults to the standard
        ticket fields used by the list and detail views. Reports pass their own
        list so they can pull custom fields (satisfaction, SLA, organizations)
        without bloating every other query.
    .OUTPUTS
        System.Object[] - the array of issue objects (may be empty).
    .EXAMPLE
        Get-IssueByJql -Jql "project = ITSD AND assignee is EMPTY"
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string]$Jql,
        [string]$Fields
    )

    if (-not $Fields) { $Fields = $script:TicketFields }

    $issues = @()
    $nextPageToken = $null
    do {
        $uri = "$script:BaseUrl/rest/api/3/search/jql?jql=" +
               [uri]::EscapeDataString($Jql) +
               "&fields=$Fields&maxResults=100"
        if ($nextPageToken) { $uri += "&nextPageToken=$nextPageToken" }
        try {
            $response = Invoke-RestMethod -Uri $uri -Headers $script:Headers -Method Get
        } catch {
            Write-Host "Search failed: $($_.Exception.Message)" -ForegroundColor Red
            return @()
        }
        if ($response.issues) { $issues += $response.issues }
        $nextPageToken = $response.nextPageToken
    } while ($nextPageToken)
    return $issues
}

function Get-MyTicket {
    <#
    .SYNOPSIS
        Returns all of my open tickets (any status that is not Done).
    .OUTPUTS
        System.Object[] - issues assigned to the current user, newest first.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    $jql = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"
    return Get-IssueByJql -Jql $jql
}

function Get-UnassignedTicket {
    <#
    .SYNOPSIS
        Returns the "needs pickup" queue: open, unassigned tickets in the project.
    .DESCRIPTION
        Scoped to $script:ProjectKey and ordered oldest-first so the
        longest-waiting tickets surface at the top.
    .OUTPUTS
        System.Object[] - unassigned open issues.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    $jql = "project = $script:ProjectKey AND assignee is EMPTY AND statusCategory != Done ORDER BY created ASC"
    return Get-IssueByJql -Jql $jql
}

function Find-JiraUser {
    <#
    .SYNOPSIS
        Searches Jira users by name or email. Returns matching user objects.
    .DESCRIPTION
        Unlike the teammate picker, this does NOT filter to staff accounts, so it
        also finds customers/reporters. Returns an empty array on error or no
        match (after printing the reason on error).
    .PARAMETER Query
        A name or email fragment, e.g. 'jsmith' or 'John'.
    .OUTPUTS
        System.Object[] - matching user objects (may be empty).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$Query)

    $uri = "$script:BaseUrl/rest/api/3/user/search?query=" + [uri]::EscapeDataString($Query) + "&maxResults=20"
    # Capture then wrap. @(Invoke-RestMethod ...) nests the returned array inside
    # another one, so every match collapses into a single item.
    try { $resp = Invoke-RestMethod -Uri $uri -Headers $script:Headers -Method Get }
    catch { Write-Host "User search failed: $($_.Exception.Message)" -ForegroundColor Red; return @() }
    return @($resp)
}

function Get-Ticket {
    <#
    .SYNOPSIS
        Fetches a single issue by key.
    .DESCRIPTION
        Used for lookups and to refresh a ticket after assigning or on demand.
        Requests renderedFields so the description comes back as HTML (the raw
        field is Atlassian Document Format), ready for Convert-HtmlToText.
    .PARAMETER Key
        The issue key, e.g. "ITSD-5592".
    .OUTPUTS
        The issue object, or $null if it could not be loaded.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Key)

    # Include the Organizations field (if this instance has one) so the ticket
    # view can display it.
    $fields = $script:TicketFields
    if ($script:OrgFieldId) { $fields += ",$script:OrgFieldId" }

    $uri = "$script:BaseUrl/rest/api/3/issue/$Key" + "?fields=$fields&expand=renderedFields"
    try {
        return Invoke-RestMethod -Uri $uri -Headers $script:Headers -Method Get
    } catch {
        Write-Host "Could not reload $Key : $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}
