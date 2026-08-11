import Foundation

/// Persists battery-backed cartridge RAM — the in-game save.
///
/// Files are written in the plain `.sav` layout every other emulator uses, so a
/// save can be moved to or from a desktop emulator through the Files app.
struct SaveManager {
    private let fileManager = FileManager.default

    private var savesDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Saves", isDirectory: true)
    }

    private func ensureDirectory() {
        try? fileManager.createDirectory(at: savesDirectory, withIntermediateDirectories: true)
    }

    /// Saves are keyed by cartridge content, so renaming a ROM keeps its save.
    private func saveURL(for contentID: String) -> URL {
        savesDirectory
            .appendingPathComponent(contentID)
            .appendingPathExtension("sav")
    }

    private func clockURL(for contentID: String) -> URL {
        savesDirectory
            .appendingPathComponent(contentID)
            .appendingPathExtension("rtc")
    }

    /// Restore SRAM and any real-time-clock state into a freshly built core.
    func load(into core: any EmulatorCore, contentID: String) {
        if let data = try? Data(contentsOf: saveURL(for: contentID)) {
            core.loadBatteryRAM([UInt8](data))
        }
        if let data = try? Data(contentsOf: clockURL(for: contentID)),
           let clock = try? JSONDecoder().decode([String: Int].self, from: data) {
            core.restoreAuxiliarySaveData(clock)
        }
    }

    /// Write SRAM out if it has changed. Cheap enough to call every second.
    func flushIfNeeded(_ core: any EmulatorCore, contentID: String) {
        guard core.needsBatteryFlush, let ram = core.batteryRAM else { return }
        ensureDirectory()

        do {
            // Atomic so a crash or a force-quit mid-write can't corrupt a save.
            try Data(ram).write(to: saveURL(for: contentID), options: .atomic)

            let clock = core.auxiliarySaveData
            if !clock.isEmpty, let encoded = try? JSONEncoder().encode(clock) {
                try encoded.write(to: clockURL(for: contentID), options: .atomic)
            }
            core.markBatteryFlushed()
        } catch {
            // Leave the dirty flag set so the next flush retries.
            NSLog("DotMatrix: failed to write save for \(contentID): \(error)")
        }
    }

    /// Force a write regardless of the dirty flag, for backgrounding.
    func forceFlush(_ core: any EmulatorCore, contentID: String) {
        guard core.batteryRAM != nil else { return }
        ensureDirectory()
        if let ram = core.batteryRAM {
            try? Data(ram).write(to: saveURL(for: contentID), options: .atomic)
        }
        let clock = core.auxiliarySaveData
        if !clock.isEmpty, let encoded = try? JSONEncoder().encode(clock) {
            try? encoded.write(to: clockURL(for: contentID), options: .atomic)
        }
        core.markBatteryFlushed()
    }

    func hasSave(for contentID: String) -> Bool {
        fileManager.fileExists(atPath: saveURL(for: contentID).path)
    }

    func deleteSave(for contentID: String) {
        try? fileManager.removeItem(at: saveURL(for: contentID))
        try? fileManager.removeItem(at: clockURL(for: contentID))
    }
}
