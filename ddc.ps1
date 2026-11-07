<#
    ddc.ps1  -  CLI for the DDC/CI monitor switcher (pure PowerShell).

    Usage:
      powershell -ExecutionPolicy Bypass -File ddc.ps1 list                 # monitors, resolution, aspect, input, DDC status
      powershell -ExecutionPolicy Bypass -File ddc.ps1 preset <Name>        # apply a preset from config.psd1
      powershell -ExecutionPolicy Bypass -File ddc.ps1 set "<Monitor>" 0x11 # raw input code (hex or decimal)
      powershell -ExecutionPolicy Bypass -File ddc.ps1 capture <Side>       # print current inputs as <Side>'s codes (e.g. PC, Laptop)

      ddc.ps1 status                        # brightness, contrast, picture mode, colour temp of each monitor
      ddc.ps1 caps ["<Monitor>"]            # what each monitor advertises (VCP codes and values)
      ddc.ps1 brightness 40 ["<Monitor>"]   # also contrast / volume; values 40, 40%, +10, -10
      ddc.ps1 mode Game ["<Monitor>"]       # picture mode by name, or Next / Prev
      ddc.ps1 colortemp 6500K ["<Monitor>"] # colour preset by name, or Next / Prev
      ddc.ps1 reading ["<Monitor>"]         # toggle the Reading profile (restores your settings when off)
      ddc.ps1 profile <Name> ["<Monitor>"]  # apply a profile from config.psd1
      ddc.ps1 save <Look>                   # save the monitors' current settings as a named look
      ddc.ps1 look <Look> ["<Monitor>"]     # apply a saved look
      ddc.ps1 looks                         # list saved looks and calibration
      ddc.ps1 forget <Look> | calibration   # delete a look, or the brightness calibration
      ddc.ps1 calibrate [Brightness]        # match both monitors by eye at 3 levels (both must show this machine)
      ddc.ps1 do "<Action>"                 # any action string, e.g. "Set:Brightness=+10@X340 PRO"
      ddc.ps1 wheel                         # open the radial menu here (local only, no forwarding)
      ddc.ps1 tune [Profile]                # tuner window: adjust each monitor live, save into a profile
      ddc.ps1 blank off ["<Monitor>"]       # give a blanked monitor its brightness back (blanking itself is daemon-only)

    The CLI only touches the monitors on THIS machine's active inputs; hotkeys and the wheel in the
    daemon also forward to the other machine.

    Options:
      -ConfigPath <file>   use a config other than config.psd1 next to this script
#>

param(
    [Parameter(Position = 0)][string]$Command = 'list',
    [Parameter(Position = 1)][string]$Arg1,
    [Parameter(Position = 2)][string]$Arg2,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
$ScriptDir      = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigOverride = $ConfigPath   # ddc-lib.ps1 sets $script:ConfigPath when dot-sourced
. (Join-Path $ScriptDir 'ddc-lib.ps1')
if ($ConfigOverride) { $script:ConfigPath = (Resolve-Path $ConfigOverride).Path }

# Monitor rules if a config exists, otherwise none (so `list` works before setup).
function Get-ConfigRules {
    if (Test-Path $script:ConfigPath) { return (Import-Config).Monitors }
    Write-Host "  (no config yet at $script:ConfigPath - showing raw monitors; copy config.example.psd1 to config.psd1)"
    return @()
}

# The tuner run directly (no daemon worker): each call blocks the window briefly while it runs.
function Open-CliTuner([string]$StartProfile) {
    . (Join-Path $ScriptDir 'ddc-tuner.ps1')
    $call = {
        param($c, $a, $done)
        $r = try { (& $c @a) -join "`n" } catch { 'Error: ' + $_.Exception.Message }
        & $done ([string]$r)
    }
    Show-DdcTuner -Call $call -StartProfile $StartProfile
}

function Invoke-AndShow([string]$Action) {
    Invoke-DdcAction -Action $Action | ForEach-Object { Write-Host $_ }
}

# "<feature> <value> [monitor]" -> Set:<Feature>=<value>[@monitor]
function Get-SetAction([string]$Feature) {
    if (-not $Arg1) { throw "Usage: ddc.ps1 $($Command.ToLower()) <value> [`"<Monitor>`"]" }
    $a = "Set:$Feature=$Arg1"
    if ($Arg2) { $a += "@$Arg2" }
    return $a
}

$featureCommands = @{ brightness = 'Brightness'; contrast = 'Contrast'; volume = 'Volume'; mode = 'PictureMode'; colortemp = 'ColorTemp' }

switch ($Command.ToLower()) {

    'list' {
        $mons = Get-Monitors -Rules (Get-ConfigRules)
        Write-Host ''
        Write-Host ('  {0,-14} {1,-11} {2,-7} {3,-7} {4}' -f 'NAME', 'RESOLUTION', 'ASPECT', 'INPUT', 'DDC/CI')
        Write-Host ('  {0}' -f ('-' * 56))
        foreach ($m in $mons) {
            $ddc = if ($m.DdcOk) { 'OK' } else { 'FAILED (enable DDC/CI in OSD, or inactive input)' }
            Write-Host ('  {0,-14} {1,-11} {2,-7} {3,-7} {4}' -f $m.Model, ("{0}x{1}" -f $m.Width, $m.Height), $m.Aspect, $m.InputHex, $ddc)
        }
        Write-Host ''
        Close-Monitors $mons
    }

    'set' {
        if (-not $Arg1 -or -not $Arg2) { throw "Usage: ddc.ps1 set `"<Monitor>`" <input>   e.g. set `"X340 PRO`" 0x11" }
        $val = if ($Arg2 -match '^0x') { [Convert]::ToInt32($Arg2, 16) } else { [int]$Arg2 }
        $mons = Get-Monitors -Rules (Get-ConfigRules)
        try {
            $target = $mons | Where-Object { $_.Model -eq $Arg1 -and $_.DdcOk } | Select-Object -First 1
            if (-not $target) { throw "No DDC-capable monitor named '$Arg1'. Found: $(($mons.Model) -join ', ')" }
            $ok = Set-Input -Handle $target.Handle -Value $val
            Write-Host ("{0} {1} -> input 0x{2:X2}" -f $(if ($ok) {'[OK]'} else {'[FAIL]'}), $Arg1, $val)
        } finally { Close-Monitors $mons }
    }

    'preset' {
        if (-not $Arg1) { throw "Usage: ddc.ps1 preset <Name>   (available: $(((Import-Config).Presets.Keys | Sort-Object) -join ', '))" }
        Set-Preset -Name $Arg1 | ForEach-Object { Write-Host $_ }
    }

    'capture' {
        # Prints rather than rewrites config.psd1, so comments, Match rules, Hotkeys and the
        # Network token are never touched. Run it once per side while the monitors show that machine.
        if ($Arg1 -notmatch '^[A-Za-z]\w*$') { throw "Usage: ddc.ps1 capture <Side>   e.g. capture PC / capture Laptop" }
        $cfg   = if (Test-Path $script:ConfigPath) { Import-Config } else { @{ Monitors = @() } }
        $codes = Get-InputCodeTable $cfg
        $mons  = @(Get-Monitors -Rules $cfg.Monitors | Where-Object DdcOk)
        if (-not $mons) { throw "No DDC-capable monitors detected (enable DDC/CI in each monitor's OSD)." }

        Write-Host ''
        Write-Host "  Inputs currently shown, as '$Arg1' codes:"
        foreach ($m in $mons) {
            $note = ''
            if ($codes.ContainsKey($m.Model) -and $codes[$m.Model].ContainsKey($Arg1)) {
                $old  = $codes[$m.Model][$Arg1]
                $note = if ($old -eq $m.Input) { '(matches config)' } else { '(config has 0x{0:X2} - update it)' -f $old }
            } elseif ($m.Model -eq '(unmatched)') {
                $note = "(no rule matches {0}x{1}, aspect {2} - add one to Monitors)" -f $m.Width, $m.Height, $m.Aspect
            } else {
                $note = '(new - add to config)'
            }
            Write-Host ("    {0,-14} {1} = 0x{2:X2}   {3}" -f $m.Model, $Arg1, $m.Input, $note)
        }
        Write-Host ''
        Write-Host "  In config.psd1 -> Monitors, each entry looks like:"
        Write-Host "    @{ Name = 'My Monitor'; Match = @{ MinAspect = 2.0 }; $Arg1 = 0x$('{0:X2}' -f $mons[0].Input); OtherSide = 0x11 }"
        Write-Host ''
        Close-Monitors $mons
    }

    { $_ -in 'status', 'get' } {
        Write-Host ''
        Get-DdcStatus -Target $(if ($Arg1) { $Arg1 } else { 'All' }) | ForEach-Object { Write-Host "  $_" }
        Write-Host ''
    }

    'caps' {
        $cfg  = Import-Config
        $mons = Get-Monitors -Rules $cfg.Monitors
        try {
            foreach ($m in (Select-TargetMonitor $mons $(if ($Arg1) { $Arg1 } else { 'All' }))) {
                $raw = [DdcApi]::GetCapabilities($m.Handle)
                Write-Host ''
                Write-Host "  $($m.Model)"
                Write-Host "    raw: $raw"
                $caps = ConvertFrom-CapabilitiesString $raw
                foreach ($f in $script:Features.Keys) {
                    $code  = Get-FeatureCode -Feature $f -Config $cfg -MonitorName $m.Model
                    $state = if ($null -eq $caps) { '?' } elseif ($caps.ContainsKey($code)) { 'yes' } else { 'no' }
                    $vals  = ''
                    if ($state -eq 'yes') {
                        $names = Get-FeatureValueNames -Feature $f -Config $cfg -MonitorName $m.Model
                        # Vendor codes advertise no value list; show the names configured for them.
                        $list = if ($caps[$code].Count) { $caps[$code] } elseif ($names) { @($names.Values) } else { @() }
                        $vals = ($list | ForEach-Object { Get-FeatureValueName $names $_ }) -join ', '
                    }
                    Write-Host ("    {0,-12} 0x{1:X2}  {2,-4} {3}" -f $f, $code, $state, $vals)
                }
            }
            Write-Host ''
        } finally { Close-Monitors $mons }
    }

    { $featureCommands.ContainsKey($_) } { Invoke-AndShow (Get-SetAction $featureCommands[$Command.ToLower()]) }

    'reading' { Invoke-AndShow ("Toggle:Reading" + $(if ($Arg1) { "@$Arg1" })) }

    'profile' {
        if (-not $Arg1) { throw "Usage: ddc.ps1 profile <Name> [`"<Monitor>`"]" }
        Invoke-AndShow ("Profile:$Arg1" + $(if ($Arg2) { "@$Arg2" }))
    }

    'save' {
        if (-not $Arg1) { throw "Usage: ddc.ps1 save <LookName>   (saves the current settings of the monitors showing this machine)" }
        Invoke-AndShow "Save:$Arg1"
        Write-Host "  Saved to $script:SavedPath - copy it to the other machine so it can apply this look too."
    }

    'look' {
        if (-not $Arg1) { throw "Usage: ddc.ps1 look <LookName> [`"<Monitor>`"]" }
        Invoke-AndShow ("Look:$Arg1" + $(if ($Arg2) { "@$Arg2" }))
    }

    'looks' {
        $saved = Read-DdcSaved
        Write-Host ''
        if (-not $saved.Looks.Count) { Write-Host '  No saved looks yet. Tune the monitors, then: ddc.ps1 save <Name>' }
        foreach ($l in ($saved.Looks.Keys | Sort-Object)) {
            Write-Host "  $l"
            foreach ($m in ($saved.Looks[$l].Keys | Sort-Object)) {
                $v = $saved.Looks[$l][$m]
                Write-Host ("    {0,-12} {1}" -f $m, (($v.Keys | Sort-Object | ForEach-Object { "$_ $($v[$_])" }) -join ', '))
            }
        }
        foreach ($m in ($saved.Calibration.Keys | Sort-Object)) {
            foreach ($f in $saved.Calibration[$m].Keys) { Write-Host ("  calibrated {0} {1}: {2}" -f $m, $f, ((@($saved.Calibration[$m][$f]) | ForEach-Object { "$($_[0])->$($_[1])" }) -join '  ')) }
        }
        Write-Host ''
    }

    'forget' {
        if (-not $Arg1) { throw "Usage: ddc.ps1 forget <LookName>   or   ddc.ps1 forget calibration" }
        $saved = Read-DdcSaved
        if ($Arg1 -eq 'calibration') { $saved.Calibration = @{}; Write-Host '  Calibration removed.' }
        elseif ($saved.Looks.ContainsKey($Arg1)) { $saved.Looks.Remove($Arg1); Write-Host "  Look '$Arg1' removed." }
        else { throw "No look named '$Arg1'." }
        Write-DdcSaved $saved
    }

    'calibrate' {
        # Match the monitors by eye at three levels; the shared 0-100 scale then maps to each panel's
        # raw values, so "All" steps look the same on both and they bottom out together.
        $feature = if ($Arg1) { $Arg1 } else { 'Brightness' }
        if (-not $script:Features.Contains($feature) -or $script:Features[$feature].Kind -ne 'Range') { throw "Can only calibrate a range feature (Brightness, Contrast, ...), not '$feature'." }
        try { [void][Console]::KeyAvailable } catch { throw 'calibrate needs an interactive console window (run it in your own terminal).' }
        $cfg  = Import-Config
        $all  = Get-Monitors -Rules $cfg.Monitors
        try {
            $mons = @(Select-TargetMonitor $all 'All')
            if ($mons.Count -lt 2) { throw "Calibration needs every monitor showing this machine (e.g. press Ctrl+Alt+P first). Found: $(@($mons.Model) -join ', ')" }
            $info = foreach ($m in $mons) {
                $code = Get-FeatureCode -Feature $feature -Config $cfg -MonitorName $m.Model
                $r = Get-Vcp -Handle $m.Handle -Code $code
                if (-not $r.Ok) { throw "$($m.Model) doesn't answer $feature reads." }
                [PSCustomObject]@{ Mon = $m; Code = $code; Start = $r.Current; Max = $r.Max; Raw = 0; Curve = (Get-FeatureCurve -Feature $feature -Config $cfg -MonitorName $m.Model); Points = @() }
            }
            Write-Host ''
            Write-Host "  $feature calibration. Put something plain and light (e.g. a white page) across both monitors."
            Write-Host '  At each step, make the two monitors look equally bright.'
            Write-Host '  Tab / Left / Right: pick monitor   Up / Down: +-1   PageUp / PageDown: +-5   Enter: matched   Esc: cancel'
            $aborted = $false
            foreach ($level in 0, 50, 100) {
                $hint = switch ($level) { 0 { 'DIM: both start at their minimum; raise the darker one until they match' } 50 { 'MIDDLE' } 100 { 'BRIGHT: lower the brighter one until they match' } }
                Write-Host ''
                Write-Host "  Step $level/100 - $hint"
                foreach ($i in $info) {
                    $i.Raw = if ($i.Curve) { ConvertTo-RawValue $i.Curve $level } else { [int][math]::Round($level * $i.Max / 100) }
                    [void](Set-Vcp -Handle $i.Mon.Handle -Code $i.Code -Value $i.Raw); Start-Sleep -Milliseconds 60
                }
                $sel = 0
                while ($true) {
                    $cells = for ($c = 0; $c -lt $info.Count; $c++) {
                        $t = '{0} {1,3}' -f $info[$c].Mon.Model, $info[$c].Raw
                        if ($c -eq $sel) { "[$t]" } else { " $t " }
                    }
                    $line = $cells -join '    '
                    Write-Host -NoNewline ("`r    $line      ")
                    $k = [Console]::ReadKey($true)
                    $delta = switch ($k.Key) { 'UpArrow' { 1 } 'DownArrow' { -1 } 'PageUp' { 5 } 'PageDown' { -5 } default { 0 } }
                    if ($k.Key -in 'Tab', 'LeftArrow', 'RightArrow') { $sel = ($sel + 1) % $info.Count; continue }
                    if ($k.Key -eq 'Enter') { break }
                    if ($k.Key -eq 'Escape') { $aborted = $true; break }
                    if ($delta) {
                        $i = $info[$sel]
                        $i.Raw = [math]::Max(0, [math]::Min($i.Max, $i.Raw + $delta))
                        [void](Set-Vcp -Handle $i.Mon.Handle -Code $i.Code -Value $i.Raw)
                    }
                }
                Write-Host ''
                if ($aborted) { break }
                foreach ($i in $info) { $i.Points += , @($level, [int]$i.Raw) }
            }
            if ($aborted) { Write-Host '  Cancelled - nothing saved.' }
            else {
                $saved = Read-DdcSaved
                foreach ($i in $info) {
                    # Raw must not fall as the level rises, or the curve can't be inverted.
                    for ($p = 1; $p -lt $i.Points.Count; $p++) { if ($i.Points[$p][1] -lt $i.Points[$p - 1][1]) { $i.Points[$p][1] = $i.Points[$p - 1][1] } }
                    if (-not $saved.Calibration[$i.Mon.Model]) { $saved.Calibration[$i.Mon.Model] = @{} }
                    $saved.Calibration[$i.Mon.Model][$feature] = $i.Points
                    Write-Host ("  {0,-12} {1}" -f $i.Mon.Model, (($i.Points | ForEach-Object { "$($_[0])->$($_[1])" }) -join '  '))
                }
                Write-DdcSaved $saved
                Write-Host "  Saved to $script:SavedPath - copy it to the other machine too."
            }
        } finally {
            foreach ($i in @($info)) { if ($i) { [void](Set-Vcp -Handle $i.Mon.Handle -Code $i.Code -Value $i.Start); Start-Sleep -Milliseconds 60 } }
            Close-Monitors $all
        }
    }

    'do' {
        if (-not $Arg1) { throw "Usage: ddc.ps1 do `"<Action>`"   e.g. do `"Set:Brightness=+10`"" }
        Invoke-AndShow $Arg1
    }

    'wheel' {
        . (Join-Path $ScriptDir 'ddc-wheel.ps1')
        $cfg = Import-Config
        $run = { param($a) (Invoke-DdcAction -Action $a -Config $cfg) -join "`n" }
        $status = { param($t) (Get-DdcStatus -Config $cfg -Target $t) -join "`n" }
        $picked = Show-DdcWheel -Config $cfg -Run $run -Status $status
        if ($picked -eq 'Tune') { Open-CliTuner }
        elseif ($picked) { Invoke-AndShow $picked }
    }

    'tune' { Open-CliTuner $Arg1 }

    'blank' {
        # Blanking itself needs the daemon (it draws the black window); here `blank off` still
        # gives a monitor its brightness back, e.g. if the daemon stopped while it was blanked.
        $mode = if ($Arg1) { $Arg1 } else { 'Off' }
        if ($mode -notin 'On', 'Off', 'Toggle') { throw "Usage: ddc.ps1 blank [on|off|toggle] [`"<Monitor>`"]" }
        Invoke-AndShow ("Blank:$mode" + $(if ($Arg2) { "@$Arg2" }))
    }

    default { Write-Host "Unknown command '$Command'. Use: list | preset | set | capture | status | caps | brightness | contrast | volume | mode | colortemp | reading | profile | save | look | looks | forget | calibrate | do | wheel | tune | blank" }
}
