<#
.SYNOPSIS
    Add, remove and list members of a distribution list (Exchange Online).

.DESCRIPTION
    Pick a distribution list by name or address, then add people, remove people,
    or just see who is on it.

    Sign-in is interactive the first time. Needs the ExchangeOnlineManagement
    module.

.EXAMPLE
    .\Manage-DistributionGroup.ps1
#>

[CmdletBinding()]
param()

. "$PSScriptRoot\..\..\lib\Common.ps1"

if (-not (Connect-ExoSession)) { return }

# Pick a distribution list (its own lookup - Find-ExoRecipient is fine too, but
# Get-DistributionGroup -ANR only returns lists, so there's no wrong pick).
function Select-DistributionGroup {
    $kw = (Read-Host "  Distribution list (name or email)").Trim()
    if (-not $kw) { return $null }
    try { $rows = @(Get-DistributionGroup -ANR $kw -ResultSize 25 -ErrorAction Stop) }
    catch { Write-Host "  Lookup failed: $($_.Exception.Message)" -ForegroundColor Red; return $null }
    if ($rows.Count -eq 0) { Write-Host "  No list matched '$kw'." -ForegroundColor Yellow; return $null }
    Select-FromList -Items $rows -Prompt '  Number' -Label { param($g) "{0}   <{1}>" -f $g.DisplayName, $g.PrimarySmtpAddress }
}

function Show-Members ($group) {
    try { $members = @(Get-DistributionGroupMember -Identity $group.PrimarySmtpAddress -ResultSize Unlimited -ErrorAction Stop) }
    catch { Write-Host "  Could not read members: $($_.Exception.Message)" -ForegroundColor Red; return }
    Write-Host ("`n  {0} member(s) of {1}:" -f $members.Count, $group.DisplayName) -ForegroundColor Cyan
    if ($members.Count -eq 0) { Write-Host "    (empty)" -ForegroundColor DarkGray; return }
    $members | Sort-Object DisplayName | ForEach-Object { Write-Host ("    {0}   <{1}>" -f $_.DisplayName, $_.PrimarySmtpAddress) }
}

function Add-Members ($group) {
    $people = ConvertFrom-PeopleList (Read-Host "  People to ADD (emails, comma-separated)")
    if ($people.Count -eq 0) { Write-Host "  Nobody entered." -ForegroundColor Yellow; return }
    Write-Host "`n  Add to $($group.DisplayName):" -ForegroundColor Cyan
    $people | ForEach-Object { Write-Host "    - $_" }
    if (-not (Confirm-DeskSideAction 'Proceed?' -Indent '  ')) { return }
    foreach ($p in $people) {
        try {
            Add-DistributionGroupMember -Identity $group.PrimarySmtpAddress -Member $p -ErrorAction Stop
            Write-Host "    $p - added." -ForegroundColor Green
            Write-ActionLog -Action 'Exchange: DL Add Member' -Target $group.PrimarySmtpAddress -Details $p
        }
        catch {
            $msg = $_.Exception.Message
            if ($msg -match 'already a member') { Write-Host "    $p - already a member." -ForegroundColor DarkGray }
            else {
                Write-Host "    $p - failed: $msg" -ForegroundColor Red
                Write-ActionLog -Action 'Exchange: DL Add Member' -Target $group.PrimarySmtpAddress -Result 'Failed' -Details "$p - $msg"
            }
        }
    }
}

function Remove-Members ($group) {
    $people = ConvertFrom-PeopleList (Read-Host "  People to REMOVE (emails, comma-separated)")
    if ($people.Count -eq 0) { Write-Host "  Nobody entered." -ForegroundColor Yellow; return }
    Write-Host "`n  Remove from $($group.DisplayName):" -ForegroundColor Yellow
    $people | ForEach-Object { Write-Host "    - $_" }
    if (-not (Confirm-DeskSideAction 'Proceed?' -Indent '  ')) { return }
    foreach ($p in $people) {
        try {
            Remove-DistributionGroupMember -Identity $group.PrimarySmtpAddress -Member $p -Confirm:$false -ErrorAction Stop
            Write-Host "    $p - removed." -ForegroundColor Green
            Write-ActionLog -Action 'Exchange: DL Remove Member' -Target $group.PrimarySmtpAddress -Details $p
        }
        catch {
            Write-Host "    $p - failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-ActionLog -Action 'Exchange: DL Remove Member' -Target $group.PrimarySmtpAddress -Result 'Failed' -Details "$p - $($_.Exception.Message)"
        }
    }
}

# --- Menu --------------------------------------------------------------------
Write-ToolHeader 'Distribution lists'
$group = Select-DistributionGroup
if (-not $group) { return }

while ($true) {
    Write-Host ("`n  List: {0}   <{1}>" -f $group.DisplayName, $group.PrimarySmtpAddress) -ForegroundColor DarkCyan
    Write-ToolMenuItem -Key 1 -Label 'List members'
    Write-ToolMenuItem -Key 2 -Label 'Add member(s)'
    Write-ToolMenuItem -Key 3 -Label 'Remove member(s)'
    Write-ToolMenuItem -Key 'C' -Label 'Choose a different list'
    Write-ToolMenuItem -Key 0 -Label 'Back'
    Write-Host ''

    switch ((Read-Host '  Select').Trim().ToUpper()) {
        '1'     { Show-Members  $group }
        '2'     { Add-Members   $group }
        '3'     { Remove-Members $group }
        'C'     { $g = Select-DistributionGroup; if ($g) { $group = $g } }
        '0'     { return }
        default { Write-Host 'Unknown option.' -ForegroundColor DarkGray }
    }
}
