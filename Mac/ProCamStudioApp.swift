import SwiftUI

@main
struct ProCamStudioApp: App {
    @StateObject private var model = StudioModel()

    var body: some Scene {
        Window("ProCam Studio", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1100, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 880)
        .commands {
            CommandMenu("Kamera") {
                Button("Fokus: Auto") { model.setFocusMode(.auto) }.keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Belichtung: Auto") { model.setExposureMode(.auto) }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Farbe zurücksetzen") { model.resetGrade() }.keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("LUT laden …") { model.chooseLUT() }.keyboardShortcut("l", modifiers: [.command])
            }
            CommandMenu("Monitoring") {
                Toggle("Zebra", isOn: $model.overlays.zebra).keyboardShortcut("z", modifiers: [.command, .option])
                Toggle("Focus Peaking", isOn: $model.overlays.peaking).keyboardShortcut("p", modifiers: [.command, .option])
                Toggle("Falschfarben", isOn: $model.overlays.falseColor).keyboardShortcut("c", modifiers: [.command, .option])
                Toggle("Drittel-Raster", isOn: $model.overlays.grid).keyboardShortcut("g", modifiers: [.command, .option])
            }
        }
    }
}
