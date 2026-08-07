<#
.SYNOPSIS
    Offboard leavers - one person, or a whole list - by disabling their account.

.DESCRIPTION
    Most leavers are already disabled by the time the request reaches you. The
    point of this script is to tell you quickly WHICH ONES ARE NOT, and to
    disable those after you have looked at them and agreed.

    ONE PERSON OR A LIST
    Run it with no arguments and it asks which you want. Or say up front:

        .\Start-Offboarding.ps1 -Name "Jane Sample"     one person
        .\Start-Offboarding.ps1 -Path .\leavers.txt     a list

    Either way the person is found by their FULL NAME, the same three-pass
    search batch onboarding uses, so "Jane Sample" still finds an account
    stored as "Sample, Jane".

    (To disable somebody by their username instead, and for unlock/enable, use
    Account Actions > Lock / Unlock / Enable.)

    THE LIST FILE
    Run this with no file and File Explorer opens so you can click the list.

    Same format as batch onboarding - either name and role on one line:

        Dana Example, Cas SRW
        Rowan Sample          Cas SRW

    or name on one line and role on the next, as pasted out of an email:

        Dana Example

        Cas SRW

        Rowan Sample

        CSW005

    A line starting with # is ignored, so you can leave yourself notes.

    The role is only used to help you recognise the person in the report. It is
    never checked against AD and never changed here.

    WHAT HAPPENS
      1. Everyone is looked up. Nothing is changed.
      2. You get a report: already disabled, still ENABLED, not found, or
         matching several accounts.
      3. Only the still-enabled ones are offered for disabling, listed one by
         one with their details. You confirm before anything happens.

    Anyone not found or matching several accounts is written to an exceptions
    file in output\ for you to handle by hand.

.PARAMETER Name
    Offboard one person, by their full name. No file needed.

.PARAMETER Path
    The list file, to offboard several people. If neither -Name nor -Path is
    given, you are asked which you want and a file picker opens if you choose
    the list.

.PARAMETER ConfirmMode
    How to confirm the disables:
      'Each' (default) - shown one at a time, answer for each person
      'Once'           - shown as one list, one yes/no for all of them

.EXAMPLE
    .\Start-Offboarding.ps1 -Name "Jane Sample"

.EXAMPLE
    .\Start-Offboarding.ps1 .\leavers.txt

.EXAMPLE
    # Longer list, confirm the whole set in one go after reviewing it:
    .\Start-Offboarding.ps1 .\leavers.txt -ConfirmMode Once
#>

#Requires -Modules ActiveDirectory
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Path,

    [string]$Name,

    [ValidateSet('Each', 'Once')]
    [string]$ConfirmMode = 'Each'
)

. "$PSScriptRoot\..\..\lib\Common.ps1"

Write-Host ("Running as: {0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) -ForegroundColor DarkGray

# --- 1. Work out who we are offboarding --------------------------------------
# Nothing said either way (the normal case when run from the menu) - ask.
if (-not $Path -and -not $Name) {
    Write-Host ""
    Write-Host "  1. One person (type their name)"
    Write-Host "  2. A list of people (pick a file)"
    Write-Host "  0. Cancel"
    switch ((Read-Host "`nOffboard").Trim()) {
        '1'     { $Name = (Read-Host "  Full name of the person leaving").Trim() }
        '2'     {
            Write-Host "`nOpening File Explorer to pick the list of leavers..." -ForegroundColor Cyan
            Write-Host "(if you don't see it, check behind this window)" -ForegroundColor DarkGray
            $Path = Select-LocalFilePath -Title 'Choose the list of leavers' `
                                         -Filter 'Text files (*.txt)|*.txt|All files (*.*)|*.*' `
                                         -Prompt '  Path to the list file'
        }
        default { Write-Host "Cancelled." -ForegroundColor Yellow; return }
    }
}

# Both routes end up as the same list of people, so everything below this point
# treats one person and fifty people exactly the same way.
if ($Name) {
    $roster = @([pscustomobject]@{
        LineNumber = 1
        Name       = $Name
        Role       = ''
        Location   = ''
        RawLine    = $Name
        ParseNote  = ''
    })
    Write-Host "`nOffboarding one person: $Name" -ForegroundColor Cyan
}
else {
    if (-not $Path) { Write-Host "No file chosen - cancelled." -ForegroundColor Yellow; return }

    try { $roster = Import-StaffRosterFile -Path $Path }
    catch { Write-Host $_.Exception.Message -ForegroundColor Red; return }

    if ($roster.Count -eq 0) { Write-Host "No people found in $Path." -ForegroundColor Yellow; return }
    Write-Host "`nRead $($roster.Count) person(s) from $(Split-Path $Path -Leaf)." -ForegroundColor Cyan
}

# --- 2. Look everyone up (read-only - nothing is changed yet) ----------------
Write-Host $(if ($roster.Count -eq 1) { "Looking them up in Active Directory..." }
             else { "Looking each person up in Active Directory..." }) -ForegroundColor DarkGray

$plan = foreach ($person in $roster) {
    $lookup = Resolve-ADToolUserByName -Name $person.Name -Properties @(
        'DisplayName', 'SamAccountName', 'UserPrincipalName', 'EmailAddress',
        'Description', 'Title', 'Department', 'Office', 'Enabled', 'LastLogonDate'
    )
    $user = if ($lookup.Status -eq 'Matched') { $lookup.Users[0] } else { $null }

    # Four outcomes: already done, needs doing, or a person we cannot act on.
    $outcome = if ($lookup.Status -eq 'NotFound')  { 'NotFound' }
               elseif ($lookup.Status -eq 'Ambiguous') { 'Ambiguous' }
               elseif ($user.Enabled)              { 'StillEnabled' }
               else                                { 'AlreadyDisabled' }

    [pscustomobject]@{
        LineNumber  = $person.LineNumber
        Name        = $person.Name
        Role        = $person.Role
        Outcome     = $outcome
        MatchedBy   = $lookup.MatchedBy
        Sam         = if ($user) { $user.SamAccountName } else { '' }
        Upn         = if ($user) { $user.UserPrincipalName } else { '' }
        Email       = if ($user) { $user.EmailAddress }   else { '' }
        DisplayName = if ($user) { $user.DisplayName }    else { '' }
        Description = if ($user) { $user.Description }    else { '' }
        Office      = if ($user) { $user.Office }         else { '' }
        LastLogon   = if ($user) { $user.LastLogonDate }  else { $null }
        Note        = if ($lookup.Status -eq 'Ambiguous') {
                          "matches $($lookup.Users.Count) accounts: " + (($lookup.Users | ForEach-Object { $_.SamAccountName }) -join ', ')
                      } elseif ($lookup.Status -eq 'NotFound') { 'no account found' } else { '' }
    }
}

$alreadyDisabled = @($plan | Where-Object Outcome -eq 'AlreadyDisabled')
$stillEnabled    = @($plan | Where-Object Outcome -eq 'StillEnabled')
$notFound        = @($plan | Where-Object Outcome -eq 'NotFound')
$ambiguous       = @($plan | Where-Object Outcome -eq 'Ambiguous')

# --- 3. Report ---------------------------------------------------------------
Write-ToolHeader 'Findings'

if ($alreadyDisabled.Count) {
    Write-Host "`nALREADY DISABLED ($($alreadyDisabled.Count)) - nothing to do:" -ForegroundColor DarkGray
    $alreadyDisabled | ForEach-Object { Write-Host ("   {0,-26} {1}" -f $_.Name, $_.Sam) -ForegroundColor DarkGray }
}

if ($notFound.Count) {
    Write-Host "`nNO ACCOUNT FOUND ($($notFound.Count)) - check these by hand:" -ForegroundColor Red
    $notFound | ForEach-Object { Write-Host ("   line {0,-4} {1}" -f $_.LineNumber, $_.Name) }
}

if ($ambiguous.Count) {
    Write-Host "`nNAME MATCHES SEVERAL ACCOUNTS ($($ambiguous.Count)) - do these by hand:" -ForegroundColor Red
    Write-Host "   (never guessed at - disabling the wrong person locks out a working employee)" -ForegroundColor DarkGray
    $ambiguous | ForEach-Object { Write-Host ("   line {0,-4} {1,-26} {2}" -f $_.LineNumber, $_.Name, $_.Note) }
}

if ($stillEnabled.Count -eq 0) {
    Write-Host "`nNo accounts still enabled. Nothing to disable." -ForegroundColor Green
}
else {
    Write-Host "`nSTILL ENABLED ($($stillEnabled.Count)) - these need your decision:" -ForegroundColor Yellow
}

# --- 4. Confirm and disable --------------------------------------------------
$disabled = 0
$skipped  = 0
$failed   = 0

# Print everything known about one person, so the decision is an informed one.
function Show-Leaver ($p) {
    Write-Host ""
    Write-Host ("  Name        : {0}" -f $p.DisplayName) -ForegroundColor White
    Write-Host ("  Account     : {0}" -f $p.Sam)
    Write-Host ("  {0}: {1}{2}" -f $(if ($Name) { 'You typed   ' } else { 'On the list ' }),
                                   $p.Name, $(if ($p.Role) { " ($($p.Role))" } else { '' }))
    Write-Host ("  Description : {0}" -f $p.Description)
    Write-Host ("  Office      : {0}" -f $p.Office)
    Write-Host ("  Last logon  : {0}" -f $(if ($p.LastLogon) { $p.LastLogon } else { 'never / unknown' }))
    if ($p.MatchedBy -eq 'NameParts') {
        Write-Host "  NOTE        : matched loosely on name parts, not exactly - check this is the right person." -ForegroundColor Yellow
    }
}

$approved = @()

if ($stillEnabled.Count -gt 0) {
    if ($ConfirmMode -eq 'Once') {
        $stillEnabled | ForEach-Object { Show-Leaver $_ }
        Write-Host ""
        Write-Host "Disabling an account signs the person out of the domain and blocks new logins." -ForegroundColor Yellow
        if (Confirm-DeskSideAction "Disable all $($stillEnabled.Count) account(s) listed above?" -Quiet) {
            $approved = $stillEnabled
        }
        else {
            Write-Host "Cancelled - no accounts disabled." -ForegroundColor Yellow
            $skipped = $stillEnabled.Count
        }
    }
    else {
        foreach ($p in $stillEnabled) {
            Show-Leaver $p
            $answer = Read-Host "  Disable this account? (Y = yes, N = skip, Q = stop here)"
            if ($answer -match '^[Qq]') {
                Write-Host "  Stopped. Remaining accounts left alone." -ForegroundColor Yellow
                $skipped += @($stillEnabled | Where-Object { $_.LineNumber -ge $p.LineNumber }).Count
                break
            }
            if ($answer -match '^[Yy]') { $approved += $p }
            else { Write-Host "  Skipped." -ForegroundColor DarkGray; $skipped++ }
        }
    }
}

# Where this run's names came from, recorded on every audit row so the log shows
# whether a disable was done one-off or as part of a list.
$source = if ($Name) { 'by name' } else { "from list: $(Split-Path $Path -Leaf)" }

$justDisabled = @()
foreach ($p in $approved) {
    try {
        Disable-ADAccount -Identity $p.Sam -ErrorAction Stop
        Write-Host "  Disabled $($p.Sam)." -ForegroundColor Green
        Write-ActionLog -Action 'Offboard: Disable Account' -Target $p.Sam `
            -Details "$source - $($p.Name)$(if ($p.Role) { " ($($p.Role))" })"
        $disabled++
        $justDisabled += $p
    }
    catch {
        Write-Host "  Could not disable $($p.Sam): $($_.Exception.Message)" -ForegroundColor Red
        Write-ActionLog -Action 'Offboard: Disable Account' -Target $p.Sam `
            -Result 'Failed' -Details "$source - $($_.Exception.Message)"
        $failed++
    }
}

# --- 4b. Mailbox + licence cleanup (Microsoft 365) ---------------------------
# For the offboarded people - the ones just disabled AND any that were already
# disabled - offer to convert the mailbox to a shared mailbox and remove the
# Office 365 E1 licence. Order matters: convert WHILE still licensed, then drop
# the licence (a shared mailbox under 50 GB needs none). Every step is optional
# and skips cleanly (no mailbox / not licensed / could not connect).
$cloudTargets = @(@($alreadyDisabled) + @($justDisabled) | Where-Object { $_.Upn })
if ($cloudTargets.Count -gt 0 -and
    (Confirm-DeskSideAction "Also convert the mailbox to shared and remove the Office 365 E1 licence for $($cloudTargets.Count) account(s)?" -Quiet)) {

    $exoOk   = Connect-ExoSession
    $mgOk    = Connect-MgGraphSession
    $e1Sku   = if ($mgOk) { Get-M365LicenseSku } else { $null }

    foreach ($p in $cloudTargets) {
        $upn = $p.Upn
        Write-Host "`n  $($p.DisplayName)  <$upn>" -ForegroundColor Cyan

        # 1. Convert mailbox to shared.
        if ($exoOk) {
            try {
                $box = Get-Mailbox -Identity $upn -ErrorAction Stop
                if ($box.RecipientTypeDetails -eq 'SharedMailbox') {
                    Write-Host "    Mailbox already shared." -ForegroundColor DarkGray
                }
                else {
                    Set-Mailbox -Identity $upn -Type Shared -ErrorAction Stop
                    Write-Host "    Mailbox converted to shared." -ForegroundColor Green
                    Write-ActionLog -Action 'Offboard: Convert Mailbox to Shared' -Target $upn -Details "was $($box.RecipientTypeDetails)"
                }
            }
            catch {
                Write-Host "    Mailbox: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-ActionLog -Action 'Offboard: Convert Mailbox to Shared' -Target $upn -Result 'Failed' -Details $_.Exception.Message
            }
        }

        # 2. Remove the E1 licence (only if the user actually has it).
        # "We could not read the licences" is NOT the same as "there is no
        # licence to remove". This used to swallow the error and print the
        # reassuring line, which left a leaver still holding a paid licence
        # with nothing in the audit log to show it.
        if ($e1Sku) {
            $licences   = $null
            $couldCheck = $true
            try { $licences = @(Get-MgUserLicenseDetail -UserId $upn -ErrorAction Stop) }
            catch {
                $couldCheck = $false
                Write-Host "    Could not check the licences - the E1 licence has NOT been removed: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-ActionLog -Action 'Offboard: Remove E1 Licence' -Target $upn -Result 'Failed' -Details "Could not read licences - $($_.Exception.Message)"
            }

            if ($couldCheck) {
                if (@($licences | Where-Object { $_.SkuId -eq $e1Sku.SkuId }).Count -eq 0) {
                    Write-Host "    No Office 365 E1 licence to remove." -ForegroundColor DarkGray
                }
                elseif (Set-M365UserLicense -UserId $upn -SkuId $e1Sku.SkuId -Action Remove) {
                    Write-Host "    Office 365 E1 licence removed." -ForegroundColor Green
                    Write-ActionLog -Action 'Offboard: Remove E1 Licence' -Target $upn
                }
                else { Write-ActionLog -Action 'Offboard: Remove E1 Licence' -Target $upn -Result 'Failed' }
            }
        }
    }
}

# --- 5. Reports --------------------------------------------------------------
# Only written when working from a list. For one person the console said it all
# and the audit log has the record - a one-row CSV is just clutter in output\.
$outputDir = Get-ADToolOutputDir
$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'

$exceptions = @(@($notFound) + @($ambiguous) | Sort-Object LineNumber)
if ($exceptions.Count -and $roster.Count -gt 1) {
    $exPath = Join-Path $outputDir "Offboarding-Exceptions-$stamp.csv"
    $exceptions |
        Select-Object LineNumber, Name, Role,
                      @{ n = 'Status'; e = { $_.Outcome } },
                      @{ n = 'Reason'; e = { $_.Note } } |
        Export-Csv -Path $exPath -NoTypeInformation -Encoding UTF8
    Write-Host "`nExceptions for manual handling: $exPath" -ForegroundColor Yellow
}

# Full record of the run, including the ones that needed no action. Only worth
# writing for a list - for one person the console and the audit log say it all.
if ($roster.Count -gt 1) {
    $runPath = Join-Path $outputDir "Offboarding-Report-$stamp.csv"
    $plan |
        Select-Object LineNumber, Name, Role, Outcome,
                      @{ n = 'ADAccount';   e = { $_.Sam } },
                      @{ n = 'DisplayName'; e = { $_.DisplayName } },
                      @{ n = 'LastLogon';   e = { $_.LastLogon } },
                      @{ n = 'Disabled';    e = { if ($approved -contains $_) { 'Yes' } else { 'No' } } },
                      @{ n = 'Reason';      e = { $_.Note } } |
        Export-Csv -Path $runPath -NoTypeInformation -Encoding UTF8
    Write-Host "Full report: $runPath" -ForegroundColor Cyan
}

# --- 6. Summary --------------------------------------------------------------
Write-ToolHeader 'Summary'
Write-Host ("  Already disabled     : {0}" -f $alreadyDisabled.Count) -ForegroundColor DarkGray
Write-Host ("  Disabled just now    : {0}" -f $disabled)              -ForegroundColor Green
if ($skipped)          { Write-Host ("  Left enabled by you  : {0}" -f $skipped)          -ForegroundColor Yellow }
if ($failed)           { Write-Host ("  Failed to disable    : {0}" -f $failed)           -ForegroundColor Red }
if ($notFound.Count)   { Write-Host ("  No account found     : {0}" -f $notFound.Count)   -ForegroundColor Red }
if ($ambiguous.Count)  { Write-Host ("  Ambiguous name       : {0}" -f $ambiguous.Count)  -ForegroundColor Red }
Write-Host ""
