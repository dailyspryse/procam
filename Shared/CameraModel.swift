import Foundation

// MARK: - Settings (Mac → iPhone)

/// Everything the Studio can set. The Mac always sends the whole struct and
/// the iPhone diffs it against what is active, so a lost or reordered update
/// can never leave the two sides disagreeing for longer than one message.
struct CameraSettings: Codable, Equatable {
    // Lens & format
    var lensID: String = ""
    var width: Int = 1920
    var height: Int = 1080
    var fps: Double = 30
    var codec: VideoCodec = .hevc
    var bitrateMbps: Double = 12

    // Exposure
    var exposureMode: ControlMode = .auto
    var iso: Float = 100
    /// Shutter as seconds (1/50 s = 0.02).
    var shutter: Double = 1.0 / 50.0
    var exposureBias: Float = 0

    // White balance
    var whiteBalanceMode: ControlMode = .auto
    var temperature: Float = 5600
    var tint: Float = 0

    // Focus
    var focusMode: ControlMode = .auto
    var lensPosition: Float = 0.5

    // Optics & sensor
    var zoom: Double = 1
    var stabilization: Bool = false
    var hdr: Bool = false
    var appleLog: Bool = false
    var torch: Float = 0

    // Geometry
    /// Clockwise rotation of the output: 0, 90, 180, 270.
    var rotation: Int = 0
    var mirror: Bool = false

    // Look
    var grade = GradeSettings()
    var backgroundBlur: Bool = false
    var backgroundBlurAmount: Float = 0.6
}

enum ControlMode: String, Codable, CaseIterable {
    case auto, locked, manual
}

/// The colour pipeline, applied on the iPhone's GPU so every PC that receives
/// the stream sees exactly the same picture.
struct GradeSettings: Codable, Equatable {
    var exposure: Float = 0          // EV, -3 … 3
    var contrast: Float = 1          // 0.5 … 1.5
    var saturation: Float = 1        // 0 … 2
    var vibrance: Float = 0          // -1 … 1
    var temperature: Float = 0       // creative warm/cool, -1 … 1
    var tint: Float = 0              // -1 … 1
    var highlights: Float = 0        // -1 … 1
    var shadows: Float = 0           // -1 … 1
    var blackPoint: Float = 0        // 0 … 0.2 (fade)
    var lift: RGB = .zero            // -0.2 … 0.2 per channel, added to all
    var gamma: RGB = .one            // 0.5 … 2
    var gain: RGB = .one             // 0.5 … 2
    var vignette: Float = 0          // 0 … 1
    var sharpen: Float = 0           // 0 … 1
    var lutIntensity: Float = 1      // 0 … 1, only used when a LUT is loaded
    var lutEnabled: Bool = true
    /// Convert Apple Log to Rec.709 before grading. Only meaningful with
    /// `appleLog` on; off lets a LUT made for Apple Log do the conversion.
    var logToRec709: Bool = true

    static let neutral = GradeSettings()
}

struct RGB: Codable, Equatable {
    var r: Float
    var g: Float
    var b: Float

    static let zero = RGB(r: 0, g: 0, b: 0)
    static let one = RGB(r: 1, g: 1, b: 1)
}

// MARK: - Commands (Mac → iPhone)

enum Command: Codable {
    case apply(CameraSettings)
    /// Normalised point in output-image coordinates (0…1, top-left origin).
    case focusAt(x: Double, y: Double)
    case exposeAt(x: Double, y: Double)
    case loadLUT(name: String, cube: String)
    case clearLUT
    case requestKeyframe
}

// MARK: - Status (iPhone → Mac)

struct LensInfo: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var isFront: Bool
    var formats: [FormatOption]
}

struct FormatOption: Codable, Hashable {
    var width: Int
    var height: Int
    var maxFps: Double
    var supportsLog: Bool
    var supportsHDR: Bool

    var label: String {
        switch height {
        case 2160: return "4K"
        case 1080: return "1080p"
        case 720: return "720p"
        default: return "\(width)×\(height)"
        }
    }
}

/// Ranges of the *active* format; they change with lens and format.
struct CameraRanges: Codable, Equatable {
    var isoMin: Float = 25
    var isoMax: Float = 3200
    var shutterMin: Double = 1.0 / 8000
    var shutterMax: Double = 1.0 / 2
    var biasMin: Float = -8
    var biasMax: Float = 8
    var zoomMin: Double = 1
    var zoomMax: Double = 10
    var hasTorch: Bool = false
    var manualFocus: Bool = true
}

/// Live readings, so the Studio can show what auto modes chose and seed the
/// manual sliders with it when the user switches to manual.
struct CameraReadings: Codable, Equatable {
    var iso: Float = 0
    var shutter: Double = 0
    var exposureOffset: Float = 0
    var temperature: Float = 0
    var tint: Float = 0
    var lensPosition: Float = 0
    var zoom: Double = 1
    var fps: Double = 0
    var bitrateMbps: Double = 0
    var droppedFrames: Int = 0
    /// ProcessInfo.ThermalState raw value: 0 nominal … 3 critical.
    var thermal: Int = 0
    var battery: Float = -1
    var charging: Bool = false
    var processingMs: Double = 0
}

struct CameraStatus: Codable {
    var deviceName: String
    var lenses: [LensInfo]
    var settings: CameraSettings
    var ranges: CameraRanges
    var readings: CameraReadings
    var lutName: String?
    var error: String?
}
