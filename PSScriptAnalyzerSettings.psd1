<#
    Settings for PSScriptAnalyzer - the PowerShell code checker.

    Run it with:  .\Run-Tests.ps1

    The rules listed under ExcludeRules are switched OFF because they disagree
    with a choice this project made on purpose. Every one has a reason written
    next to it. Do NOT add to this list just to make a warning go away - a
    warning is usually telling you something true. Add to it only when the rule
    genuinely does not apply here, and say why.
#>
@{
    ExcludeRules = @(
        # This toolkit IS a console menu. Write-Host is how it draws that menu
        # and colours warnings, which is exactly what this rule tells you not to
        # do in a reusable module. It is the right call for a module and the
        # wrong call for us.
        'PSAvoidUsingWriteHost'

        # This rule wants -WhatIf / -Confirm on anything that changes state.
        # Our destructive features instead print the full list of what they are
        # about to do and make you type a confirmation. Same protection, and it
        # suits people who run these from a menu rather than a script.
        'PSUseShouldProcessForStateChangingFunctions'

        # Wants singular nouns (Get-MyTicket rather than Get-MyTickets). Plural
        # names are baked into feature manifests and documentation, and renaming
        # a feature script means renaming its .tool.psd1 too. Not worth breaking
        # working menu entries over a naming preference.
        'PSUseSingularNouns'

        # Flags Invoke-TrmmRequest GET 'agents/' and asks for
        # Invoke-TrmmRequest -Method GET -Path 'agents/'. The short form reads
        # better for a call made dozens of times, and the parameter order is
        # fixed by the function itself.
        'PSAvoidUsingPositionalParameters'
    )
}
