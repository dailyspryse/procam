using System;
using System.Buffers.Binary;
using System.IO;
using FFmpeg.AutoGen;

namespace ProCam;

/// A decoded frame in BGRA, top-down. Buffers are recycled from a small ring,
/// so consumers must copy what they keep beyond the next few frames.
public sealed class DecodedFrame
{
    public byte[] Bgra = Array.Empty<byte>();
    public int Width;
    public int Height;
    public int Stride => Width * 4;
    public ulong PtsUs;
}

/// FFmpeg decoder for the phone's HEVC/H.264 stream. FFmpeg ships with the
/// app, so Windows' paid HEVC extension is not needed.
///
/// The phone sends AVCC (length-prefixed NAL units) plus parameter sets in a
/// VideoFormat message; FFmpeg's raw decoders take Annex-B, so every sample
/// is rewritten with start codes and keyframes get the parameter sets.
public sealed unsafe class VideoDecoder : IDisposable
{
    public event Action<DecodedFrame>? FrameDecoded;
    public event Action? NeedKeyframe;

    /// Called with each frame as BGR24 1920×1080 top-down, letterboxed —
    /// exactly what softcam wants. Only produced while set.
    public Action<byte[]>? VirtualCameraSink;

    private AVCodecContext* _ctx;
    private AVPacket* _pkt;
    private AVFrame* _frame;
    private SwsContext* _sws;
    private SwsContext* _swsVcam;
    private VideoFormat? _format;
    private byte[] _paramSetsAnnexB = Array.Empty<byte>();
    private bool _waitKey = true;

    private readonly DecodedFrame[] _ring = { new(), new(), new(), new() };
    private int _ringIndex;
    private readonly byte[] _vcam = new byte[VirtualCamera.Width * VirtualCamera.Height * 3];

    public static bool Initialized { get; private set; }

    public static void Initialize(string? libraryDir = null)
    {
        if (Initialized) return;
        ffmpeg.RootPath = libraryDir ?? Path.Combine(AppContext.BaseDirectory, "ffmpeg");
        DynamicallyLoadedBindings.Initialize();
        ffmpeg.av_log_set_level(ffmpeg.AV_LOG_ERROR);
        Initialized = true;
    }

    public static string Version => ffmpeg.av_version_info();

    public void SetFormat(VideoFormat f)
    {
        if (_format != null && _format.Codec == f.Codec && _format.Width == f.Width
            && _format.Height == f.Height && SameSets(_format, f))
            return;
        Close();
        _format = f;

        using var ms = new MemoryStream();
        foreach (var ps in f.ParameterSets)
        {
            ms.Write(StartCode);
            ms.Write(ps);
        }
        _paramSetsAnnexB = ms.ToArray();

        var id = f.Codec == VideoCodec.Hevc ? AVCodecID.AV_CODEC_ID_HEVC : AVCodecID.AV_CODEC_ID_H264;
        var codec = ffmpeg.avcodec_find_decoder(id);
        if (codec == null) throw new InvalidOperationException("Decoder fehlt in FFmpeg");
        _ctx = ffmpeg.avcodec_alloc_context3(codec);
        // Low delay: output each frame as soon as it is decoded. Slice
        // threads instead of frame threads, which would add a frame of
        // latency per thread.
        _ctx->flags |= ffmpeg.AV_CODEC_FLAG_LOW_DELAY;
        _ctx->thread_type = ffmpeg.FF_THREAD_SLICE;
        _ctx->thread_count = Math.Min(Environment.ProcessorCount, 8);
        int r = ffmpeg.avcodec_open2(_ctx, codec, null);
        if (r < 0) throw new InvalidOperationException($"Decoder konnte nicht geöffnet werden ({r})");
        _pkt = ffmpeg.av_packet_alloc();
        _frame = ffmpeg.av_frame_alloc();
        _waitKey = true;
    }

    private static readonly byte[] StartCode = { 0, 0, 0, 1 };

    private static bool SameSets(VideoFormat a, VideoFormat b)
    {
        if (a.ParameterSets.Count != b.ParameterSets.Count) return false;
        for (int i = 0; i < a.ParameterSets.Count; i++)
            if (!a.ParameterSets[i].AsSpan().SequenceEqual(b.ParameterSets[i])) return false;
        return true;
    }

    public void Decode(ReadOnlyMemory<byte> sample, ulong ptsUs, bool keyframe)
    {
        if (_ctx == null || _format == null) { NeedKeyframe?.Invoke(); return; }
        if (_waitKey)
        {
            if (!keyframe) return;
            _waitKey = false;
        }

        byte[] annexB = ToAnnexB(sample.Span, _format.NalLengthSize, keyframe ? _paramSetsAnnexB : null);
        if (ffmpeg.av_new_packet(_pkt, annexB.Length) < 0) return;
        fixed (byte* src = annexB)
            Buffer.MemoryCopy(src, _pkt->data, annexB.Length, annexB.Length);
        _pkt->pts = (long)ptsUs;

        int r = ffmpeg.avcodec_send_packet(_ctx, _pkt);
        ffmpeg.av_packet_unref(_pkt);
        if (r < 0) { Fail(); return; }

        while (true)
        {
            r = ffmpeg.avcodec_receive_frame(_ctx, _frame);
            if (r == ffmpeg.AVERROR(ffmpeg.EAGAIN) || r == ffmpeg.AVERROR_EOF) break;
            if (r < 0) { Fail(); break; }
            if ((_frame->decode_error_flags != 0) || (_frame->flags & ffmpeg.AV_FRAME_FLAG_CORRUPT) != 0)
            {
                ffmpeg.av_frame_unref(_frame);
                Fail();
                break;
            }
            Emit(ptsUs);
            ffmpeg.av_frame_unref(_frame);
        }
    }

    private void Fail()
    {
        _waitKey = true;
        NeedKeyframe?.Invoke();
    }

    public static byte[] ToAnnexB(ReadOnlySpan<byte> avcc, int nalLengthSize, byte[]? prefix)
    {
        var outBuf = new byte[avcc.Length + (prefix?.Length ?? 0) + 64];
        int o = 0;
        if (prefix != null) { prefix.CopyTo(outBuf, 0); o = prefix.Length; }
        int i = 0;
        while (i + nalLengthSize <= avcc.Length)
        {
            int len = 0;
            for (int k = 0; k < nalLengthSize; k++) len = (len << 8) | avcc[i + k];
            i += nalLengthSize;
            if (len <= 0 || i + len > avcc.Length) break;
            if (o + 4 + len > outBuf.Length) Array.Resize(ref outBuf, (o + 4 + len) * 2);
            outBuf[o++] = 0; outBuf[o++] = 0; outBuf[o++] = 0; outBuf[o++] = 1;
            avcc.Slice(i, len).CopyTo(outBuf.AsSpan(o));
            o += len;
            i += len;
        }
        Array.Resize(ref outBuf, o);
        return outBuf;
    }

    private void Emit(ulong ptsUs)
    {
        int w = _frame->width, h = _frame->height;
        var df = _ring[_ringIndex];
        _ringIndex = (_ringIndex + 1) % _ring.Length;
        if (df.Bgra.Length != w * h * 4) df.Bgra = new byte[w * h * 4];
        df.Width = w; df.Height = h; df.PtsUs = ptsUs;

        _sws = ffmpeg.sws_getCachedContext(_sws, w, h, (AVPixelFormat)_frame->format,
            w, h, AVPixelFormat.AV_PIX_FMT_BGRA, (int)SwsFlags.SWS_BILINEAR, null, null, null);
        SetColorspace(_sws);
        fixed (byte* dst = df.Bgra)
        {
            var dstData = new byte*[] { dst, null, null, null };
            var dstStride = new[] { w * 4, 0, 0, 0 };
            ffmpeg.sws_scale(_sws, _frame->data, _frame->linesize, 0, h, dstData, dstStride);
        }
        FrameDecoded?.Invoke(df);

        var sink = VirtualCameraSink;
        if (sink != null)
        {
            ScaleToVirtualCamera(w, h);
            sink(_vcam);
        }
    }

    /// The iPhone's encoder tags HD video as BT.709, limited range. swscale
    /// defaults to BT.601, which would shift every colour slightly.
    private void SetColorspace(SwsContext* sws)
    {
        int full = _frame->color_range == AVColorRange.AVCOL_RANGE_JPEG ? 1 : 0;
        var coeffs = *(int_array4*)ffmpeg.sws_getCoefficients(ffmpeg.SWS_CS_ITU709);
        ffmpeg.sws_setColorspaceDetails(sws, in coeffs, full, in coeffs, 1, 0, 1 << 16, 1 << 16);
    }

    private void ScaleToVirtualCamera(int w, int h)
    {
        int vw = VirtualCamera.Width, vh = VirtualCamera.Height;
        // Letterbox: fit inside 1920×1080, keep the aspect, centre, black bars.
        double s = Math.Min((double)vw / w, (double)vh / h);
        int tw = Math.Max(2, (int)(w * s) & ~1), th = Math.Max(2, (int)(h * s) & ~1);
        int ox = (vw - tw) / 2, oy = (vh - th) / 2;
        if (tw != vw || th != vh) Array.Clear(_vcam);

        _swsVcam = ffmpeg.sws_getCachedContext(_swsVcam, w, h, (AVPixelFormat)_frame->format,
            tw, th, AVPixelFormat.AV_PIX_FMT_BGR24, (int)SwsFlags.SWS_BILINEAR, null, null, null);
        SetColorspace(_swsVcam);
        fixed (byte* dst = _vcam)
        {
            var dstData = new byte*[] { dst + (oy * vw + ox) * 3, null, null, null };
            var dstStride = new[] { vw * 3, 0, 0, 0 };
            ffmpeg.sws_scale(_swsVcam, _frame->data, _frame->linesize, 0, h, dstData, dstStride);
        }
    }

    private void Close()
    {
        if (_ctx != null) { var c = _ctx; ffmpeg.avcodec_free_context(&c); _ctx = null; }
        if (_pkt != null) { var p = _pkt; ffmpeg.av_packet_free(&p); _pkt = null; }
        if (_frame != null) { var f = _frame; ffmpeg.av_frame_free(&f); _frame = null; }
        _format = null;
    }

    public void Dispose()
    {
        Close();
        if (_sws != null) { ffmpeg.sws_freeContext(_sws); _sws = null; }
        if (_swsVcam != null) { ffmpeg.sws_freeContext(_swsVcam); _swsVcam = null; }
    }
}
