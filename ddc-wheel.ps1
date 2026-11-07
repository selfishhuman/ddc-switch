<#
    ddc-wheel.ps1  -  Radial "weapon wheel" overlay for presets and monitor settings.
    Dot-sourced by ddc-hotkeys.ps1 (Wheel hotkey) and ddc.ps1 (`ddc.ps1 wheel`). Needs ddc-lib.ps1.

    Hold the hotkey, flick toward a slice, release to pick it (release in the centre cancels).
    Or tap the hotkey and click / press 1-9. Right-click / Backspace goes back, Esc or the hotkey
    again closes. Scroll over Brightness to adjust it. Click the centre (or Tab) to pick which
    monitor the settings apply to.

    Smoothness: the window is created once and re-shown (no WPF start-up cost per open), it is only
    wheel-sized (a full-screen transparent window is slow to redraw), it opens centred on the mouse,
    and monitor reads/writes go through the caller's async callbacks so the UI never waits on DDC.
#>

Add-Type -ReferencedAssemblies PresentationFramework, PresentationCore, WindowsBase, System.Xaml -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.ComponentModel;
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
    public string Glyph { get; set; }         // Segoe MDL2 / Fluent icon character, optional
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
    const double HoldMs = 300;
    // Window size and wheel geometry in DIPs. The wheel centre sits at (Wd/2, Cy).
    const double Wd = 660, Ht = 720, Cy = 300, OuterR = 230, InnerR = 96;

    class Surface : FrameworkElement {
        readonly DdcWheel w;
        public Surface(DdcWheel w) { this.w = w; }
        protected override void OnRender(DrawingContext dc) { w.Draw(dc); }
    }

    static DdcWheel instance;
    static readonly Dictionary<string, string> statusCache = new Dictionary<string, string>();

    readonly Surface surface;
    readonly ScaleTransform zoom;
    readonly DispatcherTimer poll, scrollTimer;
    readonly Stack<WheelItem> path = new Stack<WheelItem>();
    readonly IntPtr hwnd;
    Action<string, Action<string>> run, status;
    string[] targets = { "All" };
    int triggerVk, hotkeyId;
    DispatcherFrame frame;
    WheelItem menu, scrollItem;
    List<WheelItem> items = new List<WheelItem>();
    double[] heat = new double[0];
    double hubHeat;
    int targetIdx, scrollNotches, hover = -2, statusSeq, busy;   // hover: slice index, -1 = hub, -2 = nothing
    string statusText = "", resultText = "";
    bool triggerDown, open;
    DateTime openedAt;
    public string Result { get; private set; }

    static readonly Brush Backdrop;
    static readonly Brush HitFill   = Frozen(Color.FromArgb(0x01, 0, 0, 0));   // keeps the whole window clickable
    static readonly Color SliceCol  = Color.FromArgb(0xE6, 0x1E, 0x1F, 0x26);
    static readonly Color SliceHotC = Color.FromArgb(0xF5, 0xF4, 0xF4, 0xF6);
    static readonly Brush HubFill   = Frozen(Color.FromArgb(0xF2, 0x13, 0x14, 0x19));
    static readonly Brush TextMain  = Frozen(Color.FromRgb(0xFF, 0xFF, 0xFF));
    static readonly Brush TextDark  = Frozen(Color.FromRgb(0x14, 0x14, 0x18));
    static readonly Brush TextSoft  = Frozen(Color.FromArgb(0xB4, 0xFF, 0xFF, 0xFF));
    static readonly Brush Accent    = Frozen(Color.FromRgb(0xFF, 0xC8, 0x57));
    static readonly Brush Panel     = Frozen(Color.FromArgb(0xD8, 0x13, 0x14, 0x19));
    static readonly Pen   Edge      = FrozenPen(Color.FromArgb(0x38, 0xFF, 0xFF, 0xFF), 1);
    static readonly Pen   AccentArc;
    static readonly Pen   AccentRing;
    static readonly Typeface Ui     = new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);
    static readonly Typeface UiBold = new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal);
    static readonly Typeface Icons  = new Typeface(new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"), FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);
    static Brush Frozen(Color c) { var b = new SolidColorBrush(c); b.Freeze(); return b; }
    static Pen FrozenPen(Color c, double t) { var p = new Pen(Frozen(c), t); p.Freeze(); return p; }

    static DdcWheel() {
        var g = new RadialGradientBrush();
        g.GradientStops.Add(new GradientStop(Color.FromArgb(0x90, 0, 0, 0), 0.0));
        g.GradientStops.Add(new GradientStop(Color.FromArgb(0x80, 0, 0, 0), 0.72));
        g.GradientStops.Add(new GradientStop(Color.FromArgb(0x00, 0, 0, 0), 1.0));
        g.Freeze();
        Backdrop = g;
        var a = new Pen(Accent, 4) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round }; a.Freeze(); AccentArc = a;
        var r = new Pen(Accent, 2); r.Freeze(); AccentRing = r;
    }

    // Build the window ahead of time (and optionally fetch status) so the first open is instant.
    public static void Warm(Action<string, Action<string>> status) {
        if (instance == null) instance = new DdcWheel();
        if (status != null) status("All", s => { lock (statusCache) statusCache["All"] = s ?? ""; });
    }

    // Shows the wheel and returns the action of a closing slice (e.g. a preset), or null.
    // run / status get an action or target and a callback for the result; they may complete on any thread.
    public static string Show(WheelItem root, string[] targets, Action<string, Action<string>> run, Action<string, Action<string>> status, int triggerVk, int hotkeyId) {
        if (instance == null) instance = new DdcWheel();
        if (instance.open) return null;
        return instance.OpenWheel(root, targets, run, status, triggerVk, hotkeyId);
    }

    DdcWheel() {
        WindowStyle = WindowStyle.None; AllowsTransparency = true; Background = Brushes.Transparent;
        Topmost = true; ShowInTaskbar = false; ResizeMode = ResizeMode.NoResize; ShowActivated = true;
        WindowStartupLocation = WindowStartupLocation.Manual; Width = Wd; Height = Ht; Left = -10000; Top = -10000;
        Title = "DDC wheel";
        surface = new Surface(this);
        zoom = new ScaleTransform(1, 1, Wd / 2, Cy);
        surface.RenderTransform = zoom;
        Content = surface;
        hwnd = new WindowInteropHelper(this).EnsureHandle();
        SetWindowLong(hwnd, -20, GetWindowLong(hwnd, -20) | 0x80);   // WS_EX_TOOLWINDOW: no Alt+Tab entry

        poll = new DispatcherTimer(DispatcherPriority.Input) { Interval = TimeSpan.FromMilliseconds(12) };
        poll.Tick += delegate { Poll(); };
        scrollTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(200) };
        scrollTimer.Tick += delegate { scrollTimer.Stop(); FlushScroll(); };

        ComponentDispatcher.ThreadPreprocessMessage += OnThreadMessage;
        MouseLeftButtonUp += delegate { if (open) Click(); };
        MouseRightButtonUp += delegate { if (open) Back(); };
        MouseWheel += (s, e) => { if (open) Scroll(e.Delta); };
        KeyDown += (s, e) => { if (open) OnKey(e.Key); };
        // Keep the mouse captured while open so clicks just outside the wheel still reach it.
        LostMouseCapture += delegate {
            if (open) Dispatcher.BeginInvoke(DispatcherPriority.Input, new Action(() => { if (open && IsActive) Mouse.Capture(this, CaptureMode.SubTree); }));
        };
    }

    protected override void OnClosing(CancelEventArgs e) { e.Cancel = true; Dismiss(); }   // Alt+F4 hides, never destroys

    string OpenWheel(WheelItem root, string[] targets, Action<string, Action<string>> run, Action<string, Action<string>> status, int triggerVk, int hotkeyId) {
        this.targets = (targets != null && targets.Length > 0) ? targets : new[] { "All" };
        this.run = run; this.status = status; this.triggerVk = triggerVk; this.hotkeyId = hotkeyId;
        menu = root; path.Clear(); targetIdx = 0; Result = null; resultText = ""; busy = 0;
        scrollItem = null; scrollNotches = 0; hubHeat = 0;
        Rebuild();
        lock (statusCache) { string s; statusText = statusCache.TryGetValue(Target, out s) ? s : ""; }

        PlaceAtCursor();
        Opacity = 0; zoom.ScaleX = zoom.ScaleY = 0.92;
        open = true;
        Show();
        SetForegroundWindow(hwnd); Activate(); Focus();
        Mouse.Capture(this, CaptureMode.SubTree);
        openedAt = DateTime.Now;
        triggerDown = triggerVk != 0 && (GetAsyncKeyState(triggerVk) & 0x8000) != 0;

        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(110)));
        zoom.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(0.92, 1, TimeSpan.FromMilliseconds(150)) { EasingFunction = ease });
        zoom.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(0.92, 1, TimeSpan.FromMilliseconds(150)) { EasingFunction = ease });
        poll.Start();
        surface.InvalidateVisual();
        RefreshStatus();

        frame = new DispatcherFrame();
        Dispatcher.PushFrame(frame);   // returns once Dismiss() runs
        return Result;
    }

    void Dismiss() {
        if (!open) return;
        scrollTimer.Stop();
        FlushScroll();   // a scroll still waiting for its pause is applied, not lost
        open = false;
        poll.Stop();
        if (Mouse.Captured != null) Mouse.Capture(null);
        BeginAnimation(OpacityProperty, null); Opacity = 0;
        Hide();
        if (frame != null) frame.Continue = false;
    }

    // Centre the wheel on the mouse, kept inside the work area of the monitor it's on.
    void PlaceAtCursor() {
        POINT p; GetCursorPos(out p);
        double s = 1;
        var src = HwndSource.FromHwnd(hwnd);
        if (src != null && src.CompositionTarget != null) s = src.CompositionTarget.TransformToDevice.M11;
        int w = (int)Math.Round(Wd * s), h = (int)Math.Round(Ht * s);
        int x = p.X - (int)Math.Round(Wd / 2 * s), y = p.Y - (int)Math.Round(Cy * s);
        var mi = new MONITORINFO { cbSize = Marshal.SizeOf(typeof(MONITORINFO)) };
        if (GetMonitorInfo(MonitorFromPoint(p, 2), ref mi)) {
            x = Math.Max(mi.rcWork.L, Math.Min(x, mi.rcWork.R - w));
            y = Math.Max(mi.rcWork.T, Math.Min(y, mi.rcWork.B - h));
        }
        SetWindowPos(hwnd, new IntPtr(-1), x, y, w, h, 0x0010);   // HWND_TOPMOST, SWP_NOACTIVATE
    }

    // Hotkeys are thread messages; the daemon's own loop is paused while the wheel is open.
    // Pressing the wheel hotkey again closes it; other hotkeys are ignored meanwhile.
    void OnThreadMessage(ref MSG msg, ref bool handled) {
        if (!open || msg.message != WM_HOTKEY) return;
        handled = true;
        if ((int)msg.wParam == hotkeyId) Dismiss();
    }

    string Target { get { return targets[targetIdx]; } }

    // A monitor-specific choice (e.g. a picture mode only one monitor has) is hidden on "All".
    void Rebuild() {
        items = menu.Children.FindAll(i => i.OnlyFor == null || Array.IndexOf(i.OnlyFor, Target) >= 0);
        heat = new double[items.Count];
        hover = -2;
    }

    void Poll() {
        if (!open) return;
        if ((GetAsyncKeyState(VK_ESCAPE) & 0x8000) != 0) { Dismiss(); return; }
        POINT p; GetCursorPos(out p);
        Point m = surface.PointFromScreen(new Point(p.X, p.Y));
        double dx = m.X - Wd / 2, dy = m.Y - Cy;
        int h = -2;
        if (Math.Sqrt(dx * dx + dy * dy) < InnerR) h = -1;
        else if (items.Count > 0) {
            double slice = 360.0 / items.Count;
            double a = Math.Atan2(dy, dx) * 180 / Math.PI + 90 + slice / 2;
            a = ((a % 360) + 360) % 360;
            h = Math.Min(items.Count - 1, (int)(a / slice));
        }
        bool dirty = h != hover;
        hover = h;

        // Ease the highlight in and out instead of snapping.
        for (int i = 0; i < heat.Length; i++) dirty |= Ease(ref heat[i], i == hover ? 1 : 0);
        dirty |= Ease(ref hubHeat, hover == -1 ? 1 : 0);
        if (dirty) surface.InvalidateVisual();

        // Hold-and-release: letting go of the hotkey picks the slice you're pointing at (the centre
        // cancels). A quick tap leaves the wheel open for clicking instead.
        if (triggerDown && (GetAsyncKeyState(triggerVk) & 0x8000) == 0) {
            triggerDown = false;
            if ((DateTime.Now - openedAt).TotalMilliseconds >= HoldMs) {
                if (hover >= 0) Pick(items[hover]); else Dismiss();
            } else surface.InvalidateVisual();
        }
    }

    static bool Ease(ref double v, double target) {
        if (v == target) return false;
        double d = target - v;
        v = Math.Abs(d) < 0.02 ? target : v + d * 0.38;
        return true;
    }

    void OnKey(Key k) {
        if (k == Key.Escape) Dismiss();
        else if (k == Key.Back) Back();
        else if (k == Key.Tab) NextTarget();
        else if (k == Key.Enter && hover >= 0) Pick(items[hover]);
        else {
            int n = -1;
            if (k >= Key.D1 && k <= Key.D9) n = k - Key.D1;
            else if (k >= Key.NumPad1 && k <= Key.NumPad9) n = k - Key.NumPad1;
            if (n >= 0 && n < items.Count) Pick(items[n]);
        }
    }

    void Click() {
        if (hover == -1) NextTarget();
        else if (hover >= 0) Pick(items[hover]);
    }

    void NextTarget() {
        targetIdx = (targetIdx + 1) % targets.Length;
        resultText = "";
        lock (statusCache) { string s; statusText = statusCache.TryGetValue(Target, out s) ? s : ""; }
        Rebuild();
        RefreshStatus();
        surface.InvalidateVisual();
    }

    void Back() {
        if (path.Count > 0) { menu = path.Pop(); resultText = ""; Rebuild(); surface.InvalidateVisual(); }
        else Dismiss();
    }

    string WithTarget(string action) {
        if (Target == "All" || action.Contains("@")) return action;
        if (action.StartsWith("Set:") || action.StartsWith("Profile:") || action.StartsWith("Toggle:") || action.StartsWith("Look:")) return action + "@" + Target;
        return action;
    }

    void Pick(WheelItem item) {
        if (item.Children != null && item.Children.Count > 0) {
            path.Push(menu); menu = item; resultText = ""; Rebuild(); surface.InvalidateVisual();
            return;
        }
        if (string.IsNullOrEmpty(item.Action)) return;
        if (!item.Keep) { Result = WithTarget(item.Action); Dismiss(); return; }   // caller runs it after we close
        RunInPlace(WithTarget(item.Action), item.Label);
    }

    // Hand the action to the caller's worker; the result comes back on any thread.
    void RunInPlace(string action, string label) {
        if (run == null) return;
        busy++;
        resultText = label + " " + (char)0x2026;
        surface.InvalidateVisual();
        run(action, r => Dispatcher.BeginInvoke(new Action(() => {
            busy = Math.Max(0, busy - 1);
            resultText = r ?? "";
            if (open) { surface.InvalidateVisual(); if (busy == 0) RefreshStatus(); }
        })));
    }

    // Scrolling over an adjustable slice (or anywhere inside its submenu) batches the notches and
    // sends one relative change after a short pause, so the monitor isn't flooded with writes.
    void Scroll(int delta) {
        WheelItem it = (hover >= 0 && items[hover].ScrollAction != null) ? items[hover] : (menu.ScrollAction != null ? menu : null);
        if (it == null) return;
        if (scrollItem != it) { FlushScroll(); scrollItem = it; }
        scrollNotches += delta > 0 ? 1 : -1;
        int d = scrollNotches * it.ScrollStep;
        resultText = it.Label + " " + (d > 0 ? "+" : "") + d;
        surface.InvalidateVisual();
        scrollTimer.Stop(); scrollTimer.Start();
    }

    void FlushScroll() {
        if (scrollItem == null || scrollNotches == 0) { scrollNotches = 0; return; }
        int d = scrollNotches * scrollItem.ScrollStep;
        string action = scrollItem.ScrollAction.Replace("{delta}", (d > 0 ? "+" : "") + d);
        scrollNotches = 0;
        RunInPlace(WithTarget(action), scrollItem.Label + " " + (d > 0 ? "+" : "") + d);
    }

    void RefreshStatus() {
        if (status == null) return;
        string t = Target;
        int seq = ++statusSeq;
        status(t, s => {
            lock (statusCache) statusCache[t] = s ?? "";
            Dispatcher.BeginInvoke(new Action(() => {
                if (seq != statusSeq || !open) return;
                statusText = s ?? ""; surface.InvalidateVisual();
            }));
        });
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

    static Geometry Arc(double cx, double cy, double r, double a0, double a1) {
        var g = new StreamGeometry();
        using (var c = g.Open()) {
            c.BeginFigure(Polar(cx, cy, r, a0), false, false);
            c.ArcTo(Polar(cx, cy, r, a1), new Size(r, r), 0, (a1 - a0) > 180, SweepDirection.Clockwise, true, false);
        }
        g.Freeze();
        return g;
    }

    static Color Mix(Color a, Color b, double t) {
        return Color.FromArgb((byte)(a.A + (b.A - a.A) * t), (byte)(a.R + (b.R - a.R) * t), (byte)(a.G + (b.G - a.G) * t), (byte)(a.B + (b.B - a.B) * t));
    }

    FormattedText Text(string s, double size, Brush b, Typeface tf, double maxWidth) {
        var ft = new FormattedText(s ?? "", CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, tf, size, b,
                                   VisualTreeHelper.GetDpi(this).PixelsPerDip);
        // Centre alignment only within a fixed box; without one, WPF centres on the origin instead.
        if (maxWidth > 0) { ft.MaxTextWidth = maxWidth; ft.TextAlignment = TextAlignment.Center; }
        return ft;
    }

    static void DrawText(DrawingContext dc, FormattedText ft, double cx, double cy) {
        // With TextAlignment.Center the origin x is the centre of a MaxTextWidth-wide box.
        double w = ft.MaxTextWidth > 0 ? ft.MaxTextWidth : ft.Width;
        dc.DrawText(ft, new Point(cx - w / 2, cy - ft.Height / 2));
    }

    internal void Draw(DrawingContext dc) {
        double cx = Wd / 2, cy = Cy;
        dc.DrawRectangle(HitFill, null, new Rect(0, 0, Wd, Ht));
        dc.DrawEllipse(Backdrop, null, new Point(cx, cy), OuterR + 70, OuterR + 70);

        int n = items.Count;
        double slice = n > 0 ? 360.0 / n : 360, gap = n > 1 ? 1.0 : 0;
        for (int i = 0; i < n; i++) {
            var it = items[i];
            double t = i < heat.Length ? heat[i] : 0;
            double mid = -90 + i * slice;
            double a0 = mid - slice / 2 + gap, a1 = mid + slice / 2 - gap;
            if (n == 1) { a0 = -90; a1 = 269.9; }
            double rOut = OuterR + 12 * t;
            var fill = new SolidColorBrush(Mix(SliceCol, SliceHotC, t)); fill.Freeze();
            dc.DrawGeometry(fill, Edge, Slice(cx, cy, InnerR + 5, rOut, a0, a1));
            if (t > 0.05) {
                dc.PushOpacity(t);
                dc.DrawGeometry(null, AccentArc, Arc(cx, cy, rOut + 7, a0 + 2, a1 - 2));
                dc.Pop();
            }
            bool dark = t > 0.5;
            bool hasKids = it.Children != null && it.Children.Count > 0;
            double rMid = (InnerR + rOut) / 2 + 4;
            Point c = Polar(cx, cy, rMid, mid);
            double tw = Math.Min((OuterR - InnerR) * 0.95, Math.Max(70, 2 * Math.PI * rMid / Math.Max(n, 1) * 0.85));
            var label = Text(it.Label + (hasKids ? " " + (char)0x203A : ""), 15, dark ? TextDark : TextMain, dark ? UiBold : Ui, tw);
            if (!string.IsNullOrEmpty(it.Glyph)) {
                var g = Text(it.Glyph, 22, dark ? TextDark : TextMain, Icons, 0);
                double total = g.Height + label.Height;
                DrawText(dc, g, c.X, c.Y - total / 2 + g.Height / 2 + 2);
                DrawText(dc, label, c.X, c.Y + total / 2 - label.Height / 2);
            } else DrawText(dc, label, c.X, c.Y);
        }

        // Hub: where you are, what you're pointing at, and which monitor settings go to.
        dc.DrawEllipse(HubFill, Edge, new Point(cx, cy), InnerR, InnerR);
        if (hubHeat > 0.05) {
            dc.PushOpacity(hubHeat);
            dc.DrawEllipse(null, AccentRing, new Point(cx, cy), InnerR - 3, InnerR - 3);
            dc.Pop();
        }
        string title = path.Count > 0 ? menu.Label : "Monitors";
        string line = "", hint = "";
        if (hover >= 0) { line = items[hover].Label; hint = items[hover].Hint; }
        else if (hover == -1) { line = triggerDown ? "Cancel" : "Target"; hint = triggerDown ? "release to close" : "click or Tab to change"; }
        double hw = InnerR * 1.7;
        DrawText(dc, Text(title.ToUpperInvariant(), 11, TextSoft, UiBold, hw), cx, cy - InnerR * 0.56);
        DrawText(dc, Text(line, 19, TextMain, UiBold, hw), cx, cy - InnerR * 0.14);
        if (!string.IsNullOrEmpty(hint)) DrawText(dc, Text(hint, 11.5, TextSoft, Ui, hw), cx, cy + InnerR * 0.18);
        DrawText(dc, Text((char)0x25C2 + " " + Target + " " + (char)0x25B8, 13, hover == -1 ? Accent : TextMain, UiBold, hw), cx, cy + InnerR * 0.56);

        // Above: controls. Below: live values for this machine's monitors, then the last result.
        var help = Text("Release / click / 1-" + Math.Min(9, Math.Max(1, n)) + " to pick   " + (char)0x2022 + "   Right-click: back   " + (char)0x2022 + "   Scroll: adjust   " + (char)0x2022 + "   Esc: close", 11.5, TextSoft, Ui, 0);
        var helpR = new Rect(cx - help.Width / 2 - 12, cy - OuterR - 52, help.Width + 24, help.Height + 8);
        dc.DrawRoundedRectangle(Panel, null, helpR, 10, 10);
        dc.DrawText(help, new Point(cx - help.Width / 2, helpR.Top + 4));

        double y = cy + OuterR + 26;
        string st = string.IsNullOrEmpty(statusText) ? "Reading monitors" + (char)0x2026 : statusText;
        var stT = Text(st, 12.5, TextMain, Ui, Wd - 48);
        FormattedText rsT = string.IsNullOrEmpty(resultText) ? null : Text(resultText, 12.5, Accent, Ui, Wd - 48);
        double ph = stT.Height + (rsT != null ? rsT.Height + 8 : 0) + 16;
        dc.DrawRoundedRectangle(Panel, null, new Rect(14, y, Wd - 28, ph), 12, 12);
        DrawText(dc, stT, cx, y + 8 + stT.Height / 2);
        if (rsT != null) DrawText(dc, rsT, cx, y + 8 + stT.Height + 8 + rsT.Height / 2);
    }
}
"@ -ErrorAction SilentlyContinue

function New-WheelItem {
    param([string]$Label, [string]$Action, [string]$Hint = '', [string]$Glyph, [switch]$Keep, [string]$ScrollAction, [int]$ScrollStep = 5, [string[]]$OnlyFor, [object[]]$Children)
    $i = New-Object WheelItem
    $i.Label = $Label; $i.Hint = $Hint; $i.Keep = [bool]$Keep; $i.ScrollStep = $ScrollStep
    if ($Action) { $i.Action = $Action }
    if ($Glyph) { $i.Glyph = $Glyph }
    if ($ScrollAction) { $i.ScrollAction = $ScrollAction }
    if ($OnlyFor) { $i.OnlyFor = $OnlyFor }
    foreach ($c in @($Children)) { if ($c) { $i.Children.Add($c) } }
    return $i
}

# Icon characters (Segoe MDL2 Assets / Segoe Fluent Icons).
$script:WheelGlyph = @{
    Layout = [string][char]0xE7F4; Normal = [string][char]0xE821; Gaming = [string][char]0xE7FC
    Reading = [string][char]0xE736; Brightness = [string][char]0xE706; Colour = [string][char]0xE790
    Looks = [string][char]0xE734; Profiles = [string][char]0xE713; Tune = [string][char]0xE9E9
    Blank = [string][char]0xE708
}

# Wheel items for a List feature: each monitor's own names (config override, else the defaults).
# A name every monitor has is shown always; one only some monitors have is shown only when
# targeting those monitors, so "All" never offers a mode a monitor would skip.
# Names matching $Exclude (e.g. the User colour presets kept for Reading) are left off.
function Get-WheelChoiceItem {
    param($Config, [string]$Feature, [string[]]$Default, [string]$Exclude)
    $key = $script:FeatureNameKeys[$Feature]
    $owners = [ordered]@{}
    $monitors = @($Config.Monitors | Where-Object { $_ })
    foreach ($rule in $monitors) {
        $names = if ($rule[$key]) { @($rule[$key].Keys | Sort-Object { $rule[$key][$_] }) } else { $Default }
        foreach ($n in $names) {
            if ($Exclude -and $n -match $Exclude) { continue }
            if (-not $owners.Contains($n)) { $owners[$n] = @() }; $owners[$n] += [string]$rule.Name
        }
    }
    foreach ($n in $owners.Keys) {
        $only = if ($owners[$n].Count -lt $monitors.Count) { [string[]]$owners[$n] } else { $null }
        New-WheelItem -Label $n -Action "Set:$Feature=$n" -Keep -OnlyFor $only -Hint $(if ($only) { $only -join ', ' } else { '' })
    }
}

function Get-WheelMenu {
    param([Parameter(Mandatory)]$Config)
    $g = $script:WheelGlyph
    $labels = if ($Config.PresetLabels) { $Config.PresetLabels } else { @{} }
    $layout = foreach ($p in ($Config.Presets.Keys | Sort-Object)) {
        New-WheelItem -Label $(if ($labels[$p]) { $labels[$p] } else { $p }) -Action $p -Hint "preset $p"
    }
    $level = {
        param($Feature, $Label)
        $kids = @(
            New-WheelItem -Label '-10' -Action "Set:$Feature=-10" -Keep
            New-WheelItem -Label '+10' -Action "Set:$Feature=+10" -Keep
        ) + (25, 50, 75, 100 | ForEach-Object { New-WheelItem -Label "$_%" -Action "Set:$Feature=$_%" -Keep })
        New-WheelItem -Label $Label -Glyph $g[$Feature] -Hint 'scroll to adjust' -ScrollAction "Set:$Feature={delta}" -Children $kids
    }
    # Contrast, Picture mode, Volume and Mute are left off: neither monitor supports Mute over DDC,
    # only the F270i has Volume, and picture modes override brightness. They still work as hotkey actions.
    # The User colour presets are tuned for Reading in the monitors' menus, so they're left off too.
    $temps = @(Get-WheelChoiceItem $Config 'ColorTemp' @('6500K', '9300K', 'sRGB') -Exclude '^User' |
               Sort-Object { if ($_.Label -match '^(\d+)K$') { [int]$Matches[1] } else { 99999 } })   # warm -> cool
    # Saved looks (saved.psd1) plus a slot to save the current settings as the next "Look N".
    $lookNames = @(if ($Config.Looks) { $Config.Looks.Keys | Sort-Object })
    $n = 1; while ($lookNames -contains "Look $n") { $n++ }
    $looks = @(foreach ($l in $lookNames) { New-WheelItem -Label $l -Action "Look:$l" -Hint 'apply look' }) +
             @(New-WheelItem -Label '+ Save current' -Action "Save:Look $n" -Hint "as 'Look $n' (rename in saved.psd1)")

    # Normal and Gaming get their own slices. A profile's Hint (config) is shown in the hub.
    $prof = {
        param($Name, $Hint)
        if (-not ($Config.Profiles -and $Config.Profiles.ContainsKey($Name))) { return }
        $h = if ($Config.Profiles[$Name].Hint) { [string]$Config.Profiles[$Name].Hint } else { $Hint }
        New-WheelItem -Label $Name -Glyph $g[$Name] -Action "Profile:$Name" -Hint $h
    }
    $items = @(
        New-WheelItem -Label 'Layout' -Glyph $g.Layout -Hint 'switch inputs' -Children $layout
        & $prof 'Normal' 'everyday work'
        & $prof 'Gaming' 'bright, punchy'
    )
    if ($Config.Profiles -and $Config.Profiles.ContainsKey('Reading')) {
        $items += New-WheelItem -Label 'Reading' -Glyph $g.Reading -Action 'Toggle:Reading' -Hint 'warm + dim, toggle'
    }
    $items += & $level 'Brightness' 'Brightness'
    $items += New-WheelItem -Label 'Colour' -Glyph $g.Colour -Hint 'colour temperature' -Children $temps
    $items += New-WheelItem -Label 'Looks' -Glyph $g.Looks -Hint 'saved settings' -Children $looks
    # Blank: one child per monitor (the wheel's target doesn't apply; the monitor is in the action).
    $blank = foreach ($rule in @($Config.Monitors | Where-Object { $_ })) {
        New-WheelItem -Label ([string]$rule.Name) -Action "Blank:Toggle@$($rule.Name)" -Hint 'black out / back (or double-click it)'
    }
    $items += New-WheelItem -Label 'Blank' -Glyph $g.Blank -Hint 'black out a monitor' -Children $blank
    $items += New-WheelItem -Label 'Tune' -Glyph $g.Tune -Action 'Tune' -Hint 'adjust + save profiles'
    $profiles = @()
    if ($Config.Profiles) {
        $profiles = foreach ($p in ($Config.Profiles.Keys | Where-Object { $_ -notin 'Reading', 'Normal', 'Gaming' } | Sort-Object)) {
            New-WheelItem -Label $p -Action "Profile:$p"
        }
    }
    if ($profiles) { $items += New-WheelItem -Label 'Profiles' -Glyph $g.Profiles -Children $profiles }
    return New-WheelItem -Label 'Monitors' -Children @($items | Where-Object { $_ })
}

# Show the wheel. Either pass -RunAsync / -StatusAsync ([Action[string,Action[string]]]: start the
# work and call the callback with a short result, from any thread), or plain -Run / -Status
# scriptblocks that return the result (they then run on the UI thread). Returns the action picked
# from a closing slice (e.g. a preset), or $null; the caller runs it after the overlay is gone.
function Show-DdcWheel {
    param(
        [Parameter(Mandatory)]$Config,
        [scriptblock]$Run, [scriptblock]$Status,
        [Action[string, Action[string]]]$RunAsync, [Action[string, Action[string]]]$StatusAsync,
        [int]$TriggerVk = 0, [int]$HotkeyId = 0
    )
    if (-not $RunAsync -and $Run) {
        $r = $Run
        $RunAsync = [Action[string, Action[string]]]({ param($a, $cb) $cb.Invoke([string](& $r $a)) }.GetNewClosure())
    }
    if (-not $StatusAsync -and $Status) {
        $s = $Status
        $StatusAsync = [Action[string, Action[string]]]({ param($t, $cb) $cb.Invoke([string](& $s $t)) }.GetNewClosure())
    }
    $targets = @('All') + @($Config.Monitors | ForEach-Object { [string]$_.Name })
    return [DdcWheel]::Show((Get-WheelMenu $Config), [string[]]$targets, $RunAsync, $StatusAsync, $TriggerVk, $HotkeyId)
}
