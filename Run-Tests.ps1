<#
.SYNOPSIS
    Run the toolkit's automated checks.

.DESCRIPTION
    Two things happen here:

      1. TESTS      - proves the shared helpers in lib\Common.ps1 still work.
      2. CODE CHECK - reads every script looking for common mistakes.

    Neither touches Active Directory, Snipe-IT, Tactical RMM, or the network,
    and neither needs any credentials. They are safe to run at any time, on any
    PC, as often as you like.

    WHEN TO RUN THIS
    After you change anything in lib\Common.ps1, and before you hand a change
    to someone else. If it is all green, you have not broken the shared parts.

    FIRST TIME: the tests need Pester version 5 or newer. Windows ships with an
    old version 3, which cannot read these tests. If this script says Pester is
    too old, run the one line it prints - no admin rights needed.

.PARAMETER TestsOnly
    Run the tests and skip the code check.

.PARAMETER CheckOnly
    Run the code check and skip the tests.

.EXAMPLE
    .\Run-Tests.ps1
#>

[CmdletBinding()]
param(
    [switch]$TestsOnly,
    [switch]$CheckOnly
)

$failed = $false

# --- 1. Tests ----------------------------------------------------------------
if (-not $CheckOnly) {
    Write-Host "`n=== Tests =====================================================" -ForegroundColor Cyan

    # Pick the newest Pester on this machine and check it is new enough.
    $pester = Get-Module -ListAvailable -Name Pester |
        Sort-Object Version -Descending | Select-Object -First 1

    if (-not $pester -or $pester.Version.Major -lt 5) {
        $found = if ($pester) { "version $($pester.Version)" } else { 'nothing' }
        Write-Host "Cannot run the tests: they need Pester 5 or newer, and I found $found." -ForegroundColor Yellow
        Write-Host "Install it with this single line (no admin rights needed):" -ForegroundColor Yellow
        Write-Host "    Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck" -ForegroundColor White
        Write-Host "Then open a NEW PowerShell window and run this script again." -ForegroundColor Yellow
        $failed = $true
    }
    else {
        Import-Module $pester.Path -Force
        $result = Invoke-Pester -Path (Join-Path $PSScriptRoot 'tests') -Output Detailed -PassThru

        if ($result.FailedCount -gt 0) {
            Write-Host "`n$($result.FailedCount) test(s) FAILED." -ForegroundColor Red
            $failed = $true
        }
        else {
            Write-Host "`nAll $($result.PassedCount) tests passed." -ForegroundColor Green
        }
    }
}

# --- 2. Code check -----------------------------------------------------------
if (-not $TestsOnly) {
    Write-Host "`n=== Code check ================================================" -ForegroundColor Cyan

    if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
        Write-Host "Skipping: PSScriptAnalyzer is not installed. To add it:" -ForegroundColor Yellow
        Write-Host "    Install-Module PSScriptAnalyzer -Scope CurrentUser -Force" -ForegroundColor White
    }
    else {
        Import-Module PSScriptAnalyzer

        # Which rules are switched off, and why, lives in this file.
        $settings = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'
        $findings = @(Invoke-ScriptAnalyzer -Path $PSScriptRoot -Recurse -Settings $settings)

        # The documentation\API-Examples folder holds copy-paste teaching snippets,
        # not toolkit code that ships or runs. Don't hold example code to the same
        # bar as the real thing (e.g. a demo temp-password line).
        $findings = @($findings | Where-Object { $_.ScriptPath -notlike '*\documentation\API-Examples\*' })

        # Errors are worth stopping for. Warnings are worth reading.
        $errors   = @($findings | Where-Object Severity -eq 'Error')
        $warnings = @($findings | Where-Object Severity -ne 'Error')

        if ($findings.Count -eq 0) {
            Write-Host "No findings." -ForegroundColor Green
        }
        else {
            foreach ($f in ($findings | Sort-Object Severity -Descending)) {
                $colour = if ($f.Severity -eq 'Error') { 'Red' } else { 'DarkYellow' }
                Write-Host ("  [{0}] {1}:{2}" -f $f.Severity, $f.ScriptName, $f.Line) -ForegroundColor $colour
                Write-Host ("      {0}" -f $f.Message) -ForegroundColor Gray
            }
            Write-Host "`n$($errors.Count) error(s), $($warnings.Count) warning(s)." -ForegroundColor $(
                if ($errors.Count) { 'Red' } else { 'Yellow' })
        }

        if ($errors.Count -gt 0) { $failed = $true }
    }
}

# --- Result ------------------------------------------------------------------
Write-Host ""
if ($failed) {
    Write-Host "SOMETHING NEEDS ATTENTION - see above." -ForegroundColor Red
    exit 1
}
Write-Host "All good." -ForegroundColor Green
exit 0
