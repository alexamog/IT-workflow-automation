<#
.SYNOPSIS
    Manage SharePoint Online sites: list/search, create (for a user), remove, and
    manage access by role - site collection admins, owners, members, and visitors
    - plus the primary owner and a one-tap "add me as admin to investigate".

.DESCRIPTION
    Uses the SharePoint Online Management Shell
    (Microsoft.Online.SharePoint.PowerShell), which runs on Windows PowerShell.
    Sign-in is interactive the first time. Needs the tenant admin URL in
    SPO_ADMIN_URL - set it once with .\setup\Set-M365Config.ps1.

    CREATE makes a site owned by the user you name - either a Communication site
    (for publishing / info) or a classic Team site (for collaboration). The
    "address" is the /sites/<name> part; the full URL is built for you.

    Note: a classic Team site here is NOT connected to a Microsoft 365 group
    (the SPO shell can't make group-connected sites - that needs Graph/PnP on
    PowerShell 7). For a group/Teams-backed site, create it from the M365 admin
    centre or Teams.

    Every change is confirmed first and written to the action log.

.EXAMPLE
    .\Manage-SharePointSite.ps1
#>

[CmdletBinding()]
param()

. "$PSScriptRoot\..\..\lib\Common.ps1"

if (-not (Connect-SpoSession)) { return }

$root = Get-SpoRootUrl

# Pick a site: search by URL or title, then choose from the list. Returns the
# site object, or $null.
function Select-SpoSite {
    $kw = (Read-Host "  Site URL or title keyword (ENTER to list some)").Trim()
    try { $sites = @(Get-SPOSite -Limit All -ErrorAction Stop) }
    catch { Write-Host "  Could not read sites: $($_.Exception.Message)" -ForegroundColor Red; return $null }
    if ($kw) { $sites = @($sites | Where-Object { $_.Url -match [regex]::Escape($kw) -or $_.Title -match [regex]::Escape($kw) }) }
    if ($sites.Count -eq 0) { Write-Host "  No site matched." -ForegroundColor Yellow; return $null }
    Select-FromList -Items ($sites | Sort-Object Url) -Prompt '  Number' -Label {
        param($s) "{0}   ({1})" -f $s.Url, $s.Title
    }
}

# --- List / search -----------------------------------------------------------
function Show-Sites {
    $kw = (Read-Host "  Filter by URL or title (ENTER for all)").Trim()
    Write-Host "  Reading sites..." -ForegroundColor DarkGray
    try { $sites = @(Get-SPOSite -Limit All -ErrorAction Stop) }
    catch { Write-Host "  Could not read sites: $($_.Exception.Message)" -ForegroundColor Red; return }
    if ($kw) { $sites = @($sites | Where-Object { $_.Url -match [regex]::Escape($kw) -or $_.Title -match [regex]::Escape($kw) }) }
    if ($sites.Count -eq 0) { Write-Host "  No sites match." -ForegroundColor Yellow; return }

    $ordered = @($sites | Sort-Object Url)
    Write-Host ("`n  {0} site(s):" -f $ordered.Count) -ForegroundColor Green
    $n = 0
    $ordered | ForEach-Object {
        $n++
        [PSCustomObject][ordered]@{
            '#'        = $n
            Title      = $_.Title
            Url        = $_.Url
            Owner      = $_.Owner
            StorageMB  = $_.StorageQuota
            Template   = $_.Template
            Status     = $_.Status
        }
    } | Format-Table -AutoSize | Out-Host

    # Pick one to manage its access (admins / owners / members / visitors).
    $sel = (Read-Host "  Manage which site? (number, or ENTER to go back)").Trim()
    if ($sel -and ($sel -as [int]) -and [int]$sel -ge 1 -and [int]$sel -le $ordered.Count) {
        Edit-SiteAccessFor $ordered[[int]$sel - 1]
    }
}

# --- Create ------------------------------------------------------------------
function New-Site {
    $title = (Read-Host "  Site title (what people see)").Trim()
    if (-not $title) { Write-Host "  Cancelled." -ForegroundColor Yellow; return }

    $leaf = (Read-Host "  Site address - the /sites/<this> part (letters, digits, hyphens)").Trim()
    if ($leaf -notmatch '^[A-Za-z0-9\-]+$') { Write-Host "  That address has characters SharePoint won't accept." -ForegroundColor Red; return }
    $url = "$root/sites/$leaf"

    $owner = (Read-Host "  Owner (the user's email)").Trim()
    if (-not $owner) { Write-Host "  Cancelled." -ForegroundColor Yellow; return }

    Write-Host "  Site type:" -ForegroundColor Cyan
    Write-Host "    1. Communication site (publishing / info)"
    Write-Host "    2. Team site (classic collaboration)"
    $template = switch ((Read-Host "  Choose (1/2)").Trim()) {
        '1'     { 'SITEPAGEPUBLISHING#0' }
        '2'     { 'STS#0' }
        default { Write-Host "  Cancelled." -ForegroundColor Yellow; return }
    }

    $quotaIn = (Read-Host "  Storage quota in MB (ENTER for 1024)").Trim()
    $quota = 1024
    if ($quotaIn -and -not [int]::TryParse($quotaIn, [ref]$quota)) { Write-Host "  Not a number - using 1024." -ForegroundColor DarkYellow; $quota = 1024 }

    # Time-zone ID: from config (SPO_TIMEZONE), else ask. 13 = (UTC-08:00) Pacific;
    # the full list is in the SharePoint admin docs (SPRegionalSettings TimeZone id).
    $tz = 0
    if ($ADTool.SpoTimeZone -and [int]::TryParse([string]$ADTool.SpoTimeZone, [ref]$tz)) { }
    else {
        $tzIn = (Read-Host "  Time-zone ID (e.g. 13 = Pacific, 10 = Eastern; ENTER for 13)").Trim()
        if (-not $tzIn) { $tz = 13 }
        elseif (-not [int]::TryParse($tzIn, [ref]$tz)) { Write-Host "  Not a number - using 13." -ForegroundColor DarkYellow; $tz = 13 }
    }

    Write-Host ""
    Write-Host "  About to create:" -ForegroundColor Cyan
    Write-Host ("    Title    : {0}" -f $title)
    Write-Host ("    URL      : {0}" -f $url)
    Write-Host ("    Owner    : {0}" -f $owner)
    Write-Host ("    Type     : {0}" -f $(if ($template -eq 'SITEPAGEPUBLISHING#0') { 'Communication' } else { 'Team (classic)' }))
    Write-Host ("    Storage  : {0} MB" -f $quota)
    Write-Host ("    TimeZone : {0}" -f $tz)
    if (-not (Confirm-DeskSideAction 'Create it?' -Indent '  ')) { return }

    try {
        # New-SPOSite is synchronous-ish; the site may take a minute to provision.
        New-SPOSite -Url $url -Owner $owner -Title $title -Template $template -StorageQuota $quota -TimeZone $tz -ErrorAction Stop | Out-Null
        Write-Host "  Created $url (owner $owner). It can take a minute to finish provisioning." -ForegroundColor Green
        Write-ActionLog -Action 'SharePoint: Create Site' -Target $url -Details "owner=$owner; template=$template; ${quota}MB"
    }
    catch {
        Write-Host "  Create failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-ActionLog -Action 'SharePoint: Create Site' -Target $url -Result 'Failed' -Details $_.Exception.Message
    }
}

# --- Remove ------------------------------------------------------------------
function Remove-Site {
    $site = Select-SpoSite
    if (-not $site) { return }

    Write-Host ""
    Write-Host "  This deletes the site and everything in it:" -ForegroundColor Yellow
    Write-Host ("    {0}   ({1})" -f $site.Url, $site.Title)
    Write-Host "  It goes to the SharePoint recycle bin (recoverable for ~93 days), not gone forever." -ForegroundColor DarkGray
    if (-not (Confirm-DeskSideWord 'delete this site' -CancelNote 'nothing deleted' -Indent '  ')) { return }

    try {
        Remove-SPOSite -Identity $site.Url -Confirm:$false -ErrorAction Stop
        Write-Host "  Deleted (in the recycle bin)." -ForegroundColor Green
        Write-ActionLog -Action 'SharePoint: Remove Site' -Target $site.Url -Details "title=$($site.Title)"
    }
    catch {
        Write-Host "  Delete failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-ActionLog -Action 'SharePoint: Remove Site' -Target $site.Url -Result 'Failed' -Details $_.Exception.Message
    }
}

# Find the site's Owners / Members / Visitors group. The default associated
# groups are named "<Title> Owners" etc., so match on that first; if a site was
# customised, fall back to the permission level each role implies, and if it is
# still unclear, let the operator pick. Returns the group Title, or $null.
function Get-SiteRoleGroupName ($SiteUrl, $Role) {
    try { $groups = @(Get-SPOSiteGroup -Site $SiteUrl -ErrorAction Stop) }
    catch { Write-Host "  Could not read the site's groups: $($_.Exception.Message)" -ForegroundColor Red; return $null }
    if ($groups.Count -eq 0) { Write-Host "  This site has no SharePoint groups." -ForegroundColor Yellow; return $null }

    # 1. By name (the normal case).
    $byName = @($groups | Where-Object { $_.Title -match ("\s$Role$") })
    if ($byName.Count -eq 1) { return $byName[0].Title }

    # 2. By the permission level the role implies.
    $levels = switch ($Role) {
        'Owners'   { @('Full Control') }
        'Members'  { @('Edit', 'Contribute') }
        'Visitors' { @('Read') }
    }
    $byRole = @($groups | Where-Object { @($_.Roles | Where-Object { $levels -contains $_ }).Count -gt 0 })
    if ($byRole.Count -eq 1) { return $byRole[0].Title }

    # 3. Ambiguous - ask.
    Write-Host "  Couldn't identify the $Role group automatically - pick it:" -ForegroundColor DarkYellow
    $g = Select-FromList -Items ($groups | Sort-Object Title) -Prompt '  Group number' -Label {
        param($x) "{0}   [{1}]" -f $x.Title, ($x.Roles -join ', ')
    }
    if ($g) { $g.Title } else { $null }
}

# Add or remove a batch of people in one role. $Role is Admins/Owners/Members/
# Visitors; $Add is $true to add, $false to remove.
function Set-SiteRoleMembers ($SiteUrl, $Role, [bool]$Add, $People) {
    if ($People.Count -eq 0) { Write-Host "  Nobody entered." -ForegroundColor Yellow; return }

    # Admins are site collection admins (a flag on the user), not a group.
    if ($Role -eq 'Admins') {
        foreach ($p in $People) {
            try {
                Set-SPOUser -Site $SiteUrl -LoginName $p -IsSiteCollectionAdmin $Add -ErrorAction Stop | Out-Null
                Write-Host ("    {0} - {1} site admin." -f $p, $(if ($Add) { 'added as' } else { 'removed as' })) -ForegroundColor Green
                Write-ActionLog -Action ("SharePoint: {0} Site Admin" -f $(if ($Add) { 'Add' } else { 'Remove' })) -Target $SiteUrl -Details $p
            }
            catch {
                Write-Host "    $p - failed: $($_.Exception.Message)" -ForegroundColor Red
                Write-ActionLog -Action ("SharePoint: {0} Site Admin" -f $(if ($Add) { 'Add' } else { 'Remove' })) -Target $SiteUrl -Result 'Failed' -Details "$p : $($_.Exception.Message)"
            }
        }
        return
    }

    # Owners / Members / Visitors are SharePoint groups.
    $group = Get-SiteRoleGroupName $SiteUrl $Role
    if (-not $group) { return }
    foreach ($p in $People) {
        try {
            if ($Add) { Add-SPOUser    -Site $SiteUrl -LoginName $p -Group $group -ErrorAction Stop | Out-Null }
            else      { Remove-SPOUser -Site $SiteUrl -LoginName $p -Group $group -ErrorAction Stop | Out-Null }
            Write-Host ("    {0} - {1} {2}." -f $p, $(if ($Add) { 'added to' } else { 'removed from' }), $group) -ForegroundColor Green
            Write-ActionLog -Action ("SharePoint: {0} {1}" -f $(if ($Add) { 'Add' } else { 'Remove' }), $Role) -Target $SiteUrl -Details "$p / $group"
        }
        catch {
            Write-Host "    $p - failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-ActionLog -Action ("SharePoint: {0} {1}" -f $(if ($Add) { 'Add' } else { 'Remove' }), $Role) -Target $SiteUrl -Result 'Failed' -Details "$p / $group : $($_.Exception.Message)"
        }
    }
}

# Ask which role to act on. Returns 'Admins'/'Owners'/'Members'/'Visitors' or $null.
function Select-AccessRole {
    Write-Host "  Which role?" -ForegroundColor Cyan
    Write-ToolMenuItem -Key 1 -Label 'Site admins' -Note 'full control of the whole site collection'
    Write-ToolMenuItem -Key 2 -Label 'Owners'      -Note 'full control of the site'
    Write-ToolMenuItem -Key 3 -Label 'Members'     -Note 'edit content'
    Write-ToolMenuItem -Key 4 -Label 'Visitors'    -Note 'read-only'
    switch ((Read-Host '  Select').Trim()) {
        '1'     { 'Admins' }
        '2'     { 'Owners' }
        '3'     { 'Members' }
        '4'     { 'Visitors' }
        default { $null }
    }
}

# Print who currently has access: site collection admins, then each group.
function Show-SiteAccess ($SiteUrl) {
    try { $users = @(Get-SPOUser -Site $SiteUrl -Limit All -ErrorAction Stop) }
    catch { Write-Host "  Could not read the site's users: $($_.Exception.Message)" -ForegroundColor Red; $users = @() }
    $admins = @($users | Where-Object { $_.IsSiteAdmin } | Select-Object -ExpandProperty LoginName)
    Write-Host "`n  Site admins (site collection):" -ForegroundColor Cyan
    if ($admins.Count) { $admins | ForEach-Object { Write-Host "     - $_" } }
    else { Write-Host "     (none)" -ForegroundColor DarkGray }

    try { $groups = @(Get-SPOSiteGroup -Site $SiteUrl -ErrorAction Stop) }
    catch { Write-Host "  Could not read the site's groups: $($_.Exception.Message)" -ForegroundColor Red; return }
    foreach ($g in $groups) {
        Write-Host ("`n  {0}   [{1}]" -f $g.Title, ($g.Roles -join ', ')) -ForegroundColor Cyan
        $members = @($g.Users)
        if ($members.Count) { $members | ForEach-Object { Write-Host "     - $_" } }
        else { Write-Host "     (no members)" -ForegroundColor DarkGray }
    }
}

function Edit-SiteAccess {
    $site = Select-SpoSite
    if (-not $site) { return }
    Edit-SiteAccessFor $site
}

# The access menu for a site that has already been chosen (from a search or
# picked out of the list/search results).
function Edit-SiteAccessFor ($site) {
    $url = $site.Url

    while ($true) {
        Write-Host ("`n  Site: {0}" -f $url) -ForegroundColor DarkCyan
        Write-Host ("  Primary owner: {0}" -f $site.Owner) -ForegroundColor DarkGray
        Write-ToolMenuItem -Key 1 -Label 'Show who has access' -Note 'admins, owners, members, visitors'
        Write-ToolMenuItem -Key 2 -Label 'Add people to a role'
        Write-ToolMenuItem -Key 3 -Label 'Remove people from a role'
        Write-ToolMenuItem -Key 4 -Label 'Add ME as a site admin' -Note 'to investigate'
        Write-ToolMenuItem -Key 5 -Label 'Remove ME as a site admin'
        Write-ToolMenuItem -Key 6 -Label 'Change the primary owner'
        Write-ToolMenuItem -Key 0 -Label 'Back'
        Write-Host ''

        switch ((Read-Host '  Select').Trim()) {
            '1' { Show-SiteAccess $url }
            '2' {
                $role = Select-AccessRole
                if (-not $role) { continue }
                $people = ConvertFrom-PeopleList (Read-Host "  People to ADD as $role (emails, comma-separated)")
                Set-SiteRoleMembers $url $role $true $people
            }
            '3' {
                $role = Select-AccessRole
                if (-not $role) { continue }
                $people = ConvertFrom-PeopleList (Read-Host "  People to REMOVE from $role (emails, comma-separated)")
                Set-SiteRoleMembers $url $role $false $people
            }
            '4' {
                $me = Get-DeskSideAdminUpn
                if (-not $me) { continue }
                Write-Host ("  Grant {0} site collection admin on {1}?" -f $me, $url) -ForegroundColor Cyan
                if (-not (Confirm-DeskSideAction 'Go ahead?' -Indent '  ')) { continue }
                Set-SiteRoleMembers $url 'Admins' $true @($me)
            }
            '5' {
                $me = Get-DeskSideAdminUpn
                if (-not $me) { continue }
                Set-SiteRoleMembers $url 'Admins' $false @($me)
            }
            '6' {
                $who = (Read-Host "  New primary owner (email)").Trim()
                if (-not $who) { continue }
                try {
                    Set-SPOSite -Identity $url -Owner $who -ErrorAction Stop
                    Write-Host "  Owner set to $who." -ForegroundColor Green
                    Write-ActionLog -Action 'SharePoint: Set Owner' -Target $url -Details $who
                    $site.Owner = $who
                }
                catch { Write-Host "  Failed: $($_.Exception.Message)" -ForegroundColor Red }
            }
            '0'     { return }
            default { Write-Host "  Unknown option." -ForegroundColor DarkGray }
        }
    }
}

# --- Menu --------------------------------------------------------------------
while ($true) {
    Write-ToolHeader 'SharePoint sites'
    Write-ToolMenuItem -Key 1 -Label 'List / search sites' -Note 'pick one to manage its access'
    Write-ToolMenuItem -Key 2 -Label 'Create a site' -Note 'for a user (they own it)'
    Write-ToolMenuItem -Key 3 -Label 'Remove a site'
    Write-ToolMenuItem -Key 4 -Label 'Access (admins / owners / members / visitors)'
    Write-ToolMenuItem -Key 0 -Label 'Back'
    Write-Host ''

    switch ((Read-Host '  Select').Trim()) {
        '1'     { Show-Sites }
        '2'     { New-Site }
        '3'     { Remove-Site }
        '4'     { Edit-SiteAccess }
        '0'     { return }
        default { Write-Host 'Unknown option.' -ForegroundColor DarkGray }
    }
}
