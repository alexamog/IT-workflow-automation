<#
.SYNOPSIS
    Find where a user's account lockouts are coming from (by SAM or UPN).

.DESCRIPTION
    Lockout events (ID 4740) are written to the PDC emulator's Security log.
    This shows which source computer triggered each lockout - usually a stale
    cached password on a phone, mapped drive, or service account.

.PARAMETER Identity
    SamAccountName or UPN. If omitted, you'll be prompted.

.PARAMETER Newest
    How many recent lockout events to show (default 10).

.EXAMPLE
    .\Get-LockoutSource.ps1 alex.amog
#>

#Requires -Modules ActiveDirectory
param(
    [string]$Identity,
    [int]$Newest = 10
)

. "$PSScriptRoot\..\..\lib\Common.ps1"

if (-not $Identity) { $Identity = Read-Host "Enter SAM or UPN" }

$user = Resolve-ADToolUser -Identity $Identity -Properties LockedOut
if (-not $user) { return }
$sam = $user.SamAccountName

Write-Host "`nUser     : $($user.Name)  ($sam)" -ForegroundColor Cyan
Write-Host "LockedOut: $($user.LockedOut)"

$pdc = (Get-ADDomain).PDCEmulator
Write-Host "Reading lockout events (4740) from PDC: $pdc ...`n" -ForegroundColor DarkGray

try {
    $events = Get-WinEvent -ComputerName $pdc -FilterHashtable @{ LogName = 'Security'; Id = 4740 } `
                -MaxEvents 200 -ErrorAction Stop
}
catch {
    Write-Host "Could not read events from $pdc : $($_.Exception.Message)" -ForegroundColor Red
    return
}

# 4740: TargetUserName = locked account, TargetDomainName = source computer.
$hits = foreach ($e in $events) {
    $xml  = [xml]$e.ToXml()
    $data = @{}
    foreach ($d in $xml.Event.EventData.Data) { $data[$d.Name] = $d.'#text' }
    if ($data['TargetUserName'] -eq $sam) {
        [PSCustomObject]@{
            Time           = $e.TimeCreated
            LockedAccount  = $data['TargetUserName']
            SourceComputer = $data['TargetDomainName']
        }
    }
}

if (-not $hits) { Write-Host "No lockout events found for $sam on $pdc." -ForegroundColor Yellow; return }

$hits | Select-Object -First $Newest | Format-Table -AutoSize
