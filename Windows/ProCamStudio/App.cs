using System;
using System.IO;
using System.Windows;

namespace ProCam;

public sealed class App : Application
{
    [STAThread]
    public static int Main(string[] args)
    {
        // Headless verification for CI (see SelfTest.cs). Runs before any
        // window or WPF resource exists.
        if (args.Length > 0 && args[0] == "--selftest")
            return SelfTest.Run(args);
        if (args.Length > 0 && args[0] == "--fakephone")
            return SelfTest.FakePhone(args);
        // Elevated helpers started by VirtualCamera.Register (UAC).
        if (args.Length > 0 && (args[0] == "--install-vcam" || args[0] == "--uninstall-vcam"))
        {
            var log = new StringWriter();
            int code = args[0] == "--install-vcam" ? VirtualCamera.InstallMf(log) : VirtualCamera.UninstallMf(log);
            try { File.WriteAllText(Path.Combine(Path.GetTempPath(), "procam-vcam-setup.log"), log.ToString()); } catch { }
            Console.Write(log.ToString());
            return code;
        }

        var app = new App();
        app.Resources.MergedDictionaries.Add(new ResourceDictionary
        {
            Source = new Uri("pack://application:,,,/ProCamStudio;component/Theme.xaml"),
        });
        app.DispatcherUnhandledException += (_, e) =>
        {
            // A UI bug must never take the webcam down mid-call: log and go on.
            Log(e.Exception);
            e.Handled = true;
        };

        try
        {
            VideoDecoder.Initialize();
        }
        catch (Exception e)
        {
            MessageBox.Show("FFmpeg konnte nicht geladen werden. Liegt der Ordner „ffmpeg“ neben ProCamStudio.exe?\n\n" + e.Message,
                "ProCam Studio", MessageBoxButton.OK, MessageBoxImage.Error);
            return 1;
        }

        var model = new StudioModel(app.Dispatcher);
        // `--connect <ip>` skips discovery (scripts, shortcuts, CI).
        int ci = Array.IndexOf(args, "--connect");
        if (ci >= 0 && ci + 1 < args.Length) model.Connect(args[ci + 1]);
        var window = new MainWindow(model);
        window.Closed += (_, _) => model.Dispose();
        return app.Run(window);
    }

    public static void Log(Exception e)
    {
        try
        {
            var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ProCam");
            Directory.CreateDirectory(dir);
            File.AppendAllText(Path.Combine(dir, "errors.log"), $"{DateTime.Now:s} {e}\n\n");
        }
        catch { }
    }
}
