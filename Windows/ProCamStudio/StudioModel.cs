using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Threading;

namespace ProCam;

public sealed class Preset
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public GradeSettings Grade { get; set; } = new();
    public CameraSettings? Camera { get; set; }
}

public enum VcamState { NotInstalled, Ready, Busy, Failed }

/// Port of Mac/StudioModel.swift. All public members are used on the UI
/// thread; network and decoder callbacks are marshalled onto it.
public sealed class StudioModel : IDisposable
{
    // Connection
    public IReadOnlyList<Phone> Phones { get; private set; } = Array.Empty<Phone>();
    public LinkState LinkState { get; private set; } = LinkState.Idle;
    public string? DeviceName { get; private set; }
    public string? ConnectingTo { get; private set; }

    // Camera
    public CameraSettings Settings { get; private set; } = new();
    public List<LensInfo> Lenses { get; private set; } = new();
    public CameraRanges Ranges { get; private set; } = new();
    public CameraReadings Readings { get; private set; } = new();
    public string? PhoneLutName { get; private set; }
    public string? PhoneError { get; private set; }
    public (int W, int H) VideoSize { get; private set; } = (1920, 1080);
    public double ReceivedFps { get; private set; }

    // Studio-side
    public OverlayOptions Overlays { get; private set; } = new();
    public ScopeData Scopes { get; private set; } = new();
    public List<Preset> Presets { get; private set; } = new();
    public VcamState Vcam { get; private set; } = VcamState.NotInstalled;
    public string? LutPath { get; private set; }
    public string? LutError { get; private set; }

    /// Something other than a control the user is dragging changed the
    /// settings (phone clamped a value, preset, restore) — rebuild controls.
    public event Action? SettingsReplaced;
    /// Readings, ranges, lenses, connection, vcam … — refresh labels.
    public event Action? StatusChanged;
    public event Action? ScopesChanged;

    private readonly Dispatcher _ui;
    private readonly PhoneLink _link = new();
    private readonly VideoDecoder _decoder = new();
    private readonly VirtualCamera _vcam = new();
    private readonly DispatcherTimer _sendTimer;
    private DateTime _lastLocalEdit = DateTime.MinValue;
    private bool _pendingSend;
    private bool _receivedInitialStatus;

    // Latest decoded frame for the preview, handed over without copying.
    private readonly object _frameGate = new();
    private DecodedFrame? _latest;
    private int _frameGeneration;
    private int _frameCounter;
    private int _scopeBusy;
    private int _fpsCount;
    private readonly Stopwatch _fpsWatch = Stopwatch.StartNew();
    private long _lastKeyframeRequest;

    private static readonly string Dir =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ProCam");

    public StudioModel(Dispatcher ui)
    {
        _ui = ui;
        Directory.CreateDirectory(Dir);
        Settings = Load<CameraSettings>("settings") ?? new CameraSettings();
        Overlays = Load<OverlayOptions>("overlays") ?? new OverlayOptions();
        Presets = Load<List<Preset>>("presets") ?? BuiltInLooks();
        LutPath = Load<string>("lut");

        _sendTimer = new DispatcherTimer(TimeSpan.FromMilliseconds(33), DispatcherPriority.Normal,
            (_, _) => FlushSend(), _ui);
        _sendTimer.Start();

        _link.PhonesChanged += p => _ui.BeginInvoke(() => { Phones = p; StatusChanged?.Invoke(); });
        _link.StateChanged += (s, name) => _ui.BeginInvoke(() => OnLinkState(s, name));
        _link.StatusReceived += s => _ui.BeginInvoke(() => OnStatus(s));
        _link.FormatReceived += f =>
        {
            try { _decoder.SetFormat(f); }
            catch (Exception e) { _ui.BeginInvoke(() => { PhoneError = e.Message; StatusChanged?.Invoke(); }); }
            _ui.BeginInvoke(() => { VideoSize = (f.Width, f.Height); StatusChanged?.Invoke(); });
        };
        _link.FrameReceived += (sample, pts, key) => _decoder.Decode(sample, pts, key);
        _decoder.NeedKeyframe += RequestKeyframeThrottled;
        _decoder.FrameDecoded += OnFrame;

        StartVirtualCamera();
        _link.Start();
        _ = Task.Run(PlaceholderLoop);
    }

    // ─── Frames ─────────────────────────────────────────────────────────

    private void OnFrame(DecodedFrame f)
    {
        lock (_frameGate) { _latest = f; _frameGeneration++; }
        _fpsCount++;
        if (_fpsWatch.Elapsed.TotalSeconds >= 1)
        {
            double fps = _fpsCount / _fpsWatch.Elapsed.TotalSeconds;
            _fpsCount = 0;
            _fpsWatch.Restart();
            _ui.BeginInvoke(() => { ReceivedFps = fps; });
        }
        // Scopes at ~10 Hz, never two at once.
        if (++_frameCounter % 3 == 0 && Interlocked.CompareExchange(ref _scopeBusy, 1, 0) == 0)
        {
            Task.Run(() =>
            {
                try
                {
                    var d = ScopeAnalyzer.Analyze(f);
                    _ui.BeginInvoke(() => { Scopes = d; ScopesChanged?.Invoke(); });
                }
                finally { Interlocked.Exchange(ref _scopeBusy, 0); }
            });
        }
    }

    /// Returns the newest frame if it changed since `generation`.
    public DecodedFrame? TakeFrame(ref int generation)
    {
        lock (_frameGate)
        {
            if (_frameGeneration == generation) return null;
            generation = _frameGeneration;
            return _latest;
        }
    }

    private void RequestKeyframeThrottled()
    {
        long now = Environment.TickCount64;
        if (now - Interlocked.Read(ref _lastKeyframeRequest) < 500) return;
        Interlocked.Exchange(ref _lastKeyframeRequest, now);
        _link.Send(Commands.RequestKeyframe());
    }

    // ─── Link ───────────────────────────────────────────────────────────

    private void OnLinkState(LinkState s, string? name)
    {
        LinkState = s;
        switch (s)
        {
            case LinkState.Connected:
                DeviceName = name;
                ConnectingTo = null;
                _receivedInitialStatus = false;
                break;
            case LinkState.Connecting:
                ConnectingTo = name;
                break;
            case LinkState.Idle:
                DeviceName = null;
                ConnectingTo = null;
                ReceivedFps = 0;
                lock (_frameGate) { _latest = null; _frameGeneration++; }
                break;
        }
        StatusChanged?.Invoke();
    }

    private void OnStatus(CameraStatus s)
    {
        Lenses = s.Lenses;
        Ranges = s.Ranges;
        Readings = s.Readings;
        PhoneLutName = s.LutName;
        PhoneError = s.Error;

        if (!_receivedInitialStatus)
        {
            _receivedInitialStatus = true;
            // Restore the last setup; a lens ID from another phone is meaningless.
            if (!s.Lenses.Any(l => l.Id == Settings.LensId)) Settings.LensId = s.Settings.LensId;
            _link.Send(Commands.Apply(Settings));
            if (s.LutName == null && LutPath != null) LoadLut(LutPath);
            SettingsReplaced?.Invoke();
        }
        else if (!s.Settings.SameAs(Settings) && (DateTime.UtcNow - _lastLocalEdit).TotalSeconds > 1.2)
        {
            // Adopt the phone's clamped values once the user stopped dragging.
            Settings = s.Settings;
            SettingsReplaced?.Invoke();
        }
        StatusChanged?.Invoke();
    }

    public void Connect(Phone p) => _link.Connect(p);
    public void Connect(string host) => _link.Connect(host);
    public void Disconnect() => _link.Disconnect();

    // ─── Settings ───────────────────────────────────────────────────────

    /// Every control goes through here. Sends are coalesced to ~30/s.
    public void Edit(Action<CameraSettings> change)
    {
        change(Settings);
        _lastLocalEdit = DateTime.UtcNow;
        _pendingSend = true;
    }

    private void FlushSend()
    {
        if (!_pendingSend) return;
        _pendingSend = false;
        _link.Send(Commands.Apply(Settings));
        Save("settings", Settings);
    }

    public void PointOfInterest(double x, double y, bool exposure) =>
        _link.Send(exposure ? Commands.ExposeAt(x, y) : Commands.FocusAt(x, y));

    public void SetExposureMode(ControlMode m)
    {
        Edit(s =>
        {
            if (m == ControlMode.Manual && s.ExposureMode != ControlMode.Manual && Readings.Iso > 0)
            {
                s.Iso = Readings.Iso;
                s.Shutter = Readings.Shutter;
            }
            s.ExposureMode = m;
        });
    }

    public void SetWhiteBalanceMode(ControlMode m)
    {
        Edit(s =>
        {
            if (m == ControlMode.Manual && s.WhiteBalanceMode != ControlMode.Manual && Readings.Temperature > 0)
            {
                s.Temperature = MathF.Round(Readings.Temperature);
                s.Tint = MathF.Round(Readings.Tint);
            }
            s.WhiteBalanceMode = m;
        });
    }

    public void SetFocusMode(ControlMode m)
    {
        Edit(s =>
        {
            if (m == ControlMode.Manual && s.FocusMode != ControlMode.Manual) s.LensPosition = Readings.LensPosition;
            s.FocusMode = m;
        });
    }

    public void SaveOverlays() => Save("overlays", Overlays);

    // ─── LUT ────────────────────────────────────────────────────────────

    public void LoadLut(string path)
    {
        try
        {
            var text = File.ReadAllText(path);
            CubeLut.Validate(text);
            _link.Send(Commands.LoadLut(Path.GetFileName(path), text));
            LutPath = path;
            LutError = null;
            Save("lut", path);
        }
        catch (Exception e)
        {
            LutError = e.Message;
        }
        StatusChanged?.Invoke();
    }

    public void ClearLut()
    {
        _link.Send(Commands.ClearLut());
        LutPath = null;
        try { File.Delete(Path.Combine(Dir, "lut.json")); } catch { }
        StatusChanged?.Invoke();
    }

    // ─── Presets ────────────────────────────────────────────────────────

    public void ApplyPreset(Preset p)
    {
        if (p.Camera != null)
        {
            var cam = p.Camera.Clone();
            if (!Lenses.Any(l => l.Id == cam.LensId)) cam.LensId = Settings.LensId;
            cam.Grade = p.Grade.Clone();
            Settings = cam;
        }
        else
        {
            Settings.Grade = p.Grade.Clone();
        }
        _lastLocalEdit = DateTime.UtcNow;
        _pendingSend = true;
        SettingsReplaced?.Invoke();
    }

    public void SavePreset(string name, bool includeCamera)
    {
        Presets.Add(new Preset { Name = name, Grade = Settings.Grade.Clone(), Camera = includeCamera ? Settings.Clone() : null });
        Save("presets", Presets);
        StatusChanged?.Invoke();
    }

    public void DeletePreset(Preset p)
    {
        Presets.Remove(p);
        Save("presets", Presets);
        StatusChanged?.Invoke();
    }

    public void ResetGrade()
    {
        Edit(s => s.Grade = new GradeSettings());
        SettingsReplaced?.Invoke();
    }

    public static List<Preset> BuiltInLooks()
    {
        GradeSettings G(Action<GradeSettings> f) { var g = new GradeSettings(); f(g); return g; }
        return new()
        {
            new() { Name = "Neutral", Grade = new GradeSettings() },
            new() { Name = "Warm", Grade = G(g => { g.Temperature = 0.35f; g.Contrast = 1.08f; g.Saturation = 1.05f; g.BlackPoint = 0.03f; g.Highlights = -0.25f; g.Lift = new RGB(0.01f, 0, -0.015f); }) },
            new() { Name = "Kühl", Grade = G(g => { g.Temperature = -0.3f; g.Contrast = 1.12f; g.Saturation = 0.9f; g.Gain = new RGB(0.98f, 1, 1.03f); }) },
            new() { Name = "Knackig", Grade = G(g => { g.Contrast = 1.25f; g.Vibrance = 0.35f; g.Shadows = -0.15f; g.Sharpen = 0.3f; }) },
            new() { Name = "Weich", Grade = G(g => { g.Contrast = 0.9f; g.Highlights = -0.3f; g.Shadows = 0.3f; g.Exposure = 0.15f; g.Vibrance = 0.1f; g.Temperature = 0.1f; }) },
            new() { Name = "Kino", Grade = G(g => { g.Contrast = 1.1f; g.Saturation = 0.85f; g.BlackPoint = 0.04f; g.Lift = new RGB(-0.01f, 0.005f, 0.02f); g.Gain = new RGB(1.03f, 1, 0.96f); g.Vignette = 0.3f; }) },
            new() { Name = "Schwarzweiß", Grade = G(g => { g.Saturation = 0; g.Contrast = 1.2f; g.Vignette = 0.25f; }) },
        };
    }

    // ─── Virtual camera ─────────────────────────────────────────────────

    private void StartVirtualCamera()
    {
        if (!VirtualCamera.IsRegistered) { Vcam = VcamState.NotInstalled; return; }
        if (_vcam.Start())
        {
            Vcam = VcamState.Ready;
            _decoder.VirtualCameraSink = _vcam.Send;
        }
        else
        {
            // Another ProCam Studio is already feeding the camera.
            Vcam = VcamState.Busy;
        }
    }

    public void InstallVirtualCamera()
    {
        if (VirtualCamera.Register()) StartVirtualCamera();
        else Vcam = VcamState.Failed;
        StatusChanged?.Invoke();
    }

    public void UninstallVirtualCamera()
    {
        _decoder.VirtualCameraSink = null;
        _vcam.Dispose();
        VirtualCamera.Register(unregister: true);
        Vcam = VcamState.NotInstalled;
        StatusChanged?.Invoke();
    }

    /// While no phone streams, conferencing apps get a calm placeholder
    /// instead of a frozen last frame.
    private async Task PlaceholderLoop()
    {
        var card = VirtualCamera.MakePlaceholder();
        while (true)
        {
            await Task.Delay(500);
            // The MF media source draws its own placeholder when frames stop.
            if (Vcam != VcamState.Ready || VirtualCamera.UseMediaFoundation) continue;
            bool streaming;
            lock (_frameGate) streaming = _latest != null && LinkState == LinkState.Connected;
            if (!streaming || ReceivedFps < 1) _vcam.Send(card);
        }
    }

    // ─── Persistence ────────────────────────────────────────────────────

    private static void Save<T>(string name, T value)
    {
        try { File.WriteAllText(Path.Combine(Dir, name + ".json"), JsonSerializer.Serialize(value, Wire.Json)); }
        catch { }
    }

    private static T? Load<T>(string name)
    {
        try { return JsonSerializer.Deserialize<T>(File.ReadAllText(Path.Combine(Dir, name + ".json")), Wire.Json); }
        catch { return default; }
    }

    public void Dispose()
    {
        _link.Dispose();
        _decoder.Dispose();
        _vcam.Dispose();
    }
}
