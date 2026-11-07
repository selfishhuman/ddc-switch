<#
    ddc-lib.ps1  -  Shared DDC/CI engine (functions only, no top-level actions).
    Dot-sourced by ddc.ps1 (CLI), ddc-hotkeys.ps1 (global-hotkey daemon) and the Pester tests.
#>

$script:ConfigPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'config.psd1'
$script:StatePath  = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'state.local.json'
# Machine-written looks + calibration (`ddc.ps1 save` / `calibrate`). Copy it to the other machine too.
$script:SavedPath  = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'saved.psd1'

Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Collections.Generic;

public class DdcApi {
    // szPhysicalMonitorDescription is WCHAR[128] (256 bytes). Without CharSet.Unicode the
    // marshaller sizes it as 128 ANSI bytes and dxva2 overruns the buffer on every lookup,
    // which corrupts the heap and eventually kills the process (0xc0000374).
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
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
    public static extern bool DestroyPhysicalMonitor(IntPtr h);
    [DllImport("dxva2.dll")]
    public static extern bool GetCapabilitiesStringLength(IntPtr h, ref uint length);
    [DllImport("dxva2.dll", CharSet = CharSet.Ansi)]
    public static extern bool CapabilitiesRequestAndCapabilitiesReply(IntPtr h, StringBuilder caps, uint length);

    public class Mon { public IntPtr Handle; public IntPtr HMonitor; public int Width; public int Height; public string Desc; }

    public static List<Mon> Enumerate() {
        var list = new List<Mon>();
        MonitorEnumProc cb = (IntPtr hMon, IntPtr hdc, ref RECT r, IntPtr d) => {
            uint n = 0;
            if (GetNumberOfPhysicalMonitorsFromHMONITOR(hMon, ref n) && n > 0) {
                var arr = new PHYSICAL_MONITOR[n];
                if (GetPhysicalMonitorsFromHMONITOR(hMon, n, arr)) {
                    foreach (var p in arr)
                        list.Add(new Mon { Handle = p.hPhysicalMonitor, HMonitor = hMon, Width = r.right - r.left, Height = r.bottom - r.top, Desc = p.szPhysicalMonitorDescription });
                }
            }
            return true;
        };
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, cb, IntPtr.Zero);
        return list;
    }

    // MCCS capabilities string, e.g. "(prot(monitor)type(lcd)...vcp(02 04 10 12 14(05 08) ...))". Can take ~1 s.
    public static string GetCapabilities(IntPtr h) {
        uint len = 0;
        if (!GetCapabilitiesStringLength(h, ref len) || len == 0) return null;
        var sb = new StringBuilder((int)len);
        return CapabilitiesRequestAndCapabilitiesReply(h, sb, len) ? sb.ToString() : null;
    }
}
"@ -ErrorAction SilentlyContinue

# Monitor settings this tool may write, in the order a profile applies them: picture mode first
# (a mode change can reset brightness/colour on some monitors), colour preset before the gains
# (gains usually only apply in a User preset). Restores run in reverse order.
# Nothing outside this table is ever written, so no power-off (0xD6) or factory reset (0x04).
$script:Features = [ordered]@{
    # AlwaysWrite: some monitors misreport their mode (the X340 PRO reads back Read as 0x00),
    # so the current value can't be trusted to skip a write. A mode write doesn't re-handshake.
    PictureMode = @{ Code = 0xDC; Kind = 'List'; AlwaysWrite = $true; Names = [ordered]@{
            Standard = 0x00; Productivity = 0x01; Mixed = 0x02; Movie = 0x03; User = 0x04
            Game = 0x05; Sports = 0x06; Professional = 0x07 } }
    ColorTemp   = @{ Code = 0x14; Kind = 'List'; Names = [ordered]@{
            sRGB = 0x01; Native = 0x02; '4000K' = 0x03; '5000K' = 0x04; '6500K' = 0x05; '7500K' = 0x06
            '8200K' = 0x07; '9300K' = 0x08; '10000K' = 0x09; '11500K' = 0x0A; User1 = 0x0B; User2 = 0x0C; User3 = 0x0D } }
    Brightness  = @{ Code = 0x10; Kind = 'Range' }
    Contrast    = @{ Code = 0x12; Kind = 'Range' }
    RedGain     = @{ Code = 0x16; Kind = 'Range' }
    GreenGain   = @{ Code = 0x18; Kind = 'Range' }
    BlueGain    = @{ Code = 0x1A; Kind = 'Range' }
    Volume      = @{ Code = 0x62; Kind = 'Range' }
    Mute        = @{ Code = 0x8D; Kind = 'List'; Names = [ordered]@{ On = 0x01; Off = 0x02 } }
}
# Per-monitor config keys that rename a List feature's values (e.g. PictureModes = @{ Reading = 0x02 }).
$script:FeatureNameKeys = @{ PictureMode = 'PictureModes'; ColorTemp = 'ColorTemps' }
# Gap after a write before the next write to the same monitor. MCCS asks hosts to wait 50 ms between
# commands; mode changes take longer. Waited for only when another write follows, never after the last.
$script:SettleMs = @{ Range = 60; List = 250 }
$script:NextWriteAt = @{}
$script:CapsCache = @{}

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
# Name/Match and the hashtable-valued settings (PictureModes, ...) is a side (a machine, e.g. PC / Laptop).
function Get-InputCodeTable {
    param($Config)
    $table = @{}
    foreach ($rule in @($Config.Monitors)) {
        if (-not $rule) { continue }
        $codes = @{}
        foreach ($k in $rule.Keys) {
            if ($k -in 'Name', 'Match' -or $rule[$k] -is [System.Collections.IDictionary]) { continue }
            $codes[$k] = [int]$rule[$k]
        }
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
            HMonitor = $m.HMonitor
            Input    = if ($ok) { [int]$cur } else { $null }
            InputHex = if ($ok) { '0x{0:X2}' -f $cur } else { 'n/a' }
            DdcOk    = $ok
        }
    }
    return $out
}

# Release the physical-monitor handles Get-Monitors opened. Fake monitors (tests) have a zero handle.
function Close-Monitors {
    param($Monitors)
    foreach ($m in @($Monitors)) {
        if ($m -and $m.Handle -and $m.Handle -ne [IntPtr]::Zero) { [void][DdcApi]::DestroyPhysicalMonitor($m.Handle) }
    }
}

function Set-Input {
    param([Parameter(Mandatory)]$Handle, [Parameter(Mandatory)][int]$Value)
    return [DdcApi]::SetVCPFeature($Handle, [byte]0x60, [uint32]$Value)
}

function Get-Vcp {
    param([Parameter(Mandatory)]$Handle, [Parameter(Mandatory)][int]$Code)
    $cur = [uint32]0; $max = [uint32]0
    $ok = [DdcApi]::GetVCPFeatureAndVCPFeatureReply($Handle, [byte]$Code, [IntPtr]::Zero, [ref]$cur, [ref]$max)
    return [PSCustomObject]@{ Ok = $ok; Current = [int]$cur; Max = [int]$max }
}

function Set-Vcp {
    param([Parameter(Mandatory)]$Handle, [Parameter(Mandatory)][int]$Code, [Parameter(Mandatory)][int]$Value)
    return [DdcApi]::SetVCPFeature($Handle, [byte]$Code, [uint32]$Value)
}

# The vcp(...) section of an MCCS capabilities string -> @{ <code> = int[] allowed values }.
# Continuous features have an empty value list. Returns $null if there is no vcp section.
function ConvertFrom-CapabilitiesString {
    param([string]$Caps)
    if (-not $Caps) { return $null }
    $m = [regex]::Match($Caps, '(?i)(?<![a-z_])vcp\(')
    if (-not $m.Success) { return $null }
    $table = @{}
    $i = $m.Index + $m.Length
    $depth = 1; $lastCode = $null; $values = $null; $token = ''
    while ($i -lt $Caps.Length -and $depth -gt 0) {
        $c = $Caps[$i]
        if ($c -match '[0-9A-Fa-f]') { $token += $c }
        else {
            if ($token) {
                $n = [Convert]::ToInt32($token, 16)
                if ($depth -eq 1) { $lastCode = $n; $table[$n] = @() } elseif ($null -ne $values) { $values += $n }
                $token = ''
            }
            if ($c -eq '(') {
                $depth++
                if ($depth -eq 2 -and $null -ne $lastCode) { $values = @() }
            } elseif ($c -eq ')') {
                if ($depth -eq 2 -and $null -ne $lastCode -and $null -ne $values) { $table[$lastCode] = $values; $values = $null }
                $depth--
            }
        }
        $i++
    }
    return $table
}

# Parsed capabilities for a monitor, cached per monitor name (the request is slow). $null when
# the monitor doesn't answer; that is not cached, so a later attempt can still succeed.
function Get-MonitorCapabilities {
    param([Parameter(Mandatory)]$Monitor)
    if ($script:CapsCache.ContainsKey($Monitor.Model)) { return $script:CapsCache[$Monitor.Model] }
    $parsed = ConvertFrom-CapabilitiesString ([DdcApi]::GetCapabilities($Monitor.Handle))
    if ($parsed) { $script:CapsCache[$Monitor.Model] = $parsed }
    return $parsed
}

function Get-MonitorRule {
    param($Config, [string]$MonitorName)
    if (-not $Config) { return $null }
    return @($Config.Monitors) | Where-Object { $_ -and $_.Name -eq $MonitorName } | Select-Object -First 1
}

# VCP code of a feature on a monitor: the rule's Codes override (for vendor codes, e.g. a picture
# mode on 0xE0 instead of 0xDC) or the MCCS standard code.
function Get-FeatureCode {
    param([Parameter(Mandatory)][string]$Feature, $Config, [string]$MonitorName)
    $rule = Get-MonitorRule $Config $MonitorName
    if ($rule -and $rule.Codes -and $rule.Codes.ContainsKey($Feature)) { return [int]$rule.Codes[$Feature] }
    return [int]$script:Features[$Feature].Code
}

# Value names for a List feature on a monitor: the monitor rule's override (PictureModes /
# ColorTemps in config) or the MCCS standard names.
function Get-FeatureValueNames {
    param([Parameter(Mandatory)][string]$Feature, $Config, [string]$MonitorName)
    $def = $script:Features[$Feature]
    if ($def.Kind -ne 'List') { return $null }
    $key = $script:FeatureNameKeys[$Feature]
    if ($key -and $Config) {
        $rule = Get-MonitorRule $Config $MonitorName
        if ($rule -and $rule[$key]) {
            $names = [ordered]@{}
            foreach ($k in ($rule[$key].Keys | Sort-Object { $rule[$key][$_] })) { $names[$k] = [int]$rule[$key][$k] }
            return $names
        }
    }
    return $def.Names
}

# Calibration curve for a Range feature on a monitor (from `ddc.ps1 calibrate`): sorted
# (level, raw) points. Levels are a shared 0-100 scale on which both monitors look alike.
function Get-FeatureCurve {
    param([Parameter(Mandatory)][string]$Feature, $Config, [string]$MonitorName)
    if (-not $Config -or -not $Config.Calibration -or -not $Config.Calibration[$MonitorName]) { return $null }
    $pts = $Config.Calibration[$MonitorName][$Feature]
    if (-not $pts -or @($pts).Count -lt 2) { return $null }
    return , @(@($pts) | ForEach-Object { , @([double]$_[0], [double]$_[1]) } | Sort-Object { $_[0] })
}

# Shared level -> this monitor's raw value (piecewise linear between calibration points).
function ConvertTo-RawValue {
    param([Parameter(Mandatory)]$Curve, [double]$Level)
    if ($Level -le $Curve[0][0]) { return [int][math]::Round($Curve[0][1]) }
    for ($i = 1; $i -lt $Curve.Count; $i++) {
        $a = $Curve[$i - 1]; $b = $Curve[$i]
        if ($Level -le $b[0]) { return [int][math]::Round($a[1] + ($Level - $a[0]) * ($b[1] - $a[1]) / ($b[0] - $a[0])) }
    }
    return [int][math]::Round($Curve[-1][1])
}

# This monitor's raw value -> shared level (inverse of ConvertTo-RawValue; raw rises with level).
function ConvertFrom-RawValue {
    param([Parameter(Mandatory)]$Curve, [double]$Raw)
    if ($Raw -le $Curve[0][1]) { return [int][math]::Round($Curve[0][0]) }
    for ($i = 1; $i -lt $Curve.Count; $i++) {
        $a = $Curve[$i - 1]; $b = $Curve[$i]
        if ($Raw -le $b[1]) {
            if ($b[1] -eq $a[1]) { return [int][math]::Round($a[0]) }
            return [int][math]::Round($a[0] + ($Raw - $a[1]) * ($b[0] - $a[0]) / ($b[1] - $a[1]))
        }
    }
    return [int][math]::Round($Curve[-1][0])
}

# Read a feature as the rest of the tool sees it: the calibrated level for a calibrated Range
# feature, otherwise the raw VCP value. Returns @{ Ok; Value; Raw; Max }.
function Get-MonitorFeatureValue {
    param([Parameter(Mandatory)]$Monitor, [Parameter(Mandatory)][string]$Feature, $Config, $Caps)
    $code = Get-FeatureCode -Feature $Feature -Config $Config -MonitorName $Monitor.Model
    if ($null -ne $Caps -and -not $Caps.ContainsKey($code)) { return @{ Ok = $false } }
    $r = Get-Vcp -Handle $Monitor.Handle -Code $code
    if (-not $r.Ok) { return @{ Ok = $false } }
    if ($null -eq $Caps -and $script:Features[$Feature].Kind -eq 'Range' -and ($r.Max -le 0 -or $r.Max -gt 1000)) { return @{ Ok = $false } }
    $curve = Get-FeatureCurve -Feature $Feature -Config $Config -MonitorName $Monitor.Model
    $value = if ($curve) { ConvertFrom-RawValue $curve $r.Current } else { $r.Current }
    return @{ Ok = $true; Value = [int]$value; Raw = $r.Current; Max = $r.Max }
}

function Get-FeatureValueName {
    param($Names, [int]$Value)
    if ($Names) { foreach ($k in $Names.Keys) { if ($Names[$k] -eq $Value) { return $k } } }
    return ('0x{0:X2}' -f $Value)
}

# Work out the value to write. Range: '40' / '40%' absolute, '+10' / '-10' relative, clamped to
# 0..Max. List: a name, a number, or Next / Prev to cycle. A List value must be one the monitor
# advertises ($Allowed, from its capabilities) or, if it advertises none, one of $Names.
# Returns @{ Ok; Value; Error }.
function Resolve-FeatureValue {
    param(
        [Parameter(Mandatory)][string]$Feature,
        [Parameter(Mandatory)][string]$Value,
        [int]$Current, [int]$Max, $Names, [int[]]$Allowed
    )
    $def = $script:Features[$Feature]
    if (-not $def) { return @{ Ok = $false; Error = "unknown feature '$Feature'" } }
    $v = $Value.Trim()
    if ($def.Kind -eq 'Range') {
        if ($Max -le 0) { return @{ Ok = $false; Error = 'monitor reports no range' } }
        if ($v -match '^([+-])(\d+)$') { $target = $Current + [int]$v }
        elseif ($v -match '^(\d+)%$') { $target = [int][math]::Round([int]$Matches[1] * $Max / 100) }
        elseif ($v -match '^\d+$')    { $target = [int]$v }
        else { return @{ Ok = $false; Error = "bad value '$Value' (use 40, 40%, +10 or -10)" } }
        return @{ Ok = $true; Value = [math]::Max(0, [math]::Min($Max, $target)) }
    }
    # List: the cycle order is the advertised values if any, otherwise the known names.
    $choices = if ($Allowed -and $Allowed.Count) { @($Allowed) } else { @($Names.Values) }
    if ($v -match '^(Next|Prev|Toggle)$') {
        if (-not $choices.Count) { return @{ Ok = $false; Error = 'no known values to cycle' } }
        $idx = [array]::IndexOf($choices, $Current)
        $step = if ($v -eq 'Prev') { -1 } else { 1 }
        $idx = if ($idx -lt 0) { 0 } else { ($idx + $step + $choices.Count) % $choices.Count }
        return @{ Ok = $true; Value = [int]$choices[$idx] }
    }
    $target = $null
    if ($Names) { foreach ($k in $Names.Keys) { if ($k -eq $v) { $target = [int]$Names[$k] } } }
    if ($null -eq $target) {
        if ($v -match '^0x[0-9A-Fa-f]+$') { $target = [Convert]::ToInt32($v, 16) }
        elseif ($v -match '^\d+$')        { $target = [int]$v }
        else { return @{ Ok = $false; Error = "unknown $Feature '$Value' (have: $(@($Names.Keys) -join ', '))" } }
    }
    if ($target -notin $choices) { return @{ Ok = $false; Error = ("{0} 0x{1:X2} is not one this monitor supports" -f $Feature, $target) } }
    return @{ Ok = $true; Value = $target }
}

# Set one feature on one monitor, with the safety checks: whitelisted feature only, supported per
# the monitor's capabilities, value validated/clamped, and no write when it already matches.
function Set-MonitorFeature {
    param(
        [Parameter(Mandatory)]$Monitor,
        [Parameter(Mandatory)][string]$Feature,
        [Parameter(Mandatory)][string]$Value,
        $Config, $Caps
    )
    $def = $script:Features[$Feature]
    if (-not $def) { return "[SKIP] unknown feature '$Feature' (have: $(@($script:Features.Keys) -join ', '))" }
    $label = '{0} {1}' -f $Monitor.Model, $Feature
    $code = Get-FeatureCode -Feature $Feature -Config $Config -MonitorName $Monitor.Model
    if ($null -ne $Caps -and -not $Caps.ContainsKey($code)) { return "[SKIP] $label not supported by this monitor" }
    $r = Get-Vcp -Handle $Monitor.Handle -Code $code
    if (-not $r.Ok) { return "[SKIP] $label no DDC reply" }
    # Without capabilities, a nonsense range (e.g. 65535 for a monitor without speakers) means unsupported.
    if ($null -eq $Caps -and $def.Kind -eq 'Range' -and ($r.Max -le 0 -or $r.Max -gt 1000)) { return "[SKIP] $label not supported (range 0..$($r.Max))" }
    $names   = Get-FeatureValueNames -Feature $Feature -Config $Config -MonitorName $Monitor.Model
    $allowed = if ($null -ne $Caps) { [int[]]@($Caps[$code]) } else { [int[]]@() }
    # A calibrated feature works on the shared 0-100 level, mapped to this monitor's raw value.
    $curve = if ($def.Kind -eq 'Range') { Get-FeatureCurve -Feature $Feature -Config $Config -MonitorName $Monitor.Model }
    if ($curve) {
        $curLevel = ConvertFrom-RawValue $curve $r.Current
        $res = Resolve-FeatureValue -Feature $Feature -Value $Value -Current $curLevel -Max 100
        if (-not $res.Ok) { return "[SKIP] $label $($res.Error)" }
        $target = [math]::Max(0, [math]::Min($r.Max, (ConvertTo-RawValue $curve $res.Value)))
        $from = "$curLevel (raw $($r.Current))"; $to = "$($res.Value) (raw $target)"
    } else {
        $res = Resolve-FeatureValue -Feature $Feature -Value $Value -Current $r.Current -Max $r.Max -Names $names -Allowed $allowed
        if (-not $res.Ok) { return "[SKIP] $label $($res.Error)" }
        $target = $res.Value
        $show = { param($x) if ($def.Kind -eq 'List') { Get-FeatureValueName $names $x } else { $x } }
        $from = & $show $r.Current; $to = & $show $target
    }
    if ($target -eq $r.Current -and -not $def.AlwaysWrite) { return ('[SAME] {0} already {1}' -f $label, $from) }
    # Space consecutive writes to one monitor as MCCS asks, without sleeping after the last one.
    $wait = 0
    if ($script:NextWriteAt.ContainsKey($Monitor.Model)) { $wait = ($script:NextWriteAt[$Monitor.Model] - [DateTime]::UtcNow).TotalMilliseconds }
    if ($wait -gt 0) { Start-Sleep -Milliseconds ([int][math]::Ceiling($wait)) }
    $ok = Set-Vcp -Handle $Monitor.Handle -Code $code -Value $target
    $script:NextWriteAt[$Monitor.Model] = [DateTime]::UtcNow.AddMilliseconds([int]$script:SettleMs[$def.Kind])
    return ('{0} {1} {2} -> {3}' -f $(if ($ok) { '[OK]' } else { '[FAIL]' }), $label, $from, $to)
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
    # Looks and calibration are machine-written to saved.psd1 so config.psd1 (and its comments) is
    # never rewritten. Only merged for the real config, so tests using another path stay hermetic.
    if ($Path -eq $script:ConfigPath) {
        $saved = Read-DdcSaved
        $cfg.Looks = $saved.Looks; $cfg.Calibration = $saved.Calibration
        $cfg.Profiles = Merge-DdcProfiles $cfg.Profiles $saved.Profiles
    }
    return $cfg
}

function Read-DdcSaved {
    param([string]$Path = $script:SavedPath)
    $s = if (Test-Path $Path) { Import-PowerShellDataFile -Path $Path } else { @{} }
    if (-not $s.Looks) { $s.Looks = @{} }
    if (-not $s.Calibration) { $s.Calibration = @{} }
    if (-not $s.Profiles) { $s.Profiles = @{} }
    return $s
}

# Profiles tuned in the tuner (saved.psd1 -> Profiles) layered over config.psd1's: each tuned
# monitor block is merged over that profile's block for the monitor, so its values win over the
# profile's shared ones. A profile only in saved.psd1 is added as is.
function Merge-DdcProfiles {
    param($ConfigProfiles, $SavedProfiles)
    $out = @{}
    if ($ConfigProfiles) { foreach ($k in $ConfigProfiles.Keys) { $out[$k] = @{} + $ConfigProfiles[$k] } }
    if (-not $SavedProfiles) { return $out }
    foreach ($name in $SavedProfiles.Keys) {
        if (-not $out.ContainsKey($name)) { $out[$name] = @{} }
        foreach ($mon in $SavedProfiles[$name].Keys) {
            $block = if ($out[$name][$mon] -is [System.Collections.IDictionary]) { @{} + $out[$name][$mon] } else { @{} }
            foreach ($f in $SavedProfiles[$name][$mon].Keys) { $block[$f] = $SavedProfiles[$name][$mon][$f] }
            $out[$name][$mon] = $block
        }
    }
    return $out
}

# Hashtables / arrays / numbers / strings -> PowerShell data-file text.
function ConvertTo-Psd1 {
    param($Value, [int]$Indent = 0)
    $pad = '    ' * $Indent
    if ($Value -is [System.Collections.IDictionary]) {
        if (-not $Value.Count) { return '@{}' }
        $lines = foreach ($k in ($Value.Keys | Sort-Object)) {
            "$pad    '$($k -replace "'", "''")' = $(ConvertTo-Psd1 $Value[$k] ($Indent + 1))"
        }
        return "@{`r`n$($lines -join "`r`n")`r`n$pad}"
    }
    if ($Value -is [array]) { return '@(' + (@($Value | ForEach-Object { ConvertTo-Psd1 $_ ($Indent + 1) }) -join ', ') + ')' }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) { return [string]$Value }
    return "'$(([string]$Value) -replace "'", "''")'"
}

function Write-DdcSaved {
    param([Parameter(Mandatory)]$Saved, [string]$Path = $script:SavedPath)
    $text = "# Written by ddc-switch (ddc.ps1 save / calibrate). Copy this file to the other machine too.`r`n" +
            (ConvertTo-Psd1 @{ Looks = $Saved.Looks; Calibration = $Saved.Calibration; Profiles = $(if ($Saved.Profiles) { $Saved.Profiles } else { @{} }) })
    Set-Content -Path $Path -Value $text -Encoding UTF8
}

# Save the current settings of this machine's monitors as a look. Monitors on the other machine
# keep whatever that look already had for them.
function Save-DdcLook {
    param([Parameter(Mandatory)][string]$Name, $Config, $Monitors)
    if ($Name -notmatch '^[\w][\w \-]{0,31}$') { throw "Bad look name '$Name' (letters, digits, space, - and _, up to 32)" }
    if (-not $Config) { $Config = Import-Config }
    $opened = -not $Monitors
    if ($opened) { $Monitors = Get-Monitors -Rules $Config.Monitors }
    try {
        $saved = Read-DdcSaved
        $look = if ($saved.Looks[$Name]) { $saved.Looks[$Name] } else { @{} }
        $results = @()
        foreach ($m in (Select-TargetMonitor $Monitors 'All')) {
            $caps = Get-MonitorCapabilities $m
            $vals = @{}
            foreach ($f in $script:Features.Keys) {
                if ($script:Features[$f].AlwaysWrite -and $null -eq $caps) { continue }
                $v = Get-MonitorFeatureValue -Monitor $m -Feature $f -Config $Config -Caps $caps
                if ($v.Ok) { $vals[$f] = [int]$v.Value }
            }
            $look[$m.Model] = $vals
            $results += "[SAVED] $($m.Model) -> look '$Name': " + (($vals.Keys | Sort-Object | ForEach-Object { "$_ $($vals[$_])" }) -join ', ')
        }
        if (-not $results) { return , "[SKIP] no monitor on this machine's active input to save" }
        $saved.Looks[$Name] = $look
        Write-DdcSaved $saved
        return $results
    } finally { if ($opened) { Close-Monitors $Monitors } }
}

# A token must be set, changed from the template placeholder, long enough to not be guessable,
# and free of ':' (the wire format is "<token>:<action>").
function Test-NetworkToken {
    param([string]$Token)
    return [bool]($Token -and $Token.Length -ge 16 -and $Token -notlike 'CHANGE-ME*' -and -not $Token.Contains(':'))
}

# 'Ctrl+Alt+1' -> Modifiers/Vk for RegisterHotKey. Supports Ctrl, Alt, Shift, Win plus one key:
# A-Z, 0-9, F1-F24, Space, arrows, PageUp/PageDown. MOD_NOREPEAT is always added so holding the
# keys doesn't re-fire.
function ConvertTo-HotKey {
    param([Parameter(Mandatory)][string]$Keys, [switch]$AllowRepeat)
    $MOD_ALT = 0x0001; $MOD_CONTROL = 0x0002; $MOD_SHIFT = 0x0004; $MOD_WIN = 0x0008; $MOD_NOREPEAT = 0x4000
    $named = @{ Space = 0x20; PageUp = 0x21; PageDown = 0x22; Left = 0x25; Up = 0x26; Right = 0x27; Down = 0x28 }
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
        elseif ($named.ContainsKey($p))       { $key = $named[$p] }
        else { throw "Unrecognized key '$p' in hotkey '$Keys'" }
        if ($null -ne $key) {
            if ($null -ne $vk) { throw "Hotkey '$Keys' has more than one non-modifier key" }
            $vk = $key
        }
    }
    if ($null -eq $vk) { throw "Hotkey '$Keys' has no key (e.g. 'Ctrl+Alt+1')" }
    if ($mods -eq 0)   { throw "Hotkey '$Keys' needs at least one modifier (Ctrl/Alt/Shift/Win)" }
    if (-not $AllowRepeat) { $mods = $mods -bor $MOD_NOREPEAT }
    return [PSCustomObject]@{ Modifiers = $mods; Vk = $vk; Label = $Keys }
}

# Apply a named preset. Returns a list of result strings for logging.
function Set-Preset {
    param([Parameter(Mandatory)][string]$Name, $Config, $Monitors)
    if (-not $Config)   { $Config   = Import-Config }
    if (-not $Config.Presets.ContainsKey($Name)) { throw "Preset '$Name' not found. Have: $(($Config.Presets.Keys) -join ', ')" }
    $opened = -not $Monitors
    if ($opened) { $Monitors = Get-Monitors -Rules $Config.Monitors }
    try {
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
            # A blanked monitor gets its brightness back first, or the other machine would show at 0.
            if (Test-DdcBlank $target) { $results += Switch-DdcBlank -Mode Off -Targets @($target) -Config $Config }
            $ok = Set-Input -Handle $target.Handle -Value $val
            $results += ("{0} {1,-12} -> {2,-6} (0x{3:X2})" -f $(if ($ok){'[OK]'}else{'[FAIL]'}), $model, $side, $val)
        }
        return $results
    } finally { if ($opened) { Close-Monitors $Monitors } }
}

# Action strings are what hotkeys, the wheel and the peer link carry:
#   <Preset>                        switch inputs, e.g. AllPC
#   Set:<Feature>=<Value>[@<Mon>]   e.g. Set:Brightness=+10, Set:PictureMode=Game@X340 PRO
#   Profile:<Name>[@<Mon>]          apply a Profiles entry from config
#   Toggle:<Name>[@<Mon>]           apply a profile, or restore what it replaced if it's already on
#   Look:<Name>[@<Mon>]             apply a saved look (saved.psd1)
#   Save:<Name>                     save this machine's monitors' current settings as a look
#   Blank:<On|Off|Toggle>[@<Mon>]   black out a monitor (see Switch-DdcBlank)
function ConvertFrom-DdcAction {
    param([Parameter(Mandatory)][string]$Action)
    $a = $Action.Trim()
    if ($a -notmatch '^(Set|Profile|Toggle|Look|Save|Blank):(.+)$') { return @{ Kind = 'Preset'; Name = $a } }
    $kind = $Matches[1]; $body = $Matches[2]; $target = 'All'
    $at = $body.LastIndexOf('@')
    if ($at -ge 0) { $target = $body.Substring($at + 1).Trim(); $body = $body.Substring(0, $at) }
    if (-not $target) { $target = 'All' }
    if ($kind -eq 'Set') {
        if ($body -notmatch '^\s*(\w+)\s*=\s*(.+?)\s*$') { throw "Bad action '$Action' (use Set:<Feature>=<Value>)" }
        return @{ Kind = 'Set'; Feature = $Matches[1]; Value = $Matches[2]; Target = $target }
    }
    return @{ Kind = $kind; Name = $body.Trim(); Target = $target }
}

# The monitors an action applies to: this machine's DDC-reachable, named monitors, filtered by target.
function Select-TargetMonitor {
    param($Monitors, [string]$Target = 'All')
    @($Monitors | Where-Object { $_.DdcOk -and $_.Model -notin 'Internal/Other', '(unmatched)' -and ($Target -eq 'All' -or $_.Model -eq $Target) })
}

# A profile's settings for one monitor: the shared values plus any per-monitor override block.
# An override of $null drops that setting for the monitor (e.g. a mode it doesn't have).
function Get-ProfileSetting {
    param([Parameter(Mandatory)]$ProfileDef, [string]$MonitorName)
    $s = [ordered]@{}
    foreach ($f in $script:Features.Keys) { if ($ProfileDef.ContainsKey($f) -and $null -ne $ProfileDef[$f]) { $s[$f] = [string]$ProfileDef[$f] } }
    if ($MonitorName -and $ProfileDef[$MonitorName] -is [System.Collections.IDictionary]) {
        $o = $ProfileDef[$MonitorName]
        foreach ($f in $script:Features.Keys) {
            if (-not $o.ContainsKey($f)) { continue }
            if ($null -eq $o[$f]) { $s.Remove($f) } else { $s[$f] = [string]$o[$f] }
        }
    }
    return $s
}

function Set-MonitorSetting {
    param($Monitor, $Settings, $Config, [switch]$Reverse)
    $caps = Get-MonitorCapabilities $Monitor
    $order = @($script:Features.Keys)
    if ($Reverse) { [array]::Reverse($order) }
    foreach ($f in $order) {
        if ($Settings.Contains($f)) { Set-MonitorFeature -Monitor $Monitor -Feature $f -Value $Settings[$f] -Config $Config -Caps $caps }
    }
}

# True when every readable setting in the profile already matches the monitor.
function Test-ProfileActive {
    param($Monitor, $Settings, $Config)
    $caps = Get-MonitorCapabilities $Monitor
    $checked = 0
    foreach ($f in $Settings.Keys) {
        if ($script:Features[$f].AlwaysWrite) { continue }   # its readback can't be trusted
        $v = Get-MonitorFeatureValue -Monitor $Monitor -Feature $f -Config $Config -Caps $caps
        if (-not $v.Ok) { continue }
        $names = Get-FeatureValueNames -Feature $f -Config $Config -MonitorName $Monitor.Model
        $max = if (Get-FeatureCurve -Feature $f -Config $Config -MonitorName $Monitor.Model) { 100 } else { $v.Max }
        $res = Resolve-FeatureValue -Feature $f -Value $Settings[$f] -Current $v.Value -Max $max -Names $names
        if (-not $res.Ok -or $res.Value -ne $v.Value) { return $false }
        $checked++
    }
    return ($checked -gt 0)
}

function Read-DdcState {
    if (-not (Test-Path $script:StatePath)) { return @{} }
    try {
        $obj = Get-Content -Raw -Path $script:StatePath | ConvertFrom-Json
        $h = @{}
        foreach ($p in $obj.PSObject.Properties) {
            $s = [ordered]@{}
            foreach ($q in $p.Value.PSObject.Properties) { $s[$q.Name] = [string]$q.Value }
            $h[$p.Name] = $s
        }
        return $h
    } catch { return @{} }
}

function Write-DdcState {
    param([hashtable]$State)
    $State | ConvertTo-Json -Depth 4 | Set-Content -Path $script:StatePath -Encoding UTF8
}

# Forget the settings toggles saved for these monitors ("<Profile>|<Monitor>" keys in the state file).
function Clear-DdcToggleState {
    param($Monitors)
    $state = Read-DdcState
    $drop = @(foreach ($m in @($Monitors)) { $state.Keys | Where-Object { $_.EndsWith("|$($m.Model)") } })
    if (-not $drop.Count) { return }
    foreach ($k in $drop) { $state.Remove($k) }
    Write-DdcState $state
}

# Toggle a profile on this machine's target monitors. If any of them already shows the profile,
# all of them go back to the settings saved when it was switched on (or to the 'Normal' profile
# when nothing was saved, e.g. it was switched on from the other machine). Otherwise the current
# settings are saved and the profile is applied.
function Switch-DdcProfile {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Targets, $Config)
    $def = $Config.Profiles[$Name]
    $state = Read-DdcState
    # On = we saved settings when switching it on here, or the monitor visibly matches it (e.g. it
    # was switched on from the other machine).
    $active = @($Targets | Where-Object { $state.ContainsKey("$Name|$($_.Model)") -or (Test-ProfileActive $_ (Get-ProfileSetting $def $_.Model) $Config) })
    $results = @()
    if ($active.Count) {
        foreach ($m in $active) {
            $key = "$Name|$($m.Model)"
            if ($state.ContainsKey($key)) {
                $results += "[$Name off] $($m.Model): restoring saved settings"
                $results += Set-MonitorSetting $m $state[$key] $Config -Reverse
                $state.Remove($key)
            } elseif ($Config.Profiles.ContainsKey('Normal') -and $Name -ne 'Normal') {
                $results += "[$Name off] $($m.Model): nothing saved, applying Normal"
                $results += Set-MonitorSetting $m (Get-ProfileSetting $Config.Profiles['Normal'] $m.Model) $Config
            } else {
                $results += "[SKIP] $($m.Model): $Name is on but nothing was saved to restore (add a 'Normal' profile)"
            }
        }
    } else {
        foreach ($m in $Targets) {
            $settings = Get-ProfileSetting $def $m.Model
            $caps = Get-MonitorCapabilities $m
            $saved = [ordered]@{}
            foreach ($f in $settings.Keys) {
                $v = Get-MonitorFeatureValue -Monitor $m -Feature $f -Config $Config -Caps $caps
                if ($v.Ok) { $saved[$f] = [string]$v.Value }
            }
            $state["$Name|$($m.Model)"] = $saved
            $results += "[$Name on] $($m.Model): saved current settings"
            $results += Set-MonitorSetting $m $settings $Config
        }
    }
    Write-DdcState $state
    return $results
}

# Blanking: a black window over the monitor plus raw brightness 0 (below the calibrated minimum),
# so the panel is as dark as it gets while it keeps its signal and still answers DDC. The window
# is drawn by the daemon ([BlankOverlay] in ddc-hotkeys.ps1); without it (the CLI) a monitor can
# only be un-blanked. The brightness it had is kept in the state file ("Blank|<Monitor>") and put
# back on un-blank, even after a daemon restart.
function Test-DdcBlank {
    param([Parameter(Mandatory)]$Monitor, $State)
    if ($null -eq $State) { $State = Read-DdcState }
    $overlay = 'BlankOverlay' -as [type]
    return [bool]($State.ContainsKey("Blank|$($Monitor.Model)") -or ($overlay -and $overlay::IsShown([string]$Monitor.Model)))
}

# Toggle blanks every target if none is blanked, otherwise un-blanks them all (like Switch-DdcProfile).
function Switch-DdcBlank {
    param([Parameter(Mandatory)][ValidateSet('On', 'Off', 'Toggle')][string]$Mode, [Parameter(Mandatory)]$Targets, $Config)
    $overlay = 'BlankOverlay' -as [type]
    $state = Read-DdcState
    $on = if ($Mode -eq 'Toggle') { -not @($Targets | Where-Object { Test-DdcBlank $_ $state }).Count } else { $Mode -eq 'On' }
    $results = @()
    foreach ($m in $Targets) {
        $key = "Blank|$($m.Model)"
        $code = Get-FeatureCode -Feature Brightness -Config $Config -MonitorName $m.Model
        if ($on) {
            if (-not $overlay) { $results += "[SKIP] $($m.Model): blanking needs the daemon (use its hotkey or the wheel)"; continue }
            $note = 'already blank'
            if (-not $state.ContainsKey($key)) {
                $b = Get-Vcp -Handle $m.Handle -Code $code
                if ($b.Ok) {
                    $state[$key] = [ordered]@{ Brightness = [string]$b.Current }
                    $note = "brightness $($b.Current) -> 0"
                    [void](Set-Vcp -Handle $m.Handle -Code $code -Value 0)
                } else { $note = 'brightness unreadable, left as is' }
            }
            $overlay::Show([string]$m.Model, [long]$m.HMonitor)
            $results += "[Blank on] $($m.Model): $note"
        } else {
            if ($overlay) { $overlay::Hide([string]$m.Model) }
            if ($state.ContainsKey($key)) {
                $raw = [int]$state[$key]['Brightness']
                $ok = Set-Vcp -Handle $m.Handle -Code $code -Value $raw
                $state.Remove($key)
                $results += "$(if ($ok) { '[Blank off]' } else { '[FAIL] Blank off' }) $($m.Model): brightness back to $raw"
            } else { $results += "[Blank off] $($m.Model)" }
        }
    }
    Write-DdcState $state
    return $results
}

# Run an action string (see ConvertFrom-DdcAction) on the monitors this machine owns.
# Returns result strings for logging. Unknown presets, features and profiles are rejected.
function Invoke-DdcAction {
    param([Parameter(Mandatory)][string]$Action, $Config, $Monitors)
    if (-not $Config) { $Config = Import-Config }
    $a = ConvertFrom-DdcAction $Action
    if ($a.Kind -eq 'Preset') { return Set-Preset -Name $a.Name -Config $Config -Monitors $Monitors }
    if ($a.Kind -eq 'Save')   { return Save-DdcLook -Name $a.Name -Config $Config -Monitors $Monitors }

    $known = @($Config.Monitors | ForEach-Object { $_.Name })
    if ($a.Target -ne 'All' -and $a.Target -notin $known) { throw "Unknown monitor '$($a.Target)'. Have: All, $($known -join ', ')" }
    if ($a.Kind -eq 'Set' -and -not $script:Features.Contains($a.Feature)) { throw "Unknown feature '$($a.Feature)'. Have: $(@($script:Features.Keys) -join ', ')" }
    if ($a.Kind -eq 'Look' -and -not ($Config.Looks -and $Config.Looks.ContainsKey($a.Name))) {
        throw "Look '$($a.Name)' not found in saved.psd1. Have: $(if ($Config.Looks) { @($Config.Looks.Keys) -join ', ' })"
    }
    if ($a.Kind -in 'Profile', 'Toggle' -and -not ($Config.Profiles -and $Config.Profiles.ContainsKey($a.Name))) {
        throw "Profile '$($a.Name)' not found. Have: $(if ($Config.Profiles) { @($Config.Profiles.Keys) -join ', ' })"
    }
    if ($a.Kind -eq 'Blank' -and $a.Name -notin 'On', 'Off', 'Toggle') { throw "Bad action '$Action' (use Blank:On, Blank:Off or Blank:Toggle, optionally @<Monitor>)" }

    $opened = -not $Monitors
    if ($opened) { $Monitors = Get-Monitors -Rules $Config.Monitors }
    try {
        $targets = @(Select-TargetMonitor $Monitors $a.Target)   # @(): one monitor comes back unwrapped, and PS 5.1 objects have no .Count
        if (-not $targets.Count) { return , "[SKIP] no monitor$(if ($a.Target -ne 'All') { " '$($a.Target)'" }) on this machine's active input" }
        # Picking a profile or look replaces whatever a toggle (e.g. Reading) switched on, so forget
        # what that toggle saved: otherwise toggling it later would "restore" those older settings.
        if ($a.Kind -in 'Profile', 'Look') { Clear-DdcToggleState $targets }
        switch ($a.Kind) {
            'Set' {
                foreach ($m in $targets) { Set-MonitorFeature -Monitor $m -Feature $a.Feature -Value $a.Value -Config $Config -Caps (Get-MonitorCapabilities $m) }
            }
            'Profile' {
                foreach ($m in $targets) { Set-MonitorSetting $m (Get-ProfileSetting $Config.Profiles[$a.Name] $m.Model) $Config }
            }
            'Toggle' { Switch-DdcProfile -Name $a.Name -Targets $targets -Config $Config }
            'Blank'  { Switch-DdcBlank -Mode $a.Name -Targets $targets -Config $Config }
            'Look' {
                $look = $Config.Looks[$a.Name]
                foreach ($m in $targets) {
                    if ($look[$m.Model]) { Set-MonitorSetting $m (Get-ProfileSetting $look[$m.Model]) $Config }
                    else { "[SKIP] $($m.Model) isn't in look '$($a.Name)' (save it while this monitor shows this machine)" }
                }
            }
        }
    } finally { if ($opened) { Close-Monitors $Monitors } }
}

# ---- Tuner (ddc-tuner.ps1) ----
# Features the tuner shows, in display order.
$script:TuneFeatures = @('PictureMode', 'ColorTemp', 'Brightness', 'Contrast', 'RedGain', 'GreenGain', 'BlueGain')

# JSON for the tuner: every configured monitor, and for each one this machine can reach, the
# current value, range or choices of each tunable feature it supports. Brightness is on the
# calibrated 0-100 scale when calibrated.
function Get-DdcTuneState {
    param($Config)
    if (-not $Config) { $Config = Import-Config }
    $mons = Get-Monitors -Rules $Config.Monitors
    try {
        $reach = @{}
        foreach ($m in (Select-TargetMonitor $mons 'All')) { $reach[$m.Model] = $m }
        $list = foreach ($rule in @($Config.Monitors | Where-Object { $_ })) {
            $name = [string]$rule.Name
            $m = $reach[$name]
            if (-not $m) { [ordered]@{ Name = $name; Reachable = $false }; continue }
            $caps = Get-MonitorCapabilities $m
            $feats = [ordered]@{}
            foreach ($f in $script:TuneFeatures) {
                $v = Get-MonitorFeatureValue -Monitor $m -Feature $f -Config $Config -Caps $caps
                if (-not $v.Ok) { continue }
                if ($script:Features[$f].Kind -eq 'List') {
                    $names = Get-FeatureValueNames -Feature $f -Config $Config -MonitorName $name
                    $code = Get-FeatureCode -Feature $f -Config $Config -MonitorName $name
                    $allowed = if ($null -ne $caps -and $caps[$code]) { @($caps[$code]) } else { @() }
                    $opts = @(foreach ($k in $names.Keys) { if (-not $allowed.Count -or $names[$k] -in $allowed) { $k } })
                    $feats[$f] = [ordered]@{ Value = (Get-FeatureValueName $names $v.Value); Options = $opts }
                } else {
                    $max = if (Get-FeatureCurve -Feature $f -Config $Config -MonitorName $name) { 100 } else { $v.Max }
                    $feats[$f] = [ordered]@{ Value = $v.Value; Max = $max }
                }
            }
            [ordered]@{ Name = $name; Reachable = $true; Features = $feats }
        }
        $profiles = @(if ($Config.Profiles) { $Config.Profiles.Keys | Sort-Object })
        return ([ordered]@{ Monitors = @($list); Profiles = $profiles } | ConvertTo-Json -Depth 6 -Compress)
    } finally { Close-Monitors $mons }
}

# '{"X340 PRO":{"Brightness":"60"}}' -> @{ 'X340 PRO' = [ordered]@{ Brightness = '60' } }
function ConvertFrom-TuneJson {
    param([string]$Json)
    $h = @{}
    $obj = $Json | ConvertFrom-Json
    foreach ($p in $obj.PSObject.Properties) {
        $s = [ordered]@{}
        foreach ($q in $p.Value.PSObject.Properties) { if ($script:Features.Contains($q.Name)) { $s[$q.Name] = [string]$q.Value } }
        $h[$p.Name] = $s
    }
    return $h
}

# Apply per-monitor settings (tuner preview / revert) to the monitors this machine can reach.
function Set-DdcTuneSettings {
    param([Parameter(Mandatory)][string]$Json, $Config)
    if (-not $Config) { $Config = Import-Config }
    $want = ConvertFrom-TuneJson $Json
    $mons = Get-Monitors -Rules $Config.Monitors
    try {
        $out = foreach ($m in (Select-TargetMonitor $mons 'All')) {
            if ($want.ContainsKey($m.Model) -and $want[$m.Model].Count) { Set-MonitorSetting $m $want[$m.Model] $Config }
        }
        return (@($out) -join "`n")
    } finally { Close-Monitors $mons }
}

# Save tuned per-monitor settings as a profile in saved.psd1 (merged over config.psd1's profile).
# Monitors not in $Json keep what was saved for them before.
function Save-DdcTuneProfile {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Json)
    if ($Name -notmatch '^[\w][\w \-]{0,31}$') { throw "Bad profile name '$Name' (letters, digits, space, - and _, up to 32)" }
    $vals = ConvertFrom-TuneJson $Json
    $saved = Read-DdcSaved
    $prof = if ($saved.Profiles[$Name]) { $saved.Profiles[$Name] } else { @{} }
    foreach ($mon in $vals.Keys) {
        $block = @{}
        foreach ($f in $vals[$mon].Keys) { $v = $vals[$mon][$f]; $block[$f] = if ($v -match '^\d+$') { [int]$v } else { $v } }
        $prof[$mon] = $block
    }
    $saved.Profiles[$Name] = $prof
    Write-DdcSaved $saved
    return "Saved '$Name' for $(@($vals.Keys) -join ' + ')"
}

# One line per monitor with its current picture settings (only what it supports), for the
# CLI and the wheel's status text.
function Get-DdcStatus {
    param($Config, [string]$Target = 'All')
    if (-not $Config) { $Config = Import-Config }
    $mons = Get-Monitors -Rules $Config.Monitors
    try {
        $lines = @()
        foreach ($m in (Select-TargetMonitor $mons $Target)) {
            $caps = Get-MonitorCapabilities $m
            $parts = @()
            foreach ($f in 'Brightness', 'Contrast', 'PictureMode', 'ColorTemp', 'Volume') {
                $r = Get-MonitorFeatureValue -Monitor $m -Feature $f -Config $Config -Caps $caps
                if (-not $r.Ok) { continue }
                $v = if ($script:Features[$f].Kind -eq 'List') { Get-FeatureValueName (Get-FeatureValueNames -Feature $f -Config $Config -MonitorName $m.Model) $r.Value } else { $r.Value }
                $parts += "$f $v"
            }
            $lines += "$($m.Model): $($parts -join ', ')"
        }
        $others = @($mons | Where-Object { -not $_.DdcOk }).Count
        if ($others) { $lines += "$others display(s) not controllable from here (showing the other machine, or no DDC)" }
        return $lines
    } finally { Close-Monitors $mons }
}
