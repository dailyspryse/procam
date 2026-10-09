using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;

namespace ProCam;

/// Port of Mac/ContentView.swift: top bar, preview, scopes, inspector.
public sealed class MainWindow : Window
{
    private readonly StudioModel _m;
    private static Brush B(string key) => (Brush)Application.Current.Resources[key];

    // Preview
    private readonly Image _preview = new() { Stretch = Stretch.Uniform };
    private readonly Canvas _guides = new() { IsHitTestVisible = false };
    private readonly Grid _previewHost = new() { Background = Brushes.Black, ClipToBounds = true };
    private readonly StackPanel _empty = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _emptyTitle = new() { FontSize = 17, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly TextBlock _phoneError = new() { Margin = new Thickness(12), Foreground = Brushes.Orange, FontWeight = FontWeights.SemiBold,
        VerticalAlignment = VerticalAlignment.Top, HorizontalAlignment = HorizontalAlignment.Left };
    private WriteableBitmap? _bitmap;
    private byte[] _overlayBuffer = Array.Empty<byte>();
    private int _generation;
    private readonly DateTime _start = DateTime.UtcNow;

    // Top bar
    private readonly TextBlock _connText = new() { FontSize = 11.5, FontWeight = FontWeights.SemiBold };
    private readonly Ellipse _connDot = new() { Width = 7, Height = 7, Margin = new Thickness(0, 0, 7, 0) };
    private readonly StackPanel _stats = new() { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
    private readonly Button _vcamButton = new();
    private readonly Popup _connPopup = new() { StaysOpen = false, AllowsTransparency = true, Placement = PlacementMode.Bottom };
    private readonly Popup _vcamPopup = new() { StaysOpen = false, AllowsTransparency = true, Placement = PlacementMode.Bottom };

    // Scopes
    private readonly HistogramView _histogram = new();
    private readonly Image _waveform = new() { Stretch = Stretch.Fill };
    private WriteableBitmap? _waveBitmap;
    private readonly StackPanel _signal = new();

    public MainWindow(StudioModel m)
    {
        _m = m;
        Title = "ProCam Studio";
        Width = 1440; Height = 880; MinWidth = 1100; MinHeight = 680;
        Background = B("Bg");
        WindowStartupLocation = WindowStartupLocation.CenterScreen;

        var root = new Grid();
        root.ColumnDefinitions.Add(new ColumnDefinition());
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1) });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(330) });

        var left = new Grid();
        left.RowDefinitions.Add(new RowDefinition { Height = new GridLength(48) });
        left.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1) });
        left.RowDefinitions.Add(new RowDefinition());
        left.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1) });
        left.RowDefinitions.Add(new RowDefinition { Height = new GridLength(150) });
        Add(left, TopBar(), 0);
        Add(left, new Border { Background = B("Line") }, 1);
        Add(left, PreviewArea(), 2);
        Add(left, new Border { Background = B("Line") }, 3);
        Add(left, ScopeBar(), 4);

        Grid.SetColumn(left, 0);
        root.Children.Add(left);
        var sep = new Border { Background = B("Line") };
        Grid.SetColumn(sep, 1);
        root.Children.Add(sep);
        var inspector = new Inspector(m);
        Grid.SetColumn(inspector, 2);
        root.Children.Add(inspector);
        Content = root;

        m.StatusChanged += RefreshStatus;
        m.ScopesChanged += RefreshScopes;
        CompositionTarget.Rendering += (_, _) => RenderFrame();
        SizeChanged += (_, _) => DrawGuides();
        KeyDown += OnKey;
        RefreshStatus();
    }

    private static void Add(Grid g, UIElement e, int row) { Grid.SetRow(e, row); g.Children.Add(e); }

    // ─── Top bar ────────────────────────────────────────────────────────

    private UIElement TopBar()
    {
        var bar = new DockPanel { Background = B("Panel"), LastChildFill = false };
        var brand = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(16, 0, 14, 0) };
        brand.Children.Add(new TextBlock { Text = "ProCam", FontSize = 15, FontWeight = FontWeights.Black });
        brand.Children.Add(new TextBlock { Text = "STUDIO", FontSize = 9.5, FontWeight = FontWeights.Bold, Foreground = B("Accent"),
            Margin = new Thickness(6, 4, 0, 0) });
        bar.Children.Add(brand);

        var pill = new Button { Style = (Style)Application.Current.Resources["Flat"], VerticalAlignment = VerticalAlignment.Center };
        var pillContent = new StackPanel { Orientation = Orientation.Horizontal };
        pillContent.Children.Add(_connDot);
        pillContent.Children.Add(_connText);
        pillContent.Children.Add(new TextBlock { Text = "  ▾", Foreground = B("Dim") });
        pill.Content = pillContent;
        pill.Click += (_, _) => { _connPopup.Child = ConnectPopup(); _connPopup.PlacementTarget = pill; _connPopup.IsOpen = true; };
        bar.Children.Add(pill);

        _vcamButton.Style = (Style)Application.Current.Resources["Flat"];
        _vcamButton.VerticalAlignment = VerticalAlignment.Center;
        _vcamButton.Margin = new Thickness(14, 0, 16, 0);
        _vcamButton.Click += (_, _) => { _vcamPopup.Child = VcamPopup(); _vcamPopup.PlacementTarget = _vcamButton; _vcamPopup.IsOpen = true; };
        DockPanel.SetDock(_vcamButton, Dock.Right);
        bar.Children.Add(_vcamButton);
        DockPanel.SetDock(_stats, Dock.Right);
        bar.Children.Add(_stats);
        return bar;
    }

    private Border PopupFrame(UIElement content) => new()
    {
        Background = B("Raised"), BorderBrush = B("Line"), BorderThickness = new Thickness(1),
        CornerRadius = new CornerRadius(8), Padding = new Thickness(16), Width = 320, Child = content,
        Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 18, Opacity = 0.5, ShadowDepth = 4 },
    };

    private UIElement ConnectPopup()
    {
        var p = new StackPanel();
        p.Children.Add(new TextBlock { Text = "iPhones im Netzwerk", FontSize = 14, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 8) });
        if (_m.Phones.Count == 0)
            p.Children.Add(new TextBlock { Text = "Keins gefunden. Ist ProCam auf dem iPhone geöffnet und im selben WLAN? Sonst die IP-Adresse vom iPhone-Bildschirm unten eintragen.",
                Foreground = B("Dim"), TextWrapping = TextWrapping.Wrap });
        foreach (var phone in _m.Phones)
        {
            var b = new Button { Content = $"📱  {phone.Name}   ({phone.Host})", Style = (Style)Application.Current.Resources["Flat"],
                HorizontalContentAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 0, 0, 6) };
            b.Click += (_, _) => { _m.Connect(phone); _connPopup.IsOpen = false; };
            p.Children.Add(b);
        }
        p.Children.Add(new TextBlock { Text = "Direkt per IP", Foreground = B("Dim"), Margin = new Thickness(0, 10, 0, 4) });
        var row = new DockPanel();
        var go = new Button { Content = "Verbinden", Style = (Style)Application.Current.Resources["Flat"], Margin = new Thickness(6, 0, 0, 0) };
        DockPanel.SetDock(go, Dock.Right);
        var ip = new TextBox { Text = Properties.LastHost ?? "" };
        go.Click += (_, _) =>
        {
            if (string.IsNullOrWhiteSpace(ip.Text)) return;
            Properties.LastHost = ip.Text.Trim();
            _m.Connect(ip.Text.Trim());
            _connPopup.IsOpen = false;
        };
        row.Children.Add(go);
        row.Children.Add(ip);
        p.Children.Add(row);
        if (_m.DeviceName != null)
        {
            var dc = new Button { Content = "Trennen", Style = (Style)Application.Current.Resources["Link"], Margin = new Thickness(0, 12, 0, 0) };
            dc.Click += (_, _) => { _m.Disconnect(); _connPopup.IsOpen = false; };
            p.Children.Add(dc);
        }
        return PopupFrame(p);
    }

    private UIElement VcamPopup()
    {
        var p = new StackPanel();
        p.Children.Add(new TextBlock { Text = "Virtuelle Webcam", FontSize = 14, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 8) });
        TextBlock T(string s, Brush? c = null) => new() { Text = s, TextWrapping = TextWrapping.Wrap, Foreground = c ?? B("Text"), Margin = new Thickness(0, 0, 0, 10) };
        if (VirtualCamera.DesktopCameraAccessDenied)
        {
            p.Children.Add(T("Windows sperrt gerade den Kamerazugriff für Desktop-Apps. Einstellungen → Datenschutz und Sicherheit → Kamera: „Kamerazugriff“ und „Desktop-Apps den Zugriff auf die Kamera erlauben“ einschalten.", B("Live")));
            var open = new Button { Content = "Kamera-Einstellungen öffnen", Style = (Style)Application.Current.Resources["Flat"], Margin = new Thickness(0, 0, 0, 10) };
            open.Click += (_, _) => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("ms-settings:privacy-webcam") { UseShellExecute = true });
            p.Children.Add(open);
        }
        switch (_m.Vcam)
        {
            case VcamState.Ready:
                p.Children.Add(T($"In Zoom, Teams, OBS, Discord, Browser oder der Kamera-App „{VirtualCamera.DisplayName}“ als Kamera wählen. Apps, die schon offen waren, einmal komplett beenden (auch aus dem Infobereich) und neu starten."));
                var un = new Button { Content = "Entfernen", Style = (Style)Application.Current.Resources["Link"] };
                un.Click += (_, _) => { _m.UninstallVirtualCamera(); _vcamPopup.IsOpen = false; };
                p.Children.Add(un);
                break;
            case VcamState.Busy:
                p.Children.Add(T("Die Webcam wird gerade von einem anderen ProCam-Fenster gespeist. Das andere Fenster schließen.", B("Accent")));
                break;
            case VcamState.Failed:
                p.Children.Add(T("Einrichten abgebrochen oder fehlgeschlagen. Windows fragt nach Administratorrechten – bitte bestätigen.", B("Live")));
                goto default;
            default:
                p.Children.Add(T($"Richtet „{VirtualCamera.DisplayName}“ als Kamera für alle Apps ein. Windows fragt einmal nach Administratorrechten."));
                var inst = new Button { Content = "Einrichten", Style = (Style)Application.Current.Resources["Flat"] };
                inst.Click += (_, _) => { _vcamPopup.IsOpen = false; _m.InstallVirtualCamera(); };
                p.Children.Add(inst);
                break;
        }
        return PopupFrame(p);
    }

    private void RefreshStatus()
    {
        var (dot, text) = _m.LinkState switch
        {
            LinkState.Connected => (B("Live"), _m.DeviceName ?? "iPhone"),
            LinkState.Connecting => (B("Accent"), $"Verbinde mit {_m.ConnectingTo} …"),
            _ => (B("Dim"), _m.Phones.Count == 0 ? "Suche iPhone …" : "Nicht verbunden"),
        };
        _connDot.Fill = dot;
        _connText.Text = text;

        _stats.Children.Clear();
        if (_m.DeviceName != null)
        {
            var r = _m.Readings;
            Stat("ISO", $"{r.Iso:0}");
            Stat("VERSCHL.", Inspector.ShutterLabel(r.Shutter));
            Stat("WB", $"{r.Temperature:0}K");
            Stat("FPS", $"{_m.ReceivedFps:0}");
            Stat("DATEN", $"{r.BitrateMbps:0.0}");
            if (r.Battery >= 0) Stat(r.Charging ? "AKKU ⚡" : "AKKU", $"{r.Battery * 100:0}%");
            if (r.Thermal >= 2) Stat("", "🌡 Heiß", B("Live"));
        }

        (string vt, Brush vc) = _m.Vcam switch
        {
            VcamState.Ready => ("● Webcam aktiv", B("Ok")),
            VcamState.Busy => ("Webcam belegt", B("Accent")),
            VcamState.Failed => ("Webcam-Fehler", B("Live")),
            _ => ("Webcam einrichten", B("Accent")),
        };
        _vcamButton.Content = new TextBlock { Text = vt, Foreground = vc, FontWeight = FontWeights.SemiBold };

        _empty.Visibility = _m.DeviceName == null ? Visibility.Visible : Visibility.Collapsed;
        _emptyTitle.Text = _m.LinkState == LinkState.Idle ? "Kein iPhone verbunden" : "Verbinde …";
        _phoneError.Text = _m.PhoneError ?? "";
        _phoneError.Visibility = _m.PhoneError != null && _m.DeviceName != null ? Visibility.Visible : Visibility.Collapsed;
        if (_m.DeviceName == null) _preview.Source = null;
        RefreshSignal();
    }

    private void Stat(string title, string value, Brush? color = null)
    {
        var s = new StackPanel { Margin = new Thickness(14, 0, 0, 0) };
        s.Children.Add(new TextBlock { Text = title, FontSize = 8.5, FontWeight = FontWeights.Bold, Foreground = B("Dim"), HorizontalAlignment = HorizontalAlignment.Right });
        s.Children.Add(new TextBlock { Text = value, FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = color ?? B("Text"), HorizontalAlignment = HorizontalAlignment.Right });
        _stats.Children.Add(s);
    }

    // ─── Preview ────────────────────────────────────────────────────────

    private UIElement PreviewArea()
    {
        _empty.Children.Add(new Ellipse { Width = 74, Height = 74, Stroke = new SolidColorBrush(Color.FromArgb(30, 255, 255, 255)), StrokeThickness = 3 });
        _empty.Children.Add(_emptyTitle);
        _empty.Children.Add(new TextBlock { Text = "ProCam auf dem iPhone öffnen – gleiches WLAN genügt.", Foreground = B("Dim"), FontSize = 12.5,
            HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 6, 0, 0) });
        _emptyTitle.Margin = new Thickness(0, 14, 0, 0);

        _previewHost.Children.Add(_preview);
        _previewHost.Children.Add(_guides);
        _previewHost.Children.Add(_empty);
        _previewHost.Children.Add(_phoneError);
        _previewHost.MouseLeftButtonDown += OnPreviewClick;
        return _previewHost;
    }

    private Rect ImageRect()
    {
        double cw = _previewHost.ActualWidth, ch = _previewHost.ActualHeight;
        var (w, h) = _m.VideoSize;
        if (w <= 0 || h <= 0 || cw <= 0 || ch <= 0) return new Rect(0, 0, cw, ch);
        double s = Math.Min(cw / w, ch / h);
        return new Rect((cw - w * s) / 2, (ch - h * s) / 2, w * s, h * s);
    }

    private void OnPreviewClick(object sender, MouseButtonEventArgs e)
    {
        if (_m.DeviceName == null) return;
        var r = ImageRect();
        var p = e.GetPosition(_previewHost);
        if (!r.Contains(p)) return;
        bool exposure = Keyboard.Modifiers.HasFlag(ModifierKeys.Alt);
        _m.PointOfInterest((p.X - r.X) / r.Width, (p.Y - r.Y) / r.Height, exposure);

        var marker = new Rectangle { Width = 70, Height = 70, Stroke = exposure ? Brushes.Yellow : B("Accent"), StrokeThickness = 1.5, RadiusX = 4, RadiusY = 4 };
        Canvas.SetLeft(marker, p.X - 35);
        Canvas.SetTop(marker, p.Y - 35);
        _guides.Children.Add(marker);
        var t = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(1.2) };
        t.Tick += (_, _) => { _guides.Children.Remove(marker); t.Stop(); };
        t.Start();
    }

    private void DrawGuides()
    {
        // Keep transient tap markers; redraw only the guide lines.
        foreach (var old in _guides.Children.OfType<Line>().ToList()) _guides.Children.Remove(old);
        foreach (var old in _guides.Children.OfType<Rectangle>().Where(x => x.Tag as string == "safe").ToList()) _guides.Children.Remove(old);
        if (_m.DeviceName == null) return;
        var r = ImageRect();
        var o = _m.Overlays;
        if (o.Grid)
        {
            for (int i = 1; i <= 2; i++)
            {
                double x = r.X + r.Width * i / 3, y = r.Y + r.Height * i / 3;
                _guides.Children.Add(new Line { X1 = x, X2 = x, Y1 = r.Top, Y2 = r.Bottom, Stroke = new SolidColorBrush(Color.FromArgb(90, 255, 255, 255)), StrokeThickness = 0.75 });
                _guides.Children.Add(new Line { X1 = r.Left, X2 = r.Right, Y1 = y, Y2 = y, Stroke = new SolidColorBrush(Color.FromArgb(90, 255, 255, 255)), StrokeThickness = 0.75 });
            }
        }
        if (o.SafeArea)
        {
            var safe = new Rectangle { Width = r.Width * 0.9, Height = r.Height * 0.9, Tag = "safe",
                Stroke = new SolidColorBrush(Color.FromArgb(115, 255, 255, 255)), StrokeDashArray = new DoubleCollection { 6, 4 } };
            Canvas.SetLeft(safe, r.X + r.Width * 0.05);
            Canvas.SetTop(safe, r.Y + r.Height * 0.05);
            _guides.Children.Add(safe);
        }
    }

    private bool _lastGrid, _lastSafe;

    private void RenderFrame()
    {
        if (_m.Overlays.Grid != _lastGrid || _m.Overlays.SafeArea != _lastSafe)
        {
            _lastGrid = _m.Overlays.Grid; _lastSafe = _m.Overlays.SafeArea;
            DrawGuides();
        }
        var f = _m.TakeFrame(ref _generation);
        if (f == null) return;
        if (_bitmap == null || _bitmap.PixelWidth != f.Width || _bitmap.PixelHeight != f.Height)
        {
            _bitmap = new WriteableBitmap(f.Width, f.Height, 96, 96, PixelFormats.Bgr32, null);
            _preview.Source = _bitmap;
            DrawGuides();
        }
        else if (_preview.Source == null) _preview.Source = _bitmap;

        byte[] src = f.Bgra;
        if (_m.Overlays.AnyPixelOverlay)
        {
            if (_overlayBuffer.Length != src.Length) _overlayBuffer = new byte[src.Length];
            Overlays.Apply(src, _overlayBuffer, f.Width, f.Height, _m.Overlays, (DateTime.UtcNow - _start).TotalSeconds);
            src = _overlayBuffer;
        }
        _bitmap.WritePixels(new Int32Rect(0, 0, f.Width, f.Height), src, f.Stride, 0);
    }

    // ─── Scopes ─────────────────────────────────────────────────────────

    private UIElement ScopeBar()
    {
        var g = new Grid { Background = B("Line") };
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1) });
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(210) });
        UIElement Panel(string title, UIElement content)
        {
            var d = new DockPanel { Background = B("Panel") };
            var t = new TextBlock { Text = title, FontSize = 9, FontWeight = FontWeights.Bold, Foreground = B("Dim"), Margin = new Thickness(10, 10, 10, 6) };
            DockPanel.SetDock(t, Dock.Top);
            d.Children.Add(t);
            d.Children.Add(new Border { Background = Brushes.Black, CornerRadius = new CornerRadius(4), Margin = new Thickness(10, 0, 10, 10), Child = content, ClipToBounds = true });
            return d;
        }
        var a = Panel("HISTOGRAMM", _histogram);
        var b = Panel("WAVEFORM", _waveform);
        var sig = new Border { Background = B("Panel"), Padding = new Thickness(10), Child = _signal };
        Grid.SetColumn(a, 0); Grid.SetColumn(b, 2); Grid.SetColumn(sig, 4);
        g.Children.Add(a); g.Children.Add(b); g.Children.Add(sig);
        return g;
    }

    private void RefreshScopes()
    {
        var s = _m.Scopes;
        _histogram.Data = s;
        _histogram.InvalidateVisual();
        _waveBitmap ??= new WriteableBitmap(ScopeData.WaveColumns, ScopeData.WaveRows, 96, 96, PixelFormats.Bgr32, null);
        _waveBitmap.WritePixels(new Int32Rect(0, 0, ScopeData.WaveColumns, ScopeData.WaveRows), s.Waveform, ScopeData.WaveColumns * 4, 0);
        _waveform.Source = _waveBitmap;
        RefreshSignal();
    }

    private void RefreshSignal()
    {
        var s = _m.Scopes;
        _signal.Children.Clear();
        _signal.Children.Add(new TextBlock { Text = "SIGNAL", FontSize = 9, FontWeight = FontWeights.Bold, Foreground = B("Dim"), Margin = new Thickness(0, 0, 0, 8) });
        Meter("Ausgebrannt", s.Clipped, 0.02f);
        Meter("Abgesoffen", s.Crushed, 0.05f);
        _signal.Children.Add(new TextBlock { Text = $"{_m.VideoSize.W}×{_m.VideoSize.H} · iPhone-GPU {_m.Readings.ProcessingMs:0.0} ms",
            FontSize = 10, Foreground = B("Dim"), Margin = new Thickness(0, 8, 0, 0) });
        if (_m.Readings.DroppedFrames > 0)
            _signal.Children.Add(new TextBlock { Text = $"{_m.Readings.DroppedFrames} Frames verworfen (WLAN)", FontSize = 10, Foreground = B("Accent") });
    }

    private void Meter(string title, float value, float warn)
    {
        var d = new DockPanel();
        var v = new TextBlock { Text = $"{value * 100:0.0} %", FontSize = 10.5, Foreground = value > warn ? B("Live") : B("Text") };
        DockPanel.SetDock(v, Dock.Right);
        d.Children.Add(v);
        d.Children.Add(new TextBlock { Text = title, FontSize = 10.5, Foreground = B("Dim") });
        _signal.Children.Add(d);
        var track = new Grid { Height = 4, Margin = new Thickness(0, 3, 0, 8) };
        track.Children.Add(new Border { Background = B("Raised"), CornerRadius = new CornerRadius(2) });
        track.Children.Add(new Border { Background = value > warn ? B("Live") : B("Ok"), CornerRadius = new CornerRadius(2),
            HorizontalAlignment = HorizontalAlignment.Left, Width = Math.Max(2, 190 * Math.Min(value * 10, 1)) });
        _signal.Children.Add(track);
    }

    // ─── Keyboard ───────────────────────────────────────────────────────

    private void OnKey(object sender, KeyEventArgs e)
    {
        if (Keyboard.Modifiers != (ModifierKeys.Control | ModifierKeys.Alt)) return;
        var o = _m.Overlays;
        switch (e.Key)
        {
            case Key.Z: o.Zebra = !o.Zebra; break;
            case Key.P: o.Peaking = !o.Peaking; break;
            case Key.C: o.FalseColor = !o.FalseColor; break;
            case Key.G: o.Grid = !o.Grid; break;
            default: return;
        }
        _m.SaveOverlays();
        e.Handled = true;
    }
}

/// RGB histogram with additive blending, like the Mac's Canvas version.
public sealed class HistogramView : FrameworkElement
{
    public ScopeData? Data;

    protected override void OnRender(DrawingContext dc)
    {
        dc.DrawRectangle(Brushes.Black, null, new Rect(0, 0, ActualWidth, ActualHeight));
        if (Data == null) return;
        void Curve(float[] v, Color c)
        {
            var geo = new StreamGeometry();
            using (var ctx = geo.Open())
            {
                ctx.BeginFigure(new Point(0, ActualHeight), true, true);
                for (int i = 0; i < v.Length; i++)
                    ctx.LineTo(new Point(ActualWidth * i / (v.Length - 1), ActualHeight * (1 - v[i] * 0.95)), true, false);
                ctx.LineTo(new Point(ActualWidth, ActualHeight), true, false);
            }
            geo.Freeze();
            dc.DrawGeometry(new SolidColorBrush(c), null, geo);
        }
        Curve(Data.Red, Color.FromArgb(120, 230, 38, 38));
        Curve(Data.Green, Color.FromArgb(120, 38, 217, 64));
        Curve(Data.Blue, Color.FromArgb(130, 51, 89, 255));
        Curve(Data.Luma, Color.FromArgb(46, 255, 255, 255));
        var pen = new Pen(new SolidColorBrush(Color.FromArgb(18, 255, 255, 255)), 1);
        for (int i = 1; i < 4; i++) dc.DrawLine(pen, new Point(ActualWidth * i / 4, 0), new Point(ActualWidth * i / 4, ActualHeight));
    }
}

/// Tiny persisted UI preferences.
public static class Properties
{
    private static readonly string File = System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ProCam", "lasthost.txt");

    public static string? LastHost
    {
        get { try { return System.IO.File.ReadAllText(File).Trim(); } catch { return null; } }
        set { try { System.IO.File.WriteAllText(File, value ?? ""); } catch { } }
    }
}
