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

# Logging, forwarding and "run an action here and on the peer". Defined once and loaded both here
# and in the worker runspace (below), which is where monitor actions actually run.
$Shared = {
    # The listener runspace, the worker and the peer sender write the same file, so retry briefly
    # on a lock rather than let a logging error kill the daemon.
    function Log([string]$msg) {
        $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
        for ($i = 0; $i -lt 5; $i++) {
            try { Add-Content -Path $LogPath -Value $line -Encoding UTF8 -ErrorAction Stop; return } catch { Start-Sleep -Milliseconds 20 }
        }
    }
    function Send-ToPeer([string]$action) {
        if (-not $NetworkEnabled) { return }
        if (-not $PeerHost) { Log "no PeerHost set - not forwarding (edit machine.local.psd1)"; return }
        [PeerSender]::Send($PeerHost, $Port, $Token, $action)
    }
    # Config is re-read per action, so presets/profiles can be edited without a restart.
    function Invoke-Everywhere([string]$action, [string]$source) {
        try {
            Send-ToPeer $action                                                    # peer: monitors it owns (queued, in the background)
            $results = Invoke-DdcAction -Action $action -Config (Import-Config)   # local: only monitors we own
            Log ("{0} -> {1} (local): {2}" -f $source, $action, ($results -join ' | '))
            return $results
        } catch {
            Log ("ERROR applying '{0}': {1}" -f $action, $_.Exception.Message)
            return , ("Error: " + $_.Exception.Message)
        }
    }
}
. $Shared

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
using System.Collections.Generic;
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
// Black windows over blanked monitors (Blank:On / Off / Toggle, see Switch-DdcBlank in ddc-lib.ps1).
// Plain Win32 on its own thread, so they never depend on the hotkey loop or WPF. They swallow clicks
// without taking focus and hide the cursor; double-click one to un-blank that monitor.
public static class BlankOverlay {
    delegate IntPtr WndProc(IntPtr h, uint m, IntPtr w, IntPtr l);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WNDCLASSEX {
        public uint cbSize; public uint style; public WndProc lpfnWndProc; public int cbClsExtra; public int cbWndExtra;
        public IntPtr hInstance; public IntPtr hIcon; public IntPtr hCursor; public IntPtr hbrBackground;
        public string lpszMenuName; public string lpszClassName; public IntPtr hIconSm;
    }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern ushort RegisterClassEx(ref WNDCLASSEX c);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowEx(uint ex, string cls, string title, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr DefWindowProc(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hgt, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr mon, ref MONITORINFO mi);
    [DllImport("user32.dll")] static extern IntPtr SetCursor(IntPtr c);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetMessage(out HotKeyApi.MSG m, IntPtr h, uint a, uint b);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool PeekMessage(out HotKeyApi.MSG m, IntPtr h, uint a, uint b, uint remove);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref HotKeyApi.MSG m);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr DispatchMessage(ref HotKeyApi.MSG m);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool PostThreadMessage(uint tid, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string n);
    [DllImport("gdi32.dll")] static extern IntPtr GetStockObject(int i);

    const uint WM_RUN = 0x8000;   // WM_APP: run the queued jobs
    const string ClassName = "DdcSwitchBlank";
    static readonly object gate = new object();
    static readonly HashSet<string> shown = new HashSet<string>();                    // wanted state, any thread (under gate)
    static readonly ConcurrentQueue<Action> jobs = new ConcurrentQueue<Action>();
    static readonly Dictionary<string, IntPtr> windows = new Dictionary<string, IntPtr>();   // overlay thread only
    static readonly Dictionary<IntPtr, string> names = new Dictionary<IntPtr, string>();     // overlay thread only
    static WndProc proc;   // held so the GC never collects the delegate Windows calls back
    static uint threadId;

    public static bool IsShown(string name) { lock (gate) return shown.Contains(name); }
    public static void Show(string name, long hMonitor) {
        lock (gate) shown.Add(name);
        Run(() => Place(name, new IntPtr(hMonitor)));
    }
    public static void Hide(string name) {
        lock (gate) shown.Remove(name);
        Run(() => {
            IntPtr h;
            if (windows.TryGetValue(name, out h)) { windows.Remove(name); names.Remove(h); DestroyWindow(h); }
        });
    }

    static void Run(Action job) {
        lock (gate) {
            if (threadId == 0) {
                var ready = new ManualResetEventSlim();
                var t = new Thread(() => Loop(ready)) { IsBackground = true, Name = "BlankOverlay" };
                t.Start(); ready.Wait();
            }
        }
        jobs.Enqueue(job);
        PostThreadMessage(threadId, WM_RUN, IntPtr.Zero, IntPtr.Zero);
    }

    static void Loop(ManualResetEventSlim ready) {
        // Per-monitor DPI aware (v2): monitor rects and window positions are both real pixels.
        try { SetThreadDpiAwarenessContext(new IntPtr(-4)); } catch { }
        proc = WndProcImpl;
        var wc = new WNDCLASSEX {
            cbSize = (uint)Marshal.SizeOf(typeof(WNDCLASSEX)), style = 0x0008 /* CS_DBLCLKS */, lpfnWndProc = proc,
            hInstance = GetModuleHandle(null), hbrBackground = GetStockObject(4) /* BLACK_BRUSH */, lpszClassName = ClassName
        };
        RegisterClassEx(ref wc);
        HotKeyApi.MSG m;
        PeekMessage(out m, IntPtr.Zero, 0, 0, 0);   // creates this thread's queue, so PostThreadMessage can reach it
        threadId = GetCurrentThreadId();
        ready.Set();
        while (GetMessage(out m, IntPtr.Zero, 0, 0) > 0) {
            if (m.hwnd == IntPtr.Zero && m.message == WM_RUN) {
                Action job;
                while (jobs.TryDequeue(out job)) { try { job(); } catch { } }
                continue;
            }
            TranslateMessage(ref m); DispatchMessage(ref m);
        }
    }

    static void Place(string name, IntPtr hMon) {
        lock (gate) { if (!shown.Contains(name)) return; }   // hidden again before this ran
        var mi = new MONITORINFO { cbSize = Marshal.SizeOf(typeof(MONITORINFO)) };
        if (!GetMonitorInfo(hMon, ref mi)) return;
        var r = mi.rcMonitor; int w = r.right - r.left, h = r.bottom - r.top;
        IntPtr hwnd;
        if (!windows.TryGetValue(name, out hwnd)) {
            // WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW (no taskbar / Alt+Tab) | WS_EX_TOPMOST, WS_POPUP
            hwnd = CreateWindowEx(0x08000000 | 0x80 | 0x8, ClassName, "DDC Switch blank", 0x80000000, r.left, r.top, w, h, IntPtr.Zero, IntPtr.Zero, GetModuleHandle(null), IntPtr.Zero);
            if (hwnd == IntPtr.Zero) return;
            windows[name] = hwnd; names[hwnd] = name;
        }
        SetWindowPos(hwnd, new IntPtr(-1) /* HWND_TOPMOST */, r.left, r.top, w, h, 0x0010 | 0x0040 /* NOACTIVATE | SHOWWINDOW */);
    }

    static IntPtr WndProcImpl(IntPtr h, uint msg, IntPtr w, IntPtr l) {
        switch (msg) {
            case 0x0020: SetCursor(IntPtr.Zero); return new IntPtr(1);   // WM_SETCURSOR: no cursor over the black
            case 0x0021: return new IntPtr(3);                           // WM_MOUSEACTIVATE: MA_NOACTIVATE, the click is swallowed
            case 0x0203: {                                               // WM_LBUTTONDBLCLK: un-blank (this machine only)
                string n;
                if (names.TryGetValue(h, out n)) DdcWorker.Invoke("Invoke-DdcAction", new[] { "Blank:Off@" + n }, null);
                return IntPtr.Zero;
            }
        }
        return DefWindowProc(h, msg, w, l);
    }
}
// Runs every monitor action and status read, one at a time and in order, on one background thread
// with its own PowerShell runspace, so the hotkey loop and the wheel never wait on DDC.
// Each job is a real pipeline (PowerShell.Invoke): calling script delegates directly breaks
// try/finally in Windows PowerShell 5.1.
public static class DdcWorker {
    static readonly BlockingCollection<Action> queue = new BlockingCollection<Action>();
    static readonly object gate = new object();
    static System.Management.Automation.Runspaces.Runspace runspace;
    static string statusTarget; static Action<string> statusDone; static bool statusQueued;
    public static void Start(System.Management.Automation.Runspaces.Runspace rs) {
        runspace = rs;
        var t = new Thread(() => { foreach (var job in queue.GetConsumingEnumerable()) { try { job(); } catch { } } }) { IsBackground = true, Name = "DdcWorker" };
        t.Start();
    }
    static string Call(string command, params string[] args) {
        using (var ps = System.Management.Automation.PowerShell.Create()) {
            ps.Runspace = runspace;
            ps.AddCommand(command);
            foreach (var a in args) ps.AddArgument(a);
            var outp = ps.Invoke();
            var parts = new List<string>();
            foreach (var o in outp) if (o != null) parts.Add(o.ToString());
            if (parts.Count == 0 && ps.Streams.Error.Count > 0) return "Error: " + ps.Streams.Error[0].ToString();
            return string.Join("\n", parts);
        }
    }
    public static void Post(string source, string action, Action<string> done) {
        queue.Add(() => {
            string res;
            try { res = Call("Invoke-WorkerAction", source, action); } catch (Exception ex) { res = "Error: " + ex.Message; }
            if (done != null) done(res);
        });
    }
    // Any ddc-lib function by name (the tuner uses this), with string arguments.
    public static void Invoke(string command, string[] args, Action<string> done) {
        queue.Add(() => {
            string res;
            try { res = Call(command, args ?? new string[0]); } catch (Exception ex) { res = "Error: " + ex.Message; }
            if (done != null) done(res);
        });
    }
    public static string RunSync(string source, string action) {
        string res = null;
        using (var ev = new ManualResetEventSlim()) { Post(source, action, r => { res = r; ev.Set(); }); ev.Wait(); }
        return res;
    }
    // Status reads coalesce: only the latest request still waiting is run.
    public static void Status(string target, Action<string> done) {
        lock (gate) { statusTarget = target; statusDone = done; if (statusQueued) return; statusQueued = true; }
        queue.Add(() => {
            string t; Action<string> d;
            lock (gate) { t = statusTarget; d = statusDone; statusQueued = false; }
            string res;
            try { res = Call("Get-WorkerStatus", t); } catch (Exception ex) { res = "Status error: " + ex.Message; }
            if (d != null) d(res);
        });
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
$TunerEnabled = $false
try { . (Join-Path $ScriptDir 'ddc-tuner.ps1'); $TunerEnabled = $true }
catch { Log ("Tuner unavailable: " + $_.Exception.Message) }

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

# --- Worker runspace: runs all monitor actions off the hotkey / wheel thread --------
$workerInit = {
    param($ScriptDir, $SharedText, $LogPath, $NetworkEnabled, $PeerHost, $Port, $Token)
    # The shared helpers (Log, Invoke-Everywhere, ...) read these from this scope; touch them so the analyzer sees them used.
    $null = $LogPath, $NetworkEnabled, $PeerHost, $Port, $Token
    . (Join-Path $ScriptDir 'ddc-lib.ps1')
    . ([scriptblock]::Create($SharedText))
    function global:Invoke-WorkerAction([string]$source, [string]$action) {
        $r = Invoke-Everywhere $action $source
        # The wheel has room for a short summary, not the full log line.
        (@($r) | ForEach-Object { $_ -replace '^\[(OK|SAME|SKIP|FAIL)\]\s*', '$1: ' }) -join "`n"
    }
    function global:Get-WorkerStatus([string]$target) {
        try { (Get-DdcStatus -Config (Import-Config) -Target $target) -join "`n" } catch { 'Status error: ' + $_.Exception.Message }
    }
}
$wrs = [runspacefactory]::CreateRunspace(); $wrs.Open()
$psInit = [powershell]::Create(); $psInit.Runspace = $wrs
[void]$psInit.AddScript($workerInit).AddArgument($ScriptDir).AddArgument($Shared.ToString()).AddArgument($LogPath).AddArgument($NetworkEnabled).AddArgument($PeerHost).AddArgument($Port).AddArgument($Token)
[void]$psInit.Invoke()
if ($psInit.HadErrors) { Log ("FATAL: worker init failed: " + ($psInit.Streams.Error | Out-String)); throw 'worker init failed' }
$psInit.Dispose()
[DdcWorker]::Start($wrs)

# A monitor blanked when the daemon last stopped has no black window any more but is still at
# brightness 0: give it its brightness back (on this machine only - not forwarded).
foreach ($k in @((Read-DdcState).Keys | Where-Object { $_ -like 'Blank|*' })) {
    $mon = $k.Substring(6)
    Log "restoring brightness of $mon (was blanked when the daemon stopped)"
    [DdcWorker]::Invoke('Invoke-DdcAction', [string[]]@("Blank:Off@$mon"), $null)
}

$WheelRun    = [Action[string, Action[string]]]{ param($a, $cb) [DdcWorker]::Post('Wheel', $a, $cb) }
$WheelStatus = [Action[string, Action[string]]]{ param($t, $cb) [DdcWorker]::Status($t, $cb) }
if ($WheelEnabled) {
    # Build the overlay now and read the monitors once (also caches their capabilities), so the
    # first Ctrl+Alt+Space opens instantly with live values.
    try { [DdcWheel]::Warm($WheelStatus) } catch { Log ("Wheel warm-up failed: " + $_.Exception.Message) }
}

# The picked action (a preset, profile, look) is queued, so the wheel is gone immediately and the
# hotkey loop is free again while the monitors switch.
function Open-Wheel($binding, [int]$id) {
    $picked = Show-DdcWheel -Config (Import-Config) -RunAsync $WheelRun -StatusAsync $WheelStatus -TriggerVk $binding.Vk -HotkeyId $id
    if ($picked -eq 'Tune') { Open-Tuner }
    elseif ($picked) { [DdcWorker]::Post('Wheel', $picked, $null) }
}

# The tuner's reads and writes go through the worker (local monitors only, never forwarded);
# results come back on this thread's dispatcher. Hotkeys are ignored while it's open.
function Open-Tuner {
    if (-not $TunerEnabled) { Log 'Tuner unavailable'; return }
    $disp = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
    $call = { param($c, $a, $done) [DdcWorker]::Invoke($c, [string[]]@($a), [UiPost]::Wrap($disp, [Action[string]]$done)) }.GetNewClosure()
    Log 'Tuner opened'
    Show-DdcTuner -Call $call
    Log 'Tuner closed'
}

# --- Register hotkeys ------------------------------------------------------
foreach ($id in $Bindings.Keys) {
    $b = $Bindings[$id]
    if ($b.Action -eq 'Wheel' -and -not $WheelEnabled) { continue }
    if ($b.Action -eq 'Tune' -and -not $TunerEnabled) { continue }
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
                # A WPF callback that throws surfaces here. Log it and keep going: letting it escape
                # ends the loop, and with it every hotkey.
                try {
                    [void][HotKeyApi]::TranslateMessage([ref]$msg)
                    [void][HotKeyApi]::DispatchMessage([ref]$msg)
                } catch { Log ("UI error (ignored): " + $_.Exception.Message) }
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
        if ($b.Action -eq 'Tune') {
            try { Open-Tuner } catch { Log ("Tuner error: " + $_.Exception.Message) }
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
        [void][DdcWorker]::RunSync(("Hotkey " + $b.Label), $action)
    }
}
catch { Log ("FATAL in message loop: " + $_.Exception.Message); throw }
finally {
    foreach ($id in $Bindings.Keys) { [void][HotKeyApi]::UnregisterHotKey([IntPtr]::Zero, $id) }
    Log "ddc-hotkeys stopped"
    # Stop() would wait forever for the listener's blocking AcceptTcpClient; don't wait for it.
    if ($psListener) { try { [void]$psListener.BeginStop($null, $null) } catch { Log ("listener stop failed: " + $_.Exception.Message) } }
    try { $mutex.ReleaseMutex() } catch { $null = $_ }
    [Environment]::Exit(0)   # the listener runspace's thread would otherwise keep this process alive
}
