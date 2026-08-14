# Jira Service Console

A small menu-driven PowerShell console for Jira Service Management (JSM).
View your tickets, read the conversation, reply to customers, add internal
notes, and pick up unassigned tickets — without leaving the terminal.

> Standalone edition of the Jira console also bundled inside **Desk Side Toolkit**
> (there it lives in `Jira Scripts\` and is launched from the Jira menu). This
> standalone version signs off with a goodbye on quit; the bundled one returns
> to the Desk Side Toolkit menu instead. If a shared feature changes, update both.

## Files

```
Start-JiraConsole.ps1   # Run this. Entry point - loads lib/ then shows the menu.
Set-JiraCredentials.ps1 # Run once to store email, base URL, and API token.
README.md               # This file.
lib/
  Context.ps1      # config (statuses, project) + authentication
  Helpers.ps1      # time formatting, multi-line input, HTML-to-text
  Data.ps1         # read-only ticket fetching (JQL search, single issue)
  Display.ps1      # console rendering (ticket list, comment thread)
  Actions.ps1      # write operations (comment, assign, worklog, close)
  Interaction.ps1  # interactive menus (single ticket, list browser)
```

The code is split by responsibility. `Start-JiraConsole.ps1` dot-sources every
file in `lib/` (which all share one script scope) and wires the functions to a
menu. To change behaviour, edit the relevant file — e.g. the highlighted status
and project key live in the config block at the top of `lib/Context.ps1`.

## One-time setup

1. Open PowerShell in this folder.
2. Store your credentials (token entered hidden, saved as a user environment
   variable — never written into any script file):
   ```powershell
   .\Set-JiraCredentials.ps1
   ```
3. **Close and reopen PowerShell** so the variables load.
4. If scripts are blocked by execution policy, allow scripts to run. Open
   PowerShell **as Administrator** and run one of these once per machine
   (answer `Y` when prompted):
   ```powershell
   Set-ExecutionPolicy RemoteSigned
   ```
   If that still doesn't let the scripts run, use the more permissive setting:
   ```powershell
   Set-ExecutionPolicy Unrestricted
   ```
   `RemoteSigned` is the recommended, safer choice (local scripts run; downloaded
   ones must be signed). To limit the change to just your account without admin,
   append `-Scope CurrentUser`.

## Daily use

```powershell
.\Start-JiraConsole.ps1
```

### Main menu
```
1) My tickets (all open)          every open ticket assigned to you, in one list
2) Unassigned queue               pick up open tickets no one owns
3) Find / search tickets          open one by key, or filter by keyword,
                                   reporter, assignee, status, priority, recency
4) Monthly reports                ticket numbers by site, CSAT, first response
Q) Quit
```

### Ticket list
- Shows **all** your open tickets together (any status).
- **Waiting for support** tickets are shown loud (red highlight + yellow text) so
  they stand out; everything else is calmer green/grey.
- Each row shows priority, reporter, assignee, and the last-updated time with a
  friendly "30 min ago" difference.

### Inside a ticket
Opening a ticket shows its **description** first (the original request text,
rendered to clean text), then the comment thread (activity log), which prints as:
```
[PUBLIC]   [2026-07-02 08:32] (13 min ago) - Alexander Amog : Hi Danya, ...
[INTERNAL] [2026-06-30 09:41] (2 day(s) ago) - Alexander Amog : Reached out to client...
```
Comment bodies are rendered to clean text (HTML/markup stripped, long email
signatures collapsed). Images can't be shown in the terminal, so they're
**flagged instead**: when you open a ticket, a magenta `ATTACHMENTS` block lists
the attached filenames, and inline images in comments are marked
`[inline image - open ticket in browser to view]`. Press `O` to open the ticket
in your browser and see them. (The ticket list stays clean - attachments are
only noted once you're inside a ticket.) Actions:

| Key | Action |
|-----|--------|
| `R` | **Reply to customer** — public comment. Asks for confirmation before sending. |
| `I` | **Internal note** — staff-only, customer cannot see it. |
| `A` | **Assign to me** — takes ownership of the ticket. |
| `C` | **Close** — logs how long it took, then moves the ticket to Done/Resolved. |
| `O` | **Open in browser** — opens the ticket in your default browser. |
| `M` | **ManageEngine** — opens the ManageEngine remote-control console in your browser. |
| `V` | Refresh the ticket + thread. |
| `B` | Back to the list. |

In any ticket **list**, press `R` to refresh the list (re-fetch from Jira), a
number to open a ticket, or `B` to go back.

### Picking up unassigned tickets
Choosing **2) Unassigned queue** lists open tickets no one owns. Selecting a
number opens the **full detail view first** (status, reporter, comment thread) —
nothing is assigned automatically. Assign it to yourself only when you press `A`.

### Closing a ticket
Pressing `C` inside a ticket:
1. Offers the available **Done/Resolved** transitions (auto-selects if there's only one).
2. Asks **how long it took** — this is required. Enter Jira time format:
   `30m`, `1h`, `2h 15m`. A bare number is treated as minutes.
3. Confirms, then **logs the time** and moves the ticket to the chosen Done status.
4. Returns you to the ticket list, which reloads without the just-closed ticket.

When typing a note or reply, enter your text over one or more lines and press
**Enter on an empty line** to finish.

## Monthly reports

Menu option **4** does the two monthly write-ups that used to be done by hand.
Everything is read-only — no ticket is changed. It defaults to **last month**,
which is what both of the old runbooks asked for.

```
1) Ticket numbers by site      (Monthly Ticket Numbers)
2) IT metrics                  (CSAT + first response + phishing)
3) Full pack + export files    (everything, written to output\)
4) Change month                (e.g. 3 = three months ago)
B) Back
```

### 1) Ticket numbers by site
Replaces the whole export-to-Excel-and-build-a-pivot-table routine. It counts
every ticket **created** in the month, drops the ones nobody worked (`Canceled`,
`Closed`), and totals them per Organization — the same table the pivot produced.

Two things the manual version could not tell you, printed underneath:
- how many tickets have **no organization** set, and
- how many had **more than one** organization. Those are counted once, against
  their first one, so the site numbers always add up to the total.

### 2) IT metrics
- **Satisfaction (CSAT)** — average rating, how many surveys came back, the
  spread of 1-5 scores, a per-agent breakdown, and any comments staff left.
- **Time to first response** — the percentage answered inside the 24-hour target
  from the runbook, how many met or breached the Jira SLA, and the median and
  average response time. The median is shown because a single ticket left over a
  weekend badly skews the average.
- **Time to resolution** — how long tickets actually took to finish, how many met
  or breached the resolution SLA, and the five longest-running ones. Answering
  quickly is not the same as finishing quickly, and the old runbooks never
  covered this. July 2026 shows why both numbers are printed: the median was
  0.8 hours but the average was 26.7, because one ticket had been open 103 days.
- **Phishing simulation** — see the note below.

> **Note the two different populations.** First response counts tickets
> **created** in the month ("did we answer the new ones"). Resolution time counts
> tickets **resolved** in the month, because a ticket raised in July and closed in
> August belongs to August's work — and counting by creation date would make the
> most recent month look artificially good while its slow tickets are still open.

### 3) Full pack
Runs everything and writes three files into a folder for that month —
`output\Reports\Monthly\2026-07\` — so each month's report stays together
instead of the files piling up in one long list:

| File | What it is |
|------|-----------|
| `Summary.html` | A formatted summary. **Open it and copy it straight into the monthly report or an email** — it uses inline styling so Outlook and Word keep the formatting when you paste. |
| `Sites.csv` | The tickets-per-site table on its own. |
| `Tickets.csv` | Every ticket that was counted, so any number can be checked. |

### About the phishing numbers

The other two reports come straight out of Jira. The phishing simulation
percentages live in Microsoft Defender, not Jira, so they are the one part that
is not automatic yet. The console will **ask you to type in the two
percentages** (compromised users, reporting users), which you read from
security.microsoft.com exactly as the old runbook describes:

> Email & collaboration > Attack simulation training > Simulations > pick the
> month's simulation.

Press Enter twice to leave the section out entirely.

To make this part automatic as well, two things are needed **once**:

1. Install the Graph module (no admin rights needed):
   ```powershell
   Install-Module Microsoft.Graph -Scope CurrentUser
   ```
2. Ask a Microsoft 365 administrator to consent to the
   **`AttackSimulation.Read.All`** permission for the Microsoft Graph PowerShell
   app.

Once both are done the console pulls the percentages itself and stops asking.
Until then it falls back to the prompt, so the rest of the report still runs
unattended.

## Configuration

Edit the CONFIG block at the top of `lib/Context.ps1`:

| Setting | Meaning |
|---------|---------|
| `$AttentionStatus` | The status that gets the loud red highlight (default `Waiting for support`). |
| `$ProjectKey` | Project scanned for the unassigned queue (default `ITSD`). |

And the CONFIG block at the top of `lib/Reports.ps1`:

| Setting | Meaning |
|---------|---------|
| `$ReportExcludedStatuses` | Statuses left out of the ticket count — tickets nobody worked. Names this Jira does not have are ignored, so listing both `Canceled` and `Cancelled` is safe. |
| `$FirstResponseTargetHours` | The first-response target the report grades against (default `24`). |

## Requirements

- Replying, adding notes, and assigning use the JSM **agent** APIs, so your
  account must be an **agent** on the service desk (not just a customer). A
  `403` when posting/assigning means your account lacks agent permission.

## Security notes

- Your token lives only in your Windows user environment variables, not in any
  script file.
- To rotate the token, run `Set-JiraCredentials.ps1` again.
- Manage/revoke tokens at:
  https://id.atlassian.com/manage-profile/security/api-tokens

## For maintainers / onboarding

- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — how the layers fit together,
  which APIs are used, and where to make common changes.
- Every function has comment-based help: `Get-Help Complete-Ticket -Full` after
  loading the library. Lint with
  `Invoke-ScriptAnalyzer -Path . -Recurse -Settings ..\PSScriptAnalyzerSettings.psd1`
  (use the settings file - it turns off four rules, each for a written reason).
