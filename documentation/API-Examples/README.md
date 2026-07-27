# API Examples

Minimal **skeleton functions** for the REST calls (and AD operations) the Desk Side
Desk Side toolkit uses. Reference material: copy one out as the start of a new
script, or run them to see how each API behaves.

Each file is a tiny wrapper (`Jira` / `Snipe`) plus one short function per call, so
the request is easy to read. They read credentials from environment variables and
do not depend on the toolkit's `lib\`.

## Files

| File | System | Functions |
| ---- | ------ | --------- |
| [`Jira-RestExamples.ps1`](Jira-RestExamples.ps1) | Jira Cloud + JSM (REST) | `Get-Myself`, `Get-FieldId`, `Search-Issues`, `Get-Issue`, `Add-Comment`, `Set-Assignee`, `Get-Organizations`, `Set-Organization` |
| [`SnipeIT-RestExamples.ps1`](SnipeIT-RestExamples.ps1) | Snipe-IT v1 (REST) | `Find-Asset`, `Get-AssetByTag`, `Get-List`, `New-Asset`, `Edit-Asset`, `Checkout-Asset`, `Checkin-Asset` |
| [`ActiveDirectory-Examples.ps1`](ActiveDirectory-Examples.ps1) | Active Directory (module) | `Find-User`, `Get-LockedOut`, `Reset-Password`, `Unlock-User`, `Enable-User`, `Disable-User`, `Add-ToGroup`, `Move-User` |
| [`TacticalRMM-RestExamples.ps1`](TacticalRMM-RestExamples.ps1) | Tactical RMM (REST) | `Get-TrmmClients`, `Get-TrmmAgents`, `Find-TrmmAgent`, `Get-TrmmAgent`, `Invoke-TrmmCommand`, `Get-TrmmScripts`, `Invoke-TrmmScript`, `Restart-TrmmAgent` |

## How to use

1. Set the environment variables for the system (see each file's header):
   - **Jira**: `JIRA_BASEURL`, `JIRA_EMAIL`, `JIRA_API_TOKEN`
   - **Snipe-IT**: `SNIPEIT_TOKEN` (raw, no `Bearer `), optional `SNIPEIT_URL`
   - **AD**: RSAT `ActiveDirectory` module + directory rights
   - **Tactical RMM**: `TRMM_APIKEY`, `TRMM_URL` (run `..\..\setup\Set-TacticalCredentials.ps1`)
2. Dot-source the file (nothing runs on load):
   ```powershell
   . .\Jira-RestExamples.ps1
   Get-Myself
   Search-Issues 'project = ITSD AND statusCategory != Done'
   ```
   Each file ends with a commented `--- examples ---` block.

## Good to know

- **Secrets come from environment variables**, never hard-coded.
- **Snipe-IT returns `{ status = 'success'|'error' }` even on HTTP 200** - check
  `.status`, don't trust the HTTP code alone.
- **Jira's real error message** is in `$_.ErrorDetails.Message`, not
  `$_.Exception.Message` (which is just "(400) Bad Request").
- **JQL paging** uses `nextPageToken` (loop until empty); the **organizations list**
  caps at **50 per page**.
- **Setting the Organizations field** has a payload shape that varies by Jira
  deployment - the example uses the Cloud shape; the toolkit's `Set-OrgFieldValue`
  (`..\Jira Scripts\lib\Actions.ps1`) tries several.

> Reference scripts. The production versions (logging, retries, the interactive UI)
> live in `..\lib\`, `..\scripts\`, and `..\Jira Scripts\`.
