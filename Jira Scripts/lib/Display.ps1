<#
    Display.ps1
    -----------
    Presentation only: renders the ticket list (as an aligned table) and the
    comment thread to the console. Show-TicketComment does its own read; nothing
    here writes to a ticket.
#>

function Show-TicketList {
    <#
    .SYNOPSIS
        Renders a list of issues as an aligned, colorized table.
    .DESCRIPTION
        Columns: number, key, age, status, summary, reporter. Over-long values
        are truncated with an ellipsis so rows stay aligned. Rows in the attention
        status ($script:AttentionStatus) get a red key highlight so they stand out.
    .PARAMETER Issues
        The array of issue objects to display.
    .PARAMETER Title
        A heading shown above the table.
    #>
    [CmdletBinding()]
    param(
        [object[]]$Issues,
        [string]$Title = "Tickets"
    )

    # Column widths (characters). Change here to re-balance the table.
    $wNum = 3; $wKey = 10; $wAge = 12; $wStatus = 20; $wSummary = 34; $wReporter = 22

    Write-Host ""
    Write-Host "===================================================================" -ForegroundColor Cyan
    Write-Host " $Title     $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
    Write-Host "===================================================================" -ForegroundColor Cyan

    if ($Issues.Count -eq 0) {
        Write-Host "(None found.)" -ForegroundColor Green
        return
    }

    # Header row + divider
    $header = "  " + ("#".PadRight($wNum)) + " " + ("KEY".PadRight($wKey)) + " " +
              ("AGE".PadRight($wAge)) + " " + ("STATUS".PadRight($wStatus)) + " " +
              ("SUMMARY".PadRight($wSummary)) + " " + "REPORTER"
    Write-Host $header -ForegroundColor DarkCyan
    Write-Host ("  " + ("-" * ($header.Length))) -ForegroundColor DarkCyan

    for ($i = 0; $i -lt $Issues.Count; $i++) {
        $issue    = $Issues[$i]
        $num      = $i + 1
        $key      = $issue.key
        $summary  = $issue.fields.summary
        $status   = $issue.fields.status.name
        $reporter = if ($issue.fields.reporter) { $issue.fields.reporter.displayName } else { "Unknown" }
        $updated  = [datetime]$issue.fields.updated
        $ago      = Get-TimeAgo $updated
        $isAttention = ($status -eq $script:AttentionStatus)

        $numCell = "{0,2})" -f $num                # right-aligned number, e.g. " 1)"
        $keyCell = Format-Cell $key      $wKey
        $ageCell = Format-Cell $ago      $wAge
        $staCell = Format-Cell $status   $wStatus
        $sumCell = Format-Cell $summary  $wSummary
        $repCell = Format-Cell $reporter $wReporter

        # Colors differ for the attention status so it still stands out.
        $keyColor = if ($isAttention) { "Black" }  else { "Green" }
        $staColor = if ($isAttention) { "Red" }    else { "DarkGray" }
        $sumColor = if ($isAttention) { "Yellow" } else { "Gray" }

        Write-Host "  $numCell " -NoNewline -ForegroundColor White
        if ($isAttention) {
            Write-Host $keyCell -NoNewline -ForegroundColor $keyColor -BackgroundColor Red
        } else {
            Write-Host $keyCell -NoNewline -ForegroundColor $keyColor
        }
        Write-Host " "      -NoNewline
        Write-Host $ageCell -NoNewline -ForegroundColor DarkGray
        Write-Host " "      -NoNewline
        Write-Host $staCell -NoNewline -ForegroundColor $staColor
        Write-Host " "      -NoNewline
        Write-Host $sumCell -NoNewline -ForegroundColor $sumColor
        Write-Host " "      -NoNewline
        Write-Host $repCell -ForegroundColor DarkGray
    }
    Write-Host ("  " + ("-" * ($header.Length))) -ForegroundColor DarkCyan
}

function Show-TicketComment {
    <#
    .SYNOPSIS
        Prints a ticket's comment thread (the activity log).
    .DESCRIPTION
        Pages through all comments, renders each body to clean text, skips
        empty/attachment-only comments, and tags each as [PUBLIC] (customer
        visible) or [INTERNAL] (staff only) based on the jsdPublic flag.
    .PARAMETER Key
        The issue key whose comments to show.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Key)

    $comments = @()
    $start = 0
    do {
        $uri = "$script:BaseUrl/rest/api/3/issue/$Key/comment?expand=renderedBody&startAt=$start&maxResults=50&orderBy=created"
        try {
            $resp = Invoke-RestMethod -Uri $uri -Headers $script:Headers -Method Get
        } catch {
            Write-Host "Could not load comments: $($_.Exception.Message)" -ForegroundColor Red
            return
        }
        if ($resp.comments) { $comments += $resp.comments }
        $start += 50
    } while ($start -lt $resp.total)

    Write-Host ""
    Write-Host "----- Activity log: $Key ------------------------------------------" -ForegroundColor Cyan
    if ($comments.Count -eq 0) {
        Write-Host "(No comments yet.)" -ForegroundColor DarkGray
        return
    }

    foreach ($c in $comments) {
        $author = $c.author.displayName
        $text   = Convert-HtmlToText $c.renderedBody
        if ([string]::IsNullOrWhiteSpace($text)) { continue }   # skip empty/attachment-only
        $when   = [datetime]$c.created
        $stamp  = $when.ToString("yyyy-MM-dd HH:mm")
        $ago    = Get-TimeAgo $when

        if ($c.PSObject.Properties.Name -contains 'jsdPublic' -and -not $c.jsdPublic) {
            $tag = "[INTERNAL]"; $color = "Yellow"
        } else {
            $tag = "[PUBLIC]  "; $color = "Green"
        }

        Write-Host ""
        Write-Host "$tag [$stamp] ($ago) - $author :" -ForegroundColor $color
        foreach ($line in ($text -split "`n")) {
            Write-Host "    $line" -ForegroundColor Gray
        }
    }
    Write-Host ""
    Write-Host "-------------------------------------------------------------------" -ForegroundColor Cyan
}
