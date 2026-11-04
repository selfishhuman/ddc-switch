<#
    ddc-wheel.ps1  -  Radial "weapon wheel" overlay for presets and monitor settings.
    Dot-sourced by ddc-hotkeys.ps1 (Wheel hotkey) and ddc.ps1 (`ddc.ps1 wheel`). Needs ddc-lib.ps1.

    Hold the hotkey, point toward a slice, release to pick it. Or tap the hotkey and click.
    Right-click / Backspace goes back, Esc or the hotkey again closes. Scroll over Brightness
    to adjust it. Click the centre to pick which monitor the settings apply to.
#>

Add-Type -ReferencedAssemblies PresentationFramework, PresentationCore, WindowsBase, System.Xaml -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

public class WheelItem {
    public string Label { get; set; }
    public string Action { get; set; }        // null for a category (has Children)
    public string Hint { get; set; }
    public bool Keep { get; set; }            // run in place and stay open (adjustments)
    public string ScrollAction { get; set; }  // e.g. "Set:Brightness={delta}", run when scrolling over it
    public int ScrollStep { get; set; }
    public string[] OnlyFor { get; set; }     // shown only when one of these monitors is the target (null = always)
    public List<WheelItem> Children { get; set; }
    public WheelItem() { Label = ""; Hint = ""; ScrollStep = 5; Children = new List<WheelItem>(); }
}

public class DdcWheel : Window {
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(POINT pt, uint flags);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr h, ref MONITORINFO mi);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);

    const int WM_HOTKEY = 0x0312, VK_ESCAPE = 0x1B;
    const double HoldMs = 350;

    class Surface : FrameworkElement {
        readonly DdcWheel w;
        public Surface(DdcWheel w) { this.w = w; }
        protected override void OnRender(DrawingContext dc) { w.Draw(dc, RenderSize); }
    }

    readonly Func<string, string> run, status;
    readonly string[] targets;
    readonly int triggerVk, hotkeyId;
    readonly Stack<WheelItem> path = new Stack<WheelItem>();
    readonly Surface surface;
    readonly DispatcherTimer poll, scrollTimer;
    WheelItem menu, scrollItem;
    int targetIdx, scrollNotches, hover = -2;   // hover: slice index, -1 = hub, -2 = nothing
    string statusText = "", resultText = "";
    bool triggerDown;
    DateTime openedAt;
    double outerR = 250, innerR = 105;
    public string Result { get; private set; }

    static readonly Brush Dim       = Frozen(Color.FromArgb(0x73, 0, 0, 0));
    static readonly Brush SliceFill = Frozen(Color.FromArgb(0xE0, 0x1C, 0x1C, 0x21));
    static readonly Brush SliceHot  = Frozen(Color.FromArgb(0xF2, 0xF2, 0xF2, 0xF2));
    static readonly Brush HubFill   = Frozen(Color.FromArgb(0xF0, 0x12, 0x12, 0x16));
    static readonly Brush TextMain  = Frozen(Color.FromRgb(0xFF, 0xFF, 0xFF));
    static readonly Brush TextDark  = Frozen(Color.FromRgb(0x10, 0x10, 0x14));
    static readonly Brush TextSoft  = Frozen(Color.FromArgb(0xB0, 0xFF, 0xFF, 0xFF));
    static readonly Brush Accent    = Frozen(Color.FromRgb(0xFF, 0xC8, 0x57));
    static readonly Pen   Edge      = FrozenPen(Color.FromArgb(0x40, 0xFF, 0xFF, 0xFF), 1);
    static readonly Typeface Ui     = new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);
    static readonly Typeface UiBold = new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal);
    static Brush Frozen(Color c) { var b = new SolidColorBrush(c); b.Freeze(); return b; }
    static Pen FrozenPen(Color c, double t) { var p = new Pen(Frozen(c), t); p.Freeze(); return p; }

    public static string Show(WheelItem root, string[] targets, Func<string, string> run, Func<string, string> status, int triggerVk, int hotkeyId) {
        var w = new DdcWheel(root, targets, run, status, triggerVk, hotkeyId);
        w.ShowDialog();
        return w.Result;
    }

    DdcWheel(WheelItem root, string[] targets, Func<string, string> run, Func<string, string> status, int triggerVk, int hotkeyId) {
        menu = root; this.targets = (targets != null && targets.Length > 0) ? targets : new[] { "All" };
        this.run = run; this.status = status; this.triggerVk = triggerVk; this.hotkeyId = hotkeyId;
        WindowStyle = WindowStyle.None; AllowsTransparency = true; Background = Dim;
        Topmost = true; ShowInTaskbar = false; ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.Manual; Left = 0; Top = 0; Width = 100; Height = 100;
        Title = "DDC wheel"; Opacity = 0;
        surface = new Surface(this);
        Content = surface;
        poll = new DispatcherTimer(DispatcherPriority.Input) { Interval = TimeSpan.FromMilliseconds(15) };
        poll.Tick += delegate { Poll(); };
        scrollTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(220) };
        scrollTimer.Tick += delegate { scrollTimer.Stop(); FlushScroll(); };

        SourceInitialized += delegate { CoverCursorMonitor(); };
        Loaded += delegate {
            openedAt = DateTime.Now;
            triggerDown = triggerVk != 0 && (GetAsyncKeyState(triggerVk) & 0x8000) != 0;
            SetForegroundWindow(new WindowInteropHelper(this).Handle); Activate(); Focus();
            BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(90)));
            poll.Start();
            RefreshStatus();
        };
        Closed += delegate { poll.Stop(); scrollTimer.Stop(); ComponentDispatcher.ThreadPreprocessMessage -= OnThreadMessage; };
        ComponentDispatcher.ThreadPreprocessMessage += OnThreadMessage;
        MouseLeftButtonUp += delegate { Click(); };
        MouseRightButtonUp += delegate { Back(); };
        MouseWheel += (s, e) => Scroll(e.Delta);
        KeyDown += (s, e) => {
            if (e.Key == Key.Escape) Close();
            else if (e.Key == Key.Back) Back();
        };
    }

    // Size the window to the whole monitor under the cursor (physical pixels, so mixed DPI is fine).
    void CoverCursorMonitor() {
        var hwnd = new WindowInteropHelper(this).Handle;
        SetWindowLong(hwnd, -20, GetWindowLong(hwnd, -20) | 0x80);   // WS_EX_TOOLWINDOW: no Alt+Tab entry
        POINT p; GetCursorPos(out p);
        var mi = new MONITORINFO { cbSize = Marshal.SizeOf(typeof(MONITORINFO)) };
        if (GetMonitorInfo(MonitorFromPoint(p, 2), ref mi))
            SetWindowPos(hwnd, new IntPtr(-1), mi.rcMonitor.L, mi.rcMonitor.T, mi.rcMonitor.R - mi.rcMonitor.L, mi.rcMonitor.B - mi.rcMonitor.T, 0x0010);
    }

    // Hotkeys are thread messages; the daemon's own loop is paused while the wheel is open.
    // Pressing the wheel hotkey again closes it; other hotkeys are ignored meanwhile.
    void OnThreadMessage(ref MSG msg, ref bool handled) {
        if (msg.message != WM_HOTKEY) return;
        handled = true;
        if ((int)msg.wParam == hotkeyId) Close();
    }

    // A monitor-specific choice (e.g. a picture mode only one monitor has) is hidden on "All".
    List<WheelItem> Items {
        get { return menu.Children.FindAll(i => i.OnlyFor == null || Array.IndexOf(i.OnlyFor, Target) >= 0); }
    }
    string Target { get { return targets[targetIdx]; } }

    void Poll() {
        if ((GetAsyncKeyState(VK_ESCAPE) & 0x8000) != 0) { Close(); return; }
        POINT p; GetCursorPos(out p);
        Point m = surface.PointFromScreen(new Point(p.X, p.Y));
        double dx = m.X - surface.ActualWidth / 2, dy = m.Y - surface.ActualHeight / 2;
        int h = -2;
        if (Math.Sqrt(dx * dx + dy * dy) < innerR) h = -1;
        else if (Items.Count > 0) {
            double slice = 360.0 / Items.Count;
            double a = Math.Atan2(dy, dx) * 180 / Math.PI + 90 + slice / 2;
            a = ((a % 360) + 360) % 360;
            h = Math.Min(Items.Count - 1, (int)(a / slice));
        }
        if (h != hover) { hover = h; surface.InvalidateVisual(); }

        // Hold-and-release: letting go of the hotkey picks the slice you're pointing at.
        // A quick tap leaves the wheel open for clicking instead.
        if (triggerDown && (GetAsyncKeyState(triggerVk) & 0x8000) == 0) {
            triggerDown = false;
            if ((DateTime.Now - openedAt).TotalMilliseconds >= HoldMs) {
                if (hover >= 0) Pick(Items[hover]); else if (hover == -2) Close();
            }
        }
    }

    void Click() {
        if (hover == -1) { targetIdx = (targetIdx + 1) % targets.Length; resultText = ""; RefreshStatus(); surface.InvalidateVisual(); }
        else if (hover >= 0) Pick(Items[hover]);
    }

    void Back() {
        if (path.Count > 0) { menu = path.Pop(); hover = -2; resultText = ""; surface.InvalidateVisual(); }
        else Close();
    }

    string WithTarget(string action) {
        if (Target == "All" || action.Contains("@")) return action;
        if (action.StartsWith("Set:") || action.StartsWith("Profile:") || action.StartsWith("Toggle:") || action.StartsWith("Look:")) return action + "@" + Target;
        return action;
    }

    void Pick(WheelItem item) {
        if (item.Children != null && item.Children.Count > 0) {
            path.Push(menu); menu = item; hover = -2; resultText = ""; surface.InvalidateVisual();
            return;
        }
        if (string.IsNullOrEmpty(item.Action)) return;
        if (!item.Keep) { Result = WithTarget(item.Action); Close(); return; }   // caller runs it after we close
        RunInPlace(WithTarget(item.Action));
    }

    void RunInPlace(string action) {
        resultText = "...";
        surface.InvalidateVisual();
        Dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(() => {
            try { resultText = run(action) ?? ""; } catch (Exception ex) { resultText = "Error: " + ex.Message; }
            surface.InvalidateVisual();
        }));
    }

    // Scrolling over an adjustable slice (or anywhere inside its submenu) batches the notches and
    // sends one relative change after a short pause, so the monitor isn't flooded with writes.
    void Scroll(int delta) {
        WheelItem it = (hover >= 0 && Items[hover].ScrollAction != null) ? Items[hover] : (menu.ScrollAction != null ? menu : null);
        if (it == null) return;
        if (scrollItem != it) { FlushScroll(); scrollItem = it; }
        scrollNotches += delta > 0 ? 1 : -1;
        int d = scrollNotches * it.ScrollStep;
        resultText = it.Label + " " + (d > 0 ? "+" : "") + d + " ...";
        surface.InvalidateVisual();
        scrollTimer.Stop(); scrollTimer.Start();
    }

    void FlushScroll() {
        if (scrollItem == null || scrollNotches == 0) { scrollNotches = 0; return; }
        int d = scrollNotches * scrollItem.ScrollStep;
        string action = scrollItem.ScrollAction.Replace("{delta}", (d > 0 ? "+" : "") + d);
        scrollNotches = 0;
        RunInPlace(WithTarget(action));
    }

    void RefreshStatus() {
        if (status == null) return;
        string t = Target;
        Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, new Action(() => {
            try { statusText = status(t) ?? ""; } catch (Exception ex) { statusText = "Status error: " + ex.Message; }
            surface.InvalidateVisual();
        }));
    }

    // ---- drawing ----
    static Point Polar(double cx, double cy, double r, double deg) {
        double a = deg * Math.PI / 180;
        return new Point(cx + r * Math.Cos(a), cy + r * Math.Sin(a));
    }

    static Geometry Slice(double cx, double cy, double rIn, double rOut, double a0, double a1) {
        bool large = (a1 - a0) > 180;
        var g = new StreamGeometry();
        using (var c = g.Open()) {
            c.BeginFigure(Polar(cx, cy, rOut, a0), true, true);
            c.ArcTo(Polar(cx, cy, rOut, a1), new Size(rOut, rOut), 0, large, SweepDirection.Clockwise, true, false);
            c.LineTo(Polar(cx, cy, rIn, a1), true, false);
            c.ArcTo(Polar(cx, cy, rIn, a0), new Size(rIn, rIn), 0, large, SweepDirection.Counterclockwise, true, false);
        }
        g.Freeze();
        return g;
    }

    FormattedText Text(string s, double size, Brush b, Typeface tf, double maxWidth) {
        var ft = new FormattedText(s ?? "", CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, tf, size, b,
                                   VisualTreeHelper.GetDpi(this).PixelsPerDip);
        ft.TextAlignment = TextAlignment.Center;
        if (maxWidth > 0) ft.MaxTextWidth = maxWidth;
        return ft;
    }

    void DrawText(DrawingContext dc, FormattedText ft, double cx, double cy) {
        // With TextAlignment.Center the origin x is the centre of a MaxTextWidth-wide box.
        double w = ft.MaxTextWidth > 0 ? ft.MaxTextWidth : ft.Width;
        dc.DrawText(ft, new Point(cx - w / 2, cy - ft.Height / 2));
    }

    internal void Draw(DrawingContext dc, Size size) {
        double cx = size.Width / 2, cy = size.Height / 2;
        outerR = Math.Min(250, Math.Min(size.Width, size.Height) * 0.36);
        innerR = outerR * 0.42;
        int n = Items.Count;
        double slice = n > 0 ? 360.0 / n : 360, gap = n > 1 ? 1.2 : 0;
        for (int i = 0; i < n; i++) {
            var it = Items[i];
            bool hot = i == hover;
            double mid = -90 + i * slice;
            double a0 = mid - slice / 2 + gap, a1 = mid + slice / 2 - gap;
            if (n == 1) { a0 = -90; a1 = 269.9; }
            double rOut = outerR + (hot ? 10 : 0);
            dc.DrawGeometry(hot ? SliceHot : SliceFill, Edge, Slice(cx, cy, innerR + 4, rOut, a0, a1));
            string label = it.Label + ((it.Children != null && it.Children.Count > 0) ? "  " + (char)0x203A : "");
            var ft = Text(label, 16, hot ? TextDark : TextMain, hot ? UiBold : Ui, (outerR - innerR) * 0.95);
            Point c = Polar(cx, cy, (innerR + rOut) / 2, mid);
            DrawText(dc, ft, c.X, c.Y);
        }

        // Hub: where you are, what you're pointing at, and which monitor settings go to.
        dc.DrawEllipse(HubFill, Edge, new Point(cx, cy), innerR, innerR);
        string title = path.Count == 0 ? "Monitors" : menu.Label;
        string line = "", hint = "";
        if (hover >= 0) { line = Items[hover].Label; hint = Items[hover].Hint; }
        else if (hover == -1) { line = "Target"; hint = "click to change"; }
        double tw = innerR * 1.7;
        DrawText(dc, Text(title, 13, TextSoft, Ui, tw), cx, cy - innerR * 0.55);
        DrawText(dc, Text(line, 20, TextMain, UiBold, tw), cx, cy - innerR * 0.12);
        if (!string.IsNullOrEmpty(hint)) DrawText(dc, Text(hint, 12, TextSoft, Ui, tw), cx, cy + innerR * 0.2);
        DrawText(dc, Text((char)0x25C2 + " " + Target + " " + (char)0x25B8, 14, hover == -1 ? Accent : TextMain, UiBold, tw), cx, cy + innerR * 0.58);

        // Below the wheel: live status of this machine's monitors, then the last result.
        double y = cy + outerR + 28;
        if (!string.IsNullOrEmpty(statusText)) {
            var st = Text(statusText, 13, TextMain, Ui, Math.Min(size.Width - 40, 900));
            DrawText(dc, st, cx, y + st.Height / 2); y += st.Height + 10;
        }
        if (!string.IsNullOrEmpty(resultText)) {
            var rt = Text(resultText, 13, Accent, Ui, Math.Min(size.Width - 40, 900));
            DrawText(dc, rt, cx, y + rt.Height / 2); y += rt.Height + 10;
        }
        var help = Text("Release / click to pick   " + (char)0x2022 + "   Right-click: back   " + (char)0x2022 + "   Scroll: adjust   " + (char)0x2022 + "   Esc: close", 12, TextSoft, Ui, 0);
        dc.DrawText(help, new Point(cx - help.Width / 2, cy - outerR - 40));
    }
}
"@ -ErrorAction SilentlyContinue

function New-WheelItem {
    param([string]$Label, [string]$Action, [string]$Hint = '', [switch]$Keep, [string]$ScrollAction, [int]$ScrollStep = 5, [string[]]$OnlyFor, [object[]]$Children)
    $i = New-Object WheelItem
    $i.Label = $Label; $i.Hint = $Hint; $i.Keep = [bool]$Keep; $i.ScrollStep = $ScrollStep
    if ($Action) { $i.Action = $Action }
    if ($ScrollAction) { $i.ScrollAction = $ScrollAction }
    if ($OnlyFor) { $i.OnlyFor = $OnlyFor }
    foreach ($c in @($Children)) { if ($c) { $i.Children.Add($c) } }
    return $i
}

# Wheel items for a List feature: each monitor's own names (config override, else the defaults).
# A name every monitor has is shown always; one only some monitors have is shown only when
# targeting those monitors, so "All" never offers a mode a monitor would skip.
function Get-WheelChoiceItem {
    param($Config, [string]$Feature, [string[]]$Default)
    $key = $script:FeatureNameKeys[$Feature]
    $owners = [ordered]@{}
    $monitors = @($Config.Monitors | Where-Object { $_ })
    foreach ($rule in $monitors) {
        $names = if ($rule[$key]) { @($rule[$key].Keys | Sort-Object { $rule[$key][$_] }) } else { $Default }
        foreach ($n in $names) { if (-not $owners.Contains($n)) { $owners[$n] = @() }; $owners[$n] += [string]$rule.Name }
    }
    foreach ($n in $owners.Keys) {
        $only = if ($owners[$n].Count -lt $monitors.Count) { [string[]]$owners[$n] } else { $null }
        New-WheelItem -Label $n -Action "Set:$Feature=$n" -Keep -OnlyFor $only -Hint $(if ($only) { $only -join ', ' } else { '' })
    }
}

function Get-WheelMenu {
    param([Parameter(Mandatory)]$Config)
    $labels = if ($Config.PresetLabels) { $Config.PresetLabels } else { @{} }
    $layout = foreach ($p in ($Config.Presets.Keys | Sort-Object)) {
        New-WheelItem -Label $(if ($labels[$p]) { $labels[$p] } else { $p }) -Action $p -Hint "preset $p"
    }
    $level = {
        param($Feature, $Label)
        $kids = @(
            New-WheelItem -Label '-10' -Action "Set:$Feature=-10" -Keep
            New-WheelItem -Label '+10' -Action "Set:$Feature=+10" -Keep
        ) + (0, 25, 50, 75, 100 | ForEach-Object { New-WheelItem -Label "$_%" -Action "Set:$Feature=$_%" -Keep })
        New-WheelItem -Label $Label -Hint 'scroll to adjust' -ScrollAction "Set:$Feature={delta}" -Children $kids
    }
    # Contrast, Picture mode, Volume and Mute are left off: neither monitor supports Mute over DDC,
    # only the F270i has Volume, and picture modes override brightness. They still work as hotkey actions.
    $temps = Get-WheelChoiceItem $Config 'ColorTemp' @('6500K', '9300K', 'sRGB', 'User1')
    # Saved looks (saved.psd1) plus a slot to save the current settings as the next "Look N".
    $lookNames = @(if ($Config.Looks) { $Config.Looks.Keys | Sort-Object })
    $n = 1; while ($lookNames -contains "Look $n") { $n++ }
    $looks = @(foreach ($l in $lookNames) { New-WheelItem -Label $l -Action "Look:$l" -Hint 'apply look' }) +
             @(New-WheelItem -Label '+ Save current' -Action "Save:Look $n" -Hint "as 'Look $n' (rename in saved.psd1)")
    $items = @(
        New-WheelItem -Label 'Layout' -Hint 'switch inputs' -Children $layout
        New-WheelItem -Label 'Looks' -Hint 'saved settings' -Children $looks
        & $level 'Brightness' 'Brightness'
        New-WheelItem -Label 'Colour temp' -Children $temps
    )
    $profiles = @()
    if ($Config.Profiles) {
        if ($Config.Profiles.ContainsKey('Reading')) { $items += New-WheelItem -Label 'Reading' -Action 'Toggle:Reading' -Hint 'toggle on / off' }
        $profiles = foreach ($p in ($Config.Profiles.Keys | Where-Object { $_ -ne 'Reading' } | Sort-Object)) {
            New-WheelItem -Label $p -Action "Profile:$p" -Keep
        }
    }
    if ($profiles) { $items += New-WheelItem -Label 'Profiles' -Children $profiles }
    return New-WheelItem -Label 'Monitors' -Children $items
}

# Show the wheel. $Run executes an action string (and returns a short result); $Status returns the
# status text for a target. Returns the action picked from a closing slice (e.g. a preset), or $null;
# the caller runs it after the overlay is gone.
function Show-DdcWheel {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][scriptblock]$Run, [scriptblock]$Status, [int]$TriggerVk = 0, [int]$HotkeyId = 0)
    $targets = @('All') + @($Config.Monitors | ForEach-Object { [string]$_.Name })
    $runFn    = [Func[string, string]]$Run
    $statusFn = if ($Status) { [Func[string, string]]$Status } else { $null }
    return [DdcWheel]::Show((Get-WheelMenu $Config), [string[]]$targets, $runFn, $statusFn, $TriggerVk, $HotkeyId)
}
