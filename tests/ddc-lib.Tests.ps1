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
    It 'parses named keys (Space, arrows)' {
        (ConvertTo-HotKey 'Ctrl+Alt+Space').Vk | Should -Be 0x20
        (ConvertTo-HotKey 'Ctrl+Alt+Up').Vk    | Should -Be 0x26
        (ConvertTo-HotKey 'Ctrl+Alt+Down').Vk  | Should -Be 0x28
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

Describe 'ConvertFrom-CapabilitiesString' {
    BeforeAll {
        # Real reply from a PRISM+ X340 PRO (MStar scaler).
        $script:X340Caps = '(prot(monitor)type(lcd)MStarcmds(01 02 03 07 0C E3 F3)vcp(02 04 05 08 10 12 14(05 08 0B 0C) 16 18 1A 52 60( 11 12 0F 10) AC AE B2 B6 C6 C8 C9 D6(01 04 05) DC(00 02 03 05 ) DF FD)mccs_ver(2.1)mswhql(1))'
    }
    It 'lists continuous codes with no values' {
        $c = ConvertFrom-CapabilitiesString $script:X340Caps
        $c.ContainsKey(0x10) | Should -BeTrue
        @($c[0x10]).Count     | Should -Be 0
    }
    It 'parses value lists, including stray spaces' {
        $c = ConvertFrom-CapabilitiesString $script:X340Caps
        $c[0x14] | Should -Be @(0x05, 0x08, 0x0B, 0x0C)
        $c[0x60] | Should -Be @(0x11, 0x12, 0x0F, 0x10)
        $c[0xDC] | Should -Be @(0x00, 0x02, 0x03, 0x05)
    }
    It 'ignores the cmds() section' {
        $c = ConvertFrom-CapabilitiesString $script:X340Caps
        $c.ContainsKey(0xE3) | Should -BeFalse
        $c.ContainsKey(0x62) | Should -BeFalse
    }
    It 'returns $null without a vcp section' {
        ConvertFrom-CapabilitiesString '(prot(monitor)type(lcd))' | Should -BeNullOrEmpty
        ConvertFrom-CapabilitiesString '' | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-DdcAction' {
    It 'treats a plain name as a preset' {
        $a = ConvertFrom-DdcAction 'AllPC'
        $a.Kind | Should -Be 'Preset'; $a.Name | Should -Be 'AllPC'
    }
    It 'parses Set with a target monitor' {
        $a = ConvertFrom-DdcAction 'Set:Brightness=+10@X340 PRO'
        $a.Kind | Should -Be 'Set'; $a.Feature | Should -Be 'Brightness'; $a.Value | Should -Be '+10'; $a.Target | Should -Be 'X340 PRO'
    }
    It 'defaults the target to All' {
        (ConvertFrom-DdcAction 'Toggle:Reading').Target | Should -Be 'All'
    }
    It 'rejects a malformed Set' {
        { ConvertFrom-DdcAction 'Set:Brightness' } | Should -Throw '*Set:<Feature>=<Value>*'
    }
}

Describe 'Resolve-FeatureValue' {
    It 'clamps relative brightness to 0..Max' {
        (Resolve-FeatureValue -Feature Brightness -Value '+30' -Current 90 -Max 100).Value | Should -Be 100
        (Resolve-FeatureValue -Feature Brightness -Value '-30' -Current 10 -Max 100).Value | Should -Be 0
    }
    It 'scales percentages to the monitor range' {
        (Resolve-FeatureValue -Feature Contrast -Value '50%' -Current 0 -Max 200).Value | Should -Be 100
    }
    It 'resolves a picture-mode name the monitor supports' {
        $r = Resolve-FeatureValue -Feature PictureMode -Value 'game' -Current 0 -Names $script:Features.PictureMode.Names -Allowed 0, 2, 3, 5
        $r.Ok | Should -BeTrue; $r.Value | Should -Be 5
    }
    It 'refuses a value the monitor does not advertise' {
        $r = Resolve-FeatureValue -Feature PictureMode -Value 'Sports' -Current 0 -Names $script:Features.PictureMode.Names -Allowed 0, 2, 3, 5
        $r.Ok | Should -BeFalse
    }
    It 'cycles Next / Prev through the advertised values' {
        $n = $script:Features.PictureMode.Names
        (Resolve-FeatureValue -Feature PictureMode -Value Next -Current 5 -Names $n -Allowed 0, 2, 3, 5).Value | Should -Be 0
        (Resolve-FeatureValue -Feature PictureMode -Value Prev -Current 0 -Names $n -Allowed 0, 2, 3, 5).Value | Should -Be 5
    }
    It 'rejects junk' {
        (Resolve-FeatureValue -Feature Brightness -Value 'bright' -Current 0 -Max 100).Ok | Should -BeFalse
    }
}

Describe 'Set-MonitorFeature' {
    BeforeAll { $script:SettleMs = @{ Range = 0; List = 0 } }
    BeforeEach {
        Mock Set-Vcp { $true }
        Mock Get-Vcp { [PSCustomObject]@{ Ok = $true; Current = 30; Max = 100 } }
        $script:Mon  = [PSCustomObject]@{ Model = 'Wide'; Handle = [IntPtr]::Zero; DdcOk = $true }
        $script:Caps = @{ 0x10 = @(); 0x12 = @(); 0xDC = @(0, 2, 3, 5) }
    }
    It 'writes a changed value' {
        $r = Set-MonitorFeature -Monitor $script:Mon -Feature Brightness -Value '+10' -Caps $script:Caps
        $r | Should -Be '[OK] Wide Brightness 30 -> 40'
        Should -Invoke Set-Vcp -Times 1 -Exactly -ParameterFilter { $Code -eq 0x10 -and $Value -eq 40 }
    }
    It 'does not write an unchanged value' {
        $r = Set-MonitorFeature -Monitor $script:Mon -Feature Brightness -Value '30' -Caps $script:Caps
        $r | Should -Match '^\[SAME\]'
        Should -Invoke Set-Vcp -Times 0 -Exactly
    }
    It 'skips a feature the monitor does not advertise' {
        $r = Set-MonitorFeature -Monitor $script:Mon -Feature Volume -Value '50' -Caps $script:Caps
        $r | Should -Match 'not supported'
        Should -Invoke Set-Vcp -Times 0 -Exactly
    }
    It 'without capabilities, skips a nonsense range' {
        Mock Get-Vcp { [PSCustomObject]@{ Ok = $true; Current = 50; Max = 65535 } }
        $r = Set-MonitorFeature -Monitor $script:Mon -Feature Volume -Value '+10' -Caps $null
        $r | Should -Match 'not supported'
        Should -Invoke Set-Vcp -Times 0 -Exactly
    }
    It 'refuses features outside the whitelist' {
        Set-MonitorFeature -Monitor $script:Mon -Feature PowerMode -Value '4' -Caps $script:Caps | Should -Match 'unknown feature'
        Should -Invoke Set-Vcp -Times 0 -Exactly
    }
    It 'uses a per-monitor vendor code and always writes picture mode' {
        Mock Get-Vcp { [PSCustomObject]@{ Ok = $true; Current = 0; Max = 9 } }
        $cfg = @{ Monitors = @( @{ Name = 'Wide'; Match = @{}; Codes = @{ PictureMode = 0xE0 }; PictureModes = @{ Standard = 0; Reading = 5 } } ) }
        $caps = @{ 0xE0 = @() }
        Set-MonitorFeature -Monitor $script:Mon -Feature PictureMode -Value 'Reading' -Config $cfg -Caps $caps | Should -Match '^\[OK\]'
        Should -Invoke Set-Vcp -Times 1 -Exactly -ParameterFilter { $Code -eq 0xE0 -and $Value -eq 5 }
        # Readback says Standard, but the mode is re-sent anyway (monitors misreport it).
        Set-MonitorFeature -Monitor $script:Mon -Feature PictureMode -Value 'Standard' -Config $cfg -Caps $caps | Should -Match '^\[OK\]'
        Should -Invoke Set-Vcp -Times 1 -Exactly -ParameterFilter { $Code -eq 0xE0 -and $Value -eq 0 }
        # A code the monitor doesn't advertise is refused, vendor or not.
        Set-MonitorFeature -Monitor $script:Mon -Feature PictureMode -Value 'Reading' -Config $cfg -Caps @{ 0x10 = @() } | Should -Match 'not supported'
    }
    It 'uses per-monitor mode names from config' {
        Mock Get-Vcp { [PSCustomObject]@{ Ok = $true; Current = 0; Max = 255 } }
        $cfg = @{ Monitors = @( @{ Name = 'Wide'; Match = @{}; PictureModes = @{ Office = 0x00; Reading = 0x02 } } ) }
        $r = Set-MonitorFeature -Monitor $script:Mon -Feature PictureMode -Value 'Reading' -Config $cfg -Caps $script:Caps
        $r | Should -Be '[OK] Wide PictureMode Office -> Reading'
        Should -Invoke Set-Vcp -Times 1 -Exactly -ParameterFilter { $Code -eq 0xDC -and $Value -eq 2 }
    }
}

Describe 'Calibration curves' {
    BeforeAll { $script:Curve = @( @(0.0, 10.0), @(50.0, 30.0), @(100.0, 80.0) ) }
    It 'maps levels to raw values piecewise' {
        ConvertTo-RawValue $script:Curve 0   | Should -Be 10
        ConvertTo-RawValue $script:Curve 25  | Should -Be 20
        ConvertTo-RawValue $script:Curve 75  | Should -Be 55
        ConvertTo-RawValue $script:Curve 120 | Should -Be 80
    }
    It 'inverts raw values back to levels' {
        ConvertFrom-RawValue $script:Curve 20 | Should -Be 25
        ConvertFrom-RawValue $script:Curve 55 | Should -Be 75
        ConvertFrom-RawValue $script:Curve 5  | Should -Be 0
        ConvertFrom-RawValue $script:Curve 99 | Should -Be 100
    }
    It 'makes a calibrated Brightness step move on the shared scale and floor together' {
        $script:SettleMs = @{ Range = 0; List = 0 }
        $script:Raw = 30
        Mock Get-Vcp { [PSCustomObject]@{ Ok = $true; Current = $script:Raw; Max = 100 } }
        Mock Set-Vcp { $script:Raw = $Value; $true }
        $cfg = @{ Monitors = @( @{ Name = 'Wide'; Match = @{} } ); Calibration = @{ Wide = @{ Brightness = $script:Curve } } }
        $mon = [PSCustomObject]@{ Model = 'Wide'; Handle = [IntPtr]::Zero; DdcOk = $true }
        Set-MonitorFeature -Monitor $mon -Feature Brightness -Value '-10' -Config $cfg -Caps @{ 0x10 = @() } | Should -Be '[OK] Wide Brightness 50 (raw 30) -> 40 (raw 26)'
        Set-MonitorFeature -Monitor $mon -Feature Brightness -Value '0' -Config $cfg -Caps @{ 0x10 = @() } | Out-Null
        $script:Raw | Should -Be 10   # level 0 = this panel's calibrated floor, not raw 0
    }
}

Describe 'Get-ProfileSetting' {
    It 'merges a per-monitor block and drops $null overrides' {
        $p = @{ PictureMode = 'Reading'; Brightness = 20; 'Wide' = @{ PictureMode = $null; ColorTemp = 'User1' } }
        $s = Get-ProfileSetting $p 'Wide'
        $s.Contains('PictureMode') | Should -BeFalse
        $s['ColorTemp'] | Should -Be 'User1'
        $s['Brightness'] | Should -Be '20'
        (Get-ProfileSetting $p 'Std')['PictureMode'] | Should -Be 'Reading'
    }
}

Describe 'Saved looks' {
    BeforeEach {
        $script:SavedPath = Join-Path $TestDrive 'saved.psd1'
        if (Test-Path $script:SavedPath) { Remove-Item $script:SavedPath }
        $script:SettleMs = @{ Range = 0; List = 0 }
        $script:Vcp = @{ 0x10 = 40; 0x12 = 55; 0x14 = 5 }
        Mock Get-MonitorCapabilities { @{ 0x10 = @(); 0x12 = @(); 0x14 = @(5, 11) } }
        Mock Get-Vcp { [PSCustomObject]@{ Ok = $true; Current = $script:Vcp[$Code]; Max = 100 } }
        Mock Set-Vcp { $script:Vcp[$Code] = $Value; $true }
        $script:LookCfg = @{ Monitors = @( @{ Name = 'Wide'; Match = @{} } ) }
        $script:Mons = @( [PSCustomObject]@{ Model = 'Wide'; Handle = [IntPtr]::Zero; DdcOk = $true; Input = 8 } )
    }
    It 'round-trips through saved.psd1' {
        $s = @{ Looks = @{ "Day's" = @{ Wide = @{ Brightness = 40 } } }; Calibration = @{ Wide = @{ Brightness = @(@(0, 5), @(100, 90)) } } }
        Write-DdcSaved $s
        $r = Read-DdcSaved
        $r.Looks["Day's"].Wide.Brightness | Should -Be 40
        $r.Calibration.Wide.Brightness[1][1] | Should -Be 90
    }
    It 'saves the current settings and applies them later' {
        Save-DdcLook -Name 'Day' -Config $script:LookCfg -Monitors $script:Mons | Should -Match '^\[SAVED\] Wide'
        $script:Vcp = @{ 0x10 = 90; 0x12 = 10; 0x14 = 11 }
        $script:LookCfg.Looks = (Read-DdcSaved).Looks
        Invoke-DdcAction -Action 'Look:Day' -Config $script:LookCfg -Monitors $script:Mons | Out-Null
        $script:Vcp[0x10] | Should -Be 40
        $script:Vcp[0x12] | Should -Be 55
        $script:Vcp[0x14] | Should -Be 5
    }
    It 'keeps other monitors already in the look' {
        Write-DdcSaved @{ Looks = @{ Day = @{ Std = @{ Brightness = 70 } } }; Calibration = @{} }
        Save-DdcLook -Name 'Day' -Config $script:LookCfg -Monitors $script:Mons | Out-Null
        $l = (Read-DdcSaved).Looks.Day
        $l.Std.Brightness | Should -Be 70
        $l.Wide.Brightness | Should -Be 40
    }
    It 'rejects unsafe look names' {
        { Save-DdcLook -Name '..\evil' -Config $script:LookCfg -Monitors $script:Mons } | Should -Throw '*Bad look name*'
    }
    It 'rejects an unknown look' {
        { Invoke-DdcAction -Action 'Look:Nope' -Config $script:LookCfg -Monitors $script:Mons } | Should -Throw "*Look 'Nope' not found*"
    }
}

Describe 'Switch-DdcProfile' {
    BeforeAll { $script:SettleMs = @{ Range = 0; List = 0 } }
    BeforeEach {
        $script:StatePath = Join-Path $TestDrive 'state.json'
        if (Test-Path $script:StatePath) { Remove-Item $script:StatePath }
        $script:Vcp = @{ 0x10 = 30; 0x14 = 5 }
        Mock Get-MonitorCapabilities { @{ 0x10 = @(); 0x14 = @(5, 8, 11, 12) } }
        Mock Get-Vcp { [PSCustomObject]@{ Ok = $true; Current = $script:Vcp[$Code]; Max = 100 } }
        Mock Set-Vcp { $script:Vcp[$Code] = $Value; $true }
        $script:Mon = [PSCustomObject]@{ Model = 'Wide'; Handle = [IntPtr]::Zero; DdcOk = $true }
        $script:Cfg = @{ Monitors = @( @{ Name = 'Wide'; Match = @{} } )
                         Profiles = @{ Reading = @{ Brightness = 15; ColorTemp = 'User1' } } }
    }
    It 'applies the profile and saves the old settings' {
        Switch-DdcProfile -Name Reading -Targets @($script:Mon) -Config $script:Cfg | Out-Null
        $script:Vcp[0x10] | Should -Be 15
        $script:Vcp[0x14] | Should -Be 0x0B
        (Read-DdcState)['Reading|Wide']['Brightness'] | Should -Be '30'
    }
    It 'restores the saved settings on the second toggle' {
        Switch-DdcProfile -Name Reading -Targets @($script:Mon) -Config $script:Cfg | Out-Null
        Switch-DdcProfile -Name Reading -Targets @($script:Mon) -Config $script:Cfg | Out-Null
        $script:Vcp[0x10] | Should -Be 30
        $script:Vcp[0x14] | Should -Be 5
        (Read-DdcState).ContainsKey('Reading|Wide') | Should -BeFalse
    }
    It 'falls back to Normal when the profile is on but nothing was saved' {
        $script:Vcp = @{ 0x10 = 15; 0x14 = 0x0B }
        $script:Cfg.Profiles.Normal = @{ Brightness = 50; ColorTemp = '6500K' }
        Switch-DdcProfile -Name Reading -Targets @($script:Mon) -Config $script:Cfg | Out-Null
        $script:Vcp[0x10] | Should -Be 50
        $script:Vcp[0x14] | Should -Be 5
    }
}

Describe 'Invoke-DdcAction' {
    BeforeEach {
        Mock Set-Input { $true }
        $script:Cfg2 = @{ Monitors = $script:Rules; Presets = $script:Config.Presets; Profiles = @{ Reading = @{ Brightness = 10 } } }
    }
    It 'runs presets through Set-Preset' {
        $r = Invoke-DdcAction -Action 'Split' -Config $script:Cfg2 -Monitors @((New-FakeMonitor 'Wide' 0x08))
        ($r -join "`n") | Should -Match '\[OK\] Wide'
    }
    It 'rejects an unknown monitor target' {
        { Invoke-DdcAction -Action 'Set:Brightness=10@Nope' -Config $script:Cfg2 -Monitors @() } | Should -Throw "*Unknown monitor 'Nope'*"
    }
    It 'rejects an unknown feature' {
        { Invoke-DdcAction -Action 'Set:PowerMode=4' -Config $script:Cfg2 -Monitors @() } | Should -Throw "*Unknown feature*"
    }
    It 'rejects an unknown profile' {
        { Invoke-DdcAction -Action 'Toggle:Party' -Config $script:Cfg2 -Monitors @() } | Should -Throw "*Profile 'Party' not found*"
    }
    It 'acts on a single targeted monitor' {
        $script:SettleMs = @{ Range = 0; List = 0 }
        Mock Get-MonitorCapabilities { @{ 0x10 = @() } }
        Mock Get-Vcp { [PSCustomObject]@{ Ok = $true; Current = 30; Max = 100 } }
        Mock Set-Vcp { $true }
        $mons = @( [PSCustomObject]@{ Model = 'Wide'; Handle = [IntPtr]::Zero; DdcOk = $true; Input = 8 },
                   [PSCustomObject]@{ Model = 'Std';  Handle = [IntPtr]::Zero; DdcOk = $true; Input = 15 } )
        $r = Invoke-DdcAction -Action 'Set:Brightness=40@Wide' -Config $script:Cfg2 -Monitors $mons
        $r | Should -Be '[OK] Wide Brightness 30 -> 40'
    }
    It 'skips when no target monitor is on this machine' {
        $r = Invoke-DdcAction -Action 'Set:Brightness=10' -Config $script:Cfg2 -Monitors @((New-FakeMonitor 'Wide' 0 -DdcOk $false))
        $r | Should -Match 'no monitor'
    }
}

Describe 'Import-Config' {
    It 'loads the shipped example config' {
        $cfg = Import-Config -Path (Join-Path $PSScriptRoot '..\config.example.psd1')
        @($cfg.Monitors).Count | Should -BeGreaterThan 0
        foreach ($h in $cfg.Hotkeys) { { ConvertTo-HotKey $h.Keys } | Should -Not -Throw }
        foreach ($h in $cfg.Hotkeys) {
            if ($h.Action -eq 'Wheel') { continue }
            $a = ConvertFrom-DdcAction $h.Action
            switch ($a.Kind) {
                'Preset' { $cfg.Presets.Keys | Should -Contain $a.Name }
                'Set'    { $script:Features.Keys | Should -Contain $a.Feature }
                default  { $cfg.Profiles.Keys | Should -Contain $a.Name }
            }
        }
        $names = @($cfg.Monitors | ForEach-Object { $_.Name })
        foreach ($p in $cfg.Profiles.Values) { foreach ($k in $p.Keys) { @($script:Features.Keys) + $names | Should -Contain $k } }
        Test-NetworkToken $cfg.Network.Token | Should -BeFalse   # placeholder must never pass
    }
    It 'does not treat PictureModes / ColorTemps as input sides' {
        $cfg = Import-Config -Path (Join-Path $PSScriptRoot '..\config.example.psd1')
        $t = Get-InputCodeTable $cfg
        $t['X340 PRO'].Keys | Should -Not -Contain 'PictureModes'
        $t['X340 PRO'].Keys | Should -Not -Contain 'ColorTemps'
        $t['X340 PRO']['PC'] | Should -Be 0x08
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
