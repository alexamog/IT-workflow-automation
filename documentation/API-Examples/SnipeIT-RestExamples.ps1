<#
    SnipeIT-RestExamples.ps1  -  minimal Snipe-IT v1 REST skeletons.
    Dot-source it, then call the functions. Needs these env vars:
        SNIPEIT_TOKEN  the raw API token (no "Bearer " prefix)
        SNIPEIT_URL    optional, default https://assets.contoso.ca/api/v1
#>

# One wrapper for every call: Bearer auth + Invoke-RestMethod.
# Write calls return { status = 'success'|'error' } even on HTTP 200 - check .status.
function Snipe ($Method, $Path, $Body) {
    $base = if ($env:SNIPEIT_URL) { $env:SNIPEIT_URL } else { 'https://assets.contoso.ca/api/v1' }
    $headers = @{ Authorization = "Bearer $env:SNIPEIT_TOKEN"; Accept = 'application/json'; 'Content-Type' = 'application/json' }
    Invoke-RestMethod -Uri "$($base.TrimEnd('/'))/$Path" -Headers $headers -Method $Method -Body $Body
}

# Search assets (matches name, tag, serial, and custom fields like IMEI). Returns .rows.
function Find-Asset ($keyword) {
    (Snipe GET "hardware?search=$([uri]::EscapeDataString($keyword))&limit=25").rows
}

# One asset by its asset tag.
function Get-AssetByTag ($tag) { Snipe GET "hardware/bytag/$tag" }

# A reference list you pick from when creating an asset (models, categories,
# manufacturers, statuslabels, locations, fields, ...). Returns .rows.
function Get-List ($type) { (Snipe GET "$type`?limit=100").rows }

# Create an asset (model_id + status_id required; leave tag out to auto-generate).
function New-Asset ($modelId, $statusId, $name, $serial) {
    $body = @{ model_id = $modelId; status_id = $statusId; name = $name; serial = $serial } | ConvertTo-Json
    Snipe POST 'hardware' $body
}

# Edit an asset (pass only the fields to change, e.g. @{ name = 'NEW' }).
function Edit-Asset ($id, $fields) { Snipe PATCH "hardware/$id" ($fields | ConvertTo-Json) }

# Check out to a user / check back in.
function Checkout-Asset ($id, $userId) {
    Snipe POST "hardware/$id/checkout" (@{ checkout_to_type = 'user'; assigned_user = $userId } | ConvertTo-Json)
}
function Checkin-Asset ($id) { Snipe POST "hardware/$id/checkin" '{}' }

# --- examples ---
# Find-Asset 'ThinkPad'
# $m = Get-List 'models' | Where-Object { $_.name -match 'E16 Gen 1' } | Select-Object -First 1
# New-Asset $m.id 2 'LT-0999' 'SN12345'          # check the result's .status
# Edit-Asset 42 @{ name = 'LT-0001' }
