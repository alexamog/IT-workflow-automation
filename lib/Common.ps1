<#
.SYNOPSIS
    Shared library for Desk Side Toolkit.

.DESCRIPTION
    Dot-source this file at the top of every script:

        . "$PSScriptRoot\..\lib\Common.ps1"

    It provides one place for:
      - Configuration  ($ADTool: domain, source OU, regions)
      - Folder helpers (Get-ADToolRoot / -OutputDir / -DataDir)
      - DC selection   (Get-ADToolDC)
      - User lookup    (Resolve-ADToolUser - matches SAM or UPN)
      - Snipe-IT API   (Invoke-SnipeRequest, Get-SnipeHardware,
                        ConvertFrom-SnipeField, Write-SnipeAssetReport)
      - Tactical RMM   (Test-TrmmConfigured, Invoke-TrmmRequest,
                        Invoke-TrmmAgentCommand, ConvertTo-RemoteLiteral)
      - Exchange Online (Connect-ExoSession, Find-ExoRecipient)
      - Microsoft Graph (Connect-MgGraphSession, Get-M365LicenseSku,
                        Set-M365UserLicense)
      - SharePoint     (Connect-SpoSession, Get-SpoRootUrl)
      - Audit logging  (Write-ActionLog, Write-SnipeAssetLog)
#>

# NOTE: this shared library does NOT require the ActiveDirectory module at load
# time, so the non-AD features (Snipe-IT, Tactical RMM) that reuse its helpers -
# Invoke-SnipeRequest, the folder helpers, Write-*Log - run on a machine without
# RSAT. The AD-only helpers below (Resolve-ADToolUser, Get-ADToolDC) still need
# the module, but only the AD feature scripts call them, and each of those
# scripts declares its own "#Requires -Modules ActiveDirectory".

# --- Configuration -----------------------------------------------------------
# EVERYTHING organisation-specific lives here, and every value reads from an
# environment variable with NO organisation baked in as a fallback. That is what
# lets this toolkit move to another company without editing code: set the env
# vars once (setup\Set-ToolConfig.ps1) and every script picks them up. Anything
# left unset either auto-detects (the AD domain) or the feature that needs it
# tells you which variable to set.
$Global:ADTool = @{
    # AD domain distinguished name. Empty = auto-detect from the current domain
    # at run time (Get-ADToolDomainDN), so AD features work with no setup. Pin it
    # with AD_DOMAIN_DN only if you need a specific value.
    DomainDN = if ($env:AD_DOMAIN_DN) { $env:AD_DOMAIN_DN } else { '' }

    # The OU holding disabled / "unmatched" accounts, for the reports that scan
    # it. Set AD_SOURCE_OU; the reports say so if it is empty.
    SourceOU = if ($env:AD_SOURCE_OU) { $env:AD_SOURCE_OU } else { '' }

    # Region OUs to scan (semicolon-separated in AD_REGIONS). Empty = none.
    Regions  = if ($env:AD_REGIONS) {
        $env:AD_REGIONS -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    } else { @() }

    # Onboarding. The group new users join (ONBOARDING_GROUP) and the email domain
    # used to build the "username" line when a user has no mailbox yet
    # (EMAIL_DOMAIN). Both optional: no group = the group step is skipped; no
    # domain = it is taken from the user's own UPN. The temporary password
    # (ONBOARDING_TEMP_PASSWORD) has a neutral default and is force-changed at
    # next logon.
    OnboardingGroup = if ($env:ONBOARDING_GROUP) { $env:ONBOARDING_GROUP } else { '' }
    EmailDomain     = if ($env:EMAIL_DOMAIN) { $env:EMAIL_DOMAIN } else { '' }
    TempPassword    = if ($env:ONBOARDING_TEMP_PASSWORD) { $env:ONBOARDING_TEMP_PASSWORD } else { 'ChangeMeNow!123' }

    # SharePoint time-zone ID used when creating a site (e.g. 13 = Pacific).
    # Empty = you're asked when creating a site. Set SPO_TIMEZONE to skip the ask.
    SpoTimeZone = if ($env:SPO_TIMEZONE) { $env:SPO_TIMEZONE } else { '' }

    # Snipe-IT asset management REST API. Both come from environment variables so
    # nothing organisation-specific (and no token) lives in source:
    #   SNIPEIT_TOKEN - the raw API token (no "Bearer " prefix)
    #   SNIPEIT_URL   - API base URL, e.g. https://assets.contoso.com/api/v1
    # Set them once with: .\setup\Set-SnipeCredentials.ps1
    SnipeIT = @{
        BaseUrl = if ($env:SNIPEIT_URL) { $env:SNIPEIT_URL } else { '' }
        Token   = if ($env:SNIPEIT_TOKEN) { "Bearer $env:SNIPEIT_TOKEN" } else { $null }
    }
}

# --- Folder helpers ----------------------------------------------------------
# Tool root = the parent of this lib folder. Output/Data are created on demand.
function Get-ADToolRoot { Split-Path $PSScriptRoot -Parent }

function Get-ADToolOutputDir {
    $dir = Join-Path (Get-ADToolRoot) 'output'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $dir
}

# On managed machines, the profile-cleanup features keep their log/backups here.
# It's a neutral product path (no organisation name); override with
# DESKSIDE_PROGRAMDATA if you want it somewhere else.
function Get-DeskSideProgramDataDir {
    if ($env:DESKSIDE_PROGRAMDATA) { $env:DESKSIDE_PROGRAMDATA } else { 'C:\ProgramData\DeskSideToolkit' }
}

# Accounts that profile cleanup must NEVER delete, whatever a keep/delete list
# says. Default is the admin-prefix convention "adm-*"; add exact names or
# wildcards with PROTECTED_ACCOUNTS (semicolon- or comma-separated), e.g.
# "svc-*;breakglass". No account name is baked in, so this is org-agnostic.
function Get-DeskSideProtectedAccount {
    if ($env:PROTECTED_ACCOUNTS) {
        @($env:PROTECTED_ACCOUNTS -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    } else { @('adm-*') }
}
function Test-DeskSideProtectedAccount ($Name) {
    foreach ($p in (Get-DeskSideProtectedAccount)) { if ($Name -like $p) { return $true } }
    $false
}

function Get-ADToolDataDir {
    $dir = Join-Path (Get-ADToolRoot) 'data'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $dir
}

# --- Packaging exclusions ----------------------------------------------------
# THE single rule for "do not ship this" - used by both Build-SharePackage.ps1
# (the zip) and Publish-ToShare.ps1 (the shared-drive copy). Keeping it here
# means the zip and the share can never drift apart on what they leave out.
#
# Given a path RELATIVE to the project root, returns $true if it must be left
# out of a shared/published copy. The two reasons to exclude:
#   1. REAL DATA (privacy) - output\ and Jira Scripts\output\ hold live
#      hostnames, staff names, and exported ticket PII; data\ is this machine's
#      own OU paths. None of that belongs in a copy handed to someone else.
#   2. LOCAL / DEV noise - .git, .claude, generated standalone editions, temp
#      and corrupt files: not useful in a running copy.
function Test-DeskSidePathExcluded {
    param([Parameter(Mandatory)][string]$RelativePath)

    $parts = @(($RelativePath -replace '/', '\') -split '\\' | Where-Object { $_ })
    if ($parts.Count -eq 0) { return $false }

    # Names dropped wherever they appear in the path (folder or file).
    $excludeNames = @('output', 'data', '.git', '.claude',
        'Standalone Editions', 'Desk Side Tool - Core')
    foreach ($p in $parts) { if ($excludeNames -contains $p) { return $true } }

    # Leaf-name patterns.
    $leaf = $parts[-1]
    if ($leaf -eq 'settings.local.json')  { return $true }
    if ($leaf -like 'My-Completed-Tickets*') { return $true }  # ticket PII, belt-and-braces
    if ($leaf -like '*.corrupt-*')        { return $true }
    if ($leaf -like '*.tmp')              { return $true }

    return $false
}

# The AD domain DN: the configured value if set, otherwise read it from the
# current domain so AD features need no configuration to work.
function Get-ADToolDomainDN {
    if ($ADTool.DomainDN) { return $ADTool.DomainDN }
    try { (Get-ADDomain).DistinguishedName } catch { '' }
}

# --- Domain controller selection ---------------------------------------------
# Use the supplied -Server, otherwise the PDC emulator (authoritative read).
function Get-ADToolDC {
    param([string]$Server)
    if ($Server) { return $Server }
    try { (Get-ADDomain).PDCEmulator } catch { $env:LOGONSERVER -replace '\\', '' }
}

# --- User lookup -------------------------------------------------------------

# Make a piece of typed-in text safe to drop into an LDAP search.
# Four characters mean something special to LDAP, so each is replaced by its
# escape code (RFC 4515). Without this, a name containing "(" or "*" either
# errors or quietly searches for the wrong thing.
function ConvertTo-LdapEscapedString {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    # Backslash MUST be replaced first, or it would double-escape the codes
    # added by the replacements after it.
    $Value -replace '\\', '\5c' -replace '\(', '\28' -replace '\)', '\29' -replace '\*', '\2a'
}

# Resolve a user by SAM or UPN. Returns the user object, or $null (with a
# message) if nothing matched. Pass -Properties/-Server as needed.
#
# WHY -LDAPFilter AND NOT -Filter: the -Filter syntax wraps the value in single
# quotes, so a perfectly normal name like o'brien ends the quote early and the
# whole search fails to parse. -LDAPFilter has no quoting, so apostrophes are
# just ordinary characters, and the escape helper above handles the four that
# genuinely are special.
function Resolve-ADToolUser {
    param(
        [Parameter(Mandatory)][string]$Identity,
        [string[]]$Properties,
        [string]$Server
    )
    # Exact match on either attribute. Note the escape means a typed "*" is
    # searched for literally rather than acting as a wildcard - this is an
    # identity lookup, not a search.
    $safe = ConvertTo-LdapEscapedString -Value $Identity
    $params = @{
        LDAPFilter  = "(|(sAMAccountName=$safe)(userPrincipalName=$safe))"
        ErrorAction = 'SilentlyContinue'
    }
    if ($Properties) { $params.Properties = $Properties }
    if ($Server)     { $params.Server     = $Server }

    $user = Get-ADUser @params
    if (-not $user) { Write-Host "No user found matching '$Identity'." -ForegroundColor Red }
    $user
}

# --- File picker -------------------------------------------------------------
# Open the normal Windows "Open file" box so someone can click a file instead of
# typing a path. Falls back to typing the path if the dialog cannot be shown
# (for example over a plain remote session with no desktop).
function Select-LocalFilePath {
    param(
        [string]$Title  = 'Choose a file',
        [string]$Filter = 'All files (*.*)|*.*',
        [string]$Prompt = '  File path'
    )
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title            = $Title
        $dlg.InitialDirectory = [Environment]::GetFolderPath('Desktop')
        $dlg.Filter           = $Filter
        $dlg.Multiselect      = $false
        # A hidden top-most form makes the dialog appear in front of the console.
        $front  = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }
        $result = $dlg.ShowDialog($front)
        $front.Dispose()
        if ($result -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.FileName }
        return $null
    }
    catch {
        Write-Host "  (file picker unavailable here - type the path instead)" -ForegroundColor DarkYellow
        return (Read-Host $Prompt)
    }
}

# --- Staff roster files (batch onboarding / offboarding) ---------------------

# Does this line look like a job role rather than a person's name?
#
# This matters because lists arrive with the role on its OWN line, underneath
# the person. Without a way to tell the two apart, "Cas PEER" would be treated
# as somebody called Cas Peer and looked up in AD.
#
# Recognised as a role:
#   Cas SRW, Cas PEER, Cas COOK, Cas TSW   (casual, then the position)
#   COOK037, JANMAINT046, CSW005, SRW416   (position codes)
#   SRW, TSW, MCA                          (bare abbreviations)
#   Cook, Homemaker, Supervisor, Summer Student, ...
#
# Anything else is assumed to be a name. That is the safe way round: an
# unrecognised role becomes a "person" who is then not found in AD, so it shows
# up in the exceptions report instead of quietly attaching to the wrong person.
function Test-LooksLikeStaffRole {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $t = ($Text -replace '\s+', ' ').Trim()
    if (-not $t) { return $false }

    if ($t -match '^Cas\s+\S+$')              { return $true }   # Cas SRW
    if ($t -match '^[A-Za-z]{2,12}\d{2,4}$')  { return $true }   # COOK037
    if ($t -cmatch '^[A-Z]{2,12}$')           { return $true }   # SRW

    $known = @('cook', 'homemaker', 'supervisor', 'summer student', 'caseplanner',
               'case planner', 'janitor', 'maintenance', 'relief', 'peer', 'student',
               'casual')
    return ($known -contains $t.ToLower())
}

# Does the role written on a list match the job title held in AD?
#
# They are almost never spelled the same. Lists use the short form the payroll
# system uses; AD holds the full job title:
#
#     Cas SRW      ->  Shelter Resource Worker
#     Cas TSW      ->  Tenant Support Worker
#     COOK037      ->  Cook
#     JANMAINT046  ->  Janitor/ Maintenance
#     MCA002       ->  Medical Care Aid
#
# Rather than keeping a list of every abbreviation - which would go stale the
# first time somebody invents a job title - this works out the relationship:
# THE ABBREVIATION IS BUILT FROM THE START OF EACH WORD OF THE TITLE.
#     S-helter R-esource W-orker      -> SRW
#     Jan-itor/ Maint-enance          -> JANMAINT
#     Cook                            -> COOK
# So the test is: can the abbreviation be spelled out by taking some letters
# from the front of each word of the title, in order, using them all up?
#
# Before comparing, two things are stripped from the list's version:
#   "Cas " / "Casual "  - that is the employment type, not the job
#   trailing digits     - COOK037 and SRW416 are one position, numbered
function Test-StaffRoleMatchesTitle {
    param(
        [AllowEmptyString()][string]$Role,
        [AllowEmptyString()][string]$Title
    )
    if (-not $Role -or -not $Title) { return $false }

    $r = ($Role -replace '\s+', ' ').Trim()
    $r = $r -replace '^(Cas|Casual)\b\s*', '' -replace '[0-9]+$', ''
    $r = $r.Trim()
    if (-not $r) { return $false }   # the line said only "Cas" - nothing to check

    # Spelled out in full, ignoring case, spacing and punctuation.
    if (($r -replace '[^A-Za-z]', '') -ieq ($Title -replace '[^A-Za-z]', '')) { return $true }

    # Otherwise: walk the title's words, letting each one consume as much of the
    # abbreviation as it can from the front. A match means it was all consumed.
    $words = @($Title -split '[^A-Za-z]+' | Where-Object { $_ })
    $abbrev = ($r -replace '[^A-Za-z]', '').ToUpper()
    if ($words.Count -eq 0 -or -not $abbrev) { return $false }

    $i = 0
    foreach ($w in $words) {
        $upper = $w.ToUpper()
        $take  = 0
        while ($take -lt $upper.Length -and ($i + $take) -lt $abbrev.Length -and
               $abbrev[$i + $take] -eq $upper[$take]) { $take++ }
        $i += $take
    }
    return ($i -eq $abbrev.Length)
}

# Read a plain text list of people into objects. TWO layouts are understood, and
# the file may mix them.
#
# 1. Everything on one line, separated by a COMMA, a TAB, or TWO OR MORE SPACES
#    (a single space is NOT a separator, or "John Doe" would split in two):
#
#        John Doe, Cas SRW
#        Alex Rivera-Stone    Cas SRW    Example Residence
#
# 2. Name on one line, role on the next - which is what you get pasting out of
#    an email or a Word document. Blank lines between them make no difference:
#
#        Marcus Fictional
#
#        Cas PEER
#
#        Aisha Notreal
#
#        Cas COOK
#
# Lines starting with # are ignored, so you can leave yourself notes.
#
# Returns one object per PERSON with LineNumber, Name, Role, Location, RawLine,
# and ParseNote (empty unless something about the line needs a human's eye).
function Import-StaffRosterFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "Roster file not found: $Path" }

    $entries = New-Object System.Collections.Generic.List[object]
    $lineNo  = 0

    # A name waiting to see whether the next line is its role.
    $pendingName = $null
    $pendingLine = 0

    # Flush the waiting name, with the role if one turned up.
    $emit = {
        param($role)
        if ($null -ne $pendingName) {
            $entries.Add([pscustomobject]@{
                LineNumber = $pendingLine
                Name       = $pendingName
                Role       = $role
                Location   = ''
                RawLine    = $pendingName
                ParseNote  = ''
            })
        }
    }

    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $lineNo++
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }              # blank line
        if ($trimmed.StartsWith('#')) { continue }   # comment

        # Layout 1: this single line already holds the whole record.
        if ($trimmed -match ',|\t|\s{2,}') {
            & $emit ''                               # any waiting name had no role
            $pendingName = $null

            $parts = if ($trimmed -match ',') { $trimmed -split ',' }
                     else                     { $trimmed -split '\t|\s{2,}' }
            $parts = @($parts | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if ($parts.Count -eq 0) { continue }

            $entries.Add([pscustomobject]@{
                LineNumber = $lineNo
                Name       = $parts[0]
                Role       = if ($parts.Count -ge 2) { $parts[1] } else { '' }
                Location   = if ($parts.Count -ge 3) { $parts[2] } else { '' }
                RawLine    = $trimmed
                ParseNote  = ''
            })
            continue
        }

        # Layout 2: a bare line - either a name, or the role belonging to the
        # name above it.
        if (Test-LooksLikeStaffRole -Text $trimmed) {
            if ($null -ne $pendingName) {
                & $emit $trimmed
                $pendingName = $null
            }
            else {
                # A role with nobody above it. Never silently dropped - the
                # person it belongs to may have been missed off the list.
                $entries.Add([pscustomobject]@{
                    LineNumber = $lineNo
                    Name       = $trimmed
                    Role       = ''
                    Location   = ''
                    RawLine    = $trimmed
                    ParseNote  = 'looks like a role, but no name came before it'
                })
            }
        }
        else {
            # A new name. Anything still waiting had no role of its own.
            & $emit ''
            $pendingName = $trimmed
            $pendingLine = $lineNo
        }
    }

    & $emit ''   # last name in the file

    , $entries.ToArray()
}

# Find one AD user from a person's full name as a human would write it.
#
# Names on a ticket rarely match AD exactly - "Alex Rivera-Stone" might be
# stored as "Rivera-Stone, Alex", or the account might not exist at all. So
# this tries three passes, easiest and most certain first:
#
#   1. Exact match on the usual identifiers (username, UPN, email, display name)
#   2. The firstname.lastname username this organisation uses
#   3. Every word of the name appearing somewhere in the display name, in any
#      order - this is what catches "Surname, Firstname" and extra middle names
#
# Returns an object with:
#   Status    'Matched' (exactly one), 'Ambiguous' (several), 'NotFound' (none)
#   Users     what was found (one entry when Matched, several when Ambiguous)
#   MatchedBy which of the three passes found them - useful in the report,
#             because a name found only by pass 3 is worth a human glance
function Resolve-ADToolUserByName {
    # The code checker cannot see inside the $search scriptblock below, so it
    # believes these two are never used. They are - every search passes them
    # straight to Get-ADUser.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Properties',
        Justification = 'Used inside the $search scriptblock, which the analyzer does not follow.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Server',
        Justification = 'Used inside the $search scriptblock, which the analyzer does not follow.')]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Properties = @('DisplayName', 'EmailAddress', 'UserPrincipalName',
                                  'SamAccountName', 'Description', 'Title',
                                  'Department', 'Office', 'Enabled'),
        [string]$Server
    )

    # Run one LDAP search and return whatever it found.
    #
    # NOTE the @( ) around every call below, not just inside here: returning a
    # one-element array through & unwraps it back to a bare object, and a bare
    # object has no .Count - which would make a single clean match look like no
    # match at all. Wrap at the point of assignment.
    $search = {
        param($ldap)
        $p = @{ LDAPFilter = $ldap; Properties = $Properties; ErrorAction = 'SilentlyContinue' }
        if ($Server) { $p.Server = $Server }
        Get-ADUser @p
    }

    $clean = $Name.Trim()
    $safe  = ConvertTo-LdapEscapedString -Value $clean

    # Pass 1: exact.
    $hits = @(& $search "(|(sAMAccountName=$safe)(userPrincipalName=$safe)(mail=$safe)(displayName=$safe)(cn=$safe))")
    $how  = 'Exact'

    # Pass 2: the firstname.lastname convention, built from the first and last
    # words of the name ("Mary Jane Watson" -> mary.watson).
    if ($hits.Count -eq 0) {
        $words = @($clean -split '\s+' | Where-Object { $_ })
        if ($words.Count -ge 2) {
            $guess = ConvertTo-LdapEscapedString -Value ("{0}.{1}" -f $words[0], $words[-1])
            $hits  = @(& $search "(sAMAccountName=$guess)")
            $how   = 'UsernamePattern'
        }
    }

    # Pass 3: all words present, any order.
    if ($hits.Count -eq 0) {
        $words = @($clean -split '\s+' | Where-Object { $_ } |
                   ForEach-Object { ConvertTo-LdapEscapedString -Value $_ })
        if ($words.Count -gt 0) {
            $byDisplay = ($words | ForEach-Object { "(displayName=*$_*)" }) -join ''
            $byCn      = ($words | ForEach-Object { "(cn=*$_*)" }) -join ''
            $hits      = @(& $search "(|(&$byDisplay)(&$byCn))")
            $how       = 'NameParts'
        }
    }

    $status = switch ($hits.Count) {
        0       { 'NotFound' }
        1       { 'Matched' }
        default { 'Ambiguous' }
    }

    [pscustomobject]@{
        Status    = $status
        Users     = $hits
        MatchedBy = if ($status -eq 'NotFound') { '' } else { $how }
    }
}

# --- Console styling ---------------------------------------------------------
# The banner / header / menu-row helpers and the colour theme live in their own
# small file so the Jira console can share the exact same look without pulling in
# the whole library. Load it if it's there (it always is in a normal install).
$uiPath = Join-Path $PSScriptRoot 'Ui.ps1'
if (Test-Path $uiPath) { . $uiPath }

# The sign-off quote (Show-DeskSideSignoff) lives in Ui.ps1, dot-sourced just
# above, so both this toolkit and the Jira console share one implementation.

# --- Console UI helper -------------------------------------------------------
# Show a numbered list and return the chosen item (or $null for 0/Cancel).
# $Label is a scriptblock that turns one item into its display text, e.g.
#   Select-FromList $groups { param($g) $g.Name }
function Select-FromList {
    param(
        [array]$Items,
        [Parameter(Mandatory)][scriptblock]$Label,
        [string]$Prompt = 'Select number'
    )
    $Items = @($Items)
    if ($Items.Count -eq 0) { Write-Host "  (no matches)" -ForegroundColor Yellow; return $null }

    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-ToolMenuItem -Key ($i + 1) -Label (& $Label $Items[$i])
    }
    Write-ToolMenuItem -Key '0' -Label 'Cancel'

    $sel = Read-Host "  $Prompt"
    if (($sel -as [int]) -and [int]$sel -ge 1 -and [int]$sel -le $Items.Count) { return $Items[[int]$sel - 1] }
    if ($sel -ne '0') { Write-Host "Invalid selection." -ForegroundColor Yellow }
    return $null
}

# --- Snipe-IT REST API -------------------------------------------------------
# Generic request wrapper. Examples:
#   Invoke-SnipeRequest -Path 'hardware' -Query @{ limit = 50; search = 'dell' }
#   Invoke-SnipeRequest -Path 'hardware/2296'
function Invoke-SnipeRequest {
    param(
        [Parameter(Mandatory)][string]$Path,    # e.g. 'hardware'
        [hashtable]$Query,
        [ValidateSet('GET','POST','PUT','PATCH','DELETE')][string]$Method = 'GET',
        [string]$Body                            # JSON string for POST/PUT/PATCH
    )

    # Fail clearly if the token or URL env vars aren't set.
    if (-not $ADTool.SnipeIT.Token) {
        throw "SNIPEIT_TOKEN is not set. Run .\setup\Set-SnipeCredentials.ps1 to configure it."
    }
    if (-not $ADTool.SnipeIT.BaseUrl) {
        throw "SNIPEIT_URL is not set. Run .\setup\Set-SnipeCredentials.ps1 to configure it."
    }

    # Snipe-IT is HTTPS; make sure TLS 1.2 is enabled (needed on PS 5.1).
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $uri = "{0}/{1}" -f $ADTool.SnipeIT.BaseUrl.TrimEnd('/'), $Path.TrimStart('/')
    if ($Query -and $Query.Count) {
        $pairs = foreach ($k in $Query.Keys) { "$k=$([uri]::EscapeDataString([string]$Query[$k]))" }
        $uri += '?' + ($pairs -join '&')
    }

    $headers = @{
        Authorization  = $ADTool.SnipeIT.Token
        Accept         = 'application/json'
        'Content-Type' = 'application/json'
    }

    $params = @{ Uri = $uri; Headers = $headers; Method = $Method; ErrorAction = 'Stop' }
    if ($Body) { $params.Body = $Body }
    Invoke-RestMethod @params
}

# Snipe-IT returns dates as @{ date = ...; formatted = ... }. Return the friendly
# 'formatted' value when present, the raw value when it's a plain string, or ''
# for null. Use this everywhere a Snipe field is shown or written to a report.
function ConvertFrom-SnipeField {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value.PSObject -and ($Value.PSObject.Properties.Name -contains 'formatted')) { return $Value.formatted }
    return $Value
}

# Pull EVERY hardware row that matches a query, following Snipe-IT's paging.
# The API returns one page at a time (limit/offset); this keeps asking until a
# short page comes back or the safety cap is hit, so a query is never silently
# cut off at the first 50/500 rows.
#   Get-SnipeHardware -Query @{ search = 'ITDESSPARE'; status_id = 4 }
function Get-SnipeHardware {
    param(
        [hashtable]$Query = @{},
        [int]$PageSize = 500,
        [int]$MaxRows  = 5000
    )
    $all    = New-Object System.Collections.Generic.List[object]
    $offset = 0
    while ($true) {
        $q = @{} + $Query               # copy so the caller's hashtable is untouched
        $q.limit  = $PageSize
        $q.offset = $offset
        $resp  = Invoke-SnipeRequest -Path 'hardware' -Query $q
        $batch = @($resp.rows)
        foreach ($r in $batch) { $all.Add($r) }
        $offset += $PageSize
        if ($batch.Count -lt $PageSize -or $all.Count -ge $MaxRows) { break }
    }
    # Return the plain array (no leading comma). Callers wrap with @(), which
    # unrolls this correctly and gives an empty array when nothing matched. A
    # leading-comma "protective" return would instead nest inside that @() and
    # collapse every result into a single array-valued row.
    $all.ToArray()
}

# Write a report of a set of Snipe-IT assets to output\SnipeReports as JSON (for
# later parsing) and HTML (readable). $Criteria is a list of human-readable
# strings describing what was searched for - keywords, or "status = Ready to
# Deploy" style filters - shown as chips at the top of the report.
# Returns the two file paths. Prompts to open the HTML unless -NoPrompt.
function Write-SnipeAssetReport {
    param(
        [Parameter(Mandatory)][object[]]$Assets,
        [string[]]$Criteria = @(),
        [switch]$NoPrompt
    )
    $flat = $Assets | ForEach-Object {
        [PSCustomObject][ordered]@{
            AssetTag        = $_.asset_tag
            Name            = $_.name
            Model           = $_.model.name
            Manufacturer    = $_.manufacturer.name
            Category        = $_.category.name
            Status          = $_.status_label.name
            AssignedTo      = $_.assigned_to.name
            Location        = $_.location.name
            RtdLocation     = $_.rtd_location.name
            Serial          = $_.serial
            PurchaseDate    = (ConvertFrom-SnipeField $_.purchase_date)
            WarrantyExpires = (ConvertFrom-SnipeField $_.warranty_expires)
            Notes           = $_.notes
        }
    }

    $dir = Join-Path (Get-ADToolOutputDir) 'SnipeReports'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyy-MM-dd HHmmss'
    $json  = Join-Path $dir "Asset Report - $stamp.json"
    $html  = Join-Path $dir "Asset Report - $stamp.html"
    $count = @($flat).Count
    $when  = Get-Date -Format 'yyyy-MM-dd HH:mm'

    [ordered]@{
        criteria    = @($Criteria)
        generatedAt = (Get-Date -Format 'o')
        generatedBy = $env:USERNAME
        count       = $count
        assets      = $flat
    } | ConvertTo-Json -Depth 6 | Out-File -FilePath $json -Encoding UTF8

    # Escape every value so notes/names can't break the markup.
    function Enc($v) { ([string]$v) -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;' }
    $cols = 'AssetTag', 'Name', 'Model', 'Manufacturer', 'Category', 'Status', 'AssignedTo', 'Location', 'RtdLocation', 'Serial', 'PurchaseDate', 'WarrantyExpires', 'Notes'
    $head = ($cols | ForEach-Object { "<th>$(Enc $_)</th>" }) -join ''
    $rowsHtml = foreach ($r in $flat) {
        $cells = ($cols | ForEach-Object { "<td>$(Enc $r.$_)</td>" }) -join ''
        "<tr>$cells</tr>"
    }
    $chips = if (@($Criteria).Count) { ($Criteria | ForEach-Object { "<span>$(Enc $_)</span>" }) -join '' } else { '<span>(all assets)</span>' }
    $htmlDoc = @"
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Snipe-IT Asset Report</title>
<style>
 body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#222}
 h1{font-size:20px;margin:0 0 6px}
 .meta{color:#666;font-size:13px;margin-bottom:6px}
 .kw{margin:0 0 16px}
 .kw span{display:inline-block;background:#eef3f8;border:1px solid #d4e0ea;color:#33506b;
   border-radius:12px;padding:2px 10px;font-size:12px;margin:2px 4px 2px 0}
 table{border-collapse:collapse;width:100%;font-size:13px}
 th,td{border:1px solid #ddd;padding:6px 8px;text-align:left;vertical-align:top}
 th{background:#f4f6f8;position:sticky;top:0}
 tr:nth-child(even){background:#fafafa}
</style></head><body>
<h1>Snipe-IT Asset Report</h1>
<div class="meta">$count asset(s) &middot; generated $when by $(Enc $env:USERNAME)</div>
<div class="kw">Filters: $chips</div>
<table><thead><tr>$head</tr></thead><tbody>
$($rowsHtml -join "`n")
</tbody></table></body></html>
"@
    $htmlDoc | Out-File -FilePath $html -Encoding UTF8

    Write-Host "`nReport of $count asset(s) written to:" -ForegroundColor Green
    Write-Host "  $json"
    Write-Host "  $html"
    if (-not $NoPrompt -and (Read-Host "Open the HTML report now? (y/n)").Trim().ToUpper() -eq 'Y') { Start-Process $html }

    [pscustomobject]@{ Json = $json; Html = $html; Count = $count }
}

# --- Tactical RMM REST API ---------------------------------------------------
# Same idea as Invoke-SnipeRequest above, for the other system we talk to.
# Credentials come from environment variables so no key lives in source:
#   TRMM_APIKEY (required) - the API key from TRMM Settings > Global Settings
#   TRMM_URL    (required) - the api. address, e.g. https://api.contoso.com
#                            (NOT the rmm. website you log into)
# Set them once with: .\setup\Set-TacticalCredentials.ps1

# Check the two variables are set before a script tries to use them. Prints the
# fix and returns $false so the caller can stop cleanly:
#     if (-not (Test-TrmmConfigured)) { return }
function Test-TrmmConfigured {
    if ($env:TRMM_APIKEY -and $env:TRMM_URL) { return $true }
    Write-Host "TRMM_APIKEY / TRMM_URL are not set. Run setup\Set-TacticalCredentials.ps1 first." -ForegroundColor Red
    return $false
}

# Generic request wrapper. Examples:
#   Invoke-TrmmRequest GET 'agents/'
#   Invoke-TrmmRequest POST "agents/$id/cmd/" @{ shell = 'powershell'; cmd = 'hostname' }
# A hashtable passed as -Body is converted to JSON for you.
function Invoke-TrmmRequest {
    param(
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')][string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Path,
        $Body
    )
    if (-not $env:TRMM_APIKEY -or -not $env:TRMM_URL) {
        throw "TRMM_APIKEY / TRMM_URL are not set. Run .\setup\Set-TacticalCredentials.ps1 to configure them."
    }

    # TRMM is HTTPS; make sure TLS 1.2 is enabled (needed on PS 5.1).
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $headers = @{ 'X-API-KEY' = $env:TRMM_APIKEY; 'Content-Type' = 'application/json' }
    $params  = @{
        Uri         = "{0}/{1}" -f $env:TRMM_URL.TrimEnd('/'), $Path.TrimStart('/')
        Headers     = $headers
        Method      = $Method
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) { $params.Body = ($Body | ConvertTo-Json -Depth 5) }

    try {
        # Capture then emit: Invoke-RestMethod returns a JSON array as ONE object;
        # emitting it via a variable unrolls it into normal pipeline items.
        $result = Invoke-RestMethod @params
        $result
    }
    catch {
        # PowerShell's own message is just "400 Bad Request". TRMM's actual
        # explanation ("agent offline", "script not found") arrives in the
        # response body, which lands in ErrorDetails. Show that, then rethrow so
        # the calling script's own try/catch still runs.
        if ($_.ErrorDetails.Message) { Write-Host "TRMM API error: $($_.ErrorDetails.Message)" -ForegroundColor Red }
        throw
    }
}

# Run a PowerShell command on one agent and return TRMM's response.
# -AsUser runs it in the logged-in user's session, which is needed for anything
# that touches the desktop (locking the screen, showing a message box).
# -TimeoutSec is how long TRMM lets the command run before giving up.
function Invoke-TrmmAgentCommand {
    param(
        [Parameter(Mandatory)][string]$AgentId,
        [Parameter(Mandatory)][string]$Command,
        [switch]$AsUser,
        [int]$TimeoutSec = 90
    )
    Invoke-TrmmRequest -Method POST -Path "agents/$AgentId/cmd/" -Body @{
        shell        = 'powershell'
        cmd          = $Command
        timeout      = $TimeoutSec
        run_as_user  = [bool]$AsUser
        custom_shell = $null
    }
}

# Make text safe to drop INSIDE a single-quoted string in a remote command.
# A value that carries an apostrophe - a name like  caitlin.o'sullivan  or a
# path like  C:\Users\o'brien\  - would otherwise close the quote early and the
# whole remote command fails to parse ("Unexpected token 'sullivan'").
# In PowerShell a single quote is escaped by DOUBLING it, so:
#     $cmd = "Remove-Printer -Name '$(ConvertTo-RemoteLiteral $name)'"
# Build every remote command that embeds a name or path this way.
function ConvertTo-RemoteLiteral {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $Text.Replace("'", "''")
}

# --- Exchange Online ---------------------------------------------------------
# Make sure the ExchangeOnlineManagement module is present and a session is open,
# reusing an existing connection so you are not signed in over and over. Returns
# $true when ready to run Exchange cmdlets, $false (with guidance) when not.
#
# Sign-in is interactive (a browser/modern-auth window). Set EXO_ADMIN_UPN to
# your admin address to skip typing it each time - .\setup\Set-ExchangeAdmin.ps1.
function Connect-ExoSession {
    if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
        Write-Host "The ExchangeOnlineManagement module is not installed." -ForegroundColor Red
        Write-Host "Install it once (no admin rights needed):" -ForegroundColor Yellow
        Write-Host "    Install-Module ExchangeOnlineManagement -Scope CurrentUser" -ForegroundColor White
        Write-Host "Then open a new PowerShell window and try again." -ForegroundColor Yellow
        return $false
    }
    Import-Module ExchangeOnlineManagement -ErrorAction SilentlyContinue

    # Already connected? Reuse it rather than prompting again.
    try {
        $live = @(Get-ConnectionInformation -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Connected' })
        if ($live.Count -gt 0) { return $true }
    } catch { }

    $params = @{ ShowBanner = $false; ErrorAction = 'Stop' }
    if ($env:EXO_ADMIN_UPN) { $params.UserPrincipalName = $env:EXO_ADMIN_UPN }
    try {
        Write-Host "Connecting to Exchange Online (a sign-in window may open)..." -ForegroundColor DarkGray
        Connect-ExchangeOnline @params
        return $true
    }
    catch {
        Write-Host "Could not connect to Exchange Online: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# Search Exchange recipients by name or email (ANR) and let the operator pick
# one. $Types limits to certain RecipientTypeDetails (e.g. 'UserMailbox',
# 'SharedMailbox', 'MailUniversalDistributionGroup'). Returns the chosen
# recipient object, or $null.
function Find-ExoRecipient {
    param(
        [string]$Prompt = 'Search by name or email',
        [string[]]$Types
    )
    $kw = (Read-Host "  $Prompt").Trim()
    if (-not $kw) { return $null }
    try { $rows = @(Get-Recipient -ANR $kw -ResultSize 25 -ErrorAction Stop) }
    catch { Write-Host "  Lookup failed: $($_.Exception.Message)" -ForegroundColor Red; return $null }
    if ($Types) { $rows = @($rows | Where-Object { $Types -contains $_.RecipientTypeDetails }) }
    if ($rows.Count -eq 0) { Write-Host "  Nothing matched '$kw'." -ForegroundColor Yellow; return $null }
    Select-FromList -Items $rows -Prompt '  Number' -Label {
        param($r) "{0}   <{1}>   [{2}]" -f $r.DisplayName, $r.PrimarySmtpAddress, $r.RecipientTypeDetails
    }
}

# --- Microsoft Graph (M365 admin centre) -------------------------------------
# Licences, users and groups in the Microsoft 365 admin centre are Graph, not
# Exchange. These mirror the EXO helpers above.

# Ensure the Microsoft.Graph module is present and a session is open, reusing an
# existing one. Returns $true when ready, $false (with guidance) when not.
# Sign-in is interactive. Default scopes cover reading SKUs and changing a user's
# licences.
function Connect-MgGraphSession {
    param([string[]]$Scopes = @('User.ReadWrite.All', 'Organization.Read.All'))

    $haveModule = (Get-Module -ListAvailable -Name Microsoft.Graph) -or
                  ((Get-Module -ListAvailable -Name Microsoft.Graph.Users) -and
                   (Get-Module -ListAvailable -Name Microsoft.Graph.Identity.DirectoryManagement))
    if (-not $haveModule) {
        Write-Host "The Microsoft.Graph module is not installed." -ForegroundColor Red
        Write-Host "Install it once (no admin rights needed):" -ForegroundColor Yellow
        Write-Host "    Install-Module Microsoft.Graph -Scope CurrentUser" -ForegroundColor White
        Write-Host "(or the smaller Microsoft.Graph.Users + Microsoft.Graph.Identity.DirectoryManagement)" -ForegroundColor DarkGray
        return $false
    }

    # Already connected? Reuse it.
    try { if (Get-MgContext -ErrorAction SilentlyContinue) { return $true } } catch { }

    try {
        Write-Host "Connecting to Microsoft Graph (a sign-in window may open)..." -ForegroundColor DarkGray
        Connect-MgGraph -Scopes $Scopes -NoWelcome -ErrorAction Stop
        return $true
    }
    catch {
        Write-Host "Could not connect to Microsoft Graph: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# Resolve a licence SKU to its object (needs a live Graph session). Defaults to
# Office 365 E1 (SkuPartNumber STANDARDPACK); override the part number with the
# M365_E1_SKU environment variable or -PartNumber. If it isn't in the tenant,
# lists what IS available so the operator can pick the right part number.
function Get-M365LicenseSku {
    param([string]$PartNumber = $(if ($env:M365_E1_SKU) { $env:M365_E1_SKU } else { 'STANDARDPACK' }))
    try { $skus = @(Get-MgSubscribedSku -All -ErrorAction Stop) }
    catch { Write-Host "  Could not read licences: $($_.Exception.Message)" -ForegroundColor Red; return $null }

    $match = $skus | Where-Object { $_.SkuPartNumber -eq $PartNumber } | Select-Object -First 1
    if (-not $match) {
        Write-Host "  No licence with part number '$PartNumber' in this tenant. Available:" -ForegroundColor Yellow
        $skus | Sort-Object SkuPartNumber | ForEach-Object {
            $free = $_.PrepaidUnits.Enabled - $_.ConsumedUnits
            Write-Host ("    {0,-32} {1} free of {2}" -f $_.SkuPartNumber, $free, $_.PrepaidUnits.Enabled) -ForegroundColor DarkGray
        }
        Write-Host "  Set the right one with:  setx M365_E1_SKU <PartNumber>" -ForegroundColor DarkGray
        return $null
    }
    $match
}

# Add or remove a licence on one user (needs a live Graph session).
#   Set-M365UserLicense -UserId x@y -SkuId <guid> -Action Add
# On Add, the user needs a UsageLocation first (default CA, override
# M365_USAGE_LOCATION). Returns $true on success.
function Set-M365UserLicense {
    param(
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][string]$SkuId,
        [Parameter(Mandatory)][ValidateSet('Add', 'Remove')][string]$Action
    )
    try {
        if ($Action -eq 'Add') {
            $loc = if ($env:M365_USAGE_LOCATION) { $env:M365_USAGE_LOCATION } else { 'CA' }
            Update-MgUser -UserId $UserId -UsageLocation $loc -ErrorAction Stop
            Set-MgUserLicense -UserId $UserId -AddLicenses @(@{ SkuId = $SkuId }) -RemoveLicenses @() -ErrorAction Stop | Out-Null
        }
        else {
            Set-MgUserLicense -UserId $UserId -AddLicenses @() -RemoveLicenses @($SkuId) -ErrorAction Stop | Out-Null
        }
        return $true
    }
    catch {
        Write-Host "    Licence $Action failed for ${UserId}: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# --- SharePoint Online -------------------------------------------------------
# SharePoint admin uses the Microsoft.Online.SharePoint.PowerShell module (the
# "SPO Management Shell"), which works on Windows PowerShell 5.1. (PnP.PowerShell
# would be richer but its current version needs PowerShell 7.)

# Ensure the SPO module is present and a session is open, reusing an existing
# one. Needs the tenant admin URL in SPO_ADMIN_URL
# (e.g. https://contoso-admin.sharepoint.com). Sign-in is interactive.
# Returns $true when ready, $false (with guidance) when not.
function Connect-SpoSession {
    if (-not (Get-Module -ListAvailable -Name Microsoft.Online.SharePoint.PowerShell)) {
        Write-Host "The Microsoft.Online.SharePoint.PowerShell module is not installed." -ForegroundColor Red
        Write-Host "Install it once (no admin rights needed):" -ForegroundColor Yellow
        Write-Host "    Install-Module Microsoft.Online.SharePoint.PowerShell -Scope CurrentUser" -ForegroundColor White
        return $false
    }
    if (-not $env:SPO_ADMIN_URL) {
        Write-Host "SPO_ADMIN_URL is not set (e.g. https://contoso-admin.sharepoint.com)." -ForegroundColor Red
        Write-Host "Set it once with:  .\setup\Set-M365Config.ps1" -ForegroundColor Yellow
        return $false
    }
    Import-Module Microsoft.Online.SharePoint.PowerShell -ErrorAction SilentlyContinue

    # Already connected? Any admin cmdlet succeeds only with a live session.
    try { Get-SPOTenant -ErrorAction Stop | Out-Null; return $true } catch { }

    try {
        Write-Host "Connecting to SharePoint Online (a sign-in window may open)..." -ForegroundColor DarkGray
        Connect-SPOService -Url $env:SPO_ADMIN_URL -ErrorAction Stop
        return $true
    }
    catch {
        Write-Host "Could not connect to SharePoint Online: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# The root site URL (where /sites/<x> live), derived from the admin URL:
#   https://tenant-admin.sharepoint.com  ->  https://tenant.sharepoint.com
function Get-SpoRootUrl {
    if (-not $env:SPO_ADMIN_URL) { return '' }
    # TrimEnd so a trailing slash on SPO_ADMIN_URL doesn't become //sites/... later.
    ($env:SPO_ADMIN_URL -replace '-admin\.sharepoint\.com', '.sharepoint.com').TrimEnd('/')
}

# --- Audit logging -----------------------------------------------------------
# Append one row per change to output\AD-Toolkit-Actions.csv.
function Write-ActionLog {
    param(
        [Parameter(Mandatory)][string]$Action,    # e.g. 'Reset Password'
        [Parameter(Mandatory)][string]$Target,    # SAM the action applied to
        [string]$Result  = 'Success',             # Success / Failed / Cancelled
        [string]$Details = ''
    )
    $logPath = Join-Path (Get-ADToolOutputDir) 'AD-Toolkit-Actions.csv'
    [PSCustomObject]@{
        Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Operator  = $env:USERNAME
        Action    = $Action
        Target    = $Target
        Result    = $Result
        Details   = $Details
    } | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8 -Append
}

# Append a Snipe-IT asset-change event to output\Snipe-Asset-Changes.json.
# The file is kept as a single JSON array so it's easy to read and audit.
function Write-SnipeAssetLog {
    param(
        [Parameter(Mandatory)][string]$Action,    # Create / Update / Checkout / Checkin
        [Parameter(Mandatory)][string]$AssetTag,
        [int]$AssetId,
        [string]$Field,
        [string]$OldValue,
        [string]$NewValue,
        [string]$Result  = 'Success',
        [string]$Details  = ''
    )
    $logPath = Join-Path (Get-ADToolOutputDir) 'Snipe-Asset-Changes.json'

    $entry = [PSCustomObject]@{
        Timestamp = (Get-Date -Format 'o')   # ISO 8601
        Operator  = $env:USERNAME
        Action    = $Action
        AssetId   = $AssetId
        AssetTag  = $AssetTag
        Field     = $Field
        OldValue  = $OldValue
        NewValue  = $NewValue
        Result    = $Result
        Details   = $Details
    }

    # Read existing entries (if any) into a flat list, append, and rewrite.
    $entries = New-Object System.Collections.Generic.List[object]
    if (Test-Path $logPath) {
        try {
            $parsed = Get-Content $logPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            foreach ($p in @($parsed)) { $entries.Add($p) }
        }
        catch {
            # The file exists but will not parse - usually a half-written file
            # from a session that was closed mid-write.
            #
            # NEVER silently continue here. Continuing would start from an empty
            # list and the rewrite below would erase every past entry. Instead
            # move the damaged file aside (so it can still be read by hand) and
            # begin a fresh log, loudly.
            $stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
            $sidePath = "$logPath.corrupt-$stamp"
            Move-Item -LiteralPath $logPath -Destination $sidePath -Force
            Write-Host "WARNING: $(Split-Path $logPath -Leaf) could not be read and was kept as $(Split-Path $sidePath -Leaf)." -ForegroundColor Yellow
            Write-Host "         A new log starts from this entry. The old entries are still in that file." -ForegroundColor Yellow
        }
    }
    $entries.Add($entry)

    # -InputObject (not the pipeline) keeps the array intact; wrap a lone entry.
    $json = ConvertTo-Json -InputObject $entries.ToArray() -Depth 5
    if ($json.TrimStart() -notmatch '^\[') { $json = "[`r`n$json`r`n]" }

    # Write to a temporary file first, then swap it into place. The swap is a
    # single operation, so the real log is never in a half-written state - even
    # if the window is closed mid-save. This is what stops the corruption the
    # rescue above has to clean up after.
    $tempPath = "$logPath.tmp"
    $json | Out-File -FilePath $tempPath -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $logPath -Force
}
