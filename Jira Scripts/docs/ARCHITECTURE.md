# Architecture

This document is for whoever maintains or takes over the Jira Service Console.
It explains how the pieces fit together so you can change things safely.

## What this tool is

A single-user, menu-driven PowerShell console for Jira Service Management (JSM).
It runs in a terminal and talks to Jira's Cloud REST APIs over HTTPS. There is no
database, no server, and no build step - it's plain `.ps1` files you run directly.

## Layered design

The code is split into layers. Each layer only depends on the ones below it, so a
change in one place has a predictable blast radius.

```
Start-JiraConsole.ps1        (entry point: loads lib/, shows the main menu)
        |
   lib/Interaction.ps1       lib/Reports.ps1   (UI flow / monthly reporting pack)
        |            \            |
   lib/Display.ps1    lib/Actions.ps1     (render tickets / change tickets)
        |            /
   lib/Data.ps1                            (read-only fetching via JQL + issue GET)
        |
   lib/Helpers.ps1                         (pure utilities: time, text, formatting)
        |
   lib/Context.ps1                         (config + auth; sets the shared context)
```

- **Context** - configuration (`$script:AttentionStatus`, `$script:ProjectKey`)
  and `Initialize-JiraContext`, which authenticates and stores the shared
  `$script:BaseUrl`, `$script:Headers`, `$script:MyAccountId`.
- **Helpers** - pure functions with no API calls: `Get-TimeAgo`,
  `ConvertTo-TicketJql`, `Sort-TicketForDisplay`, `Format-Cell`,
  `Read-MultiLine`, `Convert-HtmlToText`, `Get-AdfText`,
  `Get-TicketKeywordOrg`, and the two Jira error readers. Easiest place to test.
- **Data** - read-only: `Get-IssueByJql`, `Get-MyTicket`, `Get-UnassignedTicket`,
  `Get-Ticket`. Never modifies a ticket.
- **Display** - console rendering: `Show-TicketList` (the aligned table) and
  `Show-TicketComment` (the activity log).
- **Actions** - writes: `Add-JiraComment`, `Set-TicketAssignedToMe`,
  `Add-TicketWorklog`, `Complete-Ticket`.
- **Interaction** - the interactive glue: `Enter-Ticket` (single-ticket menu),
  `Invoke-TicketLookup`, `Invoke-TicketBrowser` (list browser).
- **Reports** - the monthly reporting pack (`Invoke-MonthlyReports`). Sits beside
  Interaction rather than under it: it is its own menu, and it only ever reads.
  Splits into `Get-*Report` functions that return plain objects, `Show-*Report`
  functions that print them, and `Export-MonthlyReport` which writes the files.
  Keeping "work out the numbers" separate from "print the numbers" is what lets
  the tests check the maths without a console or a network.

### Custom fields in the reports

The reports need three fields that are **not** part of core Jira: Organizations,
Satisfaction, and the Time to first response SLA. Their ids (`customfield_10025`
and friends) are assigned per Jira site, so they are **never hard-coded**.
`Initialize-JiraContext` caches the full field list in `$script:AllFields`, and
`Get-JiraFieldId -Name 'Satisfaction'` looks an id up by the name shown in the
Jira UI. A site that does not have a field gets `$null` back, and the report
skips that metric instead of failing.

> **Watch out.** Do not write `$script:AllFields = @(Invoke-RestMethod ...)`.
> Under PowerShell 5.1 that wraps the `object[]` the call already returns inside
> a *second* array, so `AllFields` ends up holding one element containing all 170
> fields. Every lookup then returns every id at once, those get pasted into the
> `fields=` query string, Jira ignores them, and the report comes back empty with
> no error anywhere. Assign first, then copy the items across in a loop.
> `tests\Reports.Tests.ps1` has a test pinning this down.

## How the files share state

`Start-JiraConsole.ps1` **dot-sources** every file in `lib/`:

```powershell
. (Join-Path $PSScriptRoot "lib\Context.ps1")
```

Dot-sourcing runs each file in the caller's scope, so all functions and all
`$script:` variables live in one shared scope. That's why `Get-Ticket` in
Data.ps1 can use `$script:Headers` that `Initialize-JiraContext` set in
Context.ps1. If you add a new file, add it to the `$libFiles` list in the entry
point.

## Authentication

Jira Cloud uses HTTP Basic auth: `email:api_token`, Base64-encoded, in the
`Authorization` header. Credentials are read from environment variables
(`JIRA_EMAIL`, `JIRA_BASEURL`, `JIRA_API_TOKEN`) that `Set-JiraCredentials.ps1`
stores once. Secrets are never written into the script files.

## APIs used

| Purpose            | Endpoint                                              |
|--------------------|-------------------------------------------------------|
| Who am I           | `GET  /rest/api/3/myself`                             |
| Search tickets     | `GET  /rest/api/3/search/jql`                         |
| One ticket         | `GET  /rest/api/3/issue/{key}`                        |
| Comments (read)    | `GET  /rest/api/3/issue/{key}/comment?expand=renderedBody` |
| Comment (write)    | `POST /rest/servicedeskapi/request/{key}/comment`     |
| Assign             | `PUT  /rest/api/3/issue/{key}/assignee`               |
| Log work           | `POST /rest/api/3/issue/{key}/worklog`                |
| Transitions        | `GET/POST /rest/api/3/issue/{key}/transitions`        |
| Field ids by name  | `GET  /rest/api/3/field`                              |
| Project statuses   | `GET  /rest/api/3/project/{key}/statuses`             |
| Phishing results   | `GET  https://graph.microsoft.com/beta/security/attackSimulation/simulations` |

The last row is Microsoft Graph, not Jira, and is the only optional one: it needs
the `Microsoft.Graph` module plus admin consent for `AttackSimulation.Read.All`.
Without it the phishing section falls back to asking the operator for the two
percentages. See the README for the one-time setup.

Note the split: **reading** comments uses the core API (clean rendered HTML +
the `jsdPublic` flag), while **writing** comments uses the Service Desk API
(the only one that separates a public reply from an internal note).

## Conventions

- **Approved verbs.** Function names use approved PowerShell verbs
  (`Get`, `Set`, `Show`, `Add`, `Invoke`, `Complete`, ...). Run `Get-Verb` to see
  the list. Collection-returning functions use singular nouns (`Get-MyTicket`),
  matching built-ins like `Get-Process`.
- **Comment-based help.** Every function has `.SYNOPSIS` / `.PARAMETER` /
  `.OUTPUTS`. Try `Get-Help Complete-Ticket -Full` after loading the library.
- **`Write-Host` is intentional.** This is an interactive, colorized UI, so
  `Write-Host` is the right tool. Functions that return *data* still emit objects
  to the pipeline; `Write-Host` is only for messages to the human.
- **Confirm destructive/outward actions.** Public replies and closing a ticket
  prompt for confirmation before calling the API.

## Quality gate

Lint with PSScriptAnalyzer before committing:

```powershell
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ..\..\PSScriptAnalyzerSettings.psd1
```

`PSAvoidUsingWriteHost` is excluded on purpose (see above). The tree should
otherwise come back clean.

## Where to make common changes

| I want to...                        | Edit...                                   |
|-------------------------------------|-------------------------------------------|
| Change which status glows red       | `$script:AttentionStatus` in Context.ps1  |
| Point at a different project        | `$script:ProjectKey` in Context.ps1       |
| Change the queue's JQL              | `Get-*Ticket` in Data.ps1                 |
| Add/remove a table column           | `Show-TicketList` in Display.ps1          |
| Add a per-ticket action             | `Enter-Ticket` switch in Interaction.ps1  |
| Add a main-menu option              | the `switch` in Start-JiraConsole.ps1     |
| Add a new API write                 | a new function in Actions.ps1             |

