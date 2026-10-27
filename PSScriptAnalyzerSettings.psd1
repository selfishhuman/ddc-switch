@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # ddc.ps1 is an interactive CLI; console output is its purpose.
        'PSAvoidUsingWriteHost'
        # Get-Monitors returns a collection of monitors; the plural reads naturally.
        'PSUseSingularNouns'
        # Set-Input / Set-Preset are invoked by hotkeys and tests with no interactive user,
        # so -WhatIf/-Confirm would add nothing.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
