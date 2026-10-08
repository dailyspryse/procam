import Foundation
import Network

/// Finds iPhones running ProCam and holds the connection to one of them.
///
/// Lives off the main actor: video frames arrive here at up to 60 per second
/// and go straight to the decoder. Only status and connection changes are
/// hopped to the UI.
final class PhoneLink {

    struct Phone: Hashable, Identifiable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { "\(endpoint)" }
    }

    enum State: Equatable {
        case idle
        case connecting(String)
        case connected(String)
    }

    var onPhones: (([Phone]) -> Void)?
    var onState: ((State) -> Void)?
    var onStatus: ((CameraStatus) -> Void)?
    var onFormat: ((VideoFormat) -> Void)?
    var onFrame: ((_ sample: Data, _ ptsUs: UInt64, _ keyframe: Bool) -> Void)?

    private let queue = DispatchQueue(label: "procam.link", qos: .userInteractive)
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var parser = MessageParser()
    private var target: Phone?
    private var lastReceive = Date()
    private var watchdog: DispatchSourceTimer?
    private var state: State = .idle {
        didSet { if state != oldValue { onState?(state) } }
    }

    /// When set, the link reconnects to whatever it last talked to and
    /// connects to the first phone it sees if it never had one.
    var autoConnect = true

    func start() {
        queue.async { [self] in
            let params = NWParameters()
            params.includePeerToPeer = true
            let b = NWBrowser(for: .bonjour(type: ProCamWire.bonjourType, domain: nil), using: params)
            b.browseResultsChangedHandler = { [weak self] results, _ in
                self?.handleResults(results)
            }
            b.stateUpdateHandler = { [weak self] st in
                if case .failed = st {
                    self?.queue.asyncAfter(deadline: .now() + 2) { self?.restartBrowser() }
                }
            }
            b.start(queue: queue)
            browser = b

            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.setEventHandler { [weak self] in self?.checkAlive() }
            t.resume()
            watchdog = t
        }
    }

    private func restartBrowser() {
        browser?.cancel()
        browser = nil
        watchdog?.cancel()
        watchdog = nil
        start()
    }

    private var phones: [Phone] = []

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        phones = results.compactMap { r in
            if case let .service(name, _, _, _) = r.endpoint {
                return Phone(name: name, endpoint: r.endpoint)
            }
            return nil
        }.sorted { $0.name < $1.name }
        onPhones?(phones)

        guard autoConnect, connection == nil else { return }
        if let t = target, let match = phones.first(where: { $0.name == t.name }) {
            open(match)
        } else if target == nil, let first = phones.first {
            open(first)
        }
    }

    func connect(_ phone: Phone) {
        queue.async { [self] in open(phone) }
    }

    func connect(host: String) {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host),
                                           port: NWEndpoint.Port(rawValue: ProCamWire.defaultPort)!)
        connect(Phone(name: host, endpoint: endpoint))
    }

    func disconnect() {
        queue.async { [self] in
            target = nil
            autoConnect = false
            close()
        }
    }

    private func open(_ phone: Phone) {
        close()
        target = phone
        autoConnect = true
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = true
        // Video arrives on this connection; mark it so the OS schedules it
        // like a call rather than a download.
        params.serviceClass = .interactiveVideo
        let c = NWConnection(to: phone.endpoint, using: params)
        connection = c
        parser = MessageParser()
        lastReceive = Date()
        state = .connecting(phone.name)

        c.stateUpdateHandler = { [weak self, weak c] st in
            guard let self, let c, self.connection === c else { return }
            switch st {
            case .ready:
                self.lastReceive = Date()
                let host = Host.current().localizedName ?? "Mac"
                self.send(.json(.hello, Hello(role: "studio", name: host)))
                self.receive(on: c)
            case .failed, .cancelled:
                self.close()
            case .waiting:
                // Unreachable (phone asleep, wrong network): give up quickly
                // and let the browser bring it back.
                self.close()
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    private func close() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        state = .idle
    }

    private func checkAlive() {
        guard connection != nil else {
            // Retry the last phone by name once it is visible again.
            if autoConnect, let t = target {
                if let match = phones.first(where: { $0.name == t.name }) {
                    open(match)
                } else if case .hostPort = t.endpoint {
                    open(t)
                }
            }
            return
        }
        // The phone sends status five times a second; silence means the link
        // is dead even if TCP has not noticed yet.
        if Date().timeIntervalSince(lastReceive) > 4 {
            close()
        } else if case .connected = state {
            send(WireMessage(type: .ping, payload: Data()))
        }
    }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 4 << 20) { [weak self] data, _, done, error in
            guard let self, self.connection === c else { return }
            if let data, !data.isEmpty {
                self.lastReceive = Date()
                do {
                    for m in try self.parser.feed(data) { self.handle(m) }
                } catch {
                    self.close()
                    return
                }
            }
            if done || error != nil {
                self.close()
                return
            }
            self.receive(on: c)
        }
    }

    private func handle(_ m: WireMessage) {
        switch m.type {
        case .hello:
            if let h = m.decode(Hello.self) { state = .connected(h.name) }
        case .status:
            if let s = m.decode(CameraStatus.self) { onStatus?(s) }
        case .videoFormat:
            if let f = m.decode(VideoFormat.self) { onFormat?(f) }
        case .videoFrame:
            if let f = VideoFramePayload.decode(m.payload) { onFrame?(f.sample, f.ptsUs, f.keyframe) }
        default:
            break
        }
    }

    private func send(_ m: WireMessage) {
        connection?.send(content: m.encoded(), completion: .contentProcessed { _ in })
    }

    func send(_ command: Command) {
        queue.async { [self] in send(.json(.command, command)) }
    }
}
