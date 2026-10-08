import SwiftUI

struct Inspector: View {
    @EnvironmentObject var m: StudioModel
    @State private var presetName = ""
    @State private var presetWithCamera = false
    @State private var showSavePreset = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                cameraSection
                exposureSection
                whiteBalanceSection
                focusSection
                imageSection
                gradeSection
                wheelsSection
                lutSection
                effectsSection
                monitorSection
                presetSection
            }
            .frame(width: 330, alignment: .leading)
        }
        .scrollIndicators(.never)
        .background(Theme.panel)
    }

    private var connected: Bool { m.deviceName != nil }

    private var activeLens: LensInfo? { m.lenses.first { $0.id == m.settings.lensID } }
    private var activeFormat: FormatOption? {
        activeLens?.formats.first { $0.width == m.settings.width && $0.height == m.settings.height }
    }

    // MARK: Camera

    private var cameraSection: some View {
        InspectorSection("Kamera", icon: "camera.aperture") {
            if m.lenses.isEmpty {
                Text("Objektive erscheinen, sobald das iPhone verbunden ist.")
                    .font(.system(size: 11)).foregroundStyle(Theme.dim)
            } else {
                label("Objektiv")
                FlowRow {
                    ForEach(m.lenses) { lens in
                        Chip(title: lens.name, active: lens.id == m.settings.lensID) {
                            m.settings.lensID = lens.id
                            m.settings.zoom = 1
                            m.settings.mirror = lens.isFront
                        }
                    }
                }
            }

            label("Auflösung")
            HStack(spacing: 6) {
                ForEach(activeLens?.formats ?? [], id: \.self) { f in
                    Chip(title: f.label, active: f.height == m.settings.height) {
                        m.settings.width = f.width
                        m.settings.height = f.height
                        m.settings.fps = min(m.settings.fps, f.maxFps)
                    }
                }
            }

            label("Bildrate")
            HStack(spacing: 6) {
                ForEach([24.0, 25, 30, 50, 60], id: \.self) { fps in
                    let ok = fps <= (activeFormat?.maxFps ?? 30)
                    Chip(title: "\(Int(fps))", active: m.settings.fps == fps) {
                        m.settings.fps = fps
                        // Keep the shutter physically possible.
                        m.settings.shutter = min(m.settings.shutter, 1 / fps)
                    }
                    .disabled(!ok)
                    .opacity(ok ? 1 : 0.35)
                }
            }

            HStack {
                label("Codec")
                Spacer()
                Picker("", selection: $m.settings.codec) {
                    Text("HEVC").tag(VideoCodec.hevc)
                    Text("H.264").tag(VideoCodec.h264)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 130)
            }
            ParamSlider(title: "Datenrate", value: floatBinding(\.bitrateMbps), range: 2...60,
                        defaultValue: 12, format: { String(format: "%.0f Mbit/s", $0) })

            label("Zoom")
            ParamSlider(title: "Faktor", value: zoomBinding,
                        range: 0...1, defaultValue: nil,
                        format: { _ in String(format: "%.2f×", m.settings.zoom) })
            HStack(spacing: 6) {
                ForEach([1.0, 1.5, 2, 3, 5], id: \.self) { z in
                    if z <= m.ranges.zoomMax {
                        Chip(title: z == 1 ? "1×" : String(format: "%g×", z),
                             active: abs(m.settings.zoom - z) < 0.01) { m.settings.zoom = z }
                    }
                }
            }
        }
    }

    /// Zoom feels linear on a log scale.
    private var zoomBinding: Binding<Float> {
        Binding(
            get: {
                let lo = log(m.ranges.zoomMin), hi = log(max(m.ranges.zoomMax, m.ranges.zoomMin + 0.01))
                return Float((log(m.settings.zoom) - lo) / (hi - lo))
            },
            set: {
                let lo = log(m.ranges.zoomMin), hi = log(max(m.ranges.zoomMax, m.ranges.zoomMin + 0.01))
                m.settings.zoom = exp(lo + Double($0) * (hi - lo))
            })
    }

    // MARK: Exposure

    private var shutterValues: [Double] {
        let denominators: [Double] = [8000, 6400, 5000, 4000, 3200, 2500, 2000, 1600, 1250, 1000, 800,
                                      640, 500, 400, 320, 250, 200, 160, 125, 120, 100, 80, 60, 50,
                                      48, 40, 30, 25, 24, 20, 15, 12, 10, 8, 6, 4, 2]
        let maxShutter = min(m.ranges.shutterMax, 1 / m.settings.fps)
        var vals = denominators.map { 1 / $0 }.filter { $0 >= m.ranges.shutterMin - 1e-7 && $0 <= maxShutter + 1e-7 }
        if !vals.contains(where: { abs($0 - m.settings.shutter) < 1e-7 }) {
            vals.append(m.settings.shutter)
            vals.sort()
        }
        return vals.sorted()
    }

    private var isoValues: [Float] {
        let stops: [Float] = [25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800,
                              1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800]
        var vals = stops.filter { $0 >= m.ranges.isoMin - 0.5 && $0 <= m.ranges.isoMax + 0.5 }
        if !vals.contains(m.settings.iso) { vals.append(m.settings.iso) }
        return vals.sorted()
    }

    private var exposureSection: some View {
        InspectorSection("Belichtung", icon: "sun.max") {
            ModePicker(selection: m.settings.exposureMode, onChange: m.setExposureMode)
            if m.settings.exposureMode == .manual {
                StepSlider(title: "ISO", values: isoValues, selection: $m.settings.iso,
                           label: { String(format: "%.0f", $0) })
                StepSlider(title: "Verschluss", values: shutterValues, selection: $m.settings.shutter,
                           label: shutterLabel)
                HStack(spacing: 6) {
                    Chip(title: "180° (1/\(Int(m.settings.fps * 2)))") {
                        m.settings.shutter = 1 / (m.settings.fps * 2)
                    }
                    Chip(title: "Flimmerfrei 50 Hz") {
                        m.settings.shutter = m.settings.fps > 50 ? 1 / 100 : 1 / 50
                    }
                }
                meter
            } else {
                ParamSlider(title: "Belichtungskorrektur", value: $m.settings.exposureBias,
                            range: max(m.ranges.biasMin, -4)...min(m.ranges.biasMax, 4), defaultValue: 0,
                            format: { String(format: "%+.1f EV", $0) })
                readout("Automatik wählt",
                        "ISO \(Int(m.readings.iso)) · \(shutterLabel(m.readings.shutter))")
                Text("⌥ + Klick ins Bild misst die Belichtung an dieser Stelle.")
                    .font(.system(size: 10)).foregroundStyle(Theme.dim)
            }
        }
    }

    /// Exposure meter: how far the manual setting is from what auto wanted.
    private var meter: some View {
        let offset = m.readings.exposureOffset.clamped(-3, 3)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Belichtungsmesser").font(.system(size: 11)).foregroundStyle(Theme.dim)
                Spacer()
                Text(String(format: "%+.1f EV", offset))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(abs(offset) < 0.35 ? Theme.ok : Theme.accent)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.raised)
                    Rectangle().fill(Theme.dim).frame(width: 1).offset(x: g.size.width / 2)
                    Circle()
                        .fill(abs(offset) < 0.35 ? Theme.ok : Theme.accent)
                        .frame(width: 8, height: 8)
                        .offset(x: g.size.width / 2 + CGFloat(offset / 3) * (g.size.width / 2 - 4) - 4)
                }
            }
            .frame(height: 8)
        }
    }

    // MARK: White balance

    private var whiteBalanceSection: some View {
        InspectorSection("Weißabgleich", icon: "thermometer.sun") {
            ModePicker(selection: m.settings.whiteBalanceMode, onChange: m.setWhiteBalanceMode)
            if m.settings.whiteBalanceMode == .manual {
                ParamSlider(title: "Farbtemperatur", value: $m.settings.temperature, range: 2000...10000,
                            defaultValue: 5600, format: { String(format: "%.0f K", $0) })
                ParamSlider(title: "Tönung", value: $m.settings.tint, range: -150...150, defaultValue: 0,
                            format: { String(format: "%+.0f", $0) })
                FlowRow {
                    Chip(title: "Kunstlicht 3200") { m.settings.temperature = 3200 }
                    Chip(title: "Leuchtstoff 4000") { m.settings.temperature = 4000 }
                    Chip(title: "Tageslicht 5600") { m.settings.temperature = 5600 }
                    Chip(title: "Bewölkt 6500") { m.settings.temperature = 6500 }
                }
            } else {
                readout("Automatik wählt",
                        String(format: "%.0f K · Tönung %+.0f", m.readings.temperature, m.readings.tint))
            }
        }
    }

    // MARK: Focus

    private var focusSection: some View {
        InspectorSection("Fokus", icon: "scope") {
            ModePicker(selection: m.settings.focusMode, onChange: m.setFocusMode,
                       manualAvailable: m.ranges.manualFocus)
            if m.settings.focusMode == .manual {
                ParamSlider(title: "Fokusdistanz", value: $m.settings.lensPosition, range: 0...1,
                            defaultValue: nil,
                            format: { $0 < 0.02 ? "Nah" : ($0 > 0.98 ? "∞" : String(format: "%.0f %%", $0 * 100)) })
                ToggleRow(title: "Focus Peaking", isOn: $m.overlays.peaking,
                          hint: "Markiert scharfe Kanten in der Vorschau")
            } else {
                readout("Linsenposition", String(format: "%.0f %%", m.readings.lensPosition * 100))
            }
            Text("Klick ins Bild setzt den Fokus auf diese Stelle.")
                .font(.system(size: 10)).foregroundStyle(Theme.dim)
        }
    }

    // MARK: Image

    private var imageSection: some View {
        InspectorSection("Bild", icon: "camera.filters") {
            ToggleRow(title: "Apple Log", isOn: $m.settings.appleLog,
                      disabled: !(activeFormat?.supportsLog ?? false),
                      hint: (activeFormat?.supportsLog ?? false)
                        ? "10-Bit, maximaler Dynamikumfang"
                        : "Für dieses Objektiv/Format nicht verfügbar")
            if m.settings.appleLog {
                ToggleRow(title: "Log → Rec.709 umwandeln", isOn: $m.settings.grade.logToRec709,
                          hint: "Aus, wenn eine LUT die Umwandlung übernimmt")
            }
            ToggleRow(title: "HDR", isOn: $m.settings.hdr,
                      disabled: !(activeFormat?.supportsHDR ?? false) || m.settings.appleLog)
            ToggleRow(title: "Bildstabilisierung", isOn: $m.settings.stabilization,
                      hint: "Kostet etwas Bildausschnitt und Latenz")
            ToggleRow(title: "Spiegeln", isOn: $m.settings.mirror)

            label("Drehung")
            HStack(spacing: 6) {
                ForEach([0, 90, 180, 270], id: \.self) { r in
                    Chip(title: r == 0 ? "Quer" : (r == 90 ? "Hoch" : "\(r)°"),
                         active: m.settings.rotation == r) { m.settings.rotation = r }
                }
            }
            if m.ranges.hasTorch {
                ParamSlider(title: "Licht (Taschenlampe)", value: $m.settings.torch, range: 0...1,
                            defaultValue: 0, format: { $0 < 0.01 ? "Aus" : String(format: "%.0f %%", $0 * 100) })
            }
        }
    }

    // MARK: Grade

    private var gradeSection: some View {
        InspectorSection("Farbe", icon: "paintpalette") {
            HStack {
                Spacer()
                Button("Alles zurücksetzen") { m.resetGrade() }
                    .buttonStyle(.link).font(.system(size: 11))
            }
            ParamSlider(title: "Belichtung", value: $m.settings.grade.exposure, range: -3...3,
                        defaultValue: 0, format: { String(format: "%+.2f EV", $0) })
            ParamSlider(title: "Kontrast", value: $m.settings.grade.contrast, range: 0.5...1.6,
                        defaultValue: 1, format: pct100)
            ParamSlider(title: "Lichter", value: $m.settings.grade.highlights, range: -1...1,
                        defaultValue: 0, format: signedPct)
            ParamSlider(title: "Tiefen", value: $m.settings.grade.shadows, range: -1...1,
                        defaultValue: 0, format: signedPct)
            ParamSlider(title: "Schwarzwert (Fade)", value: $m.settings.grade.blackPoint, range: 0...0.2,
                        defaultValue: 0, format: { String(format: "%.0f", $0 * 500) })
            Divider().overlay(Theme.line)
            ParamSlider(title: "Sättigung", value: $m.settings.grade.saturation, range: 0...2,
                        defaultValue: 1, format: pct100)
            ParamSlider(title: "Dynamik", value: $m.settings.grade.vibrance, range: -1...1,
                        defaultValue: 0, format: signedPct)
            ParamSlider(title: "Temperatur", value: $m.settings.grade.temperature, range: -1...1,
                        defaultValue: 0, format: signedPct)
            ParamSlider(title: "Tönung", value: $m.settings.grade.tint, range: -1...1,
                        defaultValue: 0, format: signedPct)
            Divider().overlay(Theme.line)
            ParamSlider(title: "Schärfe", value: $m.settings.grade.sharpen, range: 0...1,
                        defaultValue: 0, format: pct)
            ParamSlider(title: "Vignette", value: $m.settings.grade.vignette, range: 0...1,
                        defaultValue: 0, format: pct)
        }
    }

    private var wheelsSection: some View {
        InspectorSection("Farbräder", icon: "circle.hexagongrid", defaultOpen: false) {
            HStack(alignment: .top, spacing: 8) {
                ColorWheel(title: "Lift", value: $m.settings.grade.lift, neutral: 0,
                           strength: 0.08, masterRange: -0.2...0.2)
                ColorWheel(title: "Gamma", value: $m.settings.grade.gamma, neutral: 1,
                           strength: 0.25, masterRange: 0.5...2)
                ColorWheel(title: "Gain", value: $m.settings.grade.gain, neutral: 1,
                           strength: 0.25, masterRange: 0.5...2)
            }
            .frame(maxWidth: .infinity)
            Button("Räder zurücksetzen") {
                m.settings.grade.lift = .zero
                m.settings.grade.gamma = .one
                m.settings.grade.gain = .one
            }
            .buttonStyle(.link).font(.system(size: 11))
        }
    }

    // MARK: LUT

    private var lutSection: some View {
        InspectorSection("LUT", icon: "cube.transparent", defaultOpen: false) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.phoneLutName ?? "Keine LUT geladen")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(m.phoneLutName != nil ? Theme.text : Theme.dim)
                        .lineLimit(1).truncationMode(.middle)
                    Text(".cube · z. B. Apple-Log-LUT oder Film-Look")
                        .font(.system(size: 10)).foregroundStyle(Theme.dim)
                }
                Spacer()
                Button("Laden …") { m.chooseLUT() }.controlSize(.small)
            }
            if let e = m.lutError {
                Text(e).font(.system(size: 10.5)).foregroundStyle(Theme.live)
            }
            if m.phoneLutName != nil {
                ToggleRow(title: "LUT aktiv", isOn: $m.settings.grade.lutEnabled)
                ParamSlider(title: "Stärke", value: $m.settings.grade.lutIntensity, range: 0...1,
                            defaultValue: 1, format: pct)
                Button("LUT entfernen", role: .destructive) { m.clearLUT() }
                    .buttonStyle(.link).font(.system(size: 11))
            }
        }
    }

    // MARK: Effects

    private var effectsSection: some View {
        InspectorSection("Effekte", icon: "person.crop.rectangle", defaultOpen: false) {
            ToggleRow(title: "Hintergrund unscharf", isOn: $m.settings.backgroundBlur,
                      hint: "Personenerkennung auf dem iPhone")
            if m.settings.backgroundBlur {
                ParamSlider(title: "Stärke", value: $m.settings.backgroundBlurAmount, range: 0.1...1,
                            defaultValue: 0.6, format: pct)
            }
        }
    }

    // MARK: Monitoring

    private var monitorSection: some View {
        InspectorSection("Monitoring", icon: "waveform.path.ecg.rectangle", defaultOpen: false) {
            Text("Nur in der Vorschau – nie in der Webcam.")
                .font(.system(size: 10)).foregroundStyle(Theme.dim)
            ToggleRow(title: "Zebra", isOn: $m.overlays.zebra)
            if m.overlays.zebra {
                ParamSlider(title: "Schwelle", value: $m.overlays.zebraLevel, range: 0.7...1,
                            defaultValue: 0.95, format: { String(format: "%.0f IRE", $0 * 100) })
            }
            ToggleRow(title: "Focus Peaking", isOn: $m.overlays.peaking)
            if m.overlays.peaking {
                ParamSlider(title: "Empfindlichkeit", value: Binding(
                    get: { 0.3 - m.overlays.peakThreshold },
                    set: { m.overlays.peakThreshold = 0.3 - $0 }), range: 0.05...0.27,
                            defaultValue: 0.18, format: pct)
            }
            ToggleRow(title: "Falschfarben", isOn: $m.overlays.falseColor,
                      hint: "Grün = 18 % Grau · Rosa = Haut · Rot = ausgebrannt")
            ToggleRow(title: "Drittel-Raster", isOn: $m.overlays.grid)
            ToggleRow(title: "Sicherer Bereich", isOn: $m.overlays.safeArea)
        }
    }

    // MARK: Presets

    private var presetSection: some View {
        InspectorSection("Presets", icon: "square.stack.3d.up") {
            FlowRow {
                ForEach(m.presets) { p in
                    Chip(title: p.name, active: p.grade == m.settings.grade) { m.applyPreset(p) }
                        .contextMenu {
                            Button("Löschen", role: .destructive) { m.deletePreset(p) }
                        }
                }
            }
            if showSavePreset {
                TextField("Name", text: $presetName)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                ToggleRow(title: "Kamera-Einstellungen mitspeichern", isOn: $presetWithCamera)
                HStack {
                    Button("Abbrechen") { showSavePreset = false }.controlSize(.small)
                    Spacer()
                    Button("Speichern") {
                        m.savePreset(name: presetName.isEmpty ? "Preset \(m.presets.count + 1)" : presetName,
                                     includeCamera: presetWithCamera)
                        presetName = ""
                        showSavePreset = false
                    }
                    .controlSize(.small).keyboardShortcut(.defaultAction)
                }
            } else {
                Button {
                    showSavePreset = true
                } label: {
                    Label("Aktuellen Look speichern", systemImage: "plus")
                }
                .buttonStyle(.link).font(.system(size: 11))
            }
            Text("Rechtsklick auf ein Preset zum Löschen.")
                .font(.system(size: 10)).foregroundStyle(Theme.dim)
        }
    }

    // MARK: Helpers

    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 11.5)).foregroundStyle(Theme.dim)
    }

    private func readout(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.dim)
            Spacer()
            Text(value).font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6))
    }

    private func floatBinding(_ kp: WritableKeyPath<CameraSettings, Double>) -> Binding<Float> {
        Binding(get: { Float(m.settings[keyPath: kp]) },
                set: { m.settings[keyPath: kp] = Double($0.rounded()) })
    }

    private func shutterLabel(_ s: Double) -> String {
        guard s > 0 else { return "–" }
        if s >= 0.25 { return String(format: "%.1f s", s) }
        return "1/\(Int((1 / s).rounded()))"
    }

    private func pct(_ v: Float) -> String { String(format: "%.0f %%", v * 100) }
    private func pct100(_ v: Float) -> String { String(format: "%.0f %%", v * 100) }
    private func signedPct(_ v: Float) -> String { String(format: "%+.0f", v * 100) }
}

/// Wrapping row of chips.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}
