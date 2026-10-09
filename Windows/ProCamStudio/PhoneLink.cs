using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;
using Zeroconf;

namespace ProCam;

public sealed record Phone(string Name, string Host, int Port);

public enum LinkState { Idle, Connecting, Connected }

/// Finds iPhones running ProCam (mDNS) and holds the connection to one.
/// Port of Mac/PhoneLink.swift. Video frames are delivered on the receive
/// thread; everything UI-related is marshalled by the caller.
public sealed class PhoneLink : IDisposable
{
    public event Action<IReadOnlyList<Phone>>? PhonesChanged;
    public event Action<LinkState, string?>? StateChanged;
    public event Action<CameraStatus>? StatusReceived;
    public event Action<VideoFormat>? FormatReceived;
    public event Action<ReadOnlyMemory<byte>, ulong, bool>? FrameReceived;

    private readonly CancellationTokenSource _cts = new();
    private readonly object _gate = new();
    private TcpClient? _client;
    private NetworkStream? _stream;
    private Phone? _target;
    private bool _autoConnect = true;
    private DateTime _lastReceive = DateTime.UtcNow;
    private List<Phone> _phones = new();
    private LinkState _state = LinkState.Idle;
    private int _generation;

    public LinkState State => _state;

    public void Start()
    {
        _ = Task.Run(DiscoveryLoop);
        _ = Task.Run(WatchdogLoop);
    }

    // ─── Discovery ───────────────────────────────────────────────────────

    private async Task DiscoveryLoop()
    {
        while (!_cts.IsCancellationRequested)
        {
            try
            {
                var hosts = await ZeroconfResolver.ResolveAsync(Wire.BonjourType,
                    scanTime: TimeSpan.FromSeconds(2), cancellationToken: _cts.Token);
                var found = new List<Phone>();
                foreach (var h in hosts)
                {
                    // Prefer IPv4: link-local IPv6 needs a scope id that
                    // Zeroconf does not always report.
                    var ip = h.IPAddresses.FirstOrDefault(a => IPAddress.TryParse(a, out var p)
                                 && p.AddressFamily == AddressFamily.InterNetwork)
                             ?? h.IPAddress;
                    var svc = h.Services.Values.FirstOrDefault();
                    if (ip == null) continue;
                    found.Add(new Phone(h.DisplayName, ip, svc?.Port ?? Wire.DefaultPort));
                }
                found = found.OrderBy(p => p.Name).ToList();
                lock (_gate) _phones = found;
                PhonesChanged?.Invoke(found);
                MaybeAutoConnect();
            }
            catch (OperationCanceledException) { return; }
            catch
            {
                // mDNS can fail on networks that block multicast; manual IP
                // still works, so keep trying quietly.
            }
            try { await Task.Delay(3000, _cts.Token); } catch { return; }
        }
    }

    private void MaybeAutoConnect()
    {
        Phone? pick = null;
        lock (_gate)
        {
            if (!_autoConnect || _client != null) return;
            if (_target != null)
                pick = _phones.FirstOrDefault(p => p.Name == _target.Name) ?? _target;
            else
                pick = _phones.FirstOrDefault();
        }
        if (pick != null) Connect(pick);
    }

    // ─── Connection ──────────────────────────────────────────────────────

    public void Connect(Phone phone)
    {
        int gen;
        lock (_gate)
        {
            CloseLocked();
            _target = phone;
            _autoConnect = true;
            gen = ++_generation;
        }
        SetState(LinkState.Connecting, phone.Name);
        _ = Task.Run(() => RunConnection(phone, gen));
    }

    public void Connect(string host) => Connect(new Phone(host, host, Wire.DefaultPort));

    public void Disconnect()
    {
        lock (_gate)
        {
            _autoConnect = false;
            _target = null;
            _generation++;
            CloseLocked();
        }
        SetState(LinkState.Idle, null);
    }

    private async Task RunConnection(Phone phone, int gen)
    {
        var client = new TcpClient { NoDelay = true, ReceiveBufferSize = 1 << 20 };
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(4));
            await client.ConnectAsync(phone.Host, phone.Port, timeout.Token);
        }
        catch
        {
            client.Dispose();
            lock (_gate) if (gen == _generation) SetState(LinkState.Idle, null);
            return;
        }

        NetworkStream stream;
        lock (_gate)
        {
            if (gen != _generation) { client.Dispose(); return; }
            _client = client;
            _stream = stream = client.GetStream();
            _lastReceive = DateTime.UtcNow;
        }
        Send(Wire.EncodeJson(MessageType.Hello, new Hello { Name = Environment.MachineName }));

        var parser = new MessageParser();
        var buffer = new byte[1 << 20];
        try
        {
            while (true)
            {
                int n = await stream.ReadAsync(buffer, _cts.Token);
                if (n <= 0) break;
                _lastReceive = DateTime.UtcNow;
                foreach (var m in parser.Feed(buffer.AsSpan(0, n)))
                    Handle(m, phone);
            }
        }
        catch { }

        lock (_gate)
        {
            if (gen != _generation) return;
            CloseLocked();
        }
        SetState(LinkState.Idle, null);
    }

    private void Handle(WireMessage m, Phone phone)
    {
        switch (m.Type)
        {
            case MessageType.Hello:
                var h = Wire.Decode<Hello>(m.Payload);
                SetState(LinkState.Connected, h?.Name ?? phone.Name);
                break;
            case MessageType.Status:
                var s = Wire.Decode<CameraStatus>(m.Payload);
                if (s != null) StatusReceived?.Invoke(s);
                break;
            case MessageType.VideoFormat:
                var f = Wire.Decode<VideoFormat>(m.Payload);
                if (f != null) FormatReceived?.Invoke(f);
                break;
            case MessageType.VideoFrame:
                var v = VideoFramePayload.Decode(m.Payload);
                if (v is { } fr) FrameReceived?.Invoke(fr.sample, fr.ptsUs, fr.keyframe);
                break;
        }
    }

    private async Task WatchdogLoop()
    {
        while (!_cts.IsCancellationRequested)
        {
            try { await Task.Delay(1000, _cts.Token); } catch { return; }
            bool dead = false;
            lock (_gate)
            {
                if (_client != null)
                {
                    // The phone sends status 5×/s; silence means the link is dead.
                    if (DateTime.UtcNow - _lastReceive > TimeSpan.FromSeconds(4))
                    {
                        _generation++;
                        CloseLocked();
                        dead = true;
                    }
                }
            }
            if (dead) SetState(LinkState.Idle, null);
            else if (_state == LinkState.Connected) Send(Wire.Encode(MessageType.Ping, ReadOnlySpan<byte>.Empty));
            else MaybeAutoConnect();
        }
    }

    private void CloseLocked()
    {
        try { _stream?.Dispose(); } catch { }
        try { _client?.Dispose(); } catch { }
        _stream = null;
        _client = null;
    }

    private void SetState(LinkState s, string? name)
    {
        _state = s;
        StateChanged?.Invoke(s, name);
    }

    private readonly object _sendGate = new();

    public void Send(byte[] message)
    {
        NetworkStream? s;
        lock (_gate) s = _stream;
        if (s == null) return;
        try
        {
            lock (_sendGate) s.Write(message, 0, message.Length);
        }
        catch { }
    }

    public void Dispose()
    {
        _cts.Cancel();
        lock (_gate) CloseLocked();
    }
}
