import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// Declared in Info.plist so Files and AirDrop offer this app as a
    /// destination for cartridge dumps.
    static let gbaROM = UTType(exportedAs: "com.dotmatrix.gba-rom")
}

/// One imported cartridge image.
struct ROMEntry: Identifiable, Hashable {
    let id: String            // cartridge content ID
    let url: URL
    let title: String
    let gameCode: String
    let saveType: String
    let sizeBytes: Int
    let importedAt: Date

    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }
}

/// Owns the on-disk collection of user-supplied ROMs.
///
/// The app ships with no game content whatsoever. Everything here arrives from
/// a file the user explicitly imported.
@MainActor
final class ROMLibrary: ObservableObject {
    /// This build only runs Pokémon Emerald; imports of anything else are
    /// rejected with an explanation rather than silently ignored.
    static let requireEmerald = true

    @Published private(set) var entries: [ROMEntry] = []
    @Published var lastError: String?

    private let fileManager = FileManager.default

    private var romsDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ROMs", isDirectory: true)
    }

    /// The folder `UIFileSharingEnabled` exposes in the Files app. Anything
    /// dropped here is adopted into the library on the next refresh.
    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Take ownership of cartridge images the user copied in through the Files
    /// app, so importing never depends on the document picker working.
    ///
    /// Returns a description of anything that was rejected, for display.
    @discardableResult
    private func adoptDroppedFiles() -> [String] {
        guard let dropped = try? fileManager.contentsOfDirectory(
            at: documentsDirectory,
            includingPropertiesForKeys: nil
        ) else { return [] }

        var rejected: [String] = []

        for url in dropped where url.pathExtension.lowercased() == "gba" {
            do {
                let data = try Data(contentsOf: url)
                let cartridge = try GBACartridge(data: data, requireEmerald: Self.requireEmerald)

                createDirectoryIfNeeded()
                var destination = romsDirectory
                    .appendingPathComponent(url.deletingPathExtension().lastPathComponent)
                    .appendingPathExtension("gba")

                var suffix = 2
                while fileManager.fileExists(atPath: destination.path) {
                    if let existing = try? Data(contentsOf: destination),
                       let existingCartridge = try? GBACartridge(data: existing,
                                                                 requireEmerald: Self.requireEmerald),
                       existingCartridge.contentID == cartridge.contentID {
                        // Already have this one; drop the duplicate.
                        try? fileManager.removeItem(at: url)
                        break
                    }
                    destination = romsDirectory
                        .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) \(suffix)")
                        .appendingPathExtension("gba")
                    suffix += 1
                }

                if !fileManager.fileExists(atPath: url.path) { continue }
                try fileManager.moveItem(at: url, to: destination)
            } catch {
                // Leave the file in place so the user can see it is still
                // there, and say why it wasn't accepted.
                rejected.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        return rejected
    }

    init() {
        createDirectoryIfNeeded()
        reload()
    }

    private func createDirectoryIfNeeded() {
        try? fileManager.createDirectory(at: romsDirectory, withIntermediateDirectories: true)
    }

    func reload() {
        createDirectoryIfNeeded()

        // Pick up anything copied in through the Files app first.
        let rejected = adoptDroppedFiles()
        if !rejected.isEmpty {
            lastError = rejected.joined(separator: "\n\n")
        }

        guard let files = try? fileManager.contentsOfDirectory(
            at: romsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            entries = []
            return
        }

        var found: [ROMEntry] = []
        for url in files where url.pathExtension.lowercased() == "gba" {
            guard let data = try? Data(contentsOf: url),
                  let cartridge = try? GBACartridge(data: data, requireEmerald: Self.requireEmerald)
            else { continue }

            let attributes = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            found.append(ROMEntry(
                id: cartridge.contentID,
                url: url,
                title: cartridge.title.isEmpty
                    ? url.deletingPathExtension().lastPathComponent
                    : cartridge.title,
                gameCode: cartridge.gameCode,
                saveType: cartridge.saveType.displayName,
                sizeBytes: data.count,
                importedAt: attributes?.contentModificationDate ?? .distantPast
            ))
        }

        entries = found.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    /// Copy a user-picked file into the library, validating it first.
    @discardableResult
    func importROM(from source: URL) -> Bool {
        // Files picked from outside the sandbox need an explicit access scope.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: source)
            // Parse before copying so a rejected file never enters the library.
            let cartridge = try GBACartridge(data: data, requireEmerald: Self.requireEmerald)

            createDirectoryIfNeeded()

            let baseName = source.deletingPathExtension().lastPathComponent
            var destination = romsDirectory
                .appendingPathComponent(baseName)
                .appendingPathExtension("gba")

            var suffix = 2
            while fileManager.fileExists(atPath: destination.path) {
                // Re-importing the same cartridge is a no-op rather than a
                // duplicate.
                if let existing = try? Data(contentsOf: destination),
                   let existingCartridge = try? GBACartridge(data: existing,
                                                             requireEmerald: Self.requireEmerald),
                   existingCartridge.contentID == cartridge.contentID {
                    reload()
                    return true
                }
                destination = romsDirectory
                    .appendingPathComponent("\(baseName) \(suffix)")
                    .appendingPathExtension("gba")
                suffix += 1
            }

            try data.write(to: destination, options: .atomic)
            reload()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func delete(_ entry: ROMEntry) {
        try? fileManager.removeItem(at: entry.url)
        reload()
    }

    func cartridge(for entry: ROMEntry) throws -> GBACartridge {
        let data = try Data(contentsOf: entry.url)
        return try GBACartridge(data: data, requireEmerald: Self.requireEmerald)
    }
}
