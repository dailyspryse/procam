import AVFoundation
import UIKit

/// Owns the capture session and translates `CameraSettings` into device state.
///
/// All device mutation happens on `sessionQueue`. Frames arrive on
/// `videoQueue` and are handed to `onFrame` without copying.
final class CameraEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    let session = AVCaptureSession()
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    private let sessionQueue = DispatchQueue(label: "procam.session")
    let videoQueue = DispatchQueue(label: "procam.video", qos: .userInteractive)

    private var device: AVCaptureDevice?
    private var input: AVCaptureDeviceInput?
    private let output = AVCaptureVideoDataOutput()

    private let lock = NSLock()
    private var _settings = CameraSettings()
    private var _ranges = CameraRanges()
    private var _error: String?

    private(set) lazy var lenses: [LensInfo] = Self.discoverLenses()
    private var devicesByID: [String: AVCaptureDevice] = [:]

    var settings: CameraSettings { lock.withLock { _settings } }
    var ranges: CameraRanges { lock.withLock { _ranges } }
    var lastError: String? { lock.withLock { _error } }

    // MARK: Lifecycle

    func start() {
        sessionQueue.async { [self] in
            for lens in lenses {
                devicesByID[lens.id] = AVCaptureDevice(uniqueID: lens.id)
            }
            var initial = CameraSettings()
            initial.lensID = lenses.first(where: { $0.name.hasPrefix("Weitwinkel") })?.id
                ?? lenses.first?.id ?? ""
            session.beginConfiguration()
            // Wide colour would let the session pick P3 on its own; Apple Log
            // needs the colour space under our control instead.
            session.automaticallyConfiguresCaptureDeviceForWideColor = false
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()

            configure(initial, force: true)
            session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async { [self] in session.stopRunning() }
    }

    func apply(_ new: CameraSettings) {
        sessionQueue.async { [self] in configure(new, force: false) }
    }

    // MARK: Configuration

    private func configure(_ requested: CameraSettings, force: Bool) {
        var new = requested
        let old = settings

        guard let lens = lenses.first(where: { $0.id == new.lensID }) ?? lenses.first,
              let dev = devicesByID[lens.id] else {
            setError("Keine Kamera gefunden")
            return
        }
        new.lensID = lens.id

        // Clamp the format to something this lens can deliver.
        let fmtOption = bestFormatOption(lens: lens, width: new.width, height: new.height)
        new.width = fmtOption.width
        new.height = fmtOption.height
        new.fps = min(new.fps, fmtOption.maxFps)
        if !fmtOption.supportsLog { new.appleLog = false }
        if !fmtOption.supportsHDR || new.appleLog { new.hdr = false }

        let needsRebuild = force
            || old.lensID != new.lensID
            || old.width != new.width || old.height != new.height
            || old.fps != new.fps
            || old.appleLog != new.appleLog
            || old.hdr != new.hdr

        let geometryChanged = old.rotation != new.rotation || old.mirror != new.mirror
            || old.stabilization != new.stabilization

        // Session reconfiguration is expensive and can stall frames, so it
        // only happens for changes that need it. Slider drags (ISO, focus,
        // zoom …) go straight to the device below.
        if needsRebuild || geometryChanged {
            session.beginConfiguration()
            let ok = needsRebuild ? rebuild(dev, &new) : true
            if ok { configureConnection(new) }
            session.commitConfiguration()
            guard ok else { return }
        }

        applyDeviceControls(dev, &new)

        lock.withLock {
            _settings = new
            _ranges = Self.ranges(for: dev)
            _error = nil
        }
    }

    /// Runs one AVFoundation mutation. AVFoundation raises an NSException for
    /// a value it rejects, which would otherwise kill the app.
    @discardableResult
    private func safely(_ what: String, _ block: () -> Void) -> Bool {
        if let reason = ObjCTry.run(block) {
            setError("\(what) abgelehnt: \(reason)")
            return false
        }
        return true
    }

    private func rebuild(_ dev: AVCaptureDevice, _ new: inout CameraSettings) -> Bool {
        if input?.device != dev {
            if let input { session.removeInput(input) }
            do {
                let newInput = try AVCaptureDeviceInput(device: dev)
                guard session.canAddInput(newInput) else {
                    setError("Kamera kann nicht verwendet werden")
                    // Put the previous camera back rather than leave none.
                    if let input, session.canAddInput(input) { session.addInput(input) }
                    return false
                }
                session.addInput(newInput)
                input = newInput
                device = dev
            } catch {
                setError("Kamera-Fehler: \(error.localizedDescription)")
                if let input, session.canAddInput(input) { session.addInput(input) }
                return false
            }
        }
        // Not every lens offers every rate (25 fps is often missing); fall
        // back to 30 instead of leaving the camera without a format.
        var format = findFormat(dev, new)
        if format == nil, new.fps != 30 {
            var fallback = new
            fallback.fps = 30
            if let f = findFormat(dev, fallback) {
                format = f
                new.fps = 30
            }
        }
        guard let format else {
            setError("Kein passendes Format für \(new.width)×\(new.height) @ \(Int(new.fps))")
            return false
        }
        guard (try? dev.lockForConfiguration()) != nil else {
            setError("Kamera ist belegt")
            return false
        }
        let fps = new.fps
        let log = new.appleLog
        let hdr = new.hdr
        let ok = safely("Format") {
            dev.activeFormat = format
            let duration = CMTime(value: 1000, timescale: CMTimeScale(fps * 1000))
            dev.activeVideoMinFrameDuration = duration
            dev.activeVideoMaxFrameDuration = duration
            if log {
                dev.activeColorSpace = .appleLog
            } else if format.supportedColorSpaces.contains(.sRGB) {
                dev.activeColorSpace = .sRGB
            }
            if format.isVideoHDRSupported {
                dev.automaticallyAdjustsVideoHDREnabled = false
                dev.isVideoHDREnabled = hdr
            }
        }
        dev.unlockForConfiguration()
        guard ok else { return false }

        let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        return safely("Ausgabeformat") {
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: subtype,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
        }
    }

    private func configureConnection(_ new: CameraSettings) {
        guard let conn = output.connection(with: .video) else { return }
        safely("Bildausrichtung") {
            if conn.isVideoRotationAngleSupported(CGFloat(new.rotation)) {
                conn.videoRotationAngle = CGFloat(new.rotation)
            }
            if conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = new.mirror
            }
            if conn.isVideoStabilizationSupported {
                // Standard only: cinematic stabilisation buffers ~0.5 s of
                // frames to look ahead, which is fatal for a webcam.
                conn.preferredVideoStabilizationMode = new.stabilization ? .standard : .off
            }
        }
    }

    private func applyDeviceControls(_ dev: AVCaptureDevice, _ s: inout CameraSettings) {
        do { try dev.lockForConfiguration() } catch { return }
        defer { dev.unlockForConfiguration() }
        let fmt = dev.activeFormat

        // Exposure
        switch s.exposureMode {
        case .auto:
            if dev.isExposureModeSupported(.continuousAutoExposure) {
                safely("Belichtung") { dev.exposureMode = .continuousAutoExposure }
            }
        case .locked:
            if dev.isExposureModeSupported(.locked) {
                safely("Belichtung") { dev.exposureMode = .locked }
            }
        case .manual:
            if dev.isExposureModeSupported(.custom) {
                s.iso = s.iso.clamped(fmt.minISO, fmt.maxISO)
                // The shutter can never be longer than one frame.
                let maxShutter = min(fmt.maxExposureDuration.seconds, 1.0 / s.fps)
                s.shutter = s.shutter.clamped(fmt.minExposureDuration.seconds, maxShutter)
                // Round down to whole microseconds so rounding can never push
                // the duration past the format's limits.
                var duration = CMTime(value: CMTimeValue(s.shutter * 1_000_000), timescale: 1_000_000)
                duration = CMTimeClampToRange(duration, range: CMTimeRange(
                    start: fmt.minExposureDuration,
                    end: min(fmt.maxExposureDuration, CMTime(seconds: maxShutter, preferredTimescale: 1_000_000))))
                let iso = s.iso
                safely("Manuelle Belichtung") { dev.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil) }
            }
        }
        s.exposureBias = s.exposureBias.clamped(dev.minExposureTargetBias, dev.maxExposureTargetBias)
        if s.exposureMode != .manual {
            let bias = s.exposureBias
            safely("Belichtungskorrektur") { dev.setExposureTargetBias(bias, completionHandler: nil) }
        }

        // White balance
        switch s.whiteBalanceMode {
        case .auto:
            if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                safely("Weißabgleich") { dev.whiteBalanceMode = .continuousAutoWhiteBalance }
            }
        case .locked:
            if dev.isWhiteBalanceModeSupported(.locked) {
                safely("Weißabgleich") { dev.whiteBalanceMode = .locked }
            }
        case .manual:
            if dev.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                s.temperature = s.temperature.clamped(2000, 10000)
                s.tint = s.tint.clamped(-150, 150)
                let tt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                    temperature: s.temperature, tint: s.tint)
                safely("Weißabgleich") {
                    let gains = Self.clampedGains(dev.deviceWhiteBalanceGains(for: tt), dev)
                    dev.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                }
            }
        }

        // Focus
        switch s.focusMode {
        case .auto:
            if dev.isFocusModeSupported(.continuousAutoFocus) {
                safely("Fokus") { dev.focusMode = .continuousAutoFocus }
            }
        case .locked:
            if dev.isFocusModeSupported(.locked) {
                safely("Fokus") { dev.focusMode = .locked }
            }
        case .manual:
            if dev.isLockingFocusWithCustomLensPositionSupported {
                s.lensPosition = s.lensPosition.clamped(0, 1)
                let pos = s.lensPosition
                safely("Manueller Fokus") { dev.setFocusModeLocked(lensPosition: pos, completionHandler: nil) }
            } else {
                s.focusMode = .auto
            }
        }

        // Zoom
        s.zoom = s.zoom.clamped(Double(dev.minAvailableVideoZoomFactor),
                                min(Double(dev.maxAvailableVideoZoomFactor), 30))
        if abs(Double(dev.videoZoomFactor) - s.zoom) > 0.001 {
            let z = CGFloat(s.zoom)
            safely("Zoom") { dev.videoZoomFactor = z }
        }

        // Torch. The available level drops to 0 when the phone is hot;
        // asking for "on" then raises.
        if dev.hasTorch, dev.isTorchAvailable {
            let level = min(s.torch, AVCaptureDevice.maxAvailableTorchLevel)
            if level > 0.01 {
                safely("Licht") { try? dev.setTorchModeOn(level: level) }
            } else if dev.torchMode != .off {
                safely("Licht") { dev.torchMode = .off }
            }
        } else {
            s.torch = 0
        }
    }

    private static func clampedGains(_ g: AVCaptureDevice.WhiteBalanceGains,
                                     _ dev: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceGains {
        let maxGain = dev.maxWhiteBalanceGain
        return AVCaptureDevice.WhiteBalanceGains(
            redGain: g.redGain.clamped(1, maxGain),
            greenGain: g.greenGain.clamped(1, maxGain),
            blueGain: g.blueGain.clamped(1, maxGain))
    }

    // MARK: Points of interest

    /// Maps a point in the delivered (rotated, maybe mirrored) image back to
    /// the sensor-landscape space that points of interest are expressed in.
    private func devicePoint(x: Double, y: Double) -> CGPoint {
        let s = settings
        let x = x.clamped(0, 1), y = y.clamped(0, 1)
        let ux = s.mirror ? 1 - x : x
        switch s.rotation {
        case 90: return CGPoint(x: y, y: 1 - ux)
        case 180: return CGPoint(x: 1 - ux, y: 1 - y)
        case 270: return CGPoint(x: 1 - y, y: ux)
        default: return CGPoint(x: ux, y: y)
        }
    }

    func focus(atX x: Double, y: Double) {
        sessionQueue.async { [self] in
            guard let dev = device, dev.isFocusPointOfInterestSupported,
                  (try? dev.lockForConfiguration()) != nil else { return }
            defer { dev.unlockForConfiguration() }
            let point = devicePoint(x: x, y: y)
            // Tap-to-focus keeps tracking afterwards in auto mode, and does a
            // one-shot otherwise so a locked focus stays locked.
            let mode: AVCaptureDevice.FocusMode = settings.focusMode == .auto ? .continuousAutoFocus : .autoFocus
            guard dev.isFocusModeSupported(mode) else { return }
            safely("Fokuspunkt") {
                dev.focusPointOfInterest = point
                dev.focusMode = mode
            }
        }
    }

    func expose(atX x: Double, y: Double) {
        sessionQueue.async { [self] in
            guard let dev = device, dev.isExposurePointOfInterestSupported,
                  settings.exposureMode != .manual,
                  (try? dev.lockForConfiguration()) != nil else { return }
            defer { dev.unlockForConfiguration() }
            let point = devicePoint(x: x, y: y)
            let mode: AVCaptureDevice.ExposureMode = settings.exposureMode == .auto ? .continuousAutoExposure : .autoExpose
            guard dev.isExposureModeSupported(mode) else { return }
            safely("Belichtungspunkt") {
                dev.exposurePointOfInterest = point
                dev.exposureMode = mode
            }
        }
    }

    // MARK: Readings

    private var _readings = CameraReadings()

    /// Last readings. They are sampled on the session queue, where the
    /// device is never mid-reconfiguration; reading a device from another
    /// thread while its format or lens changes is what crashed before.
    func readings() -> CameraReadings {
        sessionQueue.async { [self] in
            guard let dev = device else { return }
            var r = CameraReadings()
            r.iso = dev.iso
            r.shutter = dev.exposureDuration.seconds
            r.exposureOffset = dev.exposureTargetOffset
            r.lensPosition = dev.lensPosition
            r.zoom = Double(dev.videoZoomFactor)
            ObjCTry.run {
                let tt = dev.temperatureAndTintValues(for: Self.clampedGains(dev.deviceWhiteBalanceGains, dev))
                r.temperature = tt.temperature
                r.tint = tt.tint
            }
            lock.withLock { _readings = r }
        }
        return lock.withLock { _readings }
    }

    /// One line per lens: which pixel formats and colour spaces it offers.
    func diagnostics() -> String {
        lenses.map { lens in
            guard let dev = AVCaptureDevice(uniqueID: lens.id) else { return lens.name }
            var seen = Set<String>()
            for f in dev.formats {
                let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
                let fourcc = String(bytes: [24, 16, 8, 0].map { UInt8((sub >> $0) & 0xff) }, encoding: .ascii) ?? "?"
                let cs = f.supportedColorSpaces.map { "\($0.rawValue)" }.joined(separator: ",")
                seen.insert("\(d.height)p \(fourcc) cs[\(cs)]")
            }
            return lens.name + ": " + seen.sorted().joined(separator: " ; ")
        }.joined(separator: "\n")
    }

    // MARK: Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pb, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    // MARK: Helpers

    private func setError(_ msg: String) {
        lock.withLock { _error = msg }
    }

    private func bestFormatOption(lens: LensInfo, width: Int, height: Int) -> FormatOption {
        if let exact = lens.formats.first(where: { $0.width == width && $0.height == height }) {
            return exact
        }
        return lens.formats.first(where: { $0.height == 1080 }) ?? lens.formats.first
            ?? FormatOption(width: 1920, height: 1080, maxFps: 30, supportsLog: false, supportsHDR: false)
    }

    private static let acceptedSubtypes: Set<FourCharCode> = [
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
        // Apple Log is only offered as 10-bit 4:2:2 ('x422') on iPhone 15 Pro.
        kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
    ]

    static func isTenBit(_ sub: FourCharCode) -> Bool {
        sub == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || sub == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            || sub == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
            || sub == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
    }

    private func findFormat(_ dev: AVCaptureDevice, _ s: CameraSettings) -> AVCaptureDevice.Format? {
        let candidates = dev.formats.filter { f in
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            guard Int(dims.width) == s.width, Int(dims.height) == s.height,
                  Self.acceptedSubtypes.contains(sub),
                  f.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= s.fps + 0.01 && $0.maxFrameRate >= s.fps - 0.01 })
            else { return false }
            if s.appleLog && !f.supportedColorSpaces.contains(.appleLog) { return false }
            if s.hdr && !f.isVideoHDRSupported { return false }
            return true
        }
        // Prefer 10-bit for Log (the curve needs the code values), 8-bit
        // video range otherwise; then unbinned formats for sharpness.
        return candidates.max { a, b in score(a, s) < score(b, s) }
    }

    private func score(_ f: AVCaptureDevice.Format, _ s: CameraSettings) -> Int {
        let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
        let tenBit = Self.isTenBit(sub)
        var score = 0
        if s.appleLog == tenBit { score += 100 }
        if sub == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || sub == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || sub == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange { score += 10 }
        if !f.isVideoBinned { score += 20 }
        if f.isVideoStabilizationModeSupported(.standard) { score += 5 }
        return score
    }

    private static func ranges(for dev: AVCaptureDevice) -> CameraRanges {
        let f = dev.activeFormat
        return CameraRanges(
            isoMin: f.minISO, isoMax: f.maxISO,
            shutterMin: f.minExposureDuration.seconds,
            shutterMax: min(f.maxExposureDuration.seconds, 0.5),
            biasMin: dev.minExposureTargetBias, biasMax: dev.maxExposureTargetBias,
            zoomMin: Double(dev.minAvailableVideoZoomFactor),
            zoomMax: min(Double(dev.maxAvailableVideoZoomFactor), 30),
            hasTorch: dev.hasTorch,
            manualFocus: dev.isLockingFocusWithCustomLensPositionSupported
        )
    }

    private static func discoverLenses() -> [LensInfo] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video, position: .unspecified)
        let order: [AVCaptureDevice.DeviceType: Int] = [
            .builtInUltraWideCamera: 0, .builtInWideAngleCamera: 1, .builtInTelephotoCamera: 2,
        ]
        let devices = discovery.devices.sorted {
            if $0.position != $1.position { return $0.position == .back }
            return order[$0.deviceType, default: 9] < order[$1.deviceType, default: 9]
        }
        return devices.map { dev in
            let name: String
            if dev.position == .front {
                name = "Frontkamera"
            } else {
                switch dev.deviceType {
                case .builtInUltraWideCamera: name = "Ultraweitwinkel 0,5×"
                case .builtInTelephotoCamera: name = "Tele"
                default: name = "Weitwinkel 1×"
                }
            }
            return LensInfo(id: dev.uniqueID, name: name, isFront: dev.position == .front,
                            formats: formatOptions(dev))
        }
    }

    private static func formatOptions(_ dev: AVCaptureDevice) -> [FormatOption] {
        let sizes = [(1280, 720), (1920, 1080), (3840, 2160)]
        return sizes.compactMap { (w, h) in
            let matching = dev.formats.filter {
                let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                return Int(d.width) == w && Int(d.height) == h
                    && acceptedSubtypes.contains(CMFormatDescriptionGetMediaSubType($0.formatDescription))
            }
            guard !matching.isEmpty else { return nil }
            let maxFps = matching.flatMap(\.videoSupportedFrameRateRanges).map(\.maxFrameRate).max() ?? 30
            return FormatOption(
                width: w, height: h, maxFps: min(maxFps, 60),
                supportsLog: matching.contains { $0.supportedColorSpaces.contains(.appleLog) },
                supportsHDR: matching.contains { $0.isVideoHDRSupported })
        }
    }
}

extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), max(lo, hi)) }
}
