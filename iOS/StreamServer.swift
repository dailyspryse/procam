import Foundation
import Network

/// Advertises the phone over Bonjour and serves one Studio at a time.
///
/// Backpressure is the important part. TCP never drops, so if Wi-Fi stalls,
/// frames would queue up in the socket and the picture would fall seconds
/// behind. Instead we count frames handed to the connection but not yet
/// accepted by the kernel; above a small limit we drop frames and wait for a
/// keyframe, which is the only frame the decoder can restart from cleanly.
final class StreamServer {

    var onCommand: ((Command) -> Void)?
    var onClientChanged: ((String?) -> Void)?
    var onNeedKeyframe: (() -> Void)?

    private let queue = DispatchQueue(label: "procam.net", qos: .userInteractive)
    private var listener: NWListener?
    private var connection: NWConnection?
    private var parser = MessageParser()
    private var clientName: String?

    private var inFlight = 0
    private var waitingForKeyframe = true
    private var lastFormat: VideoFormat?
    private static let maxInFlight = 3

    // Stats, read from the status timer.
    private let statsLock = NSLock()
    private var sentFrames = 0
    private var sentBytes = 0
    private(set) var droppedFrames = 0

    /// Read from the video queue to skip all frame work while nobody watches.
    var isConnected: Bool { statsLock.withLock { connected } }
    private var connected = false

    private func setConnected(_ value: Bool) {
        statsLock.withLock { connected = value }
    }

    func start(name: String) {
        queue.async { [self] in
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let params = NWParameters(tls: nil, tcp: tcp)
            params.includePeerToPeer = true
            do {
                // Fixed port so the Studio can also connect by IP when
                // Bonjour is blocked (guest networks, some mesh routers).
                let l: NWListener
                if let fixed = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: ProCamWire.defaultPort)!) {
                    l = fixed
                } else {
                    l = try NWListener(using: params)
                }
                l.service = NWListener.Service(name: name, type: ProCamWire.bonjourType)
                l.newConnectionHandler = { [weak self] c in self?.accept(c) }
                l.stateUpdateHandler = { [weak self] state in
                    if case .failed = state {
                        // Restart after network changes (Wi-Fi off/on).
                        self?.queue.asyncAfter(deadline: .now() + 1) { self?.restart(name: name) }
                    }
                }
                l.start(queue: queue)
                listener = l
            } catch {
                queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.restart(name: name) }
            }
        }
    }

    private func restart(name: String) {
        listener?.cancel()
        listener = nil
        start(name: name)
    }

    private func accept(_ c: NWConnection) {
        // The newest Studio wins; a stale connection from a sleeping Mac
        // should never block a fresh one.
        drop()
        connection = c
        parser = MessageParser()
        inFlight = 0
        waitingForKeyframe = true
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c else { return }
            switch state {
            case .ready:
                self.send(.json(.hello, Hello(role: "iphone", name: UIDeviceName.current)), on: c)
                if let f = self.lastFormat { self.send(.json(.videoFormat, f), on: c) }
                self.onNeedKeyframe?()
                self.receive(on: c)
            case .failed, .cancelled:
                if self.connection === c { self.drop() }
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    private func drop() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        if clientName != nil {
            clientName = nil
            setConnected(false)
            onClientChanged?(nil)
        }
    }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self, self.connection === c else { return }
            if let data, !data.isEmpty {
                do {
                    for m in try self.parser.feed(data) { self.handle(m, on: c) }
                } catch {
                    self.drop()
                    return
                }
            }
            if done || error != nil {
                self.drop()
                return
            }
            self.receive(on: c)
        }
    }

    private func handle(_ m: WireMessage, on c: NWConnection) {
        switch m.type {
        case .hello:
            if let h = m.decode(Hello.self) {
                clientName = h.name
                setConnected(true)
                onClientChanged?(h.name)
            }
        case .command:
            if let cmd = m.decode(Command.self) { onCommand?(cmd) }
        case .ping:
            send(WireMessage(type: .pong, payload: m.payload), on: c)
        default:
            break
        }
    }

    private func send(_ m: WireMessage, on c: NWConnection, completion: (() -> Void)? = nil) {
        c.send(content: m.encoded(), completion: .contentProcessed { _ in completion?() })
    }

    // MARK: Outgoing

    func sendFormat(_ f: VideoFormat) {
        queue.async { [self] in
            lastFormat = f
            if let c = connection { send(.json(.videoFormat, f), on: c) }
        }
    }

    func sendStatus(_ s: CameraStatus) {
        queue.async { [self] in
            if let c = connection, clientName != nil { send(.json(.status, s), on: c) }
        }
    }

    func sendFrame(_ f: VideoEncoder.Frame) {
        queue.async { [self] in
            guard let c = connection, clientName != nil else { return }
            if waitingForKeyframe && !f.keyframe { return }
            if inFlight >= Self.maxInFlight {
                waitingForKeyframe = true
                statsLock.withLock { droppedFrames += 1 }
                onNeedKeyframe?()
                return
            }
            waitingForKeyframe = false
            inFlight += 1
            totalSent += 1
            let payload = VideoFramePayload.encode(ptsUs: f.ptsUs, keyframe: f.keyframe, sample: f.sample)
            send(WireMessage(type: .videoFrame, payload: payload), on: c) { [weak self] in
                self?.queue.async { self?.inFlight -= 1 }
            }
            statsLock.withLock {
                sentFrames += 1
                sentBytes += payload.count
            }
        }
    }

    private var totalSent = 0

    func debugState() -> String {
        queue.sync { "sent=\(totalSent) inFlight=\(inFlight) waitKey=\(waitingForKeyframe) drop=\(droppedFrames)" }
    }

    /// Returns frames and bytes sent since the last call.
    func takeStats() -> (frames: Int, bytes: Int, dropped: Int) {
        statsLock.withLock {
            defer { sentFrames = 0; sentBytes = 0 }
            return (sentFrames, sentBytes, droppedFrames)
        }
    }
}
