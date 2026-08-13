import SwiftUI

/// User preferences, persisted in `UserDefaults`.
@MainActor
final class AppSettings: ObservableObject {
    @AppStorage("lcdGrid") var lcdGrid: Bool = false
    @AppStorage("smoothing") var smoothing: Bool = false
    @AppStorage("haptics") var haptics: Bool = true
    @AppStorage("showFPS") var showFPS: Bool = false
    /// Overlays live PPU register state, for diagnosing misrendered frames.
    @AppStorage("showVideoDiagnostics") var showVideoDiagnostics: Bool = false
    /// Native-UI battle panel beside the game viewport.
    @AppStorage("battleOverlay") var battleOverlay: Bool = true
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("LCD grid", isOn: $settings.lcdGrid)
                    Toggle("Smooth scaling", isOn: $settings.smoothing)
                } header: {
                    Text("Display")
                } footer: {
                    Text("The GBA screen is 240×160. It's shown pixel-perfect at the largest whole multiple that fits.")
                }

                Section {
                    Toggle("Battle panel", isOn: $settings.battleOverlay)
                } header: {
                    Text("Companion")
                } footer: {
                    Text("Uses the space beside the game to show party status and move details, read live from the running game.")
                }

                Section("Controls") {
                    Toggle("Haptic feedback", isOn: $settings.haptics)
                }

                Section {
                    Toggle("Show frame rate", isOn: $settings.showFPS)
                    Toggle("Show video registers", isOn: $settings.showVideoDiagnostics)
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("Video registers overlay the PPU's live configuration, so a screenshot of a wrong-looking frame carries the state that produced it.")
                }

                Section {
                    Text("DotMatrix contains no game software. It plays a cartridge image you supply yourself.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
