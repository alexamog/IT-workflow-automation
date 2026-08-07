<#
.SYNOPSIS
    Set or clear mail forwarding on a mailbox (Exchange Online).

.DESCRIPTION
    Point a mailbox's incoming mail at another address, or turn forwarding off.
    You can also choose whether a copy is KEPT in the original mailbox as well as
    forwarded (usually yes).

    Sign-in is interactive the first time. Needs the ExchangeOnlineManagement
    module.

.EXAMPLE
    .\Set-MailboxForwarding.ps1
#>

[CmdletBinding()]
param()

. "$PSScriptRoot\..\..\lib\Common.ps1"

if (-not (Connect-ExoSession)) { return }

$mbx = Find-ExoRecipient -Prompt 'Mailbox to change (name or email)' -Types 'UserMailbox', 'SharedMailbox'
if (-not $mbx) { return }
$id = $mbx.PrimarySmtpAddress

try { $box = Get-Mailbox -Identity $id -ErrorAction Stop }
catch { Write-Host "Could not read the mailbox: $($_.Exception.Message)" -ForegroundColor Red; return }

$current = if ($box.ForwardingSmtpAddress) { "$($box.ForwardingSmtpAddress)" }
           elseif ($box.ForwardingAddress) { "$($box.ForwardingAddress)" }
           else { '(none)' }

Write-ToolHeader "Forwarding for $($box.DisplayName)"
Write-Host ("  Currently forwarding to : {0}" -f $current)
Write-Host ("  Keep a copy in mailbox  : {0}" -f $box.DeliverToMailboxAndForward)
Write-Host ""
Write-ToolMenuItem -Key 1 -Label 'Set forwarding to an address'
Write-ToolMenuItem -Key 2 -Label 'Turn forwarding OFF'
Write-ToolMenuItem -Key 0 -Label 'Back'
Write-Host ''

switch ((Read-Host '  Select').Trim()) {
    '1' {
        $dest = (Read-Host "  Forward to (email address)").Trim()
        if (-not $dest) { Write-Host "  Cancelled." -ForegroundColor Yellow; return }
        # -DefaultYes: keeping a copy is the safe, usual answer, so a bare ENTER
        # keeps it. This is choosing a setting, not guarding an action.
        $keep = Confirm-DeskSideAction 'Keep a copy in the original mailbox too?' -DefaultYes -Quiet -Indent '  '

        Write-Host ""
        Write-Host ("  Forward {0}  ->  {1}   (keep copy: {2})" -f $id, $dest, $keep) -ForegroundColor Cyan
        if (-not (Confirm-DeskSideAction 'Proceed?' -Indent '  ')) { return }
        try {
            # ForwardingSmtpAddress works for any address (inside or outside the org).
            Set-Mailbox -Identity $id -ForwardingSmtpAddress $dest -DeliverToMailboxAndForward $keep -ErrorAction Stop
            Write-Host "  Forwarding set." -ForegroundColor Green
            Write-ActionLog -Action 'Exchange: Set Forwarding' -Target $id -Details "-> $dest; keepCopy=$keep"
        }
        catch {
            Write-DeskSideFailure "  Failed" 'Exchange: Set Forwarding' $id $_
        }
    }
    '2' {
        if (-not (Confirm-DeskSideAction "Turn forwarding OFF for $id?" -Indent '  ')) { return }
        try {
            Set-Mailbox -Identity $id -ForwardingSmtpAddress $null -ForwardingAddress $null -DeliverToMailboxAndForward $false -ErrorAction Stop
            Write-Host "  Forwarding removed." -ForegroundColor Green
            Write-ActionLog -Action 'Exchange: Remove Forwarding' -Target $id
        }
        catch {
            Write-DeskSideFailure "  Failed" 'Exchange: Remove Forwarding' $id $_
        }
    }
    default { return }
}
