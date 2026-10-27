# Pester 5+ tests for the pure logic in ddc-lib.ps1. No monitors needed: Set-Preset takes
# injected config + fake monitors, and Set-Input (the only call into dxva2) is mocked.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\ddc-lib.ps1')

    $script:Rules = @(
        @{ Name = 'Wide'; Match = @{ MinAspect = 2.0 }; PC = 0x08; Laptop = 0x05 }
        @{ Name = 'Exact'; Match = @{ Width = 1920; Height = 1200 }; PC = 0x0F }
        @{ Name = 'Std'; Match = @{}; PC = 0x0F; Laptop = 0x11 }
    )
    $script:Config = @{
        Monitors = $script:Rules
        Presets  = @{
            Split  = @{ Wide = 'Laptop'; Std = 'PC' }
            NoCode = @{ Std = 'Tablet' }
        }
    }
    function New-FakeMonitor([string]$Model, [int]$InputCode, [bool]$DdcOk = $true) {
        [PSCustomObject]@{ Model = $Model; Handle = [IntPtr]::Zero; Input = $InputCode; DdcOk = $DdcOk }
    }
}

Describe 'Resolve-MonitorName' {
    It 'matches a 21:9 ultrawide by MinAspect' {
        Resolve-MonitorName 3440 1440 $script:Rules | Should -Be 'Wide'
    }
    It 'matches an exact resolution' {
        Resolve-MonitorName 1920 1200 $script:Rules | Should -Be 'Exact'
    }
    It 'falls back to the empty-Match rule for 16:9' {
        Resolve-MonitorName 2560 1440 $script:Rules | Should -Be 'Std'
    }
    It 'returns the first matching rule when several match' {
        $rules = @( @{ Name = 'First'; Match = @{} }, @{ Name = 'Second'; Match = @{} } )
        Resolve-MonitorName 2560 1440 $rules | Should -Be 'First'
    }
    It 'returns $null when no rule matches' {
        $rules = @( @{ Name = 'Wide'; Match = @{ MinAspect = 2.0 } } )
        Resolve-MonitorName 2560 1440 $rules | Should -BeNullOrEmpty
    }
    It 'honours MaxAspect' {
        $rules = @( @{ Name = 'Portrait'; Match = @{ MaxAspect = 1.0 } } )
        Resolve-MonitorName 1440 2560 $rules | Should -Be 'Portrait'
        Resolve-MonitorName 2560 1440 $rules | Should -BeNullOrEmpty
    }
}

Describe 'Get-InputCodeTable' {
    It 'maps each monitor Name to its side codes, excluding Name and Match' {
        $t = Get-InputCodeTable $script:Config
        $t['Wide']['Laptop'] | Should -Be 0x05
        $t['Std']['PC']      | Should -Be 0x0F
        $t['Wide'].Keys      | Should -Not -Contain 'Match'
        $t['Wide'].Keys      | Should -Not -Contain 'Name'
    }
}

Describe 'ConvertTo-HotKey' {
    It 'parses Ctrl+Alt+digit with MOD_NOREPEAT' {
        $hk = ConvertTo-HotKey 'Ctrl+Alt+1'
        $hk.Vk        | Should -Be 0x31
        $hk.Modifiers | Should -Be (0x0002 -bor 0x0001 -bor 0x4000)
    }
    It 'parses letters case-insensitively' {
        (ConvertTo-HotKey 'ctrl+alt+p').Vk | Should -Be 0x50
    }
    It 'parses Shift, Win and F-keys' {
        $hk = ConvertTo-HotKey 'Shift+Win+F12'
        $hk.Vk        | Should -Be 0x7B
        $hk.Modifiers | Should -Be (0x0004 -bor 0x0008 -bor 0x4000)
    }
    It 'tolerates spaces around +' {
        (ConvertTo-HotKey 'Ctrl + Alt + L').Vk | Should -Be 0x4C
    }
    It 'rejects <Keys>' -ForEach @(
        @{ Keys = 'Ctrl+Alt' }       # no key
        @{ Keys = '1' }              # no modifier
        @{ Keys = 'Ctrl+1+2' }       # two keys
        @{ Keys = 'Ctrl+Alt+Enter' } # unsupported key
        @{ Keys = 'Ctrl+F25' }       # out of range
    ) {
        { ConvertTo-HotKey $Keys } | Should -Throw
    }
}

Describe 'Test-NetworkToken' {
    It 'rejects <Token>' -ForEach @(
        @{ Token = '' }
        @{ Token = 'CHANGE-ME' }
        @{ Token = 'CHANGE-ME-but-long-enough' }
        @{ Token = 'short' }
        @{ Token = 'has:colon-and-long-enough' }
    ) {
        Test-NetworkToken $Token | Should -BeFalse
    }
    It 'accepts a long random token' {
        Test-NetworkToken 'k3J9vQ2xLp8ZrT4wYb6N' | Should -BeTrue
    }
}

Describe 'Set-Preset' {
    BeforeEach {
        Mock Set-Input { $true }
    }

    It 'switches a monitor that is on a different input' {
        $mons = @( (New-FakeMonitor 'Wide' 0x08), (New-FakeMonitor 'Std' 0x0F) )
        $r = Set-Preset -Name 'Split' -Config $script:Config -Monitors $mons
        ($r -join "`n") | Should -Match '\[OK\] Wide\s+-> Laptop \(0x05\)'
        Should -Invoke Set-Input -Times 1 -Exactly -ParameterFilter { $Value -eq 0x05 }
    }

    It 'does not re-send an input the monitor already shows (no flicker)' {
        $mons = @( (New-FakeMonitor 'Wide' 0x08), (New-FakeMonitor 'Std' 0x0F) )
        $r = Set-Preset -Name 'Split' -Config $script:Config -Monitors $mons
        ($r -join "`n") | Should -Match '\[SAME\] Std\s+already PC'
        Should -Invoke Set-Input -Times 0 -Exactly -ParameterFilter { $Value -eq 0x0F }
    }

    It 'skips a monitor this machine cannot reach over DDC' {
        $mons = @( (New-FakeMonitor 'Wide' 0 -DdcOk $false), (New-FakeMonitor 'Std' 0x11) )
        $r = Set-Preset -Name 'Split' -Config $script:Config -Monitors $mons
        ($r -join "`n") | Should -Match '\[SKIP\] Wide not connected / no DDC'
        Should -Invoke Set-Input -Times 1 -Exactly
    }

    It 'skips a side with no input code in the config' {
        $mons = @( (New-FakeMonitor 'Std' 0x0F) )
        $r = Set-Preset -Name 'NoCode' -Config $script:Config -Monitors $mons
        $r | Should -Be '[SKIP] Std Tablet (no code in config)'
        Should -Invoke Set-Input -Times 0 -Exactly
    }

    It 'reports [FAIL] when the monitor rejects the command' {
        Mock Set-Input { $false }
        $mons = @( (New-FakeMonitor 'Wide' 0x08), (New-FakeMonitor 'Std' 0x0F) )
        $r = Set-Preset -Name 'Split' -Config $script:Config -Monitors $mons
        ($r -join "`n") | Should -Match '\[FAIL\] Wide'
    }

    It 'throws on an unknown preset' {
        { Set-Preset -Name 'Nope' -Config $script:Config -Monitors @((New-FakeMonitor 'Std' 0x0F)) } |
            Should -Throw "*Preset 'Nope' not found*"
    }
}

Describe 'Import-Config' {
    It 'loads the shipped example config' {
        $cfg = Import-Config -Path (Join-Path $PSScriptRoot '..\config.example.psd1')
        @($cfg.Monitors).Count | Should -BeGreaterThan 0
        foreach ($h in $cfg.Hotkeys) { { ConvertTo-HotKey $h.Keys } | Should -Not -Throw }
        foreach ($h in $cfg.Hotkeys) { $cfg.Presets.Keys | Should -Contain $h.Preset }
        Test-NetworkToken $cfg.Network.Token | Should -BeFalse   # placeholder must never pass
    }
    It 'rejects the old hashtable Monitors format with a helpful message' {
        $old = Join-Path $TestDrive 'old.psd1'
        Set-Content -Path $old -Value "@{ Monitors = @{ 'X' = @{ PC = 1 } }; Presets = @{} }"
        { Import-Config -Path $old } | Should -Throw '*old Monitors format*'
    }
    It 'points at the example when the config is missing' {
        { Import-Config -Path (Join-Path $TestDrive 'missing.psd1') } | Should -Throw '*config.example.psd1*'
    }
}
