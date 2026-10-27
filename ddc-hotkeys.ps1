<#
    ddc-hotkeys.ps1  -  Coordinated global-hotkey daemon for monitor input switching.

    Runs on BOTH machines. Because many monitors only accept DDC on their ACTIVE input,
    no single machine can switch a monitor that is currently showing the other machine. So:

      * Each machine, when it applies a preset, only switches the monitors it currently
        owns (its active inputs) -- Set-Preset naturally skips monitors it can't reach.
      * Pressing a hotkey applies the preset locally AND forwards the preset name to the
        peer machine, which applies it to the monitors IT owns. The union = the full
        target layout, with neither machine ever needing inactive-input DDC.

    Hotkeys, presets and the network token live in config.psd1 (shared by both machines);
    PeerHost lives in machine.local.psd1 (per machine).
    Logs to ddc-hotkeys.log. Run hidden at logon via install-startup.ps1.
#>

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogPath   = Join-Path $ScriptDir 'ddc-hotkeys.log'
. (Join-Path $ScriptDir 'ddc-lib.ps1')

function Log([string]$msg) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
}

Set-Content -Path $LogPath -Value '' -Encoding UTF8

# --- Load config + peer settings ------------------------------------------
try { $cfg = Import-Config } catch { Log ("FATAL: " + $_.Exception.Message); throw }
$Port  = 58762
$Token = $null
$RestrictToPeer = $true
if ($cfg.Network) {
    if ($cfg.Network.Port)  { $Port  = [int]$cfg.Network.Port }
    if ($cfg.Network.Token) { $Token = [string]$cfg.Network.Token }
    if ($cfg.Network.ContainsKey('RestrictToPeer')) { $RestrictToPeer = [bool]$cfg.Network.RestrictToPeer }
}
$PeerHost = $null
$machineFile = Join-Path $ScriptDir 'machine.local.psd1'
if (Test-Path $machineFile) {
    $mc = Import-PowerShellDataFile $machineFile
    if ($mc.PeerHost -and $mc.PeerHost -notin 'OTHER-MACHINE-IP-OR-HOSTNAME', 'LAPTOP-IP-OR-HOSTNAME') { $PeerHost = [string]$mc.PeerHost }
}

# Never listen with a missing/placeholder/short token: run local-only instead.
$NetworkEnabled = Test-NetworkToken $Token
Log "ddc-hotkeys starting (PID $PID). Port=$Port PeerHost=$(if ($PeerHost) { $PeerHost } else { '(none)' }) Network=$(if ($NetworkEnabled) { 'on' } else { 'OFF' })"
if (-not $NetworkEnabled) {
    Log "WARNING: Network.Token in config.psd1 is missing, still CHANGE-ME, under 16 chars, or contains ':' - running LOCAL-ONLY (no peer listener / forwarding)."
}

# --- Windows API for global hotkeys ---------------------------------------
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class HotKeyApi {
    [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [StructLayout(LayoutKind.Sequential)] public struct MSG {
        public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int ptX; public int ptY;
    }
    [DllImport("user32.dll")] public static extern int GetMessage(out MSG msg, IntPtr hWnd, uint min, uint max);
}
"@ -ErrorAction SilentlyContinue

# id -> @{ Vk; Modifiers; Preset; Label }, from config.psd1 -> Hotkeys
$Bindings = @{}
$nextId = 1
foreach ($h in @($cfg.Hotkeys)) {
    if (-not $h) { continue }
    try {
        $hk = ConvertTo-HotKey $h.Keys
        $Bindings[$nextId] = @{ Vk = $hk.Vk; Modifiers = $hk.Modifiers; Preset = [string]$h.Preset; Label = $hk.Label }
        $nextId++
    } catch { Log ("Bad hotkey entry: " + $_.Exception.Message) }
}
if ($Bindings.Count -eq 0) { Log "WARNING: no Hotkeys defined in config.psd1" }

# --- Peer listener (separate runspace so it can block on Accept) -----------
$listenerScript = {
    param($ScriptDir, $Port, $Token, $LogPath, $PeerHost, $RestrictToPeer)
    . (Join-Path $ScriptDir 'ddc-lib.ps1')
    $peerLog = $LogPath   # captured for PLog (the analyzer misses param use inside nested functions)
    function PLog($m) { Add-Content -Path $peerLog -Value ("{0}  [peer] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8 }
    function Get-PeerAddress {
        if (-not $PeerHost) { return @() }
        try { return @([System.Net.Dns]::GetHostAddresses($PeerHost) | ForEach-Object { $_.ToString() }) } catch { return @() }
    }
    try {
        $allowed = Get-PeerAddress
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $Port)
        $listener.Start()
        PLog "listening on port $Port$(if ($RestrictToPeer) { " (peer-only: $PeerHost)" })"
        while ($true) {
            $client = $listener.AcceptTcpClient()
            try {
                $remote = $client.Client.RemoteEndPoint.Address.ToString()
                if ($RestrictToPeer) {
                    # Re-resolve on a miss: DNS may not have been ready at logon, or the peer's IP changed.
                    if ($remote -notin $allowed) { $allowed = Get-PeerAddress }
                    if ($remote -notin $allowed) { PLog "rejected connection from $remote (not PeerHost)"; continue }
                }
                $client.ReceiveTimeout = 2000   # a silent client can't stall the accept loop
                $reader = New-Object System.IO.StreamReader($client.GetStream())
                $line = $reader.ReadLine()
                if ($line) {
                    $parts = $line.Split(':', 2)
                    if ($parts.Count -eq 2 -and $parts[0] -eq $Token) {
                        $preset = $parts[1].Trim()
                        try { $r = Set-Preset -Name $preset; PLog ("applied '$preset': " + ($r -join ' | ')) }
                        catch { PLog ("error applying '$preset': " + $_.Exception.Message) }
                    } else { PLog "rejected message from $remote (bad token)" }
                }
            } catch { PLog ('client error: ' + $_.Exception.Message) }
            finally { $client.Close() }
        }
    } catch { PLog ('listener fatal: ' + $_.Exception.Message) }
}
if ($NetworkEnabled) {
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $psListener = [powershell]::Create(); $psListener.Runspace = $rs
    [void]$psListener.AddScript($listenerScript).AddArgument($ScriptDir).AddArgument($Port).AddArgument($Token).AddArgument($LogPath).AddArgument($PeerHost).AddArgument($RestrictToPeer)
    [void]$psListener.BeginInvoke()
}

# --- Forward a preset to the peer machine ---------------------------------
function Send-ToPeer([string]$preset) {
    if (-not $NetworkEnabled) { return }
    if (-not $PeerHost) { Log "no PeerHost set - not forwarding (edit machine.local.psd1)"; return }
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($PeerHost, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(1500)) { $client.Close(); throw "connect timeout" }
        $client.EndConnect($iar)
        $writer = New-Object System.IO.StreamWriter($client.GetStream())
        $writer.WriteLine("${Token}:${preset}")
        $writer.Flush(); $writer.Close(); $client.Close()
        Log "forwarded '$preset' to $PeerHost"
    } catch {
        Log ("could not reach peer ${PeerHost}: " + $_.Exception.Message)
    }
}

# --- Register hotkeys ------------------------------------------------------
foreach ($id in $Bindings.Keys) {
    $b = $Bindings[$id]
    if ([HotKeyApi]::RegisterHotKey([IntPtr]::Zero, $id, $b.Modifiers, $b.Vk)) {
        Log ("Registered {0} -> {1}" -f $b.Label, $b.Preset)
    } else {
        Log ("FAILED to register {0} (already in use?)" -f $b.Label)
    }
}

# --- Message loop ----------------------------------------------------------
$WM_HOTKEY = 0x0312
$msg = New-Object HotKeyApi+MSG
try {
    while ([HotKeyApi]::GetMessage([ref]$msg, [IntPtr]::Zero, 0, 0) -gt 0) {
        if ($msg.message -eq $WM_HOTKEY) {
            $id = [int]$msg.wParam
            if ($Bindings.ContainsKey($id)) {
                $preset = $Bindings[$id].Preset
                try {
                    $results = Set-Preset -Name $preset                  # local: only monitors we own
                    Send-ToPeer $preset                                   # peer: monitors it owns
                    Log ("Hotkey {0} -> {1} (local): {2}" -f $Bindings[$id].Label, $preset, ($results -join ' | '))
                } catch {
                    Log ("ERROR applying '{0}': {1}" -f $preset, $_.Exception.Message)
                }
            }
        }
    }
}
finally {
    foreach ($id in $Bindings.Keys) { [void][HotKeyApi]::UnregisterHotKey([IntPtr]::Zero, $id) }
    if ($psListener) { try { $psListener.Stop() } catch { Log ("listener stop failed: " + $_.Exception.Message) } }
    Log "ddc-hotkeys stopped"
}
