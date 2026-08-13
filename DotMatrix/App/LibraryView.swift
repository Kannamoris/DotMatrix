import SwiftUI
import UniformTypeIdentifiers

/// The home screen: the user's imported cartridge.
struct LibraryView: View {
    @StateObject private var library = ROMLibrary()
    @StateObject private var settings = AppSettings()

    @State private var showImporter = false
    @State private var showSettings = false
    @State private var importMessage: String?
    /// Set while confirming a save erase; erasing is irreversible.
    @State private var pendingSaveDeletion: ROMEntry?

    private let saves = SaveManager()

    var body: some View {
        NavigationStack {
            Group {
                if library.entries.isEmpty {
                    emptyState
                } else {
                    romList
                }
            }
            .navigationTitle("DotMatrix")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add cartridge")
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                // `.data` plus the app's exported type. Broadening this to
                // `.item` made files unselectable entirely, so leave it alone.
                allowedContentTypes: [.gbaROM, .data],
                // Single selection, so one tap imports. This app runs one
                // cartridge; picking several was never useful, and multi-select
                // requires a separate confirm step that reads as a dead button.
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(settings: settings)
            }
            .alert("Erase save data?", isPresented: Binding(
                get: { pendingSaveDeletion != nil },
                set: { if !$0 { pendingSaveDeletion = nil } }
            ), presenting: pendingSaveDeletion) { entry in
                Button("Erase", role: .destructive) {
                    saves.deleteSave(for: entry.id)
                    pendingSaveDeletion = nil
                    library.reload()
                }
                Button("Cancel", role: .cancel) { pendingSaveDeletion = nil }
            } message: { entry in
                Text("This permanently deletes the in-game save for \(entry.title), including its clock data. There is no undo.")
            }
            .alert("Import failed", isPresented: Binding(
                get: { importMessage != nil },
                set: { if !$0 { importMessage = nil } }
            )) {
                Button("OK") { importMessage = nil }
            } message: {
                Text(importMessage ?? "")
            }
        }
    }

    private var romList: some View {
        List {
            Section {
                ForEach(library.entries) { entry in
                    NavigationLink {
                        EmulatorView(entry: entry, settings: settings)
                    } label: {
                        row(for: entry)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            library.delete(entry)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        if saves.hasSave(for: entry.id) {
                            Button {
                                pendingSaveDeletion = entry
                            } label: {
                                Label("Erase Save", systemImage: "clock.arrow.circlepath")
                            }
                            .tint(.orange)
                        }
                    }
                }
            } footer: {
                Text("Swipe a cartridge for options. Removing it leaves the save in place; erasing the save cannot be undone.")
            }
        }
        .refreshable {
            library.reload()
        }
    }

    private func row(for entry: ROMEntry) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.25))
                .frame(width: 38, height: 38)
                .overlay(
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.accentColor)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(entry.gameCode)
                    Text("·")
                    Text(entry.saveType)
                    Text("·")
                    Text(entry.displaySize)
                    if saves.hasSave(for: entry.id) {
                        Text("·")
                        Image(systemName: "internaldrive")
                            .accessibilityLabel("Has save data")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)

                Text("No cartridge yet")
                    .font(.title3.weight(.semibold))

                Text("""
                DotMatrix is an emulator. It contains no game data — you supply \
                your own cartridge image.

                Tap **+** to import a `.gba` file, or copy one into **On My \
                iPhone → DotMatrix** in the Files app and pull down here to \
                refresh.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

                Button {
                    showImporter = true
                } label: {
                    Label("Import Cartridge", systemImage: "plus")
                        .frame(maxWidth: 260)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Check for dropped files") {
                    library.lastError = nil
                    library.reload()
                }
                .font(.footnote)

                // Shown inline as well as in the alert. A rejected cartridge is
                // the single most likely thing to go wrong here, and an alert
                // that fails to present leaves no explanation at all.
                if let error = library.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.orange.opacity(0.12))
                        )
                        .textSelection(.enabled)
                }

                Text("Dump the cartridge you own. Downloading a ROM of a game you don't have a copy of is illegal in most countries.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
            .padding(28)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                importMessage = "The picker returned no file."
                return
            }
            if !library.importROM(from: url) {
                // Name the file explicitly — without a console, this alert is
                // the only diagnostic available on-device.
                let reason = library.lastError ?? "Unrecognised file"
                importMessage = "\(url.lastPathComponent)\n\n\(reason)"
            }
        case .failure(let error):
            importMessage = error.localizedDescription
        }
    }
}
