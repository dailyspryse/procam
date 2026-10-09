using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.MemoryMappedFiles;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32;

namespace ProCam;

/// The "ProCam iPhone" webcam.
///
/// Windows 11: a Media Foundation virtual camera (MFCreateVirtualCamera).
/// It is visible to every app — the Camera app, browsers, Discord, Teams,
/// and DirectShow apps through Windows' bridge. Its media source
/// (procam_mfcam.dll, from Windows/VirtualCamera) runs inside the Frame
/// Server service and reads frames from shared memory that we write.
///
/// Windows 10: no MF virtual cameras exist, so a DirectShow filter
/// (softcam, procam_vcam.dll) is used instead; DirectShow apps only.
public sealed class VirtualCamera : IDisposable
{
    public const int Width = 1920;
    public const int Height = 1080;
    public const string DeviceName = "ProCam iPhone";

    /// Must match the GUID patched into softcam.cpp by the CI workflow.
    public const string Clsid = "{5B0E1D52-8C7A-4E2B-9F3D-7A61C2B84E19}";
    /// Must match CLSID_VCam in VirtualCamera/Source/dllmain.cpp.
    public const string MfClsid = "{7C1E4F2A-3B5D-4E8F-A6C2-9D0B1E2F3A4B}";

    /// MF virtual cameras need Windows 11 (build 22000).
    /// PROCAM_VCAM=dshow|mf forces a backend (CI tests both on one machine).
    public static bool UseMediaFoundation =>
        Environment.GetEnvironmentVariable("PROCAM_VCAM") switch
        {
            "dshow" => false,
            "mf" => true,
            _ => Environment.OSVersion.Version.Build >= 22000,
        };

    /// Frames the decoder should produce for this camera.
    public static bool WantsBgra => UseMediaFoundation;

    private const string DShowDll = "procam_vcam.dll";
    private const string MfDll = "procam_mfcam.dll";
    private const string MfCtl = "procam_vcamctl.exe";

    public static string DllPath => Path.Combine(AppContext.BaseDirectory, DShowDll);

    /// The Frame Server service and app-container apps must be able to read
    /// the media source, which is not true inside a user profile (where the
    /// ZIP usually gets extracted). Program Files grants both.
    public static string MfInstallDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "ProCam");

    // ─── softcam (DirectShow) API ───────────────────────────────────────

    [DllImport(DShowDll, CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr scCreateCamera(int width, int height, float framerate);

    [DllImport(DShowDll, CallingConvention = CallingConvention.Cdecl)]
    private static extern void scDeleteCamera(IntPtr camera);

    [DllImport(DShowDll, CallingConvention = CallingConvention.Cdecl)]
    private static extern void scSendFrame(IntPtr camera, byte[] imageBits);

    [DllImport(DShowDll, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    private static extern bool scIsConnected(IntPtr camera);

    // ─── Registration ───────────────────────────────────────────────────

    public static bool IsRegistered => UseMediaFoundation ? IsMfRegistered : IsDShowRegistered;

    private static bool IsDShowRegistered
    {
        get
        {
            var path = RegisteredPath(Registry.ClassesRoot, $@"CLSID\{Clsid}\InprocServer32");
            return path != null && string.Equals(Path.GetFullPath(path), Path.GetFullPath(DllPath),
                StringComparison.OrdinalIgnoreCase);
        }
    }

    private static bool IsMfRegistered
    {
        get
        {
            var path = RegisteredPath(Registry.LocalMachine, $@"SOFTWARE\Classes\CLSID\{MfClsid}\InprocServer32");
            return path != null && File.Exists(path);
        }
    }

    private static string? RegisteredPath(RegistryKey root, string sub)
    {
        try
        {
            using var key = root.OpenSubKey(sub);
            return key?.GetValue(null) as string;
        }
        catch { return null; }
    }

    /// Asks for admin rights (UAC) and runs the actual setup in an elevated
    /// copy of this app (`--install-vcam`). Returns false if declined/failed.
    public static bool Register(bool unregister = false)
    {
        if (!UseMediaFoundation)
            return RunElevated("regsvr32.exe", (unregister ? "/u " : "") + "/s \"" + DllPath + "\"");
        var exe = Environment.ProcessPath ?? Path.Combine(AppContext.BaseDirectory, "ProCamStudio.exe");
        return RunElevated(exe, unregister ? "--uninstall-vcam" : "--install-vcam");
    }

    private static bool RunElevated(string file, string args)
    {
        try
        {
            var psi = new ProcessStartInfo(file, args)
            {
                UseShellExecute = true,
                Verb = "runas",
                WindowStyle = ProcessWindowStyle.Hidden,
            };
            using var p = Process.Start(psi);
            p?.WaitForExit(60000);
            return p != null && p.ExitCode == 0;
        }
        catch (Win32Exception)
        {
            return false; // UAC cancelled
        }
    }

    /// Runs elevated. Copies the media source to Program Files, registers it,
    /// creates the system-wide camera and removes the DirectShow camera so
    /// DirectShow apps do not list "ProCam iPhone" twice.
    public static int InstallMf(TextWriter log)
    {
        try
        {
            Directory.CreateDirectory(MfInstallDir);
            // A running Frame Server keeps the old DLL loaded; a new file name
            // per install avoids "file in use" and Windows' DLL cache alike.
            var target = Path.Combine(MfInstallDir, $"procam_mfcam_{DateTime.UtcNow:yyyyMMddHHmmss}.dll");
            // Write the bytes instead of copying, which also drops the
            // downloaded-from-the-internet mark (Zone.Identifier).
            File.WriteAllBytes(target, File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, MfDll)));
            var ctl = Path.Combine(MfInstallDir, MfCtl);
            File.WriteAllBytes(ctl, File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, MfCtl)));

            int r = Run("regsvr32.exe", $"/s \"{target}\"", log);
            if (r != 0) { log.WriteLine($"regsvr32 fehlgeschlagen: {r}"); return 10; }
            r = Run(ctl, "install", log);
            if (r != 0) { log.WriteLine($"Kamera anlegen fehlgeschlagen: {r}"); return 11; }

            if (File.Exists(DllPath)) Run("regsvr32.exe", $"/u /s \"{DllPath}\"", log);

            // Clean up older copies that are no longer registered.
            foreach (var old in Directory.GetFiles(MfInstallDir, "procam_mfcam_*.dll"))
                if (!string.Equals(old, target, StringComparison.OrdinalIgnoreCase))
                    try { File.Delete(old); } catch { /* still loaded: next time */ }
            return 0;
        }
        catch (Exception e)
        {
            log.WriteLine(e.ToString());
            return 12;
        }
    }

    public static int UninstallMf(TextWriter log)
    {
        var ctl = Path.Combine(MfInstallDir, MfCtl);
        if (File.Exists(ctl)) Run(ctl, "remove", log);
        var path = RegisteredPath(Registry.LocalMachine, $@"SOFTWARE\Classes\CLSID\{MfClsid}\InprocServer32");
        if (path != null) Run("regsvr32.exe", $"/u /s \"{path}\"", log);
        return 0;
    }

    private static int Run(string file, string args, TextWriter log)
    {
        var psi = new ProcessStartInfo(file, args) { UseShellExecute = false, RedirectStandardOutput = true, CreateNoWindow = true };
        using var p = Process.Start(psi)!;
        log.Write(p.StandardOutput.ReadToEnd());
        p.WaitForExit();
        log.WriteLine($"{Path.GetFileName(file)} {args} → {p.ExitCode}");
        return p.ExitCode;
    }

    // ─── Sending ────────────────────────────────────────────────────────

    private IntPtr _cam;
    private readonly MfFrameWriter? _mf = UseMediaFoundation ? new MfFrameWriter() : null;
    private readonly object _gate = new();

    public bool IsActive => _mf != null || _cam != IntPtr.Zero;

    /// Creates the sender side. For DirectShow this fails if another ProCam
    /// instance already owns the camera.
    public bool Start()
    {
        if (_mf != null) return true;
        lock (_gate)
        {
            if (_cam != IntPtr.Zero) return true;
            try
            {
                // Frame rate 0: frames go out immediately, no pacing.
                _cam = scCreateCamera(Width, Height, 0);
            }
            catch (DllNotFoundException) { _cam = IntPtr.Zero; }
            catch (EntryPointNotFoundException) { _cam = IntPtr.Zero; }
            return _cam != IntPtr.Zero;
        }
    }

    /// Some app is reading the camera right now.
    public bool IsWatched
    {
        get
        {
            if (_mf != null) return _mf.IsOpen;
            lock (_gate) return _cam != IntPtr.Zero && scIsConnected(_cam);
        }
    }

    /// 1920×1080, top-down. BGRA for Media Foundation, BGR24 for DirectShow
    /// (see WantsBgra).
    public void Send(byte[] frame)
    {
        if (_mf != null) { _mf.Write(frame); return; }
        lock (_gate)
        {
            if (_cam != IntPtr.Zero) scSendFrame(_cam, frame);
        }
    }

    public void Dispose()
    {
        _mf?.Dispose();
        lock (_gate)
        {
            if (_cam != IntPtr.Zero) scDeleteCamera(_cam);
            _cam = IntPtr.Zero;
        }
    }

    /// Dark "waiting for iPhone" card for the DirectShow camera. (The MF
    /// media source draws its own when frames stop.)
    public static byte[] MakePlaceholder()
    {
        int bpp = WantsBgra ? 4 : 3;
        var img = new byte[Width * Height * bpp];
        void Set(int o, byte b, byte g, byte r) { img[o] = b; img[o + 1] = g; img[o + 2] = r; if (bpp == 4) img[o + 3] = 255; }
        for (int i = 0; i < img.Length; i += bpp) Set(i, 16, 14, 14);
        int cx = Width / 2, cy = Height / 2;
        for (int y = cy - 80; y < cy + 80; y++)
        for (int x = cx - 80; x < cx + 80; x++)
        {
            double d = Math.Sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy));
            int o = (y * Width + x) * bpp;
            if (d > 66 && d < 72) Set(o, 60, 58, 58);
            else if (d < 14) Set(o, 58, 68, 255);
        }
        return img;
    }
}

/// Writes frames into the section the MF media source reads. Layout must
/// match VirtualCamera/Source/FrameGenerator.cpp.
///
/// The section is created by the media source inside the Frame Server
/// service: only services may create Global objects. It therefore exists
/// only while some app has the camera open, and we keep trying to open it.
public sealed unsafe class MfFrameWriter : IDisposable
{
    public const string SectionName = @"Global\ProCamVirtualCamera";
    private const uint Magic = 0x5043414D; // 'PCAM'
    private const int HeaderSize = 64;
    private static readonly int FrameBytes = VirtualCamera.Width * VirtualCamera.Height * 4;

    private MemoryMappedFile? _file;
    private MemoryMappedViewAccessor? _view;
    private byte* _ptr;
    private long _lastAttempt;
    private readonly object _gate = new();

    public bool IsOpen { get { lock (_gate) return _ptr != null; } }

    public void Write(byte[] bgra)
    {
        if (bgra.Length < FrameBytes) return;
        lock (_gate)
        {
            if (_ptr == null && !TryOpen()) return;
            var seq = (long*)(_ptr + 16);
            *(uint*)_ptr = Magic;
            *(uint*)(_ptr + 4) = 1;
            *(uint*)(_ptr + 8) = VirtualCamera.Width;
            *(uint*)(_ptr + 12) = VirtualCamera.Height;
            Interlocked.Increment(ref *seq);         // odd: writing
            fixed (byte* src = bgra)
                Buffer.MemoryCopy(src, _ptr + HeaderSize, FrameBytes, FrameBytes);
            *(long*)(_ptr + 24) = Environment.TickCount64;
            Interlocked.Increment(ref *seq);         // even: complete
        }
    }

    private bool TryOpen()
    {
        long now = Environment.TickCount64;
        if (now - _lastAttempt < 1000) return false;
        _lastAttempt = now;
        try
        {
            _file = MemoryMappedFile.OpenExisting(SectionName, MemoryMappedFileRights.ReadWrite);
            _view = _file.CreateViewAccessor(0, 0, MemoryMappedFileAccess.ReadWrite);
            if (_view.Capacity < HeaderSize + FrameBytes) { Close(); return false; }
            byte* p = null;
            _view.SafeMemoryMappedViewHandle.AcquirePointer(ref p);
            _ptr = p + _view.PointerOffset;
            return true;
        }
        catch
        {
            Close();
            return false; // no app is using the camera yet
        }
    }

    private void Close()
    {
        if (_ptr != null && _view != null) _view.SafeMemoryMappedViewHandle.ReleasePointer();
        _ptr = null;
        _view?.Dispose(); _view = null;
        _file?.Dispose(); _file = null;
    }

    public void Dispose()
    {
        lock (_gate) Close();
    }
}
