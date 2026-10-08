import SwiftUI

struct ContentView: View {
    @EnvironmentObject var m: StudioModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TopBar()
                Rectangle().fill(Theme.line).frame(height: 1)
                PreviewArea()
                Rectangle().fill(Theme.line).frame(height: 1)
                ScopeBar()
            }
            Rectangle().fill(Theme.line).frame(width: 1)
            Inspector()
                .frame(width: 330)
        }
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Top bar

struct TopBar: View {
    @EnvironmentObject var m: StudioModel
    @State private var showConnect = false
    @State private var manualHost = ""

    var body: some View {
        HStack(spacing: 14) {
            Text("ProCam")
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(Theme.text)
            Text("STUDIO")
                .font(.system(size: 9.5, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(Theme.accent)
                .padding(.leading, -8)

            Button { showConnect.toggle() } label: { connectionPill }
                .buttonStyle(.plain)
                .popover(isPresented: $showConnect, arrowEdge: .bottom) { connectPopover }

            Spacer()

            if m.deviceName != nil {
                stat("ISO", "\(Int(m.readings.iso))")
                stat("VERSCHL.", shutter(m.readings.shutter))
                stat("WB", String(format: "%.0fK", m.readings.temperature))
                stat("FPS", String(format: "%.0f", m.receivedFps))
                stat("DATEN", String(format: "%.1f", m.readings.bitrateMbps))
                if m.readings.battery >= 0 {
                    stat(m.readings.charging ? "AKKU ⚡︎" : "AKKU", "\(Int(m.readings.battery * 100))%")
                }
                if m.readings.thermal >= 2 {
                    Label("Heiß", systemImage: "thermometer.high")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.live)
                }
            }

            VirtualCamButton()
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(Theme.panel)
    }

    private var connectionPill: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
                .shadow(color: dotColor.opacity(0.8), radius: m.deviceName != nil ? 4 : 0)
            Text(connectionText)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.text)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.dim)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Theme.raised, in: Capsule())
    }

    private var dotColor: Color {
        switch m.linkState {
        case .connected: return Theme.live
        case .connecting: return Theme.accent
        case .idle: return Theme.dim
        }
    }

    private var connectionText: String {
        switch m.linkState {
        case .connected(let n): return n
        case .connecting(let n): return "Verbinde mit \(n) …"
        case .idle: return m.phones.isEmpty ? "Suche iPhone …" : "Nicht verbunden"
        }
    }

    private var connectPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("iPhones im Netzwerk").font(.headline)
            if m.phones.isEmpty {
                Text("Keins gefunden. Ist ProCam auf dem iPhone geöffnet und im selben WLAN?")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(m.phones) { p in
                Button {
                    m.connect(p)
                    showConnect = false
                } label: {
                    HStack {
                        Image(systemName: "iphone")
                        Text(p.name)
                        Spacer()
                        if m.deviceName == p.name { Image(systemName: "checkmark") }
                    }
                }
                .buttonStyle(.plain)
            }
            Divider()
            Text("Direkt per IP").font(.subheadline)
            HStack {
                TextField("192.168.178.x", text: $manualHost).textFieldStyle(.roundedBorder)
                Button("Verbinden") {
                    m.connect(host: manualHost)
                    showConnect = false
                }
                .disabled(manualHost.isEmpty)
            }
            if m.deviceName != nil {
                Button("Trennen", role: .destructive) {
                    m.disconnect()
                    showConnect = false
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(title).font(.system(size: 8.5, weight: .bold)).tracking(0.6).foregroundStyle(Theme.dim)
            Text(value).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.text)
        }
    }

    private func shutter(_ s: Double) -> String {
        s > 0 ? (s >= 0.25 ? String(format: "%.1fs", s) : "1/\(Int((1 / s).rounded()))") : "–"
    }
}

struct VirtualCamButton: View {
    @EnvironmentObject var m: StudioModel
    @State private var showInfo = false

    var body: some View {
        Button { showInfo.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "web.camera")
                Text(title)
            }
            .font(.system(size: 11.5, weight: .semibold))
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(m.vcam == .ready ? Theme.ok.opacity(0.16) : Theme.accent.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(m.vcam == .ready ? Theme.ok : Theme.accent)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showInfo, arrowEdge: .bottom) { info }
    }

    private var title: String {
        switch m.vcam {
        case .ready: return "Webcam aktiv"
        case .needsApproval: return "Freigabe nötig"
        case .installing: return "Wird eingerichtet …"
        case .failed: return "Webcam-Fehler"
        case .notInstalled, .unknown: return "Webcam einrichten"
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Virtuelle Webcam").font(.headline)
            switch m.vcam {
            case .ready:
                Text("In Zoom, Teams, OBS, FaceTime … „\(VirtualCameraIDs.deviceName)“ als Kamera wählen.")
            case .needsApproval:
                Text("Systemeinstellungen → Allgemein → Anmeldeobjekte & Erweiterungen → Kameraerweiterungen: ProCam erlauben.")
                Button("Systemeinstellungen öffnen") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                }
            case .failed(let msg):
                Text(msg).foregroundStyle(Theme.live)
                Button("Erneut versuchen") { m.installVirtualCamera() }
            case .installing:
                Text("Die Erweiterung wird geladen. Das dauert einige Sekunden.")
            case .notInstalled, .unknown:
                if !m.isInApplicationsFolder {
                    Text("ProCam Studio muss im Ordner „Programme“ liegen, damit macOS die Kamera-Erweiterung lädt.")
                        .foregroundStyle(Theme.accent)
                }
                Text("Richtet „\(VirtualCameraIDs.deviceName)“ als Kamera für alle Apps ein. macOS fragt einmal nach einer Freigabe.")
                Button("Einrichten") { m.installVirtualCamera() }
                    .keyboardShortcut(.defaultAction)
            }
            if m.vcam == .ready {
                Button("Entfernen", role: .destructive) { m.uninstallVirtualCamera() }
                    .buttonStyle(.link)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(width: 320)
    }
}

// MARK: - Preview

struct PreviewArea: View {
    @EnvironmentObject var m: StudioModel
    @State private var tapMarker: (CGPoint, Bool, Date)?

    var body: some View {
        GeometryReader { geo in
            let rect = fittedRect(image: m.videoSize, in: geo.size)
            ZStack(alignment: .topLeading) {
                PreviewView(store: m.store, overlays: m.overlays)

                if m.deviceName == nil {
                    emptyState.frame(width: geo.size.width, height: geo.size.height)
                } else {
                    guides(rect)
                    if let (p, exposure, _) = tapMarker {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(exposure ? Color.yellow : Theme.accent, lineWidth: 1.5)
                            .frame(width: 70, height: 70)
                            .overlay(Image(systemName: exposure ? "sun.max.fill" : "scope")
                                .font(.system(size: 11)).foregroundStyle(exposure ? Color.yellow : Theme.accent)
                                .offset(x: 44, y: -26))
                            .position(p)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                    if let err = m.phoneError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .padding(8)
                            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(Theme.accent)
                            .padding(12)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { loc in
                guard m.deviceName != nil, rect.contains(loc) else { return }
                let x = (loc.x - rect.minX) / rect.width
                let y = (loc.y - rect.minY) / rect.height
                let exposure = NSEvent.modifierFlags.contains(.option)
                m.pointOfInterest(x: x, y: y, exposure: exposure)
                withAnimation(.easeOut(duration: 0.15)) { tapMarker = (loc, exposure, Date()) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    withAnimation(.easeOut(duration: 0.3)) { tapMarker = nil }
                }
            }
        }
        .background(Color.black)
    }

    @ViewBuilder
    private func guides(_ r: CGRect) -> some View {
        if m.overlays.grid {
            Path { p in
                for i in 1...2 {
                    let x = r.minX + r.width * CGFloat(i) / 3
                    let y = r.minY + r.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                    p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.75)
            .allowsHitTesting(false)
        }
        if m.overlays.safeArea {
            Rectangle()
                .strokeBorder(Color.white.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                .frame(width: r.width * 0.9, height: r.height * 0.9)
                .position(x: r.midX, y: r.midY)
                .allowsHitTesting(false)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 3).frame(width: 74, height: 74)
                Circle().fill(m.linkState == .idle ? Theme.dim : Theme.accent).frame(width: 14, height: 14)
            }
            Text(m.linkState == .idle ? "Kein iPhone verbunden" : "Verbinde …")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("ProCam auf dem iPhone öffnen – gleiches WLAN genügt.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.dim)
        }
    }
}

// MARK: - Scopes

struct ScopeBar: View {
    @EnvironmentObject var m: StudioModel

    var body: some View {
        HStack(spacing: 1) {
            scopePanel("Histogramm") { histogram }
            scopePanel("Waveform") {
                if let img = m.scopes.waveform {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .overlay(waveformScale)
                } else { Color.clear }
            }
            exposurePanel
        }
        .frame(height: 150)
        .background(Theme.line)
    }

    private func scopePanel<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(Theme.dim)
            content()
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel)
    }

    private var histogram: some View {
        Canvas { ctx, size in
            func curve(_ values: [Float], _ color: Color) {
                guard values.count > 1 else { return }
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height))
                for (i, v) in values.enumerated() {
                    let x = size.width * CGFloat(i) / CGFloat(values.count - 1)
                    p.addLine(to: CGPoint(x: x, y: size.height * (1 - CGFloat(v) * 0.95)))
                }
                p.addLine(to: CGPoint(x: size.width, y: size.height))
                p.closeSubpath()
                ctx.fill(p, with: .color(color))
            }
            var blend = ctx
            blend.blendMode = .plusLighter
            func add(_ v: [Float], _ c: Color) {
                guard v.count > 1 else { return }
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height))
                for (i, val) in v.enumerated() {
                    p.addLine(to: CGPoint(x: size.width * CGFloat(i) / CGFloat(v.count - 1),
                                          y: size.height * (1 - CGFloat(val) * 0.95)))
                }
                p.addLine(to: CGPoint(x: size.width, y: size.height))
                p.closeSubpath()
                blend.fill(p, with: .color(c))
            }
            add(m.scopes.red, Color(red: 0.9, green: 0.15, blue: 0.15).opacity(0.55))
            add(m.scopes.green, Color(red: 0.15, green: 0.85, blue: 0.25).opacity(0.55))
            add(m.scopes.blue, Color(red: 0.2, green: 0.35, blue: 1).opacity(0.6))
            curve(m.scopes.luma, Color.white.opacity(0.18))
            for i in 1..<4 {
                let x = size.width * CGFloat(i) / 4
                ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                           with: .color(.white.opacity(0.07)))
            }
        }
    }

    private var waveformScale: some View {
        GeometryReader { g in
            ForEach([0, 25, 50, 75, 100], id: \.self) { ire in
                let y = g.size.height * (1 - CGFloat(ire) / 100)
                Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: g.size.width, y: y)) }
                    .stroke(Color.white.opacity(ire == 100 ? 0.25 : 0.08), lineWidth: 0.5)
                Text("\(ire)")
                    .font(.system(size: 8).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.35))
                    .position(x: 10, y: min(max(y, 6), g.size.height - 6))
            }
        }
    }

    private var exposurePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SIGNAL").font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(Theme.dim)
            meterRow("Ausgebrannt", m.scopes.clippedHighlights, warn: 0.02)
            meterRow("Abgesoffen", m.scopes.crushedShadows, warn: 0.05)
            Spacer(minLength: 0)
            HStack {
                Text("\(Int(m.videoSize.width))×\(Int(m.videoSize.height))")
                Spacer()
                Text(String(format: "GPU %.1f ms", m.readings.processingMs))
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(Theme.dim)
            if m.readings.droppedFrames > 0 {
                Text("\(m.readings.droppedFrames) Frames verworfen (WLAN)")
                    .font(.system(size: 10)).foregroundStyle(Theme.accent)
            }
        }
        .padding(10)
        .frame(width: 210)
        .frame(maxHeight: .infinity)
        .background(Theme.panel)
    }

    private func meterRow(_ title: String, _ value: Float, warn: Float) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 10.5)).foregroundStyle(Theme.dim)
                Spacer()
                Text(String(format: "%.1f %%", value * 100))
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(value > warn ? Theme.live : Theme.text)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.raised)
                    Capsule().fill(value > warn ? Theme.live : Theme.ok)
                        .frame(width: max(2, g.size.width * CGFloat(min(value * 10, 1))))
                }
            }
            .frame(height: 4)
        }
    }
}
