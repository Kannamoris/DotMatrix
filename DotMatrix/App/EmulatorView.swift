import SwiftUI

/// The play screen: display, controls, and the pause overlay.
struct EmulatorView: View {
    let entry: ROMEntry
    @ObservedObject var settings: AppSettings

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    // The session is built asynchronously once the cartridge parses, so it
    // can't be a `@StateObject` (those need their value at init). It lives in
    // `@State` for lifecycle only — every view that reads its published
    // properties takes it as an `@ObservedObject` instead, which is what
    // actually subscribes to changes.
    @State private var session: EmulatorSession?
    @State private var loadError: String?
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let session {
                RunningSessionView(session: session, settings: settings)
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
                        PauseMenuButton(session: session)
                    }
                    if let session {
                        Divider()
                        Button {
                            session.requestSnapshot()
                        } label: {
                            Label("Save Snapshot", systemImage: "camera")
                        }
                        Button {
                            session.requestRestore()
                        } label: {
                            Label("Load Snapshot", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(!session.hasSnapshot)
                        Divider()
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
        .alert("Snapshot", isPresented: Binding(
            get: { session?.stateMessage != nil },
            set: { if !$0 { session?.clearStateMessage() } }
        )) {
            Button("OK") { session?.clearStateMessage() }
        } message: {
            Text(session?.stateMessage ?? "")
        }
        .statusBarHidden()
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

/// Everything that reads the session's published state.
///
/// Split out purely so the session can be an `@ObservedObject` here. Held in
/// the parent's `@State` it published nothing, which is why the frame counter
/// sat at its initial value and the pause button never changed label.
private struct RunningSessionView: View {
    @ObservedObject var session: EmulatorSession
    @ObservedObject var settings: AppSettings

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        let isLandscape = verticalSizeClass == .compact

        ZStack {
            if isLandscape {
                // Controls flank the screen rather than sitting under it.
                display
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    display
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
                pauseOverlay
            }

            VStack(alignment: .leading, spacing: 4) {
                if settings.showFPS {
                    HStack {
                        Spacer()
                        Text(String(format: "%.1f fps", session.measuredFPS))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                if settings.showVideoDiagnostics, !session.videoDiagnostics.isEmpty {
                    Text(session.inputDiagnostics + "\n" + session.videoDiagnostics)
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundStyle(.green.opacity(0.85))
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.black.opacity(0.65))
                        )
                        .textSelection(.enabled)
                }
                Spacer()
            }
            .padding(8)
            .allowsHitTesting(false)
        }
    }

    private var display: some View {
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

    private var pauseOverlay: some View {
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
}

/// Separate so the label tracks the session's actual paused state.
private struct PauseMenuButton: View {
    @ObservedObject var session: EmulatorSession

    var body: some View {
        Button {
            session.isPaused ? session.resume() : session.pause()
        } label: {
            Label(session.isPaused ? "Resume" : "Pause",
                  systemImage: session.isPaused ? "play.fill" : "pause.fill")
        }
    }
}
