import SwiftUI
import UniformTypeIdentifiers

/// The home screen: the user's imported cartridge.
struct LibraryView: View {
    @StateObject private var library = ROMLibrary()
    @StateObject private var settings = AppSettings()

    @State private var showImporter = false
    @State private var showSettings = false
    @State private var importMessage: String?

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
                // `.data` is included because a .gba file from an unknown
                // source is often typed as plain data rather than a declared UTI.
                allowedContentTypes: [.gbaROM, .data],
                allowsMultipleSelection: true
            ) { result in
                handleImport(result)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(settings: settings)
            }
            .alert("Import failed", isPresented: .constant(importMessage != nil)) {
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
                    }
                }
            } footer: {
                Text("Removing a cartridge leaves its save file in place.")
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

                Tap **+** to import a `.gba` file from Files, iCloud Drive, or \
                anywhere else your device can reach. You can also drop files \
                into DotMatrix's folder in the Files app.
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
            var failures: [String] = []
            for url in urls {
                if !library.importROM(from: url) {
                    let reason = library.lastError ?? "Unrecognised file"
                    failures.append("\(url.lastPathComponent): \(reason)")
                }
            }
            if !failures.isEmpty {
                importMessage = failures.joined(separator: "\n\n")
            }
        case .failure(let error):
            importMessage = error.localizedDescription
        }
    }
}
