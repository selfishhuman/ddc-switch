<#
    ddc-hotkeys.ps1  -  Coordinated global-hotkey daemon for monitor input switching.

    Runs on BOTH machines. Because many monitors only accept DDC on their ACTIVE input,
    no single machine can switch a monitor that is currently showing the other machine. So:

      * Each machine, when it runs an action, only touches the monitors it currently
        owns (its active inputs) -- monitors it can't reach are skipped.
      * Pressing a hotkey runs the action locally AND forwards it to the peer machine,
        which runs it on the monitors IT owns. The union = the full target result, with
        neither machine ever needing inactive-input DDC.

    Actions are preset names (input switching) or monitor settings such as
    Set:Brightness=+10, Toggle:Reading (see ConvertFrom-DdcAction in ddc-lib.ps1).
    The special action 'Wheel' opens the radial menu (ddc-wheel.ps1).

    Hotkeys, presets, profiles and the network token live in config.psd1 (shared by both
    machines); PeerHost lives in machine.local.psd1 (per machine).
    Logs to ddc-hotkeys.log. Started at logon / unlock / wake by install-startup.ps1.
#>

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogPath   = Join-Path $ScriptDir 'ddc-hotkeys.log'
. (Join-Path $ScriptDir 'ddc-lib.ps1')

# The listener runspace and the peer sender write the same file, so retry briefly on a lock
# rather than let a logging error kill the daemon.
function Log([string]$msg) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    for ($i = 0; $i -lt 5; $i++) {
        try { Add-Content -Path $LogPath -Value $line -Encoding UTF8 -ErrorAction Stop; return } catch { Start-Sleep -Milliseconds 20 }
    }
}

# Single instance. The scheduled task fires on every logon, unlock and wake; if a daemon is
# already running, this copy leaves quietly without touching the log, hotkeys or port.
$mutex = New-Object System.Threading.Mutex($false, 'Local\DDCSwitchHotkeys')
try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }   # previous copy crashed
if (-not $owned) { exit 0 }

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

# --- Windows API for global hotkeys + a background peer sender --------------
Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Collections.Concurrent;
using System.Threading;
public class HotKeyApi {
    [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [StructLayout(LayoutKind.Sequential)] public struct MSG {
        public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int ptX; public int ptY;
    }
    [DllImport("user32.dll")] public static extern int GetMessage(out MSG msg, IntPtr hWnd, uint min, uint max);
    [DllImport("user32.dll")] public static extern bool PeekMessage(out MSG msg, IntPtr hWnd, uint min, uint max, uint remove);
    [DllImport("user32.dll")] public static extern bool TranslateMessage(ref MSG msg);
    [DllImport("user32.dll")] public static extern IntPtr DispatchMessage(ref MSG msg);
}
// Sends "<token>:<action>" lines to the peer on one background thread, in order, so a peer that
// is off (connect timeout) never blocks a hotkey or the wheel.
public static class PeerSender {
    static readonly BlockingCollection<string[]> queue = new BlockingCollection<string[]>();
    static string logPath;
    public static void Start(string log) {
        logPath = log;
        var t = new Thread(Loop) { IsBackground = true, Name = "PeerSender" };
        t.Start();
    }
    public static void Send(string host, int port, string token, string action) { queue.Add(new[] { host, port.ToString(), token, action }); }
    static void Loop() {
        foreach (var m in queue.GetConsumingEnumerable()) {
            string host = m[0], action = m[3];
            try {
                using (var c = new TcpClient()) {
                    var iar = c.BeginConnect(host, int.Parse(m[1]), null, null);
                    if (!iar.AsyncWaitHandle.WaitOne(1500)) throw new TimeoutException("connect timeout");
                    c.EndConnect(iar);
                    using (var w = new StreamWriter(c.GetStream())) { w.WriteLine(m[2] + ":" + action); w.Flush(); }
                }
                Log("forwarded '" + action + "' to " + host);
            } catch (Exception ex) { Log("could not reach peer " + host + ": " + ex.Message); }
        }
    }
    static void Log(string s) {
        string line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + s + Environment.NewLine;
        for (int i = 0; i < 5; i++) { try { File.AppendAllText(logPath, line); return; } catch (IOException) { Thread.Sleep(20); } }
    }
}
"@ -ErrorAction SilentlyContinue

# Set:<Feature>=+N / -N, optionally @<Monitor>: presses of these can be merged into one bigger step.
$RelativeAction = '^Set:(\w+)=([+-])(\d+)(@.+)?$'

# id -> @{ Vk; Modifiers; Action; Label }, from config.psd1 -> Hotkeys (Action, or Preset for older configs)
$Bindings = @{}
$nextId = 1
foreach ($h in @($cfg.Hotkeys)) {
    if (-not $h) { continue }
    try {
        $action = if ($h.Action) { [string]$h.Action } else { [string]$h.Preset }
        if (-not $action) { throw "hotkey '$($h.Keys)' has no Action" }
        # Relative steps (Set:Brightness=+10) repeat while held; queued repeats are merged below.
        $repeat = if ($h.ContainsKey('Repeat')) { [bool]$h.Repeat } else { $action -match $RelativeAction }
        $hk = ConvertTo-HotKey $h.Keys -AllowRepeat:$repeat
        $Bindings[$nextId] = @{ Vk = $hk.Vk; Modifiers = $hk.Modifiers; Action = $action; Label = $hk.Label }
        $nextId++
    } catch { Log ("Bad hotkey entry: " + $_.Exception.Message) }
}
if ($Bindings.Count -eq 0) { Log "WARNING: no Hotkeys defined in config.psd1" }

$WheelEnabled = $false
if (@($Bindings.Values | Where-Object { $_.Action -eq 'Wheel' }).Count) {
    try { . (Join-Path $ScriptDir 'ddc-wheel.ps1'); $WheelEnabled = $true }
    catch { Log ("Wheel unavailable: " + $_.Exception.Message) }
}

# --- Peer listener (separate runspace so it can block on Accept) -----------
$listenerScript = {
    param($ScriptDir, $Port, $Token, $LogPath, $PeerHost, $RestrictToPeer)
    . (Join-Path $ScriptDir 'ddc-lib.ps1')
    $peerLog = $LogPath   # captured for PLog (the analyzer misses param use inside nested functions)
    function PLog($m) {
        $line = "{0}  [peer] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
        for ($i = 0; $i -lt 5; $i++) {
            try { Add-Content -Path $peerLog -Value $line -Encoding UTF8 -ErrorAction Stop; return } catch { Start-Sleep -Milliseconds 20 }
        }
    }
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
                        $action = $parts[1].Trim()
                        try { $r = Invoke-DdcAction -Action $action; PLog ("applied '$action': " + ($r -join ' | ')) }
                        catch { PLog ("error applying '$action': " + $_.Exception.Message) }
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
    [PeerSender]::Start($LogPath)
}

# --- Run an action here and on the peer -------------------------------------
function Send-ToPeer([string]$action) {
    if (-not $NetworkEnabled) { return }
    if (-not $PeerHost) { Log "no PeerHost set - not forwarding (edit machine.local.psd1)"; return }
    [PeerSender]::Send($PeerHost, $Port, $Token, $action)
}

# Config is re-read per action, so presets/profiles can be edited without a restart.
function Invoke-Everywhere([string]$action, [string]$source) {
    try {
        $results = Invoke-DdcAction -Action $action -Config (Import-Config)   # local: only monitors we own
        Send-ToPeer $action                                                    # peer: monitors it owns
        Log ("{0} -> {1} (local): {2}" -f $source, $action, ($results -join ' | '))
        return $results
    } catch {
        Log ("ERROR applying '{0}': {1}" -f $action, $_.Exception.Message)
        return , ("Error: " + $_.Exception.Message)
    }
}

function Open-Wheel($binding, [int]$id) {
    $wcfg = Import-Config
    $run = {
        param($a)
        $r = Invoke-Everywhere $a 'Wheel'
        # The overlay has room for a short summary, not the full log line.
        (@($r) | ForEach-Object { $_ -replace '^\[(OK|SAME|SKIP|FAIL)\]\s*', '$1: ' }) -join "`n"
    }
    $status = { param($t) (Get-DdcStatus -Config $wcfg -Target $t) -join "`n" }
    $picked = Show-DdcWheel -Config $wcfg -Run $run -Status $status -TriggerVk $binding.Vk -HotkeyId $id
    if ($picked) { [void](Invoke-Everywhere $picked 'Wheel') }
}

# --- Register hotkeys ------------------------------------------------------
foreach ($id in $Bindings.Keys) {
    $b = $Bindings[$id]
    if ($b.Action -eq 'Wheel' -and -not $WheelEnabled) { continue }
    if ([HotKeyApi]::RegisterHotKey([IntPtr]::Zero, $id, $b.Modifiers, $b.Vk)) {
        Log ("Registered {0} -> {1}" -f $b.Label, $b.Action)
    } else {
        Log ("FAILED to register {0} (already in use?)" -f $b.Label)
    }
}

# --- Message loop ----------------------------------------------------------
# Non-hotkey messages are dispatched so the wheel's WPF windows keep working between uses.
# A DDC change takes a few hundred ms, so presses that queue up meanwhile (spamming the key, or
# holding it) are drained and merged: N queued "+10" presses become one "+N*10" step, capped at
# 3 presses so a held key ramps smoothly instead of jumping. Other hotkeys keep their order.
$WM_HOTKEY = 0x0312; $PM_REMOVE = 1; $MaxMerge = 3
$msg = New-Object HotKeyApi+MSG
$pending = New-Object 'System.Collections.Generic.Queue[int]'
try {
    while ($true) {
        if ($pending.Count) { $id = $pending.Dequeue() }
        else {
            if ([HotKeyApi]::GetMessage([ref]$msg, [IntPtr]::Zero, 0, 0) -le 0) { break }
            if ($msg.message -ne $WM_HOTKEY) {
                [void][HotKeyApi]::TranslateMessage([ref]$msg)
                [void][HotKeyApi]::DispatchMessage([ref]$msg)
                continue
            }
            $id = [int]$msg.wParam
        }
        if (-not $Bindings.ContainsKey($id)) { continue }
        $b = $Bindings[$id]
        if ($b.Action -eq 'Wheel') {
            try { Open-Wheel $b $id } catch { Log ("Wheel error: " + $_.Exception.Message) }
            continue
        }
        $action = $b.Action
        if ($action -match $RelativeAction) {
            $count = 1
            while ([HotKeyApi]::PeekMessage([ref]$msg, [IntPtr]::Zero, $WM_HOTKEY, $WM_HOTKEY, $PM_REMOVE)) {
                if ([int]$msg.wParam -eq $id) { $count++ } else { $pending.Enqueue([int]$msg.wParam) }
            }
            if ($count -gt 1) { $action = 'Set:{0}={1}{2}{3}' -f $Matches[1], $Matches[2], ([int]$Matches[3] * [math]::Min($count, $MaxMerge)), $Matches[4] }
        }
        [void](Invoke-Everywhere $action ("Hotkey " + $b.Label))
    }
}
finally {
    foreach ($id in $Bindings.Keys) { [void][HotKeyApi]::UnregisterHotKey([IntPtr]::Zero, $id) }
    if ($psListener) { try { $psListener.Stop() } catch { Log ("listener stop failed: " + $_.Exception.Message) } }
    Log "ddc-hotkeys stopped"
    $mutex.ReleaseMutex()
}
