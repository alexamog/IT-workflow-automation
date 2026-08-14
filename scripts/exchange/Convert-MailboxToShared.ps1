<#
.SYNOPSIS
    Convert a leaver's user mailbox into a shared mailbox (Exchange Online).

.DESCRIPTION
    Part of offboarding: when someone leaves, their mailbox is usually turned
    into a SHARED mailbox so the team keeps the email and the paid licence can be
    freed. This does the mailbox conversion only.

    IT DOES NOT touch the AD account or the Microsoft 365 licence - disable the
    account with the Offboarding tool, and remove the licence in the 365 admin
    centre. A shared mailbox under 50 GB needs no licence, which is the point.

    Sign-in is interactive the first time. Needs the ExchangeOnlineManagement
    module.

.EXAMPLE
    .\Convert-MailboxToShared.ps1
#>

[CmdletBinding()]
param()

. "$PSScriptRoot\..\..\lib\Common.ps1"

if (-not (Connect-ExoSession)) { return }

$mbx = Find-ExoRecipient -Prompt "Mailbox to convert (the leaver's name or email)" -Types 'UserMailbox'
if (-not $mbx) { return }
$id = $mbx.PrimarySmtpAddress

# Show what it is now so the operator is sure it's the right person.
try { $box = Get-Mailbox -Identity $id -ErrorAction Stop }
catch { Write-Host "Could not read the mailbox: $($_.Exception.Message)" -ForegroundColor Red; return }

Write-ToolHeader 'Convert mailbox to shared'
Write-Host ("  Name    : {0}" -f $box.DisplayName)
Write-Host ("  Address : {0}" -f $box.PrimarySmtpAddress)
Write-Host ("  Type    : {0}" -f $box.RecipientTypeDetails)
Write-Host ""

if ($box.RecipientTypeDetails -eq 'SharedMailbox') {
    Write-Host "  This mailbox is already shared - nothing to do." -ForegroundColor Yellow
    return
}

Write-Host "  Converting to a shared mailbox keeps all the mail. The person can no" -ForegroundColor Yellow
Write-Host "  longer sign in to it directly; the team opens it as a shared mailbox." -ForegroundColor Yellow
Write-Host "  Disable the AD account (Offboarding) and remove the 365 licence separately." -ForegroundColor DarkGray
Write-Host ""
if (-not (Confirm-DeskSideWord 'convert' -CancelNote 'nothing changed' -Indent '  ')) { return }

try {
    Set-Mailbox -Identity $id -Type Shared -ErrorAction Stop
    Write-Host "  Converted $id to a shared mailbox." -ForegroundColor Green
    Write-ActionLog -Action 'Exchange: Convert Mailbox to Shared' -Target $id -Details "was $($box.RecipientTypeDetails)"
}
catch {
    Write-DeskSideFailure "  Convert failed" 'Exchange: Convert Mailbox to Shared' $id $_
}
