<#
.SYNOPSIS
    Search Snipe-IT assets by a combination of filters - keyword, status,
    location, category, model, company - and export the results.

.DESCRIPTION
    Get-SnipeAsset.ps1 searches by one keyword. This is for the "find me every
    asset that is X and Y and Z" questions, e.g.

        spare desktops (ITDESSPARE) that are Ready to Deploy in the Admin building

    You build the filters one at a time, see them listed, then run. Add only the
    ones you care about; the rest are left wide open.

    HOW THE FILTERS ARE APPLIED
    Keyword, status, category, model and company are sent to Snipe-IT so the
    server does the narrowing. LOCATION is then matched here, on the results,
    against BOTH the asset's current location and its default (RTD) location -
    because a spare that has never been checked out has only a default location,
    and Snipe-IT's own location filter misses those. So "in the Admin building"
    finds a Ready-to-Deploy spare that lives there by default, which is usually
    exactly what you want.

    Read-only. It never changes an asset - to edit one, note its tag and open it
    in Get-SnipeAsset.ps1.

    Needs the Snipe-IT token - run .\setup\Set-SnipeCredentials.ps1 once.

.EXAMPLE
    .\Search-SnipeAssets.ps1
    Build the query interactively.
#>

param()

. "$PSScriptRoot\..\..\lib\Common.ps1"

if (-not $ADTool.SnipeIT.Token) {
    Write-Host "SNIPEIT_TOKEN is not set. Run setup\Set-SnipeCredentials.ps1 first." -ForegroundColor Red
    return
}

# --- The filter set we are building ------------------------------------------
# Each entry holds the value to send to the API (Id / text) and a human label
# for the on-screen summary and the report.
$filters = [ordered]@{
    Keyword  = @{ Label = ''; Query = $null }   # free text, goes to ?search=
    Status   = @{ Label = ''; Id    = $null }   # ?status_id=
    Location = @{ Label = ''; Id    = $null }   # matched here, on results
    Category = @{ Label = ''; Id    = $null }   # ?category_id=
    Model    = @{ Label = ''; Id    = $null }   # ?model_id=
    Company  = @{ Label = ''; Id    = $null }   # ?company_id=
}

# Pick one row from a Snipe-IT lookup list (locations, categories, ...). Returns
# the chosen row, or $null. $endpoint is the API path; $extraQuery lets the
# status picker pull every label without a search term.
function Select-SnipeThing ($endpoint, $prompt, $extraQuery = @{}) {
    $kw = (Read-Host "  $prompt keyword (ENTER to list some)").Trim()
    $q  = @{ limit = 100 } + $extraQuery
    if ($kw) { $q.search = $kw }
    try { $rows = @((Invoke-SnipeRequest -Path $endpoint -Query $q).rows) }
    catch { Write-Host "  Lookup failed: $($_.Exception.Message)" -ForegroundColor Red; return $null }
    if ($rows.Count -eq 0) { Write-Host "  Nothing matched." -ForegroundColor Yellow; return $null }
    Select-FromList -Items $rows -Label { param($x) if ($x.type) { "$($x.name)   ($($x.type))" } else { $x.name } } -Prompt '  Number'
}

function Show-Filters {
    Write-Host "`n--- Current filters ---" -ForegroundColor Cyan
    $any = $false
    foreach ($k in $filters.Keys) {
        if ($filters[$k].Label) { Write-Host ("  {0,-9}: {1}" -f $k, $filters[$k].Label); $any = $true }
    }
    if (-not $any) { Write-Host "  (none yet - the query would return everything)" -ForegroundColor DarkGray }
}

# A one-line description of each active filter, for the report chips.
function Get-CriteriaText {
    $c = @()
    foreach ($k in $filters.Keys) { if ($filters[$k].Label) { $c += "$($k.ToLower()) = $($filters[$k].Label)" } }
    $c
}

# --- Run the query -----------------------------------------------------------
function Invoke-Query {
    $query = @{}
    if ($filters.Keyword.Query)  { $query.search      = $filters.Keyword.Query }
    if ($filters.Status.Id)      { $query.status_id   = $filters.Status.Id }
    if ($filters.Category.Id)    { $query.category_id = $filters.Category.Id }
    if ($filters.Model.Id)       { $query.model_id    = $filters.Model.Id }
    if ($filters.Company.Id)     { $query.company_id  = $filters.Company.Id }

    Write-Host "`nAsking Snipe-IT..." -ForegroundColor DarkGray
    try { $rows = @(Get-SnipeHardware -Query $query) }
    catch { Write-Host "Query failed: $($_.Exception.Message)" -ForegroundColor Red; return }

    # Location is matched HERE, over current AND default location (see .DESCRIPTION).
    if ($filters.Location.Label) {
        $loc = $filters.Location.Label
        $rows = @($rows | Where-Object {
            ($_.location.name -eq $loc) -or ($_.rtd_location.name -eq $loc)
        })
    }

    $rows = @($rows | Sort-Object { $_.asset_tag })

    if ($rows.Count -eq 0) { Write-Host "`nNo assets match all of those filters." -ForegroundColor Yellow; return }

    Write-Host ("`n{0} asset(s) match:" -f $rows.Count) -ForegroundColor Green
    $i = 0
    $rows | ForEach-Object {
        $i++
        [PSCustomObject][ordered]@{
            '#'        = $i
            'Tag'      = $_.asset_tag
            'Name'     = $_.name
            'Model'    = $_.model.name
            'Status'   = $_.status_label.name
            'Location' = if ($_.location.name) { $_.location.name } else { "$($_.rtd_location.name) (default)" }
            'Assigned' = $_.assigned_to.name
        }
    } | Format-Table -AutoSize | Out-Host

    Write-Host "  [E] export report (JSON + HTML)   [ENTER] back to filters" -ForegroundColor White
    if ((Read-Host "Choose").Trim().ToUpper() -eq 'E') {
        Write-SnipeAssetReport -Assets $rows -Criteria (Get-CriteriaText) | Out-Null
    }
}

# --- Menu --------------------------------------------------------------------
Write-ToolHeader 'Snipe-IT asset query'

while ($true) {
    Show-Filters
    Write-Host ""
    Write-Host "  1) Keyword (tag, name, serial, model)"
    Write-Host "  2) Status        3) Location"
    Write-Host "  4) Category      5) Model         6) Company"
    Write-Host "  C) Clear all filters   R) Run the query   0) Exit"

    switch ((Read-Host "Choose").Trim().ToUpper()) {
        '1' {
            $kw = (Read-Host "  Keyword (ENTER to clear)").Trim()
            $filters.Keyword.Query = if ($kw) { $kw } else { $null }
            $filters.Keyword.Label = $kw
        }
        '2' {
            # Pull every status label (no search term) so the list is complete.
            $st = Select-SnipeThing 'statuslabels' 'Status'
            if ($st) { $filters.Status.Id = $st.id; $filters.Status.Label = $st.name }
        }
        '3' {
            $l = Select-SnipeThing 'locations' 'Location'
            if ($l) { $filters.Location.Id = $l.id; $filters.Location.Label = $l.name }
        }
        '4' {
            $c = Select-SnipeThing 'categories' 'Category'
            if ($c) { $filters.Category.Id = $c.id; $filters.Category.Label = $c.name }
        }
        '5' {
            $m = Select-SnipeThing 'models' 'Model'
            if ($m) { $filters.Model.Id = $m.id; $filters.Model.Label = $m.name }
        }
        '6' {
            $co = Select-SnipeThing 'companies' 'Company'
            if ($co) { $filters.Company.Id = $co.id; $filters.Company.Label = $co.name }
        }
        'C' {
            foreach ($k in $filters.Keys) { $filters[$k].Label = ''; if ($filters[$k].ContainsKey('Id')) { $filters[$k].Id = $null } else { $filters[$k].Query = $null } }
            Write-Host "Filters cleared." -ForegroundColor DarkGray
        }
        'R'     { Invoke-Query }
        '0'     { return }
        default { Write-Host "Unknown option." -ForegroundColor DarkGray }
    }
}
