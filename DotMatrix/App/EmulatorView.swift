import SwiftUI

/// The play screen: display, controls, and the pause overlay.
struct EmulatorView: View {
    let entry: ROMEntry
    @ObservedObject var settings: AppSettings

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var session: EmulatorSession?
    @State private var loadError: String?
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let session {
                content(for: session)
            } else if let loadError {
                errorState(loadError)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(session?.displayTitle ?? entry.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let session {
                        Button {
                            session.isPaused ? session.resume() : session.pause()
                        } label: {
                            Label(session.isPaused ? "Resume" : "Pause",
                                  systemImage: session.isPaused ? "play.fill" : "pause.fill")
                        }
                    }
                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .toolbarBackground(.black, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings)
        }
        .statusBarHidden()
        // Games are meant to be looked at; don't let the display sleep.
        .persistentSystemOverlays(.hidden)
        .task {
            loadIfNeeded()
        }
        .onDisappear {
            session?.stop()
            session = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                session?.resume()
                UIApplication.shared.isIdleTimerDisabled = true
            case .inactive, .background:
                // Pause on the way out so the save is written before the system
                // can suspend or kill the process.
                session?.pause()
                UIApplication.shared.isIdleTimerDisabled = false
            @unknown default:
                break
            }
        }
    }

    @ViewBuilder
    private func content(for session: EmulatorSession) -> some View {
        let isLandscape = verticalSizeClass == .compact

        ZStack {
            if isLandscape {
                // Controls flank the screen rather than sitting under it.
                display(for: session)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    display(for: session)
                        .padding(.top, 8)
                    Spacer(minLength: 0)
                }
            }

            Gamepad(
                onButtonsChanged: { session.setButtons($0) },
                hapticsEnabled: settings.haptics
            )
            .ignoresSafeArea(.container, edges: .bottom)
            .allowsHitTesting(!session.isPaused)

            if session.isPaused {
                pauseOverlay(session)
            }

            if settings.showFPS {
                VStack {
                    HStack {
                        Spacer()
                        Text(String(format: "%.1f fps", session.measuredFPS))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(6)
                    }
                    Spacer()
                }
            }
        }
    }

    private func display(for session: EmulatorSession) -> some View {
        MetalDisplayView(
            session: session,
            gridStrength: settings.lcdGrid ? 1.0 : 0.0,
            smoothing: settings.smoothing ? 1.0 : 0.0
        )
        .aspectRatio(
            CGFloat(session.screenWidth) / CGFloat(session.screenHeight),
            contentMode: .fit
        )
        .background(Color.black)
        .accessibilityLabel("Game screen")
    }

    private func pauseOverlay(_ session: EmulatorSession) -> some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.white.opacity(0.85))
                Text("Paused")
                    .font(.headline)
                    .foregroundStyle(.white)
                Button("Resume") {
                    session.resume()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .transition(.opacity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Couldn't start this cartridge")
                .font(.headline)
                .foregroundStyle(.white)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Button("Back") { dismiss() }
                .buttonStyle(.bordered)
                .tint(.white)
        }
        .padding(32)
    }

    private func loadIfNeeded() {
        guard session == nil, loadError == nil else { return }

        do {
            let data = try Data(contentsOf: entry.url)
            let cartridge = try GBACartridge(data: data, requireEmerald: ROMLibrary.requireEmerald)
            let core = GBASystem(cartridge: cartridge, sampleRate: AudioEngine.sampleRate)
            let newSession = EmulatorSession(core: core, contentID: cartridge.contentID)
            session = newSession
            newSession.start()
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            loadError = error.localizedDescription
        }
    }
}
