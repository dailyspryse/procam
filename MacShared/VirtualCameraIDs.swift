import CoreMedia
import Foundation

/// Shared between ProCam Studio and its camera extension. The device UUID is
/// how the app finds the extension's sink stream through CoreMediaIO.
enum VirtualCameraIDs {
    static let deviceUID = "6F1C2A4E-7B3D-4C8E-9A15-2D7E8B4F0C31"
    static let sourceStreamUID = "6F1C2A4E-7B3D-4C8E-9A15-2D7E8B4F0C32"
    static let sinkStreamUID = "6F1C2A4E-7B3D-4C8E-9A15-2D7E8B4F0C33"
    static let deviceName = "ProCam iPhone"
    static let extensionBundleID = "de.procam.studio.camera"

    /// Video-conferencing apps want one stable format; the Studio scales
    /// whatever the phone sends to this.
    static let width: Int32 = 1920
    static let height: Int32 = 1080
    static let maxFps: Int32 = 60
}
