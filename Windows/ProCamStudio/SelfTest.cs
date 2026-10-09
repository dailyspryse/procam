using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ProCam;

/// Headless checks run by CI on a real Windows machine:
///
///   ProCamStudio.exe --selftest <testdata> [--vcam <seconds>]
///
/// 1. Protocol: JSON produced by Swift (status.json, commands.jsonl) parses,
///    and our commands have exactly the shape Swift's Codable expects.
/// 2. Decoding: streams recorded in the phone's wire format (by
///    tools/testvector on the Mac) decode completely, with correct colours,
///    in both codecs, including the letterboxed virtual-camera image.
/// 3. With --vcam: feeds the registered "ProCam iPhone" camera for N seconds
///    so CI can grab a frame from it through DirectShow with ffmpeg.
///
/// Results go to stdout and selftest-report.txt; exit code 0 means all passed.
public static class SelfTest
{
    private static readonly StringBuilder Report = new();
    private static int _failures;

    public static int Run(string[] args)
    {
        string dir = args.Length > 1 ? args[1] : "testdata";
        int vcamSeconds = 0;
        int vi = Array.IndexOf(args, "--vcam");
        if (vi >= 0 && vi + 1 < args.Length) int.TryParse(args[vi + 1], out vcamSeconds);

        try
        {
            VideoDecoder.Initialize();
            Line($"FFmpeg {VideoDecoder.Version}");
            ProtocolTests(dir);
            foreach (var codec in new[] { "hevc", "h264" }) DecodeTest(Path.Combine(dir, codec + ".procam"), codec);
            if (vcamSeconds > 0) VirtualCameraTest(Path.Combine(dir, "hevc.procam"), vcamSeconds);
        }
        catch (Exception e)
        {
            Fail("Ausnahme: " + e);
        }

        Line(_failures == 0 ? "ALLE TESTS BESTANDEN" : $"{_failures} FEHLER");
        File.WriteAllText("selftest-report.txt", Report.ToString());
        return _failures == 0 ? 0 : 1;
    }

    private static void Line(string s)
    {
        Report.AppendLine(s);
        Console.WriteLine(s);
    }

    private static void Check(bool ok, string what)
    {
        Line((ok ? "  ok    " : "  FEHLER ") + what);
        if (!ok) _failures++;
    }

    private static void Fail(string what) => Check(false, what);

    // ─── Protocol ───────────────────────────────────────────────────────

    private static void ProtocolTests(string dir)
    {
        Line("Protokoll");
        var status = Wire.Decode<CameraStatus>(File.ReadAllBytes(Path.Combine(dir, "status.json")));
        Check(status != null, "status.json (von Swift) wird gelesen");
        if (status == null) return;
        Check(status.DeviceName == "iPhone Test", "deviceName");
        Check(status.Lenses.Count == 1 && status.Lenses[0].Formats[0].SupportsLog && status.Lenses[0].Formats[0].SupportsHDR,
            "Objektive inkl. supportsLog/supportsHDR");
        Check(Math.Abs(status.Settings.Grade.Lift.B - -0.02f) < 1e-6, "verschachtelte Werte (grade.lift.b)");
        Check(status.Settings.Codec == VideoCodec.Hevc && status.Settings.ExposureMode == ControlMode.Auto, "Enums als Strings");

        var swift = File.ReadAllLines(Path.Combine(dir, "commands.jsonl"));
        var ours = new[]
        {
            Commands.Apply(status.Settings), Commands.FocusAt(0.25, 0.75), Commands.LoadLut("a.cube", "LUT_3D_SIZE 2"),
            Commands.ClearLut(), Commands.RequestKeyframe(), Commands.ExposeAt(0.5, 0.5),
        };
        string[] names = { "apply", "focusAt", "loadLUT", "clearLUT", "requestKeyframe", "exposeAt" };
        for (int i = 0; i < ours.Length; i++)
        {
            var mine = JsonNode.Parse(Encoding.UTF8.GetString(ours[i], 5, ours[i].Length - 5));
            var theirs = JsonNode.Parse(swift[i]);
            var diff = Compare(mine, theirs, names[i]);
            Check(diff == null, $"Befehl {names[i]} hat exakt Swifts Form" + (diff != null ? $" – {diff}" : ""));
        }
    }

    /// Structural comparison: same keys everywhere, numbers equal within
    /// float precision, strings/bools identical.
    private static string? Compare(JsonNode? a, JsonNode? b, string path)
    {
        if (a is JsonObject oa && b is JsonObject ob)
        {
            var ka = oa.Select(p => p.Key).OrderBy(k => k).ToList();
            var kb = ob.Select(p => p.Key).OrderBy(k => k).ToList();
            if (!ka.SequenceEqual(kb))
                return $"{path}: Schlüssel {string.Join(",", ka.Except(kb))} zu viel, {string.Join(",", kb.Except(ka))} fehlen";
            foreach (var k in ka)
            {
                var d = Compare(oa[k], ob[k], path + "." + k);
                if (d != null) return d;
            }
            return null;
        }
        if (a is JsonValue va && b is JsonValue vb)
        {
            if (va.TryGetValue<double>(out var da) && vb.TryGetValue<double>(out var db))
                return Math.Abs(da - db) < 1e-5 ? null : $"{path}: {da} ≠ {db}";
            return a.ToJsonString() == b.ToJsonString() ? null : $"{path}: {a.ToJsonString()} ≠ {b.ToJsonString()}";
        }
        return (a == null && b == null) ? null : $"{path}: Typen verschieden";
    }

    // ─── Decoding ───────────────────────────────────────────────────────

    private static List<WireMessage> ReadStream(string file) => new MessageParser().Feed(File.ReadAllBytes(file));

    private static void DecodeTest(string file, string codec)
    {
        Line($"Dekodieren {codec}");
        var messages = ReadStream(file);
        int sent = messages.Count(m => m.Type == MessageType.VideoFrame);
        Check(messages.Count > 0 && messages[0].Type == MessageType.VideoFormat, $"{sent} Frames im Protokoll gelesen");

        using var dec = new VideoDecoder();
        int decoded = 0, keyRequests = 0;
        DecodedFrame? last = null;
        byte[]? vcam = null;
        dec.FrameDecoded += f => { decoded++; last = f; };
        dec.NeedKeyframe += () => keyRequests++;
        dec.VirtualCameraSink = b => vcam = b;
        var sw = Stopwatch.StartNew();
        foreach (var m in messages)
        {
            if (m.Type == MessageType.VideoFormat) dec.SetFormat(Wire.Decode<VideoFormat>(m.Payload)!);
            else if (m.Type == MessageType.VideoFrame && VideoFramePayload.Decode(m.Payload) is { } fr)
                dec.Decode(fr.sample, fr.ptsUs, fr.keyframe);
        }
        double ms = sw.Elapsed.TotalMilliseconds / Math.Max(decoded, 1);
        Check(decoded == sent, $"alle Frames dekodiert ({decoded}/{sent}, {ms:0.0} ms pro Frame)");
        Check(keyRequests == 0, $"keine Keyframe-Anforderungen ({keyRequests})");
        if (last == null) return;
        Check(last.Width == 1280 && last.Height == 720, $"Größe {last.Width}×{last.Height}");

        // Quadrant centres of the last frame (the moving bar is at x≈1068).
        (int b, int g, int r) Px(int x, int y) { int o = (y * last.Width + x) * 4; return (last.Bgra[o], last.Bgra[o + 1], last.Bgra[o + 2]); }
        ColorCheck("rot", Px(320, 180), (30, 30, 220));
        ColorCheck("grün", Px(960, 180), (30, 200, 30));
        ColorCheck("blau", Px(320, 540), (220, 40, 30));
        ColorCheck("grau", Px(960, 540), (128, 128, 128));

        Check(vcam != null && vcam.Length == VirtualCamera.Width * VirtualCamera.Height * 3, "Webcam-Bild 1920×1080 BGR24");
        if (vcam != null)
        {
            (int b, int g, int r) V(int x, int y) { int o = (y * VirtualCamera.Width + x) * 3; return (vcam[o], vcam[o + 1], vcam[o + 2]); }
            // 1280×720 scales to exactly 1920×1080: no letterbox bars.
            ColorCheck("Webcam rot", V(480, 270), (30, 30, 220));
            ColorCheck("Webcam grau", V(1440, 810), (128, 128, 128));
        }
    }

    private static void ColorCheck(string name, (int b, int g, int r) got, (int b, int g, int r) want)
    {
        int d = Math.Max(Math.Abs(got.b - want.b), Math.Max(Math.Abs(got.g - want.g), Math.Abs(got.r - want.r)));
        Check(d <= 24, $"Farbe {name}: BGR({got.b},{got.g},{got.r}) erwartet ({want.b},{want.g},{want.r}), Abweichung {d}");
    }

    // ─── Virtual camera ─────────────────────────────────────────────────

    private static void VirtualCameraTest(string file, int seconds)
    {
        Line("Virtuelle Kamera");
        Check(VirtualCamera.IsRegistered, $"registriert ({VirtualCamera.Clsid})");
        using var cam = new VirtualCamera();
        bool started = cam.Start();
        Check(started, "Sender gestartet");
        if (!started) return;

        // Decode the test stream once and loop its frames into the camera.
        var frames = new List<byte[]>();
        using (var dec = new VideoDecoder())
        {
            dec.VirtualCameraSink = b => frames.Add((byte[])b.Clone());
            foreach (var m in ReadStream(file))
            {
                if (m.Type == MessageType.VideoFormat) dec.SetFormat(Wire.Decode<VideoFormat>(m.Payload)!);
                else if (VideoFramePayload.Decode(m.Payload) is { } fr) dec.Decode(fr.sample, fr.ptsUs, fr.keyframe);
            }
        }
        var sw = Stopwatch.StartNew();
        int sent = 0;
        bool watched = false;
        while (sw.Elapsed.TotalSeconds < seconds)
        {
            cam.Send(frames[sent % frames.Count]);
            sent++;
            watched |= cam.IsWatched;
            System.Threading.Thread.Sleep(33);
        }
        Line($"  {sent} Frames gesendet, Empfänger verbunden: {watched}");
        Check(watched, "eine App hat die Webcam geöffnet");
    }

    // ─── Fake phone ─────────────────────────────────────────────────────

    /// `--fakephone <testdata> <seconds>`: behaves like the iPhone app on
    /// port 47800 — hello, status 5×/s, the recorded video in a loop — and
    /// logs every command the Studio sends to fakephone-commands.txt.
    public static int FakePhone(string[] args)
    {
        string dir = args.Length > 1 ? args[1] : "testdata";
        int seconds = args.Length > 2 && int.TryParse(args[2], out var s) ? s : 60;
        var stream = ReadStream(Path.Combine(dir, "hevc.procam"));
        var format = stream.First(m => m.Type == MessageType.VideoFormat);
        var frames = stream.Where(m => m.Type == MessageType.VideoFrame).ToList();
        var status = File.ReadAllBytes(Path.Combine(dir, "status.json"));
        var log = new StringBuilder();

        var listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Any, Wire.DefaultPort);
        listener.Start();
        var deadline = DateTime.UtcNow.AddSeconds(seconds);
        try
        {
            while (DateTime.UtcNow < deadline)
            {
                if (!listener.Pending()) { System.Threading.Thread.Sleep(50); continue; }
                using var client = listener.AcceptTcpClient();
                client.NoDelay = true;
                var ns = client.GetStream();
                log.AppendLine("Studio verbunden");
                var parser = new MessageParser();
                var buf = new byte[1 << 16];
                void Send(byte[] m) => ns.Write(m, 0, m.Length);
                Send(Wire.EncodeJson(MessageType.Hello, new Hello { Role = "iphone", Name = "Test-iPhone" }));
                Send(Wire.Encode(MessageType.VideoFormat, format.Payload));
                int i = 0;
                var sw = Stopwatch.StartNew();
                while (client.Connected && DateTime.UtcNow < deadline)
                {
                    // Frames loop; keyframe only at index 0, so restart there.
                    var f = frames[i % frames.Count];
                    var payload = (byte[])f.Payload.Clone();
                    System.Buffers.Binary.BinaryPrimitives.WriteUInt64BigEndian(payload, (ulong)(sw.Elapsed.TotalMilliseconds * 1000));
                    Send(Wire.Encode(MessageType.VideoFrame, payload));
                    if (i % 6 == 0) Send(Wire.Encode(MessageType.Status, status));
                    i++;
                    while (ns.DataAvailable)
                    {
                        int n = ns.Read(buf, 0, buf.Length);
                        foreach (var m in parser.Feed(buf.AsSpan(0, n)))
                            if (m.Type == MessageType.Command)
                                log.AppendLine(Encoding.UTF8.GetString(m.Payload));
                    }
                    System.Threading.Thread.Sleep(33);
                }
            }
        }
        catch (Exception e) { log.AppendLine("Fehler: " + e.Message); }
        finally
        {
            listener.Stop();
            File.WriteAllText("fakephone-commands.txt", log.ToString());
        }
        return 0;
    }
}
