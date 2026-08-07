<#
.SYNOPSIS
    Deletes local Windows user profiles EXCEPT the ones you list to keep.
    Can also clean up disk space (-Cleanup) and run system health checks (-HealthCheck).

.DESCRIPTION
    Give this script a list of usernames to KEEP. Every other normal user
    profile on the machine gets deleted (both the C:\Users folder and the
    registry entry, the same as removing it from Settings > System > About >
    Advanced system settings > User Profiles).

    Built-in safety rails:
      - System/service profiles (SYSTEM, LocalService, etc.) are never touched.
      - Profiles currently loaded (someone logged in) are skipped.
      - The profile of whoever is running the script is always kept.
      - Protected accounts (default 'adm-*', configurable via PROTECTED_ACCOUNTS)
        are ALWAYS kept, even if they are not on your keep list.
      - You see the full delete list and must confirm before anything happens.

    Optional extras:
      -Cleanup      Clears temp folders, the recycle bin, the Windows Update
                    download cache, and old Windows component files (DISM).
      -HealthCheck  Checks the registry for corrupted profile entries (.bak
                    keys, entries pointing to missing folders, orphaned
                    C:\Users folders), then repairs the Windows image
                    (DISM /RestoreHealth) and runs sfc /scannow.
                    The DISM + sfc part takes roughly 15-30 minutes.

.EXAMPLE
    # Preview only - shows what WOULD be deleted, deletes nothing:
    .\Remove-UnlistedProfiles.ps1 -Keep alex.amog, john.smith -WhatIf

.EXAMPLE
    # Read the keep list from a text file of full names (one per line,
    # e.g. "Holly Stout" becomes holly.stout automatically):
    .\Remove-UnlistedProfiles.ps1 -KeepFile .\keep-list.txt -WhatIf

.EXAMPLE
    # Delete profiles, then clean up disk space and run health checks:
    .\Remove-UnlistedProfiles.ps1 -Keep alex.amog, john.smith -Cleanup -HealthCheck

.EXAMPLE
    # Just cleanup + health check, no profile deletion at all:
    .\Remove-UnlistedProfiles.ps1 -Cleanup -HealthCheck

.NOTES
    Must be run from an elevated (Run as administrator) PowerShell window.

    Every action is logged to C:\ProgramData\DeskSideToolkit\ProfileCleanup.log
    on the machine the script runs on (also for remote runs via Tactical RMM).

    KeepFile format - a plain .txt file, one entry per line (commas also work):
        Holly Stout            -> becomes holly.stout
        Kevin Hurtado          -> becomes kevin.hurtado
        adm-alex               -> no spaces, kept exactly as written
        # lines starting with # are ignored (use them for notes)
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    # Usernames to KEEP, e.g. -Keep alex.amog, john.smith
    # If you leave this out, no profiles are deleted (useful with -Cleanup / -HealthCheck).
    [string[]]$Keep,

    # Path to a text file of people to KEEP. Full names like "Holly Stout" are
    # converted to holly.stout; entries without spaces (adm-alex) are used as-is.
    # Can be combined with -Keep; the two lists are merged.
    [string]$KeepFile,

    # Free up disk space: temp folders, recycle bin, Windows Update cache, DISM cleanup.
    [switch]$Cleanup,

    # Repair system files: DISM /RestoreHealth followed by sfc /scannow.
    [switch]$HealthCheck,

    # OPPOSITE MODE: delete ONLY these named profiles and leave everything else
    # alone. Cannot be combined with -Keep / -KeepFile (those mean "delete
    # everything EXCEPT the list").
    [string[]]$DeleteOnly,

    # Skip the "type YES" confirmation. ONLY for remote/automated runs where
    # the operator already reviewed the delete list (e.g. via Tactical RMM,
    # which cannot answer prompts). Never use -Force on a first run.
    [switch]$Force
)

# Allow comma-separated names inside one entry ("a.b,c.d") - needed when the
# list is passed as a single argument by remote tools like Tactical RMM.
if ($Keep) {
    $Keep = @($Keep | ForEach-Object { $_ -split ',' } |
        ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}
if ($DeleteOnly) {
    $DeleteOnly = @($DeleteOnly | ForEach-Object { $_ -split ',' } |
        ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

# The two list modes are opposites - never let both be given.
if ($DeleteOnly -and ($Keep -or $KeepFile)) {
    Write-Host "ERROR: -DeleteOnly (delete ONLY these) cannot be combined with -Keep / -KeepFile (delete everything EXCEPT these)." -ForegroundColor Red
    return
}

# Menu mode: launched with no options at all (e.g. from the AD-Toolkit menu)
# -> ask interactively instead of silently doing nothing.
if (-not $Keep -and -not $KeepFile -and -not $DeleteOnly -and -not $Cleanup -and -not $HealthCheck) {
    $answer = Read-Host "Usernames to KEEP (comma-separated), or the path to a names .txt file (ENTER to skip profile deletion)"
    if ($answer -like '*.txt') { $KeepFile = $answer }
    elseif ($answer) {
        $Keep = @($answer -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    }
    if ((Read-Host "Also run disk cleanup? (y/N)") -eq 'y')                         { $Cleanup = $true }
    if ((Read-Host "Also run health check (DISM + sfc, 15-30 min)? (y/N)") -eq 'y') { $HealthCheck = $true }
    if (-not $Keep -and -not $KeepFile -and -not $Cleanup -and -not $HealthCheck) {
        Write-Host "Nothing selected - exiting." -ForegroundColor Yellow
        return
    }
}

# Load the CIM module up front with -WhatIf temporarily off; otherwise its
# auto-load during a -WhatIf run prints a dozen confusing "Set Alias" lines.
$script:oldWhatIf = $WhatIfPreference
$WhatIfPreference = $false
Import-Module CimCmdlets -ErrorAction SilentlyContinue
$WhatIfPreference = $script:oldWhatIf

# This script is SELF-CONTAINED: it is uploaded to and run on remote machines by
# Tactical RMM, where lib\Common.ps1 does NOT exist. So it must define its own
# helpers and read config straight from environment variables - never call into
# Common.

# Accounts that are NEVER deleted, whatever the keep list says. Default is the
# admin pattern "adm-*"; add exact names or wildcards with the PROTECTED_ACCOUNTS
# environment variable (semicolon- or comma-separated), e.g. "svc-*;breakglass".
$script:ProtectedAccounts = if ($env:PROTECTED_ACCOUNTS) {
    @($env:PROTECTED_ACCOUNTS -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
} else { @('adm-*') }
function Test-ProtectedAccount ($Name) {
    foreach ($p in $script:ProtectedAccounts) { if ($Name -like $p) { return $true } }
    $false
}

# Helper: current free space on C: in GB, for before/after comparison.
function Get-FreeSpaceGB {
    [math]::Round((Get-PSDrive -Name C).Free / 1GB, 2)
}

# Every action is appended to a log ON THE MACHINE THE SCRIPT RUNS ON, so there
# is an audit trail even for remote runs. Neutral product path (override with
# DESKSIDE_PROGRAMDATA); no organisation name baked in.
$script:ProgramData = if ($env:DESKSIDE_PROGRAMDATA) { $env:DESKSIDE_PROGRAMDATA } else { 'C:\ProgramData\DeskSideToolkit' }
$script:LogFile = Join-Path $script:ProgramData 'ProfileCleanup.log'
function Write-CleanupLog ($Message) {
    try {
        # -WhatIf:$false: the log must be written even on -WhatIf preview runs
        # (recording that a preview happened IS part of the audit trail).
        $dir = Split-Path -Path $script:LogFile -Parent
        if (-not (Test-Path -Path $dir)) { New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false | Out-Null }
        "{0}  [{1}]  {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:USERNAME, $Message |
            Add-Content -Path $script:LogFile -Encoding UTF8 -WhatIf:$false
    }
    catch { }   # logging must never break the run itself
}

# ============================================================
# PART 0: Read names from -KeepFile and turn them into usernames
# ============================================================
if ($KeepFile) {
    if (-not (Test-Path -Path $KeepFile)) {
        Write-Host "ERROR: Keep file not found: $KeepFile" -ForegroundColor Red
        return
    }

    Write-Host "Reading keep list from: $KeepFile" -ForegroundColor Cyan

    # Split lines on commas too, trim spaces, drop blanks and # comment lines.
    $rawNames = Get-Content -Path $KeepFile |
        ForEach-Object { $_ -split ',' } |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne '' -and -not $_.StartsWith('#') }

    foreach ($name in $rawNames) {
        $parts = $name -split '\s+'

        if ($parts.Count -eq 1) {
            # No spaces - already a username (adm-alex, nguyen.le), use as-is.
            $username = $name.ToLower()
        }
        else {
            # "First Last" -> first.last (lowercase, SAM style).
            $username = ('{0}.{1}' -f $parts[0], $parts[-1]).ToLower()

            if ($parts.Count -gt 2) {
                # 3+ words is ambiguous (middle names) - flag it for a human check.
                Write-Host ("CHECK  : '{0}' has {1} words - guessed '{2}'. If wrong, put the exact username in the file instead." -f $name, $parts.Count, $username) -ForegroundColor Yellow
            }
        }

        Write-Host ("File   : {0,-30} -> {1}" -f "'$name'", $username)

        if ($Keep -notcontains $username) {
            $Keep += $username
        }
    }
    Write-Host ""
}

Write-CleanupLog ("START Keep=[{0}] KeepFile=[{1}] DeleteOnly=[{2}] Cleanup={3} HealthCheck={4} Force={5} Preview={6}" -f `
    ($Keep -join ','), $KeepFile, ($DeleteOnly -join ','), [bool]$Cleanup, [bool]$HealthCheck, [bool]$Force, [bool]$WhatIfPreference)

# ============================================================
# PART 1b: DELETE-LIST mode - remove ONLY the named profiles.
# This is the OPPOSITE of the keep-list mode below: nothing else is touched.
# ============================================================
if ($DeleteOnly) {
    Write-Host "`n==================================================" -ForegroundColor Magenta
    Write-Host "DELETE-LIST MODE - deleting ONLY the profiles named below." -ForegroundColor Magenta
    Write-Host "Every other profile on this computer is left alone." -ForegroundColor Magenta
    Write-Host "==================================================" -ForegroundColor Magenta

    $allProfiles = Get-CimInstance -ClassName Win32_UserProfile | Where-Object { -not $_.Special }
    $hits = @()
    foreach ($wanted in $DeleteOnly) {
        # Protected accounts are never deleted, whatever the list says.
        if (Test-ProtectedAccount $wanted) {
            Write-Host "PROTECTED : $wanted (skipped - protected account)" -ForegroundColor Yellow
            continue
        }
        if ($wanted -ieq $env:USERNAME) {
            Write-Host "SKIP      : $wanted (that is the account running this script)" -ForegroundColor Yellow
            continue
        }
        $match = @($allProfiles | Where-Object { (Split-Path -Path $_.LocalPath -Leaf) -ieq $wanted })
        if ($match.Count -eq 0) { Write-Host "NOT FOUND : $wanted (no such profile on this computer)" -ForegroundColor DarkGray; continue }
        foreach ($m in $match) {
            if ($m.Loaded) { Write-Host "SKIP      : $wanted (currently logged in - log them off first)" -ForegroundColor Yellow; continue }
            Write-Host "DELETE    : $wanted ($($m.LocalPath))" -ForegroundColor Red
            $hits += $m
        }
    }

    if ($hits.Count -eq 0) {
        Write-Host "`nNothing to delete from the list." -ForegroundColor Green
        Write-CleanupLog "DELETE-LIST: nothing matched"
    }
    elseif ($WhatIfPreference) {
        Write-Host "`n-WhatIf was used: nothing was deleted." -ForegroundColor Yellow
        Write-CleanupLog ("DELETE-LIST PREVIEW - would delete: " + (@($hits | ForEach-Object { Split-Path -Path $_.LocalPath -Leaf }) -join ', '))
    }
    else {
        # Distinct confirmation word so this can't be muscle-memoried from keep mode.
        if ($Force) { Write-Host "`n-Force used: skipping the confirmation." -ForegroundColor Yellow; $ans = 'DELETE LIST' }
        else { $ans = Read-Host "`nType 'DELETE LIST' (in capitals) to delete the $($hits.Count) profile(s) above" }

        if ($ans -cne 'DELETE LIST') {
            Write-Host "Cancelled - nothing was deleted." -ForegroundColor Yellow
            Write-CleanupLog "DELETE-LIST CANCELLED at confirmation"
        }
        else {
            foreach ($userProfile in $hits) {
                $username = Split-Path -Path $userProfile.LocalPath -Leaf
                try {
                    Remove-CimInstance -InputObject $userProfile -ErrorAction Stop
                    Write-Host "Deleted : $username" -ForegroundColor Green
                    Write-CleanupLog "DELETE-LIST deleted profile $username"
                }
                catch {
                    Write-Host "FAILED  : $username - $($_.Exception.Message)" -ForegroundColor Red
                    Write-CleanupLog "DELETE-LIST failed ${username}: $($_.Exception.Message)"
                }
            }
        }
    }
}

# ============================================================
# PART 1: KEEP-LIST mode - delete every profile EXCEPT the list
# ============================================================
if ($Keep) {

    # Always keep the account running this script, so you can't lock yourself out.
    $currentUser = $env:USERNAME
    if ($Keep -notcontains $currentUser) {
        $Keep += $currentUser
        Write-Host "Note: added '$currentUser' (you) to the keep list automatically." -ForegroundColor Yellow
    }

    # Get all real user profiles. 'Special' filters out SYSTEM/service accounts.
    $allProfiles = Get-CimInstance -ClassName Win32_UserProfile |
        Where-Object { -not $_.Special }

    # Work out which profiles are NOT on the keep list.
    # The username is the last part of the folder path (C:\Users\<username>).
    $toDelete = @()
    foreach ($userProfile in $allProfiles) {
        $username = Split-Path -Path $userProfile.LocalPath -Leaf

        # Protected accounts: always kept no matter what the keep list says.
        if (Test-ProtectedAccount $username) {
            Write-Host "KEEP    : $username (protected account)" -ForegroundColor Green
            continue
        }

        if ($Keep -contains $username) {
            Write-Host "KEEP    : $username" -ForegroundColor Green
            continue
        }

        if ($userProfile.Loaded) {
            Write-Host "SKIP    : $username (currently logged in - log them off first)" -ForegroundColor Yellow
            continue
        }

        Write-Host "DELETE  : $username ($($userProfile.LocalPath))" -ForegroundColor Red
        $toDelete += $userProfile
    }

    # --- Keyword cross-check ---------------------------------------------
    # A keep-list entry that matched NO profile might still exist on this
    # machine under a different name (e.g. keep list says kevin.hurtado but
    # the profile is kevin.rutabara). Compare name parts (split on . - _)
    # against the delete list and flag any overlap before confirming.
    $profileNames  = @($allProfiles | ForEach-Object { Split-Path -Path $_.LocalPath -Leaf })
    $unmatchedKeep = @($Keep | Where-Object { $profileNames -notcontains $_ })

    if ($unmatchedKeep.Count -gt 0) {
        Write-Host "`nKeep-list entries that matched no profile on this machine:" -ForegroundColor Yellow
        foreach ($entry in $unmatchedKeep) {
            $entryParts = $entry.ToLower() -split '[.\-_]' | Where-Object { $_.Length -ge 3 }
            $hits = @()
            foreach ($candidate in $toDelete) {
                $delName  = Split-Path -Path $candidate.LocalPath -Leaf
                $delParts = $delName.ToLower() -split '[.\-_]' | Where-Object { $_.Length -ge 3 }
                $common   = @($entryParts | Where-Object { $delParts -contains $_ })
                if ($common.Count -gt 0) {
                    $hits += "'$delName' shares '$($common -join "', '")'"
                }
            }
            if ($hits.Count -gt 0) {
                Write-Host ("  - {0}  <-- CHECK: {1}. Same person with a different name? If so, cancel and add the real username to the keep list." -f $entry, ($hits -join '; ')) -ForegroundColor Red
            }
            else {
                Write-Host "  - $entry (no profile here - they likely never signed in on this machine)" -ForegroundColor Yellow
            }
        }
        # Record which listed names had no matching profile, for the audit log.
        Write-CleanupLog ("KEEP-LIST NOT FOUND ($($unmatchedKeep.Count)): " + ($unmatchedKeep -join ', '))
    }

    if ($toDelete.Count -eq 0) {
        Write-Host "`nNothing to delete." -ForegroundColor Green
    }
    else {
        # --- Final confirmation: show the complete delete list before touching anything ---
        Write-Host "`n==================================================" -ForegroundColor Cyan
        Write-Host "The following $($toDelete.Count) profile(s) will be PERMANENTLY deleted:" -ForegroundColor Cyan
        foreach ($userProfile in $toDelete) {
            Write-Host ("  - {0}  ({1})" -f (Split-Path -Path $userProfile.LocalPath -Leaf), $userProfile.LocalPath) -ForegroundColor Red
        }
        Write-Host "==================================================" -ForegroundColor Cyan

        if ($WhatIfPreference) {
            # -WhatIf was used: this run is preview-only.
            Write-Host "`n-WhatIf was used: nothing was deleted." -ForegroundColor Yellow
            Write-CleanupLog ("PREVIEW - would delete: " + (@($toDelete | ForEach-Object { Split-Path -Path $_.LocalPath -Leaf }) -join ', '))
        }
        else {
            if ($Force) {
                # Remote/automated run - the operator confirmed on their side.
                Write-Host "`n-Force used: skipping the YES prompt." -ForegroundColor Yellow
                $answer = 'YES'
            }
            else {
                # Require the exact word YES so a stray keypress can't trigger deletion.
                $answer = Read-Host "`nType YES (in capitals) to delete these profiles, or anything else to cancel"
            }
            if ($answer -cne 'YES') {
                Write-Host "Cancelled - nothing was deleted." -ForegroundColor Yellow
                Write-CleanupLog "CANCELLED at confirmation - nothing deleted"
            }
            else {
                # User confirmed the full list - delete them all.
                foreach ($userProfile in $toDelete) {
                    $username = Split-Path -Path $userProfile.LocalPath -Leaf
                    try {
                        Remove-CimInstance -InputObject $userProfile -ErrorAction Stop
                        Write-Host "Deleted : $username" -ForegroundColor Green
                        Write-CleanupLog "DELETED profile $username"
                    }
                    catch {
                        Write-Host "FAILED  : $username - $($_.Exception.Message)" -ForegroundColor Red
                        Write-CleanupLog "FAILED deleting profile ${username}: $($_.Exception.Message)"
                    }
                }
            }
        }
    }
}
elseif (-not $DeleteOnly) {
    # Only say this when NEITHER mode ran. -DeleteOnly does its own deleting in
    # PART 1b above, so without the -DeleteOnly test this line used to announce
    # "skipping profile deletion" immediately after profiles had been deleted.
    Write-Host "No -Keep list or -KeepFile given: skipping profile deletion." -ForegroundColor Yellow
}

# ============================================================
# PART 2: Disk space cleanup (-Cleanup)
# ============================================================
if ($Cleanup) {
    if ($WhatIfPreference) {
        Write-Host "`n-WhatIf: skipping disk cleanup (it would clear temp files, recycle bin, update cache)." -ForegroundColor Yellow
    }
    else {
        Write-Host "`n========== DISK CLEANUP ==========" -ForegroundColor Cyan
        $before = Get-FreeSpaceGB
        Write-Host "Free space on C: before cleanup: $before GB"

        Write-Host "Clearing temp folders..."
        Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue

        Write-Host "Emptying the recycle bin..."
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue

        Write-Host "Clearing the Windows Update download cache..."
        Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "C:\Windows\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
        Start-Service -Name wuauserv -ErrorAction SilentlyContinue

        Write-Host "Removing old Windows component files (DISM)... this can take several minutes."
        dism.exe /Online /Cleanup-Image /StartComponentCleanup

        $after = Get-FreeSpaceGB
        Write-Host ("Cleanup done. Free space on C: now {0} GB (freed {1} GB)." -f $after, [math]::Round($after - $before, 2)) -ForegroundColor Green
        Write-CleanupLog ("CLEANUP freed {0} GB (free space {1} GB -> {2} GB)" -f [math]::Round($after - $before, 2), $before, $after)
    }
}

# ============================================================
# PART 3: System health check (-HealthCheck)
# ============================================================
if ($HealthCheck) {

    # --- Registry profile check (read-only, so it runs even with -WhatIf) ---
    Write-Host "`n========== REGISTRY PROFILE CHECK ==========" -ForegroundColor Cyan
    Write-Host "Looking for corrupted or orphaned profile entries..."

    $profileListPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    $issueCount      = 0
    $registryFolders = @()

    foreach ($regKey in Get-ChildItem -Path $profileListPath) {
        $sid       = $regKey.PSChildName
        $imagePath = (Get-ItemProperty -Path $regKey.PSPath -ErrorAction SilentlyContinue).ProfileImagePath

        if ($imagePath) { $registryFolders += $imagePath }

        # Only real user accounts have SIDs starting S-1-5-21. Skip the
        # built-in service accounts (SYSTEM etc.) - their folders live in
        # protected system paths and are not our concern here.
        if ($sid -notlike 'S-1-5-21-*') { continue }

        if ($sid -like '*.bak') {
            # A .bak key means Windows once failed to load this profile and
            # gave the user a temporary profile - the classic corruption sign.
            $issueCount++
            Write-Host "ISSUE  : backup key '$sid' ($imagePath) - user likely got a 'temporary profile' at some point." -ForegroundColor Red
        }
        elseif (-not $imagePath) {
            $issueCount++
            Write-Host "ISSUE  : registry entry '$sid' has no profile folder path - broken entry." -ForegroundColor Red
        }
        elseif (-not (Test-Path -Path $imagePath)) {
            $issueCount++
            Write-Host "ISSUE  : registry entry '$sid' points to a folder that no longer exists: $imagePath" -ForegroundColor Red
        }
    }

    # The reverse problem: a folder in C:\Users that no registry entry claims.
    foreach ($folder in Get-ChildItem -Path 'C:\Users' -Directory) {
        if ($folder.Name -in @('Public', 'Default', 'Default User', 'All Users')) { continue }
        if ($registryFolders -notcontains $folder.FullName) {
            $issueCount++
            Write-Host "ISSUE  : folder $($folder.FullName) has no registry entry (orphaned folder)." -ForegroundColor Red
        }
    }

    Write-CleanupLog "REGISTRY CHECK: $issueCount issue(s) found"
    if ($issueCount -eq 0) {
        Write-Host "No corrupted profile entries found - the registry and C:\Users line up." -ForegroundColor Green
    }
    else {
        Write-Host "`n$issueCount issue(s) found. How to fix:" -ForegroundColor Yellow
        Write-Host "  - '.bak' key or missing folder: log the user off, open regedit, go to"
        Write-Host "    HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList,"
        Write-Host "    right-click the broken key > Export (as a backup), then delete it."
        Write-Host "    The user gets a fresh profile at next sign-in."
        Write-Host "  - Orphaned folder: if the user is gone for good, delete the folder in C:\Users."

        # Flag it for the profile-deletion side too: an orphaned folder will NOT
        # appear in this script's delete list, because Windows no longer tracks it.
        Write-Host "  Note: orphaned folders are invisible to the profile-deletion part of this script." -ForegroundColor Yellow
    }

    if ($WhatIfPreference) {
        Write-Host "`n-WhatIf: skipping the repair steps (they would run DISM /RestoreHealth and sfc /scannow)." -ForegroundColor Yellow
    }
    else {
        Write-Host "`n========== HEALTH CHECK ==========" -ForegroundColor Cyan
        Write-Host "This takes roughly 15-30 minutes. Leave the window open until it finishes." -ForegroundColor Yellow

        # DISM first: it repairs the Windows image that sfc uses as its source,
        # so running it before sfc gives sfc good files to repair from.
        Write-Host "`nStep 1 of 2: Repairing the Windows image (DISM /RestoreHealth)..."
        dism.exe /Online /Cleanup-Image /RestoreHealth

        Write-Host "`nStep 2 of 2: Scanning and repairing system files (sfc /scannow)..."
        sfc.exe /scannow

        Write-Host "`nHealth check finished. If sfc reported problems it could not fix," -ForegroundColor Green
        Write-Host "the details are in C:\Windows\Logs\CBS\CBS.log - or just run this again." -ForegroundColor Green
        Write-CleanupLog "HEALTH CHECK completed (DISM /RestoreHealth + sfc /scannow)"
    }
}

Write-CleanupLog "END"
Write-Host "`nLog: $script:LogFile" -ForegroundColor DarkGray
