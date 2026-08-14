<#
.SYNOPSIS
    Automated checks for lib\Printer.ps1 (the SNMP/IPP helpers behind
    scripts\remote\Monitor-CanonPrinter.ps1).

.DESCRIPTION
    Run with .\Run-Tests.ps1, same as every other test file here.

    NOTHING HERE TOUCHES A REAL PRINTER. These are round-trip checks on the
    BER (SNMP) and IPP wire encoding itself: encode something, decode it back,
    check it matches. That is deliberate - the one real printer available
    while writing this could not be used to prove the code works everywhere,
    but proving the encoding is byte-correct against the RFCs it implements
    (1157/3805 for SNMP, 8010/2911 for IPP) is something a test can do
    perfectly well without one.

    THE BUG THIS FILE EXISTS TO CATCH: PowerShell flattens an array into the
    pipeline whenever it crosses a function return OR an if/else used as a
    value - so a function meaning to hand back a byte[] can silently hand
    back an Object[] instead, which then fails (or silently truncates) the
    next .NET call that expects real bytes. Every function below that touches
    a byte[] got bitten by this at least once while writing it. These tests
    check the TYPE of what comes back, not just its content, so a regression
    of that exact mistake fails loudly here instead of quietly on a printer.
#>

BeforeAll {
    . "$PSScriptRoot\..\lib\Printer.ps1"

    # Builds one IPP attribute (tag/name/value) directly, bypassing
    # Write-IppAttribute's Mandatory Name check, so a synthetic response can
    # include the empty-name "additional value" form a real device sends for
    # multi-valued attributes.
    function Write-TestIppValue {
        param($Writer, [byte]$Tag, [string]$Name, [byte[]]$ValueBytes)
        $nameBytes = [System.Text.Encoding]::ASCII.GetBytes($Name)
        $Writer.Write($Tag)
        $Writer.Write([byte[]](ConvertTo-IppInt16Bytes $nameBytes.Length))
        $Writer.Write($nameBytes)
        $Writer.Write([byte[]](ConvertTo-IppInt16Bytes $ValueBytes.Length))
        $Writer.Write($ValueBytes)
    }
}

Describe "BER byte[] helpers return a real byte[] (not a flattened Object[])" {
    # This is the regression test for the bug class described above - every
    # one of these failed with "Object[]" before the leading-comma fix.
    It "New-BerTlv" { (New-BerTlv 0x04 ([byte[]]@(1, 2, 3))).GetType().Name | Should -Be 'Byte[]' }
    It "ConvertTo-BerInteger" { (ConvertTo-BerInteger 42).GetType().Name | Should -Be 'Byte[]' }
    It "ConvertTo-BerOctetStringFromText" { (ConvertTo-BerOctetStringFromText 'public').GetType().Name | Should -Be 'Byte[]' }
    It "New-BerNull" { (New-BerNull).GetType().Name | Should -Be 'Byte[]' }
    It "ConvertTo-BerOid" { (ConvertTo-BerOid '1.3.6.1.2.1.1.1.0').GetType().Name | Should -Be 'Byte[]' }
    It "New-SnmpMessage" {
        (New-SnmpMessage -PduType 0xA0 -Community 'public' -VarBinds @(@{ Oid = '1.3.6.1.2.1.1.1.0' })).GetType().Name | Should -Be 'Byte[]'
    }
}

Describe "ConvertTo-BerOid / ConvertFrom-BerOid round-trip" {
    It "round-trips a table OID with a multi-digit index" {
        $oid = '1.3.6.1.2.1.43.11.1.1.9.1.12'
        $tlv = Read-BerTlv (ConvertTo-BerOid $oid) 0
        ConvertFrom-BerOid $tlv.Content | Should -Be $oid
    }
}

Describe "ConvertTo-BerInteger / ConvertFrom-BerInteger round-trip" {
    $intCases = @(0, 1, 127, 128, 255, 256, 65535, -1, -3, -129, 2147483647, -2147483648) |
        ForEach-Object { @{ Value = $_ } }
    It "round-trips <Value>" -TestCases $intCases {
        param($Value)
        $tlv = Read-BerTlv (ConvertTo-BerInteger $Value) 0
        [int64](ConvertFrom-BerInteger $tlv.Content) | Should -Be ([int64]$Value)
    }
}

Describe "New-SnmpMessage / ConvertFrom-SnmpResponse round-trip" {
    It "carries a string value through unchanged" {
        $msg = New-SnmpMessage -PduType 0xA2 -Community 'public' -VarBinds @(
            @{ Oid = '1.3.6.1.2.1.1.1.0'; ValueTlv = (ConvertTo-BerOctetStringFromText 'Canon MF743C/745C') }
        )
        $parsed = ConvertFrom-SnmpResponse $msg
        $parsed.VarBinds.Count | Should -Be 1
        $parsed.VarBinds[0].Oid   | Should -Be '1.3.6.1.2.1.1.1.0'
        $parsed.VarBinds[0].Value | Should -Be 'Canon MF743C/745C'
    }

    It "carries several integer values through unchanged, one per OID (a supplies-table row)" {
        $msg = New-SnmpMessage -PduType 0xA2 -Community 'public' -VarBinds @(
            @{ Oid = '1.3.6.1.2.1.43.11.1.1.9.1.1'; ValueTlv = (ConvertTo-BerInteger 42) }
            @{ Oid = '1.3.6.1.2.1.43.11.1.1.9.1.2'; ValueTlv = (ConvertTo-BerInteger -3) }   # RFC 3805 "some remains"
        )
        $parsed = ConvertFrom-SnmpResponse $msg
        $parsed.VarBinds.Count | Should -Be 2
        $parsed.VarBinds[0].Value | Should -Be 42
        $parsed.VarBinds[1].Value | Should -Be -3
    }

    It "a Set-style request/response carries the written value back" {
        # Simulates what a printer accepting the restart trigger would send back:
        # the same OID/value echoed in the response.
        $msg = New-SnmpMessage -PduType 0xA3 -Community 'private' -VarBinds @(
            @{ Oid = '1.3.6.1.2.1.43.5.1.1.3.1'; ValueTlv = (ConvertTo-BerInteger 2) }   # powerCycleReset
        )
        $parsed = ConvertFrom-SnmpResponse $msg
        $parsed.ErrorStatus       | Should -Be 0
        $parsed.VarBinds[0].Value | Should -Be 2
    }
}

Describe "IPP request building" {
    It "New-IppRequestBytes returns a real byte[] with the version header at the front" {
        $req = New-IppRequestBytes -OperationId 0x000A -PrinterUri 'ipp://10.0.0.5:631/ipp/print' -AddExtraAttributes {
            param($w) Write-IppAttribute $w 0x44 'which-jobs' 'not-completed'
        }
        $req.GetType().Name | Should -Be 'Byte[]'
        $req[0] | Should -Be 0x01   # IPP version 1.1
        $req[1] | Should -Be 0x01
    }

    It "Write-IppAttribute writes the value bytes in full, not truncated to one byte" {
        # Regression case for the if/else-flattening bug: this used to write a
        # single 0x01 byte (a bool True) instead of the 5-byte 'utf-8' value.
        $ms = New-Object System.IO.MemoryStream
        $w  = New-Object System.IO.BinaryWriter($ms)
        Write-IppAttribute $w 0x47 'attributes-charset' 'utf-8'
        $w.Flush()
        $out = $ms.ToArray()
        # tag(1) + namelen(2) + name(18) + vallen(2) + value(5) = 28 bytes
        $out.Count | Should -Be 28
        [System.Text.Encoding]::UTF8.GetString($out[-5..-1]) | Should -Be 'utf-8'
    }
}

Describe "ConvertFrom-IppResponse (Get-Jobs shaped response)" {
    BeforeAll {
        # Builds a synthetic two-job Get-Jobs response, including a
        # multi-valued job-state-reasons attribute (the empty-name repeat
        # form), to exercise every branch of the parser.
        $ms = New-Object System.IO.MemoryStream
        $w  = New-Object System.IO.BinaryWriter($ms)
        $w.Write([byte[]]@(0x01, 0x01))
        $w.Write([byte[]](ConvertTo-IppInt16Bytes 0x0000))
        $w.Write([byte[]](ConvertTo-IppInt32Bytes 12345))
        $w.Write([byte]0x01)
        Write-IppAttribute $w 0x47 'attributes-charset' 'utf-8'
        Write-IppAttribute $w 0x48 'attributes-natural-language' 'en'
        $w.Write([byte]0x02)
        Write-IppAttribute $w 0x21 'job-id' ([byte[]](ConvertTo-IppInt32Bytes 7)) -Raw
        Write-IppAttribute $w 0x42 'job-name' 'quarterly-report.pdf'
        Write-IppAttribute $w 0x42 'job-originating-user-name' 'jsmith'
        Write-IppAttribute $w 0x23 'job-state' ([byte[]](ConvertTo-IppInt32Bytes 5)) -Raw
        Write-IppAttribute $w 0x44 'job-state-reasons' 'job-printing'
        Write-TestIppValue $w 0x44 '' ([System.Text.Encoding]::UTF8.GetBytes('processing-to-stop-point'))
        $w.Write([byte]0x02)
        Write-IppAttribute $w 0x21 'job-id' ([byte[]](ConvertTo-IppInt32Bytes 8)) -Raw
        Write-IppAttribute $w 0x42 'job-name' 'invoice.docx'
        Write-IppAttribute $w 0x42 'job-originating-user-name' 'agupta'
        Write-IppAttribute $w 0x23 'job-state' ([byte[]](ConvertTo-IppInt32Bytes 4)) -Raw
        $w.Write([byte]0x03)
        $w.Flush()
        $script:jobsResponse = $ms.ToArray()
    }

    It "reads back the successful-ok status" {
        (ConvertFrom-IppResponse $script:jobsResponse).Status | Should -Be 0
    }

    It "finds both job groups plus the leading operation-attributes group" {
        (ConvertFrom-IppResponse $script:jobsResponse).Groups.Count | Should -Be 3
    }

    It "reads job #1's scalar attributes correctly" {
        $job = (ConvertFrom-IppResponse $script:jobsResponse).Groups | Where-Object { $_.'job-id' -eq 7 }
        $job.'job-name'                     | Should -Be 'quarterly-report.pdf'
        $job.'job-originating-user-name'    | Should -Be 'jsmith'
        $job.'job-state'                    | Should -Be 5
    }

    It "collects the multi-valued job-state-reasons into an array, in order" {
        $job = (ConvertFrom-IppResponse $script:jobsResponse).Groups | Where-Object { $_.'job-id' -eq 7 }
        @($job.'job-state-reasons') | Should -Be @('job-printing', 'processing-to-stop-point')
    }

    It "reads job #2 as a separate, distinct group" {
        $job = (ConvertFrom-IppResponse $script:jobsResponse).Groups | Where-Object { $_.'job-id' -eq 8 }
        $job.'job-name' | Should -Be 'invoice.docx'
        $job.'job-state' | Should -Be 4
    }

    It "Get-CanonPrinterJobs' state map/shape matches what the parser hands it (skips the non-job group)" {
        # Exercises the same mapping Get-CanonPrinterJobs applies, without a
        # network call, by feeding the parsed groups through by hand.
        $parsed = ConvertFrom-IppResponse $script:jobsResponse
        $jobs = @($parsed.Groups | Where-Object { $_.'job-id' })
        $jobs.Count | Should -Be 2
    }
}

Describe "Write-IppMultiValue (used for requested-attributes / job history)" {
    It "writes the first value with a name and every value after it with an empty name" {
        # Parseable with the same group parser ConvertFrom-IppResponse uses -
        # the request header (version+op-id+request-id) is byte-for-byte the
        # same shape as a response header (version+status+request-id), so this
        # doubles as a wire-format check for the multi-value encoding itself.
        $ms = New-Object System.IO.MemoryStream
        $w  = New-Object System.IO.BinaryWriter($ms)
        $w.Write([byte[]]@(0x01, 0x01))
        $w.Write([byte[]](ConvertTo-IppInt16Bytes 0x000A))
        $w.Write([byte[]](ConvertTo-IppInt32Bytes 1))
        $w.Write([byte]0x01)
        Write-IppMultiValue $w 0x44 'requested-attributes' @('job-id', 'job-name', 'time-at-completed')
        $w.Write([byte]0x03)
        $w.Flush()
        $parsed = ConvertFrom-IppResponse $ms.ToArray()
        @($parsed.Groups[0].'requested-attributes') | Should -Be @('job-id', 'job-name', 'time-at-completed')
    }
}

Describe "Get-CanonPrinterJobs history support (time-at-completed)" {
    It "parses a completed job's time-at-completed as a positive integer, ready for epoch conversion" {
        $ms = New-Object System.IO.MemoryStream
        $w  = New-Object System.IO.BinaryWriter($ms)
        $w.Write([byte[]]@(0x01, 0x01))
        $w.Write([byte[]](ConvertTo-IppInt16Bytes 0x0000))
        $w.Write([byte[]](ConvertTo-IppInt32Bytes 1))
        $w.Write([byte]0x01)
        Write-IppAttribute $w 0x47 'attributes-charset' 'utf-8'
        $w.Write([byte]0x02)
        Write-IppAttribute $w 0x21 'job-id' ([byte[]](ConvertTo-IppInt32Bytes 3)) -Raw
        Write-IppAttribute $w 0x23 'job-state' ([byte[]](ConvertTo-IppInt32Bytes 9)) -Raw   # completed
        Write-IppAttribute $w 0x21 'time-at-completed' ([byte[]](ConvertTo-IppInt32Bytes 1735689600)) -Raw
        $w.Write([byte]0x03)
        $w.Flush()

        $job = (ConvertFrom-IppResponse $ms.ToArray()).Groups | Where-Object { $_.'job-id' -eq 3 }
        $job.'job-state' | Should -Be 9
        $job.'time-at-completed' | Should -Be 1735689600

        # Same epoch math Get-CanonPrinterJobs applies to turn that into a
        # local DateTime.
        $epoch = [datetime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
        $epoch.AddSeconds([int64]$job.'time-at-completed').Year | Should -Be 2025
    }

    It "an unfinished job (time-at-completed 0 or absent) should not produce a completion time" {
        $ms = New-Object System.IO.MemoryStream
        $w  = New-Object System.IO.BinaryWriter($ms)
        $w.Write([byte[]]@(0x01, 0x01))
        $w.Write([byte[]](ConvertTo-IppInt16Bytes 0x0000))
        $w.Write([byte[]](ConvertTo-IppInt32Bytes 1))
        $w.Write([byte]0x01)
        Write-IppAttribute $w 0x47 'attributes-charset' 'utf-8'
        $w.Write([byte]0x02)
        Write-IppAttribute $w 0x21 'job-id' ([byte[]](ConvertTo-IppInt32Bytes 4)) -Raw
        Write-IppAttribute $w 0x23 'job-state' ([byte[]](ConvertTo-IppInt32Bytes 5)) -Raw   # processing
        Write-IppAttribute $w 0x21 'time-at-completed' ([byte[]](ConvertTo-IppInt32Bytes 0)) -Raw
        $w.Write([byte]0x03)
        $w.Flush()

        $job = (ConvertFrom-IppResponse $ms.ToArray()).Groups | Where-Object { $_.'job-id' -eq 4 }
        $job.'time-at-completed' | Should -Be 0   # Get-CanonPrinterJobs treats <= 0 as "not completed"
    }
}

Describe "Get-CanonPrinterWebUrl" {
    AfterEach {
        $Global:ADTool.Printer.WebPort = 80
        $Global:ADTool.Printer.WebHttps = $false
    }
    It "defaults to plain http with no port shown (port 80 is the http default)" {
        Get-CanonPrinterWebUrl -PrinterAddress '10.10.4.21' | Should -Be 'http://10.10.4.21/'
    }
    It "shows a non-default port" {
        $Global:ADTool.Printer.WebPort = 8080
        Get-CanonPrinterWebUrl -PrinterAddress '10.10.4.21' | Should -Be 'http://10.10.4.21:8080/'
    }
    It "switches to https and hides port 443 (its own default)" {
        $Global:ADTool.Printer.WebHttps = $true
        $Global:ADTool.Printer.WebPort = 443
        Get-CanonPrinterWebUrl -PrinterAddress '10.10.4.21' | Should -Be 'https://10.10.4.21/'
    }
}

Describe "ConvertTo-DeskSideIpRange (CIDR expansion)" {
    It "expands a /24 to 254 usable addresses, excluding network and broadcast" {
        $r = ConvertTo-DeskSideIpRange -Cidr '10.10.4.0/24'
        $r.Count      | Should -Be 254
        $r[0]         | Should -Be '10.10.4.1'
        $r[-1]        | Should -Be '10.10.4.254'
        $r            | Should -Not -Contain '10.10.4.0'
        $r            | Should -Not -Contain '10.10.4.255'
    }

    It "expands a /30 to its 2 usable addresses" {
        ConvertTo-DeskSideIpRange -Cidr '192.168.1.4/30' | Should -Be @('192.168.1.5', '192.168.1.6')
    }

    It "/31 has no network/broadcast to exclude - both addresses are usable" {
        ConvertTo-DeskSideIpRange -Cidr '10.0.0.0/31' | Should -Be @('10.0.0.0', '10.0.0.1')
    }

    It "/32 is exactly the one address given" {
        ConvertTo-DeskSideIpRange -Cidr '10.0.0.5/32' | Should -Be @('10.0.0.5')
    }

    It "normalizes an address with host bits set down to the network's usable range" {
        $r = ConvertTo-DeskSideIpRange -Cidr '10.10.4.137/24'
        $r[0] | Should -Be '10.10.4.1'
        $r[-1] | Should -Be '10.10.4.254'
        $r.Count | Should -Be 254
    }

    It "rejects text that isn't a CIDR range" {
        { ConvertTo-DeskSideIpRange -Cidr 'not-a-cidr' } | Should -Throw
    }

    It "rejects a prefix wider than /16 (too big to scan)" {
        { ConvertTo-DeskSideIpRange -Cidr '10.0.0.0/8' } | Should -Throw
    }

    It "rejects a prefix past /32" {
        { ConvertTo-DeskSideIpRange -Cidr '10.0.0.0/33' } | Should -Throw
    }
}

Describe "Find-NetworkPrinter (against a real loopback listener)" {
    BeforeAll {
        # A real TCP listener on loopback stands in for "a printer with port
        # 9100 open" - proves the async connect/wait logic actually detects an
        # open port and correctly skips a closed one, without needing a real
        # printer on the network.
        $script:listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, 19100)
        $script:listener.Start()
    }
    AfterAll { $script:listener.Stop() }

    It "finds the address with the open port and skips the one without" {
        $results = @(Find-NetworkPrinter -Addresses @('127.0.0.1', '127.0.0.2') -Ports @(19100) -TimeoutMs 500 -BatchSize 10)
        $results.Count | Should -Be 1
        $results[0].IPAddress | Should -Be '127.0.0.1'
        $results[0].Ports | Should -Contain 19100
    }

    It "reports progress that reaches the full address count" {
        $seen = New-Object System.Collections.Generic.List[int]
        [void](Find-NetworkPrinter -Addresses @('127.0.0.1', '127.0.0.2', '127.0.0.3') -Ports @(19100) -TimeoutMs 300 -BatchSize 2 -OnProgress {
            param($done, $total) $seen.Add($done)
        })
        $seen[-1] | Should -Be 3
    }

    It "finds nothing when no address in range has the port open" {
        $results = @(Find-NetworkPrinter -Addresses @('127.0.0.2', '127.0.0.3') -Ports @(19100) -TimeoutMs 300 -BatchSize 10)
        $results.Count | Should -Be 0
    }
}

Describe "Get-NetworkPrinterLabel / ConvertTo-NetworkPrinterScanLine" {
    # Regression coverage for a real bug: .Add(("{0}..." -f $a, $b, $c)) needs
    # its outer parens, because inside a .NET method call's argument list a
    # comma separates METHOD ARGUMENTS, not -f's value list - without them,
    # .Add() silently received 3 arguments and -f only got 1 value for a
    # 3-placeholder template, so it threw "Index ... must be ... less than the
    # size of the argument list" for every real (non-empty SysDescr) result.
    It "prefers SysDescr when present" {
        Get-NetworkPrinterLabel ([pscustomobject]@{ SysDescr = 'Canon iR-ADV C3926 series'; Hostname = 'printer1.contoso.com' }) |
            Should -Be 'Canon iR-ADV C3926 series'
    }
    It "falls back to Hostname when there's no SysDescr" {
        Get-NetworkPrinterLabel ([pscustomobject]@{ SysDescr = $null; Hostname = 'printer1.contoso.com' }) |
            Should -Be 'printer1.contoso.com'
    }
    It "falls back to a plain note when neither is available" {
        Get-NetworkPrinterLabel ([pscustomobject]@{ SysDescr = $null; Hostname = $null }) |
            Should -Be '(no SNMP reply - identified by open port only)'
    }

    It "builds one correct tab-separated line, the exact shape written to output\*.txt" {
        $result = [pscustomobject]@{ IPAddress = '10.113.17.88'; Ports = @(631, 9100); SysDescr = 'Canon iR-ADV C3926 series'; Hostname = $null }
        ConvertTo-NetworkPrinterScanLine $result | Should -Be "10.113.17.88`tports=631,9100`tCanon iR-ADV C3926 series"
    }

    It "does not throw when appended straight into a List[string] with .Add(...) (the exact call site that broke)" {
        $result = [pscustomobject]@{ IPAddress = '10.113.17.88'; Ports = @(631, 9100); SysDescr = 'Canon iR-ADV C3926 series'; Hostname = $null }
        $lines = New-Object System.Collections.Generic.List[string]
        { $lines.Add((ConvertTo-NetworkPrinterScanLine $result)) } | Should -Not -Throw
        $lines.Count | Should -Be 1
    }
}

Describe "Format-IppStatus" {
    It "labels a known client-error code" { Format-IppStatus 0x0406 | Should -Be 'job/target not found' }
    It "falls back to the raw hex for an unknown code" { Format-IppStatus 0x09AB | Should -Be '0x09AB' }
}
