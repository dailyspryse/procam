import AVFoundation
import UIKit

enum UIDeviceName {
    /// Since iOS 16 `UIDevice.name` is just "iPhone" without a special
    /// entitlement; the model name at least tells two phones apart.
    static var current: String {
        let name = UIDevice.current.name
        return name == "iPhone" ? "iPhone (\(UIDevice.current.systemVersion))" : name
    }
}

/// Wires camera → GPU grade → encoder → network and publishes state for the
/// on-phone status screen.
@MainActor
final class PhoneController: ObservableObject {

    @Published var clientName: String?
    @Published var cameraAllowed = true
    @Published var fps: Double = 0
    @Published var bitrateMbps: Double = 0
    @Published var formatLabel = ""
    @Published var thermal = ProcessInfo.ThermalState.nominal
    @Published var error: String?

    private let camera = CameraEngine()
    private let renderer = GradeRenderer()
    private let encoder = EncoderHost()
    private let server = StreamServer()

    private var lutName: String?
    private let counters = PipelineCounters()
    private lazy var diagnostics = camera.diagnostics()
    private var statusTimer: Timer?
    private var processingMs: Double = 0
    private let processingLock = NSLock()

    func start() {
        UIApplication.shared.isIdleTimerDisabled = true
        UIDevice.current.isBatteryMonitoringEnabled = true

        AVCaptureDevice.requestAccess(for: .video) { granted in
            Task { @MainActor in
                self.cameraAllowed = granted
                if granted { self.startPipeline() }
            }
        }
    }

    private func startPipeline() {
        let server = self.server
        let encoder = self.encoder
        let camera = self.camera
        let renderer = self.renderer

        encoder.onFrame = { [counters] in
            counters.bump(\.encoded)
            server.sendFrame($0)
        }
        encoder.onFormat = { server.sendFormat($0) }

        server.onNeedKeyframe = { encoder.requestKeyframe() }
        server.onCommand = { [weak self] cmd in
            Task { @MainActor in self?.handle(cmd) }
        }
        server.onClientChanged = { [weak self] name in
            Task { @MainActor in self?.clientName = name }
        }

        let counters = self.counters
        encoder.onEncodeError = { counters.bump(\.encodeErrors) }
        camera.onFrame = { [weak self] pb, pts in
            counters.bump(\.camera)
            defer { counters.stage("idle") }
            // No viewer, no work: the GPU and encoder stay idle and the phone cool.
            guard server.isConnected else { return }
            let s = camera.settings
            let t0 = CACurrentMediaTime()
            counters.stage("gpu")
            guard let graded = renderer?.process(pb, settings: s) else {
                counters.bump(\.renderFailed)
                return
            }
            counters.bump(\.rendered)
            let ms = (CACurrentMediaTime() - t0) * 1000
            self?.processingLock.withLock { self?.processingMs = ms }
            encoder.submit(graded, pts: pts, settings: s)
        }

        camera.start()
        server.start(name: UIDeviceName.current)

        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private var tickCount = 0
    private var statWindow: (frames: Int, bytes: Int, start: CFTimeInterval) = (0, 0, CACurrentMediaTime())

    private func tick() {
        tickCount += 1
        let stats = server.takeStats()
        statWindow.frames += stats.frames
        statWindow.bytes += stats.bytes
        let elapsed = CACurrentMediaTime() - statWindow.start
        if elapsed >= 1 {
            fps = Double(statWindow.frames) / elapsed
            bitrateMbps = Double(statWindow.bytes) * 8 / elapsed / 1_000_000
            statWindow = (0, 0, CACurrentMediaTime())
        }

        let s = camera.settings
        formatLabel = "\(s.height)p · \(Int(s.fps)) fps · \(s.codec == .hevc ? "HEVC" : "H.264")"
            + (s.appleLog ? " · Log" : "")
        thermal = ProcessInfo.processInfo.thermalState
        error = camera.lastError

        guard clientName != nil else { return }
        var r = camera.readings()
        r.fps = fps
        r.bitrateMbps = bitrateMbps
        r.droppedFrames = stats.dropped
        r.thermal = thermal.rawValue
        r.battery = UIDevice.current.batteryLevel
        r.charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        r.processingMs = processingLock.withLock { processingMs }

        server.sendStatus(CameraStatus(
            deviceName: UIDeviceName.current,
            lenses: camera.lenses,
            settings: s,
            ranges: camera.ranges,
            readings: r,
            lutName: lutName,
            error: camera.lastError,
            diagnostics: diagnostics,
            pipeline: counters.summary() + " " + encoder.debugState + " " + server.debugState()))
    }

    private func handle(_ cmd: Command) {
        switch cmd {
        case .apply(let s):
            camera.apply(s)
        case .focusAt(let x, let y):
            camera.focus(atX: x, y: y)
        case .exposeAt(let x, let y):
            camera.expose(atX: x, y: y)
        case .loadLUT(let name, let cube):
            do {
                let lut = try CubeLUT.parse(cube)
                renderer?.setLUT(lut)
                lutName = name
            } catch {
                self.error = "LUT: \(error.localizedDescription)"
            }
        case .clearLUT:
            renderer?.setLUT(nil)
            lutName = nil
        case .requestKeyframe:
            encoder.requestKeyframe()
        }
    }
}

/// Frame counts per pipeline stage, written from the video and encoder
/// threads and read by the status timer.
final class PipelineCounters {
    struct Values {
        var camera = 0, rendered = 0, renderFailed = 0, encoded = 0, encodeErrors = 0
    }
    private let lock = NSLock()
    private var v = Values()
    private var currentStage = "idle"
    private var stageSince = CACurrentMediaTime()

    func stage(_ name: String) {
        lock.withLock { currentStage = name; stageSince = CACurrentMediaTime() }
    }

    func bump(_ kp: WritableKeyPath<Values, Int>) {
        lock.withLock { v[keyPath: kp] += 1 }
    }

    func summary() -> String {
        let (c, st, since) = lock.withLock { (v, currentStage, stageSince) }
        let age = Int((CACurrentMediaTime() - since) * 1000)
        return "stage=\(st)(\(age)ms) cam=\(c.camera) gpu=\(c.rendered) gpuFail=\(c.renderFailed) enc=\(c.encoded) encErr=\(c.encodeErrors)"
    }
}
