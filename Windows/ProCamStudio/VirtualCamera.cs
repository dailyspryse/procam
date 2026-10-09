using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace ProCam;

/// The "ProCam iPhone" webcam, provided by a DirectShow filter (softcam,
/// built in CI with our own name and class ID). Registration needs admin
/// rights once; afterwards the app only feeds frames.
public sealed class VirtualCamera : IDisposable
{
    public const int Width = 1920;
    public const int Height = 1080;
    public const string DeviceName = "ProCam iPhone";

    /// Must match the GUID patched into softcam.cpp by the CI workflow.
    public const string Clsid = "{5B0E1D52-8C7A-4E2B-9F3D-7A61C2B84E19}";

    private const string Dll = "procam_vcam.dll";

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr scCreateCamera(int width, int height, float framerate);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    private static extern void scDeleteCamera(IntPtr camera);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    private static extern void scSendFrame(IntPtr camera, byte[] imageBits);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    private static extern bool scIsConnected(IntPtr camera);

    private IntPtr _cam;
    private readonly object _gate = new();

    public static string DllPath => Path.Combine(AppContext.BaseDirectory, Dll);

    /// Registered and pointing at this copy of the DLL (the app may have
    /// been moved since).
    public static bool IsRegistered
    {
        get
        {
            try
            {
                using var key = Registry.ClassesRoot.OpenSubKey($@"CLSID\{Clsid}\InprocServer32");
                var path = key?.GetValue(null) as string;
                return path != null && string.Equals(Path.GetFullPath(path), Path.GetFullPath(DllPath),
                    StringComparison.OrdinalIgnoreCase);
            }
            catch { return false; }
        }
    }

    /// Runs regsvr32 elevated (UAC prompt). Returns false if the user
    /// declined or registration failed.
    public static bool Register(bool unregister = false)
    {
        try
        {
            var psi = new ProcessStartInfo("regsvr32.exe",
                (unregister ? "/u " : "") + "/s \"" + DllPath + "\"")
            {
                UseShellExecute = true,
                Verb = "runas",
                WindowStyle = ProcessWindowStyle.Hidden,
            };
            using var p = Process.Start(psi);
            p?.WaitForExit(20000);
            return p != null && p.ExitCode == 0;
        }
        catch (Win32Exception)
        {
            return false; // UAC cancelled
        }
    }

    public bool IsActive => _cam != IntPtr.Zero;

    /// Creates the sender side. Fails if another ProCam instance already
    /// owns the camera.
    public bool Start()
    {
        lock (_gate)
        {
            if (_cam != IntPtr.Zero) return true;
            try
            {
                // Frame rate 0: frames go out immediately, no pacing — the
                // phone already delivers at its own rate.
                _cam = scCreateCamera(Width, Height, 0);
            }
            catch (DllNotFoundException) { _cam = IntPtr.Zero; }
            catch (EntryPointNotFoundException) { _cam = IntPtr.Zero; }
            return _cam != IntPtr.Zero;
        }
    }

    public bool IsWatched
    {
        get { lock (_gate) return _cam != IntPtr.Zero && scIsConnected(_cam); }
    }

    /// BGR24, top-down, 1920×1080.
    public void Send(byte[] bgr)
    {
        lock (_gate)
        {
            if (_cam != IntPtr.Zero) scSendFrame(_cam, bgr);
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_cam != IntPtr.Zero) scDeleteCamera(_cam);
            _cam = IntPtr.Zero;
        }
    }

    /// Dark "waiting for iPhone" card, shown while no phone is streaming.
    public static byte[] MakePlaceholder()
    {
        var img = new byte[Width * Height * 3];
        for (int i = 0; i < img.Length; i += 3) { img[i] = 16; img[i + 1] = 14; img[i + 2] = 14; }
        // Lens ring and red dot, drawn with plain math to avoid a GDI dependency.
        int cx = Width / 2, cy = Height / 2;
        for (int y = cy - 80; y < cy + 80; y++)
        for (int x = cx - 80; x < cx + 80; x++)
        {
            double d = Math.Sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy));
            int o = (y * Width + x) * 3;
            if (d > 66 && d < 72) { img[o] = 60; img[o + 1] = 58; img[o + 2] = 58; }
            else if (d < 14) { img[o] = 58; img[o + 1] = 68; img[o + 2] = 255; }
        }
        return img;
    }
}
