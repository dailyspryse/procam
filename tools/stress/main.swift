// Stress test: connects to the phone like the Studio does and drives every
// setting through its range. A crash on the phone shows up as a dropped
// connection; rejected values show up as `error` in the status.
//
//   swiftc -O tools/stress/main.swift Shared/Wire.swift Shared/CameraModel.swift -o build/stress
//   build/stress [seconds-per-step]

import Foundation
import Network

final class Driver {
    let queue = DispatchQueue(label: "stress")
    var conn: NWConnection?
    var parser = MessageParser()
    var status: CameraStatus?
    var statusCount = 0
    var frames = 0
    var dropped = false
    var errors: [String] = []

    func connect() {
        let browser = NWBrowser(for: .bonjour(type: ProCamWire.bonjourType, domain: nil), using: .tcp)
        let found = DispatchSemaphore(value: 0)
        var endpoint: NWEndpoint?
        browser.browseResultsChangedHandler = { results, _ in
            if endpoint == nil, let r = results.first { endpoint = r.endpoint; found.signal() }
        }
        browser.start(queue: queue)
        guard found.wait(timeout: .now() + 15) == .success, let ep = endpoint else {
            print("Kein iPhone gefunden"); exit(1)
        }
        browser.cancel()
        let c = NWConnection(to: ep, using: .tcp)
        conn = c
        c.stateUpdateHandler = { [self] st in
            switch st {
            case .ready:
                send(.json(.hello, Hello(role: "studio", name: "Stresstest")))
                receive()
            case .failed(let e): print("Verbindung fehlgeschlagen: \(e)"); dropped = true
            case .cancelled: dropped = true
            case .waiting(let e): print("Wartet: \(e)")
            default: break
            }
        }
        c.start(queue: queue)
    }

    func receive() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 22) { [self] data, _, done, err in
            if let data {
                for m in (try? parser.feed(data)) ?? [] {
                    switch m.type {
                    case .status:
                        if let s = m.decode(CameraStatus.self) {
                            status = s
                            statusCount += 1
                            if let e = s.error, errors.last != e { errors.append(e) }
                        }
                    case .videoFrame: frames += 1
                    default: break
                    }
                }
            }
            if done || err != nil { dropped = true; return }
            receive()
        }
    }

    func send(_ m: WireMessage) { conn?.send(content: m.encoded(), completion: .idempotent) }
    func apply(_ s: CameraSettings) { send(.json(.command, Command.apply(s))) }
    func sync<T>(_ f: () -> T) -> T { queue.sync(execute: f) }
}

let step = Double(CommandLine.arguments.dropFirst().first ?? "") ?? 0.6
var d = Driver()
var firstStatus: CameraStatus?
// The phone occasionally resets the first connection right after a previous
// client left; the Studio simply reconnects, so the test does too.
for attempt in 1...3 {
    d = Driver()
    d.connect()
    var waited = 0.0
    while d.sync({ d.status == nil && !d.dropped }) && waited < 10 { Thread.sleep(forTimeInterval: 0.2); waited += 0.2 }
    firstStatus = d.sync { d.status }
    if firstStatus != nil { break }
    print("Verbindungsversuch \(attempt) fehlgeschlagen")
    Thread.sleep(forTimeInterval: 1)
}
guard let first = firstStatus else { print("Kein Status"); exit(1) }
print("Verbunden mit \(first.deviceName), \(first.lenses.count) Objektive")
if CommandLine.arguments.contains("--diag") { print(first.diagnostics ?? "keine Diagnose"); exit(0) }

var stepNo = 0
var failures: [String] = []

func run(_ label: String, _ s: CameraSettings, wait: Double = step) {
    stepNo += 1
    let framesBefore = d.sync { d.frames }
    let statusBefore = d.sync { d.statusCount }
    let errBefore = d.sync { d.errors.count }
    d.apply(s)
    Thread.sleep(forTimeInterval: wait)
    let (dropped, frames, errs, st) = d.sync { (d.dropped, d.frames, d.errors, d.status) }
    let newFrames = frames - framesBefore
    let newStatus = d.sync { d.statusCount } - statusBefore
    var line = String(format: "%3d %-58@ %3d Frames %2d Status", stepNo, label as NSString, newFrames, newStatus)
    if newFrames == 0, let p = st?.pipeline { line += "  [" + p + "]" }
    if errs.count > errBefore { line += "  ⚠️ " + errs[errBefore...].joined(separator: " | ") }
    if let st, st.settings.fps != s.fps || st.settings.height != s.height {
        line += "  → iPhone: \(st.settings.height)p\(Int(st.settings.fps))"
    }
    print(line)
    if dropped {
        print("💥 VERBINDUNG WEG nach: \(label) – iPhone-App vermutlich abgestürzt")
        exit(2)
    }
    if newFrames == 0 && wait >= 0.5 { failures.append("\(label): keine Frames") }
}

var base = first.settings

// 1. Every lens × format × frame rate, with and without Log and HDR.
for lens in first.lenses {
    for f in lens.formats {
        for fps in [24.0, 25, 30, 60] where fps <= f.maxFps {
            var s = base
            s.lensID = lens.id; s.width = f.width; s.height = f.height; s.fps = fps
            s.appleLog = false; s.hdr = false; s.zoom = 1
            run("\(lens.name) \(f.label)\(Int(fps))", s, wait: 1.2)
            if f.supportsLog { s.appleLog = true; run("\(lens.name) \(f.label)\(Int(fps)) Log", s, wait: 1.2) }
            if f.supportsHDR { s.appleLog = false; s.hdr = true; run("\(lens.name) \(f.label)\(Int(fps)) HDR", s, wait: 1.2) }
        }
    }
}

// 2. Manual controls at and beyond their limits, on each lens.
for lens in first.lenses {
    var s = base
    s.lensID = lens.id; s.width = 1920; s.height = 1080; s.fps = 30; s.appleLog = false; s.hdr = false
    run("\(lens.name) Basis", s, wait: 1.0)
    s.exposureMode = .manual
    for (iso, sh) in [(Float(1), 1.0 / 100000), (100, 1.0 / 50), (99999, 1.0), (400, 1.0 / 30), (50, 1.0 / 8000)] {
        s.iso = iso; s.shutter = sh
        run("\(lens.name) manuell ISO \(iso) 1/\(Int(1 / sh))", s)
    }
    s.exposureMode = .locked; run("\(lens.name) Belichtung Sperre", s)
    s.exposureMode = .auto
    for b: Float in [-20, -2, 0, 2, 20] { s.exposureBias = b; run("\(lens.name) EV \(b)", s, wait: 0.3) }
    s.whiteBalanceMode = .manual
    for (t, tint): (Float, Float) in [(1000, -500), (2000, -150), (5600, 0), (10000, 150), (50000, 500)] {
        s.temperature = t; s.tint = tint; run("\(lens.name) WB \(Int(t))K \(Int(tint))", s, wait: 0.3)
    }
    s.whiteBalanceMode = .locked; run("\(lens.name) WB Sperre", s, wait: 0.3)
    s.whiteBalanceMode = .auto
    s.focusMode = .manual
    for p: Float in [-1, 0, 0.5, 1, 2] { s.lensPosition = p; run("\(lens.name) Fokus \(p)", s, wait: 0.3) }
    s.focusMode = .locked; run("\(lens.name) Fokus Sperre", s, wait: 0.3)
    s.focusMode = .auto
    for z in [0.1, 1, 2.5, 10, 500] { s.zoom = z; run("\(lens.name) Zoom \(z)", s, wait: 0.3) }
    s.zoom = 1
    for t: Float in [0.5, 1, 2, 0] { s.torch = t; run("\(lens.name) Licht \(t)", s, wait: 0.3) }
    for r in [90, 180, 270, 45, 0] { s.rotation = r; run("\(lens.name) Drehung \(r)", s, wait: 0.6) }
    s.mirror.toggle(); run("\(lens.name) Spiegeln", s, wait: 0.4)
    s.mirror.toggle()
    s.stabilization = true; run("\(lens.name) Stabilisierung an", s, wait: 0.8)
    s.stabilization = false; run("\(lens.name) Stabilisierung aus", s, wait: 0.8)
    s.backgroundBlur = true; run("\(lens.name) Blur", s, wait: 1.0)
    s.backgroundBlurAmount = 1; run("\(lens.name) Blur max", s, wait: 0.6)
    s.backgroundBlur = false
    base = s
}

// 3. Grading extremes, codec and bitrate.
var g = base
g.grade.exposure = 3; g.grade.contrast = 1.6; g.grade.saturation = 2; g.grade.sharpen = 1
g.grade.vignette = 1; g.grade.lift = RGB(r: 0.2, g: -0.2, b: 0.2); g.grade.gamma = RGB(r: 0.5, g: 2, b: 0.5)
run("Grading Extreme", g)
g.grade = .neutral; g.codec = .h264; run("H.264", g, wait: 1.2)
g.codec = .hevc; g.bitrateMbps = 60; run("HEVC 60 Mbit", g, wait: 1.0)
g.bitrateMbps = 2; run("HEVC 2 Mbit", g, wait: 1.0)
g.bitrateMbps = 12

// 4. Rapid fire, like dragging sliders fast.
for i in 0..<120 {
    var s = g
    s.exposureMode = i % 3 == 0 ? .manual : .auto
    s.iso = Float.random(in: 20...20000)
    s.shutter = Double.random(in: 0.00001...0.5)
    s.zoom = Double.random(in: 0.5...20)
    s.whiteBalanceMode = i % 2 == 0 ? .manual : .auto
    s.temperature = Float.random(in: 1500...12000)
    s.focusMode = .manual
    s.lensPosition = Float.random(in: -0.5...1.5)
    s.grade.exposure = Float.random(in: -3...3)
    if i % 20 == 0, let lens = first.lenses.randomElement() { s.lensID = lens.id }
    d.apply(s)
    Thread.sleep(forTimeInterval: 0.02)
}
run("Nach Schnellfeuer", g, wait: 2)

// Back to a sane default.
var final = first.settings
final.exposureMode = .auto; final.whiteBalanceMode = .auto; final.focusMode = .auto
final.zoom = 1; final.torch = 0
run("Zurück auf Standard", final, wait: 1.0)

print("\n✅ Kein Absturz in \(stepNo) Schritten.")
print("Pipeline: " + (d.sync { d.status?.pipeline } ?? "-"))
if !failures.isEmpty { print("Ohne Bild:\n  " + failures.joined(separator: "\n  ")) }
exit(0)
