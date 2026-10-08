import CoreGraphics
import CoreVideo
import Foundation

/// Histogram and luma waveform, computed from a subsample of the frame.
struct ScopeData {
    /// 64 bins each, normalised to the tallest bin across channels.
    var red: [Float] = []
    var green: [Float] = []
    var blue: [Float] = []
    var luma: [Float] = []
    var waveform: CGImage?
    var clippedHighlights: Float = 0
    var crushedShadows: Float = 0
}

enum ScopeAnalyzer {
    static let bins = 64
    private static let waveColumns = 320
    private static let waveRows = 128

    static func analyze(_ pb: CVPixelBuffer) -> ScopeData {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return ScopeData() }

        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        let px = base.assumingMemoryBound(to: UInt8.self)

        // ~150k samples whatever the resolution: plenty for a scope.
        let step = max(1, Int((Double(w * h) / 150_000).squareRoot()))

        var r = [Int](repeating: 0, count: bins)
        var g = [Int](repeating: 0, count: bins)
        var b = [Int](repeating: 0, count: bins)
        var l = [Int](repeating: 0, count: bins)
        var wave = [UInt32](repeating: 0, count: waveColumns * waveRows)
        var clipped = 0, crushed = 0, total = 0

        var y = 0
        while y < h {
            let row = px + y * rowBytes
            var x = 0
            while x < w {
                let p = row + x * 4           // BGRA
                let bv = Int(p[0]), gv = Int(p[1]), rv = Int(p[2])
                let lv = (rv * 54 + gv * 183 + bv * 19) >> 8
                r[rv >> 2] += 1
                g[gv >> 2] += 1
                b[bv >> 2] += 1
                l[lv >> 2] += 1
                if lv >= 250 { clipped += 1 }
                if lv <= 4 { crushed += 1 }
                total += 1
                let col = x * waveColumns / w
                let wrow = (waveRows - 1) - lv * (waveRows - 1) / 255
                wave[wrow * waveColumns + col] &+= 1
                x += step
            }
            y += step
        }

        // Normalise ignoring the extreme bins, which a black border or a
        // blown window would otherwise make tower over everything else.
        let peak = Float(max(1, [r, g, b, l].map { $0[1..<(bins - 1)].max() ?? 1 }.max() ?? 1))
        func norm(_ a: [Int]) -> [Float] { a.map { min(1, Float($0) / peak) } }

        return ScopeData(
            red: norm(r), green: norm(g), blue: norm(b), luma: norm(l),
            waveform: waveformImage(wave, samplesPerColumn: max(1, total / waveColumns)),
            clippedHighlights: Float(clipped) / Float(max(total, 1)),
            crushedShadows: Float(crushed) / Float(max(total, 1)))
    }

    private static func waveformImage(_ counts: [UInt32], samplesPerColumn: Int) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: waveColumns * waveRows * 4)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        // Log scale so a few pixels at a level are still visible.
        let scale = 255 / log(Float(samplesPerColumn) / 4 + 1)
        for i in 0..<counts.count where counts[i] > 0 {
            let v = UInt8(min(255, log(Float(counts[i]) + 1) * scale * 1.6))
            pixels[i * 4 + 0] = UInt8(Int(v) * 7 / 10)   // R
            pixels[i * 4 + 1] = v                        // G
            pixels[i * 4 + 2] = UInt8(Int(v) * 8 / 10)   // B
        }
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: waveColumns, height: waveRows, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: waveColumns * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
