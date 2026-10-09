using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Win32;

namespace ProCam;

/// The right-hand control column. Port of Mac/Inspector.swift, built in code.
///
/// Rebuilt completely when the structure changes (lens list, a mode switch,
/// settings replaced by phone or preset); live readouts are refreshed in
/// place so a slider being dragged is never recreated under the cursor.
public sealed class Inspector : ScrollViewer
{
    private readonly StudioModel _m;
    private readonly StackPanel _root = new();
    private readonly List<Action> _liveRefresh = new();
    private static readonly Dictionary<string, bool> Open = new();
    private string _lensSignature = "";
    private bool _presetEditorOpen;

    private static Brush B(string key) => (Brush)Application.Current.Resources[key];
    private static readonly CultureInfo De = CultureInfo.GetCultureInfo("de-DE");

    public Inspector(StudioModel m)
    {
        _m = m;
        Content = _root;
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
        Background = B("Panel");
        Rebuild();
        m.SettingsReplaced += Rebuild;
        m.StatusChanged += () =>
        {
            var sig = string.Join("|", m.Lenses.Select(l => l.Id)) + m.Ranges.HasTorch + m.Ranges.ManualFocus
                      + m.PhoneLutName + m.LutError + m.Presets.Count;
            if (sig != _lensSignature) { _lensSignature = sig; Rebuild(); }
            else RefreshLive();
        };
    }

    private CameraSettings S => _m.Settings;

    public void Rebuild()
    {
        double offset = VerticalOffset;
        _root.Children.Clear();
        _liveRefresh.Clear();
        Camera(); Exposure(); WhiteBalance(); FocusSection(); Picture(); Grade(); Wheels(); Lut(); Effects(); Monitoring(); Presets();
        ScrollToVerticalOffset(offset);
    }

    private void RefreshLive()
    {
        foreach (var a in _liveRefresh) a();
    }

    // ─── Sections ───────────────────────────────────────────────────────

    private void Camera()
    {
        Section("Kamera", "◉", p =>
        {
            if (_m.Lenses.Count == 0)
            {
                p.Children.Add(Hint("Objektive erscheinen, sobald das iPhone verbunden ist."));
            }
            else
            {
                p.Children.Add(Label("Objektiv"));
                p.Children.Add(Chips(_m.Lenses.Select(l => (l.Name, l.Id == S.LensId, (Action)(() =>
                {
                    _m.Edit(s => { s.LensId = l.Id; s.Zoom = 1; s.Mirror = l.IsFront; });
                    Rebuild();
                }), true))));
            }
            var lens = ActiveLens;
            p.Children.Add(Label("Auflösung"));
            p.Children.Add(Chips((lens?.Formats ?? new()).Select(f => (f.Label, f.Height == S.Height, (Action)(() =>
            {
                _m.Edit(s => { s.Width = f.Width; s.Height = f.Height; s.Fps = Math.Min(s.Fps, f.MaxFps); });
                Rebuild();
            }), true))));

            p.Children.Add(Label("Bildrate"));
            double maxFps = ActiveFormat?.MaxFps ?? 30;
            p.Children.Add(Chips(new[] { 24.0, 25, 30, 50, 60 }.Select(fps => (((int)fps).ToString(), S.Fps == fps, (Action)(() =>
            {
                _m.Edit(s => { s.Fps = fps; s.Shutter = Math.Min(s.Shutter, 1 / fps); });
                Rebuild();
            }), fps <= maxFps))));

            p.Children.Add(Label("Codec"));
            p.Children.Add(Chips(new[] { ("HEVC", VideoCodec.Hevc), ("H.264", VideoCodec.H264) }.Select(c =>
                (c.Item1, S.Codec == c.Item2, (Action)(() => { _m.Edit(s => s.Codec = c.Item2); Rebuild(); }), true))));
            p.Children.Add(SliderRow("Datenrate", () => S.BitrateMbps, v => _m.Edit(s => s.BitrateMbps = Math.Round(v)),
                2, 60, 12, v => $"{v:0} Mbit/s"));

            p.Children.Add(Label("Zoom"));
            double lo = Math.Log(_m.Ranges.ZoomMin), hi = Math.Log(Math.Max(_m.Ranges.ZoomMax, _m.Ranges.ZoomMin + 0.01));
            p.Children.Add(SliderRow("Faktor", () => (Math.Log(S.Zoom) - lo) / (hi - lo),
                v => _m.Edit(s => s.Zoom = Math.Exp(lo + v * (hi - lo))), 0, 1, null, _ => $"{S.Zoom:0.00}×"));
            p.Children.Add(Chips(new[] { 1.0, 1.5, 2, 3, 5 }.Where(z => z <= _m.Ranges.ZoomMax).Select(z =>
                (z == 1 ? "1×" : z.ToString(De) + "×", Math.Abs(S.Zoom - z) < 0.01, (Action)(() => { _m.Edit(s => s.Zoom = z); Rebuild(); }), true))));
        });
    }

    private void Exposure()
    {
        Section("Belichtung", "☀", p =>
        {
            p.Children.Add(ModePicker(S.ExposureMode, m => { _m.SetExposureMode(m); Rebuild(); }, true));
            if (S.ExposureMode == ControlMode.Manual)
            {
                p.Children.Add(StepRow("ISO", IsoValues(), () => S.Iso, v => _m.Edit(s => s.Iso = (float)v), v => $"{v:0}"));
                p.Children.Add(StepRow("Verschluss", ShutterValues(), () => S.Shutter, v => _m.Edit(s => s.Shutter = v), ShutterLabel));
                p.Children.Add(Chips(new[]
                {
                    ($"180° (1/{(int)(S.Fps * 2)})", false, (Action)(() => { _m.Edit(s => s.Shutter = 1 / (s.Fps * 2)); Rebuild(); }), true),
                    ("Flimmerfrei 50 Hz", false, (Action)(() => { _m.Edit(s => s.Shutter = s.Fps > 50 ? 1.0 / 100 : 1.0 / 50); Rebuild(); }), true),
                }));
                p.Children.Add(Readout("Belichtungsmesser", () => $"{_m.Readings.ExposureOffset:+0.0;-0.0;0.0} EV"));
            }
            else
            {
                p.Children.Add(SliderRow("Belichtungskorrektur", () => S.ExposureBias, v => _m.Edit(s => s.ExposureBias = (float)v),
                    Math.Max(_m.Ranges.BiasMin, -4), Math.Min(_m.Ranges.BiasMax, 4), 0, v => $"{v:+0.0;-0.0;0.0} EV"));
                p.Children.Add(Readout("Automatik wählt", () => $"ISO {_m.Readings.Iso:0} · {ShutterLabel(_m.Readings.Shutter)}"));
                p.Children.Add(Hint("Alt + Klick ins Bild misst die Belichtung an dieser Stelle."));
            }
        });
    }

    private void WhiteBalance()
    {
        Section("Weißabgleich", "◐", p =>
        {
            p.Children.Add(ModePicker(S.WhiteBalanceMode, m => { _m.SetWhiteBalanceMode(m); Rebuild(); }, true));
            if (S.WhiteBalanceMode == ControlMode.Manual)
            {
                p.Children.Add(SliderRow("Farbtemperatur", () => S.Temperature, v => _m.Edit(s => s.Temperature = (float)v),
                    2000, 10000, 5600, v => $"{v:0} K"));
                p.Children.Add(SliderRow("Tönung", () => S.Tint, v => _m.Edit(s => s.Tint = (float)v), -150, 150, 0, v => $"{v:+0;-0;0}"));
                p.Children.Add(Chips(new[] { ("Kunstlicht 3200", 3200f), ("Leuchtstoff 4000", 4000f), ("Tageslicht 5600", 5600f), ("Bewölkt 6500", 6500f) }
                    .Select(t => (t.Item1, Math.Abs(S.Temperature - t.Item2) < 1, (Action)(() => { _m.Edit(s => s.Temperature = t.Item2); Rebuild(); }), true))));
            }
            else
            {
                p.Children.Add(Readout("Automatik wählt", () => $"{_m.Readings.Temperature:0} K · Tönung {_m.Readings.Tint:+0;-0;0}"));
            }
        });
    }

    private void FocusSection()
    {
        Section("Fokus", "⊕", p =>
        {
            p.Children.Add(ModePicker(S.FocusMode, m => { _m.SetFocusMode(m); Rebuild(); }, _m.Ranges.ManualFocus));
            if (S.FocusMode == ControlMode.Manual)
            {
                p.Children.Add(SliderRow("Fokusdistanz", () => S.LensPosition, v => _m.Edit(s => s.LensPosition = (float)v), 0, 1, null,
                    v => v < 0.02 ? "Nah" : v > 0.98 ? "∞" : $"{v * 100:0} %"));
                p.Children.Add(Switch("Focus Peaking", "Markiert scharfe Kanten in der Vorschau", () => _m.Overlays.Peaking,
                    v => { _m.Overlays.Peaking = v; _m.SaveOverlays(); }));
            }
            else
            {
                p.Children.Add(Readout("Linsenposition", () => $"{_m.Readings.LensPosition * 100:0} %"));
            }
            p.Children.Add(Hint("Klick ins Bild setzt den Fokus auf diese Stelle."));
        });
    }

    private void Picture()
    {
        Section("Bild", "▣", p =>
        {
            bool log = ActiveFormat?.SupportsLog ?? false, hdr = ActiveFormat?.SupportsHDR ?? false;
            p.Children.Add(Switch("Apple Log", log ? "10-Bit, maximaler Dynamikumfang" : "Für dieses Objektiv/Format nicht verfügbar",
                () => S.AppleLog, v => { _m.Edit(s => s.AppleLog = v); Rebuild(); }, log));
            if (S.AppleLog)
                p.Children.Add(Switch("Log → Rec.709 umwandeln", "Aus, wenn eine LUT die Umwandlung übernimmt",
                    () => S.Grade.LogToRec709, v => _m.Edit(s => s.Grade.LogToRec709 = v)));
            p.Children.Add(Switch("HDR", null, () => S.Hdr, v => _m.Edit(s => s.Hdr = v), hdr && !S.AppleLog));
            p.Children.Add(Switch("Bildstabilisierung", "Kostet etwas Bildausschnitt und Latenz", () => S.Stabilization, v => _m.Edit(s => s.Stabilization = v)));
            p.Children.Add(Switch("Spiegeln", null, () => S.Mirror, v => _m.Edit(s => s.Mirror = v)));
            p.Children.Add(Label("Drehung"));
            p.Children.Add(Chips(new[] { 0, 90, 180, 270 }.Select(r => (r == 0 ? "Quer" : r == 90 ? "Hoch" : $"{r}°", S.Rotation == r,
                (Action)(() => { _m.Edit(s => s.Rotation = r); Rebuild(); }), true))));
            if (_m.Ranges.HasTorch)
                p.Children.Add(SliderRow("Licht (Taschenlampe)", () => S.Torch, v => _m.Edit(s => s.Torch = (float)v), 0, 1, 0,
                    v => v < 0.01 ? "Aus" : $"{v * 100:0} %"));
        });
    }

    private void Grade()
    {
        Section("Farbe", "◆", p =>
        {
            var reset = LinkButton("Alles zurücksetzen", () => _m.ResetGrade());
            reset.HorizontalAlignment = HorizontalAlignment.Right;
            p.Children.Add(reset);
            G(p, "Belichtung", g => g.Exposure, (g, v) => g.Exposure = v, -3, 3, 0, v => $"{v:+0.00;-0.00;0.00} EV");
            G(p, "Kontrast", g => g.Contrast, (g, v) => g.Contrast = v, 0.5, 1.6, 1, Pct);
            G(p, "Lichter", g => g.Highlights, (g, v) => g.Highlights = v, -1, 1, 0, Signed);
            G(p, "Tiefen", g => g.Shadows, (g, v) => g.Shadows = v, -1, 1, 0, Signed);
            G(p, "Schwarzwert (Fade)", g => g.BlackPoint, (g, v) => g.BlackPoint = v, 0, 0.2, 0, v => $"{v * 500:0}");
            G(p, "Sättigung", g => g.Saturation, (g, v) => g.Saturation = v, 0, 2, 1, Pct);
            G(p, "Dynamik", g => g.Vibrance, (g, v) => g.Vibrance = v, -1, 1, 0, Signed);
            G(p, "Temperatur", g => g.Temperature, (g, v) => g.Temperature = v, -1, 1, 0, Signed);
            G(p, "Tönung", g => g.Tint, (g, v) => g.Tint = v, -1, 1, 0, Signed);
            G(p, "Schärfe", g => g.Sharpen, (g, v) => g.Sharpen = v, 0, 1, 0, Pct);
            G(p, "Vignette", g => g.Vignette, (g, v) => g.Vignette = v, 0, 1, 0, Pct);
        });
    }

    private void G(Panel p, string title, Func<GradeSettings, float> get, Action<GradeSettings, float> set,
        double min, double max, double def, Func<double, string> fmt) =>
        p.Children.Add(SliderRow(title, () => get(S.Grade), v => _m.Edit(s => set(s.Grade, (float)v)), min, max, def, fmt));

    private void Wheels()
    {
        Section("Farbräder", "✣", p =>
        {
            var row = new UniformGrid { Columns = 3 };
            row.Children.Add(new ColorWheel("Lift", () => S.Grade.Lift, v => _m.Edit(s => s.Grade.Lift = v), 0, 0.08f, -0.2f, 0.2f));
            row.Children.Add(new ColorWheel("Gamma", () => S.Grade.Gamma, v => _m.Edit(s => s.Grade.Gamma = v), 1, 0.25f, 0.5f, 2f));
            row.Children.Add(new ColorWheel("Gain", () => S.Grade.Gain, v => _m.Edit(s => s.Grade.Gain = v), 1, 0.25f, 0.5f, 2f));
            p.Children.Add(row);
            p.Children.Add(LinkButton("Räder zurücksetzen", () =>
            {
                _m.Edit(s => { s.Grade.Lift = RGB.Zero; s.Grade.Gamma = RGB.One; s.Grade.Gain = RGB.One; });
                Rebuild();
            }));
            p.Children.Add(Hint("Ziehen: Farbe · Doppelklick: Farbe zurücksetzen"));
        }, defaultOpen: false);
    }

    private void Lut()
    {
        Section("LUT", "▦", p =>
        {
            var row = new DockPanel { LastChildFill = true };
            var load = FlatButton("Laden …", () =>
            {
                var dlg = new OpenFileDialog { Filter = "3D-LUT (*.cube)|*.cube", Title = "3D-LUT im .cube-Format wählen" };
                if (dlg.ShowDialog() == true) _m.LoadLut(dlg.FileName);
            });
            DockPanel.SetDock(load, Dock.Right);
            row.Children.Add(load);
            var info = new StackPanel();
            info.Children.Add(new TextBlock
            {
                Text = _m.PhoneLutName ?? "Keine LUT geladen", FontWeight = FontWeights.SemiBold,
                Foreground = _m.PhoneLutName != null ? B("Text") : B("Dim"), TextTrimming = TextTrimming.CharacterEllipsis,
            });
            info.Children.Add(Hint(".cube · z. B. Apple-Log-LUT oder Film-Look"));
            row.Children.Add(info);
            p.Children.Add(row);
            if (_m.LutError != null) p.Children.Add(new TextBlock { Text = _m.LutError, Foreground = B("Live"), TextWrapping = TextWrapping.Wrap });
            if (_m.PhoneLutName != null)
            {
                p.Children.Add(Switch("LUT aktiv", null, () => S.Grade.LutEnabled, v => _m.Edit(s => s.Grade.LutEnabled = v)));
                G(p, "Stärke", g => g.LutIntensity, (g, v) => g.LutIntensity = v, 0, 1, 1, Pct);
                p.Children.Add(LinkButton("LUT entfernen", () => _m.ClearLut()));
            }
        }, defaultOpen: false);
    }

    private void Effects()
    {
        Section("Effekte", "◎", p =>
        {
            p.Children.Add(Switch("Hintergrund unscharf", "Personenerkennung auf dem iPhone", () => S.BackgroundBlur,
                v => { _m.Edit(s => s.BackgroundBlur = v); Rebuild(); }));
            if (S.BackgroundBlur)
                p.Children.Add(SliderRow("Stärke", () => S.BackgroundBlurAmount, v => _m.Edit(s => s.BackgroundBlurAmount = (float)v), 0.1, 1, 0.6, Pct));
        }, defaultOpen: false);
    }

    private void Monitoring()
    {
        var o = _m.Overlays;
        Section("Monitoring", "∿", p =>
        {
            p.Children.Add(Hint("Nur in der Vorschau – nie in der Webcam."));
            p.Children.Add(Switch("Zebra", null, () => o.Zebra, v => { o.Zebra = v; _m.SaveOverlays(); Rebuild(); }));
            if (o.Zebra)
                p.Children.Add(SliderRow("Schwelle", () => o.ZebraLevel, v => { o.ZebraLevel = (float)v; _m.SaveOverlays(); }, 0.7, 1, 0.95, v => $"{v * 100:0} IRE"));
            p.Children.Add(Switch("Focus Peaking", null, () => o.Peaking, v => { o.Peaking = v; _m.SaveOverlays(); Rebuild(); }));
            if (o.Peaking)
                p.Children.Add(SliderRow("Empfindlichkeit", () => 0.3 - o.PeakThreshold, v => { o.PeakThreshold = (float)(0.3 - v); _m.SaveOverlays(); }, 0.05, 0.27, 0.18, Pct));
            p.Children.Add(Switch("Falschfarben", "Grün = 18 % Grau · Rosa = Haut · Rot = ausgebrannt", () => o.FalseColor, v => { o.FalseColor = v; _m.SaveOverlays(); }));
            p.Children.Add(Switch("Drittel-Raster", null, () => o.Grid, v => { o.Grid = v; _m.SaveOverlays(); }));
            p.Children.Add(Switch("Sicherer Bereich", null, () => o.SafeArea, v => { o.SafeArea = v; _m.SaveOverlays(); }));
        }, defaultOpen: false);
    }

    private void Presets()
    {
        Section("Presets", "❏", p =>
        {
            var wrap = new WrapPanel();
            foreach (var preset in _m.Presets)
            {
                var chip = ChipButton(preset.Name, preset.Grade.SameAs(S.Grade), () => _m.ApplyPreset(preset), true);
                var menu = new ContextMenu();
                var del = new MenuItem { Header = "Löschen" };
                del.Click += (_, _) => _m.DeletePreset(preset);
                menu.Items.Add(del);
                chip.ContextMenu = menu;
                wrap.Children.Add(chip);
            }
            p.Children.Add(wrap);

            if (_presetEditorOpen)
            {
                var name = new TextBox { Margin = new Thickness(0, 0, 0, 6) };
                bool withCamera = false;
                p.Children.Add(name);
                p.Children.Add(Switch("Kamera-Einstellungen mitspeichern", null, () => withCamera, v => withCamera = v));
                var buttons = new DockPanel();
                var save = FlatButton("Speichern", () =>
                {
                    _m.SavePreset(string.IsNullOrWhiteSpace(name.Text) ? $"Preset {_m.Presets.Count + 1}" : name.Text.Trim(), withCamera);
                    _presetEditorOpen = false;
                    Rebuild();
                });
                DockPanel.SetDock(save, Dock.Right);
                buttons.Children.Add(save);
                buttons.Children.Add(LinkButton("Abbrechen", () => { _presetEditorOpen = false; Rebuild(); }));
                p.Children.Add(buttons);
                name.Focus();
            }
            else
            {
                p.Children.Add(LinkButton("+ Aktuellen Look speichern", () => { _presetEditorOpen = true; Rebuild(); }));
            }
            p.Children.Add(Hint("Rechtsklick auf ein Preset zum Löschen."));
        });
    }

    // ─── Values ─────────────────────────────────────────────────────────

    private LensInfo? ActiveLens => _m.Lenses.FirstOrDefault(l => l.Id == S.LensId);
    private FormatOption? ActiveFormat => ActiveLens?.Formats.FirstOrDefault(f => f.Width == S.Width && f.Height == S.Height);

    private List<double> ShutterValues()
    {
        double[] den = { 8000, 6400, 5000, 4000, 3200, 2500, 2000, 1600, 1250, 1000, 800, 640, 500, 400, 320, 250, 200, 160,
                         125, 120, 100, 80, 60, 50, 48, 40, 30, 25, 24, 20, 15, 12, 10, 8, 6, 4, 2 };
        double max = Math.Min(_m.Ranges.ShutterMax, 1 / S.Fps);
        var v = den.Select(d => 1 / d).Where(x => x >= _m.Ranges.ShutterMin - 1e-7 && x <= max + 1e-7).ToList();
        if (!v.Any(x => Math.Abs(x - S.Shutter) < 1e-7)) v.Add(S.Shutter);
        v.Sort();
        return v;
    }

    private List<double> IsoValues()
    {
        double[] stops = { 25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600,
                           2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800 };
        var v = stops.Where(x => x >= _m.Ranges.IsoMin - 0.5 && x <= _m.Ranges.IsoMax + 0.5).ToList();
        if (!v.Contains(S.Iso)) v.Add(S.Iso);
        v.Sort();
        return v;
    }

    public static string ShutterLabel(double s) =>
        s <= 0 ? "–" : s >= 0.25 ? $"{s:0.0} s" : $"1/{Math.Round(1 / s):0}";

    private static string Pct(double v) => $"{v * 100:0} %";
    private static string Signed(double v) => $"{v * 100:+0;-0;0}";

    // ─── Building blocks ────────────────────────────────────────────────

    private void Section(string title, string icon, Action<StackPanel> build, bool defaultOpen = true)
    {
        bool open = Open.TryGetValue(title, out var o) ? o : defaultOpen;
        var outer = new StackPanel();
        var header = new DockPanel { Background = Brushes.Transparent, Cursor = Cursors.Hand, Margin = new Thickness(16, 11, 16, 11) };
        var chevron = new TextBlock { Text = open ? "▾" : "▸", Foreground = B("Dim"), FontSize = 11 };
        DockPanel.SetDock(chevron, Dock.Right);
        header.Children.Add(chevron);
        header.Children.Add(new TextBlock
        {
            Text = icon + "   " + title.ToUpper(De), FontSize = 10.5, FontWeight = FontWeights.Bold,
            Foreground = B("Text"),
        });
        header.MouseLeftButtonUp += (_, _) => { Open[title] = !open; Rebuild(); };
        outer.Children.Add(header);
        if (open)
        {
            var body = new StackPanel { Margin = new Thickness(16, 0, 16, 16) };
            build(body);
            foreach (FrameworkElement c in body.Children) if (c.Margin == default) c.Margin = new Thickness(0, 0, 0, 10);
            outer.Children.Add(body);
        }
        outer.Children.Add(new Border { Height = 1, Background = B("Line") });
        _root.Children.Add(outer);
    }

    private static TextBlock Label(string s) => new() { Text = s, Foreground = B("Dim"), FontSize = 11.5, Margin = new Thickness(0, 0, 0, 4) };
    private static TextBlock Hint(string s) => new() { Text = s, Foreground = B("Dim"), FontSize = 10.5, TextWrapping = TextWrapping.Wrap };

    private FrameworkElement SliderRow(string title, Func<double> get, Action<double> set, double min, double max,
        double? def, Func<double, string> fmt)
    {
        var panel = new StackPanel();
        var head = new DockPanel();
        var value = new TextBlock { FontWeight = FontWeights.SemiBold, FontSize = 11.5 };
        DockPanel.SetDock(value, Dock.Right);
        head.Children.Add(value);
        head.Children.Add(new TextBlock { Text = title, Foreground = B("Dim"), FontSize = 11.5 });
        var slider = new Slider { Minimum = min, Maximum = max, Value = Math.Clamp(get(), min, max), Margin = new Thickness(0, 3, 0, 0) };
        void Show()
        {
            var v = get();
            value.Text = fmt(v);
            value.Foreground = def.HasValue && Math.Abs(v - def.Value) < 0.0005 ? B("Dim") : B("Text");
        }
        slider.ValueChanged += (_, e) => { set(e.NewValue); Show(); };
        // Double-click resets, like every grading app.
        panel.PreviewMouseLeftButtonDown += (_, e) =>
        {
            if (e.ClickCount == 2 && def is { } d) { set(d); slider.Value = Math.Clamp(d, min, max); Show(); e.Handled = true; }
        };
        if (def.HasValue) panel.ToolTip = "Doppelklick setzt zurück";
        Show();
        panel.Children.Add(head);
        panel.Children.Add(slider);
        return panel;
    }

    private FrameworkElement StepRow(string title, List<double> values, Func<double> get, Action<double> set, Func<double, string> fmt)
    {
        int Index() { var v = get(); int best = 0; for (int i = 0; i < values.Count; i++) if (Math.Abs(values[i] - v) < Math.Abs(values[best] - v)) best = i; return best; }
        var panel = new StackPanel();
        var head = new DockPanel();
        var value = new TextBlock { FontWeight = FontWeights.SemiBold, FontSize = 11.5, Text = fmt(get()) };
        DockPanel.SetDock(value, Dock.Right);
        head.Children.Add(value);
        head.Children.Add(new TextBlock { Text = title, Foreground = B("Dim"), FontSize = 11.5 });
        panel.Children.Add(head);
        if (values.Count > 1)
        {
            var slider = new Slider { Minimum = 0, Maximum = values.Count - 1, Value = Index(), IsSnapToTickEnabled = true, TickFrequency = 1, Margin = new Thickness(0, 3, 0, 0) };
            slider.ValueChanged += (_, e) =>
            {
                var v = values[(int)Math.Round(e.NewValue)];
                set(v);
                value.Text = fmt(v);
            };
            panel.Children.Add(slider);
        }
        return panel;
    }

    private FrameworkElement Readout(string title, Func<string> value)
    {
        var b = new Border { Background = B("Raised"), CornerRadius = new CornerRadius(6), Padding = new Thickness(10, 7, 10, 7) };
        var d = new DockPanel();
        var v = new TextBlock { FontWeight = FontWeights.SemiBold, FontSize = 11, Text = value() };
        DockPanel.SetDock(v, Dock.Right);
        d.Children.Add(v);
        d.Children.Add(new TextBlock { Text = title, Foreground = B("Dim"), FontSize = 11 });
        b.Child = d;
        _liveRefresh.Add(() => v.Text = value());
        return b;
    }

    private FrameworkElement ModePicker(ControlMode current, Action<ControlMode> change, bool manual)
    {
        var modes = new List<(string, ControlMode)> { ("Auto", ControlMode.Auto), ("Sperre", ControlMode.Locked) };
        if (manual) modes.Add(("Manuell", ControlMode.Manual));
        var grid = new UniformGrid { Columns = modes.Count };
        foreach (var (name, mode) in modes)
        {
            var c = ChipButton(name, current == mode, () => change(mode), true);
            c.Margin = new Thickness(0, 0, 4, 0);
            c.HorizontalAlignment = HorizontalAlignment.Stretch;
            grid.Children.Add(c);
        }
        return grid;
    }

    private FrameworkElement Chips(IEnumerable<(string title, bool active, Action action, bool enabled)> items)
    {
        var wrap = new WrapPanel { Margin = new Thickness(0, 0, 0, 4) };
        foreach (var (t, a, act, en) in items) wrap.Children.Add(ChipButton(t, a, act, en));
        return wrap;
    }

    private static ToggleButton ChipButton(string title, bool active, Action action, bool enabled)
    {
        var b = new ToggleButton
        {
            Content = title, IsChecked = active, IsEnabled = enabled,
            Style = (Style)Application.Current.Resources["Chip"],
        };
        b.Click += (_, _) => { b.IsChecked = active; action(); };
        return b;
    }

    private FrameworkElement Switch(string title, string? hint, Func<bool> get, Action<bool> set, bool enabled = true)
    {
        var content = new StackPanel();
        content.Children.Add(new TextBlock { Text = title, FontSize = 11.5 });
        if (hint != null) content.Children.Add(new TextBlock { Text = hint, Foreground = B("Dim"), FontSize = 10, TextWrapping = TextWrapping.Wrap });
        var cb = new CheckBox
        {
            Content = content, IsChecked = get(), IsEnabled = enabled,
            Style = (Style)Application.Current.Resources["Switch"],
        };
        cb.Click += (_, _) => set(cb.IsChecked == true);
        return cb;
    }

    private static Button FlatButton(string text, Action click)
    {
        var b = new Button { Content = text, Style = (Style)Application.Current.Resources["Flat"] };
        b.Click += (_, _) => click();
        return b;
    }

    private static Button LinkButton(string text, Action click)
    {
        var b = new Button { Content = text, Style = (Style)Application.Current.Resources["Link"], HorizontalAlignment = HorizontalAlignment.Left };
        b.Click += (_, _) => click();
        return b;
    }
}

/// Lift / gamma / gain wheel; same maths as Mac/Controls.swift ColorWheel.
public sealed class ColorWheel : StackPanel
{
    private const double Size = 76;
    private readonly Func<RGB> _get;
    private readonly Action<RGB> _set;
    private readonly float _strength;
    private readonly Canvas _canvas = new() { Width = Size, Height = Size };
    private readonly System.Windows.Shapes.Ellipse _puck;
    private readonly TextBlock _value = new() { FontSize = 10, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly float _neutral;

    public ColorWheel(string title, Func<RGB> get, Action<RGB> set, float neutral, float strength, float min, float max)
    {
        _get = get; _set = set; _strength = strength; _neutral = neutral;
        HorizontalAlignment = HorizontalAlignment.Center;
        Children.Add(new TextBlock { Text = title.ToUpperInvariant(), FontSize = 9.5, FontWeight = FontWeights.Bold,
            Foreground = (Brush)Application.Current.Resources["Dim"], HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 6) });

        _canvas.Children.Add(new Image { Source = HueImage(), Width = Size, Height = Size });
        _puck = new System.Windows.Shapes.Ellipse { Width = 9, Height = 9, Fill = Brushes.White };
        _canvas.Children.Add(_puck);
        _canvas.Background = Brushes.Transparent;
        _canvas.MouseLeftButtonDown += (_, e) => { _canvas.CaptureMouse(); Drag(e.GetPosition(_canvas)); if (e.ClickCount == 2) ResetColor(); };
        _canvas.MouseMove += (_, e) => { if (_canvas.IsMouseCaptured) Drag(e.GetPosition(_canvas)); };
        _canvas.MouseLeftButtonUp += (_, _) => _canvas.ReleaseMouseCapture();
        Children.Add(_canvas);

        var master = new Slider { Minimum = min, Maximum = max, Value = Master(get()), Width = Size + 8, Margin = new Thickness(0, 6, 0, 0) };
        master.ValueChanged += (_, e) =>
        {
            var v = _get();
            float d = (float)e.NewValue - Master(v);
            _set(new RGB(v.R + d, v.G + d, v.B + d));
            Update();
        };
        Children.Add(master);
        Children.Add(_value);
        Update();
    }

    private static float Master(RGB v) => (v.R + v.G + v.B) / 3;

    private void Update()
    {
        var v = _get();
        float m = Master(v);
        float dr = v.R - m, dg = v.G - m, db = v.B - m;
        float x = dr - 0.5f * (dg + db);
        float y = MathF.Sqrt(3) / 2 * (dg - db);
        float scale = (float)(Size / 2) / (_strength * 1.5f);
        float angle = MathF.Atan2(y, x);
        float r = MathF.Min((float)(Size / 2 - 6), MathF.Sqrt(x * x + y * y) * scale);
        Canvas.SetLeft(_puck, Size / 2 + r * MathF.Sin(angle) - 4.5);
        Canvas.SetTop(_puck, Size / 2 - r * MathF.Cos(angle) - 4.5);
        _value.Text = (m - _neutral).ToString("+0.00;-0.00;0.00");
        _value.Foreground = (Brush)Application.Current.Resources["Dim"];
    }

    private void Drag(Point p)
    {
        double px = p.X - Size / 2, py = p.Y - Size / 2;
        float r = (float)Math.Min(Math.Sqrt(px * px + py * py), Size / 2 - 6);
        float angle = MathF.Atan2((float)px, (float)-py);
        float mag = r / (float)(Size / 2) * _strength * 1.5f;
        float x = mag * MathF.Cos(angle), y = mag * MathF.Sin(angle);
        float m = Master(_get());
        _set(new RGB(m + 2 * x / 3, m - x / 3 + y / MathF.Sqrt(3), m - x / 3 - y / MathF.Sqrt(3)));
        Update();
    }

    private void ResetColor()
    {
        float m = Master(_get());
        _set(new RGB(m, m, m));
        Update();
    }

    /// Hue ring fading to the panel colour in the centre; red at the top.
    private static ImageSource HueImage()
    {
        int n = (int)Size;
        var px = new byte[n * n * 4];
        for (int yy = 0; yy < n; yy++)
        for (int xx = 0; xx < n; xx++)
        {
            double dx = xx - n / 2.0, dy = yy - n / 2.0, d = Math.Sqrt(dx * dx + dy * dy) / (n / 2.0);
            int o = (yy * n + xx) * 4;
            if (d > 1) continue;
            double hue = (Math.Atan2(dx, -dy) * 180 / Math.PI + 360) % 360;
            var (r, g, b) = Hsv(hue, 1, 1);
            double t = Math.Pow(d, 1.2) * 0.75;
            double bg = 22;
            px[o] = (byte)(bg + (b - bg) * t); px[o + 1] = (byte)(bg + (g - bg) * t); px[o + 2] = (byte)(bg + (r - bg) * t);
            px[o + 3] = (byte)(d > 0.97 ? 255 * (1 - (d - 0.97) / 0.03) : 255);
        }
        var bmp = System.Windows.Media.Imaging.BitmapSource.Create(n, n, 96, 96, PixelFormats.Bgra32, null, px, n * 4);
        bmp.Freeze();
        return bmp;
    }

    private static (double, double, double) Hsv(double h, double s, double v)
    {
        double c = v * s, x = c * (1 - Math.Abs(h / 60 % 2 - 1)), m = v - c;
        var (r, g, b) = h switch { < 60 => (c, x, 0.0), < 120 => (x, c, 0.0), < 180 => (0.0, c, x), < 240 => (0.0, x, c), < 300 => (x, 0.0, c), _ => (c, 0.0, x) };
        return ((r + m) * 255, (g + m) * 255, (b + m) * 255);
    }
}
