# Desk Side Toolkit

Menu-driven PowerShell tools for AD, Snipe-IT, Jira, and Tactical RMM: password
resets, lockouts, account state, lookups, OU moves, reporting, asset management,
issue tracking, and remote machine maintenance.

> **Taking this over?** Read `documentation\DEVELOPER-GUIDE.md` (how it fits together, how
> to extend).

## Quick start

```powershell
.\AD-Toolkit.ps1
```

Two-level menu: pick a category, then an option. Scripts also run directly (see
Examples). Most user scripts take a **SAM** (`alex.amog`) or **UPN**
(`alex.amog@contoso.local`).

## Folder layout

| Folder | Contents |
| ------ | -------- |
| `.\` | `AD-Toolkit.ps1` launcher, `Start-DeskSide.ps1`/`.cmd` (auto-updating launcher), `Launch-AdminToolkit.ps1`, `Publish-ToShare.ps1`, `Build-SharePackage.ps1`, `Publish-Standalone.ps1`, `VERSION` |
| `setup\` | `Set-ToolConfig`, `Set-SnipeCredentials`, `Set-TacticalCredentials` |
| `lib\` | `Common.ps1` - shared config + helpers |
| `scripts\` | Task scripts, grouped by category (below) |
| `data\` | Reference data (e.g. `UsersOU-Paths.json`) |
| `output\` | Everything generated: `Logs\`, `Reports\`, `Audits\`, `Packages\` |
| `documentation\` | All written material: `DEVELOPER-GUIDE.md`, `DEPLOYMENT.md`, `API-Examples\` (REST/AD skeletons) |

### scripts\ subfolders

| Subfolder | Scripts |
| --------- | ------- |
| `accounts\` | Reset-UserPassword, Set-UserAccountState, Get-LockoutSource |
| `users\` | Get-UserDetails, Get-UserOUPath, Manage-UserGroups, Move-UserByOUPath |
| `assets\` | Get-SnipeAsset, New-SnipeAssetFromClone |
| `onboarding\` | New-UserOnboarding |
| `reporting\` | Get-DisabledUnmatchedUsers, Get-LockedOutUsers, Group-UnmatchedUsersByOffice |
| `maintenance\` | Get-UsersOUPaths, Convert-UsersOUToReadable, Remove-UnlistedProfiles |
| `remote\` | Start-TrmmConsole (hub), Invoke-RemoteProfileCleanup, Send-TrmmFile, Enter-TrmmShell, Invoke-FleetDiskCleanup |

Launcher auto-discovers features from `*.tool.psd1` manifests (see "Adding a
feature"). **Jira** is a self-contained console in `Jira Scripts\` (own launcher,
`lib\`, docs); its manifest puts it on the menu. **`documentation\API-Examples\`**
holds copy-paste REST/AD skeletons for building new scripts.

## Menu options

### Jira
| Option | Script |
| ------ | ------ |
| Jira Service Console (my/unassigned tickets, find/search, fix/undo orgs) | `Jira Scripts\Start-JiraConsole.ps1` |

### Assets (Snipe-IT)
| Option | Script |
| ------ | ------ |
| Find asset (view, edit, label; press **R** on a multi-result search for a JSON+HTML report to `output\Audits\SnipeReports\`) | `Get-SnipeAsset.ps1` |
| Search assets by filters - keyword + status + location + category + model + company | `Search-SnipeAssets.ps1` |
| Add asset (clone a model) | `New-SnipeAssetFromClone.ps1` |

`Search-SnipeAssets.ps1` answers the "find every asset that is X **and** Y **and**
Z" questions - e.g. spare desktops (`ITDESSPARE`) that are **Ready to Deploy** in
the **Admin building**. Build filters one at a time, run, and export a JSON+HTML
report. Location is matched against both the current AND the default (RTD)
location, so a Ready-to-Deploy spare that has never been checked out - and so has
only a default location - is still found. Read-only; to edit a result, open its
tag in `Get-SnipeAsset.ps1`.

### Onboarding
| Option | Script |
| ------ | ------ |
| Onboard a user (by full name) | `New-UserOnboarding.ps1` |
| Onboard a batch of users (from a list file) | `Start-BatchOnboarding.ps1` |

### Offboarding
| Option | Script |
| ------ | ------ |
| Offboard leavers (one person or a list) | `Start-Offboarding.ps1` |

Offboarding handles a single leaver as well as a list - run it and it asks
which, or use `-Name "Jane Sample"` / `-Path .\leavers.txt`. Either way the
person is found by full name and shown to you before anything is disabled.
(To disable by *username*, or to unlock/enable, use Account Actions instead.)

**Microsoft 365 steps.** Onboarding offers to assign the **Office 365 E1**
licence; offboarding offers, for the accounts it disabled, to **convert the
mailbox to shared and then remove the E1 licence** (in that order - convert
while still licensed, then drop it). These use Microsoft Graph and are each
optional and confirmed; they skip cleanly if the module/connection isn't there,
so the AD parts always run. First use needs the `Microsoft.Graph` module and an
interactive sign-in - run `.\setup\Set-M365Config.ps1` once (sets the usage
location and E1 SKU, and offers to install the module). E1 is assumed to be SKU
`STANDARDPACK` and the usage location `CA`; both are overridable, and the tool
lists your tenant's SKUs if the default isn't found.

Note: Graph/Exchange sign-in is interactive, so these cloud steps do **not** run
when the toolkit is launched as SYSTEM (they connect-fail and skip) - run
onboarding/offboarding from an interactive admin session to use them.

### Batch list files

Run either batch option from the menu and **File Explorer opens so you can pick
the list**. Both read the same kind of plain text file, in either of two
layouts - and a file may mix them.

Name and role on the same line, separated by a comma, a tab, or two or more
spaces (a single space is not a separator, or `Jane Sample` would split in two):

```
Jane Sample, Cas SRW
Robert Example        Cas PEER          Example Residence
```

Or name on one line and role on the next, which is what pasting out of an email
or a Word document gives you. Blank lines and trailing spaces make no
difference:

```
Marcus Fictional

Cas COOK

Aisha Notreal

COOK037
```

Roles are recognised by shape - `Cas SRW`, `Cas PEER`, position codes like
`COOK037` and `JANMAINT046`, and plain words like `Cook` or `Summer Student` -
so a role line is never mistaken for a person and looked up in AD. A line that
looks like a role but has no name above it is reported rather than dropped.

A worked example is in [`documentation\sample-staff-list.txt`](documentation/sample-staff-list.txt).

Neither script changes anything until you have seen the plan and agreed to it.
People whose name is not in AD, whose name matches more than one account, or
(onboarding only) whose role disagrees with AD are never handled automatically -
they go to an exceptions CSV for you to do by hand. Each run writes its files
into its own dated folder: `output\Reports\Onboarding\<date>\Exceptions.csv` (and
`Messages.txt`), or `output\Reports\Offboarding\<date>\`.

### How the role check works

Your list and AD do not spell roles the same way, and are not meant to. The list
uses the payroll short form; AD holds the full job title:

| On the list | In AD |
| ----------- | ----- |
| `Cas SRW` | Shelter Resource Worker |
| `Cas TSW` | Tenant Support Worker |
| `Cas PEER` | Peer |
| `COOK037` | Cook |
| `JANMAINT046` | Janitor/ Maintenance |
| `MCA002` | Medical Care Aid |

There is no list of abbreviations to maintain. The short form is simply built
from the start of each word of the title - **S**helter **R**esource **W**orker,
**Jan**itor/ **Maint**enance - so the check works that relationship out. `Cas`
(the employment type) and the number on a position code are ignored.

The check is deliberately forgiving about closely related titles: `Cas COOK`
is accepted against both `Cook` and `Lead Cook`. Its job is confirming you
matched the right *person*, not auditing HR data. A role belonging to a
genuinely different job - `Cas SRW` against `Tenant Support Worker` - is
rejected, because that usually means the wrong account was matched.

Onboarding checks the AD **Title** field, falling back to **Description**.
Force one with `-RoleField Title`; ignore roles entirely with `-SkipRoleCheck`.

### Exchange Online
| Option | Script |
| ------ | ------ |
| Mailbox access (create shared, add/remove by permission, add ME to investigate) | `Manage-SharedMailbox.ps1` |
| Convert a mailbox to shared (offboarding) | `Convert-MailboxToShared.ps1` |
| Distribution lists (add/remove/list members) | `Manage-DistributionGroup.ps1` |
| Mailbox forwarding (set/clear) | `Set-MailboxForwarding.ps1` |

These use the **ExchangeOnlineManagement** module. First run installs nothing
for you but tells you how (`Install-Module ExchangeOnlineManagement -Scope
CurrentUser`) if it is missing, then opens a Microsoft **sign-in window** - the
auth is interactive, no password is stored. Run `.\setup\Set-ExchangeAdmin.ps1`
once to save your admin address (`EXO_ADMIN_UPN`) so it prefills the sign-in; an
open session is reused so you are not prompted every time. Every change is
confirmed first and written to the action log.

"Full Access" opens and reads a mailbox; "Send As" sends as it; "Send on Behalf"
sends as "you on behalf of it". Add/remove is by permission (or the usual Full
Access + Send As combo), works on shared **and** regular user mailboxes, and
includes a one-tap **Add ME (Full Access) to investigate a mailbox** (e.g. a
leaver's) plus a matching remove - your address defaults to `EXO_ADMIN_UPN`.
Converting a leaver's mailbox to shared keeps the mail and frees the licence; it
does **not** touch AD or the 365 licence (disable the account in Offboarding,
remove the licence in the 365 admin centre).

### SharePoint
| Option | Script |
| ------ | ------ |
| Manage sites (list / create / remove / access) | `Manage-SharePointSite.ps1` |

Create a site **for a user** (they become the owner) - pick a Communication or
Team site, give the title, the `/sites/<address>` part, the owner's email and a
storage quota, and it builds the full URL and creates it. Also lists/searches
sites - and from that list you can **pick a site by number and drop straight into
its access menu** - and removes one (to the recycle bin, ~93 days, typed-`YES`
confirm).

**Access is managed by role.** Pick a site, then add or remove people as **site
admins** (site collection admins), **owners**, **members**, or **visitors** - the
Owners/Members/Visitors group is found for you (by name, or by permission level
if the site was customised). "Show who has access" lists all four. There's also a
one-tap **Add ME as a site admin** (defaults to your `EXO_ADMIN_UPN`) for when you
need to get into a site to investigate, and a matching remove.

Uses the **SharePoint Online Management Shell**
(`Microsoft.Online.SharePoint.PowerShell`), which runs on Windows PowerShell -
the current PnP.PowerShell needs PowerShell 7. Set the tenant admin URL once
(`SPO_ADMIN_URL`, e.g. `https://contoso-admin.sharepoint.com`) with
`.\setup\Set-M365Config.ps1`; sign-in is interactive. A classic Team site here
is **not** group/Teams-connected (the SPO shell can't make those) - create
group-backed sites from the M365 admin centre or Teams.

### Account Actions
| Option | Script |
| ------ | ------ |
| Reset password | `Reset-UserPassword.ps1` |
| Lock / Unlock / Enable | `Set-UserAccountState.ps1` |
| Find lockout source | `Get-LockoutSource.ps1` |

### Lookups & Info
| Option | Script |
| ------ | ------ |
| Full user details (incl. Member Of) | `Get-UserDetails.ps1` |
| Current OU path | `Get-UserOUPath.ps1` |
| View / manage group membership | `Manage-UserGroups.ps1` |
| Move to an OU path | `Move-UserByOUPath.ps1` |

### Reporting
| Option | Script |
| ------ | ------ |
| AD security events (lockouts, resets, changes) over a time range | `Get-ADAuditEvents.ps1` |
| Disabled users (Unmatched Accounts OU) | `Get-DisabledUnmatchedUsers.ps1` |
| Locked-out accounts | `Get-LockedOutUsers.ps1` |
| Group unmatched users by Office | `Group-UnmatchedUsersByOffice.ps1` |

`Get-ADAuditEvents.ps1` turns the DC Security log into a plain "who did what to
whom, and when" table over a time range you pick (last 24h/7d/30d or a custom
window like `48h`, `14d`, or a start date). It covers lockouts, admin password
resets, user password changes, account enable/disable/create/delete/rename, and
group add/remove.

For a **"keeps locking out"** complaint, 4740 (locked out) alone isn't enough -
it's written once per lock and only on the PDC. The events that show every bad
attempt *and where it came from* are the failed sign-ins (4625/4771/4776), each
carrying the source IP or computer. Those are included automatically when you
name a person (`Get-ADAuditEvents.ps1 brittany.harris -Days 7 -AllDcs`), or add
`-IncludeSignInFailures` for the whole domain. They land on whichever DC handled
the attempt, so pair with `-AllDcs`. Password resets likewise can be on any DC -
`-AllDcs` sweeps them too. Read-only; `-Csv` saves the table to `output\`. Needs
rights to read the DC Security log (domain admin, or a SYSTEM run on a DC).

### Remote (Tactical RMM)
| Option | Script |
| ------ | ------ |
| **Machine console** (find a computer/user, then act) | `Start-TrmmConsole.ps1` |
| Printers on a computer: add by IP, remove, or copy to another computer | `Manage-TrmmPrinters.ps1` |
| **Profiles** (find a user's profile / scan for corrupt / repair) | `Manage-TrmmProfiles.ps1` |
| Fleet: scan low disk space, dispatch cleanup (confirm; workstations by default) | `Invoke-FleetDiskCleanup.ps1` |
| Idle logoff (sign off users idle 8h+) | `Invoke-TrmmIdleLogoff.ps1` |
| Audit vs Snipe-IT (missing computers / serial + hostname check) | `Invoke-TrmmSnipeAudit.ps1` |

Two of those are small grouping menus that just launch the underlying scripts,
to keep the list short: **Profiles** covers `Find-TrmmUserProfile.ps1`,
`Find-TrmmCorruptProfile.ps1` and `Repair-TrmmCorruptProfile.ps1`; **Audit vs
Snipe-IT** covers `Compare-TrmmToSnipe.ps1` and `Compare-TrmmSerialToSnipe.ps1`.
Each still runs on its own too.

Hub finds the machine (by hostname or logged-in user), then per-machine actions:

- **Clean up profiles** (preview, confirm, delete; optional cleanup + health check) - `Invoke-RemoteProfileCleanup.ps1`
- **Send file** (SHA256-verified) - `Send-TrmmFile.ps1`
- **Remote PowerShell** (runs as SYSTEM) - `Enter-TrmmShell.ps1`
- **Take control** - MeshCentral remote desktop in browser
- **Restart / Lock / Sleep** (each confirms; lock runs in user session)
- **Printers** (add by IP, remove, or **copy** a printer onto another computer - name + driver + IP; removal needs typed `YES`) - `Manage-TrmmPrinters.ps1`. Copying needs the driver already on the target; ones whose driver is missing there are reported and skipped.

Printers: adding creates a TCP/IP port `IP_<address>` if needed, then attaches
the printer to it. Both are machine-wide, so every user of that PC gets it. The
**driver must already be on the machine** - the script lists what is installed
and you pick one; it cannot fetch a driver. It also cannot set somebody's
*default* printer, because that is a per-user setting and TRMM runs as SYSTEM.
Removing only ever deletes a port you could have created (one with an address);
built-in ports like `LPT1:` are left alone, and a port still used by another
printer is kept.
- **Installed applications** - reads registry uninstall keys; view or save

**"Group Policy Client service failed the sign-in. Access is denied." (or "User
Profile Service failed the sign-in")** - this is almost always a corrupt profile
*registry* entry, not a corrupt *folder*. The user's files are usually fine, so
try `Repair-TrmmCorruptProfile.ps1` FIRST: it backs up the registry, fixes the
entry (renames the `.bak` key back / clears the corrupt State bit) and keeps the
data. The user signs out and back in. Only if it still fails to load after a
clean repair do you delete the profile with `Find-TrmmCorruptProfile.ps1` and
lose the data. Repair skips profiles in use and ones whose folder is already
gone. Note: it fixes the common registry-state corruption, not the rarer broken-
folder-permissions kind.

Action scripts also run standalone (`.\scripts\remote\Enter-TrmmShell.ps1 ITLAPSPARE-11`).
All need `.\setup\Set-TacticalCredentials.ps1` once; the two Snipe-IT audits also
need `SNIPEIT_TOKEN` (they write JSON+HTML to `output\Audits\SnipeAudit\` and log any
Snipe-IT change to `Snipe-Asset-Changes.json`).

### Setup / Maintenance
| Option | Script |
| ------ | ------ |
| Scan regions for "Users" OUs to JSON | `Get-UsersOUPaths.ps1` |
| Build readable navigation reference | `Convert-UsersOUToReadable.ps1` |
| Clean up profiles on THIS computer | `Remove-UnlistedProfiles.ps1` |

## Examples

```powershell
.\scripts\accounts\Reset-UserPassword.ps1 alex.amog          # masked prompt
.\scripts\accounts\Set-UserAccountState.ps1 alex.amog@contoso.local
.\scripts\accounts\Get-LockoutSource.ps1 alex.amog
.\scripts\users\Get-UserDetails.ps1 alex.amog                # incl Member Of
.\scripts\users\Get-UserOUPath.ps1 alex.amog                 # OU path to clipboard
.\scripts\users\Manage-UserGroups.ps1 alex.amog
.\scripts\users\Move-UserByOUPath.ps1 alex.amog

.\scripts\assets\Get-SnipeAsset.ps1 0000001361                    # tag -> card
.\scripts\assets\Get-SnipeAsset.ps1 -Search "E16 Gen 1" -Limit 25 # keyword -> list
.\scripts\assets\New-SnipeAssetFromClone.ps1

.\"Jira Scripts"\Start-JiraConsole.ps1
.\scripts\reporting\Get-DisabledUnmatchedUsers.ps1

# Local profile cleanup (preview first; add -Cleanup / -HealthCheck)
.\scripts\maintenance\Remove-UnlistedProfiles.ps1 -Keep alex.amog, john.smith -WhatIf
.\scripts\maintenance\Remove-UnlistedProfiles.ps1 -KeepFile .\keep-list.txt -Cleanup

# Tactical RMM
.\scripts\remote\Start-TrmmConsole.ps1                            # hub (find, then act)
.\scripts\remote\Invoke-RemoteProfileCleanup.ps1 ITLAPSPARE-11 -Keep alex.amog -Cleanup
.\scripts\remote\Send-TrmmFile.ps1 ITLAPSPARE-11 -Path .\keep-list.txt -Destination C:\Temp\
.\scripts\remote\Enter-TrmmShell.ps1 ITLAPSPARE-11
```

### Working with an asset

1. Enter keyword, tag, or serial.
2. One match = detail card. Several = table (sorted by Name); pick a number, or
   press **R** to report all matches.
3. From an asset: **Edit** (Name/Status/Assigned to/Notes) or **Print label**.
4. **R** writes JSON + HTML (tag, name, model, status, assignee, location,
   serial, dates, notes) to `output\Audits\SnipeReports\`.

## Configuration (environment variables)

**Nothing in the code is organisation-specific** - every org value reads from an
environment variable, and no company name, domain, URL, tenant, or group is baked
in as a fallback. To move the toolkit to another organisation you only set these;
a value left unset either auto-detects (the AD domain) or the feature that needs
it tells you which variable to set. The examples shown in prompts use `contoso`
and are illustrations only.

**One setup screen for all of it:**

```powershell
.\setup\Setup-DeskSide.ps1
```

It lists every area (general settings, Snipe-IT, Tactical RMM, Exchange, M365 /
SharePoint, Jira) with its status - `[configured]` / `[partial]` / `[not set]` -
and **greys out anything you can't do on this machine** (a missing PowerShell
module, or a feature not in this edition), with the reason. Do what you can, skip
the rest, and **re-run it any time to fill in what you left out**; option `M`
installs the optional modules (Exchange / Graph / SharePoint). It just dispatches
to the individual `Set-*` scripts below, so you can still run those directly.

| Variable | Purpose | Secret? |
| -------- | ------- | ------- |
| `SNIPEIT_URL` | Snipe-IT API base URL (e.g. `https://assets.contoso.com/api/v1`) | No |
| `SNIPEIT_TOKEN` | Snipe-IT API token (no "Bearer ") | Yes |
| `TRMM_URL` | TRMM API URL (the `api.` address, NOT the `rmm.` UI) | No |
| `TRMM_APIKEY` | TRMM API key (Settings > Global Settings > API Keys) | Yes |
| `AD_DOMAIN_DN` | AD domain DN. **Blank = auto-detected** from the current domain | No |
| `AD_SOURCE_OU` | "Unmatched Accounts" OU (for the reports) | No |
| `AD_REGIONS` | Region OUs, semicolon-separated | No |
| `ONBOARDING_GROUP` | Group new users join. Blank = skip the group step | No |
| `EMAIL_DOMAIN` | Email domain for the onboarding message. Blank = from the user's UPN | No |
| `ONBOARDING_TEMP_PASSWORD` | Temp password set at onboarding (force-changed next logon) | Yes-ish |
| `SPO_TIMEZONE` | SharePoint site time-zone id (e.g. 13 = Pacific). Blank = you're asked | No |
| `SPO_ADMIN_URL` | SharePoint tenant admin URL (e.g. `https://contoso-admin.sharepoint.com`) | No |
| `EXO_ADMIN_UPN` | Your Exchange/365 admin address (prefills sign-in; "add me" default) | No |
| `PROTECTED_ACCOUNTS` | Profile-cleanup never-delete patterns (`;`/`,`-sep). Default `adm-*` | No |
| `JIRA_PROJECT_KEY` | Jira service-desk project key (default `ITSD`) | No |
| `MANAGEENGINE_URL` | ManageEngine remote-control URL for the Jira `[M]` action. Blank = disabled | No |
| `DESKSIDE_TITLE` | Menu banner title (also settable via `toolkit.psd1`) | No |

Set via helpers (persist per Windows user; open a new window after):

```powershell
.\setup\Set-ToolConfig.ps1            # URL/domain/OUs/regions (ENTER keeps value)
.\setup\Set-SnipeCredentials.ps1      # Snipe-IT token (masked)
.\setup\Set-TacticalCredentials.ps1   # TRMM key + URL (masked; tests connection)
```

Defaults live in the `$ADTool` block in `lib\Common.ps1`. **Jira** has its own
settings (`JIRA_BASEURL`, `JIRA_EMAIL`, `JIRA_API_TOKEN`) via
`.\"Jira Scripts"\Set-JiraCredentials.ps1`.

## Adding a feature

Launcher auto-discovers - you never edit `AD-Toolkit.ps1`. Two files in the
feature's own folder:

1. Script in a `scripts\<category>\` subfolder. If it needs shared helpers:
   ```powershell
   . "$PSScriptRoot\..\..\lib\Common.ps1"
   ```
2. Manifest beside it, same base name + `.tool.psd1`:
   ```powershell
   @{ Category = 'Reporting'; Label = 'Show stale accounts'; Order = 63 }
   ```

Existing `Category` adds to that section; new one makes a section. `Order` sets
position (lower first) and section order. Delete/rename = edit the two files.
The script still runs standalone; the manifest is only read by the launcher.

New external system: add settings to `$ADTool` in `lib\Common.ps1` + a request
wrapper next to `Invoke-SnipeRequest`. Reuse `Select-FromList` and
`Format-Table -AutoSize` to match the look.

## Shared library (`lib\Common.ps1`)

- `Resolve-ADToolUser` - look up by SAM or UPN
- `ConvertTo-LdapEscapedString` - make typed text safe for an LDAP search
- `Get-ADToolDC` - PDC emulator unless `-Server` given
- `Select-FromList` - numbered picker
- `Invoke-SnipeRequest` - Snipe-IT REST wrapper (auth, TLS)
- `Test-TrmmConfigured` / `Invoke-TrmmRequest` / `Invoke-TrmmAgentCommand` - Tactical RMM
- `Get-ADToolOutputDir` / `Get-ADToolDataDir` - file locations
- `Write-ActionLog` (AD + TRMM, CSV) / `Write-SnipeAssetLog` (Snipe, JSON)

## Tests

```powershell
.\Run-Tests.ps1
```

Runs the checks in `tests\` against the shared library, then reads every script
looking for common mistakes. Nothing here touches AD, Snipe-IT, Tactical RMM, or
the network, and no credentials are needed - it is safe to run any time.

Run it after changing `lib\Common.ps1`: if it stays green, the shared parts other
scripts depend on still work. The tests need Pester 5 or newer; the script prints
the one-line install command if the PC only has the old built-in version.

## Audit logs

Everything the toolkit generates is sorted under `output\` by **what the file
is**, so the folder stays readable as it fills up:

```
output\
  Logs\                    appended to forever
    AD-Toolkit-Actions.csv
    Snipe-Asset-Changes.json
    RemoteSessions\        one transcript per remote session
  Reports\                 things you produce, read, and send on
    Monthly\2026-07\       (Jira console writes its own under Jira Scripts\output\)
    Onboarding\<date>\     one folder per run
    Offboarding\<date>\
    AD-Security-Events\  Users-ByOffice\  InstalledApps\  AD-Structure\
  Audits\                  comparisons between two systems
    SnipeReports\  SnipeAudit\
  Packages\                built share packages
```

| File | Contents |
| ---- | -------- |
| `output\Logs\AD-Toolkit-Actions.csv` | AD changes + TRMM actions (cleanups, transfers) |
| `output\Logs\Snipe-Asset-Changes.json` | Asset create/update/checkout/checkin (old/new) |
| `output\Logs\RemoteSessions\RemoteCleanup-<pc>-<date>.log` | Remote profile-cleanup console (preview + run) |
| `output\Logs\RemoteSessions\RemoteShell-<pc>-<date>.log` | Remote PowerShell session transcript |
| `output\Audits\SnipeReports\Asset Report - <date>.json`/`.html` | Snipe asset search reports |
| `output\Audits\SnipeAudit\TRMM-Snipe Audit - <date>.*` / `Serial Audit - <date>.*` | TRMM-vs-Snipe audits (by hostname / by serial) |
| `output\Reports\InstalledApps\<pc> - <date>.txt` | Saved installed-app list from the hub |
| `output\Reports\Onboarding\<date>\` | Per-run onboarding exceptions + messages |
| `output\Reports\Offboarding\<date>\` | Per-run offboarding exceptions + report |
| `C:\ProgramData\DeskSideToolkit\ProfileCleanup.log` | On the cleaned machine: profiles deleted, keep-names not found, GB freed, health-check |

All record timestamp + operator. Failures logged with the error.

Scripts never build these paths by hand â€” they call
`Get-ADToolOutputDir -Category 'Logs'` (or `'Reports\...'`), which creates the
folder on demand. Adding a new output means picking a category, not inventing a
new place.

## Admin credentials

`Launch-AdminToolkit.ps1` (and the shortcut) prompt for your AD admin account and
run the toolkit as it.

## Standalone editions and Core

Standalone tools live in `..\Standalone Editions\` - self-contained, same
auto-discovering launcher (`Start-Toolkit.ps1`), only their features + setup.

**Generated - don't edit by hand.** `Publish-Standalone.ps1` builds them from
this project (no drift): change a feature here, re-run.

```powershell
.\Publish-Standalone.ps1                       # all + Core
.\Publish-Standalone.ps1 -Edition TacticalRMM  # one
.\Publish-Standalone.ps1 -Edition Core
```

- `..\Standalone Editions\Snipe-IT Tool\` - assets. No AD.
- `..\Standalone Editions\Tactical RMM Tool\` - remote cleanup, send, shell, fleet, local cleanup. No AD.
- `..\Desk Side Tool - Core\` - whole runnable project, docs stripped. One folder.

Edit the `$editions` list (or Core exclude list) atop `Publish-Standalone.ps1` to
change. **Jira Console** is in the collection too but has its own `lib\` and is
**not** publisher-generated - sync by hand.

## Sharing & auto-update

Two ways to get the toolkit to other people. Full walkthrough (for a non-coder)
in [`documentation\DEPLOYMENT.md`](documentation/DEPLOYMENT.md).

**A one-off zip.** `Build-SharePackage.ps1` writes a clean
`output\DeskSideToolkit-<version>.zip`. It leaves out everything private or
machine-local (live `output\`, exported Jira tickets, `data\`, `.git`, `.claude`)
and **refuses to build** if any of that reaches the package - so a zip can never
carry staff names, hostnames, or ticket PII. The zip includes the auto-updating
launcher, so whoever unzips it is set up for updates too.

```powershell
.\Build-SharePackage.ps1
```

**Auto-update from a shared drive (recommended).** Put a master copy on a shared
drive; everyone runs `Start-DeskSide.cmd`, which pulls the newest version down to
their own machine before launching:

1. Once, on the master: `.\Publish-ToShare.ps1 -ShareRoot \\server\share\DeskSideToolkit`.
   This stamps a fresh `VERSION` and copies the project up (same privacy rules as
   the zip).
2. Each person runs `Start-DeskSide.cmd`. It finds the share (from the
   `DESKSIDE_SHARE` env var, a `share.txt` beside it, or by asking once), and if
   the share's `VERSION` is newer than their local copy it mirrors the new files
   to `%LOCALAPPDATA%\DeskSideToolkit` (leaving their own logs alone), clears the
   "from another computer" mark, and runs from there.
3. If the share is unreachable it just runs the last local copy - nobody is ever
   stuck offline.

To release a change: run `Publish-ToShare.ps1` again. Everyone picks it up on
their next launch - no re-sending zips.

`VERSION` is a UTC stamp (`yyyyMMddHHmmss`); a bigger stamp means newer.
`Publish-ToShare.ps1` writes it for you - don't hand-edit it.

> Admin (AD / Microsoft) tools are gated to a **SYSTEM** run. A normal login sees
> Jira / Snipe-IT / RMM; the AD/365/SharePoint tools show greyed out. A SYSTEM run
> under RMM reads a different `%LOCALAPPDATA%` and needs the machine account to
> reach the share - for SYSTEM use, deploy via RMM or a machine-readable share.

## Requirements

- RSAT ActiveDirectory module (AD features)
- Rights for the action (password reset, group edit, PDC Security log for lockouts)
- `SNIPEIT_TOKEN` for asset options; `TRMM_*` for remote




