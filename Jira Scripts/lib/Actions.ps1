<#
    Actions.ps1
    -----------
    Write operations that change a ticket: add a comment, assign to me,
    log work, and close (transition to Done/Resolved). Each function reports
    success/failure to the console and, where useful, returns a boolean so the
    caller can react (e.g. return to the list after a close).
#>

function Add-JiraComment {
    <#
    .SYNOPSIS
        Adds a comment to a service desk request.
    .DESCRIPTION
        Uses the JSM agent API, which distinguishes a public reply to the
        customer from a staff-only internal note.
    .PARAMETER Key
        The issue key, e.g. "ITSD-5592".
    .PARAMETER Body
        The comment text (plain text / wiki markup).
    .PARAMETER Public
        $true = reply visible to the customer; $false = internal note.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][bool]$Public
    )

    $uri = "$script:BaseUrl/rest/servicedeskapi/request/$Key/comment"
    $payload = @{ body = $Body; public = $Public } | ConvertTo-Json
    try {
        Invoke-RestMethod -Uri $uri -Headers $script:Headers -Method Post -Body $payload -ContentType 'application/json' | Out-Null
        if ($Public) { Write-Host "Public reply sent to the customer." -ForegroundColor Green }
        else         { Write-Host "Internal note added." -ForegroundColor Green }
    } catch {
        Write-Host "Failed to post comment: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Set-TicketAssignedToMe {
    <#
    .SYNOPSIS
        Assigns a ticket to the current (signed-in) user.
    .PARAMETER Key
        The issue key to take ownership of.
    .OUTPUTS
        System.Boolean - $true on success, $false on failure.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Key)

    $uri = "$script:BaseUrl/rest/api/3/issue/$Key/assignee"
    $payload = @{ accountId = $script:MyAccountId } | ConvertTo-Json
    try {
        Invoke-RestMethod -Uri $uri -Headers $script:Headers -Method Put -Body $payload -ContentType 'application/json' | Out-Null
        Write-Host "$Key assigned to you ($script:MyDisplayName)." -ForegroundColor Green
        return $true
    } catch {
        Write-Host "Failed to assign $Key : $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Set-TicketAssignee {
    <#
    .SYNOPSIS
        Re-assigns a ticket to another team member.
    .DESCRIPTION
        Searches users who can be assigned to this issue (by name or email),
        lets you pick one, then sets them as the assignee.
    .PARAMETER Key
        The issue key to re-assign.
    .OUTPUTS
        System.Boolean - $true on success, $false on cancel/failure.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Key)

    $query = (Read-Host "Re-assign to (type part of a name or email)").Trim()
    if ([string]::IsNullOrWhiteSpace($query)) { Write-Host "Cancelled." -ForegroundColor DarkGray; return $false }

    # Only users who can actually be assigned to this specific issue.
    $uri = "$script:BaseUrl/rest/api/3/user/assignable/search?issueKey=$Key&query=" +
           [uri]::EscapeDataString($query) + "&maxResults=20"
    # Capture then wrap. @(Invoke-RestMethod ...) nests the returned array inside
    # another one, which made 20 matches look like a single result and
    # auto-selected the whole array as the assignee.
    try {
        $resp = Invoke-RestMethod -Uri $uri -Headers $script:Headers -Method Get
    } catch {
        Write-Host "Could not search users: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
    $users = @($resp)

    $users = @($users | Where-Object { $_.active -ne $false })
    if ($users.Count -eq 0) { Write-Host "No assignable users matched '$query'." -ForegroundColor Yellow; return $false }

    # Pick one (auto-select when there is a single match).
    if ($users.Count -eq 1) {
        $chosen = $users[0]
    } else {
        Write-Host "Select a team member:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $users.Count; $i++) {
            $email = if ($users[$i].emailAddress) { "  <$($users[$i].emailAddress)>" } else { "" }
            Write-Host ("  {0}) {1}{2}" -f ($i + 1), $users[$i].displayName, $email)
        }
        $pick = 0
        if (-not [int]::TryParse((Read-Host "Number"), [ref]$pick) -or $pick -lt 1 -or $pick -gt $users.Count) {
            Write-Host "Cancelled." -ForegroundColor DarkGray; return $false
        }
        $chosen = $users[$pick - 1]
    }

    $assignUri = "$script:BaseUrl/rest/api/3/issue/$Key/assignee"
    $payload   = @{ accountId = $chosen.accountId } | ConvertTo-Json
    try {
        Invoke-RestMethod -Uri $assignUri -Headers $script:Headers -Method Put -Body $payload -ContentType 'application/json' | Out-Null
        Write-Host "$Key re-assigned to $($chosen.displayName)." -ForegroundColor Green
        return $true
    } catch {
        Write-Host "Failed to re-assign $Key : $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Add-TicketWorklog {
    <#
    .SYNOPSIS
        Logs time spent on a ticket.
    .PARAMETER Key
        The issue key.
    .PARAMETER TimeSpent
        A Jira time string such as "30m", "1h", or "2h 15m".
    .OUTPUTS
        System.Boolean - $true on success, $false on failure.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$TimeSpent
    )

    $uri = "$script:BaseUrl/rest/api/3/issue/$Key/worklog"
    $payload = @{ timeSpent = $TimeSpent } | ConvertTo-Json
    try {
        Invoke-RestMethod -Uri $uri -Headers $script:Headers -Method Post -Body $payload -ContentType 'application/json' | Out-Null
        Write-Host "Logged $TimeSpent of work on $Key." -ForegroundColor Green
        return $true
    } catch {
        Write-Host "Could not log work: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Get-JiraOrganizationMap {
    <#
    .SYNOPSIS
        Returns a hashtable of Organization name -> id for the whole JSM instance.
    .DESCRIPTION
        Pages through /rest/servicedeskapi/organization and caches the result in
        $script:OrgNameToId so it is fetched only once per session. Keys are the
        organization names (case-insensitive, as PowerShell hashtables are);
        values are the numeric organization ids (as strings) used when setting a
        ticket's Organizations field.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    if ($script:OrgNameToId) { return $script:OrgNameToId }

    $table = @{}
    $start = 0
    do {
        # NOTE: this endpoint caps the page at 50 regardless of the limit asked
        # for, so advance $start by however many rows actually came back (not by
        # a fixed 100) or later pages get skipped.
        $uri = "$script:BaseUrl/rest/servicedeskapi/organization?start=$start&limit=50"
        try {
            $resp = Invoke-RestMethod -Uri $uri -Headers $script:Headers -Method Get
        } catch {
            Write-Host "Could not list organizations: $($_.Exception.Message)" -ForegroundColor Red
            break
        }
        $rows = @($resp.values)
        if ($rows.Count -eq 0) { break }
        foreach ($o in $rows) { $table[$o.name] = "$($o.id)" }
        $start += $rows.Count
    } while (-not $resp.isLastPage)

    $script:OrgNameToId = $table
    return $table
}

function Write-OrgChangeLog {
    <#
    .SYNOPSIS
        Appends one organization-change record to logs\org-changes.json.
    .DESCRIPTION
        Records the before and after organization for a ticket so the change can
        be audited or reverted later. The log is a JSON array; each run appends a
        new object. The single-element case is force-wrapped in [] so the file is
        always a valid JSON array.
    .PARAMETER Key
        The issue key that was changed.
    .PARAMETER Before
        The Organizations field value BEFORE the change (may be $null/empty). Only
        id + name are kept per organization - enough to restore it.
    .PARAMETER NewOrgName / NewOrgId
        The organization set on the ticket.
    .PARAMETER Reporter / Source
        Context: who raised the ticket and how the org was chosen (history vs
        department). Optional.
    .PARAMETER Result
        'Success' (default) or a failure string.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key,
        $Before,
        [Parameter(Mandatory)][string]$NewOrgName,
        [Parameter(Mandatory)][string]$NewOrgId,
        [string]$Reporter,
        [string]$Source,
        [string]$Result = 'Success'
    )

    $logDir  = Join-Path $PSScriptRoot "..\logs"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $logFile = Join-Path $logDir "org-changes.json"

    # Keep only id + name for each prior organization (the rest is noise).
    $beforeList = @()
    foreach ($b in @($Before)) {
        if ($b -and $b.name) { $beforeList += [pscustomobject]@{ id = "$($b.id)"; name = $b.name } }
    }

    $entry = [pscustomobject]@{
        timestamp = (Get-Date).ToString('o')
        issueKey  = $Key
        reporter  = $Reporter
        changedBy = $script:MyDisplayName
        source    = $Source
        before    = $beforeList                                            # empty array = ticket had no org
        after     = [pscustomobject]@{ id = "$NewOrgId"; name = $NewOrgName }
        result    = $Result
    }

    # Load existing entries (tolerant of a single-object or missing file), append.
    $entries = New-Object System.Collections.Generic.List[object]
    if (Test-Path $logFile) {
        try {
            $existing = Get-Content $logFile -Raw | ConvertFrom-Json
            foreach ($e in @($existing)) { $entries.Add($e) }
        } catch { Write-Host "Warning: could not read existing log; starting a new one." -ForegroundColor DarkYellow }
    }
    $entries.Add($entry)

    # Passing a real object[] via -InputObject (not the pipeline) keeps ConvertTo-Json
    # emitting a JSON array even for a single element - no manual [] wrapping needed
    # (wrapping here would double-nest the first entry).
    ConvertTo-Json -InputObject $entries.ToArray() -Depth 8 | Out-File -FilePath $logFile -Encoding UTF8
}

# The PUT shape the Organizations field accepts varies by Jira deployment
# (Cloud vs Data Center) and is poorly documented, so we try the known-good shapes
# in order and cache whichever one works. Each builder takes the field id and an
# array of org refs (objects with .id and .name); an empty array clears the field.
$script:OrgPayloadBuilders = @(
    @{ Name = 'fields:[{id,name,domain}]'; Build = { param($fid, $orgs)
        @{ fields = @{ $fid = @(@($orgs) | ForEach-Object { @{ id = "$($_.id)"; name = "$($_.name)"; domain = '' } }) } } } }
    @{ Name = 'fields:[{id,name}]'; Build = { param($fid, $orgs)
        @{ fields = @{ $fid = @(@($orgs) | ForEach-Object { @{ id = "$($_.id)"; name = "$($_.name)" } }) } } } }
    @{ Name = 'update/set:[{id}]'; Build = { param($fid, $orgs)
        @{ update = @{ $fid = @(@{ set = @(@($orgs) | ForEach-Object { @{ id = "$($_.id)" } }) }) } } } }
    @{ Name = 'update/set:["id"]'; Build = { param($fid, $orgs)
        @{ update = @{ $fid = @(@{ set = @(@($orgs) | ForEach-Object { "$($_.id)" }) }) } } } }
)

function Set-OrgFieldValue {
    <#
    .SYNOPSIS
        PUTs the Organizations field on an issue, trying candidate payload shapes.
    .DESCRIPTION
        Sends each shape in $script:OrgPayloadBuilders until one succeeds, then
        remembers it in $script:OrgPayloadWinner so later calls in the session go
        straight to the working shape. A 400 means "wrong shape" - try the next; any
        other status (e.g. 403 permissions) stops the loop since another shape won't
        help. On total failure it prints every attempt's status, Jira message, and
        payload so the exact problem is visible.
    .PARAMETER Key
        The issue key to update.
    .PARAMETER Orgs
        Array of org refs (each with .id and .name). Empty array clears the field.
    .PARAMETER Label
        Action label used in the failure message.
    .OUTPUTS
        System.Boolean - $true on the first shape that succeeds.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Key,
        [object[]]$Orgs = @(),
        [string]$Label
    )
    if (-not $Label) { $Label = "set organization on $Key" }
    $fid = $script:OrgFieldId
    $uri = "$script:BaseUrl/rest/api/3/issue/$Key"

    # Use the cached winning shape if we have one; otherwise try them all in order.
    if ($null -ne $script:OrgPayloadWinner) { $order = @($script:OrgPayloadWinner) }
    else { $order = 0..($script:OrgPayloadBuilders.Count - 1) }

    $attempts = @()
    foreach ($i in $order) {
        $builder = $script:OrgPayloadBuilders[$i]
        $body = (& $builder.Build $fid $Orgs) | ConvertTo-Json -Depth 8
        try {
            Invoke-RestMethod -Uri $uri -Headers $script:Headers -Method Put -Body $body -ContentType 'application/json' | Out-Null
            if ($null -eq $script:OrgPayloadWinner) {
                Write-Host "  (organizations field accepts format: $($builder.Name))" -ForegroundColor DarkGray
            }
            $script:OrgPayloadWinner = $i
            return $true
        } catch {
            $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            $attempts += [pscustomobject]@{ Format = $builder.Name; Code = $code; Msg = (Get-JiraErrorMessage $_); Body = $body }
            # 401/403/404 = auth/permission/not-found: another shape won't help, stop.
            # 400 or unknown = likely a shape problem: try the next candidate.
            if ($code -eq 401 -or $code -eq 403 -or $code -eq 404) { break }
        }
    }

    Write-Host "Failed to $Label - tried $($attempts.Count) payload shape(s):" -ForegroundColor Red
    foreach ($a in $attempts) {
        Write-Host "  [$($a.Format)] HTTP $($a.Code): $($a.Msg)" -ForegroundColor Red
        Write-Host "     payload: $($a.Body -replace '\s+', ' ')" -ForegroundColor DarkGray
    }
    Write-Host "  Request: PUT $uri" -ForegroundColor DarkGray
    return $false
}

function Set-TicketOrganization {
    <#
    .SYNOPSIS
        Sets a ticket's Organizations field to a single organization, logging the
        before/after state so it can be reverted.
    .DESCRIPTION
        Reads the current organization first (for the audit log), overwrites it via
        Set-OrgFieldValue (which handles the deployment-specific payload shape), then
        records the change via Write-OrgChangeLog.
    .PARAMETER Key
        The issue key, e.g. "ITSD-4508".
    .PARAMETER OrgName
        The organization's display name (message + log).
    .PARAMETER OrgId
        The numeric organization id (from Get-JiraOrganizationMap).
    .PARAMETER Reporter / Source
        Optional context passed through to the change log.
    .OUTPUTS
        System.Boolean - $true on success, $false on failure.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$OrgName,
        [Parameter(Mandatory)][string]$OrgId,
        [string]$Reporter,
        [string]$Source
    )

    if (-not $script:OrgFieldId) {
        Write-Host "No Organizations field on this instance - cannot set." -ForegroundColor Red
        return $false
    }
    $fid = $script:OrgFieldId

    # Capture the current organization(s) BEFORE overwriting, for the audit log.
    $before = $null
    try {
        $curUri = "$script:BaseUrl/rest/api/3/issue/$Key" + "?fields=$fid"
        $cur = Invoke-RestMethod -Uri $curUri -Headers $script:Headers -Method Get
        $before = $cur.fields.$fid
    } catch { }

    if (Set-OrgFieldValue -Key $Key -Orgs @(@{ id = $OrgId; name = $OrgName }) -Label "set organization on $Key") {
        Write-Host "$Key organization set to '$OrgName'." -ForegroundColor Green
        Write-OrgChangeLog -Key $Key -Before $before -NewOrgName $OrgName -NewOrgId $OrgId -Reporter $Reporter -Source $Source
        return $true
    }
    return $false
}

function Complete-Ticket {
    <#
    .SYNOPSIS
        Closes a ticket: logs how long it took, then transitions it to Done/Resolved.
    .DESCRIPTION
        Loads the workflow transitions for the ticket, offers only those that
        land in a "Done" status category, requires a time-spent value (logged as
        a worklog), and fills a required resolution field if the transition
        screen has one. Prompts for confirmation before making any change.
    .PARAMETER Key
        The issue key to close.
    .OUTPUTS
        System.Boolean - $true only when the ticket was actually transitioned;
        $false if the user cancelled or an error occurred.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Key)

    # 1. Load available transitions (with field metadata)
    $uri = "$script:BaseUrl/rest/api/3/issue/$Key/transitions?expand=transitions.fields"
    try {
        $data = Invoke-RestMethod -Uri $uri -Headers $script:Headers -Method Get
    } catch {
        Write-Host "Could not load transitions: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }

    # 2. Only offer transitions that land in a "Done" status category
    $doneTransitions = @($data.transitions | Where-Object { $_.to.statusCategory.key -eq 'done' })
    if ($doneTransitions.Count -eq 0) {
        Write-Host "No Done/Resolved transition is available from the current status." -ForegroundColor Yellow
        $names = ($data.transitions | ForEach-Object { $_.name }) -join ', '
        Write-Host "Available transitions here: $names" -ForegroundColor DarkGray
        return $false
    }

    # 3. Pick which one (auto-select if there's only a single Done transition)
    if ($doneTransitions.Count -eq 1) {
        $chosen = $doneTransitions[0]
    } else {
        Write-Host "Close as which resolution?" -ForegroundColor Cyan
        for ($i = 0; $i -lt $doneTransitions.Count; $i++) {
            Write-Host ("  {0}) {1}  ->  {2}" -f ($i + 1), $doneTransitions[$i].name, $doneTransitions[$i].to.name)
        }
        $pick = 0
        if (-not [int]::TryParse((Read-Host "Number"), [ref]$pick) -or $pick -lt 1 -or $pick -gt $doneTransitions.Count) {
            Write-Host "Cancelled." -ForegroundColor DarkGray; return $false
        }
        $chosen = $doneTransitions[$pick - 1]
    }

    # 4. Time spent is required
    Write-Host "How long did this take? (e.g. 30m, 1h, 2h 15m - a bare number = minutes)" -ForegroundColor Cyan
    $timeInput = (Read-Host "Time spent").Trim()
    if ([string]::IsNullOrWhiteSpace($timeInput)) {
        Write-Host "Time is required to close. Cancelled." -ForegroundColor Yellow; return $false
    }
    if ($timeInput -match '^\d+$') { $timeInput = $timeInput + "m" }   # bare number -> minutes

    # 5. Confirm (closing is hard to undo)
    Write-Host ""
    Write-Host "Close $Key as '$($chosen.to.name)' and log $timeInput? (y/n)" -ForegroundColor Yellow
    if ((Read-Host).Trim().ToUpper() -ne "Y") { Write-Host "Cancelled." -ForegroundColor DarkGray; return $false }

    # 6. Log the time first so it's recorded even if the transition needs review
    Add-TicketWorklog -Key $Key -TimeSpent $timeInput | Out-Null

    # 7. Build the transition body, filling a required resolution field if present
    $body = @{ transition = @{ id = $chosen.id } }
    if ($chosen.fields -and ($chosen.fields.PSObject.Properties.Name -contains 'resolution')) {
        $allowed = $chosen.fields.resolution.allowedValues
        if ($allowed) {
            $res = $allowed | Where-Object { $_.name -eq 'Done' } | Select-Object -First 1
            if (-not $res) { $res = $allowed | Select-Object -First 1 }
            $body.fields = @{ resolution = @{ id = $res.id } }
        }
    }

    $tUri = "$script:BaseUrl/rest/api/3/issue/$Key/transitions"
    try {
        Invoke-RestMethod -Uri $tUri -Headers $script:Headers -Method Post -Body ($body | ConvertTo-Json -Depth 6) -ContentType 'application/json' | Out-Null
        Write-Host "$Key moved to '$($chosen.to.name)'." -ForegroundColor Green
        return $true
    } catch {
        Write-Host "Failed to close ticket: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}
