<#
.SYNOPSIS
    Add a new Snipe-IT asset by cloning an existing hardware model.

.DESCRIPTION
    Workflow:
      1. Choose the asset type (Standard, or Phone).
      2. Type a keyword (e.g. "E16 Gen 1") to find matching models.
      3. Pick the model to clone (carries category, manufacturer, and any
         model custom-field template).
      4. Set the per-device fields: Name, Status, Location, Notes, Assigned to,
         and Serial. A Phone also captures IMEI and Phone number.
      5. The asset is created; if an assignee was chosen it is checked out.

    Asset tags are left blank so Snipe-IT auto-generates them (its tags are
    sequential). You can supply one if prompted/needed.
#>

. "$PSScriptRoot\..\..\lib\Common.ps1"

# Create a new model when the one you need isn't in Snipe-IT yet. Returns the
# created model (with .id and .name), or $null on cancel/failure.
function New-SnipeModel {
    Write-Host "`nAdd a new model:" -ForegroundColor Cyan
    $mName = Read-Host "Model name (e.g. ThinkPad E16 Gen 1)"
    if (-not $mName) { return $null }

    Write-Host "Category:" -ForegroundColor Cyan
    $cats     = (Invoke-SnipeRequest -Path 'categories' -Query @{ limit = 100 }).rows |
                    Where-Object { $_.category_type -eq 'asset' } | Sort-Object name
    $category = Select-FromList -Items $cats -Label { param($c) $c.name }
    if (-not $category) { return $null }

    Write-Host "Manufacturer (keyword search):" -ForegroundColor Cyan
    $mfKw         = Read-Host "Manufacturer keyword"
    $mfs          = (Invoke-SnipeRequest -Path 'manufacturers' -Query @{ search = $mfKw; limit = 25 }).rows
    $manufacturer = Select-FromList -Items $mfs -Label { param($m) $m.name }
    if (-not $manufacturer) { return $null }

    $modelNumber = Read-Host "Model number (ENTER to skip)"

    # A fieldset gives the model its custom fields. Phones need the 'Cell Phone'
    # fieldset so the asset gets IMEI / Phone number / SIM.
    Write-Host "Fieldset (pick the phone fieldset for phones; Cancel to skip):" -ForegroundColor Cyan
    $fieldset = Select-FromList -Items (Invoke-SnipeRequest -Path 'fieldsets').rows -Label { param($f) $f.name }

    $body = @{ name = $mName; category_id = $category.id; manufacturer_id = $manufacturer.id }
    if ($modelNumber) { $body.model_number = $modelNumber }
    if ($fieldset)    { $body.fieldset_id  = $fieldset.id }

    try { $resp = Invoke-SnipeRequest -Path 'models' -Method POST -Body ($body | ConvertTo-Json) }
    catch { Write-Host "Create model failed: $($_.Exception.Message)" -ForegroundColor Red; return $null }

    if ($resp.status -ne 'success') {
        Write-Host "Create model failed: $($resp.messages | ConvertTo-Json -Compress)" -ForegroundColor Red
        return $null
    }
    Write-Host "Created model '$($resp.payload.name)' (id $($resp.payload.id))." -ForegroundColor Green
    return $resp.payload
}

# --- 0. Asset type ----------------------------------------------------------
# A phone additionally captures Serial, IMEI, and Phone number.
Write-Host "Asset type:" -ForegroundColor Cyan
$type = Select-FromList -Items @(
    [PSCustomObject]@{ Name = 'Standard asset';                    Phone = $false }
    [PSCustomObject]@{ Name = 'Phone (Serial, IMEI, Phone number)'; Phone = $true }
) -Label { param($t) $t.Name }
if (-not $type) { return }
$isPhone = $type.Phone

# --- 1. Find the model to clone ---------------------------------------------
$keyword = Read-Host "Model keyword to clone (e.g. E16 Gen 1)"
if (-not $keyword) { Write-Host "Cancelled." -ForegroundColor Yellow; return }

try { $models = (Invoke-SnipeRequest -Path 'models' -Query @{ search = $keyword; limit = 25 }).rows }
catch { Write-Host "Snipe-IT request failed: $($_.Exception.Message)" -ForegroundColor Red; return }

# Offer the matches plus an "add a new model" option (in case yours isn't listed).
Write-Host "`nMatching models (or add a new one):" -ForegroundColor Cyan
$options = @($models) + [PSCustomObject]@{ id = '__ADD__'; name = '+ Add a new model' }
$model = Select-FromList -Items $options -Label {
    param($x) if ($x.id -eq '__ADD__') { $x.name } else { "$($x.name)   [$($x.manufacturer.name) / $($x.category.name)]" }
}
if (-not $model) { return }
if ($model.id -eq '__ADD__') {
    $model = New-SnipeModel
    if (-not $model) { return }
}

# --- 2-6. Per-device fields --------------------------------------------------
$name = Read-Host "`nName for the new asset"

Write-Host "`nStatus:" -ForegroundColor Cyan
$statuses = (Invoke-SnipeRequest -Path 'statuslabels' -Query @{ limit = 50 }).rows
$status = Select-FromList -Items $statuses -Label { param($x) "$($x.name)   ($($x.type))" }
if (-not $status) { return }

Write-Host "`nLocation (keyword search):" -ForegroundColor Cyan
$locKw    = Read-Host "Location keyword"
$locations = (Invoke-SnipeRequest -Path 'locations' -Query @{ search = $locKw; limit = 25 }).rows
$location  = Select-FromList -Items $locations -Label { param($x) $x.name }

$notes = Read-Host "`nNotes"

Write-Host "`nAssign to user (keyword search, or ENTER to skip):" -ForegroundColor Cyan
$asgKw    = Read-Host "User keyword (name or email)"
$assignee = $null
if ($asgKw) {
    $users = (Invoke-SnipeRequest -Path 'users' -Query @{ search = $asgKw; limit = 25 }).rows
    $assignee = Select-FromList -Items $users -Label { param($x) "$($x.name)   ($($x.username))" }
}

# --- Serial + phone-only fields ----------------------------------------------
# Serial is REQUIRED for a standard asset (workstation); optional for a phone.
$serial = $null; $imei = $null; $phoneNumber = $null
if ($isPhone) {
    $serial = Read-Host "`nSerial number (ENTER to skip)"
    Write-Host "`nPhone details:" -ForegroundColor Cyan
    $imei        = Read-Host "IMEI"
    $phoneNumber = Read-Host "Phone number"
} else {
    do {
        $serial = (Read-Host "`nSerial number (required)").Trim()
        if (-not $serial) { Write-Host "A serial number is required for this asset. Press Ctrl+C to abort." -ForegroundColor Yellow }
    } while (-not $serial)
}

# --- Confirm -----------------------------------------------------------------
Write-Host "`n--------------- New asset summary ---------------" -ForegroundColor Cyan
Write-Host "  Type       : $($type.Name)"
Write-Host "  Model      : $($model.name)"
Write-Host "  Name       : $name"
Write-Host "  Status     : $($status.name)"
Write-Host "  Location   : $(if ($location) { $location.name } else { '(none)' })"
Write-Host "  Notes      : $notes"
Write-Host "  Assigned to: $(if ($assignee) { $assignee.name } else { '(none)' })"
Write-Host "  Serial     : $serial"
if ($isPhone) {
    Write-Host "  IMEI       : $imei"
    Write-Host "  Phone #    : $phoneNumber"
}
if ((Read-Host "`nCreate this asset? (Y/N)") -notmatch '^[Yy]') { Write-Host "Cancelled." -ForegroundColor Yellow; return }

# --- Create ------------------------------------------------------------------
$body = @{ model_id = $model.id; status_id = $status.id; name = $name; notes = $notes }
if ($location) { $body.rtd_location_id = $location.id }
if ($serial)   { $body.serial = $serial }   # serial applies to any asset type

# Phone: IMEI and Phone number are custom fields whose column names are
# resolved from this instance (so it works anywhere).
if ($isPhone) {
    try { $fields = (Invoke-SnipeRequest -Path 'fields' -Query @{ limit = 200 }).rows } catch { $fields = @() }
    $imeiCol  = ($fields | Where-Object { $_.name -match '(?i)imei' }  | Select-Object -First 1).db_column_name
    $phoneCol = ($fields | Where-Object { $_.name -match '(?i)phone' } | Select-Object -First 1).db_column_name
    if ($imei        -and $imeiCol)  { $body[$imeiCol]  = $imei }
    if ($phoneNumber -and $phoneCol) { $body[$phoneCol] = $phoneNumber }
    if ($imei        -and -not $imeiCol)  { Write-Host "Note: no IMEI custom field found - IMEI not set." -ForegroundColor Yellow }
    if ($phoneNumber -and -not $phoneCol) { Write-Host "Note: no Phone Number custom field found - phone number not set." -ForegroundColor Yellow }
}

try {
    $create = Invoke-SnipeRequest -Path 'hardware' -Method POST -Body ($body | ConvertTo-Json)
}
catch { Write-Host "Create request failed: $($_.Exception.Message)" -ForegroundColor Red; return }

if ($create.status -ne 'success') {
    Write-Host "Create failed: $($create.messages | ConvertTo-Json -Compress)" -ForegroundColor Red
    Write-SnipeAssetLog -Action 'Create' -AssetTag $name -Field 'asset' -NewValue $name -Result 'Failed' -Details ($create.messages | ConvertTo-Json -Compress)
    return
}

$new = $create.payload
Write-Host "`nCreated asset: tag $($new.asset_tag)  (id $($new.id))" -ForegroundColor Green
Write-SnipeAssetLog -Action 'Create' -AssetTag $new.asset_tag -AssetId $new.id -Field 'asset' -NewValue $name -Details "Model '$($model.name)'"

# --- Optional checkout to the assignee --------------------------------------
if ($assignee) {
    $coBody = @{ checkout_to_type = 'user'; assigned_user = $assignee.id; status_id = $status.id } | ConvertTo-Json
    try {
        $co = Invoke-SnipeRequest -Path "hardware/$($new.id)/checkout" -Method POST -Body $coBody
        if ($co.status -eq 'success') {
            Write-Host "Checked out to $($assignee.name)." -ForegroundColor Green
            Write-SnipeAssetLog -Action 'Checkout' -AssetTag $new.asset_tag -AssetId $new.id -Field 'assigned_to' -NewValue $assignee.name
        } else {
            Write-Host "Checkout failed: $($co.messages | ConvertTo-Json -Compress)" -ForegroundColor Red
            Write-Host "(Tip: the status must be a 'deployable' type to check out.)" -ForegroundColor DarkGray
            Write-SnipeAssetLog -Action 'Checkout' -AssetTag $new.asset_tag -AssetId $new.id -Field 'assigned_to' -NewValue $assignee.name -Result 'Failed' -Details ($co.messages | ConvertTo-Json -Compress)
        }
    }
    catch { Write-Host "Checkout request failed: $($_.Exception.Message)" -ForegroundColor Red }
}
