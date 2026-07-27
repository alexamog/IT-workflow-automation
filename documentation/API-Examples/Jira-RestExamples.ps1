<#
    Jira-RestExamples.ps1  -  minimal Jira Cloud / JSM REST skeletons.
    Dot-source it, then call the functions. Needs these env vars:
        JIRA_BASEURL   e.g. https://your-site.atlassian.net
        JIRA_EMAIL     account email
        JIRA_API_TOKEN https://id.atlassian.com/manage-profile/security/api-tokens
#>

# One wrapper for every call: Basic auth (email:token, Base64) + Invoke-RestMethod.
# On an error, Jira's real message is in $_.ErrorDetails.Message (not $_.Exception.Message).
function Jira ($Method, $Path, $Body) {
    $auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$env:JIRA_EMAIL`:$env:JIRA_API_TOKEN"))
    $headers = @{ Authorization = "Basic $auth"; Accept = 'application/json' }
    $uri = "$($env:JIRA_BASEURL.TrimEnd('/'))$Path"
    Invoke-RestMethod -Uri $uri -Headers $headers -Method $Method -Body $Body -ContentType 'application/json'
}

# Who am I (confirm the credentials work).
function Get-Myself { Jira GET '/rest/api/3/myself' }

# Find a field's id by name (custom-field ids differ per instance).
# Assign to $fields first: piping the call's array straight into Where-Object
# passes it as one item in PS 5.1 (it doesn't enumerate).
function Get-FieldId ($name) {
    $fields = Jira GET '/rest/api/3/field'
    ($fields | Where-Object { $_.name -eq $name }).id
}

# Search with JQL. Pages with nextPageToken (not startAt) until it's empty.
function Search-Issues ($jql) {
    $issues = @(); $token = $null
    do {
        $path = "/rest/api/3/search/jql?jql=" + [uri]::EscapeDataString($jql) + "&fields=summary,status&maxResults=100"
        if ($token) { $path += "&nextPageToken=$token" }
        $r = Jira GET $path
        $issues += $r.issues; $token = $r.nextPageToken
    } while ($token)
    $issues
}

# One issue.
function Get-Issue ($key) { Jira GET "/rest/api/3/issue/$key" }

# Comment via the JSM API. $public $true = the customer sees it; $false = internal note.
function Add-Comment ($key, $text, $public) {
    Jira POST "/rest/servicedeskapi/request/$key/comment" (@{ body = $text; public = $public } | ConvertTo-Json)
}

# Assign by accountId (find one via /rest/api/3/user/search?query=email).
function Set-Assignee ($key, $accountId) {
    Jira PUT "/rest/api/3/issue/$key/assignee" (@{ accountId = $accountId } | ConvertTo-Json)
}

# List all organizations (id + name). This endpoint caps at 50 per page.
function Get-Organizations {
    $all = @(); $start = 0
    do {
        $r = Jira GET "/rest/servicedeskapi/organization?start=$start&limit=50"
        $all += $r.values; $start += @($r.values).Count
    } while (-not $r.isLastPage)
    $all
}

# Set a ticket's Organizations field. The payload shape varies by Jira deployment;
# this is the Cloud shape. (The toolkit's Set-OrgFieldValue tries several shapes.)
function Set-Organization ($key, $orgId, $orgName) {
    $body = @{ fields = @{ customfield_10002 = @(@{ id = "$orgId"; name = $orgName; domain = '' }) } } | ConvertTo-Json -Depth 6
    Jira PUT "/rest/api/3/issue/$key" $body
}

# --- examples ---
# Get-Myself
# Search-Issues 'project = ITSD AND statusCategory != Done'
# Add-Comment 'ITSD-1234' 'Looking into this now.' $true
# Set-Organization 'ITSD-1234' '71' 'Yukon Housing Centre'
