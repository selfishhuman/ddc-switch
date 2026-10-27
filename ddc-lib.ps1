<#
    ddc-lib.ps1  -  Shared DDC/CI engine (functions only, no top-level actions).
    Dot-sourced by ddc.ps1 (CLI), ddc-hotkeys.ps1 (global-hotkey daemon) and the Pester tests.
#>

$script:ConfigPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'config.psd1'

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;

public class DdcApi {
    [StructLayout(LayoutKind.Sequential)]
    public struct PHYSICAL_MONITOR {
        public IntPtr hPhysicalMonitor;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szPhysicalMonitorDescription;
    }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
    public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, ref RECT lprc, IntPtr data);

    [DllImport("user32.dll")]
    public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr rect, MonitorEnumProc proc, IntPtr data);
    [DllImport("dxva2.dll")]
    public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr h, ref uint count);
    [DllImport("dxva2.dll")]
    public static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr h, uint count, [Out] PHYSICAL_MONITOR[] arr);
    [DllImport("dxva2.dll")]
    public static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte code, IntPtr type, ref uint current, ref uint max);
    [DllImport("dxva2.dll")]
    public static extern bool SetVCPFeature(IntPtr h, byte code, uint value);
    [DllImport("dxva2.dll")]
    public static extern bool DestroyPhysicalMonitors(uint count, [In] PHYSICAL_MONITOR[] arr);

    public class Mon { public IntPtr Handle; public int Width; public int Height; public string Desc; }

    public static List<Mon> Enumerate() {
        var list = new List<Mon>();
        MonitorEnumProc cb = (IntPtr hMon, IntPtr hdc, ref RECT r, IntPtr d) => {
            uint n = 0;
            if (GetNumberOfPhysicalMonitorsFromHMONITOR(hMon, ref n) && n > 0) {
                var arr = new PHYSICAL_MONITOR[n];
                if (GetPhysicalMonitorsFromHMONITOR(hMon, n, arr)) {
                    foreach (var p in arr)
                        list.Add(new Mon { Handle = p.hPhysicalMonitor, Width = r.right - r.left, Height = r.bottom - r.top, Desc = p.szPhysicalMonitorDescription });
                }
            }
            return true;
        };
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, cb, IntPtr.Zero);
        return list;
    }
}
"@ -ErrorAction SilentlyContinue

# Name a monitor from the config's ordered Monitors rules: the FIRST rule whose Match criteria
# all pass wins. Criteria (all optional): MinAspect, MaxAspect, Width, Height. An empty Match
# matches anything, so it works as a fallback when listed last. Returns $null if nothing matches.
function Resolve-MonitorName {
    param([int]$Width, [int]$Height, $Rules)
    $aspect = if ($Height -gt 0) { $Width / $Height } else { 0 }
    foreach ($rule in @($Rules)) {
        if (-not $rule) { continue }
        $m = if ($rule.Match) { $rule.Match } else { @{} }
        if ($m.ContainsKey('MinAspect') -and $aspect -lt [double]$m.MinAspect) { continue }
        if ($m.ContainsKey('MaxAspect') -and $aspect -gt [double]$m.MaxAspect) { continue }
        if ($m.ContainsKey('Width')     -and $Width  -ne [int]$m.Width)        { continue }
        if ($m.ContainsKey('Height')    -and $Height -ne [int]$m.Height)       { continue }
        return [string]$rule.Name
    }
    return $null
}

# Monitors rules -> @{ '<Name>' = @{ '<Side>' = <input code> } }. Every key other than
# Name/Match is a side (a machine, e.g. PC / Laptop).
function Get-InputCodeTable {
    param($Config)
    $table = @{}
    foreach ($rule in @($Config.Monitors)) {
        if (-not $rule) { continue }
        $codes = @{}
        foreach ($k in $rule.Keys) { if ($k -notin 'Name', 'Match') { $codes[$k] = [int]$rule[$k] } }
        $table[[string]$rule.Name] = $codes
    }
    return $table
}

function Get-Monitors {
    param($Rules)
    if (-not $PSBoundParameters.ContainsKey('Rules')) { $Rules = (Import-Config).Monitors }
    $raw = [DdcApi]::Enumerate()
    $out = @()
    foreach ($m in $raw) {
        $cur = [uint32]0; $max = [uint32]0
        $ok = [DdcApi]::GetVCPFeatureAndVCPFeatureReply($m.Handle, [byte]0x60, [IntPtr]::Zero, [ref]$cur, [ref]$max)
        # A display with no DDC/CI (e.g. a laptop's built-in panel) is not one of our
        # controllable monitors -> label it 'Internal/Other' so it never collides with a real model.
        $name = if (-not $ok) { 'Internal/Other' } else { Resolve-MonitorName $m.Width $m.Height $Rules }
        $out += [PSCustomObject]@{
            Model    = if ($name) { $name } else { '(unmatched)' }
            Width    = $m.Width
            Height   = $m.Height
            Aspect   = if ($m.Height -gt 0) { [math]::Round($m.Width / $m.Height, 2) } else { 0 }
            Handle   = $m.Handle
            Input    = if ($ok) { [int]$cur } else { $null }
            InputHex = if ($ok) { '0x{0:X2}' -f $cur } else { 'n/a' }
            DdcOk    = $ok
        }
    }
    return $out
}

function Set-Input {
    param([Parameter(Mandatory)]$Handle, [Parameter(Mandatory)][int]$Value)
    return [DdcApi]::SetVCPFeature($Handle, [byte]0x60, [uint32]$Value)
}

function Import-Config {
    param([string]$Path = $script:ConfigPath)
    if (-not (Test-Path $Path)) {
        throw "Config not found: $Path  (copy config.example.psd1 to config.psd1 and edit it)"
    }
    $cfg = if (Get-Command Import-PowerShellDataFile -ErrorAction SilentlyContinue) {
        Import-PowerShellDataFile -Path $Path
    } else {
        & ([scriptblock]::Create((Get-Content -Raw -Path $Path)))
    }
    # v1 configs keyed Monitors by model name; rules are now an ordered list (first match wins).
    if ($cfg.Monitors -is [hashtable]) {
        throw "Config '$Path' uses the old Monitors format. Rewrite Monitors as a list of @{ Name = ...; Match = @{...}; <Side> = <code> } (see config.example.psd1)."
    }
    return $cfg
}

# A token must be set, changed from the template placeholder, long enough to not be guessable,
# and free of ':' (the wire format is "<token>:<preset>").
function Test-NetworkToken {
    param([string]$Token)
    return [bool]($Token -and $Token.Length -ge 16 -and $Token -notlike 'CHANGE-ME*' -and -not $Token.Contains(':'))
}

# 'Ctrl+Alt+1' -> Modifiers/Vk for RegisterHotKey. Supports Ctrl, Alt, Shift, Win plus one key:
# A-Z, 0-9 or F1-F24. MOD_NOREPEAT is always added so holding the keys doesn't re-fire.
function ConvertTo-HotKey {
    param([Parameter(Mandatory)][string]$Keys)
    $MOD_ALT = 0x0001; $MOD_CONTROL = 0x0002; $MOD_SHIFT = 0x0004; $MOD_WIN = 0x0008; $MOD_NOREPEAT = 0x4000
    $mods = 0; $vk = $null
    foreach ($part in $Keys.Split('+')) {
        $p = $part.Trim()
        $key = $null
        if     ($p -match '^(Ctrl|Control)$') { $mods = $mods -bor $MOD_CONTROL }
        elseif ($p -match '^Alt$')            { $mods = $mods -bor $MOD_ALT }
        elseif ($p -match '^Shift$')          { $mods = $mods -bor $MOD_SHIFT }
        elseif ($p -match '^Win$')            { $mods = $mods -bor $MOD_WIN }
        elseif ($p -match '^F([1-9]|1[0-9]|2[0-4])$') { $key = 0x6F + [int]$Matches[1] }   # VK_F1 = 0x70
        elseif ($p -match '^[A-Za-z0-9]$')    { $key = [int][char]$p.ToUpper() }           # VK = ASCII for A-Z / 0-9
        else { throw "Unrecognized key '$p' in hotkey '$Keys'" }
        if ($null -ne $key) {
            if ($null -ne $vk) { throw "Hotkey '$Keys' has more than one non-modifier key" }
            $vk = $key
        }
    }
    if ($null -eq $vk) { throw "Hotkey '$Keys' has no key (e.g. 'Ctrl+Alt+1')" }
    if ($mods -eq 0)   { throw "Hotkey '$Keys' needs at least one modifier (Ctrl/Alt/Shift/Win)" }
    return [PSCustomObject]@{ Modifiers = ($mods -bor $MOD_NOREPEAT); Vk = $vk; Label = $Keys }
}

# Apply a named preset. Returns a list of result strings for logging.
function Set-Preset {
    param([Parameter(Mandatory)][string]$Name, $Config, $Monitors)
    if (-not $Config)   { $Config   = Import-Config }
    if (-not $Monitors) { $Monitors = Get-Monitors -Rules $Config.Monitors }
    if (-not $Config.Presets.ContainsKey($Name)) { throw "Preset '$Name' not found. Have: $(($Config.Presets.Keys) -join ', ')" }
    $preset = $Config.Presets[$Name]
    $codes  = Get-InputCodeTable $Config
    $results = @()
    foreach ($model in $preset.Keys) {
        $side = $preset[$model]
        if (-not $codes.ContainsKey($model) -or -not $codes[$model].ContainsKey($side)) {
            $results += "[SKIP] $model $side (no code in config)"; continue
        }
        $val = [int]$codes[$model][$side]
        $target = $Monitors | Where-Object { $_.Model -eq $model -and $_.DdcOk } | Select-Object -First 1
        if (-not $target) { $results += "[SKIP] $model not connected / no DDC"; continue }
        # Already on the target input -> do NOT re-send it. Re-selecting the same input
        # forces an HDMI/DP re-handshake (the black flicker) for no reason.
        if ($target.Input -eq $val) { $results += ("[SAME] {0,-12} already {1,-6} (0x{2:X2})" -f $model, $side, $val); continue }
        $ok = Set-Input -Handle $target.Handle -Value $val
        $results += ("{0} {1,-12} -> {2,-6} (0x{3:X2})" -f $(if ($ok){'[OK]'}else{'[FAIL]'}), $model, $side, $val)
    }
    return $results
}
