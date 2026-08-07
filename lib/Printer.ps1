<#
    Network printer monitoring/control - SNMP and IPP, talking straight to a
    printer's own IP address (not through Tactical RMM).

    WHY HAND-ROLLED PROTOCOL CODE INSTEAD OF A MODULE
    Windows PowerShell 5.1 has no built-in SNMP or IPP client, and pulling in a
    third-party module means every technician's machine needs it installed
    (and kept current) before this toolkit works. SNMP GET/GETNEXT/SET and an
    IPP Get-Jobs/Cancel-Job request are each a few dozen lines of well-defined
    binary framing (RFC 1157 / RFC 3805 for SNMP+Printer-MIB, RFC 8010/2911 for
    IPP) - small enough to carry here with no dependency at all.

    WHAT THIS TALKS TO
      SNMP (UDP 161, community string, default 'public')
        - toner/drum/waste levels    (Printer-MIB prtMarkerSupplies table)
        - device + printer status    (Host Resources MIB, Printer-MIB)
        - the operator-panel message (Printer-MIB prtConsoleDisplayBuffer)
        - triggering a power-cycle   (Printer-MIB prtGeneralReset, SNMP SET)
      IPP (TCP 631, usually no auth for read/cancel on an office printer)
        - the job queue               (Get-Jobs)
        - cancelling one job          (Cancel-Job)

    prtGeneralReset is a STANDARD Printer-MIB object (RFC 3805), not a Canon
    trick - any printer with a reasonably complete SNMP agent supports it. Most
    devices ship with SNMP SET turned off for security, so a restart attempt
    can legitimately fail; that is reported plainly rather than retried against
    guessed web-interface endpoints. See Restart-CanonPrinter's comment.
#>

# --- Config (env-var driven, same pattern as the rest of Common.ps1) ---------
if (-not $Global:ADTool) { $Global:ADTool = @{} }
$Global:ADTool.Printer = @{
    SnmpCommunity = if ($env:PRINTER_SNMP_COMMUNITY) { $env:PRINTER_SNMP_COMMUNITY } else { 'public' }
    IppPort       = if ($env:PRINTER_IPP_PORT) { [int]$env:PRINTER_IPP_PORT } else { 631 }
    IppPath       = if ($env:PRINTER_IPP_PATH) { $env:PRINTER_IPP_PATH } else { '/ipp/print' }
    # The printer's own Remote UI (plain web page), for the "open web version"
    # menu option - everything config-related stays a manual job done there,
    # by design. Most printers serve it on plain HTTP port 80; PRINTER_WEB_HTTPS
    # switches to https:// for the (less common) devices that require it.
    WebPort       = if ($env:PRINTER_WEB_PORT) { [int]$env:PRINTER_WEB_PORT } else { 80 }
    WebHttps      = [bool]$env:PRINTER_WEB_HTTPS
}

# Builds the printer's Remote UI URL - http(s)://address[:port]/, omitting the
# port when it's the scheme's own default (80 for http, 443 for https) so the
# address printed/opened looks like what a technician would type by hand.
function Get-CanonPrinterWebUrl {
    param([Parameter(Mandatory)][string]$PrinterAddress)
    $scheme = if ($Global:ADTool.Printer.WebHttps) { 'https' } else { 'http' }
    $port = $Global:ADTool.Printer.WebPort
    $defaultPort = if ($scheme -eq 'https') { 443 } else { 80 }
    if ($port -eq $defaultPort) { "${scheme}://${PrinterAddress}/" } else { "${scheme}://${PrinterAddress}:${port}/" }
}

# Standard Printer-MIB / Host Resources MIB OIDs used here. Table entries (the
# supplies) are walked, since the index (".1", ".2", ...) varies per device.
$Script:PrinterOids = @{
    SysDescr        = '1.3.6.1.2.1.1.1.0'
    HrDeviceStatus  = '1.3.6.1.2.1.25.3.2.1.5.1'
    HrPrinterStatus = '1.3.6.1.2.1.25.3.5.1.1.1'
    ConsoleDisplay  = '1.3.6.1.2.1.43.16.5.1.2.1.1'
    SuppliesDescr   = '1.3.6.1.2.1.43.11.1.1.6.1'
    SuppliesLevel   = '1.3.6.1.2.1.43.11.1.1.9.1'
    SuppliesMax     = '1.3.6.1.2.1.43.11.1.1.8.1'
    GeneralReset    = '1.3.6.1.2.1.43.5.1.1.3.1'
}

# ==============================================================================
# BER encoding/decoding (the wire format SNMP uses). Pure functions, no I/O -
# covered by tests\Printer.Tests.ps1.
# ==============================================================================

function ConvertTo-BerLength {
    param([Parameter(Mandatory)][int]$Length)
    if ($Length -lt 0x80) { return [byte[]]@([byte]$Length) }
    $bytes = New-Object System.Collections.Generic.List[byte]
    $v = $Length
    while ($v -gt 0) { $bytes.Insert(0, [byte]($v -band 0xFF)); $v = $v -shr 8 }
    # The leading comma is load-bearing: without it, PowerShell flattens the
    # returned byte[] into the output stream and the caller gets back a
    # generic Object[] instead of a byte[] - which then fails to bind to any
    # later [byte[]] parameter. Every byte[]-returning function below needs
    # the same guard. See tests\Printer.Tests.ps1 for the regression case.
    ,[byte[]](@([byte](0x80 -bor $bytes.Count)) + $bytes.ToArray())
}

function New-BerTlv {
    # AllowEmptyCollection: a NULL value and a zero-length OCTET STRING both
    # legitimately encode to empty content - without this, PowerShell's default
    # "Mandatory array can't be empty" check rejects them before the body runs.
    param([Parameter(Mandatory)][byte]$Tag, [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Content)
    ,[byte[]](@($Tag) + (ConvertTo-BerLength $Content.Count) + $Content)
}

# Minimal two's-complement INTEGER encoding (no redundant sign-extension bytes).
function ConvertTo-BerInteger {
    param([Parameter(Mandatory)][long]$Value)
    if ($Value -eq 0) { return ,[byte[]](New-BerTlv 0x02 ([byte[]]@(0))) }
    $raw = [BitConverter]::GetBytes([int64]$Value)
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($raw) }
    $neg = $Value -lt 0
    $i = 0
    while ($i -lt $raw.Length - 1) {
        if ($neg) { if ($raw[$i] -eq 0xFF -and ($raw[$i + 1] -band 0x80)) { $i++ } else { break } }
        else      { if ($raw[$i] -eq 0x00 -and -not ($raw[$i + 1] -band 0x80)) { $i++ } else { break } }
    }
    ,[byte[]](New-BerTlv 0x02 ([byte[]]$raw[$i..($raw.Length - 1)]))
}

function ConvertFrom-BerInteger {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    if ($Bytes.Count -eq 0) { return 0 }
    $isNeg = ($Bytes[0] -band 0x80) -ne 0
    $val = [System.Numerics.BigInteger]::Zero
    foreach ($b in $Bytes) { $val = ($val -shl 8) -bor $b }
    if ($isNeg) { $val = $val - ([System.Numerics.BigInteger]::One -shl ($Bytes.Count * 8)) }
    $val
}

function ConvertTo-BerOctetString {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    ,[byte[]](New-BerTlv 0x04 $Bytes)
}

function ConvertTo-BerOctetStringFromText {
    param([Parameter(Mandatory)][string]$Text)
    ,[byte[]](ConvertTo-BerOctetString ([System.Text.Encoding]::UTF8.GetBytes($Text)))
}

function New-BerNull { ,[byte[]](New-BerTlv 0x05 ([byte[]]@())) }

# Dotted OID string -> BER OBJECT IDENTIFIER bytes (RFC 1157 encoding: first
# two arcs combined as 40*X+Y, the rest base-128 with the high bit as a
# continuation marker).
function ConvertTo-BerOid {
    param([Parameter(Mandatory)][string]$Oid)
    $parts = $Oid.Trim('.') -split '\.' | ForEach-Object { [long]$_ }
    if ($parts.Count -lt 2) { throw "OID '$Oid' needs at least two components." }
    $bytes = New-Object System.Collections.Generic.List[byte]
    $bytes.Add([byte]($parts[0] * 40 + $parts[1]))
    for ($i = 2; $i -lt $parts.Count; $i++) {
        $n = $parts[$i]
        if ($n -eq 0) { $bytes.Add(0); continue }
        $chunk = New-Object System.Collections.Generic.List[byte]
        while ($n -gt 0) { $chunk.Insert(0, [byte]($n -band 0x7F)); $n = $n -shr 7 }
        for ($j = 0; $j -lt $chunk.Count - 1; $j++) { $chunk[$j] = [byte]($chunk[$j] -bor 0x80) }
        $bytes.AddRange($chunk)
    }
    ,[byte[]](New-BerTlv 0x06 $bytes.ToArray())
}

function ConvertFrom-BerOid {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    if ($Bytes.Count -eq 0) { return '' }
    $first = [int]$Bytes[0]
    $parts = New-Object System.Collections.Generic.List[long]
    $parts.Add([Math]::Floor($first / 40))
    $parts.Add($first % 40)
    $n = [long]0
    for ($i = 1; $i -lt $Bytes.Count; $i++) {
        $b = $Bytes[$i]
        $n = ($n -shl 7) -bor ($b -band 0x7F)
        if (-not ($b -band 0x80)) { $parts.Add($n); $n = 0 }
    }
    ($parts -join '.')
}

# Reads one TLV starting at $Offset. Returns Tag / Content / NextOffset (the
# offset of whatever follows this TLV in $Bytes) - length 0 is handled
# explicitly because a descending PowerShell range (e.g. 5..4) does NOT come
# back empty, it comes back reversed.
function Read-BerTlv {
    param([Parameter(Mandatory)][byte[]]$Bytes, [Parameter(Mandatory)][int]$Offset)
    $tag = $Bytes[$Offset]
    $lenByte = $Bytes[$Offset + 1]
    if ($lenByte -band 0x80) {
        $numLenBytes = $lenByte -band 0x7F
        $len = 0
        for ($i = 0; $i -lt $numLenBytes; $i++) { $len = ($len -shl 8) -bor $Bytes[$Offset + 2 + $i] }
        $contentStart = $Offset + 2 + $numLenBytes
    } else {
        $len = $lenByte
        $contentStart = $Offset + 2
    }
    # NOTE: an if/else used as a value (like this one) flattens an array
    # result exactly like a function return does - same fix, a leading comma
    # on the branch that produces the array.
    $content = if ($len -eq 0) { , [byte[]]@() } else { , [byte[]]$Bytes[$contentStart..($contentStart + $len - 1)] }
    [pscustomobject]@{ Tag = $tag; Content = $content; NextOffset = $contentStart + $len }
}

# ==============================================================================
# SNMP v1 transport - GetRequest / GetNextRequest / SetRequest over UDP.
# ==============================================================================

# Builds one full SNMP message. $VarBinds is an array of @{ Oid = '...';
# ValueTlv = [byte[]] } - ValueTlv is omitted (NULL) for Get/GetNext and
# supplied for Set.
function New-SnmpMessage {
    param(
        [Parameter(Mandatory)][byte]$PduType,
        [Parameter(Mandatory)][string]$Community,
        [Parameter(Mandatory)][array]$VarBinds
    )
    $reqId = Get-Random -Minimum 1 -Maximum 2147483646
    $vbBytes = New-Object System.Collections.Generic.List[byte]
    foreach ($vb in $VarBinds) {
        $oidTlv = ConvertTo-BerOid $vb.Oid
        $valTlv = if ($vb.ContainsKey('ValueTlv') -and $vb.ValueTlv) { $vb.ValueTlv } else { New-BerNull }
        $vbBytes.AddRange((New-BerTlv 0x30 ([byte[]]($oidTlv + $valTlv))))
    }
    $varbindList = New-BerTlv 0x30 $vbBytes.ToArray()
    $pduBody = [byte[]]((ConvertTo-BerInteger $reqId) + (ConvertTo-BerInteger 0) + (ConvertTo-BerInteger 0) + $varbindList)
    $pdu = New-BerTlv $PduType $pduBody
    $msgBody = [byte[]]((ConvertTo-BerInteger 0) + (ConvertTo-BerOctetStringFromText $Community) + $pdu)
    ,[byte[]](New-BerTlv 0x30 $msgBody)
}

function Send-SnmpMessage {
    param(
        [Parameter(Mandatory)][byte[]]$Message,
        [Parameter(Mandatory)][string]$PrinterAddress,
        [int]$Port = 161,
        [int]$TimeoutMs = 2500
    )
    $udp = New-Object System.Net.Sockets.UdpClient
    try {
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $udp.Connect($PrinterAddress, $Port)
        [void]$udp.Send($Message, $Message.Length)
        $remoteEp = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        ,[byte[]]($udp.Receive([ref]$remoteEp))
    }
    finally { $udp.Close() }
}

# Parses a GetResponse message into @{ ErrorStatus; VarBinds = @(@{Oid;Value;Tag}) }.
function ConvertFrom-SnmpResponse {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $top = Read-BerTlv $Bytes 0
    $verTlv = Read-BerTlv $top.Content 0
    $commTlv = Read-BerTlv $top.Content $verTlv.NextOffset
    $pduTlv = Read-BerTlv $top.Content $commTlv.NextOffset

    $reqIdTlv = Read-BerTlv $pduTlv.Content 0
    $errStatusTlv = Read-BerTlv $pduTlv.Content $reqIdTlv.NextOffset
    $errIndexTlv = Read-BerTlv $pduTlv.Content $errStatusTlv.NextOffset
    $vblTlv = Read-BerTlv $pduTlv.Content $errIndexTlv.NextOffset

    $results = New-Object System.Collections.Generic.List[object]
    $o = 0
    while ($o -lt $vblTlv.Content.Count) {
        $vbTlv = Read-BerTlv $vblTlv.Content $o
        $oidTlv = Read-BerTlv $vbTlv.Content 0
        $valTlv = Read-BerTlv $vbTlv.Content $oidTlv.NextOffset
        $oidStr = ConvertFrom-BerOid $oidTlv.Content
        $val = switch ($valTlv.Tag) {
            0x02 { ConvertFrom-BerInteger $valTlv.Content }
            0x04 { [System.Text.Encoding]::UTF8.GetString($valTlv.Content) }
            0x06 { ConvertFrom-BerOid $valTlv.Content }
            0x40 { ($valTlv.Content -join '.') }                       # IpAddress
            { $_ -in 0x41, 0x42, 0x43 } { ConvertFrom-BerInteger $valTlv.Content }  # Counter32/Gauge32/TimeTicks
            default { $null }   # includes v2c-only noSuchObject/noSuchInstance/endOfMibView (0x80/0x81/0x82)
        }
        $results.Add([pscustomobject]@{ Oid = $oidStr; Value = $val; Tag = $valTlv.Tag })
        $o = $vbTlv.NextOffset
    }
    [pscustomobject]@{ ErrorStatus = (ConvertFrom-BerInteger $errStatusTlv.Content); VarBinds = $results.ToArray() }
}

# One SNMP GET. Returns @{Oid;Value;Tag} or $null if unreachable/no answer -
# every caller in this file treats $null as "could not read this value" rather
# than throwing, since a printer being off or SNMP being disabled is routine.
function Get-SnmpValue {
    param(
        [Parameter(Mandatory)][string]$PrinterAddress,
        [Parameter(Mandatory)][string]$Oid,
        [string]$Community = $Global:ADTool.Printer.SnmpCommunity,
        [int]$Port = 161,
        [int]$TimeoutMs = 2500
    )
    try {
        $msg = New-SnmpMessage -PduType 0xA0 -Community $Community -VarBinds @(@{ Oid = $Oid })
        $resp = Send-SnmpMessage -Message $msg -PrinterAddress $PrinterAddress -Port $Port -TimeoutMs $TimeoutMs
        $parsed = ConvertFrom-SnmpResponse $resp
        if ($parsed.VarBinds.Count -ge 1) { return $parsed.VarBinds[0] }
        return $null
    }
    catch { return $null }
}

# Walks a table by repeated GETNEXT starting at $BaseOid, stopping once the
# walk leaves that subtree, stalls (device returns the same OID again - the
# classic SNMPv1 end-of-MIB behaviour), or hits $MaxRows.
function Get-SnmpWalk {
    param(
        [Parameter(Mandatory)][string]$PrinterAddress,
        [Parameter(Mandatory)][string]$BaseOid,
        [string]$Community = $Global:ADTool.Printer.SnmpCommunity,
        [int]$Port = 161,
        [int]$TimeoutMs = 2500,
        [int]$MaxRows = 200
    )
    $results = New-Object System.Collections.Generic.List[object]
    $current = $BaseOid
    for ($i = 0; $i -lt $MaxRows; $i++) {
        try {
            $msg = New-SnmpMessage -PduType 0xA1 -Community $Community -VarBinds @(@{ Oid = $current })
            $resp = Send-SnmpMessage -Message $msg -PrinterAddress $PrinterAddress -Port $Port -TimeoutMs $TimeoutMs
            $parsed = ConvertFrom-SnmpResponse $resp
        }
        catch { break }
        if ($parsed.VarBinds.Count -eq 0) { break }
        $vb = $parsed.VarBinds[0]
        if ($vb.Oid -eq $current) { break }                                  # stalled - no progress
        if ($vb.Oid -ne $BaseOid -and -not $vb.Oid.StartsWith("$BaseOid.")) { break }  # left the subtree
        $results.Add($vb)
        $current = $vb.Oid
    }
    $results.ToArray()
}

# One SNMP SET of a single integer value. Used only for the restart trigger -
# nothing in this toolkit sets any other object (config changes stay manual,
# by design).
function Set-SnmpIntegerValue {
    param(
        [Parameter(Mandatory)][string]$PrinterAddress,
        [Parameter(Mandatory)][string]$Oid,
        [Parameter(Mandatory)][int]$Value,
        [string]$Community = $Global:ADTool.Printer.SnmpCommunity,
        [int]$Port = 161,
        [int]$TimeoutMs = 3000
    )
    $msg = New-SnmpMessage -PduType 0xA3 -Community $Community -VarBinds @(@{ Oid = $Oid; ValueTlv = (ConvertTo-BerInteger $Value) })
    $resp = Send-SnmpMessage -Message $msg -PrinterAddress $PrinterAddress -Port $Port -TimeoutMs $TimeoutMs
    $parsed = ConvertFrom-SnmpResponse $resp
    [pscustomobject]@{ Ok = ($parsed.ErrorStatus -eq 0); ErrorStatus = $parsed.ErrorStatus }
}

# ==============================================================================
# High-level printer status (SNMP)
# ==============================================================================

# Reads toner/drum levels, device + printer status, and the operator-panel
# message text. Returns $null if the printer did not answer SNMP at all
# (off, unplugged from the network, or SNMP disabled) - callers should treat
# that as "can't reach it", not as an empty/healthy result.
function Get-CanonPrinterStatus {
    param(
        [Parameter(Mandatory)][string]$PrinterAddress,
        [string]$Community = $Global:ADTool.Printer.SnmpCommunity,
        [int]$TimeoutMs = 3000
    )
    $o = $Script:PrinterOids
    $descr = Get-SnmpValue -PrinterAddress $PrinterAddress -Oid $o.SysDescr -Community $Community -TimeoutMs $TimeoutMs
    if (-not $descr -or $null -eq $descr.Value) { return $null }

    $devStatusMap = @{ 1 = 'Unknown'; 2 = 'Running'; 3 = 'Warning'; 4 = 'Testing'; 5 = 'Down' }
    $prnStatusMap = @{ 1 = 'Other'; 2 = 'Unknown'; 3 = 'Idle'; 4 = 'Printing'; 5 = 'Warming up' }

    $ds = Get-SnmpValue -PrinterAddress $PrinterAddress -Oid $o.HrDeviceStatus  -Community $Community -TimeoutMs $TimeoutMs
    $ps = Get-SnmpValue -PrinterAddress $PrinterAddress -Oid $o.HrPrinterStatus -Community $Community -TimeoutMs $TimeoutMs
    $msg = Get-SnmpValue -PrinterAddress $PrinterAddress -Oid $o.ConsoleDisplay  -Community $Community -TimeoutMs $TimeoutMs

    $descrRows = Get-SnmpWalk -PrinterAddress $PrinterAddress -BaseOid $o.SuppliesDescr -Community $Community -TimeoutMs $TimeoutMs
    $levelRows = Get-SnmpWalk -PrinterAddress $PrinterAddress -BaseOid $o.SuppliesLevel -Community $Community -TimeoutMs $TimeoutMs
    $maxRows   = Get-SnmpWalk -PrinterAddress $PrinterAddress -BaseOid $o.SuppliesMax   -Community $Community -TimeoutMs $TimeoutMs

    # Rows are index-matched by the OID's final component (the table row
    # index) rather than by position - a walk can legitimately skip an index.
    $lastPart = { param($oid) ($oid -split '\.')[-1] }
    $levelByIdx = @{}; foreach ($r in $levelRows) { $levelByIdx[(& $lastPart $r.Oid)] = $r.Value }
    $maxByIdx   = @{}; foreach ($r in $maxRows)   { $maxByIdx[(& $lastPart $r.Oid)]   = $r.Value }

    $supplies = foreach ($r in $descrRows) {
        $idx = & $lastPart $r.Oid
        $level = $levelByIdx[$idx]
        $max   = $maxByIdx[$idx]
        $pct = $null
        if ($null -ne $level -and $null -ne $max -and [int64]$max -gt 0 -and [int64]$level -ge 0) {
            $pct = [Math]::Round(([int64]$level / [int64]$max) * 100)
        }
        # RFC 3805 special level values: -1 not-used-here, -2 unknown, -3
        # "some remains" with no numeric measure available.
        $note = switch ([int64]($level | ForEach-Object { if ($null -eq $_) { -99 } else { $_ } })) {
            -1 { 'not applicable'; break }
            -2 { 'level unknown'; break }
            -3 { 'some remaining, exact level unknown'; break }
            default { $null }
        }
        [pscustomobject]@{ Name = [string]$r.Value; Level = $level; Max = $max; Percent = $pct; Note = $note }
    }

    [pscustomobject]@{
        Address        = $PrinterAddress
        SysDescr       = [string]$descr.Value
        DeviceStatus   = if ($ds) { $devStatusMap[[int]$ds.Value] } else { $null }
        PrinterStatus  = if ($ps) { $prnStatusMap[[int]$ps.Value] } else { $null }
        ConsoleMessage = if ($msg -and $msg.Value) { ([string]$msg.Value).Trim() } else { $null }
        Supplies       = @($supplies)
    }
}

# Triggers a power-cycle restart via the standard Printer-MIB prtGeneralReset
# object (value 2 = powerCycleReset). This needs SNMP SET/write access, which
# most printers disable by default for security - a rejected or unanswered
# SET is expected on a device that has not had it turned on, and is reported
# as such rather than silently retried against guessed web-UI endpoints.
function Restart-CanonPrinter {
    param(
        [Parameter(Mandatory)][string]$PrinterAddress,
        [string]$Community = $Global:ADTool.Printer.SnmpCommunity,
        [int]$TimeoutMs = 4000
    )
    try {
        $r = Set-SnmpIntegerValue -PrinterAddress $PrinterAddress -Oid $Script:PrinterOids.GeneralReset -Value 2 `
            -Community $Community -TimeoutMs $TimeoutMs
    }
    catch { return [pscustomobject]@{ Ok = $false; Reason = "no response from the printer: $($_.Exception.Message)" } }

    if ($r.Ok) { return [pscustomobject]@{ Ok = $true; Reason = 'restart command accepted' } }
    [pscustomobject]@{
        Ok     = $false
        Reason = "the printer rejected the SNMP write (error status $($r.ErrorStatus)) - SNMP write access is " +
                 "probably switched off. Open the printer's Remote UI and restart it from Management > Device."
    }
}

# ==============================================================================
# IPP - job queue + cancel. TCP/HTTP, no BER involved.
# ==============================================================================

function ConvertTo-IppInt16Bytes { param([int]$Value) $b = [BitConverter]::GetBytes([int16]$Value); if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($b) }; ,[byte[]]$b }
function ConvertTo-IppInt32Bytes { param([int]$Value) $b = [BitConverter]::GetBytes([int32]$Value); if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($b) }; ,[byte[]]$b }

# Writes a multi-valued keyword attribute (e.g. requested-attributes): the
# first value carries the name, every value after it repeats with a
# zero-length name - that repeat-with-no-name form is how IPP encodes
# "more values for the previous attribute" (see ConvertFrom-IppResponse's
# parsing of job-state-reasons for the read side of the same rule).
function Write-IppMultiValue {
    param([Parameter(Mandatory)]$Writer, [Parameter(Mandatory)][byte]$Tag, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string[]]$Values)
    for ($i = 0; $i -lt $Values.Count; $i++) {
        $thisName = if ($i -eq 0) { $Name } else { '' }
        Write-IppAttribute $Writer $Tag $thisName $Values[$i]
    }
}

# Writes one IPP attribute: tag, name-length+name, value-length+value.
# -Raw treats $Value as already-encoded bytes (used for integers); otherwise
# it is written as UTF-8 text (keywords, uris, names).
function Write-IppAttribute {
    # AllowEmptyString: a zero-length name is the valid, meaningful IPP wire
    # form for "another value of the previous attribute" - see
    # Write-IppMultiValue, which relies on this for multi-valued attributes.
    param([Parameter(Mandatory)]$Writer, [Parameter(Mandatory)][byte]$Tag, [Parameter(Mandatory)][AllowEmptyString()][string]$Name, $Value, [switch]$Raw)
    $nameBytes = [System.Text.Encoding]::ASCII.GetBytes($Name)
    $Writer.Write($Tag)
    $Writer.Write([byte[]](ConvertTo-IppInt16Bytes $nameBytes.Length))
    $Writer.Write($nameBytes)
    # Leading comma on each branch: see the note in Read-BerTlv - an if/else
    # used as a value flattens an array result just like a function return.
    $valBytes = if ($Raw) { , [byte[]]$Value } else { , [byte[]]([System.Text.Encoding]::UTF8.GetBytes([string]$Value)) }
    $Writer.Write([byte[]](ConvertTo-IppInt16Bytes $valBytes.Length))
    $Writer.Write($valBytes)
}

function New-IppRequestBytes {
    param(
        [Parameter(Mandatory)][int]$OperationId,
        [Parameter(Mandatory)][string]$PrinterUri,
        [Parameter(Mandatory)][scriptblock]$AddExtraAttributes,  # { param($w) ... } - operation-specific attrs
        [int]$RequestId = (Get-Random -Minimum 1 -Maximum 2000000000)
    )
    $ms = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter($ms)
    $w.Write([byte[]]@(0x01, 0x01))                                    # IPP version 1.1
    $w.Write([byte[]](ConvertTo-IppInt16Bytes $OperationId))
    $w.Write([byte[]](ConvertTo-IppInt32Bytes $RequestId))
    $w.Write([byte]0x01)                                                # operation-attributes-tag
    Write-IppAttribute $w 0x47 'attributes-charset' 'utf-8'
    Write-IppAttribute $w 0x48 'attributes-natural-language' 'en'
    Write-IppAttribute $w 0x45 'printer-uri' $PrinterUri
    Write-IppAttribute $w 0x42 'requesting-user-name' $env:USERNAME
    & $AddExtraAttributes $w
    $w.Write([byte]0x03)                                                # end-of-attributes-tag
    $w.Flush()
    ,[byte[]]$ms.ToArray()
}

function Send-IppRequest {
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][byte[]]$Body, [int]$TimeoutSec = 8)
    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    $client = New-Object System.Net.Http.HttpClient
    try {
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
        $content = New-Object System.Net.Http.ByteArrayContent (, $Body)
        $content.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue('application/ipp')
        $resp = $client.PostAsync($Url, $content).GetAwaiter().GetResult()
        ,[byte[]]($resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult())
    }
    finally { $client.Dispose() }
}

# Parses an IPP response into a status code plus one ordered hashtable per
# "group" the response contains (one per job for Get-Jobs; a single group for
# most other operations). Multi-valued attributes (repeated name-less entries)
# are collected into an array under the same key.
function ConvertFrom-IppResponse {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $status = ([int]$Bytes[2] -shl 8) -bor $Bytes[3]
    $groups = New-Object System.Collections.Generic.List[object]
    $current = $null
    $lastName = $null
    $pos = 8   # version(2) + status(2) + request-id(4)
    while ($pos -lt $Bytes.Count) {
        $tag = $Bytes[$pos]; $pos++
        if ($tag -le 0x0F) {
            if ($current) { $groups.Add([pscustomobject]$current) }
            if ($tag -eq 0x03) { $current = $null; break }
            $current = [ordered]@{}
            $lastName = $null
            continue
        }
        $nameLen = ([int]$Bytes[$pos] -shl 8) -bor $Bytes[$pos + 1]; $pos += 2
        $name = if ($nameLen -gt 0) { [System.Text.Encoding]::ASCII.GetString($Bytes, $pos, $nameLen) } else { $null }
        $pos += $nameLen
        $valLen = ([int]$Bytes[$pos] -shl 8) -bor $Bytes[$pos + 1]; $pos += 2
        $valBytes = if ($valLen -eq 0) { , [byte[]]@() } else { , [byte[]]$Bytes[$pos..($pos + $valLen - 1)] }
        $pos += $valLen

        $val = switch ($tag) {
            { $_ -in 0x21, 0x23 } {                             # integer / enum
                $b = $valBytes; $v = 0; foreach ($x in $b) { $v = ($v -shl 8) -bor $x }
                if ($b.Count -gt 0 -and ($b[0] -band 0x80)) { $v = $v - ([int64]1 -shl ($b.Count * 8)) }
                $v; break
            }
            0x22 { $valBytes.Count -gt 0 -and $valBytes[0] -ne 0; break }   # boolean
            default { [System.Text.Encoding]::UTF8.GetString($valBytes) }  # keyword/text/name/uri/charset/language
        }

        if (-not $current) { continue }
        if ($name) {
            $current[$name] = $val
            $lastName = $name
        }
        elseif ($lastName) {
            # Additional value for a multi-valued attribute (e.g. job-state-reasons).
            $existing = $current[$lastName]
            $current[$lastName] = @(@($existing) + $val)
        }
    }
    if ($current) { $groups.Add([pscustomobject]$current) }
    [pscustomobject]@{ Status = $status; Groups = $groups.ToArray() }
}

function Format-IppStatus {
    param([int]$Status)
    switch ($Status) {
        0x0000 { 'successful-ok'; break }
        0x0001 { 'successful-ok (with ignored/unsupported attributes)'; break }
        0x0401 { 'forbidden'; break }
        0x0402 { 'not authenticated'; break }
        0x0403 { 'not authorized'; break }
        0x0404 { 'not possible'; break }
        0x0405 { 'timeout'; break }
        0x0406 { 'job/target not found'; break }
        0x0500 { 'server error'; break }
        0x0501 { 'operation not supported'; break }
        0x0502 { 'not accepting jobs'; break }
        default { '0x{0:X4}' -f $Status }
    }
}

function Get-CanonPrinterIppUri {
    param([Parameter(Mandatory)][string]$PrinterAddress)
    $port = $Global:ADTool.Printer.IppPort
    $path = $Global:ADTool.Printer.IppPath
    [pscustomobject]@{
        Ipp  = "ipp://${PrinterAddress}:${port}${path}"
        Http = "http://${PrinterAddress}:${port}${path}"
    }
}

# Lists jobs on the printer. -Which controls which set:
#   Active    (default) - pending/processing/held, i.e. the live queue
#   Completed            - job history: finished, canceled, or aborted jobs
#   All                   - both, in one call (two IPP requests, merged)
# History depth/retention is entirely up to the printer - some keep the last
# few dozen jobs, some keep very little. This asks for whatever it has; it
# does not (and cannot) promise a full history.
function Get-CanonPrinterJobs {
    param(
        [Parameter(Mandatory)][string]$PrinterAddress,
        [ValidateSet('Active', 'Completed', 'All')][string]$Which = 'Active',
        [int]$Limit = 100,
        [int]$TimeoutSec = 8
    )
    if ($Which -eq 'All') {
        $active = @(Get-CanonPrinterJobs -PrinterAddress $PrinterAddress -Which Active -Limit $Limit -TimeoutSec $TimeoutSec)
        $done   = @(Get-CanonPrinterJobs -PrinterAddress $PrinterAddress -Which Completed -Limit $Limit -TimeoutSec $TimeoutSec)
        return @($active + $done)
    }

    $whichJobsValue = if ($Which -eq 'Completed') { 'completed' } else { 'not-completed' }
    $uris = Get-CanonPrinterIppUri $PrinterAddress
    $req = New-IppRequestBytes -OperationId 0x000A -PrinterUri $uris.Ipp -AddExtraAttributes {
        param($w)
        Write-IppAttribute $w 0x44 'which-jobs' $whichJobsValue
        Write-IppAttribute $w 0x21 'limit' ([byte[]](ConvertTo-IppInt32Bytes $Limit)) -Raw
        Write-IppMultiValue $w 0x44 'requested-attributes' @(
            'job-id', 'job-name', 'job-originating-user-name', 'job-state', 'job-state-reasons', 'time-at-completed'
        )
    }
    $resp = Send-IppRequest -Url $uris.Http -Body $req -TimeoutSec $TimeoutSec
    $parsed = ConvertFrom-IppResponse $resp
    if ($parsed.Status -ge 0x0400) { throw "printer returned IPP status $(Format-IppStatus $parsed.Status)" }

    $stateMap = @{ 3 = 'Pending'; 4 = 'Held'; 5 = 'Processing'; 6 = 'Stopped'; 7 = 'Canceled'; 8 = 'Aborted'; 9 = 'Completed' }
    $epoch = [datetime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
    foreach ($g in $parsed.Groups) {
        if (-not $g.'job-id') { continue }
        # time-at-completed is seconds since the epoch, and 0 (or absent) on a
        # job that has not finished yet - only show a real timestamp when the
        # printer actually gave us a positive value.
        $completedAt = $null
        if ($g.'time-at-completed' -and [int64]$g.'time-at-completed' -gt 0) {
            $completedAt = $epoch.AddSeconds([int64]$g.'time-at-completed').ToLocalTime()
        }
        [pscustomobject]@{
            JobId        = [int]$g.'job-id'
            Name         = $g.'job-name'
            User         = $g.'job-originating-user-name'
            State        = if ($g.'job-state') { $stateMap[[int]$g.'job-state'] } else { $null }
            StateReasons = @($g.'job-state-reasons')
            CompletedAt  = $completedAt
        }
    }
}

# Cancels one job by ID (as shown by Get-CanonPrinterJobs).
function Stop-CanonPrinterJob {
    param([Parameter(Mandatory)][string]$PrinterAddress, [Parameter(Mandatory)][int]$JobId, [int]$TimeoutSec = 8)
    $uris = Get-CanonPrinterIppUri $PrinterAddress
    $req = New-IppRequestBytes -OperationId 0x0008 -PrinterUri $uris.Ipp -AddExtraAttributes {
        param($w)
        Write-IppAttribute $w 0x21 'job-id' ([byte[]](ConvertTo-IppInt32Bytes $JobId)) -Raw
    }
    $resp = Send-IppRequest -Url $uris.Http -Body $req -TimeoutSec $TimeoutSec
    $parsed = ConvertFrom-IppResponse $resp
    [pscustomobject]@{ Ok = ($parsed.Status -lt 0x0400); Status = (Format-IppStatus $parsed.Status) }
}

# ==============================================================================
# Network discovery - find IP printers on a subnet.
#
# There is no broadcast "who are the printers" query on a routed network (SNMP
# broadcast discovery only works on the local segment, and most sites route
# between VLANs), so this works the only reliable way that does: probe every
# address in a range for the ports printers actually listen on
# (9100 = raw/JetDirect printing, 631 = IPP), then ask SNMP who answered. A
# host that has 9100 or 631 open almost always IS a printer or print server -
# ordinary workstations/servers don't listen there - but SNMP sysDescr is
# still used to label it with an actual make/model when the device allows it.
# ==============================================================================

# Expands "10.10.4.0/24" into every usable host address in it. Pure function -
# no network I/O - which is what makes it something a test can check exactly.
function ConvertTo-DeskSideIpRange {
    param([Parameter(Mandatory)][string]$Cidr)
    if ($Cidr -notmatch '^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/(\d{1,2})$') {
        throw "'$Cidr' does not look like a CIDR range, e.g. 10.10.4.0/24."
    }
    $prefix = [int]$Matches[2]
    if ($prefix -lt 16 -or $prefix -gt 32) {
        throw "Prefix /$prefix is out of range - use /16 (65k hosts) through /32 (one host). Anything wider than /16 is too big to scan from a laptop."
    }

    $ipBytes = [System.Net.IPAddress]::Parse($Matches[1]).GetAddressBytes()
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($ipBytes) }
    $ipUInt = [BitConverter]::ToUInt32($ipBytes, 0)

    $hostBits = 32 - $prefix
    $maskUInt = if ($hostBits -eq 0) { [uint32]::MaxValue } else { [uint32]::MaxValue -shl $hostBits }
    $networkUInt = $ipUInt -band $maskUInt
    $hostCount = [uint64]1 -shl $hostBits

    # /31 and /32 have no network/broadcast address to exclude (RFC 3021 /
    # a single host) - every address in range is usable. Everything wider
    # excludes the first (network) and last (broadcast) address.
    $first = if ($hostBits -le 1) { [uint64]0 } else { [uint64]1 }
    $last  = if ($hostBits -le 1) { $hostCount - 1 } else { $hostCount - 2 }

    $addresses = New-Object System.Collections.Generic.List[string]
    for ($i = $first; $i -le $last; $i++) {
        $bytes = [BitConverter]::GetBytes([uint32]($networkUInt + $i))
        if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($bytes) }
        $addresses.Add(([System.Net.IPAddress]$bytes).ToString())
    }
    # NOTE: no leading comma here, unlike the byte[] helpers above. Those need
    # one to stop PowerShell flattening an opaque blob of bytes; this function
    # means to hand back N independent address strings, and flattening is
    # exactly the normal, correct behaviour for that - callers collect them
    # with @(...) the same way Get-CanonPrinterJobs's caller does. A comma
    # here breaks piping the result straight into another command (it arrives
    # as one nested array instead of N strings) - see the regression test.
    $addresses.ToArray()
}

# The local machine's own IPv4 subnets, as CIDR strings, offered as a scan
# default so the technician doesn't have to look up the subnet by hand. Best
# effort: returns nothing (never throws) on a machine without the NetTCPIP
# module, or with no suitable adapter up.
function Get-DeskSideLocalIPv4Cidr {
    try {
        @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object {
                $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' -and
                $_.PrefixLength -ge 16 -and $_.PrefixLength -lt 32
            } |
            ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" } |
            Select-Object -Unique)
    }
    catch { @() }
}

# Probes every address in $Addresses for $Ports, in batches (so a /16 doesn't
# open 65,000+ sockets at once), then asks SNMP sysDescr of whatever answered.
# A host with 9100 or 631 open is reported even if it never answers SNMP -
# that alone is a strong signal it's a printer/print server - SysDescr is
# just extra detail when the device shares it.
function Find-NetworkPrinter {
    param(
        [Parameter(Mandatory)][string[]]$Addresses,
        [int[]]$Ports = @(9100, 631),
        [int]$TimeoutMs = 600,
        [int]$BatchSize = 256,
        [scriptblock]$OnProgress   # invoked with (addressesScannedSoFar, totalAddresses) after each batch
    )
    $openPortsByHost = [ordered]@{}

    for ($start = 0; $start -lt $Addresses.Count; $start += $BatchSize) {
        $end = [Math]::Min($start + $BatchSize, $Addresses.Count) - 1
        $batch = $Addresses[$start..$end]

        # Kick off every connect in the batch first (near-instant - BeginConnect
        # just starts the TCP handshake in the background), THEN wait on them
        # one at a time. By the time a later socket's wait handle is checked,
        # its connect attempt has usually already succeeded or failed in the
        # background, so the real wall-clock cost is close to one $TimeoutMs
        # per batch, not one per socket.
        $pending = New-Object System.Collections.Generic.List[object]
        foreach ($ip in $batch) {
            foreach ($port in $Ports) {
                $tcp = New-Object System.Net.Sockets.TcpClient
                try { $pending.Add([pscustomobject]@{ Ip = $ip; Port = $port; Client = $tcp; Async = $tcp.BeginConnect($ip, $port, $null, $null) }) }
                catch { try { $tcp.Close() } catch { } }
            }
        }
        foreach ($p in $pending) {
            $connected = $false
            try { $connected = $p.Async.AsyncWaitHandle.WaitOne($TimeoutMs) -and $p.Client.Connected }
            catch { $connected = $false }
            if ($connected) {
                if (-not $openPortsByHost.Contains($p.Ip)) { $openPortsByHost[$p.Ip] = New-Object System.Collections.Generic.List[int] }
                $openPortsByHost[$p.Ip].Add($p.Port)
            }
            try { $p.Client.Close() } catch { }
        }

        if ($OnProgress) { & $OnProgress ($end + 1) $Addresses.Count }
    }

    foreach ($ip in $openPortsByHost.Keys) {
        $descr = Get-SnmpValue -PrinterAddress $ip -Oid $Script:PrinterOids.SysDescr -TimeoutMs 1200
        $hostname = $null
        try { $hostname = ([System.Net.Dns]::GetHostEntry($ip)).HostName } catch { }
        [pscustomobject]@{
            IPAddress = $ip
            Ports     = @($openPortsByHost[$ip] | Sort-Object -Unique)
            SysDescr  = if ($descr -and $descr.Value) { [string]$descr.Value } else { $null }
            Hostname  = $hostname
        }
    }
}

# The best available label for one Find-NetworkPrinter result: its SNMP
# sysDescr if it gave one, otherwise its reverse-DNS hostname, otherwise a
# plain note that it was found by open port alone.
function Get-NetworkPrinterLabel {
    param([Parameter(Mandatory)]$Result)
    if ($Result.SysDescr) { return $Result.SysDescr }
    if ($Result.Hostname) { return $Result.Hostname }
    '(no SNMP reply - identified by open port only)'
}

# One tab-separated report line for a Find-NetworkPrinter result - shared by
# the console listing and the saved .txt file so they can never drift apart.
function ConvertTo-NetworkPrinterScanLine {
    param([Parameter(Mandatory)]$Result)
    "{0}`tports={1}`t{2}" -f $Result.IPAddress, ($Result.Ports -join ','), (Get-NetworkPrinterLabel $Result)
}
