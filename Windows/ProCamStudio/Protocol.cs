using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace ProCam;

// Port of Shared/Wire.swift and Shared/CameraModel.swift. The JSON must match
// what Swift's synthesized Codable produces and expects, field for field:
// Swift refuses to decode a CameraSettings with any key missing.

public enum MessageType : byte
{
    Hello = 1, Command = 2, Status = 3, VideoFormat = 4, VideoFrame = 5, Ping = 6, Pong = 7,
}

public static class Wire
{
    public const string BonjourType = "_procam._tcp.local.";
    public const int DefaultPort = 47800;
    public const int ProtocolVersion = 1;
    public const int MaxMessageSize = 32 * 1024 * 1024;

    public static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
        NumberHandling = JsonNumberHandling.AllowNamedFloatingPointLiterals,
    };

    /// [u32 BE length of (type + payload)][u8 type][payload]
    public static byte[] Encode(MessageType type, ReadOnlySpan<byte> payload)
    {
        var buf = new byte[payload.Length + 5];
        BinaryPrimitives.WriteUInt32BigEndian(buf, (uint)(payload.Length + 1));
        buf[4] = (byte)type;
        payload.CopyTo(buf.AsSpan(5));
        return buf;
    }

    public static byte[] EncodeJson<T>(MessageType type, T value) =>
        Encode(type, JsonSerializer.SerializeToUtf8Bytes(value, Json));

    public static T? Decode<T>(ReadOnlySpan<byte> payload)
    {
        try { return JsonSerializer.Deserialize<T>(payload, Json); }
        catch (JsonException) { return default; }
    }
}

public readonly record struct WireMessage(MessageType Type, byte[] Payload);

/// Incremental parser for the length-prefixed stream.
public sealed class MessageParser
{
    private byte[] _buf = new byte[1 << 20];
    private int _len;

    public List<WireMessage> Feed(ReadOnlySpan<byte> chunk)
    {
        if (_len + chunk.Length > _buf.Length)
            Array.Resize(ref _buf, Math.Max(_buf.Length * 2, _len + chunk.Length));
        chunk.CopyTo(_buf.AsSpan(_len));
        _len += chunk.Length;

        var result = new List<WireMessage>();
        int off = 0;
        while (_len - off >= 5)
        {
            int length = (int)BinaryPrimitives.ReadUInt32BigEndian(_buf.AsSpan(off));
            if (length < 1 || length > Wire.MaxMessageSize)
                throw new InvalidOperationException($"Ungültige Nachrichtenlänge {length}");
            if (_len - off < 4 + length) break;
            byte type = _buf[off + 4];
            var payload = _buf.AsSpan(off + 5, length - 1).ToArray();
            off += 4 + length;
            if (Enum.IsDefined(typeof(MessageType), type))
                result.Add(new WireMessage((MessageType)type, payload));
        }
        if (off > 0)
        {
            Buffer.BlockCopy(_buf, off, _buf, 0, _len - off);
            _len -= off;
        }
        return result;
    }
}

public static class VideoFramePayload
{
    public static (ulong ptsUs, bool keyframe, ReadOnlyMemory<byte> sample)? Decode(byte[] data)
    {
        if (data.Length <= 9) return null;
        ulong pts = BinaryPrimitives.ReadUInt64BigEndian(data);
        bool key = (data[8] & 1) != 0;
        return (pts, key, new ReadOnlyMemory<byte>(data, 9, data.Length - 9));
    }
}

// ─── Models ──────────────────────────────────────────────────────────────

public enum VideoCodec { Hevc, H264 }
public enum ControlMode { Auto, Locked, Manual }

public sealed class Hello
{
    public int ProtocolVersion { get; set; } = Wire.ProtocolVersion;
    public string Role { get; set; } = "studio";
    public string Name { get; set; } = "";
}

public sealed class VideoFormat
{
    public VideoCodec Codec { get; set; }
    public int Width { get; set; }
    public int Height { get; set; }
    public List<byte[]> ParameterSets { get; set; } = new();
    public int NalLengthSize { get; set; } = 4;
}

public struct RGB : IEquatable<RGB>
{
    public float R { get; set; }
    public float G { get; set; }
    public float B { get; set; }
    public RGB(float r, float g, float b) { R = r; G = g; B = b; }
    public static RGB Zero => new(0, 0, 0);
    public static RGB One => new(1, 1, 1);
    public bool Equals(RGB o) => R == o.R && G == o.G && B == o.B;
    public override bool Equals(object? o) => o is RGB r && Equals(r);
    public override int GetHashCode() => HashCode.Combine(R, G, B);
}

public sealed class GradeSettings
{
    public float Exposure { get; set; }
    public float Contrast { get; set; } = 1;
    public float Saturation { get; set; } = 1;
    public float Vibrance { get; set; }
    public float Temperature { get; set; }
    public float Tint { get; set; }
    public float Highlights { get; set; }
    public float Shadows { get; set; }
    public float BlackPoint { get; set; }
    public RGB Lift { get; set; } = RGB.Zero;
    public RGB Gamma { get; set; } = RGB.One;
    public RGB Gain { get; set; } = RGB.One;
    public float Vignette { get; set; }
    public float Sharpen { get; set; }
    public float LutIntensity { get; set; } = 1;
    public bool LutEnabled { get; set; } = true;
    public bool LogToRec709 { get; set; } = true;

    public GradeSettings Clone() => (GradeSettings)MemberwiseClone();
    public bool SameAs(GradeSettings o) =>
        JsonSerializer.Serialize(this, Wire.Json) == JsonSerializer.Serialize(o, Wire.Json);
}

public sealed class CameraSettings
{
    [JsonPropertyName("lensID")] public string LensId { get; set; } = "";
    public int Width { get; set; } = 1920;
    public int Height { get; set; } = 1080;
    public double Fps { get; set; } = 30;
    public VideoCodec Codec { get; set; } = VideoCodec.Hevc;
    public double BitrateMbps { get; set; } = 12;

    public ControlMode ExposureMode { get; set; } = ControlMode.Auto;
    public float Iso { get; set; } = 100;
    public double Shutter { get; set; } = 1.0 / 50.0;
    public float ExposureBias { get; set; }

    public ControlMode WhiteBalanceMode { get; set; } = ControlMode.Auto;
    public float Temperature { get; set; } = 5600;
    public float Tint { get; set; }

    public ControlMode FocusMode { get; set; } = ControlMode.Auto;
    public float LensPosition { get; set; } = 0.5f;

    public double Zoom { get; set; } = 1;
    public bool Stabilization { get; set; }
    public bool Hdr { get; set; }
    public bool AppleLog { get; set; }
    public float Torch { get; set; }

    public int Rotation { get; set; }
    public bool Mirror { get; set; }

    public GradeSettings Grade { get; set; } = new();
    public bool BackgroundBlur { get; set; }
    public float BackgroundBlurAmount { get; set; } = 0.6f;

    public CameraSettings Clone()
    {
        var c = (CameraSettings)MemberwiseClone();
        c.Grade = Grade.Clone();
        return c;
    }

    public bool SameAs(CameraSettings o) =>
        JsonSerializer.Serialize(this, Wire.Json) == JsonSerializer.Serialize(o, Wire.Json);
}

public sealed class FormatOption
{
    public int Width { get; set; }
    public int Height { get; set; }
    public double MaxFps { get; set; }
    public bool SupportsLog { get; set; }
    public bool SupportsHDR { get; set; }

    [JsonIgnore]
    public string Label => Height switch { 2160 => "4K", 1080 => "1080p", 720 => "720p", _ => $"{Width}×{Height}" };
}

public sealed class LensInfo
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public bool IsFront { get; set; }
    public List<FormatOption> Formats { get; set; } = new();
}

public sealed class CameraRanges
{
    public float IsoMin { get; set; } = 25;
    public float IsoMax { get; set; } = 3200;
    public double ShutterMin { get; set; } = 1.0 / 8000;
    public double ShutterMax { get; set; } = 0.5;
    public float BiasMin { get; set; } = -8;
    public float BiasMax { get; set; } = 8;
    public double ZoomMin { get; set; } = 1;
    public double ZoomMax { get; set; } = 10;
    public bool HasTorch { get; set; }
    public bool ManualFocus { get; set; } = true;
}

public sealed class CameraReadings
{
    public float Iso { get; set; }
    public double Shutter { get; set; }
    public float ExposureOffset { get; set; }
    public float Temperature { get; set; }
    public float Tint { get; set; }
    public float LensPosition { get; set; }
    public double Zoom { get; set; } = 1;
    public double Fps { get; set; }
    public double BitrateMbps { get; set; }
    public int DroppedFrames { get; set; }
    public int Thermal { get; set; }
    public float Battery { get; set; } = -1;
    public bool Charging { get; set; }
    public double ProcessingMs { get; set; }
}

public sealed class CameraStatus
{
    public string DeviceName { get; set; } = "";
    public List<LensInfo> Lenses { get; set; } = new();
    public CameraSettings Settings { get; set; } = new();
    public CameraRanges Ranges { get; set; } = new();
    public CameraReadings Readings { get; set; } = new();
    public string? LutName { get; set; }
    public string? Error { get; set; }
    public string? Diagnostics { get; set; }
    public string? Pipeline { get; set; }
}

/// Swift encodes enums with associated values as {"case":{...}}, with
/// unlabeled values under "_0". Built by hand to match exactly.
public static class Commands
{
    public static byte[] Apply(CameraSettings s) => Make("apply", new JsonObject
    {
        ["_0"] = JsonSerializer.SerializeToNode(s, Wire.Json),
    });

    public static byte[] FocusAt(double x, double y) => Make("focusAt", new JsonObject { ["x"] = x, ["y"] = y });
    public static byte[] ExposeAt(double x, double y) => Make("exposeAt", new JsonObject { ["x"] = x, ["y"] = y });
    public static byte[] LoadLut(string name, string cube) =>
        Make("loadLUT", new JsonObject { ["name"] = name, ["cube"] = cube });
    public static byte[] ClearLut() => Make("clearLUT", new JsonObject());
    public static byte[] RequestKeyframe() => Make("requestKeyframe", new JsonObject());

    private static byte[] Make(string name, JsonObject body)
    {
        var root = new JsonObject { [name] = body };
        return Wire.Encode(MessageType.Command, System.Text.Encoding.UTF8.GetBytes(root.ToJsonString()));
    }
}
