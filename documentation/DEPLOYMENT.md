# Sharing the toolkit and keeping everyone up to date

This explains, in plain steps, how to give Desk Side Toolkit to other people and
how everyone stays on the latest version without you re-sending anything. No
coding needed - you run one or two scripts.

There are two things you can do:

1. **Hand someone a zip** - a one-time copy.
2. **Set up a shared-drive copy that updates itself** - the good one. Do this
   once and you rarely think about it again.

You can do both. The zip is just a way to get the auto-updating launcher onto a
new machine.

---

## First-time setup on a machine

Whichever way people get the toolkit, the per-machine/per-user settings (URLs,
API tokens, admin addresses) are entered once with **one screen**:

```powershell
.\setup\Setup-DeskSide.ps1
```

It lists every area with its status, **greys out anything that machine can't do**
(a missing module, or a feature not in that edition), and you can **re-run it any
time** to fill in what was skipped. Option `M` installs the optional Microsoft
modules. These settings live per Windows user, so they are not carried by the
auto-update copy - each person runs it once.

## What "a version" means

There is a small file called `VERSION` in the toolkit. It holds a timestamp like
`20260724204705` (a moment in time - year, month, day, hour, minute, second). A
bigger number means newer.

You never edit this file by hand. `Publish-ToShare.ps1` writes it for you every
time you publish. That timestamp is how each person's copy knows whether the
shared drive has something newer than what they have.

---

## The privacy guardrail (important)

Both the zip and the shared-drive publish **leave out** anything with real
information in it:

- `output\` - your action logs, reports, and anything with real hostnames or
  staff names.
- The exported Jira tickets (they contain people's names and issue details).
- `data\` - this machine's own folder settings.
- Behind-the-scenes folders (`.git`, `.claude`).

If any of that ever slipped into a package, the build **stops and refuses** to
make it. So you can share without worrying that you are handing out private data.

---

## Option 1 - Make a zip to give someone

1. Open PowerShell in the toolkit folder.
2. Run:

   ```powershell
   .\Build-SharePackage.ps1
   ```

3. It creates a file like `output\Packages\DeskSideToolkit-20260724204705.zip`
   and tells you where it is.
4. Send that zip to the person. When they unzip it, tell them to run
   `Start-DeskSide.cmd` (double-click). The first time, it asks where the shared
   drive is (see Option 2) - after that it updates itself.

---

## Option 2 - The shared-drive copy that updates itself (recommended)

### One-time: put the master on a shared drive

Pick a folder on a shared drive everyone can reach, for example
`\\fileserver\IT\DeskSideToolkit`. Then, from the toolkit folder, run:

```powershell
.\Publish-ToShare.ps1 -ShareRoot \\fileserver\IT\DeskSideToolkit
```

That copies the toolkit up to the shared drive and stamps a fresh version. This
folder is now "the master" - the copy everyone gets.

### Each person, once

Give each person the folder (or the zip from Option 1) and tell them to run
`Start-DeskSide.cmd`. The first run asks for the shared-drive path - they paste
in `\\fileserver\IT\DeskSideToolkit` and it remembers it forever.

From then on, every time they run `Start-DeskSide.cmd`:

- It checks the shared drive.
- If the master is newer, it quietly copies the new files down to their own PC
  and opens the menu.
- If the shared drive can't be reached (working from home, etc.), it just opens
  the copy they already have. Nobody is ever stuck.

Their own logs stay on their own machine - updating never wipes them.

### When you change something and want everyone to get it

Just publish again:

```powershell
.\Publish-ToShare.ps1
```

(The `-ShareRoot` is remembered, so you can leave it off after the first time.)
The next time each person runs `Start-DeskSide.cmd`, they get your change. No
emails, no zips.

---

## A note on the admin (AD / Microsoft 365 / SharePoint) tools

Those tools are deliberately locked to a **SYSTEM** run - that is, when the
toolkit is launched by the computer itself (through the RMM), not by a person
logging in. A normal person opening the menu sees the Jira, Snipe-IT, and RMM
tools; the AD and 365 tools show up greyed out.

Why this matters for deployment: a SYSTEM run happens under the RMM, which uses a
different per-machine location and its own account to reach the shared drive. So
for the admin tools, the usual way to run them is **through the RMM on the target
machine**, not by double-clicking `Start-DeskSide.cmd` as yourself. The
auto-updating launcher is aimed at the everyday, per-person tools.

---

## Where things live (quick reference)

| Thing | Where |
| ----- | ----- |
| The master everyone pulls from | the shared drive, e.g. `\\fileserver\IT\DeskSideToolkit` |
| Each person's own copy | `%LOCALAPPDATA%\DeskSideToolkit` on their PC |
| The launcher they run | `Start-DeskSide.cmd` (double-click) |
| The shared-drive path they set | remembered in `share.txt` next to the launcher, and in the `DESKSIDE_SHARE` setting |
| The version marker | the `VERSION` file (don't edit by hand) |
