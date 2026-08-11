import Foundation

enum GBACartridgeError: LocalizedError {
    case fileTooSmall(Int)
    case notPokemonEmerald(title: String, code: String)

    var errorDescription: String? {
        switch self {
        case .fileTooSmall(let n):
            return "This file is only \(n) bytes. A Game Boy Advance ROM is at least 1 MB."
        case .notPokemonEmerald(let title, let code):
            let shown = title.isEmpty ? "unknown" : title
            return """
            This app only runs Pokémon Emerald. \
            That cartridge reports itself as “\(shown)” (game code \(code)).
            """
        }
    }
}

/// How a cartridge stores its save data. Detected from a marker string the
/// build tools leave in the ROM.
enum SaveType {
    case none
    case sram          // 32 KB
    case eeprom512     // 512 B
    case eeprom8k      // 8 KB
    case flash64k      // 64 KB
    case flash128k     // 128 KB — what Emerald uses

    var byteCount: Int {
        switch self {
        case .none:       return 0
        case .sram:       return 32 * 1024
        case .eeprom512:  return 512
        case .eeprom8k:   return 8 * 1024
        case .flash64k:   return 64 * 1024
        case .flash128k:  return 128 * 1024
        }
    }

    var displayName: String {
        switch self {
        case .none:      return "None"
        case .sram:      return "SRAM 32K"
        case .eeprom512: return "EEPROM 512B"
        case .eeprom8k:  return "EEPROM 8K"
        case .flash64k:  return "Flash 64K"
        case .flash128k: return "Flash 128K"
        }
    }
}

/// A user-supplied Game Boy Advance ROM.
///
/// The app ships no cartridge data. Everything here is read out of the file the
/// user imported.
final class GBACartridge {
    /// Game code of Pokémon Emerald, from the header at 0x0AC.
    static let emeraldGameCode = "BPEE"

    let rom: [UInt8]
    let title: String
    let gameCode: String
    let saveType: SaveType
    let backup: BackupMedium

    /// Stable save identity, so renaming the file doesn't orphan the save.
    let contentID: String

    var isPokemonEmerald: Bool { gameCode == Self.emeraldGameCode }

    /// - Parameter requireEmerald: reject anything that isn't Emerald. The app
    ///   sets this; the core itself has no such restriction.
    init(data: Data, requireEmerald: Bool) throws {
        // The smallest commercial GBA ROM is 1 MB; the header alone needs 0xC0.
        guard data.count >= 0xC0 else { throw GBACartridgeError.fileTooSmall(data.count) }

        let bytes = [UInt8](data)
        self.rom = bytes

        // 0x0A0...0x0AB is the title, 0x0AC...0x0AF the game code.
        let titleBytes = bytes[0x0A0...0x0AB].prefix { $0 != 0 }
        self.title = String(decoding: titleBytes.filter { (0x20...0x7E).contains($0) }, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        self.gameCode = String(decoding: bytes[0x0AC...0x0AF].filter { (0x20...0x7E).contains($0) },
                               as: UTF8.self)

        if requireEmerald && gameCode != Self.emeraldGameCode {
            throw GBACartridgeError.notPokemonEmerald(title: title, code: gameCode)
        }

        self.saveType = Self.detectSaveType(in: bytes)
        self.contentID = "\(gameCode.isEmpty ? "UNKNOWN" : gameCode)-\(bytes.count)"

        switch saveType {
        case .flash64k:
            self.backup = FlashBackup(size: 64 * 1024)
        case .flash128k:
            self.backup = FlashBackup(size: 128 * 1024)
        case .sram:
            self.backup = SRAMBackup(size: 32 * 1024)
        case .eeprom512, .eeprom8k:
            self.backup = EEPROMBackup(size: saveType.byteCount)
        case .none:
            self.backup = SRAMBackup(size: 0)
        }
    }

    /// The toolchain leaves an ASCII marker naming the save hardware. Scanning
    /// for it is how every emulator picks the right backup chip, since nothing
    /// in the header records it.
    private static func detectSaveType(in bytes: [UInt8]) -> SaveType {
        // Order matters: "FLASH1M_" and "FLASH512_" both contain "FLASH".
        let markers: [(String, SaveType)] = [
            ("FLASH1M_V", .flash128k),
            ("FLASH512_V", .flash64k),
            ("FLASH_V", .flash64k),
            ("EEPROM_V", .eeprom8k),
            ("SRAM_F_V", .sram),
            ("SRAM_V", .sram),
        ]

        for (marker, type) in markers {
            if find(marker: [UInt8](marker.utf8), in: bytes) {
                return type
            }
        }
        // Nothing found: 64 KB flash is the safest fallback — it is the most
        // common, and a too-large buffer is harmless where a too-small one
        // silently truncates saves.
        return .flash64k
    }

    private static func find(marker: [UInt8], in bytes: [UInt8]) -> Bool {
        guard !marker.isEmpty, bytes.count >= marker.count else { return false }
        let first = marker[0]
        // Markers are word-aligned in practice, which cuts the scan by 4x.
        var index = 0
        while index <= bytes.count - marker.count {
            if bytes[index] == first {
                var matched = true
                for offset in 1..<marker.count where bytes[index + offset] != marker[offset] {
                    matched = false
                    break
                }
                if matched { return true }
            }
            index += 4
        }
        return false
    }
}

// MARK: - Backup media

/// Cartridge save storage, mapped at 0x0E000000.
protocol BackupMedium: AnyObject {
    func read(_ address: UInt32) -> UInt8
    func write(_ address: UInt32, _ value: UInt8)

    var data: [UInt8] { get }
    func load(_ bytes: [UInt8])

    var isDirty: Bool { get set }
}

/// Plain battery-backed static RAM. Directly addressable, no protocol.
final class SRAMBackup: BackupMedium {
    private(set) var storage: [UInt8]
    var isDirty = false

    init(size: Int) {
        // Save media erase to 0xFF; games check for that to detect a fresh chip.
        storage = [UInt8](repeating: 0xFF, count: size)
    }

    func read(_ address: UInt32) -> UInt8 {
        guard !storage.isEmpty else { return 0xFF }
        return storage[Int(address) % storage.count]
    }

    func write(_ address: UInt32, _ value: UInt8) {
        guard !storage.isEmpty else { return }
        storage[Int(address) % storage.count] = value
        isDirty = true
    }

    var data: [UInt8] { storage }

    func load(_ bytes: [UInt8]) {
        guard !storage.isEmpty else { return }
        for i in 0..<min(bytes.count, storage.count) { storage[i] = bytes[i] }
        isDirty = false
    }
}

/// Flash memory, which Emerald uses.
///
/// Unlike SRAM this is a command-driven device: writes to two magic addresses
/// unlock a command, and only then does a third write take effect. Bytes can be
/// cleared to 0 individually but only restored to 0xFF a whole sector at a time,
/// which is why the erase commands exist at all.
final class FlashBackup: BackupMedium {
    private var storage: [UInt8]
    private let size: Int
    var isDirty = false

    /// Where the unlock sequence has got to.
    private enum Phase {
        case ready
        case unlock1        // saw 0xAA at 0x5555
        case unlock2        // saw 0x55 at 0x2AAA
        case eraseUnlock1   // erase command, second unlock round
        case eraseUnlock2
    }

    private var phase: Phase = .ready
    private var idMode = false
    private var eraseArmed = false
    private var writeArmed = false
    private var bankSwitchArmed = false
    private var bank = 0

    /// Macronix 128 KB device. Emerald reads these two bytes to size the chip,
    /// and reporting the wrong pair makes it refuse to save.
    private let manufacturerID: UInt8
    private let deviceID: UInt8

    init(size: Int) {
        self.size = size
        self.storage = [UInt8](repeating: 0xFF, count: size)
        if size > 64 * 1024 {
            self.manufacturerID = 0xC2   // Macronix
            self.deviceID = 0x09         // MX29L010, 128 KB
        } else {
            self.manufacturerID = 0x32   // Panasonic
            self.deviceID = 0x1B         // MN63F805MNP, 64 KB
        }
    }

    func read(_ address: UInt32) -> UInt8 {
        let offset = Int(address & 0xFFFF)

        if idMode {
            // While in ID mode the first two bytes report the chip identity
            // instead of its contents.
            if offset == 0 { return manufacturerID }
            if offset == 1 { return deviceID }
        }

        let index = bank * 0x10000 + offset
        guard index < storage.count else { return 0xFF }
        return storage[index]
    }

    func write(_ address: UInt32, _ value: UInt8) {
        let offset = UInt32(address & 0xFFFF)

        // A byte write or bank switch was armed by the previous command and
        // consumes this write outright.
        if writeArmed {
            let index = bank * 0x10000 + Int(offset)
            if index < storage.count {
                // Programming can only clear bits; setting them needs an erase.
                storage[index] &= value
                isDirty = true
            }
            writeArmed = false
            phase = .ready
            return
        }

        if bankSwitchArmed {
            if offset == 0 {
                bank = Int(value & 1)
            }
            bankSwitchArmed = false
            phase = .ready
            return
        }

        switch phase {
        case .ready:
            if offset == 0x5555 && value == 0xAA { phase = .unlock1 }

        case .unlock1:
            if offset == 0x2AAA && value == 0x55 {
                phase = eraseArmed ? .eraseUnlock2 : .unlock2
            } else {
                phase = .ready
            }

        case .unlock2:
            guard offset == 0x5555 else { phase = .ready; return }
            switch value {
            case 0x90:  // enter ID mode
                idMode = true
                phase = .ready
            case 0xF0:  // leave ID mode
                idMode = false
                phase = .ready
            case 0x80:  // erase command prefix — needs a second unlock round
                eraseArmed = true
                phase = .ready
            case 0xA0:  // program one byte
                writeArmed = true
            case 0xB0:  // select 64 KB bank, 128 KB devices only
                bankSwitchArmed = true
            default:
                phase = .ready
            }

        case .eraseUnlock2:
            if value == 0x10 && offset == 0x5555 {
                // Chip erase.
                for i in storage.indices { storage[i] = 0xFF }
                isDirty = true
            } else if value == 0x30 {
                // Sector erase: 4 KB containing this address.
                let sectorBase = bank * 0x10000 + Int(offset & 0xF000)
                for i in sectorBase..<min(sectorBase + 0x1000, storage.count) {
                    storage[i] = 0xFF
                }
                isDirty = true
            }
            eraseArmed = false
            phase = .ready

        case .eraseUnlock1:
            phase = .ready
        }
    }

    var data: [UInt8] { storage }

    func load(_ bytes: [UInt8]) {
        for i in 0..<min(bytes.count, storage.count) { storage[i] = bytes[i] }
        isDirty = false
    }
}

/// Serial EEPROM. Emerald doesn't use it, but detection can land here for other
/// cartridges, so the bus has something valid to talk to.
final class EEPROMBackup: BackupMedium {
    private var storage: [UInt8]
    var isDirty = false

    init(size: Int) {
        storage = [UInt8](repeating: 0xFF, count: max(size, 512))
    }

    // The real device is a bit-serial protocol over the DMA bus. Emerald never
    // reaches this path, so it is left as a stub that reads back as erased
    // rather than a half-correct implementation that would silently corrupt.
    func read(_ address: UInt32) -> UInt8 { 1 }
    func write(_ address: UInt32, _ value: UInt8) {}

    var data: [UInt8] { storage }

    func load(_ bytes: [UInt8]) {
        for i in 0..<min(bytes.count, storage.count) { storage[i] = bytes[i] }
        isDirty = false
    }
}
