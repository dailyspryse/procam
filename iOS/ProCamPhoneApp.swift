import SwiftUI

@main
struct ProCamPhoneApp: App {
    @StateObject private var controller = PhoneController()

    var body: some Scene {
        WindowGroup {
            StatusView()
                .environmentObject(controller)
                .onAppear { controller.start() }
                .preferredColorScheme(.dark)
                .persistentSystemOverlays(.hidden)
                .statusBarHidden()
        }
    }
}

/// The phone is the camera, not the monitor: this screen only says whether
/// the Studio is connected and how the phone is coping. Everything else is
/// controlled from the Mac.
struct StatusView: View {
    @EnvironmentObject var c: PhoneController
    @State private var dimmed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()
                ZStack {
                    Circle()
                        .fill(c.clientName != nil ? Color.red.opacity(0.18) : Color.white.opacity(0.06))
                        .frame(width: 120, height: 120)
                    Circle()
                        .fill(c.clientName != nil ? Color.red : Color.white.opacity(0.25))
                        .frame(width: 22, height: 22)
                }
                VStack(spacing: 8) {
                    Text(c.clientName != nil ? "LIVE" : "Bereit")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text(c.clientName.map { "Verbunden mit \($0)" }
                         ?? "Öffne ProCam Studio auf dem Mac – das iPhone wird automatisch gefunden.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                if c.clientName != nil {
                    HStack(spacing: 22) {
                        stat("Format", c.formatLabel)
                        stat("Bildrate", String(format: "%.0f fps", c.fps))
                        stat("Daten", String(format: "%.1f Mbit/s", c.bitrateMbps))
                    }
                    .padding(.top, 8)
                }

                if c.thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                    Label("iPhone wird heiß – Auflösung oder Bildrate senken",
                          systemImage: "thermometer.high")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                if !c.cameraAllowed {
                    Text("Kamerazugriff fehlt. Einstellungen → ProCam → Kamera erlauben.")
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                if let e = c.error {
                    Text(e).font(.footnote).foregroundStyle(.orange)
                }
                Spacer()
                Button {
                    dimmed = true
                } label: {
                    Label("Bildschirm abdunkeln", systemImage: "moon.fill")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 20).padding(.vertical, 12)
                        .background(.white.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 24)
            }
            .foregroundStyle(.white)

            if dimmed {
                // Pure black costs nothing on OLED; tap anywhere to come back.
                Color.black.ignoresSafeArea()
                    .onTapGesture { dimmed = false }
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.footnote.monospacedDigit().weight(.medium))
        }
    }
}
