<#
.SYNOPSIS
    Automated checks for the shared helpers in lib\Common.ps1.

.DESCRIPTION
    Run these with:  .\Run-Tests.ps1     (from the project root)

    WHAT THIS IS FOR
    These tests prove the shared helpers still behave correctly after a change.
    They are the safety net: if you edit lib\Common.ps1 and something here goes
    red, you broke something that other scripts depend on.

    NOTHING HERE TOUCHES THE REAL WORLD. There is no Active Directory, no
    Snipe-IT, no Tactical RMM, and no network call. Where a helper would
    normally reach out, the test replaces that command with a stand-in that
    just records what it was asked to do. That is why these run on any PC, in
    seconds, with no credentials set.

    HOW TO ADD A TEST
    Copy the closest 'It' block below and change it. The pattern is always:
      1. set up the situation
      2. call the helper
      3. say what you expected with 'Should'
#>

# Replacing built-in commands is normally a bad idea, which is why the code
# checker flags it. Here it is the entire point: these stand-ins are how the
# tests avoid touching AD, the network, and the keyboard. Switch the warning off
# for this file only.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
    Justification = 'Test stand-ins for Get-ADUser, Invoke-RestMethod and Read-Host are deliberate.')]
param()

BeforeAll {
    # Load the library under test. $PSScriptRoot is the tests folder, so ".."
    # is the project root.
    . "$PSScriptRoot\..\lib\Common.ps1"

    # A scratch folder that stands in for the real output\ folder, so tests
    # never write into the toolkit's own logs.
    $script:TestOutput = Join-Path ([IO.Path]::GetTempPath()) "DeskSideTests-$(Get-Random)"
    New-Item -ItemType Directory -Path $script:TestOutput -Force | Out-Null

    # Point the log writers at that scratch folder instead of output\. This
    # stand-in must honour -Category the same way the real one does, otherwise
    # the tests would write everything flat and quietly stop checking that
    # output lands in the right sub-folder.
    function Get-ADToolOutputDir {
        param([string]$Category)
        $dir = $script:TestOutput
        if ($Category) { $dir = Join-Path $dir $Category }
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $dir
    }
}

AfterAll {
    if ($script:TestOutput -and (Test-Path $script:TestOutput)) {
        Remove-Item $script:TestOutput -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'ConvertTo-LdapEscapedString' {

    It 'leaves an ordinary name alone' {
        ConvertTo-LdapEscapedString -Value 'alex.amog' | Should -Be 'alex.amog'
    }

    It "does NOT touch an apostrophe - this is the o'brien bug" {
        # An apostrophe means nothing special in LDAP. It only broke the old
        # -Filter version, which wrapped the value in single quotes.
        ConvertTo-LdapEscapedString -Value "o'brien" | Should -Be "o'brien"
    }

    It 'escapes the four characters LDAP treats as special' {
        ConvertTo-LdapEscapedString -Value '('  | Should -Be '\28'
        ConvertTo-LdapEscapedString -Value ')'  | Should -Be '\29'
        ConvertTo-LdapEscapedString -Value '*'  | Should -Be '\2a'
        ConvertTo-LdapEscapedString -Value '\'  | Should -Be '\5c'
    }

    It 'escapes the backslash first so the other codes are not mangled' {
        # If '(' were escaped before '\', the '\' of the resulting '\28' would
        # then be escaped again and the filter would be wrong.
        ConvertTo-LdapEscapedString -Value '\(' | Should -Be '\5c\28'
    }

    It 'handles a name using several special characters at once' {
        ConvertTo-LdapEscapedString -Value 'a(b)c*d\e' | Should -Be 'a\28b\29c\2ad\5ce'
    }

    It 'accepts an empty string without complaining' {
        ConvertTo-LdapEscapedString -Value '' | Should -Be ''
    }
}

Describe 'Resolve-ADToolUser' {

    BeforeAll {
        # Stand in for the real AD cmdlet: record what it was asked, return
        # whatever the test wants. A function beats a cmdlet of the same name,
        # so this is what Resolve-ADToolUser will call.
        function Get-ADUser {
            param($LDAPFilter, $Filter, $Properties, $Server, $ErrorAction)
            $script:AskedFor = $PSBoundParameters
            $script:FakeUser
        }
    }

    BeforeEach {
        $script:AskedFor = $null
        $script:FakeUser = [pscustomobject]@{ SamAccountName = 'someone' }
    }

    It 'searches on both the SAM name and the UPN' {
        Resolve-ADToolUser -Identity 'jsmith' | Out-Null
        $script:AskedFor.LDAPFilter | Should -Be '(|(sAMAccountName=jsmith)(userPrincipalName=jsmith))'
    }

    It 'uses LDAPFilter, never the quoted Filter that the apostrophe broke' {
        Resolve-ADToolUser -Identity 'jsmith' | Out-Null
        $script:AskedFor.Keys | Should -Contain 'LDAPFilter'
        $script:AskedFor.Keys | Should -Not -Contain 'Filter'
    }

    It "builds a valid search for a name containing an apostrophe" {
        Resolve-ADToolUser -Identity "o'brien" | Out-Null
        $script:AskedFor.LDAPFilter | Should -Be "(|(sAMAccountName=o'brien)(userPrincipalName=o'brien))"
    }

    It 'escapes a wildcard instead of letting it widen the search' {
        Resolve-ADToolUser -Identity 'admin*' | Out-Null
        $script:AskedFor.LDAPFilter | Should -Be '(|(sAMAccountName=admin\2a)(userPrincipalName=admin\2a))'
    }

    It 'passes -Properties and -Server straight through when given' {
        Resolve-ADToolUser -Identity 'jsmith' -Properties 'Mail' -Server 'DC01' | Out-Null
        $script:AskedFor.Properties | Should -Be 'Mail'
        $script:AskedFor.Server     | Should -Be 'DC01'
    }

    It 'returns nothing when no user matches' {
        $script:FakeUser = $null
        Resolve-ADToolUser -Identity 'ghost' 6>$null | Should -BeNullOrEmpty
    }
}

Describe 'Get-ADToolDC' {

    It 'uses the server it was given rather than looking one up' {
        Get-ADToolDC -Server 'DC42' | Should -Be 'DC42'
    }
}

Describe 'Invoke-TrmmRequest' {

    BeforeAll {
        # Stand in for the network call: return what WOULD have been sent.
        function Invoke-RestMethod {
            param($Uri, $Headers, $Method, $Body, $ErrorAction)
            [pscustomobject]@{ Uri = $Uri; Headers = $Headers; Method = $Method; Body = $Body }
        }
    }

    BeforeEach {
        $env:TRMM_APIKEY = 'TESTKEY'
        $env:TRMM_URL    = 'https://api.example.com'
    }

    It 'stops with a helpful message when the credentials are not set' {
        $env:TRMM_APIKEY = ''
        { Invoke-TrmmRequest GET 'agents/' } | Should -Throw '*Set-TacticalCredentials*'
    }

    It 'builds the full address from the base URL and the path' {
        (Invoke-TrmmRequest GET 'agents/').Uri | Should -Be 'https://api.example.com/agents/'
    }

    It 'does not produce a double slash when either side has one' {
        $env:TRMM_URL = 'https://api.example.com/'
        (Invoke-TrmmRequest GET '/agents/').Uri | Should -Be 'https://api.example.com/agents/'
    }

    It 'sends the API key in the header TRMM expects' {
        (Invoke-TrmmRequest GET 'agents/').Headers['X-API-KEY'] | Should -Be 'TESTKEY'
    }

    It 'sends no body for a plain GET' {
        (Invoke-TrmmRequest GET 'agents/').Body | Should -BeNullOrEmpty
    }

    It 'turns a hashtable body into JSON' {
        $sent = Invoke-TrmmRequest POST 'scripts/' @{ name = 'cleanup' }
        ($sent.Body | ConvertFrom-Json).name | Should -Be 'cleanup'
    }

    It 'refuses a method that is not a real HTTP verb' {
        { Invoke-TrmmRequest -Method 'FETCH' -Path 'agents/' } | Should -Throw
    }
}

Describe 'Invoke-TrmmAgentCommand' {

    BeforeAll {
        function Invoke-RestMethod {
            param($Uri, $Headers, $Method, $Body, $ErrorAction)
            [pscustomobject]@{ Uri = $Uri; Method = $Method; Body = $Body }
        }
    }

    BeforeEach {
        $env:TRMM_APIKEY = 'TESTKEY'
        $env:TRMM_URL    = 'https://api.example.com'
    }

    It 'posts to the command endpoint for that one agent' {
        $sent = Invoke-TrmmAgentCommand -AgentId 'abc-123' -Command 'hostname'
        $sent.Uri    | Should -Be 'https://api.example.com/agents/abc-123/cmd/'
        $sent.Method | Should -Be 'POST'
    }

    It 'sends the command as a PowerShell command' {
        $body = (Invoke-TrmmAgentCommand -AgentId 'a1' -Command 'hostname').Body | ConvertFrom-Json
        $body.shell | Should -Be 'powershell'
        $body.cmd   | Should -Be 'hostname'
    }

    It 'runs as the machine, not the logged-in user, unless asked' {
        $body = (Invoke-TrmmAgentCommand -AgentId 'a1' -Command 'hostname').Body | ConvertFrom-Json
        $body.run_as_user | Should -BeFalse
    }

    It 'runs in the user session when -AsUser is given' {
        # This is what makes "lock the screen" work, so it matters.
        $body = (Invoke-TrmmAgentCommand -AgentId 'a1' -Command 'x' -AsUser).Body | ConvertFrom-Json
        $body.run_as_user | Should -BeTrue
    }

    It 'passes the timeout through' {
        $body = (Invoke-TrmmAgentCommand -AgentId 'a1' -Command 'x' -TimeoutSec 45).Body | ConvertFrom-Json
        $body.timeout | Should -Be 45
    }
}

Describe 'ConvertTo-RemoteLiteral' {

    # Names and paths get pasted INSIDE single quotes in remote commands. The one
    # character that breaks that is the apostrophe - this is the caitlin.o'sullivan
    # incident. The helper doubles it, which is how PowerShell escapes a quote.

    It 'leaves an ordinary name untouched' {
        ConvertTo-RemoteLiteral 'alex.amog' | Should -Be 'alex.amog'
    }

    It "doubles an apostrophe so the name cannot break out of its quotes" {
        ConvertTo-RemoteLiteral "caitlin.o'sullivan" | Should -Be "caitlin.o''sullivan"
    }

    It 'doubles every apostrophe when there is more than one' {
        ConvertTo-RemoteLiteral "d'angelo.o'brien" | Should -Be "d''angelo.o''brien"
    }

    It 'leaves a path with a backslash alone (only the quote matters)' {
        ConvertTo-RemoteLiteral 'C:\Temp\file.txt' | Should -Be 'C:\Temp\file.txt'
    }

    It 'escapes an apostrophe inside a path' {
        ConvertTo-RemoteLiteral "C:\Users\o'brien\Desktop" | Should -Be "C:\Users\o''brien\Desktop"
    }

    It 'accepts an empty string' {
        ConvertTo-RemoteLiteral '' | Should -Be ''
    }

    # The real proof: the escaped value, embedded the way every remote script
    # does it, must (a) parse and (b) come back out as the ORIGINAL name.
    It 'round-trips through a single-quoted assignment for any name' {
        foreach ($name in @("caitlin.o'sullivan", 'alex.amog', "d'angelo.o'brien")) {
            $line = "`$u = '$(ConvertTo-RemoteLiteral $name)'"

            $errs = @()
            [System.Management.Automation.Language.Parser]::ParseInput($line, [ref]$null, [ref]$errs) | Out-Null
            $errs.Count | Should -Be 0 -Because "'$name' must produce a command that parses"

            # The scriptblock has its own scope, so have it hand $u back out.
            $got = & ([scriptblock]::Create($line + '; $u'))
            $got | Should -Be $name -Because "'$name' must survive the round trip unchanged"
        }
    }

    It 'a RAW apostrophe name would break the command (proves the escape is needed)' {
        # No ConvertTo-RemoteLiteral here on purpose - this is the bug it fixes.
        $line = "`$u = 'caitlin.o'sullivan'"
        $errs = @()
        [System.Management.Automation.Language.Parser]::ParseInput($line, [ref]$null, [ref]$errs) | Out-Null
        $errs.Count | Should -BeGreaterThan 0
    }
}

Describe 'Connect-ExoSession' {

    It 'returns false when the ExchangeOnlineManagement module is not installed' {
        function Get-Module { param([switch]$ListAvailable, $Name) }   # nothing installed
        function Connect-ExchangeOnline { throw 'must not try to connect' }
        (Connect-ExoSession 6>$null) | Should -BeFalse
    }

    It 'reuses a live connection without connecting again' {
        function Get-Module { param([switch]$ListAvailable, $Name) [pscustomobject]@{ Name = 'ExchangeOnlineManagement' } }
        function Import-Module { param($Name, $ErrorAction) }
        function Get-ConnectionInformation { [pscustomobject]@{ State = 'Connected' } }
        $script:exoConnects = 0
        function Connect-ExchangeOnline { $script:exoConnects++ }
        (Connect-ExoSession 6>$null) | Should -BeTrue
        $script:exoConnects | Should -Be 0
    }

    It 'connects when installed but not yet connected' {
        function Get-Module { param([switch]$ListAvailable, $Name) [pscustomobject]@{ Name = 'ExchangeOnlineManagement' } }
        function Import-Module { param($Name, $ErrorAction) }
        function Get-ConnectionInformation { @() }
        $script:exoConnects = 0
        function Connect-ExchangeOnline { $script:exoConnects++ }
        (Connect-ExoSession 6>$null) | Should -BeTrue
        $script:exoConnects | Should -Be 1
    }
}

Describe 'Find-ExoRecipient' {

    It 'filters the results to the requested recipient type' {
        function Read-Host { param($Prompt) 'smith' }
        function Get-Recipient {
            param($ANR, $ResultSize, $ErrorAction)
            @([pscustomobject]@{ DisplayName = 'A User'; PrimarySmtpAddress = 'a@x'; RecipientTypeDetails = 'UserMailbox' },
              [pscustomobject]@{ DisplayName = 'A Box';  PrimarySmtpAddress = 'b@x'; RecipientTypeDetails = 'SharedMailbox' })
        }
        $script:offered = $null
        function Select-FromList { param($Items, $Label, $Prompt) $script:offered = @($Items); $Items[0] }

        $chosen = Find-ExoRecipient -Types 'SharedMailbox'
        $script:offered.Count | Should -Be 1
        $script:offered[0].RecipientTypeDetails | Should -Be 'SharedMailbox'
        $chosen.PrimarySmtpAddress | Should -Be 'b@x'
    }

    It 'returns nothing when the search box is left empty' {
        function Read-Host { param($Prompt) '' }
        Find-ExoRecipient | Should -BeNullOrEmpty
    }
}

Describe 'Connect-MgGraphSession' {

    It 'returns false when Microsoft.Graph.Authentication cannot be loaded' {
        # The real failure this guards: a half-finished install leaves
        # Connect-MgGraph findable but the module unloadable.
        function Import-Module { param($Name, $ErrorAction) throw 'the module could not be loaded' }
        function Connect-MgGraph { throw 'must not connect' }
        (Connect-MgGraphSession 6>$null) | Should -BeFalse
    }

    It 'reuses an existing context without connecting again' {
        function Import-Module { param($Name, $ErrorAction) }
        function Get-MgContext { [pscustomobject]@{ Account = 'admin@x' } }
        $script:mgConnects = 0
        function Connect-MgGraph { param($Scopes, [switch]$NoWelcome, $ErrorAction) $script:mgConnects++ }
        (Connect-MgGraphSession 6>$null) | Should -BeTrue
        $script:mgConnects | Should -Be 0
    }

    It 'connects when installed but no context yet' {
        function Import-Module { param($Name, $ErrorAction) }
        function Get-MgContext { $null }
        $script:mgConnects = 0
        function Connect-MgGraph { param($Scopes, [switch]$NoWelcome, $ErrorAction) $script:mgConnects++ }
        (Connect-MgGraphSession 6>$null) | Should -BeTrue
        $script:mgConnects | Should -Be 1
    }
}

Describe 'Get-M365LicenseSku' {

    It 'resolves Office 365 E1 by its STANDARDPACK part number' {
        function Get-MgSubscribedSku {
            param([switch]$All, $ErrorAction)
            @([pscustomobject]@{ SkuId = 'sku-e3'; SkuPartNumber = 'ENTERPRISEPACK'; PrepaidUnits = @{ Enabled = 10 }; ConsumedUnits = 3 },
              [pscustomobject]@{ SkuId = 'sku-e1'; SkuPartNumber = 'STANDARDPACK';  PrepaidUnits = @{ Enabled = 50 }; ConsumedUnits = 20 })
        }
        (Get-M365LicenseSku 6>$null).SkuId | Should -Be 'sku-e1'
    }

    It 'returns nothing (and lists options) when the part number is absent' {
        function Get-MgSubscribedSku {
            param([switch]$All, $ErrorAction)
            @([pscustomobject]@{ SkuId = 'sku-e3'; SkuPartNumber = 'ENTERPRISEPACK'; PrepaidUnits = @{ Enabled = 10 }; ConsumedUnits = 3 })
        }
        Get-M365LicenseSku -PartNumber 'STANDARDPACK' 6>$null | Should -BeNullOrEmpty
    }
}

Describe 'Set-M365UserLicense' {

    BeforeEach {
        $script:added = $null; $script:removed = $null; $script:usageLoc = $null
        function Update-MgUser   { param($UserId, $UsageLocation, $ErrorAction) $script:usageLoc = $UsageLocation }
        function Set-MgUserLicense { param($UserId, $AddLicenses, $RemoveLicenses, $ErrorAction) $script:added = $AddLicenses; $script:removed = $RemoveLicenses }
    }

    It 'adds the SKU and sets a usage location first' {
        $env:M365_USAGE_LOCATION = 'CA'
        (Set-M365UserLicense -UserId 'x@y' -SkuId 'sku-e1' -Action Add 6>$null) | Should -BeTrue
        $script:usageLoc      | Should -Be 'CA'
        $script:added[0].SkuId | Should -Be 'sku-e1'
        @($script:removed).Count | Should -Be 0
    }

    It 'removes the SKU without touching usage location' {
        (Set-M365UserLicense -UserId 'x@y' -SkuId 'sku-e1' -Action Remove 6>$null) | Should -BeTrue
        $script:usageLoc     | Should -BeNullOrEmpty
        $script:removed[0]   | Should -Be 'sku-e1'
        @($script:added).Count | Should -Be 0
    }
}

Describe 'Connect-SpoSession' {

    BeforeEach { $env:SPO_ADMIN_URL = 'https://contoso-admin.sharepoint.com' }

    It 'returns false when the SharePoint module is not installed' {
        function Get-Module { param([switch]$ListAvailable, $Name) }
        function Connect-SPOService { throw 'must not connect' }
        (Connect-SpoSession 6>$null) | Should -BeFalse
    }

    It 'returns false when SPO_ADMIN_URL is not set' {
        function Get-Module { param([switch]$ListAvailable, $Name) [pscustomobject]@{ Name = 'Microsoft.Online.SharePoint.PowerShell' } }
        $env:SPO_ADMIN_URL = ''
        (Connect-SpoSession 6>$null) | Should -BeFalse
    }

    It 'reuses a live session (Get-SPOTenant succeeds) without connecting' {
        function Get-Module { param([switch]$ListAvailable, $Name) [pscustomobject]@{ Name = 'Microsoft.Online.SharePoint.PowerShell' } }
        function Import-Module { param($Name, $ErrorAction) }
        function Get-SPOTenant { [pscustomobject]@{ StorageQuota = 1 } }
        $script:spoConnects = 0
        function Connect-SPOService { param($Url, $ErrorAction) $script:spoConnects++ }
        (Connect-SpoSession 6>$null) | Should -BeTrue
        $script:spoConnects | Should -Be 0
    }

    It 'connects when installed but not yet connected' {
        function Get-Module { param([switch]$ListAvailable, $Name) [pscustomobject]@{ Name = 'Microsoft.Online.SharePoint.PowerShell' } }
        function Import-Module { param($Name, $ErrorAction) }
        function Get-SPOTenant { throw 'not connected' }
        $script:spoConnects = 0
        function Connect-SPOService { param($Url, $ErrorAction) $script:spoConnects++ }
        (Connect-SpoSession 6>$null) | Should -BeTrue
        $script:spoConnects | Should -Be 1
    }
}

Describe 'Get-SpoRootUrl' {

    It 'derives the sites root from the admin URL' {
        $env:SPO_ADMIN_URL = 'https://contoso-admin.sharepoint.com'
        Get-SpoRootUrl | Should -Be 'https://contoso.sharepoint.com'
    }

    It 'drops a trailing slash so new-site URLs are not doubled' {
        $env:SPO_ADMIN_URL = 'https://contoso-admin.sharepoint.com/'
        Get-SpoRootUrl | Should -Be 'https://contoso.sharepoint.com'
    }

    It 'returns empty when the admin URL is not set' {
        $env:SPO_ADMIN_URL = ''
        Get-SpoRootUrl | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-SnipeRequest' {

    BeforeAll {
        function Invoke-RestMethod {
            param($Uri, $Headers, $Method, $Body, $ErrorAction)
            [pscustomobject]@{ Uri = $Uri; Headers = $Headers; Method = $Method }
        }
    }

    BeforeEach {
        $ADTool.SnipeIT.BaseUrl = 'https://assets.example.com/api/v1'
        $ADTool.SnipeIT.Token   = 'Bearer TESTTOKEN'
    }

    It 'stops with a helpful message when the token is not set' {
        $ADTool.SnipeIT.Token = $null
        { Invoke-SnipeRequest -Path 'hardware' } | Should -Throw '*Set-SnipeCredentials*'
    }

    It 'builds the full address from the base URL and the path' {
        (Invoke-SnipeRequest -Path 'hardware').Uri | Should -Be 'https://assets.example.com/api/v1/hardware'
    }

    It 'adds query values to the address' {
        (Invoke-SnipeRequest -Path 'hardware' -Query @{ limit = 50 }).Uri |
            Should -Be 'https://assets.example.com/api/v1/hardware?limit=50'
    }

    It 'escapes a search term containing a space' {
        # Without escaping, a space would cut the address short.
        (Invoke-SnipeRequest -Path 'hardware' -Query @{ search = 'dell laptop' }).Uri |
            Should -Be 'https://assets.example.com/api/v1/hardware?search=dell%20laptop'
    }

    It 'sends the token as the Authorization header' {
        (Invoke-SnipeRequest -Path 'hardware').Headers.Authorization | Should -Be 'Bearer TESTTOKEN'
    }
}

Describe 'ConvertFrom-SnipeField' {

    It 'returns empty string for null' {
        ConvertFrom-SnipeField $null | Should -Be ''
    }

    It 'returns a plain string unchanged' {
        ConvertFrom-SnipeField 'ITDESSPARE-01' | Should -Be 'ITDESSPARE-01'
    }

    It 'unwraps the friendly formatted value from a Snipe date object' {
        $date = [pscustomobject]@{ date = '2026-01-02'; formatted = 'Jan 02, 2026' }
        ConvertFrom-SnipeField $date | Should -Be 'Jan 02, 2026'
    }
}

Describe 'Get-SnipeHardware' {

    BeforeAll {
        # Stand in for the API: page a synthetic dataset by limit/offset and
        # record the query each page asked for.
        function Invoke-SnipeRequest {
            param($Path, $Query, $Method, $Body)
            $script:PagesAsked += ,$Query
            $all = 1..$script:TotalRows | ForEach-Object { [pscustomobject]@{ id = $_; asset_tag = ('T{0:D4}' -f $_) } }
            $page = @($all | Select-Object -Skip $Query.offset -First $Query.limit)
            [pscustomobject]@{ rows = $page; total = $script:TotalRows }
        }
    }

    BeforeEach { $script:PagesAsked = @() }

    It 'returns every row across several pages' {
        $script:TotalRows = 1200
        (Get-SnipeHardware -Query @{ search = 'x' } -PageSize 500).Count | Should -Be 1200
    }

    It 'unrolls cleanly when the caller wraps it in @() (the collapse bug)' {
        # @(Get-SnipeHardware ...) must give N separate rows, not one row whose
        # cells are arrays. A leading-comma return breaks exactly this.
        $script:TotalRows = 3
        $rows = @(Get-SnipeHardware -Query @{})
        $rows.Count            | Should -Be 3
        $rows[0].asset_tag     | Should -Be 'T0001'
    }

    It 'stops after one page when everything fits' {
        $script:TotalRows = 30
        Get-SnipeHardware -Query @{} -PageSize 500 | Out-Null
        $script:PagesAsked.Count | Should -Be 1
    }

    It 'passes the caller filters through on every page' {
        $script:TotalRows = 1200
        Get-SnipeHardware -Query @{ status_id = 4 } -PageSize 500 | Out-Null
        foreach ($q in $script:PagesAsked) { $q.status_id | Should -Be 4 }
    }

    It 'does not mutate the caller hashtable' {
        $script:TotalRows = 10
        $mine = @{ search = 'abc' }
        Get-SnipeHardware -Query $mine | Out-Null
        $mine.ContainsKey('limit')  | Should -BeFalse
        $mine.ContainsKey('offset') | Should -BeFalse
    }

    It 'honours the safety cap instead of looping forever' {
        $script:TotalRows = 100000
        (Get-SnipeHardware -Query @{} -PageSize 500 -MaxRows 1000).Count | Should -BeLessOrEqual 1500
    }
}

Describe 'Write-SnipeAssetReport' {

    BeforeAll {
        # Don't actually prompt or open a browser during the test.
        function Read-Host { param($Prompt) 'n' }
        function Start-Process { param($x) }

        function New-Asset ($tag, $status, $loc, $rtd) {
            [pscustomobject]@{
                asset_tag = $tag; name = $tag; serial = "SN-$tag"; notes = ''
                model        = [pscustomobject]@{ name = 'OptiPlex' }
                manufacturer = [pscustomobject]@{ name = 'Dell' }
                category     = [pscustomobject]@{ name = 'Desktop' }
                status_label = [pscustomobject]@{ name = $status }
                assigned_to  = [pscustomobject]@{ name = '' }
                location     = [pscustomobject]@{ name = $loc }
                rtd_location  = [pscustomobject]@{ name = $rtd }
                purchase_date = [pscustomobject]@{ formatted = 'Jan 02, 2026' }
                warranty_expires = $null
            }
        }
    }

    It 'writes JSON and HTML with the right count and criteria' {
        $assets = @((New-Asset 'ITDESSPARE-01' 'Ready to Deploy' '' 'Admin building'),
                    (New-Asset 'ITDESSPARE-02' 'Ready to Deploy' 'Admin building' 'Admin building'))
        $r = Write-SnipeAssetReport -Assets $assets -Criteria @('keyword = ITDESSPARE', 'status = Ready to Deploy') -NoPrompt

        $r.Count | Should -Be 2
        Test-Path $r.Json | Should -BeTrue
        Test-Path $r.Html | Should -BeTrue
        # Sorted by kind, not dumped in the output root.
        Split-Path $r.Json -Parent | Should -BeLike '*Audits\SnipeReports'

        $parsed = Get-Content $r.Json -Raw | ConvertFrom-Json
        $parsed.count       | Should -Be 2
        @($parsed.criteria) | Should -Contain 'status = Ready to Deploy'
        @($parsed.assets).Count | Should -Be 2
    }

    It 'records the default (RTD) location so spares are not blank' {
        $assets = @((New-Asset 'ITDESSPARE-01' 'Ready to Deploy' '' 'Admin building'))
        $r = Write-SnipeAssetReport -Assets $assets -Criteria @() -NoPrompt
        $parsed = Get-Content $r.Json -Raw | ConvertFrom-Json
        @($parsed.assets)[0].RtdLocation | Should -Be 'Admin building'
    }

    It 'escapes HTML so a note cannot break the markup' {
        $a = New-Asset 'ITDESSPARE-09' 'Ready to Deploy' '' 'Admin building'
        $a.notes = '<script>bad()</script>'
        $r = Write-SnipeAssetReport -Assets @($a) -Criteria @() -NoPrompt
        (Get-Content $r.Html -Raw) | Should -Not -Match '<script>bad'
    }
}

Describe 'Write-ActionLog' {

    It 'writes one row with the columns the audit file expects' {
        Write-ActionLog -Action 'Reset Password' -Target 'jsmith'
        $row = Import-Csv (Join-Path $script:TestOutput 'Logs\AD-Toolkit-Actions.csv') | Select-Object -Last 1

        $row.Action   | Should -Be 'Reset Password'
        $row.Target   | Should -Be 'jsmith'
        $row.Result   | Should -Be 'Success'      # the default
        $row.Operator | Should -Be $env:USERNAME
        $row.Timestamp | Should -Not -BeNullOrEmpty
    }

    It 'records a failure with its explanation' {
        Write-ActionLog -Action 'Reset Password' -Target 'jsmith' -Result 'Failed' -Details 'Access denied'
        $row = Import-Csv (Join-Path $script:TestOutput 'Logs\AD-Toolkit-Actions.csv') | Select-Object -Last 1

        $row.Result  | Should -Be 'Failed'
        $row.Details | Should -Be 'Access denied'
    }

    It 'adds to the file instead of replacing it' {
        $log = Join-Path $script:TestOutput 'Logs\AD-Toolkit-Actions.csv'
        $before = @(Import-Csv $log).Count
        Write-ActionLog -Action 'Test' -Target 'x'
        @(Import-Csv $log).Count | Should -Be ($before + 1)
    }
}

Describe 'Write-SnipeAssetLog' {

    BeforeAll {
        # WATCH OUT (PowerShell 5.1): ConvertFrom-Json hands the whole array to
        # the pipeline as ONE object, so
        #     @(Get-Content $file -Raw | ConvertFrom-Json).Count
        # is always 1, no matter how many entries the file holds. Assign the
        # result to a variable FIRST, then count it - as this helper does. The
        # same trap is why Write-SnipeAssetLog reads into $parsed before looping.
        #
        # (This has to live in BeforeAll: Pester throws away functions declared
        # loose in a Describe body once the discovery pass is over.)
        function Read-AssetLog {
            $parsed = Get-Content $script:AssetLog -Raw | ConvertFrom-Json
            , @($parsed)
        }
    }

    BeforeEach {
        # Start each test from a clean log.
        Get-ChildItem (Join-Path $script:TestOutput 'Logs') -Filter 'Snipe-Asset-Changes.json*' -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
        $script:AssetLog = Join-Path $script:TestOutput 'Logs\Snipe-Asset-Changes.json'
    }

    It 'records the old and new value of a change' {
        Write-SnipeAssetLog -Action 'Update' -AssetTag 'A1' -AssetId 1 -Field 'name' -OldValue 'OLD' -NewValue 'NEW'
        $entry = (Read-AssetLog)[0]

        $entry.Action   | Should -Be 'Update'
        $entry.AssetTag | Should -Be 'A1'
        $entry.OldValue | Should -Be 'OLD'
        $entry.NewValue | Should -Be 'NEW'
        $entry.Operator | Should -Be $env:USERNAME
    }

    It 'keeps every entry as the file grows' {
        Write-SnipeAssetLog -Action 'Update' -AssetTag 'A1' -AssetId 1
        Write-SnipeAssetLog -Action 'Update' -AssetTag 'A2' -AssetId 2
        Write-SnipeAssetLog -Action 'Update' -AssetTag 'A3' -AssetId 3

        $entries = Read-AssetLog
        $entries.Count | Should -Be 3
        $entries[0].AssetTag | Should -Be 'A1'
        $entries[2].AssetTag | Should -Be 'A3'
    }

    It 'stays a proper JSON array even with only one entry' {
        Write-SnipeAssetLog -Action 'Create' -AssetTag 'A1' -AssetId 1
        (Get-Content $script:AssetLog -Raw).TrimStart([char]0xFEFF, ' ', "`r", "`n")[0] | Should -Be '['
    }

    It 'never silently loses history when the file is damaged' {
        # This is the regression guard for the old behaviour, where an
        # unreadable file was ignored and then overwritten from empty.
        Write-SnipeAssetLog -Action 'Update' -AssetTag 'KEEPME' -AssetId 1
        'not valid json at all {' | Out-File $script:AssetLog -Encoding UTF8

        Write-SnipeAssetLog -Action 'Update' -AssetTag 'A2' -AssetId 2 -WarningAction SilentlyContinue 6>$null

        # The damaged file must still exist under a new name...
        $kept = @(Get-ChildItem (Join-Path $script:TestOutput 'Logs') -Filter 'Snipe-Asset-Changes.json.corrupt-*')
        $kept.Count | Should -Be 1

        # ...holding the text that could not be read...
        (Get-Content $kept[0].FullName -Raw) | Should -Match 'not valid json'

        # ...and the new log carries on from the entry that was being written.
        $entries = Read-AssetLog
        $entries.Count      | Should -Be 1
        $entries[0].AssetTag | Should -Be 'A2'
    }

    It 'leaves no temporary file behind' {
        Write-SnipeAssetLog -Action 'Update' -AssetTag 'A1' -AssetId 1
        @(Get-ChildItem $script:TestOutput -Filter '*.tmp' -Recurse).Count | Should -Be 0
    }
}

Describe 'Import-StaffRosterFile' {

    BeforeAll {
        # Write a roster file for a test and return its path.
        function New-RosterFile ($Lines) {
            $p = Join-Path $script:TestOutput "roster-$(Get-Random).txt"
            $Lines -join "`r`n" | Out-File -FilePath $p -Encoding UTF8
            $p
        }
    }

    It 'reads the comma format from the request' {
        $r = Import-StaffRosterFile -Path (New-RosterFile @('John Doe, Cas SRW'))
        $r.Count   | Should -Be 1
        $r[0].Name | Should -Be 'John Doe'
        $r[0].Role | Should -Be 'Cas SRW'
    }

    It 'reads the spaced-out format pasted from a Jira ticket' {
        $r = Import-StaffRosterFile -Path (New-RosterFile @('Alex Rivera-Stone    Cas SRW    Example Residence'))
        $r[0].Name     | Should -Be 'Alex Rivera-Stone'
        $r[0].Role     | Should -Be 'Cas SRW'
        $r[0].Location | Should -Be 'Example Residence'
    }

    It 'reads tab-separated lines' {
        $r = Import-StaffRosterFile -Path (New-RosterFile @("Priya Sample`tSummer Student`tExample Residence"))
        $r[0].Name | Should -Be 'Priya Sample'
        $r[0].Role | Should -Be 'Summer Student'
    }

    It 'does NOT split a name on its single space' {
        # The whole reason two spaces are required as a separator.
        $r = Import-StaffRosterFile -Path (New-RosterFile @('John Doe'))
        $r[0].Name | Should -Be 'John Doe'
        $r[0].Role | Should -Be ''
    }

    It 'keeps a role that has a space inside it' {
        $r = Import-StaffRosterFile -Path (New-RosterFile @('Priya Sample, Summer Student'))
        $r[0].Role | Should -Be 'Summer Student'
    }

    It 'skips blank lines and # comments' {
        $r = Import-StaffRosterFile -Path (New-RosterFile @(
            '# new hires for Monday', '', 'John Doe, Cas SRW', '   ', '# that is all'))
        $r.Count   | Should -Be 1
        $r[0].Name | Should -Be 'John Doe'
    }

    It 'reports the real line number so the report can point at it' {
        # Line 3 of the file, even though it is the first person.
        $r = Import-StaffRosterFile -Path (New-RosterFile @('# header', '', 'John Doe, Cas SRW'))
        $r[0].LineNumber | Should -Be 3
    }

    It 'handles the position-code style of role' {
        $r = Import-StaffRosterFile -Path (New-RosterFile @('Kim Placeholder   CSW005'))
        $r[0].Role | Should -Be 'CSW005'
    }

    It 'reads a whole mixed list in one go' {
        $r = Import-StaffRosterFile -Path (New-RosterFile @(
            'Robert Example   Cas PRW   Example Recovery Centre'
            'Alex Rivera-Stone, Cas SRW'
            'Priya Sample'
        ))
        $r.Count | Should -Be 3
        $r[2].Name | Should -Be 'Priya Sample'
    }

    # --- The layout that arrives in real life: name on one line, role on the
    # --- next, blank lines in between, trailing spaces everywhere.
    It 'pairs a name with the role on the line below it' {
        $r = Import-StaffRosterFile -Path (New-RosterFile @(
            'Marcus Fictional ', '', 'Cas PEER ', '', 'Aisha Notreal ', '', 'Cas COOK '))

        $r.Count   | Should -Be 2
        $r[0].Name | Should -Be 'Marcus Fictional'
        $r[0].Role | Should -Be 'Cas PEER'
        $r[1].Name | Should -Be 'Aisha Notreal'
        $r[1].Role | Should -Be 'Cas COOK'
    }

    It 'never treats a role line as if it were a person' {
        # The whole danger of this layout: looking up "Cas PEER" in AD.
        $r = Import-StaffRosterFile -Path (New-RosterFile @('Marcus Fictional', '', 'Cas PEER'))
        @($r | Where-Object { $_.Name -eq 'Cas PEER' }).Count | Should -Be 0
    }

    It 'keeps a three-word name together' {
        $r = Import-StaffRosterFile -Path (New-RosterFile @('Tomas Invented Third', '', 'Cas TSW'))
        $r[0].Name | Should -Be 'Tomas Invented Third'
        $r[0].Role | Should -Be 'Cas TSW'
    }

    It 'handles a hyphenated surname' {
        $r = Import-StaffRosterFile -Path (New-RosterFile @('Jordan Test-Case', '', 'Cas PEER'))
        $r[0].Name | Should -Be 'Jordan Test-Case'
    }

    It 'recognises a position code as the role, not a name' {
        $r = Import-StaffRosterFile -Path (New-RosterFile @(
            'Jane Placeholder', '', 'COOK037', '', 'Sam Invented', '', 'JANMAINT046'))

        $r.Count   | Should -Be 2
        $r[0].Role | Should -Be 'COOK037'
        $r[1].Role | Should -Be 'JANMAINT046'
    }

    It 'reads a full real-world list without losing anybody' {
        $r = Import-StaffRosterFile -Path (New-RosterFile @(
            'Marcus Fictional ', '', 'Cas PEER ', '', 'Aisha Notreal ', '', 'Cas COOK ', ''
            'Chris Madeup ', '', 'Cas SRW ', '', 'Jane Placeholder ', '', 'COOK037 ', ''
            'Tomas Invented Third ', '', 'Cas TSW ', '', 'Sam Invented ', '', 'JANMAINT046'))

        $r.Count | Should -Be 6
        @($r | Where-Object Role).Count | Should -Be 6   # everyone got their role
    }

    It 'copes with a person who has no role line' {
        $r = Import-StaffRosterFile -Path (New-RosterFile @(
            'Marcus Fictional', '', 'Cas PEER', '', 'Lonely Person', '', 'Aisha Notreal', '', 'Cas COOK'))

        # The person without a role must NOT swallow the next person's role.
        $r.Count   | Should -Be 3
        $r[1].Name | Should -Be 'Lonely Person'
        $r[1].Role | Should -Be ''
        $r[2].Name | Should -Be 'Aisha Notreal'
        $r[2].Role | Should -Be 'Cas COOK'
    }

    It 'flags a role with no name above it instead of dropping it' {
        $r = Import-StaffRosterFile -Path (New-RosterFile @('Cas SRW', '', 'Marcus Fictional', '', 'Cas PEER'))
        $orphan = @($r | Where-Object ParseNote)
        $orphan.Count      | Should -Be 1
        $orphan[0].ParseNote | Should -BeLike '*no name came before it*'
    }

    It 'still reads the one-line layout when both are mixed in one file' {
        $r = Import-StaffRosterFile -Path (New-RosterFile @(
            'John Doe, Cas SRW', 'Marcus Fictional', '', 'Cas PEER'))

        $r.Count   | Should -Be 2
        $r[0].Name | Should -Be 'John Doe'
        $r[0].Role | Should -Be 'Cas SRW'
        $r[1].Name | Should -Be 'Marcus Fictional'
        $r[1].Role | Should -Be 'Cas PEER'
    }

    It 'complains clearly when the file is not there' {
        { Import-StaffRosterFile -Path 'X:\nope\missing.txt' } | Should -Throw '*not found*'
    }

    It 'returns an empty result for a file with nothing usable in it' {
        (Import-StaffRosterFile -Path (New-RosterFile @('# only a comment', ''))).Count | Should -Be 0
    }
}

Describe 'Test-LooksLikeStaffRole' {

    It 'recognises the casual roles used on real lists' {
        foreach ($r in 'Cas SRW', 'Cas PEER', 'Cas COOK', 'Cas TSW', 'Cas MCA') {
            Test-LooksLikeStaffRole -Text $r | Should -BeTrue -Because "'$r' is a role"
        }
    }

    It 'recognises position codes' {
        foreach ($r in 'COOK037', 'JANMAINT046', 'CSW005', 'SRW416', 'PRW015', 'MCA002') {
            Test-LooksLikeStaffRole -Text $r | Should -BeTrue -Because "'$r' is a role"
        }
    }

    It 'recognises plain-language roles' {
        foreach ($r in 'Cook', 'Homemaker', 'Supervisor', 'Summer Student') {
            Test-LooksLikeStaffRole -Text $r | Should -BeTrue -Because "'$r' is a role"
        }
    }

    It 'does NOT mistake a person for a role' {
        foreach ($n in 'Marcus Fictional', 'Tomas Invented Third', 'Jordan Test-Case',
                       'Nina Fabricated', 'Casey Notional', "Sean O'Brien") {
            Test-LooksLikeStaffRole -Text $n | Should -BeFalse -Because "'$n' is a person"
        }
    }

    It 'treats an empty line as neither' {
        Test-LooksLikeStaffRole -Text '' | Should -BeFalse
    }
}

Describe 'Test-StaffRoleMatchesTitle' {

    # Every pair below was confirmed against the live domain: the left
    # side is how the role appears on a staffing list, the right side is the job
    # title actually stored on the AD account.
    It 'matches the short form on a list to the full job title in AD' {
        $real = @{
            'Cas SRW'     = 'Shelter Resource Worker'
            'Cas TSW'     = 'Tenant Support Worker'
            'Cas PEER'    = 'Peer'
            'Cas COOK'    = 'Cook'
            'Cas HRW'     = 'Harm Reduction Worker'
            'Cas MCA'     = 'Medical Care Aid'
            'Cas RBA'     = 'Residential Building Attendant'
            'Cas SCW'     = 'Shelter Case Worker'
            'COOK037'     = 'Cook'
            'JANMAINT046' = 'Janitor/ Maintenance'
            'CSW005'      = 'Clinical Support Worker'
            'SRW416'      = 'Shelter Resource Worker'
            'MCA002'      = 'Medical Care Aid'
            'PRW015'      = 'Program Resource Worker'
        }
        foreach ($role in $real.Keys) {
            Test-StaffRoleMatchesTitle -Role $role -Title $real[$role] |
                Should -BeTrue -Because "'$role' is how AD's '$($real[$role])' is written on a list"
        }
    }

    It 'strips the casual prefix, which is an employment type not a job' {
        Test-StaffRoleMatchesTitle -Role 'Cas SRW'    -Title 'Shelter Resource Worker' | Should -BeTrue
        Test-StaffRoleMatchesTitle -Role 'Casual SRW' -Title 'Shelter Resource Worker' | Should -BeTrue
        Test-StaffRoleMatchesTitle -Role 'SRW'        -Title 'Shelter Resource Worker' | Should -BeTrue
    }

    It 'ignores the number on a position code' {
        # COOK037 and COOK041 are the same job, numbered.
        Test-StaffRoleMatchesTitle -Role 'COOK037' -Title 'Cook' | Should -BeTrue
        Test-StaffRoleMatchesTitle -Role 'SRW416'  -Title 'Cook' | Should -BeFalse
    }

    It 'accepts the role spelled out in full' {
        Test-StaffRoleMatchesTitle -Role 'Shelter Resource Worker' -Title 'Shelter Resource Worker' | Should -BeTrue
        Test-StaffRoleMatchesTitle -Role 'homemaker'               -Title 'Homemaker'               | Should -BeTrue
    }

    It 'rejects a role that belongs to a different job' {
        # This is the case that matters: it means the wrong person was matched.
        Test-StaffRoleMatchesTitle -Role 'Cas SRW' -Title 'Tenant Support Worker' | Should -BeFalse
        Test-StaffRoleMatchesTitle -Role 'Cas TSW' -Title 'Shelter Resource Worker' | Should -BeFalse
        Test-StaffRoleMatchesTitle -Role 'Cas SRW' -Title 'Summer Student'          | Should -BeFalse
        Test-StaffRoleMatchesTitle -Role 'Cas HRW' -Title 'Harm Reduction Outreach' | Should -BeFalse
        Test-StaffRoleMatchesTitle -Role 'Cas MCA' -Title 'Manager'                 | Should -BeFalse
        Test-StaffRoleMatchesTitle -Role 'Cook'    -Title 'Registered Nurse'        | Should -BeFalse
    }

    It 'is deliberately forgiving about closely related titles' {
        # A sanity check that the right PERSON was matched, not an audit of HR
        # data - so a narrower or wider version of the same job passes.
        Test-StaffRoleMatchesTitle -Role 'Cas COOK' -Title 'Lead Cook'           | Should -BeTrue
        Test-StaffRoleMatchesTitle -Role 'Cas PEER' -Title 'Peer Support Worker' | Should -BeTrue
    }

    It 'says no when either side is missing' {
        Test-StaffRoleMatchesTitle -Role 'Cas SRW' -Title ''       | Should -BeFalse
        Test-StaffRoleMatchesTitle -Role ''        -Title 'Cook'   | Should -BeFalse
        # "Cas" on its own carries no job at all.
        Test-StaffRoleMatchesTitle -Role 'Cas'     -Title 'Cook'   | Should -BeFalse
    }
}

Describe 'Resolve-ADToolUserByName' {

    BeforeAll {
        # Stand in for AD: record every filter tried, and hand back whatever the
        # test queued up for that pass.
        function Get-ADUser {
            param($LDAPFilter, $Filter, $Properties, $Server, $ErrorAction)
            $script:FiltersTried += $LDAPFilter
            $key = $script:Responses.Keys | Where-Object { $LDAPFilter -like $_ } | Select-Object -First 1
            if ($key) { return $script:Responses[$key] }
            @()
        }
        function New-FakeUser ($sam) { [pscustomobject]@{ SamAccountName = $sam; DisplayName = $sam } }
    }

    BeforeEach {
        $script:FiltersTried = @()
        $script:Responses    = @{}
    }

    It 'finds someone on the exact-match pass and says so' {
        $script:Responses['*sAMAccountName=John Doe*'] = @(New-FakeUser 'john.doe')
        $r = Resolve-ADToolUserByName -Name 'John Doe'

        $r.Status               | Should -Be 'Matched'
        $r.MatchedBy            | Should -Be 'Exact'
        $r.Users[0].SamAccountName | Should -Be 'john.doe'
        $script:FiltersTried.Count | Should -Be 1   # stopped as soon as it found them
    }

    It 'falls back to the firstname.lastname username' {
        $script:Responses['(sAMAccountName=john.doe)'] = @(New-FakeUser 'john.doe')
        $r = Resolve-ADToolUserByName -Name 'John Doe'

        $r.Status    | Should -Be 'Matched'
        $r.MatchedBy | Should -Be 'UsernamePattern'
    }

    It 'builds the username from the first and last words, ignoring middle names' {
        Resolve-ADToolUserByName -Name 'Mary Jane Watson' | Out-Null
        $script:FiltersTried | Should -Contain '(sAMAccountName=mary.watson)'
    }

    It 'falls back to matching the parts of the name in any order' {
        # This is what catches AD storing "Rivera-Stone, Alex". The key is the
        # AND form so only the third pass can satisfy it - the exact-match pass
        # also mentions displayName, and a looser key here would match that too
        # and quietly test the wrong thing.
        $script:Responses['*(&(displayName=*Alex*'] = @(New-FakeUser 'alex.rivera-stone')
        $r = Resolve-ADToolUserByName -Name 'Alex Rivera-Stone'

        $r.Status    | Should -Be 'Matched'
        $r.MatchedBy | Should -Be 'NameParts'
    }

    It 'requires every word of the name to be present, not just one' {
        Resolve-ADToolUserByName -Name 'John Doe' | Out-Null
        # The third pass is the only one that uses an LDAP AND, "(&".
        $partsFilter = @($script:FiltersTried | Where-Object { $_ -like '*(&(displayName=*' })
        $partsFilter.Count | Should -Be 1
        # Both words required, so "John Smith" cannot match "John Doe".
        $partsFilter[0] | Should -BeLike '*(displayName=*John*)(displayName=*Doe*)*'
    }

    It 'reports Ambiguous rather than picking one when several people match' {
        $script:Responses['*sAMAccountName=John Doe*'] = @((New-FakeUser 'john.doe'), (New-FakeUser 'john.doe2'))
        $r = Resolve-ADToolUserByName -Name 'John Doe'

        $r.Status     | Should -Be 'Ambiguous'
        $r.Users.Count | Should -Be 2
    }

    It 'reports NotFound after trying all three passes' {
        $r = Resolve-ADToolUserByName -Name 'Ghost Person'

        $r.Status    | Should -Be 'NotFound'
        $r.MatchedBy | Should -Be ''
        $script:FiltersTried.Count | Should -Be 3
    }

    It 'escapes a name that would otherwise break the LDAP filter' {
        Resolve-ADToolUserByName -Name 'Bob (Temp)*' | Out-Null
        # The dangerous characters must arrive escaped, not raw.
        $script:FiltersTried[0] | Should -BeLike '*\28Temp\29\2a*'
        $script:FiltersTried[0] | Should -Not -BeLike '*(Temp)**'
    }

    It "leaves an apostrophe alone in a name like o'brien" {
        Resolve-ADToolUserByName -Name "Sean O'Brien" | Out-Null
        $script:FiltersTried[0] | Should -BeLike "*Sean O'Brien*"
    }
}

Describe 'Sign-off quotes (single source)' {

    It 'has a Quotes.psd1 next to the library' {
        Test-Path (Join-Path $PSScriptRoot '..\lib\Quotes.psd1') | Should -BeTrue
    }

    It 'parses into a non-empty list of quote strings' {
        $quotes = @((Import-PowerShellDataFile (Join-Path $PSScriptRoot '..\lib\Quotes.psd1')).Quotes)
        $quotes.Count | Should -BeGreaterThan 0
        foreach ($q in $quotes) { $q | Should -Not -BeNullOrEmpty }
    }

    It 'Show-DeskSideSignoff runs without error either way' {
        $Global:ADToolTrueColor = $false
        { Show-DeskSideSignoff } | Should -Not -Throw
        $Global:ADToolTrueColor = $true
        { Show-DeskSideSignoff } | Should -Not -Throw
    }

    It 'emits a 24-bit pastel ANSI escape when truecolor is available' {
        $Global:ADToolTrueColor = $true
        $out = (Show-DeskSideSignoff 6>&1 | Out-String)
        $out | Should -Match ([regex]::Escape([string][char]27) + '\[38;2;\d+;\d+;\d+m')
    }

    It 'falls back to a named colour (no escape) when truecolor is off' {
        $Global:ADToolTrueColor = $false
        $out = (Show-DeskSideSignoff 6>&1 | Out-String)
        $out | Should -Not -Match ([regex]::Escape([string][char]27) + '\[38;2;')
    }
}

Describe 'ConvertTo-WrappedLines' {

    It 'keeps a short line on one line' {
        $lines = @(ConvertTo-WrappedLines -Text 'hello world' -Width 40)
        $lines.Count | Should -Be 1
        $lines[0]    | Should -Be 'hello world'
    }

    It 'wraps a long quote so no line exceeds the width' {
        $long = '"The good man, out of the good treasure of his heart, brings forth that which is good."'
        $lines = @(ConvertTo-WrappedLines -Text $long -Width 30)
        $lines.Count | Should -BeGreaterThan 1
        foreach ($l in $lines) { $l.Length | Should -BeLessOrEqual 30 }
    }

    It 'preserves every word in order' {
        $text  = 'one two three four five six'
        $lines = @(ConvertTo-WrappedLines -Text $text -Width 12)
        (($lines -join ' ') -split '\s+') | Should -Be @('one', 'two', 'three', 'four', 'five', 'six')
    }
}

Describe 'Console styling helpers' {

    It 'Write-ToolBanner runs for a title' {
        { Write-ToolBanner 'Desk Side Toolkit' } | Should -Not -Throw
    }

    It 'Write-ToolBanner grows for a long title without throwing' {
        { Write-ToolBanner 'A Very Long Edition Title That Exceeds The Default Width' } | Should -Not -Throw
    }

    It 'Write-ToolHeader and Write-ToolMenuItem run' {
        { Write-ToolHeader 'Accounts' } | Should -Not -Throw
        { Write-ToolMenuItem -Key 1 -Label 'Do a thing' -Note 'with a note' } | Should -Not -Throw
        { Write-ToolMenuItem -Key 'B' -Label 'Back' } | Should -Not -Throw
    }
}

Describe 'Select-FromList' {

    BeforeAll {
        # Stand in for the keyboard: return whatever the test has queued up.
        function Read-Host { param($Prompt) $script:TypedInput }
    }

    It 'returns the item matching the number typed' {
        $script:TypedInput = '2'
        $chosen = Select-FromList -Items @('apple', 'banana', 'cherry') -Label { param($x) $x } 6>$null
        $chosen | Should -Be 'banana'
    }

    It 'returns nothing when 0 is typed to cancel' {
        $script:TypedInput = '0'
        Select-FromList -Items @('apple', 'banana') -Label { param($x) $x } 6>$null | Should -BeNullOrEmpty
    }

    It 'returns nothing when the number is out of range' {
        $script:TypedInput = '99'
        Select-FromList -Items @('apple', 'banana') -Label { param($x) $x } 6>$null | Should -BeNullOrEmpty
    }

    It 'returns nothing when the list is empty' {
        $script:TypedInput = '1'
        Select-FromList -Items @() -Label { param($x) $x } 6>$null | Should -BeNullOrEmpty
    }

    It 'copes with a single item, which PowerShell would otherwise unwrap' {
        $script:TypedInput = '1'
        Select-FromList -Items 'onlyone' -Label { param($x) $x } 6>$null | Should -Be 'onlyone'
    }
}


Describe 'Test-DeskSideProtectedAccount (org-agnostic profile protection)' {

    AfterEach { $env:PROTECTED_ACCOUNTS = $null }

    It 'defaults to the adm-* pattern when nothing is configured' {
        $env:PROTECTED_ACCOUNTS = $null
        Test-DeskSideProtectedAccount 'adm-jane'  | Should -BeTrue
        Test-DeskSideProtectedAccount 'alex.amog'  | Should -BeFalse
    }

    It 'reads a custom semicolon/comma-separated list (no org name baked in)' {
        $env:PROTECTED_ACCOUNTS = 'svc-*; breakglass , adminx'
        Test-DeskSideProtectedAccount 'svc-backup' | Should -BeTrue
        Test-DeskSideProtectedAccount 'breakglass' | Should -BeTrue
        Test-DeskSideProtectedAccount 'adminx'     | Should -BeTrue
        Test-DeskSideProtectedAccount 'adm-jane'   | Should -BeFalse   # not in the custom list
    }
}

Describe 'No @(Invoke-RestMethod ...) anywhere in the source' {

    # Under PowerShell 5.1, Invoke-RestMethod hands back a JSON array as ONE
    # object, so wrapping the call in @() nests it inside a second array: 20
    # results become 1 item whose contents are the 20. It fails silently - no
    # error, just wrong counts - and it has bitten this codebase twice
    # (Jira field lookup, Jira user search). Capture into a variable first,
    # then wrap: $r = Invoke-RestMethod ...; @($r).
    #
    # A mocked test cannot reproduce this: a PowerShell function stand-in
    # enumerates its output, so the bug disappears under mocking and the test
    # would pass either way. Guarding the source text is the honest check.

    It 'never wraps Invoke-RestMethod directly in @()' {
        $root = Split-Path $PSScriptRoot -Parent
        $offenders = @(
            Get-ChildItem -Path $root -Recurse -Filter *.ps1 |
                Where-Object {
                    $_.FullName -notlike '*\.git\*' -and
                    $_.FullName -notlike '*API-Examples*' -and
                    $_.FullName -notlike "$root\tests\*"   # tests name the pattern to describe it
                } |
                Select-String -Pattern '@\(\s*Invoke-RestMethod' |
                # Comments explaining the trap are not the trap.
                Where-Object { -not $_.Line.Trim().StartsWith('#') } |
                ForEach-Object { "$($_.Filename):$($_.LineNumber)" }
        )
        $offenders -join ', ' | Should -BeNullOrEmpty
    }
}

Describe 'Source files are plain ASCII' {

    # WHY THIS TEST EXISTS - it guards against a failure that looks impossible.
    #
    # Our .ps1 files are saved as UTF-8 with NO byte-order mark, and Windows
    # PowerShell 5.1 reads a file with no mark as ANSI (code page 1252), not as
    # UTF-8. So a single em dash - three bytes in UTF-8 - is read back as three
    # separate characters, and the last of them is a curly closing quote.
    # PowerShell treats curly quotes as string delimiters, so that one dash ends
    # a string early and EVERY string after it in the file is misread. The
    # script stops parsing entirely, and the error messages point at innocent
    # lines a long way from the dash.
    #
    # It looks perfectly fine in an editor, which is exactly why a person cannot
    # be trusted to catch it. Write hyphens, not dashes; straight quotes, not
    # curly ones. This test checks BYTES, so it cannot be fooled.
    # Markdown is covered too. An em dash in a .md file cannot break a parser,
    # but editing one of these files with a tool that assumes ANSI rewrites the
    # dash as three mojibake characters, and that HAS happened here twice. Same
    # rule everywhere is easier to follow than "ASCII, except in documentation".
    # KB-Drafts is not checked: it is gitignored end-user HTML, not part of the
    # toolkit.
    It 'has no byte above 127 in any .ps1, .psd1 or .md file' {
        $root = Split-Path $PSScriptRoot -Parent

        # Code page 28591 (Latin-1) maps byte n to character n exactly, for all
        # 256 values. Reading with it means "look at the raw bytes as text",
        # so anything above 127 shows up as a character above 127.
        $latin1 = [Text.Encoding]::GetEncoding(28591)

        $bad = @(Get-ChildItem -Path $root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Extension -in '.ps1', '.psd1', '.md' -and
                $_.FullName -notmatch '\\(\.git|output|KB-Drafts)\\'
            } |
            Where-Object { [IO.File]::ReadAllText($_.FullName, $latin1) -match '[^\x00-\x7F]' } |
            ForEach-Object { $_.FullName.Substring($root.Length) })

        # Joined into the message so a failure NAMES the offending files.
        ($bad -join '; ') | Should -BeNullOrEmpty
    }
}

Describe 'Feature manifests (*.tool.psd1)' {

    # Every feature on the menu is declared by a small .tool.psd1 file next to
    # its script (see AD-Toolkit.ps1). Nothing else validates them, so a typo
    # here silently changes the menu rather than producing an error.
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        $script:Manifests = @(
            Get-ChildItem -Path $root -Recurse -Filter *.tool.psd1 -File |
                ForEach-Object {
                    [pscustomobject]@{
                        Name = $_.Name
                        Data = (Import-PowerShellDataFile -Path $_.FullName)
                    }
                })
    }

    It 'finds the feature manifests' {
        $script:Manifests.Count | Should -BeGreaterThan 20
    }

    It 'gives every feature its own Order (a clash makes the menu order arbitrary)' {
        $dupes = @($script:Manifests |
            Group-Object { $_.Data.Order } |
            Where-Object { $_.Count -gt 1 } |
            ForEach-Object { "Order $($_.Name): $(($_.Group.Name) -join ', ')" })
        ($dupes -join ' | ') | Should -BeNullOrEmpty
    }

    It 'states an Audience on every feature' {
        # AD-Toolkit.ps1 falls back to 'Both' when Audience is missing, so
        # forgetting the key quietly offers a feature to everyone. For a
        # destructive feature that is a security problem, not a cosmetic one.
        $missing = @($script:Manifests |
            Where-Object { -not $_.Data.ContainsKey('Audience') } |
            ForEach-Object { $_.Name })
        ($missing -join ', ') | Should -BeNullOrEmpty
    }

    It 'uses only the three Audience values the launcher understands' {
        foreach ($m in $script:Manifests) {
            $m.Data.Audience | Should -BeIn @('Admin', 'Standard', 'Both')
        }
    }

    It 'names a script that actually exists' {
        $root = Split-Path $PSScriptRoot -Parent
        $orphans = @(Get-ChildItem -Path $root -Recurse -Filter *.tool.psd1 -File |
            Where-Object {
                $sibling = Join-Path $_.DirectoryName (($_.BaseName -replace '\.tool$', '') + '.ps1')
                -not (Test-Path $sibling)
            } | ForEach-Object { $_.Name })
        ($orphans -join ', ') | Should -BeNullOrEmpty
    }
}

Describe 'Confirm-DeskSideAction' {

    BeforeAll { function Read-Host { param($Prompt) $script:TypedInput } }

    It 'accepts y, Y, yes and YES, and ignores stray spaces' {
        foreach ($typed in 'y', 'Y', 'yes', 'YES', ' y ', "`tY ") {
            $script:TypedInput = $typed
            Confirm-DeskSideAction 'Go?' 6>$null | Should -BeTrue -Because "'$typed' is a yes"
        }
    }

    It 'treats a bare ENTER as NO - this is the whole safety property' {
        $script:TypedInput = ''
        Confirm-DeskSideAction 'Go?' 6>$null | Should -BeFalse
    }

    It 'treats anything it does not recognise as no' {
        foreach ($typed in 'n', 'no', 'maybe', '1', 'yep', 'y e s') {
            $script:TypedInput = $typed
            Confirm-DeskSideAction 'Go?' 6>$null | Should -BeFalse -Because "'$typed' is not a clear yes"
        }
    }

    It 'treats a bare ENTER as YES only when -DefaultYes is given' {
        $script:TypedInput = ''
        Confirm-DeskSideAction 'Go?' -DefaultYes 6>$null | Should -BeTrue
    }

    It '-DefaultYes still treats n and no as NO' {
        # The old "-ne 'N'" spelling read the word "no" as a YES, because it
        # only ever compared against the single letter.
        foreach ($typed in 'n', 'N', 'no', 'NO') {
            $script:TypedInput = $typed
            Confirm-DeskSideAction 'Go?' -DefaultYes 6>$null | Should -BeFalse -Because "'$typed' means no"
        }
    }

    It 'prints a cancel line on no, and stays silent with -Quiet' {
        $script:TypedInput = 'n'
        (Confirm-DeskSideAction 'Go?' -CancelNote 'nothing changed' 6>&1 | Out-String) |
            Should -Match 'Cancelled - nothing changed\.'
        (Confirm-DeskSideAction 'Go?' -Quiet 6>&1 | Out-String) | Should -Not -Match 'Cancelled'
    }

    It 'shows a suffix that matches what ENTER actually does' {
        function Read-Host { param($Prompt) $script:Asked = $Prompt; 'n' }
        Confirm-DeskSideAction 'Go?' 6>$null | Out-Null
        $script:Asked | Should -Match '\(y/N\)$'
        Confirm-DeskSideAction 'Go?' -DefaultYes 6>$null | Out-Null
        $script:Asked | Should -Match '\(Y/n\)$'
    }
}

Describe 'Confirm-DeskSideWord' {

    BeforeAll { function Read-Host { param($Prompt) $script:TypedInput } }

    It 'passes only on the exact word in capitals' {
        $script:TypedInput = 'YES'
        Confirm-DeskSideWord 'delete 3 profiles' 6>$null | Should -BeTrue
        $script:TypedInput = ' YES '
        Confirm-DeskSideWord 'delete 3 profiles' 6>$null | Should -BeTrue
    }

    It 'refuses the lower-case word - that is the point of this gate' {
        foreach ($typed in 'yes', 'Yes', 'yEs', 'y', 'Y') {
            $script:TypedInput = $typed
            Confirm-DeskSideWord 'delete 3 profiles' 6>$null | Should -BeFalse -Because "'$typed' is not YES"
        }
    }

    It 'never passes on a bare ENTER, in any mode' {
        $script:TypedInput = ''
        Confirm-DeskSideWord 'delete 3 profiles' 6>$null | Should -BeFalse
        Confirm-DeskSideWord 'delete the list' -Word 'DELETE LIST' 6>$null | Should -BeFalse
    }

    It 'honours a multi-word phrase and refuses YES in its place' {
        $script:TypedInput = 'DELETE LIST'
        Confirm-DeskSideWord 'wipe it' -Word 'DELETE LIST' 6>$null | Should -BeTrue
        $script:TypedInput = 'YES'
        Confirm-DeskSideWord 'wipe it' -Word 'DELETE LIST' 6>$null | Should -BeFalse
    }

    It 'asks for the same word it accepts' {
        # The prompt is built from -Word, so the two cannot drift apart.
        function Read-Host { param($Prompt) $script:Asked = $Prompt; '' }
        Confirm-DeskSideWord 'wipe it' -Word 'DELETE LIST' 6>$null | Out-Null
        $script:Asked | Should -Match 'DELETE LIST'
    }

    It 'has no parameter that could weaken it into a keypress' {
        # Guards the design, not just the behaviour: if somebody ever adds a
        # -DefaultYes here, this fails and they have to think about why.
        (Get-Command Confirm-DeskSideWord).Parameters.Keys | Should -Not -Contain 'DefaultYes'
    }
}

Describe 'ConvertFrom-PeopleList' {

    It 'splits on commas, semicolons and spaces' {
        (ConvertFrom-PeopleList 'a@x.com, b@x.com')  | Should -Be @('a@x.com', 'b@x.com')
        (ConvertFrom-PeopleList 'a@x.com; b@x.com')  | Should -Be @('a@x.com', 'b@x.com')
        (ConvertFrom-PeopleList 'a@x.com  b@x.com')  | Should -Be @('a@x.com', 'b@x.com')
        (ConvertFrom-PeopleList 'a@x.com,b@x.com; c@x.com') | Should -Be @('a@x.com', 'b@x.com', 'c@x.com')
    }

    It 'ignores empty entries and stray separators' {
        (ConvertFrom-PeopleList ' , a@x.com ,, ; b@x.com , ') | Should -Be @('a@x.com', 'b@x.com')
    }

    It 'gives the caller a usable array when wrapped in @(), even for one entry' {
        # @() is the house rule for list-returning helpers (see Get-SnipeHardware).
        # Without it PowerShell unwraps the single result to a plain string and
        # $one[0] would be the letter 's'.
        $one = @(ConvertFrom-PeopleList 'solo@x.com')
        $one.Count | Should -Be 1
        $one[0]    | Should -Be 'solo@x.com'
    }

    It 'counts correctly even without the @() wrapper' {
        # Existing callers write "$people.Count -eq 0" on the bare result, so
        # that has to keep working.
        (ConvertFrom-PeopleList 'solo@x.com').Count | Should -Be 1
        (ConvertFrom-PeopleList '').Count           | Should -Be 0
    }

    It 'copes with empty and null input' {
        @(ConvertFrom-PeopleList '').Count    | Should -Be 0
        @(ConvertFrom-PeopleList $null).Count | Should -Be 0
    }
}

Describe 'ConvertTo-HtmlEncodedText' {

    It 'escapes the four characters that can break markup' {
        ConvertTo-HtmlEncodedText '<a href="x">&' | Should -Be '&lt;a href=&quot;x&quot;&gt;&amp;'
    }

    It 'escapes the ampersand first, or the other escapes get double-escaped' {
        ConvertTo-HtmlEncodedText '&lt;' | Should -Be '&amp;lt;'
    }

    It 'turns null into an empty string rather than failing' {
        ConvertTo-HtmlEncodedText $null | Should -Be ''
    }
}

Describe 'Write-DeskSideHtmlReport' {

    BeforeAll {
        function Read-Host { param($Prompt) 'n' }
        $script:Report = Join-Path $script:TestOutput 'report.html'
    }

    It 'writes one row per object, in the column order given' {
        $rows = @(
            [pscustomobject]@{ Host = 'PC1'; User = 'ann' }
            [pscustomobject]@{ Host = 'PC2'; User = 'bob' }
        )
        Write-DeskSideHtmlReport -Rows $rows -Columns 'Host', 'User' -Title 'T' -Path $script:Report -NoPrompt | Out-Null
        $html = Get-Content $script:Report -Raw
        ([regex]::Matches($html, '<tr>')).Count | Should -Be 3      # header + 2 rows
        $html | Should -Match '<td>PC1</td><td>ann</td>'
    }

    It 'escapes every cell, so a hostname of <script> cannot break the page' {
        $rows = @([pscustomobject]@{ Host = '<script>alert(1)</script>'; User = 'a&b' })
        Write-DeskSideHtmlReport -Rows $rows -Columns 'Host', 'User' -Title 'T' -Path $script:Report -NoPrompt | Out-Null
        $html = Get-Content $script:Report -Raw
        $html | Should -Not -Match '<script>alert'
        $html | Should -Match '&lt;script&gt;'
        $html | Should -Match 'a&amp;b'
    }

    It 'writes a valid, empty table for zero rows' {
        Write-DeskSideHtmlReport -Rows @() -Columns 'Host' -Title 'T' -Path $script:Report -NoPrompt | Out-Null
        $html = Get-Content $script:Report -Raw
        $html | Should -Match '<table>'
        ([regex]::Matches($html, '<tr>')).Count | Should -Be 1      # header only
    }

    It 'does not prompt when -NoPrompt is given' {
        function Read-Host { param($Prompt) throw 'should not have asked' }
        { Write-DeskSideHtmlReport -Rows @() -Columns 'Host' -Title 'T' -Path $script:Report -NoPrompt } |
            Should -Not -Throw
    }
}

Describe 'Write-DeskSideFailure' {

    It 'prints the message and writes exactly one Failed row' {
        $err = try { throw 'Access denied' } catch { $_ }
        Write-DeskSideFailure 'Move failed' 'Move User' 'jsmith' $err -Context 'OU=X' 6>$null
        $row = Import-Csv (Join-Path $script:TestOutput 'Logs\AD-Toolkit-Actions.csv') | Select-Object -Last 1
        $row.Result  | Should -Be 'Failed'
        $row.Action  | Should -Be 'Move User'
        $row.Target  | Should -Be 'jsmith'
        $row.Details | Should -Be 'OU=X - Access denied'
    }

    It 'leaves out the context separator when there is no context' {
        $err = try { throw 'Boom' } catch { $_ }
        Write-DeskSideFailure 'It failed' 'Some Action' 'target1' $err 6>$null
        $row = Import-Csv (Join-Path $script:TestOutput 'Logs\AD-Toolkit-Actions.csv') | Select-Object -Last 1
        $row.Details | Should -Be 'Boom'
    }

    It 'copes with no error record at all' {
        { Write-DeskSideFailure 'It failed' 'Some Action' 'target2' 6>$null } | Should -Not -Throw
        $row = Import-Csv (Join-Path $script:TestOutput 'Logs\AD-Toolkit-Actions.csv') | Select-Object -Last 1
        $row.Result | Should -Be 'Failed'
    }

    It 'shows the reason on screen, not only in the log' {
        $err = try { throw 'Disk is full' } catch { $_ }
        (Write-DeskSideFailure 'Copy failed' 'Copy' 't' $err 6>&1 | Out-String) |
            Should -Match 'Copy failed: Disk is full'
    }
}

Describe 'Get-TrmmAgent' {

    BeforeAll {
        $env:TRMM_APIKEY = 'test-key'
        $env:TRMM_URL    = 'https://api.example.com'
        function New-FakeAgent ($hostname, $status) {
            [pscustomobject]@{ hostname = $hostname; status = $status; agent_id = "id-$hostname" }
        }
    }
    AfterAll { $env:TRMM_APIKEY = $null; $env:TRMM_URL = $null }

    It 'reports Ok = false when the API call fails, so the caller knows to stop' {
        function Invoke-RestMethod { throw 'connection refused' }
        $lookup = Get-TrmmAgent 6>$null
        $lookup.Ok | Should -BeFalse
        @($lookup.Agents).Count | Should -Be 0
    }

    It 'reports Ok = true with an empty list when nothing matched' {
        # "The lookup died" and "nothing matched" mean opposite things to the
        # caller, so they must never look alike.
        function Invoke-RestMethod { @((New-FakeAgent 'PC1' 'online')) }
        $lookup = Get-TrmmAgent -HostnameLike 'NOSUCHHOST' 6>$null
        $lookup.Ok | Should -BeTrue
        @($lookup.Agents).Count | Should -Be 0
    }

    It 'survives being wrapped in @() - the trap a leading comma would create' {
        # @() is how this codebase reads every list, so it has to be safe here.
        # A comma-wrapped return would make the count below 1, holding an array.
        function Invoke-RestMethod { @((New-FakeAgent 'PC1' 'online'), (New-FakeAgent 'PC2' 'offline')) }
        $lookup = Get-TrmmAgent 6>$null
        @($lookup.Agents).Count      | Should -Be 2
        @($lookup.Agents)[0].hostname | Should -Be 'PC1'
    }

    It 'keeps a single match usable rather than unwrapping it' {
        function Invoke-RestMethod { @((New-FakeAgent 'PC1' 'online'), (New-FakeAgent 'PC2' 'offline')) }
        $lookup = Get-TrmmAgent -HostnameLike 'PC1' 6>$null
        @($lookup.Agents).Count       | Should -Be 1
        @($lookup.Agents)[0].hostname | Should -Be 'PC1'
    }

    It 'treats an empty keyword and * as the whole fleet' {
        function Invoke-RestMethod { @((New-FakeAgent 'PC1' 'online'), (New-FakeAgent 'PC2' 'offline')) }
        @((Get-TrmmAgent 6>$null).Agents).Count                   | Should -Be 2
        @((Get-TrmmAgent -HostnameLike '' 6>$null).Agents).Count  | Should -Be 2
        @((Get-TrmmAgent -HostnameLike '*' 6>$null).Agents).Count | Should -Be 2
    }

    It 'filters to online machines with -OnlineOnly' {
        function Invoke-RestMethod { @((New-FakeAgent 'PC1' 'online'), (New-FakeAgent 'PC2' 'offline')) }
        $lookup = Get-TrmmAgent -OnlineOnly 6>$null
        @($lookup.Agents).Count       | Should -Be 1
        @($lookup.Agents)[0].hostname | Should -Be 'PC1'
    }

    It 'matches a keyword literally, not as a regular expression' {
        function Invoke-RestMethod { @((New-FakeAgent 'PC-1' 'online'), (New-FakeAgent 'PCX1' 'online')) }
        # Unescaped, the '.' in 'PC.1' would match any character and so would
        # match BOTH machines. Escaped, it matches neither.
        $lookup = Get-TrmmAgent -HostnameLike 'PC.1' 6>$null
        $lookup.Ok | Should -BeTrue
        @($lookup.Agents).Count | Should -Be 0
    }
}

Describe 'Find-TrmmAgentByName' {

    BeforeAll {
        $env:TRMM_APIKEY = 'test-key'
        $env:TRMM_URL    = 'https://api.example.com'
        function New-FakeAgent ($hostname, $status) {
            [pscustomobject]@{ hostname = $hostname; status = $status; agent_id = "id-$hostname" }
        }
    }
    AfterAll { $env:TRMM_APIKEY = $null; $env:TRMM_URL = $null }

    It 'returns the one agent on an exact match' {
        function Invoke-RestMethod { @((New-FakeAgent 'PC1' 'online'), (New-FakeAgent 'PC2' 'online')) }
        (Find-TrmmAgentByName -Hostname 'PC1' 6>$null).agent_id | Should -Be 'id-PC1'
    }

    It 'returns nothing and suggests near matches when nothing matches exactly' {
        function Invoke-RestMethod { @((New-FakeAgent 'PC1' 'online'), (New-FakeAgent 'PC2' 'online')) }
        Find-TrmmAgentByName -Hostname 'PC' 6>$null | Should -BeNullOrEmpty
        (Find-TrmmAgentByName -Hostname 'PC' 6>&1 | Out-String) | Should -Match 'Did you mean: PC1'
    }

    It 'refuses to guess when two machines share the name' {
        function Invoke-RestMethod { @((New-FakeAgent 'PC1' 'online'), (New-FakeAgent 'PC1' 'offline')) }
        Find-TrmmAgentByName -Hostname 'PC1' 6>$null | Should -BeNullOrEmpty
    }

    It 'rejects an offline agent only when -RequireOnline is given' {
        function Invoke-RestMethod { @((New-FakeAgent 'PC1' 'offline')) }
        (Find-TrmmAgentByName -Hostname 'PC1' 6>$null).agent_id | Should -Be 'id-PC1'
        Find-TrmmAgentByName -Hostname 'PC1' -RequireOnline 6>$null | Should -BeNullOrEmpty
    }

    It 'returns nothing when the lookup itself failed' {
        function Invoke-RestMethod { throw 'connection refused' }
        Find-TrmmAgentByName -Hostname 'PC1' 6>$null | Should -BeNullOrEmpty
    }
}

Describe 'Get-DeskSideAdminUpn' {

    BeforeEach {
        $script:DeskSideAdminUpn = $null       # forget any earlier answer
        $env:EXO_ADMIN_UPN = $null
        $script:AskCount = 0
    }
    AfterAll { $script:DeskSideAdminUpn = $null; $env:EXO_ADMIN_UPN = $null }

    It 'returns what was typed' {
        function Read-Host { param($Prompt) 'admin.me@contoso.com' }
        Get-DeskSideAdminUpn 6>$null | Should -Be 'admin.me@contoso.com'
    }

    It 'asks only once and reuses the answer' {
        function Read-Host { param($Prompt) $script:AskCount++; 'admin.me@contoso.com' }
        Get-DeskSideAdminUpn 6>$null | Out-Null
        Get-DeskSideAdminUpn 6>$null | Out-Null
        Get-DeskSideAdminUpn 6>$null | Out-Null
        $script:AskCount | Should -Be 1
    }

    It 'falls back to EXO_ADMIN_UPN when the operator just presses ENTER' {
        $env:EXO_ADMIN_UPN = 'preset@contoso.com'
        function Read-Host { param($Prompt) '' }
        Get-DeskSideAdminUpn 6>$null | Should -Be 'preset@contoso.com'
    }

    It 'returns nothing when there is no answer and no default' {
        function Read-Host { param($Prompt) '' }
        Get-DeskSideAdminUpn 6>$null | Should -BeNullOrEmpty
    }
}

Describe 'Get-DeskSideRemoteProgramDataLine' {

    It 'produces a line that parses as PowerShell and sets $DeskSideData' {
        $line = Get-DeskSideRemoteProgramDataLine
        $err = $null
        [System.Management.Automation.Language.Parser]::ParseInput($line, [ref]$null, [ref]$err) | Out-Null
        $err | Should -BeNullOrEmpty
        $line | Should -Match '^\$DeskSideData\s*='
    }

    It 'leaves the variables unexpanded so the FAR END resolves them' {
        # If this ever came back with a resolved path, remote scripts would be
        # told to use the operator's folder rather than their own.
        $line = Get-DeskSideRemoteProgramDataLine
        $line | Should -Match '\$env:DESKSIDE_PROGRAMDATA'
        $line | Should -Match "'C:\\ProgramData\\DeskSideToolkit'"
    }
}

