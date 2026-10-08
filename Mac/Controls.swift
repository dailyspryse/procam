import SwiftUI

// MARK: - Palette

enum Theme {
    static let bg = Color(red: 0.055, green: 0.056, blue: 0.064)
    static let panel = Color(red: 0.085, green: 0.087, blue: 0.098)
    static let raised = Color(red: 0.12, green: 0.123, blue: 0.137)
    static let line = Color.white.opacity(0.07)
    static let text = Color.white.opacity(0.92)
    static let dim = Color.white.opacity(0.48)
    static let accent = Color(red: 1.0, green: 0.62, blue: 0.18)   // tally amber
    static let live = Color(red: 1.0, green: 0.26, blue: 0.22)
    static let ok = Color(red: 0.32, green: 0.85, blue: 0.5)
}

// MARK: - Section

struct InspectorSection<Content: View>: View {
    let title: String
    let icon: String
    @AppStorage private var open: Bool
    @ViewBuilder var content: Content

    init(_ title: String, icon: String, defaultOpen: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self._open = AppStorage(wrappedValue: defaultOpen, "section.\(title)")
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { open.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 16)
                    Text(title.uppercased())
                        .font(.system(size: 10.5, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.dim)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                VStack(alignment: .leading, spacing: 12) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }
}

// MARK: - Slider row

struct ParamSlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var defaultValue: Float? = nil
    var format: (Float) -> String = { String(format: "%.2f", $0) }
    var disabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(disabled ? Theme.dim.opacity(0.6) : Theme.dim)
                Spacer()
                Text(format(value))
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(isDefault ? Theme.dim : Theme.text)
            }
            Slider(value: $value, in: range)
                .controlSize(.small)
                .tint(Theme.accent)
                .disabled(disabled)
        }
        .contentShape(Rectangle())
        // Double-click resets, like every grading app.
        .onTapGesture(count: 2) {
            if let d = defaultValue { value = d }
        }
        .help(defaultValue != nil ? "Doppelklick setzt zurück" : "")
    }

    private var isDefault: Bool {
        guard let d = defaultValue else { return false }
        return abs(value - d) < 0.0005
    }
}

/// Slider over a list of discrete values (shutter speeds, ISO stops …).
struct StepSlider<T: Equatable>: View {
    let title: String
    let values: [T]
    @Binding var selection: T
    let label: (T) -> String
    var disabled = false

    var body: some View {
        let idx = Binding<Double>(
            get: { Double(values.firstIndex(of: selection) ?? nearestIndex) },
            set: { selection = values[Int($0.rounded()).clamped(0, values.count - 1)] })
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                Spacer()
                Text(label(selection))
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.text)
            }
            if values.count > 1 {
                Slider(value: idx, in: 0...Double(values.count - 1), step: 1)
                    .controlSize(.small)
                    .tint(Theme.accent)
                    .disabled(disabled)
            }
        }
    }

    private var nearestIndex: Int { 0 }
}

extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), max(lo, hi)) }
}

// MARK: - Mode picker

struct ModePicker: View {
    let selection: ControlMode
    let onChange: (ControlMode) -> Void
    var manualAvailable = true

    var body: some View {
        Picker("", selection: Binding(get: { selection }, set: onChange)) {
            Text("Auto").tag(ControlMode.auto)
            Text("Sperre").tag(ControlMode.locked)
            if manualAvailable { Text("Manuell").tag(ControlMode.manual) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
    }
}

// MARK: - Chips

struct Chip: View {
    let title: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(active ? Theme.accent.opacity(0.22) : Theme.raised,
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(active ? Theme.accent.opacity(0.7) : Theme.line))
                .foregroundStyle(active ? Theme.accent : Theme.text)
        }
        .buttonStyle(.plain)
    }
}

struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var disabled = false
    var hint: String? = nil

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 11.5)).foregroundStyle(Theme.text)
                if let hint {
                    Text(hint).font(.system(size: 10)).foregroundStyle(Theme.dim)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(Theme.accent)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }
}

// MARK: - Colour wheel

/// Lift / gamma / gain wheel. The puck sets a colour offset, the slider below
/// the master level. Offsets are stored as RGB around `neutral`.
struct ColorWheel: View {
    let title: String
    @Binding var value: RGB
    let neutral: Float
    let strength: Float       // how far the rim pushes a channel
    let masterRange: ClosedRange<Float>

    private let size: CGFloat = 76

    var body: some View {
        VStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.dim)
            ZStack {
                Circle()
                    .fill(AngularGradient(
                        colors: ([.red, .yellow, .green, .cyan, .blue, .purple, .red] as [Color])
                            .map { $0.opacity(0.75) },
                        center: .center, angle: .degrees(-90)))
                Circle()
                    .fill(RadialGradient(colors: [Theme.panel, Theme.panel.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: size / 2))
                Circle().strokeBorder(Color.white.opacity(0.12))
                Path { p in
                    p.move(to: CGPoint(x: size / 2, y: 6)); p.addLine(to: CGPoint(x: size / 2, y: size - 6))
                    p.move(to: CGPoint(x: 6, y: size / 2)); p.addLine(to: CGPoint(x: size - 6, y: size / 2))
                }
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                Circle()
                    .fill(Color.white)
                    .frame(width: 9, height: 9)
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .offset(puckOffset)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                setPuck(CGPoint(x: g.location.x - size / 2, y: g.location.y - size / 2))
            })
            .onTapGesture(count: 2) { resetColor() }

            Slider(value: Binding(get: { master }, set: { setMaster($0) }), in: masterRange)
                .controlSize(.mini)
                .tint(Theme.accent)
                .frame(width: size + 8)
            Text(String(format: "%+.2f", master - neutral))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Theme.dim)
        }
        .help("Ziehen: Farbe · Doppelklick: Farbe zurücksetzen")
    }

    private var master: Float { (value.r + value.g + value.b) / 3 }

    // Hue-plane projection of the RGB offset (standard opponent axes).
    private var puckOffset: CGSize {
        let m = master
        let dr = value.r - m, dg = value.g - m, db = value.b - m
        let x = dr - 0.5 * (dg + db)
        let y = Float(3).squareRoot() / 2 * (dg - db)
        let scale = Float(size / 2) / (strength * 1.5)
        // Screen: red at the top, matching the wheel gradient's start.
        let angle = atan2(y, x)
        let r = min(Float(size / 2 - 6), (x * x + y * y).squareRoot() * scale)
        return CGSize(width: CGFloat(r * sin(angle)), height: CGFloat(-r * cos(angle)))
    }

    private func setPuck(_ p: CGPoint) {
        var r = Float((p.x * p.x + p.y * p.y).squareRoot())
        r = min(r, Float(size / 2 - 6))
        let angle = atan2(Float(p.x), Float(-p.y))     // 0 at top, clockwise
        let mag = r / Float(size / 2) * strength * 1.5
        let x = mag * cos(angle), y = mag * sin(angle)
        let m = master
        value = RGB(r: m + 2 * x / 3,
                    g: m - x / 3 + y / Float(3).squareRoot(),
                    b: m - x / 3 - y / Float(3).squareRoot())
    }

    private func setMaster(_ newMaster: Float) {
        let d = newMaster - master
        value = RGB(r: value.r + d, g: value.g + d, b: value.b + d)
    }

    private func resetColor() {
        let m = master
        value = RGB(r: m, g: m, b: m)
    }
}
