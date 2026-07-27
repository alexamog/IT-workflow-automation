#Requires -Version 5.1
<#
    .SYNOPSIS
        Menu-driven console for Jira Service Management. Run THIS file.
    .DESCRIPTION
        Loads the function library in lib\ then presents a menu:
          1) My tickets (all open) - view thread, reply, note, assign, close
          2) Unassigned queue      - view details, then pick up
          3) Find / search tickets - open one by key, or filter by keyword,
                                     reporter, assignee, status, priority, ...

        Credentials come from environment variables set by Set-JiraCredentials.ps1.
    .EXAMPLE
        .\Start-JiraConsole.ps1
    .NOTES
        Prereqs: run Set-JiraCredentials.ps1 once first, then reopen PowerShell.
        See docs\ARCHITECTURE.md for how the pieces fit together.
#>

# Load the function library. Order: config/auth first, then the rest.
# (Order only matters for readability - functions aren't called until below.)
$libFiles = @(
    "Context.ps1",      # config + authentication
    "Helpers.ps1",      # time/text utilities
    "Data.ps1",         # read-only ticket fetching
    "Display.ps1",      # console rendering
    "Actions.ps1",      # ticket write operations
    "Interaction.ps1"   # interactive menus
)
foreach ($file in $libFiles) {
    . (Join-Path $PSScriptRoot "lib\$file")
}

# Shared look-and-feel (banner / headers / menu rows), used by the whole
# toolkit. This console sits inside that project, so load it from the main lib.
$uiShared = Join-Path $PSScriptRoot '..\lib\Ui.ps1'
if (Test-Path $uiShared) { . $uiShared }

# Authenticate and confirm who we are.
if (-not (Initialize-JiraContext)) { return }

Write-Host ""
Write-Host "Signed in as $script:MyDisplayName" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Main menu loop
# ---------------------------------------------------------------------------
:mainMenu while ($true) {
    # Use the shared style when it loaded; fall back to a plain header if not.
    if (Get-Command Write-ToolBanner -ErrorAction SilentlyContinue) {
        Write-ToolBanner 'Jira Service Console'
        Write-ToolHeader 'Menu'
        Write-ToolMenuItem -Key 1 -Label 'My tickets (all open)'
        Write-ToolMenuItem -Key 2 -Label 'Unassigned queue' -Note 'view, then pick up'
        Write-ToolMenuItem -Key 3 -Label 'Find / search tickets' -Note 'key, keyword, reporter, assignee, status...'
        Write-ToolMenuItem -Key 4 -Label 'Fix missing organizations' -Note 'suggest from history / AD department'
        Write-ToolMenuItem -Key 5 -Label 'Undo organization changes' -Note 'from the log'
        Write-ToolMenuItem -Key 'Q' -Label 'Quit'
        Write-Host ''
    }
    else {
        Write-Host "`n=== JIRA SERVICE CONSOLE ===" -ForegroundColor Cyan
        Write-Host "  1) My tickets   2) Unassigned   3) Search   4) Fix orgs   5) Undo orgs   Q) Quit"
    }

    $choice = (Read-Host "  Select").Trim().ToUpper()
    switch ($choice) {
        "1" { Invoke-TicketBrowser -Fetch { Get-MyTicket }         -Title "My tickets (all open)" -RefreshSeconds 90 }
        "2" { Invoke-TicketBrowser -Fetch { Get-UnassignedTicket } -Title "Unassigned queue ($script:ProjectKey) - select to view details" -RefreshSeconds 90 }
        "3" { Invoke-TicketSearch }
        "4" { Invoke-FixMissingOrgs }
        "5" { Invoke-RevertOrgChanges }
        "Q" { break mainMenu }   # break the loop, not just the switch
        default { Write-Host "Unknown option." -ForegroundColor DarkGray }
    }
}

# Sign off with a random pastel quote. Same shared function (loaded from Ui.ps1)
# and same lib\Quotes.psd1 the whole toolkit uses, so quotes and look are defined
# in one place. If the style file wasn't reachable, just skip the quote.
if (Get-Command Show-DeskSideSignoff -ErrorAction SilentlyContinue) { Show-DeskSideSignoff }
