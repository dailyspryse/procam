// Writes test streams in the exact wire format the iPhone sends, so the
// Windows Studio can be verified on a Windows CI machine without a phone.
//
//   swiftc -O tools/testvector/main.swift iOS/VideoEncoder.swift Shared/Wire.swift \
//       Shared/CameraModel.swift -o build/testvector && build/testvector Windows/testdata
//
// Output per codec: <codec>.procam — a sequence of encoded WireMessages
// (videoFormat, then 90 videoFrames). Frames show four colour quadrants so the
// decoder test can check colours, plus a moving white bar.
// Also status.json: a CameraStatus as Swift encodes it.

import CoreVideo
import Foundation
import VideoToolbox

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "testdata")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let width = 1280, height = 720, frameCount = 90

func makeFrame(_ i: Int) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
    let p = pb!
    CVPixelBufferLockBaseAddress(p, [])
    let base = CVPixelBufferGetBaseAddress(p)!.assumingMemoryBound(to: UInt8.self)
    let row = CVPixelBufferGetBytesPerRow(p)
    let barX = (i * 12) % width
    for y in 0..<height {
        for x in 0..<width {
            let o = y * row + x * 4
            // Quadrants (BGRA): red | green / blue | grey
            var (b, g, r): (UInt8, UInt8, UInt8)
            switch (x < width / 2, y < height / 2) {
            case (true, true): (b, g, r) = (30, 30, 220)
            case (false, true): (b, g, r) = (30, 200, 30)
            case (true, false): (b, g, r) = (220, 40, 30)
            default: (b, g, r) = (128, 128, 128)
            }
            if abs(x - barX) < 8 { (b, g, r) = (255, 255, 255) }
            base[o] = b; base[o + 1] = g; base[o + 2] = r; base[o + 3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(p, [])
    return p
}

for codec in [VideoCodec.hevc, .h264] {
    var out = Data()
    let lock = NSLock()
    var frames = 0
    let enc = VideoEncoder()
    enc.onFormat = { f in lock.withLock { out.append(WireMessage.json(.videoFormat, f).encoded()) } }
    enc.onFrame = { f in
        lock.withLock {
            let payload = VideoFramePayload.encode(ptsUs: f.ptsUs, keyframe: f.keyframe, sample: f.sample)
            out.append(WireMessage(type: .videoFrame, payload: payload).encoded())
            frames += 1
        }
    }
    enc.ensure(codec: codec, width: width, height: height, fps: 30, bitrateMbps: 6)
    for i in 0..<frameCount {
        enc.encode(makeFrame(i), pts: CMTime(value: CMTimeValue(i), timescale: 30))
        Thread.sleep(forTimeInterval: 0.005)
    }
    enc.stop()
    Thread.sleep(forTimeInterval: 0.3)
    let url = outDir.appendingPathComponent("\(codec.rawValue).procam")
    try lock.withLock { try out.write(to: url) }
    print("\(codec.rawValue): \(frames) Frames, \(out.count) Bytes → \(url.path)")
}

// A realistic status message, encoded by Swift's JSONEncoder.
var settings = CameraSettings()
settings.lensID = "com.apple.avfoundation.avcapturedevice.built-in_video:0"
settings.grade.lift = RGB(r: 0.01, g: 0, b: -0.02)
let status = CameraStatus(
    deviceName: "iPhone Test",
    lenses: [LensInfo(id: settings.lensID, name: "Weitwinkel 1×", isFront: false,
                      formats: [FormatOption(width: 1920, height: 1080, maxFps: 60, supportsLog: true, supportsHDR: true)])],
    settings: settings, ranges: CameraRanges(), readings: CameraReadings(),
    lutName: nil, error: nil, diagnostics: nil, pipeline: nil)
try WireMessage.json(.status, status).payload.write(to: outDir.appendingPathComponent("status.json"))
let commands: [Command] = [.apply(settings), .focusAt(x: 0.25, y: 0.75), .loadLUT(name: "a.cube", cube: "LUT_3D_SIZE 2"),
                           .clearLUT, .requestKeyframe, .exposeAt(x: 0.5, y: 0.5)]
let cmdJSON = commands.map { String(data: try! JSONEncoder().encode($0), encoding: .utf8)! }
try cmdJSON.joined(separator: "\n").write(to: outDir.appendingPathComponent("commands.jsonl"), atomically: true, encoding: .utf8)
print("status.json + commands.jsonl geschrieben")
