<#
.SYNOPSIS
    Set, schedule, or clear a person's Out of Office (automatic reply) message
    on their behalf (Exchange Online).

.DESCRIPTION
    Turns on automatic replies for a mailbox and lets you choose whether it
    runs indefinitely (until someone turns it off) or only for a set date
    range (it then turns itself off). Also turns it off and shows the current
    status.

    Sign-in is interactive the first time. Needs the ExchangeOnlineManagement
    module.

.EXAMPLE
    .\Set-MailboxAutoReply.ps1
#>

[CmdletBinding()]
param()

. "$PSScriptRoot\..\..\lib\Common.ps1"

# Describe the current auto-reply setting in plain English.
function Format-OofStatus {
    param($Config)
    switch ([string]$Config.AutoReplyState) {
        'Disabled'  { '(off)' }
        'Enabled'   { 'ON - indefinite (no end date)' }
        'Scheduled' { "ON - scheduled {0:yyyy-MM-dd HH:mm} to {1:yyyy-MM-dd HH:mm}" -f $Config.StartTime, $Config.EndTime }
        default     { [string]$Config.AutoReplyState }
    }
}

# Ask for a date and time until we get one we understand. Blank is allowed only
# when -AllowBlank is set, and returns $null so the caller can default it.
function Read-OofDateTime {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [switch]$AllowBlank,
        [datetime]$MustBeAfter
    )
    while ($true) {
        $raw = (Read-Host "  $Prompt").Trim()
        if (-not $raw) {
            if ($AllowBlank) { return $null }
            Write-Host "  A date and time is needed here." -ForegroundColor Yellow
            continue
        }
        $parsed = [datetime]::MinValue
        if (-not [datetime]::TryParse($raw, [ref]$parsed)) {
            Write-Host "  Could not read that as a date and time. Try 2026-08-10 09:00." -ForegroundColor Yellow
            continue
        }
        if ($PSBoundParameters.ContainsKey('MustBeAfter') -and $parsed -le $MustBeAfter) {
            Write-Host ("  That is not after the start ({0:yyyy-MM-dd HH:mm}). Try again." -f $MustBeAfter) -ForegroundColor Yellow
            continue
        }
        return $parsed
    }
}

if (-not (Connect-ExoSession)) { return }

$mbx = Find-ExoRecipient -Prompt 'Whose Out of Office do you want to change? (name or email)' -Types 'UserMailbox', 'SharedMailbox'
if (-not $mbx) { return }
$id = $mbx.PrimarySmtpAddress

try { $cfg = Get-MailboxAutoReplyConfiguration -Identity $id -ErrorAction Stop }
catch { Write-Host "Could not read the Out of Office settings: $($_.Exception.Message)" -ForegroundColor Red; return }

Write-ToolHeader "Out of Office for $($mbx.DisplayName)"
Write-Host ("  Current status : {0}" -f (Format-OofStatus $cfg))
Write-Host ""
Write-ToolMenuItem -Key 1 -Label 'Turn ON Out of Office'
Write-ToolMenuItem -Key 2 -Label 'Turn OFF Out of Office'
Write-ToolMenuItem -Key 0 -Label 'Back'
Write-Host ''

switch ((Read-Host '  Select').Trim()) {
    '1' {
        Write-Host ""
        Write-Host "  How long should this run?" -ForegroundColor Cyan
        Write-ToolMenuItem -Key 1 -Label 'Indefinitely (stays on until someone turns it off)'
        Write-ToolMenuItem -Key 2 -Label 'For a set period (turns itself off at the end)'
        Write-Host ''

        # Exchange has two "on" states, and picking the right one is the whole
        # point of the question below:
        #   Enabled   - replies until somebody turns it off by hand.
        #   Scheduled - replies only between StartTime and EndTime, then stops
        #               on its own. Both times are required in this state.
        $state = 'Enabled'
        $start = $null
        $end   = $null

        switch ((Read-Host '  Select').Trim()) {
            '1' { $state = 'Enabled' }
            '2' {
                $state = 'Scheduled'
                $start = Read-OofDateTime -Prompt 'Start date and time (e.g. 2026-08-10 09:00, blank = now)' -AllowBlank
                if (-not $start) { $start = Get-Date }
                $end = Read-OofDateTime -Prompt 'End date and time (e.g. 2026-08-17 09:00)' -MustBeAfter $start
            }
            default { Write-Host "  Cancelled." -ForegroundColor Yellow; return }
        }

        Write-Host ""
        $internal = (Read-Host "  Message for people INSIDE the organisation").Trim()
        if (-not $internal) { $internal = 'I am currently out of the office and will reply when I return.' }

        Write-Host ""
        Write-Host "  Should people OUTSIDE the organisation get a reply too?" -ForegroundColor Cyan
        Write-ToolMenuItem -Key 1 -Label 'Yes - anyone outside the organisation'
        Write-ToolMenuItem -Key 2 -Label 'Yes - but only contacts they know'
        Write-ToolMenuItem -Key 3 -Label 'No external reply'
        Write-Host ''

        # ExternalAudience decides who outside the organisation gets a reply:
        #   All   - anyone who writes in
        #   Known - only senders already in the person's contacts
        #   None  - nobody outside gets a reply at all
        # "Known" is the quieter choice when a mailbox gets a lot of outside
        # mail, since it will not answer marketing lists or spam.
        $audience = 'None'
        $external = $null
        switch ((Read-Host '  Select').Trim()) {
            '1' { $audience = 'All' }
            '2' { $audience = 'Known' }
            default { $audience = 'None' }
        }
        if ($audience -ne 'None') {
            $external = (Read-Host "  Message for external senders (blank = same as internal)").Trim()
            if (-not $external) { $external = $internal }
        }

        $howLong = if ($state -eq 'Enabled') { 'Indefinite - stays on until turned off' }
                   else { "{0:yyyy-MM-dd HH:mm}  to  {1:yyyy-MM-dd HH:mm}" -f $start, $end }

        Write-Host ""
        Write-Host "  Check this before it goes on:" -ForegroundColor Cyan
        Write-Host ("    Mailbox  : {0}" -f $id)
        Write-Host ("    Runs for : {0}" -f $howLong)
        Write-Host ("    Internal : {0}" -f $internal)
        Write-Host ("    External : {0}" -f $(if ($audience -eq 'None') { 'no reply sent outside the organisation' } else { "$audience - $external" }))
        Write-Host ""
        if (-not (Confirm-DeskSideAction 'Proceed?' -Indent '  ')) { return }

        try {
            $params = @{
                Identity         = $id
                AutoReplyState   = $state
                InternalMessage  = $internal
                ExternalAudience = $audience
                ErrorAction      = 'Stop'
            }
            # Only send ExternalMessage when there is one; the cmdlet rejects $null.
            if ($external) { $params.ExternalMessage = $external }
            if ($state -eq 'Scheduled') {
                $params.StartTime = $start
                $params.EndTime   = $end
            }
            Set-MailboxAutoReplyConfiguration @params
            Write-Host "  Out of Office is on." -ForegroundColor Green
            Write-ActionLog -Action 'Exchange: Set Out of Office' -Target $id -Details "$howLong; external=$audience"
        }
        catch {
            Write-DeskSideFailure "  Failed" 'Exchange: Set Out of Office' $id $_
        }
    }
    '2' {
        if (-not (Confirm-DeskSideAction "Turn Out of Office OFF for $id?" -Indent '  ')) { return }
        try {
            Set-MailboxAutoReplyConfiguration -Identity $id -AutoReplyState Disabled -ErrorAction Stop
            Write-Host "  Out of Office is off." -ForegroundColor Green
            Write-ActionLog -Action 'Exchange: Disable Out of Office' -Target $id
        }
        catch {
            Write-DeskSideFailure "  Failed" 'Exchange: Disable Out of Office' $id $_
        }
    }
    default { return }
}
