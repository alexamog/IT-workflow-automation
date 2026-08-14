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
