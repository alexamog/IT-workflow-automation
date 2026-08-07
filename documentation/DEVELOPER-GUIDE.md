# Developer Guide

For whoever maintains or extends Desk Side Toolkit. Plain `.ps1`, no build step,
Windows PowerShell 5.1.

## Architecture

```
AD-Toolkit.ps1            auto-discovering launcher (scans *.tool.psd1, builds menu)
   scripts\<cat>\*.ps1    one feature per script + a *.tool.psd1 manifest beside it
   lib\Common.ps1         shared config ($ADTool) + helpers, dot-sourced by scripts
   lib\Ui.ps1             console look-and-feel: banners, menu rows, the colour
                          theme, and the confirmation prompts. Loaded BY
                          Common.ps1, and separately by the Jira console - so it
                          must never depend on anything in Common.ps1.
   lib\Printer.ps1        hand-rolled SNMP + IPP clients for network printers.
                          Loaded by Common.ps1. See its header for why this is
                          protocol code rather than a module dependency.
   lib\Quotes.psd1        the sign-off quotes, read at run time by Ui.ps1
Jira Scripts\             self-contained console, own layered lib\ (separate stack)
setup\                    credential/config setters (env vars)
tests\                    Pester tests: Common.Tests.ps1 covers lib\Common.ps1 and
                          lib\Ui.ps1; Printer.Tests.ps1 covers lib\Printer.ps1
Publish-Standalone.ps1    generates standalone editions + Core from this project
```

`lib\` travels as a unit - Common.ps1 dot-sources Ui.ps1 and Printer.ps1, and
Ui.ps1 reads Quotes.psd1 - so anything that copies the library copies the whole
folder. Shipping a subset produces an edition that loads but fails at first use.

Each feature is independent: its own script (runnable alone) + a manifest that
places it on the menu. No central list to edit.

## Launcher (AD-Toolkit.ps1)

- Scans the tree for `*.tool.psd1` manifests via `Import-PowerShellDataFile`
  (parses data only, no code execution).
- Each manifest: `@{ Category=...; Label=...; Order=... }`. Its feature script is
  the sibling with the same base name (`Foo.tool.psd1` -> `Foo.ps1`).
- Categories appear in `Order`; items sort by `Order`. Single-item category runs
  directly.
- Optional `Audience = 'Admin' | 'Standard' | 'Both'` (default `Both`) in a
  manifest gates the feature by how the launcher is run: running as the local
  **SYSTEM** account (`Test-RunningAsSystem` - LocalSystem SID `S-1-5-18`, or a
  `SYSTEM` username) counts as `Admin` (AD / Microsoft tools), everything else as
  `Standard` (Jira / Snipe-IT / RMM). Mismatched features show greyed
  (`Write-ToolMenuItem -Disabled`), sort below the usable ones, and refuse to
  run; a category with no runnable feature greys as a whole. UI gating only -
  each script still enforces its own rights.
- Does **not** `#Requires` ActiveDirectory - AD-free features (Snipe, TRMM) run
  without RSAT. AD scripts declare their own `#Requires -Modules ActiveDirectory`.
- Optional `toolkit.psd1` at root sets the banner title (standalone editions use
  it; main project defaults to "Desk Side Toolkit").

## lib\Common.ps1

Config in `$ADTool` (each setting reads an env var, falls back to a default - so
URLs/OUs/domain change with no code edit). No file-level `#Requires` (loads
without AD; the AD helpers just fail if called without the module).

Helpers: `Resolve-ADToolUser` (SAM/UPN, via `-LDAPFilter` +
`ConvertTo-LdapEscapedString` - never build a `-Filter` string by hand, an
apostrophe in a name breaks it), `Get-ADToolDC` (PDC unless `-Server`),
`Select-FromList`, `Invoke-SnipeRequest` (Snipe REST, auth+TLS),
`Test-TrmmConfigured`/`Invoke-TrmmRequest`/`Invoke-TrmmAgentCommand` (TRMM REST,
auth+TLS, surfaces the API's real error from `ErrorDetails`),
`Get-ADToolOutputDir`/`Get-ADToolDataDir`, `Write-ActionLog` (CSV),
`Write-SnipeAssetLog` (JSON, temp-file swap + keeps a damaged file aside rather
than overwriting history).

Batch helpers: `Import-StaffRosterFile` (parses the name/role/location text file
- comma, tab, or 2+ spaces; a single space is never a separator or "John Doe"
would split), `Resolve-ADToolUserByName` (three passes: exact, then the
firstname.lastname convention, then all name parts in any order for
"Surname, Firstname"; returns Matched/Ambiguous/NotFound and never picks one
when several match), `Select-LocalFilePath` (Open-file dialog, falls back to
typing).

Covered by `tests\Common.Tests.ps1`; run `.\Run-Tests.ps1` after editing.

## Batch onboarding / offboarding (scripts\onboarding\, scripts\offboarding\)

Both follow the same shape: read the list, look everyone up WITHOUT changing
anything, print a plan grouped by outcome, confirm, then act only on the
approved set.

`Start-Offboarding.ps1` covers one person and a list from the same code: `-Name`
builds a one-entry roster by hand, `-Path` parses a file, and everything after
that point is identical. Report CSVs are only written for a list - a one-row CSV
per single disable is noise, and the console plus the audit log already have it.
Disabling by *username* stays in `Set-UserAccountState.ps1`; this script is the
by-full-name route with the leaver review card. Anything uncertain - name not found, name matching several
accounts - is written to an exceptions CSV in `output\` and never acted on.
Onboarding also checks the list's role against `-RoleField` (default `Auto` =
Title, falling back to Description) and skips mismatches unless
`-IncludeRoleMismatch`; if EVERY person mismatches it says so, because that
means the wrong field is configured.

Role comparison is `Test-StaffRoleMatchesTitle`. Lists carry the payroll short
form (`Cas SRW`, `COOK037`); AD carries the full title (`Shelter Resource
Worker`, `Cook`). Rather than a hand-kept abbreviation table, it exploits the
fact that the short form is prefixes of the title's words in order -
S|helter R|esource W|orker, Jan|itor Maint|enance - and strips the `Cas`
employment prefix and any trailing position number first. Verified against all
117 distinct job titles on the domain: no abbreviation matches an unrelated
title. It DOES accept near-neighbours (`Cas COOK` vs `Lead Cook`), which is
intended - the check exists to catch a wrong-person match, not to audit HR.

Gotcha worth knowing: `$hits = & $scriptblock ...` unwraps a one-element array
back to a bare object, and a bare object has no `.Count` - which silently turned
a single clean match into "Ambiguous". Wrap with `@( )` at the assignment.

## Add a feature

1. `scripts\<category>\Verb-Noun.ps1`. If it needs helpers, first line:
   ```powershell
   . "$PSScriptRoot\..\..\lib\Common.ps1"
   ```
   AD cmdlets? add `#Requires -Modules ActiveDirectory`.
2. `scripts\<category>\Verb-Noun.tool.psd1`:
   ```powershell
   @{ Category = 'Reporting'; Label = 'Show stale accounts'; Order = 63 }
   ```

Delete/rename = touch those two files only.

### New external system

Add settings to `$ADTool` in `Common.ps1` (env var + default), add a request
wrapper next to `Invoke-SnipeRequest`, then write feature scripts + manifests.

## Jira console (Jira Scripts\)

Separate layered stack, dot-sourced by `Start-JiraConsole.ps1`:
`Context` (auth, `$script:BaseUrl/$Headers/$MyAccountId`, resolves Org field id) ->
`Helpers` (pure: `ConvertTo-TicketJql`, `Sort-TicketForDisplay`, `Convert-HtmlToText`,
`Get-AdfText`) -> `Data` (read JQL/issue/user) -> `Display` -> `Actions` (writes) ->
`Interaction` (menus). Main menu switch lives in `Start-JiraConsole.ps1`. Full
detail: `Jira Scripts\docs\ARCHITECTURE.md`. Auth = Basic (email:token base64).

## Tactical RMM scripts (scripts\remote\)

All dot-source `lib\Common.ps1` and go through `Invoke-TrmmRequest` /
`Invoke-TrmmAgentCommand` - do not hand-roll another `Invoke-RestMethod` wrapper
(there were ten, and they drifted). Auth header `X-API-KEY`, base `$env:TRMM_URL`
(the `api.` host). Hub = `Start-TrmmConsole.ps1` (find machine by hostname or
`logged_username`, then act); it calls the action scripts with the hostname.
`Enter-TrmmShell`, `Send-TrmmFile`, and `Invoke-RemoteProfileCleanup` have no
`.tool.psd1` on purpose: the hub launches them, so they stay off the main menu.

To keep the Remote category short, two grouping menus each launch a set of
scripts: `Manage-TrmmProfiles.ps1` (Find user profile / scan corrupt / repair)
and `Invoke-TrmmSnipeAudit.ps1` (the two Snipe-IT audits). Those five underlying
scripts had their `.tool.psd1` removed so they no longer appear at the top level;
they still run standalone and are reached through the grouping menu. If you add a
new profile or audit tool, drop it into the matching grouping menu rather than
giving it its own top-level manifest.

`Repair-TrmmCorruptProfile.ps1` is the non-destructive counterpart to
`Find-TrmmCorruptProfile.ps1`: same detection, but instead of deleting it repairs
the ProfileList registry entry and keeps the folder. Remote command exports the
whole ProfileList key first (undo = reg import), then either renames `<SID>.bak`
back over the broken `<SID>` or clears the corrupt `State`/`RefCount`. Guards:
skips loaded profiles, skips ones whose folder is gone (no data to keep - those
are the finder's job), re-checks state on the machine right before acting.
Verified by capturing the generated command and running it against a throwaway
HKCU hive (rename / state / skip-loaded / no-folder all correct). Fixes registry-
state corruption only, not folder-ACL corruption.

`Manage-TrmmPrinters.ps1` reads printers/ports/drivers in ONE `cmd/` round trip,
using `###SECTION###` markers and a `~|~` field separator, then parses back into
objects. Values typed by the operator are pasted into a remote command inside
single quotes, so they go through `ConvertTo-RemoteLiteral` (doubles `'`) first -
"Reception's Printer" would otherwise end the quote and break the command.
Two PowerShell 5.1 traps bitten here: `[pscustomobject]@{ X = @($genericList) }`
throws "Argument types do not match" (use `.ToArray()`), and `@(...)` around a
piped filter that yields one string unrolls to a char array when indexed.

Endpoints used: `agents/`, `agents/{id}/`, `agents/{id}/cmd/` (run PowerShell,
`run_as_user` for user-session actions like lock), `agents/{id}/runscript/`
(library script; `output:'wait'|'forget'`), `agents/{id}/reboot/`,
`agents/{id}/meshcentral/` (`control`/`terminal`/`file` URLs = take control).
Installed apps = read HKLM Uninstall keys via `cmd/` (no software endpoint).

**Snipe-IT audits** (`Compare-TrmmToSnipe.ps1` by hostname,
`Compare-TrmmSerialToSnipe.ps1` by serial) dot-source `Common.ps1` for
`Invoke-SnipeRequest`. Serial audit can fix problems: `HostnameMismatch` PATCHes
the Snipe name; `NotInSnipe` matches `make_model` to the closest existing Snipe
model (token overlap, manufacturer words ignored) and POSTs a new asset. Both
confirm first and log via `Write-SnipeAssetLog` (revert source). Serial from the
agent list `serial_number` (detail is blank). These make the TRMM standalone need
`Common.ps1` + `SNIPEIT_TOKEN` (publisher `NeedsCommon=$true`).

## Snipe-IT scripts (scripts\assets\)

Use `Invoke-SnipeRequest`. Snipe returns `{ status='success'|'error' }` even on
HTTP 200 - check `.status`, not the HTTP code. Multi-result search: **R** writes
JSON+HTML report to `output\SnipeReports\`.

Shared in `lib\Common.ps1`: `ConvertFrom-SnipeField` (unwrap Snipe date objects),
`Get-SnipeHardware` (follows the API's limit/offset paging - callers MUST wrap in
`@()`, the function returns a plain array on purpose; a leading-comma return would
nest inside that `@()` and collapse all rows into one), and `Write-SnipeAssetReport`
(the JSON+HTML writer, used by both `Get-SnipeAsset` and `Search-SnipeAssets`).

`Search-SnipeAssets.ps1` sends keyword/status/category/model/company to the API,
then filters LOCATION client-side over both `location.name` and `rtd_location.name` -
Snipe's own `location_id` filter misses RTD-only spares, which is exactly the
"ready to deploy in building X" case.

## Exchange Online scripts (scripts\exchange\)

Every feature starts with `if (-not (Connect-ExoSession)) { return }`.
`Connect-ExoSession` (in `lib\Common.ps1`) checks the ExchangeOnlineManagement
module is installed, reuses a live session via `Get-ConnectionInformation`, else
`Connect-ExchangeOnline` (interactive modern auth; `EXO_ADMIN_UPN` prefills).
Pick recipients with `Find-ExoRecipient -Types <RecipientTypeDetails>` (wraps
`Get-Recipient -ANR` + `Select-FromList`).

Auth is INTERACTIVE by design (a deskside tech signs in as their admin) - no
secret is stored, only the convenience UPN. Feature set, all confirm-gated and
logged via `Write-ActionLog -Action 'Exchange: ...'`: shared mailbox create +
FullAccess/SendAs grant-revoke-list (`Manage-SharedMailbox`), convert user
mailbox to shared for offboarding (`Convert-MailboxToShared` = `Set-Mailbox
-Type Shared`; licence/AD stay with the offboarding tool), distribution-list
membership (`Manage-DistributionGroup`), and forwarding (`Set-MailboxForwarding`,
`ForwardingSmtpAddress` for any address).

Cannot be unit-tested against a live tenant; tests mock the EXO cmdlets. If you
add a feature, mock its cmdlets the same way (`tests\Common.Tests.ps1`,
`Connect-ExoSession` / `Find-ExoRecipient` blocks) and drive the menu with
scripted `Read-Host`.

## Microsoft Graph / M365 licences (lib\Common.ps1)

Licences and users in the M365 admin centre are **Graph**, not Exchange.
`Connect-MgGraphSession` (module `Microsoft.Graph`, reuse `Get-MgContext`, else
`Connect-MgGraph -Scopes User.ReadWrite.All,Organization.Read.All`),
`Get-M365LicenseSku` (resolves E1 = `STANDARDPACK` via `Get-MgSubscribedSku`,
overridable `M365_E1_SKU`, lists tenant SKUs if absent), and `Set-M365UserLicense`
(`Update-MgUser -UsageLocation` then `Set-MgUserLicense` add/remove; usage
location `M365_USAGE_LOCATION`, default `CA`).

Used by onboarding (assign E1 - `New-UserOnboarding` step 4, `Start-BatchOnboarding`
step 5d) and offboarding (`Start-Offboarding` step 4b: convert mailbox to shared
via EXO, THEN remove E1 via Graph - convert while licensed, then drop). Each step
is optional, confirm-gated, and skips cleanly (no mailbox / not licensed /
connect failed). Interactive auth, so it does nothing under SYSTEM. Tests mock the
Graph cmdlets (`Get-MgContext`, `Get-MgSubscribedSku`, `Set-MgUserLicense`,
`Update-MgUser`).

## SharePoint scripts (scripts\sharepoint\)

`Manage-SharePointSite.ps1` starts with `if (-not (Connect-SpoSession)) { return }`.
`Connect-SpoSession` (lib\Common.ps1) uses the **SharePoint Online Management
Shell** (`Microsoft.Online.SharePoint.PowerShell`) - chosen because it runs on
Windows PowerShell 5.1; PnP.PowerShell 2.x needs PS7. It checks the module and
`SPO_ADMIN_URL`, reuses a session (probing with `Get-SPOTenant`), else
`Connect-SPOService -Url <admin>`. `Get-SpoRootUrl` derives the sites host
(`-admin.sharepoint.com` -> `.sharepoint.com`) for building new-site URLs.

Feature: list/search (`Get-SPOSite`), create (`New-SPOSite -Template
SITEPAGEPUBLISHING#0` communication / `STS#0` team, `-Owner` = the user,
`-TimeZone 13` Pacific), remove (`Remove-SPOSite`, typed-YES, recycle bin), and
access (group members via `Get-SPOSiteGroup` + `Add-SPOUser`/`Remove-SPOUser
-Group`, site collection admins via `Set-SPOUser -IsSiteCollectionAdmin`, owner
via `Set-SPOSite -Owner`). All confirm-gated and logged `SharePoint: ...`.
Classic team sites here are NOT group-connected (SPO shell limitation). Tests
mock the SPO cmdlets.

## Logging

`output\AD-Toolkit-Actions.csv` (AD + TRMM actions), `Snipe-Asset-Changes.json`,
`RemoteCleanup-*/RemoteShell-*` transcripts, `SnipeReports\`,
`C:\ProgramData\DeskSideToolkit\ProfileCleanup.log` (on the cleaned machine).

## Standalone editions + Core (Publish-Standalone.ps1)

`$editions` list defines each edition (feature folders, needs-Common, setup
scripts, title). Publisher copies files preserving structure, drops a generic
`Start-Toolkit.ps1` launcher + `toolkit.psd1`, writes `INSTRUCTIONS.txt`.
Core = whole project minus docs. Output to `..\Standalone Editions\` and
`..\Desk Side Tool - Core\`. Re-run after any feature change (no drift). Jira
Console is generated separately (own lib) - sync by hand.

## Sharing + shared-drive auto-update

User-facing steps: `documentation\DEPLOYMENT.md`. Internals:

- **`VERSION`** (root) - UTC `yyyyMMddHHmmss`. Lexical compare == chronological.
  `Publish-ToShare.ps1` stamps it; don't hand-edit.
- **One exclusion rule**: `Test-DeskSidePathExcluded` in `lib\Common.ps1` decides
  what never ships (live `output\`, exported tickets, `data\`, `.git`, `.claude`,
  temp/corrupt). Both build scripts use it - they can't drift.
- **`Build-SharePackage.ps1`** - stages the project (applying the exclusion rule)
  to a temp folder, runs a privacy gate (`Get-DeskSidePrivacyLeak` - aborts if any
  `output\` folder or `My-Completed-Tickets*` file reached staging), then
  `Compress-Archive` to `output\DeskSideToolkit-<version>.zip`. NB PS5.1
  `Compress-Archive` stores backslash separators in the zip - split entries on
  `[\\/]` when inspecting.
- **`Publish-ToShare.ps1`** - same staging + privacy gate, stamps a fresh
  `VERSION`, then `robocopy /MIR staging -> share` with `/XD output data` so any
  logs left by someone running from the share survive. Re-running it IS a release.
- **`Start-DeskSide.ps1`** (+ `.cmd`) - the launcher users run. Dependency-free
  (no `lib\`; it runs before there's anything to sync). Resolves the share
  (`DESKSIDE_SHARE` env / `share.txt` / prompt-and-save), and if the share
  `VERSION` > local `VERSION` (`Test-DeskSideShareNewer`), `robocopy /MIR share ->
  %LOCALAPPDATA%\DeskSideToolkit` with `/XD output data .git .claude` (protects
  the user's own logs), `Unblock-File` the tree (clears MOTW), then launches
  `AD-Toolkit.ps1` from the local copy. Share unreachable -> runs the last local
  copy; no local copy -> runs in place (fresh unzip). `-NoRun` defines its
  functions without launching (used by the tests). robocopy exit code >= 8 is a
  real failure; 0-7 is success, and it resets `$LASTEXITCODE` so a "1 = copied"
  doesn't look like an error to the caller.
- SYSTEM/RMM runs use a different `%LOCALAPPDATA%` and the machine account for the
  share - deploy the admin path via RMM, not the per-user launcher.
- Tests: `Test-DeskSidePathExcluded` and `Test-DeskSideShareNewer` have unit tests
  in `tests\Common.Tests.ps1`; the real robocopy sync is exercised end-to-end
  during development on temp folders.

## Conventions

- Approved verbs (`Get-Verb`). Collection-returning funcs use singular nouns.
- Comment-based help on functions.
- `Write-Host` is intentional (interactive colored UI); data funcs still emit
  objects.
- Confirm destructive/outward actions.
- Quality gate: run `.\Run-Tests.ps1`, which runs Pester **and** PSScriptAnalyzer
  with the project's own settings and should come back "All good." To run just
  the code check: `Invoke-ScriptAnalyzer -Path . -Recurse -Settings
  PSScriptAnalyzerSettings.psd1`. Use the settings file rather than naming rules
  by hand - it turns off four rules, each with a written reason, and a bare
  `-ExcludeRule PSAvoidUsingWriteHost` will report three kinds of false failure.
- Don't add to that exclusion list to silence a new warning. A warning is
  usually telling you something true.
- Every `.ps1` and `.psd1` must be **plain ASCII**. The files have no
  byte-order mark, so PowerShell 5.1 reads them as ANSI and a single em dash
  becomes a curly quote that ends a string early - the file then stops parsing,
  with errors pointing far away from the real cause. A test enforces this.

## PS 5.1 gotchas (hit these already)

- **Sending a script body to an API**: use `[System.IO.File]::ReadAllText()`, not
  `Get-Content -Raw` - the latter tags strings so `ConvertTo-Json` emits
  `{"value":...}` and the API rejects "Not a valid string".
- **`@($list)` does NOT snapshot** a `Generic.List`. Mutating during a `foreach`
  over it throws `Argument types do not match`. Iterate `$list.ToArray()`, defer
  removals.
- **`ConvertFrom-Json` doesn't enumerate**: assign first, then wrap -
  `$x = Get-Content f | ConvertFrom-Json; @($x)` - else a JSON array collapses to
  one item.
- **JQL search index is eventually consistent** (~seconds). After changing a
  ticket, an immediate list re-query can show stale status; refresh/settle-delay
  fixes it.
- **`Invoke-RestMethod` returns a JSON array as ONE object**: emit via a variable
  (`$r = Invoke-RestMethod ...; $r`) to unroll into pipeline items.
- TRMM `runscript` needs the full payload (`run_as_user`, `env_vars`,
  `custom_field`, `save_all_output`, `email`, `emailMode`) or 500. Long runs must
  use `output:'forget'` + poll the machine's log (proxy 502s on held waits).
```
