import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

struct Preset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var grade: GradeSettings
    /// Camera settings are optional: a "look" only touches the grade.
    var camera: CameraSettings?
}

enum VirtualCameraState: Equatable {
    case unknown, notInstalled, needsApproval, installing, ready, failed(String)
}

@MainActor
final class StudioModel: ObservableObject {

    // Connection
    @Published var phones: [PhoneLink.Phone] = []
    @Published var linkState: PhoneLink.State = .idle
    @Published var deviceName: String?

    // Camera
    @Published var settings = CameraSettings() {
        didSet { settingsChanged(oldValue) }
    }
    @Published var lenses: [LensInfo] = []
    @Published var ranges = CameraRanges()
    @Published var readings = CameraReadings()
    @Published var phoneLutName: String?
    @Published var phoneError: String?
    @Published var videoSize = CGSize(width: 1920, height: 1080)
    @Published var receivedFps: Double = 0

    // Studio-side
    @Published var overlays = OverlayOptions() {
        didSet { save(overlays, key: "overlays") }
    }
    @Published var scopes = ScopeData()
    @Published var presets: [Preset] = []
    @Published var vcam: VirtualCameraState = .unknown
    @Published var lutPath: String?
    @Published var lutError: String?

    let store = FrameStore()

    private let link = PhoneLink()
    private let decoder = VideoDecoder()
    private let sink = VirtualCameraSink()
    private let installer = ExtensionInstaller()
    private let scopeQueue = DispatchQueue(label: "procam.scopes", qos: .utility)

    private var applyingRemote = false
    private var lastLocalEdit = Date.distantPast
    private var sendWork: DispatchWorkItem?
    private var receivedInitialStatus = false
    private var timers: [Timer] = []

    // Touched only on the link queue.
    nonisolated(unsafe) private var frameCounter = 0
    nonisolated(unsafe) private var scopeBusy = false
    nonisolated(unsafe) private var fpsWindow: (count: Int, start: CFTimeInterval) = (0, CACurrentMediaTime())

    init() {
        if let saved: CameraSettings = load("settings") {
            applyingRemote = true
            settings = saved
            applyingRemote = false
        }
        if let o: OverlayOptions = load("overlays") { overlays = o }
        presets = load("presets") ?? Self.builtInLooks
        lutPath = UserDefaults.standard.string(forKey: "lutPath")
        wire()
    }

    // MARK: Wiring

    private func wire() {
        let decoder = self.decoder
        let sink = self.sink
        let store = self.store
        let link = self.link

        link.onPhones = { [weak self] phones in
            Task { @MainActor in self?.phones = phones }
        }
        link.onState = { [weak self] state in
            Task { @MainActor in self?.linkStateChanged(state) }
        }
        link.onStatus = { [weak self] status in
            Task { @MainActor in self?.handleStatus(status) }
        }
        link.onFormat = { [weak self] format in
            decoder.setFormat(format)
            Task { @MainActor in
                self?.videoSize = CGSize(width: format.width, height: format.height)
            }
        }
        link.onFrame = { sample, pts, key in
            decoder.decode(sample: sample, ptsUs: pts, keyframe: key)
        }
        decoder.onNeedKeyframe = { [weak self] in self?.throttledKeyframeRequest() }
        decoder.onFrame = { [weak self] pb, _ in
            store.put(pb)
            sink.send(pb)
            self?.frameArrived(pb)
        }

        installer.onOutcome = { [weak self] outcome in
            Task { @MainActor in
                switch outcome {
                case .installed: self?.vcam = .installing
                case .needsApproval: self?.vcam = .needsApproval
                case .failed(let msg): self?.vcam = .failed(msg)
                }
            }
        }

        link.start()

        // Look for the extension's device until it appears, then keep
        // checking in case it is removed or restarted.
        timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkVirtualCamera() }
        })
        checkVirtualCamera()
    }

    nonisolated private func frameArrived(_ pb: CVPixelBuffer) {
        frameCounter &+= 1
        fpsWindow.count += 1
        let now = CACurrentMediaTime()
        if now - fpsWindow.start >= 1 {
            let fps = Double(fpsWindow.count) / (now - fpsWindow.start)
            fpsWindow = (0, now)
            Task { @MainActor in self.receivedFps = fps }
        }
        // Scopes at ~10 Hz, and never two at once.
        guard frameCounter % 3 == 0, !scopeBusy else { return }
        scopeBusy = true
        scopeQueue.async { [weak self] in
            let data = ScopeAnalyzer.analyze(pb)
            Task { @MainActor in
                self?.scopes = data
            }
            self?.scopeBusy = false
        }
    }

    nonisolated(unsafe) private var lastKeyframeRequest: CFTimeInterval = 0

    nonisolated private func throttledKeyframeRequest() {
        let now = CACurrentMediaTime()
        guard now - lastKeyframeRequest > 0.5 else { return }
        lastKeyframeRequest = now
        link.send(.requestKeyframe)
    }

    private func linkStateChanged(_ state: PhoneLink.State) {
        linkState = state
        switch state {
        case .connected(let name):
            deviceName = name
            receivedInitialStatus = false
        case .idle:
            deviceName = nil
            receivedFps = 0
            store.clear()
        case .connecting:
            break
        }
    }

    private func handleStatus(_ s: CameraStatus) {
        lenses = s.lenses
        ranges = s.ranges
        readings = s.readings
        phoneLutName = s.lutName
        phoneError = s.error

        if !receivedInitialStatus {
            receivedInitialStatus = true
            // The Studio remembers the last setup and restores it, so the
            // camera always comes up the way it was left. A lens ID from
            // another phone is meaningless, so fall back to what the phone has.
            var restored = settings
            if !s.lenses.contains(where: { $0.id == restored.lensID }) {
                restored.lensID = s.settings.lensID
            }
            settings = restored
            link.send(.apply(settings))
            if s.lutName == nil, let path = lutPath { loadLUT(path: path) }
            return
        }

        // Adopt the phone's clamped values once the user has stopped
        // touching controls, so the UI never fights a slider being dragged.
        if s.settings != settings, Date().timeIntervalSince(lastLocalEdit) > 1.2 {
            applyingRemote = true
            settings = s.settings
            applyingRemote = false
        }
    }

    private func settingsChanged(_ old: CameraSettings) {
        guard !applyingRemote, settings != old else { return }
        lastLocalEdit = Date()
        // Coalesce slider drags to ~30 updates per second.
        sendWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.link.send(.apply(self.settings))
            self.save(self.settings, key: "settings")
        }
        sendWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: work)
    }

    // MARK: Actions

    func connect(_ phone: PhoneLink.Phone) { link.connect(phone) }
    func connect(host: String) { link.connect(host: host) }
    func disconnect() { link.disconnect() }

    /// Click in the preview: focus there; with ⌥ held, meter exposure there.
    func pointOfInterest(x: Double, y: Double, exposure: Bool) {
        link.send(exposure ? .exposeAt(x: x, y: y) : .focusAt(x: x, y: y))
    }

    /// Switching to manual seeds the sliders with what auto had chosen, so
    /// the picture does not jump.
    func setExposureMode(_ mode: ControlMode) {
        if mode == .manual, settings.exposureMode != .manual, readings.iso > 0 {
            settings.iso = readings.iso
            settings.shutter = readings.shutter
        }
        settings.exposureMode = mode
    }

    func setWhiteBalanceMode(_ mode: ControlMode) {
        if mode == .manual, settings.whiteBalanceMode != .manual, readings.temperature > 0 {
            settings.temperature = readings.temperature.rounded()
            settings.tint = readings.tint.rounded()
        }
        settings.whiteBalanceMode = mode
    }

    func setFocusMode(_ mode: ControlMode) {
        if mode == .manual, settings.focusMode != .manual {
            settings.lensPosition = readings.lensPosition
        }
        settings.focusMode = mode
    }

    func chooseLUT() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.allowsMultipleSelection = false
        panel.message = "3D-LUT im .cube-Format wählen"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadLUT(path: url.path)
    }

    func loadLUT(path: String) {
        do {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            _ = try CubeLUT.parse(text)   // validate here, with a readable error
            let name = (path as NSString).lastPathComponent
            link.send(.loadLUT(name: name, cube: text))
            lutPath = path
            lutError = nil
            UserDefaults.standard.set(path, forKey: "lutPath")
        } catch {
            lutError = error.localizedDescription
        }
    }

    func clearLUT() {
        link.send(.clearLUT)
        lutPath = nil
        UserDefaults.standard.removeObject(forKey: "lutPath")
    }

    // MARK: Presets

    func applyPreset(_ p: Preset) {
        if var cam = p.camera {
            // Keep the current lens if the preset came from another phone.
            if !lenses.contains(where: { $0.id == cam.lensID }) { cam.lensID = settings.lensID }
            cam.grade = p.grade
            settings = cam
        } else {
            settings.grade = p.grade
        }
    }

    func savePreset(name: String, includeCamera: Bool) {
        presets.append(Preset(name: name, grade: settings.grade, camera: includeCamera ? settings : nil))
        save(presets, key: "presets")
    }

    func deletePreset(_ p: Preset) {
        presets.removeAll { $0.id == p.id }
        save(presets, key: "presets")
    }

    func resetGrade() { settings.grade = .neutral }

    static var builtInLooks: [Preset] {
        var warm = GradeSettings.neutral
        warm.temperature = 0.35; warm.contrast = 1.08; warm.saturation = 1.05
        warm.blackPoint = 0.03; warm.highlights = -0.25
        warm.lift = RGB(r: 0.01, g: 0, b: -0.015)

        var cool = GradeSettings.neutral
        cool.temperature = -0.3; cool.contrast = 1.12; cool.saturation = 0.9
        cool.gain = RGB(r: 0.98, g: 1, b: 1.03)

        var punchy = GradeSettings.neutral
        punchy.contrast = 1.25; punchy.vibrance = 0.35; punchy.shadows = -0.15
        punchy.sharpen = 0.3

        var soft = GradeSettings.neutral
        soft.contrast = 0.9; soft.highlights = -0.3; soft.shadows = 0.3
        soft.exposure = 0.15; soft.vibrance = 0.1; soft.temperature = 0.1

        var bw = GradeSettings.neutral
        bw.saturation = 0; bw.contrast = 1.2; bw.vignette = 0.25

        var cinema = GradeSettings.neutral
        cinema.contrast = 1.1; cinema.saturation = 0.85; cinema.blackPoint = 0.04
        cinema.lift = RGB(r: -0.01, g: 0.005, b: 0.02)
        cinema.gain = RGB(r: 1.03, g: 1.0, b: 0.96)
        cinema.vignette = 0.3

        return [
            Preset(name: "Neutral", grade: .neutral),
            Preset(name: "Warm", grade: warm),
            Preset(name: "Kühl", grade: cool),
            Preset(name: "Knackig", grade: punchy),
            Preset(name: "Weich", grade: soft),
            Preset(name: "Kino", grade: cinema),
            Preset(name: "Schwarzweiß", grade: bw),
        ]
    }

    // MARK: Virtual camera

    func installVirtualCamera() {
        vcam = .installing
        installer.activate()
    }

    func uninstallVirtualCamera() {
        sink.disconnect()
        installer.deactivate()
        vcam = .notInstalled
    }

    private func checkVirtualCamera() {
        if sink.connectIfNeeded() {
            vcam = .ready
        } else if vcam == .ready || vcam == .unknown {
            vcam = .notInstalled
        }
    }

    var isInApplicationsFolder: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    // MARK: Persistence

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
