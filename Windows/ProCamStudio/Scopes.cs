using System;
using System.Threading.Tasks;

namespace ProCam;

public sealed class ScopeData
{
    public const int Bins = 64;
    public const int WaveColumns = 320;
    public const int WaveRows = 128;

    public float[] Red = new float[Bins], Green = new float[Bins], Blue = new float[Bins], Luma = new float[Bins];
    /// BGRA pixels, WaveColumns × WaveRows.
    public byte[] Waveform = new byte[WaveColumns * WaveRows * 4];
    public float Clipped, Crushed;
}

/// Port of Mac/Scopes.swift: histogram and luma waveform from a subsample.
public static class ScopeAnalyzer
{
    public static ScopeData Analyze(DecodedFrame f)
    {
        int w = f.Width, h = f.Height;
        var px = f.Bgra;
        int step = Math.Max(1, (int)Math.Sqrt(w * h / 150_000.0));
        var r = new int[ScopeData.Bins]; var g = new int[ScopeData.Bins];
        var b = new int[ScopeData.Bins]; var l = new int[ScopeData.Bins];
        var wave = new int[ScopeData.WaveColumns * ScopeData.WaveRows];
        int clipped = 0, crushed = 0, total = 0;

        for (int y = 0; y < h; y += step)
        {
            int row = y * w * 4;
            for (int x = 0; x < w; x += step)
            {
                int o = row + x * 4;
                int bv = px[o], gv = px[o + 1], rv = px[o + 2];
                int lv = (rv * 54 + gv * 183 + bv * 19) >> 8;
                r[rv >> 2]++; g[gv >> 2]++; b[bv >> 2]++; l[lv >> 2]++;
                if (lv >= 250) clipped++;
                if (lv <= 4) crushed++;
                total++;
                int col = x * ScopeData.WaveColumns / w;
                int wrow = (ScopeData.WaveRows - 1) - lv * (ScopeData.WaveRows - 1) / 255;
                wave[wrow * ScopeData.WaveColumns + col]++;
            }
        }

        // Ignore the extreme bins when normalising (black borders, blown windows).
        int peak = 1;
        foreach (var a in new[] { r, g, b, l })
            for (int i = 1; i < ScopeData.Bins - 1; i++) peak = Math.Max(peak, a[i]);

        var d = new ScopeData();
        for (int i = 0; i < ScopeData.Bins; i++)
        {
            d.Red[i] = Math.Min(1f, r[i] / (float)peak);
            d.Green[i] = Math.Min(1f, g[i] / (float)peak);
            d.Blue[i] = Math.Min(1f, b[i] / (float)peak);
            d.Luma[i] = Math.Min(1f, l[i] / (float)peak);
        }
        float perColumn = Math.Max(1, total / ScopeData.WaveColumns);
        float scale = 255f / MathF.Log(perColumn / 4 + 1);
        for (int i = 0; i < wave.Length; i++)
        {
            int o = i * 4;
            d.Waveform[o + 3] = 255;
            if (wave[i] == 0) continue;
            byte v = (byte)Math.Min(255, MathF.Log(wave[i] + 1) * scale * 1.6f);
            d.Waveform[o] = (byte)(v * 8 / 10);   // B
            d.Waveform[o + 1] = v;                // G
            d.Waveform[o + 2] = (byte)(v * 7 / 10); // R
        }
        d.Clipped = clipped / (float)Math.Max(total, 1);
        d.Crushed = crushed / (float)Math.Max(total, 1);
        return d;
    }
}

public sealed class OverlayOptions
{
    public bool Zebra { get; set; }
    public float ZebraLevel { get; set; } = 0.95f;
    public bool Peaking { get; set; }
    public float PeakThreshold { get; set; } = 0.12f;
    public bool FalseColor { get; set; }
    public bool Grid { get; set; }
    public bool SafeArea { get; set; }

    public bool AnyPixelOverlay => Zebra || Peaking || FalseColor;
}

/// Monitoring overlays, applied to the preview copy only — never to the
/// webcam. Same bands and thresholds as Mac/Preview.metal.
public static class Overlays
{
    public static void Apply(byte[] src, byte[] dst, int w, int h, OverlayOptions o, double time)
    {
        int zebraLevel = (int)(o.ZebraLevel * 255);
        int peak = (int)(o.PeakThreshold * 255 * 2);
        int phase = (int)(time * 40);

        Parallel.For(0, h, y =>
        {
            int row = y * w * 4;
            for (int x = 0; x < w; x++)
            {
                int i = row + x * 4;
                int bv = src[i], gv = src[i + 1], rv = src[i + 2];
                int l = (rv * 54 + gv * 183 + bv * 19) >> 8;
                int ob = bv, og = gv, or = rv;

                if (o.FalseColor) FalseColor(l, out ob, out og, out or);

                if (o.Peaking && x > 0 && x < w - 1 && y > 0 && y < h - 1)
                {
                    int dx = Luma(src, i + 4) - Luma(src, i - 4);
                    int dy = Luma(src, i + w * 4) - Luma(src, i - w * 4);
                    if (dx * dx + dy * dy > peak * peak)
                    {
                        ob = 64; og = 38; or = 255;
                    }
                }

                if (o.Zebra && l >= zebraLevel)
                {
                    bool stripe = ((x + y + phase) / 7 & 1) == 0;
                    ob = og = or = stripe ? 0 : 255;
                }

                dst[i] = (byte)ob; dst[i + 1] = (byte)og; dst[i + 2] = (byte)or; dst[i + 3] = 255;
            }
        });
    }

    private static int Luma(byte[] p, int i) => (p[i + 2] * 54 + p[i + 1] * 183 + p[i] * 19) >> 8;

    private static void FalseColor(int l, out int b, out int g, out int r)
    {
        float v = l / 255f;
        (r, g, b) = v switch
        {
            < 0.025f => (115, 26, 166),
            < 0.10f => (26, 77, 230),
            > 0.38f and < 0.44f => (64, 191, 77),
            > 0.52f and < 0.60f => (242, 140, 179),
            > 0.97f => (242, 38, 38),
            > 0.90f => (250, 217, 51),
            _ => ((int)(l * 0.85f), (int)(l * 0.85f), (int)(l * 0.85f)),
        };
    }
}
