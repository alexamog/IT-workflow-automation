<#
    Context.ps1
    -----------
    Configuration + authentication. Populates the script-scoped values
    ($script:BaseUrl, $script:Headers, $script:MyAccountId, ...) that every
    other function relies on. Call Initialize-JiraContext once at startup.

    NOTE ON Write-Host: this is an interactive, colorized console tool, so
    functions here (and elsewhere) deliberately use Write-Host for the UI.
    Data-returning functions still return objects via the pipeline; Write-Host
    is only for messages meant for the human at the keyboard.
#>

# ===========================================================================
# CONFIG
# ===========================================================================
# The status that gets the loud red highlight wherever tickets are listed.
$script:AttentionStatus = "Waiting for support"

# The order ticket lists are sorted in: by this status priority first, then by
# age (oldest first) within each status. Statuses NOT listed here appear after
# these, grouped alphabetically. Adjust the order / add your statuses as needed.
$script:StatusOrder = @(
    "Waiting for support"
    "Escalated"
    "In progress"
    "Pending"
    "Waiting for customer"
    "Waiting for third party"
    "Resolved"
    "Closed"
    "Canceled"
)

# Project used to scope the unassigned queue and bare-number lookups.
# Your service desk project key. Override with JIRA_PROJECT_KEY.
$script:ProjectKey = if ($env:JIRA_PROJECT_KEY) { $env:JIRA_PROJECT_KEY } else { 'ITSD' }

# ManageEngine remote-control console, opened with the [M] action in a ticket.
# Optional - set MANAGEENGINE_URL to enable it; empty = the [M] action says so.
$script:ManageEngineUrl = $env:MANAGEENGINE_URL

# ===========================================================================
# AUTH
# ===========================================================================
function Initialize-JiraContext {
    <#
    .SYNOPSIS
        Loads credentials, builds the auth header, and confirms the signed-in user.
    .DESCRIPTION
        Reads JIRA_EMAIL, JIRA_BASEURL, and JIRA_API_TOKEN from the environment,
        builds a Basic-auth header, and calls /myself to confirm the credentials
        work. On success it populates the script-scoped context used by every
        other function: $script:BaseUrl, $script:Headers, $script:MyAccountId,
        and $script:MyDisplayName.
    .OUTPUTS
        System.Boolean. $true when the context is ready; $false on any failure
        (missing credentials or a failed authentication call).
    .EXAMPLE
        if (-not (Initialize-JiraContext)) { return }
        Aborts the console if credentials are missing or invalid.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $email   = $env:JIRA_EMAIL
    $baseUrl = $env:JIRA_BASEURL
    $token   = $env:JIRA_API_TOKEN

    if (-not $email -or -not $baseUrl -or -not $token) {
        Write-Host "Missing credentials. Run Set-JiraCredentials.ps1 first, then reopen PowerShell." -ForegroundColor Red
        return $false
    }

    $script:BaseUrl = $baseUrl.TrimEnd('/')
    $pair    = "$($email):$($token)"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
    $script:Headers = @{
        Authorization = "Basic $encoded"
        Accept        = "application/json"
    }

    try {
        $me = Invoke-RestMethod -Uri "$script:BaseUrl/rest/api/3/myself" -Headers $script:Headers -Method Get
        $script:MyAccountId   = $me.accountId
        $script:MyDisplayName = $me.displayName
    } catch {
        Write-Host "Could not authenticate to Jira: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }

    # Resolve the "Organizations" field id once (it's an instance-specific custom
    # field). Used to show a ticket's organization in the single-ticket view.
    # The full field list is cached in $script:AllFields so other layers (the
    # monthly reports) can resolve their own custom fields by NAME without
    # making a second call and without hard-coding customfield_ numbers - those
    # ids differ between Jira sites.
    try {
        $fetched = Invoke-RestMethod -Uri "$script:BaseUrl/rest/api/3/field" -Headers $script:Headers -Method Get
        # Do NOT write @(Invoke-RestMethod ...) here. Under PowerShell 5.1 that
        # wraps the object[] the call already returns inside a second array, so
        # you end up with one element holding all 170 fields, and every lookup
        # below silently returns every field id at once.
        $script:AllFields = @()
        foreach ($f in $fetched) { $script:AllFields += $f }
        $script:OrgFieldId = ($script:AllFields | Where-Object { $_.name -eq 'Organizations' } | Select-Object -First 1).id
    } catch { $script:AllFields = @(); $script:OrgFieldId = $null }

    return $true
}

function Get-JiraFieldId {
    <#
    .SYNOPSIS
        Looks up a custom field's id from its display name.
    .DESCRIPTION
        Jira custom field ids (customfield_10025 and friends) are assigned per
        site, so the same field has a different id in a different Jira. Reports
        therefore look fields up by the name shown in the UI. Returns $null when
        this site has no such field, which callers treat as "skip that metric"
        rather than an error.
    .PARAMETER Name
        The field name exactly as it appears in Jira, e.g. 'Satisfaction'.
    .OUTPUTS
        System.String - the field id, or $null when not present.
    .EXAMPLE
        Get-JiraFieldId -Name 'Time to first response'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)

    if (-not $script:AllFields) { return $null }
    $match = $script:AllFields | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if (-not $match) { return $null }
    # Cast to a scalar string: a field id must never come back as a collection,
    # or it gets pasted into a JQL "fields=" list and silently breaks the query.
    return [string]$match.id
}
