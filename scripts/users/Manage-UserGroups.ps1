<#
.SYNOPSIS
    View and manage a user's AD group membership (by SAM or UPN):
    list groups, add to a group (search by keyword), or remove from a group.

.PARAMETER Identity
    SamAccountName or UPN. If omitted, you'll be prompted.

.EXAMPLE
    .\Manage-UserGroups.ps1 alex.amog
#>

#Requires -Modules ActiveDirectory
param([string]$Identity)

. "$PSScriptRoot\..\..\lib\Common.ps1"

if (-not $Identity) { $Identity = Read-Host "Enter SAM or UPN" }

$user = Resolve-ADToolUser -Identity $Identity
if (-not $user) { return }
$sam = $user.SamAccountName

# Current membership.
Write-Host "`nGroups for $($user.Name)  ($sam):" -ForegroundColor Cyan
Get-ADPrincipalGroupMembership -Identity $sam | Sort-Object Name |
    Select-Object Name, GroupCategory, GroupScope | Format-Table -AutoSize | Out-Host

Write-Host "  1. Add to a group (search by keyword)"
Write-Host "  2. Remove from a group"
Write-Host "  0. Done"

switch (Read-Host "Choose an action") {

    '1' {
        $kw = Read-Host "Group name keyword (e.g. All Staff Distribution)"
        if (-not $kw) { return }
        $found = Get-ADGroup -Filter "Name -like '*$kw*'" -Properties GroupCategory | Sort-Object Name
        Write-Host "`nMatching groups:" -ForegroundColor Cyan
        $group = Select-FromList -Items $found -Label { param($g) "$($g.Name)   [$($g.GroupCategory)/$($g.GroupScope)]" }
        if (-not $group) { return }
        try {
            Add-ADGroupMember -Identity $group.DistinguishedName -Members $sam -ErrorAction Stop
            Write-Host "Added $sam to '$($group.Name)'." -ForegroundColor Green
            Write-ActionLog -Action 'Group Add' -Target $sam -Details "Added to $($group.Name)"
        }
        catch {
            Write-DeskSideFailure "Failed" 'Group Add' $sam $_ -Context "$($group.Name)"
        }
    }

    '2' {
        # Pick from the groups the user is actually in.
        $current = @(Get-ADPrincipalGroupMembership -Identity $sam | Sort-Object Name)
        Write-Host "`nRemove from which group?" -ForegroundColor Cyan
        $group = Select-FromList -Items $current -Label { param($g) "$($g.Name)   [$($g.GroupCategory)/$($g.GroupScope)]" }
        if (-not $group) { return }
        try {
            Remove-ADGroupMember -Identity $group.DistinguishedName -Members $sam -Confirm:$false -ErrorAction Stop
            Write-Host "Removed $sam from '$($group.Name)'." -ForegroundColor Green
            Write-ActionLog -Action 'Group Remove' -Target $sam -Details "Removed from $($group.Name)"
        }
        catch {
            Write-DeskSideFailure "Failed" 'Group Remove' $sam $_ -Context "$($group.Name)"
        }
    }

    default { Write-Host "No change made." -ForegroundColor Yellow }
}
