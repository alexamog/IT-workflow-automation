<#
.SYNOPSIS
    Onboard a whole list of new hires from a text file, in one pass.

.DESCRIPTION
    Does the same three things New-UserOnboarding.ps1 does - add to the
    distribution group, reset to a temporary password, force a password change
    at next logon - but for everyone in a list instead of one person.

    THE LIST FILE
    Run this with no file and File Explorer opens so you can click the list.

    Two layouts are understood, and one file may mix them.

    1. Name and role on the SAME line, separated by a comma, a tab, or two or
       more spaces. A single space is not a separator, or "Jane Sample" would
       be read as two fields:

           Jane Sample, Cas SRW
           Robert Example        Cas PEER          Example Residence

    2. Name on one line, role on the NEXT line - what you get pasting out of an
       email or a Word document. Blank lines and trailing spaces do not matter:

           Marcus Fictional

           Cas PEER

           Aisha Notreal

           COOK037

    Roles are recognised by their shape - "Cas SRW", "Cas PEER", position codes
    like COOK037 and JANMAINT046, and plain words like Cook or Summer Student -
    so a role line is never mistaken for a person and looked up in AD.

    A line starting with # is ignored, so you can leave yourself notes.

    NOTHING IS CHANGED UNTIL YOU SAY SO
    The script looks everyone up first and shows you a plan: who is ready, whose
    role does not match AD, who could not be found, and whose name matched more
    than one account. Only then does it ask whether to go ahead, and it only
    touches the people it listed as ready.

    PEOPLE IT CANNOT HANDLE
    Anyone not found, matched to several accounts, or whose role disagrees with
    AD is written to an exceptions file in output\ for you to do by hand. Those
    people are never onboarded automatically.

.PARAMETER Path
    The list file. If omitted, a file picker opens.

.PARAMETER RoleField
    Which AD attribute holds the job title. 'Auto' (the default) checks Title
    first and falls back to Description, which is how this domain stores it.
    Force a single field if you need to.

    Your list and AD do not spell roles the same way, and they are not meant
    to: the list uses the short form ("Cas SRW", "COOK037") while AD holds the
    full title ("Shelter Resource Worker", "Cook"). The comparison understands
    that - see Test-StaffRoleMatchesTitle in lib\Common.ps1.

.PARAMETER IncludeRoleMismatch
    Also onboard people whose role does not match AD. Off by default: a
    mismatch usually means the wrong person was matched.

.PARAMETER SkipRoleCheck
    Do not compare roles at all. Use when the list has no roles in it.

.PARAMETER UniquePassword
    Give each person their own randomly generated temporary password instead of
    the shared one. Their password appears in their own confirmation message.

.EXAMPLE
    .\Start-BatchOnboarding.ps1 .\new-hires.txt

.EXAMPLE
    # Roles live in the Title attribute at your site:
    .\Start-BatchOnboarding.ps1 .\new-hires.txt -RoleField Title
#>

#Requires -Modules ActiveDirectory

# The temporary onboarding passwords are set deliberately and forced to change at
# next logon, so a plain-text ConvertTo-SecureString is fine here. Silence the
# analyzer for that one line (see the password-reset step below).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
    Justification = 'Known/random temporary onboarding password, force-changed at next logon.')]
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Path,

    [ValidateSet('Auto', 'Title', 'Description', 'Department', 'Office')]
    [string]$RoleField = 'Auto',

    [switch]$IncludeRoleMismatch,
    [switch]$SkipRoleCheck,
    [switch]$UniquePassword
)

. "$PSScriptRoot\..\..\lib\Common.ps1"

# --- Settings (all configurable - see lib\Common.ps1 / setup\Set-ToolConfig.ps1)
$GroupName    = $ADTool.OnboardingGroup   # group new users join (ONBOARDING_GROUP); empty = skip
$TempPassword = $ADTool.TempPassword      # shared temp password (ONBOARDING_TEMP_PASSWORD)
$EmailDomain  = $ADTool.EmailDomain       # username-line domain (EMAIL_DOMAIN); empty = from the user's UPN

Write-Host ("Running as: {0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) -ForegroundColor DarkGray

# Build a random temporary password that satisfies the usual complexity rules:
# at least one capital, one lowercase, one digit, one symbol. Characters that
# are easy to misread (O/0, l/1) are left out so it can be read over the phone.
function New-TempPassword {
    $upper = 'ABCDEFGHJKMNPQRSTUVWXYZ'
    $lower = 'abcdefghjkmnpqrstuvwxyz'
    $digit = '23456789'
    $sym   = '!#$%*+=?'
    $all   = "$upper$lower$digit$sym"

    $chars = @(
        $upper[(Get-Random -Maximum $upper.Length)]
        $lower[(Get-Random -Maximum $lower.Length)]
        $digit[(Get-Random -Maximum $digit.Length)]
        $sym[(Get-Random -Maximum $sym.Length)]
    )
    # Pad to 14 characters, then shuffle so the required ones are not always
    # in the same position.
    while ($chars.Count -lt 14) { $chars += $all[(Get-Random -Maximum $all.Length)] }
    -join ($chars | Sort-Object { Get-Random })
}

# --- 1. Read the list --------------------------------------------------------
# No file given (the normal case when run from the menu) - open File Explorer so
# the list can be clicked rather than typed.
if (-not $Path) {
    Write-Host "`nOpening File Explorer to pick the list of new hires..." -ForegroundColor Cyan
    Write-Host "(if you don't see it, check behind this window)" -ForegroundColor DarkGray
    $Path = Select-LocalFilePath -Title 'Choose the list of new hires' `
                                 -Filter 'Text files (*.txt)|*.txt|All files (*.*)|*.*' `
                                 -Prompt '  Path to the list file'
}
if (-not $Path) { Write-Host "No file chosen - cancelled." -ForegroundColor Yellow; return }

try { $roster = Import-StaffRosterFile -Path $Path }
catch { Write-Host $_.Exception.Message -ForegroundColor Red; return }

if ($roster.Count -eq 0) { Write-Host "No people found in $Path." -ForegroundColor Yellow; return }
Write-Host "`nRead $($roster.Count) person(s) from $(Split-Path $Path -Leaf)." -ForegroundColor Cyan

# --- 2. Look everyone up (read-only - nothing is changed yet) ----------------
Write-Host "Looking each person up in Active Directory..." -ForegroundColor DarkGray

# Which AD attributes to compare the list's role against. 'Auto' tries the job
# title first and falls back to Description, because Description also carries
# unrelated tags on some accounts ("Vocantas User", "HIFIS User").
$roleFields = if ($RoleField -eq 'Auto') { @('Title', 'Description') } else { @($RoleField) }

# The first of those fields that actually has something in it - that is what the
# report shows the operator.
function Get-AdRoleValue ($user) {
    if (-not $user) { return '' }
    foreach ($f in $roleFields) { if ($user.$f) { return [string]$user.$f } }
    ''
}

# A match against ANY of the candidate fields counts.
function Test-RoleMatches ($fileRole, $user) {
    foreach ($f in $roleFields) {
        if (Test-StaffRoleMatchesTitle -Role $fileRole -Title ([string]$user.$f)) { return $true }
    }
    $false
}

$plan = foreach ($person in $roster) {
    $lookup  = Resolve-ADToolUserByName -Name $person.Name
    $user    = if ($lookup.Status -eq 'Matched') { $lookup.Users[0] } else { $null }
    $adRole  = Get-AdRoleValue $user

    # Decide what will happen to this person.
    $roleOk = $true
    $note   = ''
    if ($lookup.Status -ne 'Matched') {
        $roleOk = $false
        $note   = if ($lookup.Status -eq 'Ambiguous') {
            "matches $($lookup.Users.Count) accounts: " + (($lookup.Users | ForEach-Object { $_.SamAccountName }) -join ', ')
        } else { 'no account found' }
    }
    elseif (-not $SkipRoleCheck -and $person.Role) {
        if (-not (Test-RoleMatches $person.Role $user)) {
            $roleOk = $false
            $note   = if ($adRole) { "AD job title is '$adRole'" }
                      else         { "no job title on the AD account ($($roleFields -join '/') empty)" }
        }
    }

    [pscustomobject]@{
        LineNumber = $person.LineNumber
        Name       = $person.Name
        Role       = $person.Role
        Location   = $person.Location
        Status     = $lookup.Status
        MatchedBy  = $lookup.MatchedBy
        Sam        = if ($user) { $user.SamAccountName } else { '' }
        DisplayName= if ($user) { $user.DisplayName }    else { '' }
        Email      = if ($user) { $user.EmailAddress }   else { '' }
        AdRole     = $adRole
        RoleOk     = $roleOk
        Note       = $note
        User       = $user
    }
}

$ready        = @($plan | Where-Object { $_.Status -eq 'Matched' -and $_.RoleOk })
$roleMismatch = @($plan | Where-Object { $_.Status -eq 'Matched' -and -not $_.RoleOk })
$notFound     = @($plan | Where-Object { $_.Status -eq 'NotFound' })
$ambiguous    = @($plan | Where-Object { $_.Status -eq 'Ambiguous' })

# --- 3. Show the plan --------------------------------------------------------
Write-ToolHeader 'Plan'

if ($ready.Count) {
    Write-Host "`nREADY TO ONBOARD ($($ready.Count)):" -ForegroundColor Green
    $ready | ForEach-Object {
        $flag = if ($_.MatchedBy -eq 'NameParts') { '  <- loose name match, check this one' } else { '' }
        Write-Host ("   {0,-26} {1,-18} {2}{3}" -f $_.Name, $_.Role, $_.Sam, $flag)
    }
}

if ($roleMismatch.Count) {
    Write-Host "`nROLE DOES NOT MATCH AD ($($roleMismatch.Count)):" -ForegroundColor Yellow
    $roleMismatch | ForEach-Object {
        Write-Host ("   line {0,-4} {1,-26} list says '{2}', {3}" -f $_.LineNumber, $_.Name, $_.Role, $_.Note)
    }
    if (-not $IncludeRoleMismatch) { Write-Host "   (skipped - re-run with -IncludeRoleMismatch to onboard them anyway)" -ForegroundColor DarkGray }
}

if ($notFound.Count) {
    Write-Host "`nNO ACCOUNT FOUND ($($notFound.Count)) - do these by hand:" -ForegroundColor Red
    $notFound | ForEach-Object { Write-Host ("   line {0,-4} {1}" -f $_.LineNumber, $_.Name) }
}

if ($ambiguous.Count) {
    Write-Host "`nNAME MATCHES SEVERAL ACCOUNTS ($($ambiguous.Count)) - do these by hand:" -ForegroundColor Red
    $ambiguous | ForEach-Object { Write-Host ("   line {0,-4} {1,-26} {2}" -f $_.LineNumber, $_.Name, $_.Note) }
}

# A wrong -RoleField makes everyone look like a mismatch. Say so plainly rather
# than letting someone conclude the whole list is bad data.
if ($roleMismatch.Count -gt 0 -and $ready.Count -eq 0 -and -not $SkipRoleCheck) {
    Write-Host "`nEveryone matched an account but nobody's role lined up." -ForegroundColor Yellow
    Write-Host "That usually means the job title is not kept in $($roleFields -join ' or ') at your site." -ForegroundColor Yellow
    Write-Host "Try:  -RoleField Department   (or -SkipRoleCheck to ignore roles entirely)" -ForegroundColor Yellow
}

# --- 4. Confirm --------------------------------------------------------------
$targets = if ($IncludeRoleMismatch) { @($ready) + @($roleMismatch) } else { $ready }
$targets = @($targets)

if ($targets.Count -eq 0) {
    Write-Host "`nNobody to onboard. Nothing changed." -ForegroundColor Yellow
}
else {
    Write-Host ""
    $groupPart = if ($GroupName) { "add to '$GroupName', " } else { '' }
    Write-Host "About to onboard $($targets.Count) account(s): ${groupPart}reset the password, and force a change at next logon." -ForegroundColor Cyan
    if (-not (Confirm-DeskSideAction 'Proceed?' -Quiet)) {
        Write-Host "Cancelled - no changes made." -ForegroundColor Yellow
        $targets = @()
    }
}

# Optional: assign the Office 365 E1 licence to everyone being onboarded.
# Connect once up front; if it can't connect or the SKU isn't found, the licence
# step is skipped for everyone (the rest of the onboarding still runs).
$e1Sku = $null
# -DefaultYes: matches New-UserOnboarding - licensing a new starter is the
# normal path, so a bare ENTER goes ahead. Type N to skip.
Write-Host ""
if ($targets.Count -gt 0 -and (Confirm-DeskSideAction 'Also assign the Office 365 E1 licence to each?' -DefaultYes -Quiet)) {
    if (Connect-MgGraphSession) { $e1Sku = Get-M365LicenseSku }
    if (-not $e1Sku) { Write-Host "Skipping the licence step - onboarding the accounts without it." -ForegroundColor Yellow }
}

# --- 5. Do the work ----------------------------------------------------------
$messages = New-Object System.Collections.Generic.List[string]
$done     = 0
$failed   = 0

foreach ($t in $targets) {
    $sam = $t.Sam
    Write-Host "`n--- $($t.Name)  ($sam)" -ForegroundColor Cyan
    $password = if ($UniquePassword) { New-TempPassword } else { $TempPassword }
    $trouble  = $false

    # 5a. Distribution group (skipped when no ONBOARDING_GROUP is set).
    if (-not $GroupName) {
        Write-Host "    No onboarding group set - skipping the group step." -ForegroundColor DarkGray
    }
    else {
    try {
        Add-ADGroupMember -Identity $GroupName -Members $sam -ErrorAction Stop
        Write-Host "    Added to '$GroupName'." -ForegroundColor Green
        Write-ActionLog -Action 'Batch Onboard: Group Add' -Target $sam -Details "Added to $GroupName"
    }
    catch {
        # Already a member is a normal, harmless outcome when a list is re-run.
        if ($_.Exception.Message -match 'already a member') {
            Write-Host "    Already in '$GroupName' - left alone." -ForegroundColor DarkGray
        }
        else {
            Write-Host "    Group add failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-ActionLog -Action 'Batch Onboard: Group Add' -Target $sam -Result 'Failed' -Details "$GroupName - $($_.Exception.Message)"
            $trouble = $true
        }
    }
    }

    # 5b. Temporary password.
    try {
        $secure = ConvertTo-SecureString $password -AsPlainText -Force
        Set-ADAccountPassword -Identity $sam -Reset -NewPassword $secure -ErrorAction Stop
        Write-Host "    Password reset." -ForegroundColor Green
        Write-ActionLog -Action 'Batch Onboard: Reset Password' -Target $sam
    }
    catch {
        Write-Host "    Password reset failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-ActionLog -Action 'Batch Onboard: Reset Password' -Target $sam -Result 'Failed' -Details $_.Exception.Message
        $trouble = $true
    }

    # 5c. Force a change at next logon.
    try {
        Set-ADUser -Identity $sam -ChangePasswordAtLogon $true -ErrorAction Stop
        Write-Host "    Must change password at next logon." -ForegroundColor Green
        Write-ActionLog -Action 'Batch Onboard: Force Password Change' -Target $sam
    }
    catch {
        Write-Host "    Could not set change-at-logon: $($_.Exception.Message)" -ForegroundColor Red
        $trouble = $true
    }

    # 5d. Office 365 E1 licence (only if the operator opted in and we connected).
    if ($e1Sku) {
        $upn = $t.User.UserPrincipalName
        if (-not $upn) { Write-Host "    No UPN on the account - licence skipped." -ForegroundColor DarkYellow }
        elseif (Set-M365UserLicense -UserId $upn -SkuId $e1Sku.SkuId -Action Add) {
            Write-Host "    Office 365 E1 assigned." -ForegroundColor Green
            Write-ActionLog -Action 'Batch Onboard: Assign E1 Licence' -Target $sam -Details $upn
        }
        else {
            Write-ActionLog -Action 'Batch Onboard: Assign E1 Licence' -Target $sam -Result 'Failed' -Details $upn
            $trouble = $true
        }
    }

    if ($trouble) { $failed++ } else { $done++ }

    $domain   = if ($EmailDomain) { $EmailDomain } elseif ($t.User.UserPrincipalName -match '@(.+)$') { $Matches[1] } else { '' }
    $username = if ($t.Email) { $t.Email } elseif ($domain) { "$sam@$domain" } else { $sam }
    $messages.Add(@"
Account name: $($t.DisplayName)
Username: $username
Temporary password: $password
Account type: Email / network login
Note: the user will be prompted to change the password on first login.

"@)
}

# --- 6. Reports --------------------------------------------------------------
$outputDir = Get-ADToolOutputDir
$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'

# Exceptions: everyone a human still has to deal with.
$exceptions = @($notFound) + @($ambiguous) + $(if ($IncludeRoleMismatch) { @() } else { @($roleMismatch) })
$exceptions = @($exceptions | Sort-Object LineNumber)

if ($exceptions.Count) {
    $exPath = Join-Path $outputDir "Onboarding-Exceptions-$stamp.csv"
    $exceptions |
        Select-Object LineNumber, Name, Role, Location, Status,
                      @{ n = 'ADAccount'; e = { $_.Sam } },
                      @{ n = 'ADRole';    e = { $_.AdRole } },
                      @{ n = 'Reason';    e = { $_.Note } } |
        Export-Csv -Path $exPath -NoTypeInformation -Encoding UTF8
    Write-Host "`nExceptions for manual handling: $exPath" -ForegroundColor Yellow
}

if ($messages.Count) {
    $msgPath = Join-Path $outputDir "Onboarding-Messages-$stamp.txt"
    ($messages -join "`r`n") | Out-File -FilePath $msgPath -Encoding UTF8
    Write-Host "Confirmation details for the requester: $msgPath" -ForegroundColor Cyan
}

# --- 7. Summary --------------------------------------------------------------
Write-ToolHeader 'Summary'
Write-Host ("  Onboarded cleanly       : {0}" -f $done)         -ForegroundColor Green
if ($failed)             { Write-Host ("  Onboarded with errors   : {0}" -f $failed)             -ForegroundColor Red }
if (-not $IncludeRoleMismatch -and $roleMismatch.Count) {
                           Write-Host ("  Skipped, role mismatch  : {0}" -f $roleMismatch.Count) -ForegroundColor Yellow }
if ($notFound.Count)     { Write-Host ("  No account found        : {0}" -f $notFound.Count)     -ForegroundColor Red }
if ($ambiguous.Count)    { Write-Host ("  Ambiguous name          : {0}" -f $ambiguous.Count)    -ForegroundColor Red }
Write-Host ""
