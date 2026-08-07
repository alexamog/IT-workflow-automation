<#
.SYNOPSIS
    Onboard a user by full name: confirm the account details, then add them to
    the configured onboarding group, reset the password to a temporary one, force
    a change at next logon, and produce a ready-to-send message.

.PARAMETER Identity
    The employee's full name, username (firstname.lastname), UPN, or email.
    If omitted, you'll be prompted.

.EXAMPLE
    .\New-UserOnboarding.ps1 "Jane Doe"
    .\New-UserOnboarding.ps1 alex.amog
    .\New-UserOnboarding.ps1 alex.amog@contoso.com
#>

#Requires -Modules ActiveDirectory

# The temporary onboarding password is deliberately a known plain-text value:
# it is set once here and forced to change at next logon (step 3), so storing it
# as a SecureString would add nothing. Silence the analyzer for that one line.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
    Justification = 'Known temporary onboarding password, force-changed at next logon.')]
param([string]$Identity)

. "$PSScriptRoot\..\..\lib\Common.ps1"

# --- Show which account is running -------------------------------------------
# Onboarding makes AD changes, so it must run as an account with the right
# permissions. We show the account so you can confirm before anything happens;
# if it lacks rights, each step below reports why rather than failing silently.
Write-Host ("Running as: {0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) -ForegroundColor DarkGray

# --- Settings (all configurable - see lib\Common.ps1 / setup\Set-ToolConfig.ps1)
$GroupName    = $ADTool.OnboardingGroup   # group new users join (ONBOARDING_GROUP); empty = skip
$TempPassword = $ADTool.TempPassword      # temp password (ONBOARDING_TEMP_PASSWORD); changed at next logon
$EmailDomain  = $ADTool.EmailDomain       # username-line domain (EMAIL_DOMAIN); empty = from the user's UPN

if (-not $Identity) { $Identity = Read-Host "Employee full name, username (firstname.lastname), or email" }
if (-not $Identity) { return }

# --- Find the account by full name, username, UPN, or email ------------------
$id    = $Identity.Replace("'", "''")   # escape apostrophes for the AD filter
$props = 'DisplayName','EmailAddress','UserPrincipalName','SamAccountName','Description','Office'

# Exact match on the usual identifiers (username / UPN / email / display name).
$found = @(Get-ADUser -Properties $props -Filter "SamAccountName -eq '$id' -or UserPrincipalName -eq '$id' -or EmailAddress -eq '$id' -or DisplayName -eq '$id' -or Name -eq '$id'")
if ($found.Count -eq 0) {
    # Fall back to a looser name search so partial full names still find them.
    $found = @(Get-ADUser -Properties $props -Filter "DisplayName -like '*$id*' -or Name -like '*$id*'")
}
if ($found.Count -eq 0) { Write-Host "No account found for '$Identity'." -ForegroundColor Red; return }

if ($found.Count -eq 1) {
    $user = $found[0]
} else {
    Write-Host "`nMultiple accounts match '$Identity':" -ForegroundColor Yellow
    $user = Select-FromList -Items $found -Label { param($u) "$($u.DisplayName)  ($($u.SamAccountName))  $($u.UserPrincipalName)" }
    if (-not $user) { return }
}

$sam = $user.SamAccountName

# --- Show the details to confirm ---------------------------------------------
$groups = @(Get-ADPrincipalGroupMembership -Identity $sam | Sort-Object Name | Select-Object -ExpandProperty Name)

Write-ToolHeader 'Confirm account'
Write-Host ("  {0,-34} : {1}" -f 'Full name', $user.DisplayName)
Write-Host ("  {0,-34} : {1}" -f 'Description', $user.Description)
Write-Host ("  {0,-34} : {1}" -f 'Office', $user.Office)
Write-Host ("  {0,-34} : {1}" -f 'Email', $user.EmailAddress)
Write-Host ("  {0,-34} : {1}" -f 'User logon name', $user.UserPrincipalName)
Write-Host ("  {0,-34} : {1}" -f 'User logon name (pre-Windows 2000)', $sam)
Write-Host ("  {0,-34} :" -f 'Member of')
if ($groups) { $groups | ForEach-Object { Write-Host "      - $_" } } else { Write-Host "      (none)" }

if ((Read-Host "`nDoes this look correct? Proceed with onboarding? (Y/N)") -notmatch '^[Yy]') {
    Write-Host "Cancelled - no changes made." -ForegroundColor Yellow
    return
}

# --- 1. Add to the distribution group ----------------------------------------
if (-not $GroupName) {
    Write-Host "No onboarding group set (ONBOARDING_GROUP) - skipping the group step." -ForegroundColor DarkGray
}
else {
try {
    Add-ADGroupMember -Identity $GroupName -Members $sam -ErrorAction Stop
    Write-Host "Added to '$GroupName'." -ForegroundColor Green
    Write-ActionLog -Action 'Onboard: Group Add' -Target $sam -Details "Added to $GroupName"
}
catch {
    Write-Host "Could not add to '$GroupName': $($_.Exception.Message)" -ForegroundColor Red
    Write-ActionLog -Action 'Onboard: Group Add' -Target $sam -Result 'Failed' -Details "$GroupName - $($_.Exception.Message)"
}
}

# --- 2. Reset the password to the temporary one ------------------------------
try {
    $secure = ConvertTo-SecureString $TempPassword -AsPlainText -Force
    Set-ADAccountPassword -Identity $sam -Reset -NewPassword $secure -ErrorAction Stop
    Write-Host "Password reset to the temporary password." -ForegroundColor Green
    Write-ActionLog -Action 'Onboard: Reset Password' -Target $sam
}
catch {
    Write-Host "Password reset failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-ActionLog -Action 'Onboard: Reset Password' -Target $sam -Result 'Failed' -Details $_.Exception.Message
}

# --- 3. Force a password change at next logon --------------------------------
try {
    Set-ADUser -Identity $sam -ChangePasswordAtLogon $true -ErrorAction Stop
    Write-Host "User must change password at next logon." -ForegroundColor Green
    Write-ActionLog -Action 'Onboard: Force Password Change' -Target $sam
}
catch {
    Write-Host "Could not set change-at-logon: $($_.Exception.Message)" -ForegroundColor Red
}

# --- 4. Assign the Office 365 E1 licence (Microsoft 365) ----------------------
# Licences live in the M365 admin centre (Microsoft Graph), not AD, so this is a
# separate, optional step. Signs in interactively the first time.
$upn = $user.UserPrincipalName
# -DefaultYes: assigning the licence is the normal path for a new starter, so a
# bare ENTER goes ahead with it. Type N to skip.
Write-Host ""
if ($upn -and (Confirm-DeskSideAction "Assign the Office 365 E1 licence to $upn?" -DefaultYes -Quiet)) {
    if (Connect-MgGraphSession) {
        $sku = Get-M365LicenseSku
        if ($sku) {
            if (Set-M365UserLicense -UserId $upn -SkuId $sku.SkuId -Action Add) {
                Write-Host "Assigned Office 365 E1." -ForegroundColor Green
                Write-ActionLog -Action 'Onboard: Assign E1 Licence' -Target $sam -Details $upn
            }
            else { Write-ActionLog -Action 'Onboard: Assign E1 Licence' -Target $sam -Result 'Failed' -Details $upn }
        }
    }
}

# --- Confirmation message (ready to copy/paste) ------------------------------
$requester = Read-Host "`nRequester name (for the confirmation message)"
# Prefer the real email; else build one from the configured domain, or fall back
# to the domain in the user's own UPN so this works with no EMAIL_DOMAIN set.
$domain = $EmailDomain
if (-not $domain -and $user.UserPrincipalName -match '@(.+)$') { $domain = $Matches[1] }
$username  = if ($user.EmailAddress) { $user.EmailAddress } elseif ($domain) { "$sam@$domain" } else { $sam }

$message = @"
Hi $requester,

The new account you requested has been created. Details are below:

Account name: $($user.DisplayName)

Username: $username

Temporary password: $TempPassword

Account type: Email / network login

Notes:

The user will be prompted to change the password on first login.

Let us know if you need anything adjusted.
"@

Write-Host "`n---------------- Copy the message below ----------------" -ForegroundColor Cyan
Write-Host $message
Write-Host "--------------------------------------------------------" -ForegroundColor Cyan
try { $message | Set-Clipboard; Write-Host "(Also copied to your clipboard.)" -ForegroundColor Yellow } catch { }
