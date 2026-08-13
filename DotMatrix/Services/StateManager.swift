import Foundation

/// Reads and writes emulator snapshots.
///
/// A single slot per cartridge, kept in Documents rather than Application
/// Support so it shows up in the Files app — the point of this is being able to
/// hand a snapshot to someone else, or drop one in from elsewhere.
struct StateManager {
    private let fileManager = FileManager.default

    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Keyed by cartridge, so a snapshot can never be applied to the wrong game
    /// by filename alone. The core checks the contents too.
    func url(for contentID: String) -> URL {
        documentsDirectory
            .appendingPathComponent("\(contentID).state")
    }

    func hasState(for contentID: String) -> Bool {
        fileManager.fileExists(atPath: url(for: contentID).path)
    }

    func modifiedAt(for contentID: String) -> Date? {
        try? url(for: contentID)
            .resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
    }

    /// Capture and write. Returns a description of the failure, or nil.
    func save(_ core: any EmulatorCore, contentID: String) -> String? {
        let data = core.captureState()
        do {
            // Atomic, so a crash mid-write can't leave a half-snapshot that
            // would be refused — or worse, partially applied.
            try data.write(to: url(for: contentID), options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Read and apply. Returns a description of the failure, or nil.
    func load(into core: any EmulatorCore, contentID: String) -> String? {
        let location = url(for: contentID)
        guard fileManager.fileExists(atPath: location.path) else {
            return "No snapshot saved yet."
        }
        do {
            let data = try Data(contentsOf: location)
            try core.restoreState(data)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func delete(for contentID: String) {
        try? fileManager.removeItem(at: url(for: contentID))
    }
}
