<#
.SYNOPSIS
    Find Snipe-IT hardware by keyword: asset tag, serial, name, model, and (for
    phones) IMEI or phone number. One match shows the full detail card; several
    show a list you can drill into. After viewing an asset you can edit its
    Name, Status, Assigned to, and Notes.

.PARAMETER Search
    Text to search for. If omitted, you'll be prompted.

.PARAMETER Limit
    Max number of results to return (default 50).

.EXAMPLE
    .\Get-SnipeAsset.ps1 0000001980
    .\Get-SnipeAsset.ps1 -Search "latitude" -Limit 25
#>

param(
    [string]$Search,
    [int]$Limit = 50
)

. "$PSScriptRoot\..\..\lib\Common.ps1"

if (-not $PSBoundParameters.ContainsKey('Search')) {
    $Search = Read-Host "Search assets (tag, serial, name, model, IMEI, or phone #)"
}

# Field formatting (Get-Field) and the report writer now live in lib\Common.ps1
# as ConvertFrom-SnipeField and Write-SnipeAssetReport, shared with the asset
# query tool. Thin alias so the call sites below stay readable.
function Get-Field($value) { ConvertFrom-SnipeField $value }

# Re-fetch a single asset (returns the asset object).
function Get-Asset($id) { Invoke-SnipeRequest -Path "hardware/$id" }

# Read a Snipe-IT custom field value by name; '' if the asset doesn't have it.
function Get-CustomField($a, $name) {
    if (-not $a.custom_fields) { return '' }
    $prop = $a.custom_fields.PSObject.Properties[$name]
    if ($prop) { return $prop.Value.value }
    return ''
}

# Full detail card for a single asset.
function Show-AssetCard($a) {
    Write-ToolHeader 'Asset Detail'
    $card = [ordered]@{
        'ID'           = $a.id
        'Asset Tag'    = $a.asset_tag
        'Name'         = $a.name
        'Serial'       = $a.serial
        'Model'        = $a.model.name
        'Manufacturer' = $a.manufacturer.name
        'Category'     = $a.category.name
        'Status'       = $a.status_label.name
        'Assigned To'  = $a.assigned_to.name
        'Location'     = $a.location.name
    }

    # Phone fields: only shown when the asset actually has them (e.g. a phone).
    $imei  = Get-CustomField $a 'IMEI'
    $phone = Get-CustomField $a 'Phone Number'
    $sim   = Get-CustomField $a 'SIM'
    if ($imei -or $phone -or $sim) {
        $card['IMEI']         = $imei
        $card['Phone Number'] = $phone
        $card['SIM']          = $sim
    }

    $card['Purchase Date']    = (Get-Field $a.purchase_date)
    $card['Warranty Expires'] = (Get-Field $a.warranty_expires)
    $card['Last Checkout']    = (Get-Field $a.last_checkout)
    $card['Created']          = (Get-Field $a.created_at)
    $card['Notes']            = $a.notes

    [PSCustomObject]$card | Format-List
}

# PATCH simple fields (name / status_id / notes). Returns the refreshed asset.
function Set-AssetPatch($a, $body, $label) {
    # Work out field + old/new value for the change log.
    $field = @($body.Keys)[0]
    $old   = switch ($field) {
        'name'            { $a.name }
        'serial'          { $a.serial }
        'notes'           { $a.notes }
        'status_id'       { $a.status_label.name }
        'rtd_location_id' { $a.rtd_location.name }
        'model_id'        { $a.model.name }
        default           { '' }
    }
    $new = if     ($field -eq 'status_id')       { ($label -replace '^status -> ', '') }
           elseif ($field -eq 'rtd_location_id') { ($label -replace '^location -> ', '') }
           elseif ($field -eq 'model_id')        { ($label -replace '^model -> ', '') }
           else                                  { [string]$body[$field] }

    try { $resp = Invoke-SnipeRequest -Path "hardware/$($a.id)" -Method PATCH -Body ($body | ConvertTo-Json) }
    catch {
        Write-Host "Update failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-SnipeAssetLog -Action 'Update' -AssetTag $a.asset_tag -AssetId $a.id -Field $field -OldValue $old -NewValue $new -Result 'Failed' -Details $_.Exception.Message
        return $a
    }

    if ($resp.status -eq 'success') {
        Write-Host "Updated $label." -ForegroundColor Green
        Write-SnipeAssetLog -Action 'Update' -AssetTag $a.asset_tag -AssetId $a.id -Field $field -OldValue $old -NewValue $new
        return (Get-Asset $a.id)
    }

    Write-Host "Update failed: $($resp.messages | ConvertTo-Json -Compress)" -ForegroundColor Red
    Write-SnipeAssetLog -Action 'Update' -AssetTag $a.asset_tag -AssetId $a.id -Field $field -OldValue $old -NewValue $new -Result 'Failed' -Details ($resp.messages | ConvertTo-Json -Compress)
    return $a
}

# Change the "Assigned to" via checkout (user/location) or checkin (unassign).
function Edit-Assignment($a) {
    Write-Host "`nAssignment:" -ForegroundColor Cyan
    Write-Host "  1. Check out to a USER"
    Write-Host "  2. Check out to a LOCATION"
    Write-Host "  3. Check in (unassign)"
    Write-Host "  0. Cancel"

    switch (Read-Host "Choose") {
        '1' {
            $kw = Read-Host "User keyword (name or email)"
            $u  = Select-FromList (Invoke-SnipeRequest -Path 'users' -Query @{ search = $kw; limit = 25 }).rows `
                    { param($x) "$($x.name)   ($($x.username))" }
            if ($u) { return (Set-Assignment $a 'user' 'assigned_user' $u.id $u.name) }
        }
        '2' {
            $kw = Read-Host "Location keyword"
            $l  = Select-FromList (Invoke-SnipeRequest -Path 'locations' -Query @{ search = $kw; limit = 25 }).rows `
                    { param($x) $x.name }
            if ($l) { return (Set-Assignment $a 'location' 'assigned_location' $l.id $l.name) }
        }
        '3' {
            if (-not $a.assigned_to) { Write-Host "Not currently assigned." -ForegroundColor Yellow; return $a }
            try { $resp = Invoke-SnipeRequest -Path "hardware/$($a.id)/checkin" -Method POST -Body '{}' }
            catch { Write-Host "Checkin failed: $($_.Exception.Message)" -ForegroundColor Red; return (Get-Asset $a.id) }
            if ($resp.status -eq 'success') {
                Write-Host "Checked in (unassigned)." -ForegroundColor Green
                Write-SnipeAssetLog -Action 'Checkin' -AssetTag $a.asset_tag -AssetId $a.id -Field 'assigned_to' -OldValue $a.assigned_to.name -NewValue ''
            } else {
                Write-Host "Checkin failed: $($resp.messages | ConvertTo-Json -Compress)" -ForegroundColor Red
                Write-SnipeAssetLog -Action 'Checkin' -AssetTag $a.asset_tag -AssetId $a.id -Field 'assigned_to' -Result 'Failed' -Details ($resp.messages | ConvertTo-Json -Compress)
            }
            return (Get-Asset $a.id)
        }
    }
    return $a
}

# Check an asset out to a user or location (checking in first if needed so a
# reassignment works). Returns the refreshed asset.
function Set-Assignment($a, $type, $field, $targetId, $targetName) {
    if ($a.assigned_to) {
        # Snipe-IT will not check an asset out to a second person while it is
        # still out to the first, so check it in first. If THAT fails, say so:
        # the checkout below will then fail too, and its message ("not
        # deployable") does not explain that this step is the real cause.
        try { Invoke-SnipeRequest -Path "hardware/$($a.id)/checkin" -Method POST -Body '{}' | Out-Null }
        catch {
            Write-Host "Could not check the asset in from $($a.assigned_to.name) first: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    $body = @{ checkout_to_type = $type; status_id = $a.status_label.id; $field = $targetId }
    try { $resp = Invoke-SnipeRequest -Path "hardware/$($a.id)/checkout" -Method POST -Body ($body | ConvertTo-Json) }
    catch { Write-Host "Checkout failed: $($_.Exception.Message)" -ForegroundColor Red; return (Get-Asset $a.id) }

    if ($resp.status -eq 'success') {
        Write-Host "Assigned to $targetName." -ForegroundColor Green
        Write-SnipeAssetLog -Action 'Checkout' -AssetTag $a.asset_tag -AssetId $a.id -Field 'assigned_to' -OldValue $a.assigned_to.name -NewValue $targetName
    } else {
        Write-Host "Checkout failed: $($resp.messages | ConvertTo-Json -Compress)" -ForegroundColor Red
        Write-Host "(Tip: the status must be a 'deployable' type to check out.)" -ForegroundColor DarkGray
        Write-SnipeAssetLog -Action 'Checkout' -AssetTag $a.asset_tag -AssetId $a.id -Field 'assigned_to' -NewValue $targetName -Result 'Failed' -Details ($resp.messages | ConvertTo-Json -Compress)
    }
    return (Get-Asset $a.id)
}

# PATCH a custom field (e.g. IMEI, Phone Number) by its display name. The db
# column name is read from the asset's own custom_fields. Returns refreshed asset.
function Set-CustomField($a, $name, $value) {
    $entry = if ($a.custom_fields) { $a.custom_fields.PSObject.Properties[$name] } else { $null }
    if (-not $entry) { Write-Host "This asset has no '$name' field." -ForegroundColor Yellow; return $a }
    $col = $entry.Value.field
    $old = $entry.Value.value

    try { $resp = Invoke-SnipeRequest -Path "hardware/$($a.id)" -Method PATCH -Body (@{ $col = $value } | ConvertTo-Json) }
    catch {
        Write-Host "Update failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-SnipeAssetLog -Action 'Update' -AssetTag $a.asset_tag -AssetId $a.id -Field $name -OldValue $old -NewValue $value -Result 'Failed' -Details $_.Exception.Message
        return $a
    }
    if ($resp.status -eq 'success') {
        Write-Host "Updated $name." -ForegroundColor Green
        Write-SnipeAssetLog -Action 'Update' -AssetTag $a.asset_tag -AssetId $a.id -Field $name -OldValue $old -NewValue $value
        return (Get-Asset $a.id)
    }
    Write-Host "Update failed: $($resp.messages | ConvertTo-Json -Compress)" -ForegroundColor Red
    Write-SnipeAssetLog -Action 'Update' -AssetTag $a.asset_tag -AssetId $a.id -Field $name -OldValue $old -NewValue $value -Result 'Failed' -Details ($resp.messages | ConvertTo-Json -Compress)
    return $a
}

# Edit menu for a single asset.
function Edit-Asset($a) {
    do {
        # Phone custom fields (present only on phones).
        $imeiEntry  = if ($a.custom_fields) { $a.custom_fields.PSObject.Properties['IMEI'] }         else { $null }
        $phoneEntry = if ($a.custom_fields) { $a.custom_fields.PSObject.Properties['Phone Number'] } else { $null }

        Write-Host "`nEdit $($a.asset_tag):" -ForegroundColor Cyan
        Write-Host "  1. Name        (current: $($a.name))"
        Write-Host "  2. Status      (current: $($a.status_label.name))"
        Write-Host "  3. Assigned to (current: $($a.assigned_to.name))"
        Write-Host "  4. Notes       (current: $($a.notes))"
        Write-Host "  5. Location    (current: $($a.rtd_location.name))"
        Write-Host "  6. Serial      (current: $($a.serial))"
        Write-Host "  7. Model       (current: $($a.model.name))"
        if ($imeiEntry)  { Write-Host "  8. IMEI        (current: $($imeiEntry.Value.value))" }
        if ($phoneEntry) { Write-Host "  9. Phone #     (current: $($phoneEntry.Value.value))" }
        Write-Host "  0. Done"

        switch (Read-Host "Choose field to edit") {
            '1' { $a = Set-AssetPatch $a @{ name = (Read-Host "New name") }  'name' }
            '6' { $a = Set-AssetPatch $a @{ serial = (Read-Host "New serial") } 'serial' }
            '2' {
                $st = Select-FromList (Invoke-SnipeRequest -Path 'statuslabels' -Query @{ limit = 50 }).rows `
                        { param($x) "$($x.name)   ($($x.type))" }
                if ($st) { $a = Set-AssetPatch $a @{ status_id = $st.id } "status -> $($st.name)" }
            }
            '3' { $a = Edit-Assignment $a }
            '4' { $a = Set-AssetPatch $a @{ notes = (Read-Host "New notes") } 'notes' }
            '5' {
                $kw  = Read-Host "Location keyword"
                $loc = Select-FromList (Invoke-SnipeRequest -Path 'locations' -Query @{ search = $kw; limit = 25 }).rows `
                        { param($x) $x.name }
                if ($loc) { $a = Set-AssetPatch $a @{ rtd_location_id = $loc.id } "location -> $($loc.name)" }
            }
            '7' {
                $kw  = Read-Host "Model keyword (e.g. OptiPlex, Server)"
                $mdl = Select-FromList (Invoke-SnipeRequest -Path 'models' -Query @{ search = $kw; limit = 50 }).rows `
                        { param($x) $x.name }
                if ($mdl) { $a = Set-AssetPatch $a @{ model_id = $mdl.id } "model -> $($mdl.name)" }
            }
            '8' { if ($imeiEntry)  { $a = Set-CustomField $a 'IMEI'         (Read-Host "New IMEI") }         else { Write-Host "Invalid choice." -ForegroundColor Yellow } }
            '9' { if ($phoneEntry) { $a = Set-CustomField $a 'Phone Number' (Read-Host "New phone number") } else { Write-Host "Invalid choice." -ForegroundColor Yellow } }
            '0' { return $a }
            default { Write-Host "Invalid choice." -ForegroundColor Yellow }
        }
    } while ($true)
}

# Open Snipe-IT's built-in label page for the asset in the default browser.
function Out-AssetLabel($a) {
    $webRoot  = $ADTool.SnipeIT.BaseUrl -replace '/api/v1$', ''
    $labelUrl = "$webRoot/hardware/$($a.id)/label"
    Write-Host "Opening label page: $labelUrl" -ForegroundColor Green
    Start-Process $labelUrl
}

# Show an asset, then offer per-asset actions (edit / label).
function Show-AssetActions($a) {
    do {
        Show-AssetCard $a
        Write-Host "  1. Edit this asset"
        Write-Host "  2. Print / generate label"
        Write-Host "  0. Back"
        switch (Read-Host "Choose") {
            '1' { $a = Edit-Asset $a }
            '2' { Out-AssetLabel $a }
            '0' { return }
            default { Write-Host "Invalid choice." -ForegroundColor Yellow }
        }
    } while ($true)
}

# Run one keyword search, return its rows (empty on error).
function Search-Assets($term) {
    try { @((Invoke-SnipeRequest -Path 'hardware' -Query @{ search = $term; limit = $Limit }).rows) }
    catch { Write-Host "Search '$term' failed: $($_.Exception.Message)" -ForegroundColor Red; @() }
}

# Report of the current results -> shared writer in lib\Common.ps1.
function Out-AssetReport($assets, $terms) {
    Write-SnipeAssetReport -Assets @($assets) -Criteria @($terms) | Out-Null
}

# --- Search ------------------------------------------------------------------
try { $result = Invoke-SnipeRequest -Path 'hardware' -Query @{ search = $Search; limit = $Limit } }
catch { Write-Host "Snipe-IT request failed: $($_.Exception.Message)" -ForegroundColor Red; return }

$rows = @($result.rows | Sort-Object { $_.name })   # alphabetical by Name
if ($rows.Count -eq 0) { Write-Host "No assets found for '$Search'." -ForegroundColor Yellow; return }

# Single match: straight to the card (+ actions).
if ($rows.Count -eq 1) { Show-AssetActions $rows[0]; return }

# Several matches: show a clean, auto-aligned table and drill into one (0 = exit).
do {
    Write-Host ("`nShowing {0} of {1} match(es):" -f $rows.Count, $result.total) -ForegroundColor Cyan

    $i = 0
    $rows | ForEach-Object {
        $i++
        [PSCustomObject][ordered]@{
            '#'           = $i
            'Tag'         = $_.asset_tag
            'Name'        = $_.name
            'Model'       = $_.model.name
            'Assigned To' = $_.assigned_to.name
            'Status'      = $_.status_label.name
            'Serial'      = $_.serial
        }
    } | Format-Table -AutoSize | Out-Host

    $sel = (Read-Host "Select a number to view/edit, [R] to report (add more keywords), or 0 to exit").Trim()
    if ($sel -eq '0') { break }
    if ($sel.ToUpper() -eq 'R') {
        # Combine several keyword searches into one report - handles inconsistent
        # naming (e.g. ITLAPSPARE and ITSPARELAP are both spare laptops).
        $terms = @($Search)
        $more = (Read-Host "Extra keywords to include, comma-separated (ENTER = just '$Search')").Trim()
        if ($more) { $terms += @($more -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        $terms = @($terms | Select-Object -Unique)

        $byId = @{}
        foreach ($tm in $terms) { foreach ($r in (Search-Assets $tm)) { $byId[$r.id] = $r } }
        $combined = @($byId.Values | Sort-Object { $_.name })

        Write-Host ("Combined {0} unique asset(s) across {1} keyword(s): {2}" -f $combined.Count, $terms.Count, ($terms -join ', ')) -ForegroundColor Cyan
        Out-AssetReport $combined $terms
        continue
    }
    if (($sel -as [int]) -and [int]$sel -ge 1 -and [int]$sel -le $rows.Count) {
        Show-AssetActions $rows[[int]$sel - 1]
    }
    else { Write-Host "Invalid selection." -ForegroundColor Yellow }
} while ($true)
