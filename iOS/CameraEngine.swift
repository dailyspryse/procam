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

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if needsRebuild {
            if input?.device != dev {
                if let input { session.removeInput(input) }
                do {
                    let newInput = try AVCaptureDeviceInput(device: dev)
                    guard session.canAddInput(newInput) else {
                        setError("Kamera kann nicht verwendet werden")
                        return
                    }
                    session.addInput(newInput)
                    input = newInput
                    device = dev
                } catch {
                    setError("Kamera-Fehler: \(error.localizedDescription)")
                    return
                }
            }
            guard let format = findFormat(dev, new) else {
                setError("Kein passendes Format für \(new.width)×\(new.height) @ \(Int(new.fps))")
                return
            }
            do {
                try dev.lockForConfiguration()
                dev.activeFormat = format
                let duration = CMTime(value: 1000, timescale: CMTimeScale(new.fps * 1000))
                dev.activeVideoMinFrameDuration = duration
                dev.activeVideoMaxFrameDuration = duration
                if new.appleLog {
                    dev.activeColorSpace = .appleLog
                } else if format.supportedColorSpaces.contains(.sRGB) {
                    dev.activeColorSpace = .sRGB
                }
                if format.isVideoHDRSupported {
                    dev.automaticallyAdjustsVideoHDREnabled = false
                    dev.isVideoHDREnabled = new.hdr
                }
                dev.unlockForConfiguration()
            } catch {
                setError("Format konnte nicht gesetzt werden")
                return
            }
            let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: subtype,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
        }

        if let conn = output.connection(with: .video) {
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

        applyDeviceControls(dev, &new)

        lock.withLock {
            _settings = new
            _ranges = Self.ranges(for: dev)
            _error = nil
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
                dev.exposureMode = .continuousAutoExposure
            }
        case .locked:
            if dev.isExposureModeSupported(.locked) { dev.exposureMode = .locked }
        case .manual:
            if dev.isExposureModeSupported(.custom) {
                s.iso = s.iso.clamped(fmt.minISO, fmt.maxISO)
                // The shutter can never be longer than one frame.
                let maxShutter = min(fmt.maxExposureDuration.seconds, 1.0 / s.fps)
                s.shutter = s.shutter.clamped(fmt.minExposureDuration.seconds, maxShutter)
                let duration = CMTime(seconds: s.shutter, preferredTimescale: 1_000_000)
                dev.setExposureModeCustom(duration: duration, iso: s.iso)
            }
        }
        s.exposureBias = s.exposureBias.clamped(dev.minExposureTargetBias, dev.maxExposureTargetBias)
        if s.exposureMode != .manual {
            dev.setExposureTargetBias(s.exposureBias)
        }

        // White balance
        switch s.whiteBalanceMode {
        case .auto:
            if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                dev.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        case .locked:
            if dev.isWhiteBalanceModeSupported(.locked) { dev.whiteBalanceMode = .locked }
        case .manual:
            if dev.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                s.temperature = s.temperature.clamped(2000, 10000)
                s.tint = s.tint.clamped(-150, 150)
                let tt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                    temperature: s.temperature, tint: s.tint)
                var gains = dev.deviceWhiteBalanceGains(for: tt)
                let maxGain = dev.maxWhiteBalanceGain
                gains.redGain = gains.redGain.clamped(1, maxGain)
                gains.greenGain = gains.greenGain.clamped(1, maxGain)
                gains.blueGain = gains.blueGain.clamped(1, maxGain)
                dev.setWhiteBalanceModeLocked(with: gains)
            }
        }

        // Focus
        switch s.focusMode {
        case .auto:
            if dev.isFocusModeSupported(.continuousAutoFocus) {
                dev.focusMode = .continuousAutoFocus
            }
        case .locked:
            if dev.isFocusModeSupported(.locked) { dev.focusMode = .locked }
        case .manual:
            if dev.isLockingFocusWithCustomLensPositionSupported {
                s.lensPosition = s.lensPosition.clamped(0, 1)
                dev.setFocusModeLocked(lensPosition: s.lensPosition)
            }
        }

        // Zoom
        s.zoom = s.zoom.clamped(Double(dev.minAvailableVideoZoomFactor),
                                min(Double(dev.maxAvailableVideoZoomFactor), 30))
        if abs(Double(dev.videoZoomFactor) - s.zoom) > 0.001 {
            dev.videoZoomFactor = CGFloat(s.zoom)
        }

        // Torch
        if dev.hasTorch {
            if s.torch > 0.01 {
                try? dev.setTorchModeOn(level: min(s.torch, AVCaptureDevice.maxAvailableTorchLevel))
            } else if dev.torchMode != .off {
                dev.torchMode = .off
            }
        } else {
            s.torch = 0
        }
    }

    // MARK: Points of interest

    /// Maps a point in the delivered (rotated, maybe mirrored) image back to
    /// the sensor-landscape space that points of interest are expressed in.
    private func devicePoint(x: Double, y: Double) -> CGPoint {
        let s = settings
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
            dev.focusPointOfInterest = devicePoint(x: x, y: y)
            // Tap-to-focus keeps tracking afterwards in auto mode, and does a
            // one-shot otherwise so a locked focus stays locked.
            dev.focusMode = settings.focusMode == .auto ? .continuousAutoFocus : .autoFocus
            dev.unlockForConfiguration()
        }
    }

    func expose(atX x: Double, y: Double) {
        sessionQueue.async { [self] in
            guard let dev = device, dev.isExposurePointOfInterestSupported,
                  settings.exposureMode != .manual,
                  (try? dev.lockForConfiguration()) != nil else { return }
            dev.exposurePointOfInterest = devicePoint(x: x, y: y)
            dev.exposureMode = settings.exposureMode == .auto ? .continuousAutoExposure : .autoExpose
            dev.unlockForConfiguration()
        }
    }

    // MARK: Readings

    func readings() -> CameraReadings {
        var r = CameraReadings()
        guard let dev = device else { return r }
        r.iso = dev.iso
        r.shutter = dev.exposureDuration.seconds
        r.exposureOffset = dev.exposureTargetOffset
        let tt = dev.temperatureAndTintValues(for: dev.deviceWhiteBalanceGains)
        r.temperature = tt.temperature
        r.tint = tt.tint
        r.lensPosition = dev.lensPosition
        r.zoom = Double(dev.videoZoomFactor)
        return r
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
    ]

    private func findFormat(_ dev: AVCaptureDevice, _ s: CameraSettings) -> AVCaptureDevice.Format? {
        let candidates = dev.formats.filter { f in
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            guard Int(dims.width) == s.width, Int(dims.height) == s.height,
                  Self.acceptedSubtypes.contains(sub),
                  f.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= s.fps - 0.01 })
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
        let tenBit = sub == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || sub == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        var score = 0
        if s.appleLog == tenBit { score += 100 }
        if sub == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || sub == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange { score += 10 }
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
