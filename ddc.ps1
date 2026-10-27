<#
    ddc.ps1  -  CLI for the DDC/CI monitor input switcher (pure PowerShell).

    Usage:
      powershell -ExecutionPolicy Bypass -File ddc.ps1 list                 # monitors, resolution, aspect, input, DDC status
      powershell -ExecutionPolicy Bypass -File ddc.ps1 preset <Name>        # apply a preset from config.psd1
      powershell -ExecutionPolicy Bypass -File ddc.ps1 set "<Monitor>" 0x11 # raw input code (hex or decimal)
      powershell -ExecutionPolicy Bypass -File ddc.ps1 capture <Side>       # print current inputs as <Side>'s codes (e.g. PC, Laptop)

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
    }

    'set' {
        if (-not $Arg1 -or -not $Arg2) { throw "Usage: ddc.ps1 set `"<Monitor>`" <input>   e.g. set `"X340 PRO`" 0x11" }
        $val = if ($Arg2 -match '^0x') { [Convert]::ToInt32($Arg2, 16) } else { [int]$Arg2 }
        $mons = Get-Monitors -Rules (Get-ConfigRules)
        $target = $mons | Where-Object { $_.Model -eq $Arg1 -and $_.DdcOk } | Select-Object -First 1
        if (-not $target) { throw "No DDC-capable monitor named '$Arg1'. Found: $(($mons.Model) -join ', ')" }
        $ok = Set-Input -Handle $target.Handle -Value $val
        Write-Host ("{0} {1} -> input 0x{2:X2}" -f $(if ($ok) {'[OK]'} else {'[FAIL]'}), $Arg1, $val)
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
    }

    default { Write-Host "Unknown command '$Command'. Use: list | preset | set | capture" }
}
