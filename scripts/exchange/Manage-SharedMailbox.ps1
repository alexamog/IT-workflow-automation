<#
.SYNOPSIS
    Create shared mailboxes and manage who can use them (Exchange Online),
    including adding yourself to a mailbox to investigate.

.DESCRIPTION
    The most common mailbox-access jobs from tickets, in one place:
      - Create a new shared mailbox.
      - Add or remove access by permission: Full Access, Send As, Send on
        Behalf (or the usual Full Access + Send As combo).
      - See who currently has access (Full Access, Send As, Send on Behalf).
      - Add YOURSELF Full Access to any mailbox to investigate it, and step
        back out again when you're done.

    "Full Access" lets someone open and read the mailbox. "Send As" lets them
    send email that looks like it came from the mailbox itself. "Send on Behalf"
    sends as "<you> on behalf of <mailbox>". Most requests ("able to send and
    read") want Full Access + Send As. Add/remove works on shared AND regular
    user mailboxes, so the same tool covers delegating access and investigating
    a leaver's mailbox.

    Sign-in is interactive the first time - a Microsoft sign-in window opens.
    Set your admin address once with .\setup\Set-ExchangeAdmin.ps1 to skip
    typing it. Needs the ExchangeOnlineManagement module (the tool tells you how
    to install it if it is missing).

.EXAMPLE
    .\Manage-SharedMailbox.ps1
#>

[CmdletBinding()]
param()

. "$PSScriptRoot\..\..\lib\Common.ps1"

if (-not (Connect-ExoSession)) { return }

# --- Create a shared mailbox -------------------------------------------------
function New-SharedMailbox {
    $name = (Read-Host "  Display name for the mailbox (e.g. CSW Powell Horizons SRP)").Trim()
    if (-not $name) { Write-Host "  Cancelled." -ForegroundColor Yellow; return }
    $addr = (Read-Host "  Email address (e.g. team-inbox@contoso.com)").Trim()
    if (-not $addr) { Write-Host "  Cancelled." -ForegroundColor Yellow; return }

    Write-Host ""
    Write-Host "  About to create a shared mailbox:" -ForegroundColor Cyan
    Write-Host ("    Name    : {0}" -f $name)
    Write-Host ("    Address : {0}" -f $addr)
    if (-not (Confirm-DeskSideAction 'Create it?' -Indent '  ')) { return }

    try {
        New-Mailbox -Shared -Name $name -DisplayName $name -PrimarySmtpAddress $addr -ErrorAction Stop | Out-Null
        Write-Host "  Created '$name' <$addr>." -ForegroundColor Green
        Write-ActionLog -Action 'Exchange: Create Shared Mailbox' -Target $addr -Details "name=$name"
    }
    catch {
        Write-Host "  Create failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-ActionLog -Action 'Exchange: Create Shared Mailbox' -Target $addr -Result 'Failed' -Details $_.Exception.Message
        return
    }

    if (Confirm-DeskSideAction 'Add people to it now?' -Indent '  ' -Quiet) { Grant-Access -Mailbox $addr }
}

# Apply ONE permission kind (Full / SendAs / SendOnBehalf) to a batch of people.
# $Add = $true grants, $false removes. Removal tolerates a permission that was
# not there (no red error for "nothing to remove").
function Set-MailboxPermKind ($Mailbox, $Kind, [bool]$Add, $People) {
    $label = switch ($Kind) { 'Full' { 'Full Access' } 'SendAs' { 'Send As' } 'SendOnBehalf' { 'Send on Behalf' } }
    foreach ($p in $People) {
        try {
            if ($Add) {
                switch ($Kind) {
                    'Full'         { Add-MailboxPermission   -Identity $Mailbox -User $p    -AccessRights FullAccess -InheritanceType All -AutoMapping $true -ErrorAction Stop | Out-Null }
                    'SendAs'       { Add-RecipientPermission -Identity $Mailbox -Trustee $p -AccessRights SendAs -Confirm:$false -ErrorAction Stop | Out-Null }
                    'SendOnBehalf' { Set-Mailbox -Identity $Mailbox -GrantSendOnBehalfTo @{ Add = $p } -ErrorAction Stop }
                }
                Write-Host ("    {0} - granted {1}." -f $p, $label) -ForegroundColor Green
                Write-ActionLog -Action "Exchange: Grant $label" -Target $Mailbox -Details $p
            }
            else {
                switch ($Kind) {
                    'Full'         { Remove-MailboxPermission   -Identity $Mailbox -User $p    -AccessRights FullAccess -Confirm:$false -ErrorAction SilentlyContinue | Out-Null }
                    'SendAs'       { Remove-RecipientPermission -Identity $Mailbox -Trustee $p -AccessRights SendAs -Confirm:$false -ErrorAction SilentlyContinue | Out-Null }
                    'SendOnBehalf' { Set-Mailbox -Identity $Mailbox -GrantSendOnBehalfTo @{ Remove = $p } -ErrorAction SilentlyContinue }
                }
                Write-Host ("    {0} - removed {1} (if it was set)." -f $p, $label) -ForegroundColor Green
                Write-ActionLog -Action "Exchange: Remove $label" -Target $Mailbox -Details $p
            }
        }
        catch {
            Write-Host "    $p - failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-ActionLog -Action ("Exchange: {0} {1}" -f $(if ($Add) { 'Grant' } else { 'Remove' }), $label) -Target $Mailbox -Result 'Failed' -Details "$p - $($_.Exception.Message)"
        }
    }
}

# Ask which permission(s) to act on. Returns an array of kinds, or $null.
# -ForRemoval adds an "all of the above" choice.
function Select-MailboxPermission ([switch]$ForRemoval) {
    Write-Host "  Which permission?" -ForegroundColor Cyan
    Write-ToolMenuItem -Key 1 -Label 'Full Access'    -Note 'open & read the mailbox'
    Write-ToolMenuItem -Key 2 -Label 'Send As'        -Note 'send AS the mailbox'
    Write-ToolMenuItem -Key 3 -Label 'Send on Behalf' -Note 'send ON BEHALF OF the mailbox'
    Write-ToolMenuItem -Key 4 -Label 'Full Access + Send As' -Note 'the usual combo'
    if ($ForRemoval) { Write-ToolMenuItem -Key 5 -Label 'All of the above' }
    switch ((Read-Host '  Select').Trim()) {
        '1'     { , @('Full') }
        '2'     { , @('SendAs') }
        '3'     { , @('SendOnBehalf') }
        '4'     { , @('Full', 'SendAs') }
        '5'     { if ($ForRemoval) { , @('Full', 'SendAs', 'SendOnBehalf') } else { $null } }
        default { $null }
    }
}

# The common combo (Full + Send As), used right after creating a mailbox.
function Grant-Access ($Mailbox) {
    $people = ConvertFrom-PeopleList (Read-Host "  People to grant access (Full Access + Send As)")
    if ($people.Count -eq 0) { Write-Host "  Nobody entered." -ForegroundColor Yellow; return }
    Set-MailboxPermKind $Mailbox 'Full'   $true $people
    Set-MailboxPermKind $Mailbox 'SendAs' $true $people
}

# --- Add / remove access by permission ---------------------------------------
function Add-MailboxAccess {
    $mbx = Find-ExoRecipient -Prompt 'Mailbox (name or email)' -Types 'SharedMailbox', 'UserMailbox'
    if (-not $mbx) { return }
    $kinds = Select-MailboxPermission
    if (-not $kinds) { Write-Host "  Cancelled." -ForegroundColor Yellow; return }
    $people = ConvertFrom-PeopleList (Read-Host "  People to ADD (emails, comma-separated)")
    if ($people.Count -eq 0) { Write-Host "  Nobody entered." -ForegroundColor Yellow; return }
    foreach ($k in $kinds) { Set-MailboxPermKind $mbx.PrimarySmtpAddress $k $true $people }
}

function Remove-MailboxAccess {
    $mbx = Find-ExoRecipient -Prompt 'Mailbox (name or email)' -Types 'SharedMailbox', 'UserMailbox'
    if (-not $mbx) { return }
    $kinds = Select-MailboxPermission -ForRemoval
    if (-not $kinds) { Write-Host "  Cancelled." -ForegroundColor Yellow; return }
    $people = ConvertFrom-PeopleList (Read-Host "  People to REMOVE (emails, comma-separated)")
    if ($people.Count -eq 0) { Write-Host "  Nobody entered." -ForegroundColor Yellow; return }

    # Taking access away is the one path here that can lock somebody out of a
    # mailbox they are working in, so show exactly what is about to happen and
    # make the operator agree to it. Every other remove in the toolkit asks.
    Write-Host ""
    Write-Host ("  Remove {0} from {1} <{2}>" -f ($kinds -join ' + '), $mbx.DisplayName, $mbx.PrimarySmtpAddress) -ForegroundColor Cyan
    Write-Host ("  For: {0}" -f ($people -join ', ')) -ForegroundColor Cyan
    if (-not (Confirm-DeskSideAction 'Proceed?' -Indent '  ')) { return }

    foreach ($k in $kinds) { Set-MailboxPermKind $mbx.PrimarySmtpAddress $k $false $people }
}

# --- Add / remove ME (Full Access) to investigate a mailbox ------------------
function Add-MeToMailbox {
    $mbx = Find-ExoRecipient -Prompt 'Mailbox to investigate (name or email)' -Types 'SharedMailbox', 'UserMailbox'
    if (-not $mbx) { return }
    $me = Get-DeskSideAdminUpn
    if (-not $me) { return }
    $addr = $mbx.PrimarySmtpAddress
    Write-Host ("  Grant {0} Full Access to {1} <{2}>?" -f $me, $mbx.DisplayName, $addr) -ForegroundColor Cyan
    if (-not (Confirm-DeskSideAction 'Go ahead?' -Indent '  ')) { return }
    Set-MailboxPermKind $addr 'Full' $true @($me)
    Write-Host "  In Outlook it may take a while to auto-appear; you can also use" -ForegroundColor DarkGray
    Write-Host "  File > Open & Export > Other User's Folder, or open the mailbox in OWA." -ForegroundColor DarkGray
}

function Remove-MeFromMailbox {
    $mbx = Find-ExoRecipient -Prompt 'Mailbox to step out of (name or email)' -Types 'SharedMailbox', 'UserMailbox'
    if (-not $mbx) { return }
    $me = Get-DeskSideAdminUpn
    if (-not $me) { return }
    $addr = $mbx.PrimarySmtpAddress
    # Mirrors the confirmation in Add-MeToMailbox: say what is about to change
    # before changing it, so stepping out of the wrong mailbox takes two steps.
    Write-Host ("  Remove {0}'s Full Access to {1} <{2}>?" -f $me, $mbx.DisplayName, $addr) -ForegroundColor Cyan
    if (-not (Confirm-DeskSideAction 'Go ahead?' -Indent '  ')) { return }
    Set-MailboxPermKind $addr 'Full' $false @($me)
}

# --- List access -------------------------------------------------------------
function Show-Access {
    $mbx = Find-ExoRecipient -Prompt 'Mailbox (name or email)' -Types 'SharedMailbox', 'UserMailbox'
    if (-not $mbx) { return }
    $Mailbox = $mbx.PrimarySmtpAddress

    Write-Host "`n  Full Access:" -ForegroundColor Cyan
    try {
        $full = @(Get-MailboxPermission -Identity $Mailbox -ErrorAction Stop |
            Where-Object { $_.User -notlike 'NT AUTHORITY\*' -and -not $_.IsInherited -and $_.User -ne $Mailbox })
        if ($full.Count) { $full | ForEach-Object { Write-Host ("    {0}  ({1})" -f $_.User, ($_.AccessRights -join ',')) } }
        else { Write-Host "    (none beyond the owner)" -ForegroundColor DarkGray }
    } catch { Write-Host "    Could not read: $($_.Exception.Message)" -ForegroundColor Red }

    Write-Host "  Send As:" -ForegroundColor Cyan
    try {
        $sa = @(Get-RecipientPermission -Identity $Mailbox -ErrorAction Stop |
            Where-Object { $_.Trustee -notlike 'NT AUTHORITY\*' })
        if ($sa.Count) { $sa | ForEach-Object { Write-Host ("    {0}" -f $_.Trustee) } }
        else { Write-Host "    (none)" -ForegroundColor DarkGray }
    } catch { Write-Host "    Could not read: $($_.Exception.Message)" -ForegroundColor Red }

    Write-Host "  Send on Behalf:" -ForegroundColor Cyan
    try {
        $sob = @((Get-Mailbox -Identity $Mailbox -ErrorAction Stop).GrantSendOnBehalfTo)
        if ($sob.Count) { $sob | ForEach-Object { Write-Host ("    {0}" -f $_) } }
        else { Write-Host "    (none)" -ForegroundColor DarkGray }
    } catch { Write-Host "    Could not read: $($_.Exception.Message)" -ForegroundColor Red }
}

# --- Menu --------------------------------------------------------------------
while ($true) {
    Write-ToolHeader 'Shared mailboxes'
    Write-ToolMenuItem -Key 1 -Label 'Create a shared mailbox'
    Write-ToolMenuItem -Key 2 -Label 'Add access' -Note 'Full Access / Send As / Send on Behalf'
    Write-ToolMenuItem -Key 3 -Label 'Remove access'
    Write-ToolMenuItem -Key 4 -Label 'Show who has access'
    Write-ToolMenuItem -Key 5 -Label 'Add ME (Full Access) to investigate a mailbox'
    Write-ToolMenuItem -Key 6 -Label 'Remove ME from a mailbox'
    Write-ToolMenuItem -Key 0 -Label 'Back'
    Write-Host ''

    switch ((Read-Host '  Select').Trim()) {
        '1'     { New-SharedMailbox }
        '2'     { Add-MailboxAccess }
        '3'     { Remove-MailboxAccess }
        '4'     { Show-Access }
        '5'     { Add-MeToMailbox }
        '6'     { Remove-MeFromMailbox }
        '0'     { return }
        default { Write-Host 'Unknown option.' -ForegroundColor DarkGray }
    }
}
