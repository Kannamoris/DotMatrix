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
    ///
    /// The scan checks every byte offset rather than assuming word alignment.
    /// The markers usually are aligned, but "usually" isn't good enough: a miss
    /// silently falls back to the wrong chip, and a cartridge given 64 KB when
    /// it expects 128 KB appears to save and then loses the data.
    private static func detectSaveType(in bytes: [UInt8]) -> SaveType {
        // Longest first: "FLASH1M_" and "FLASH512_" both begin with "FLASH".
        let markers: [([UInt8], SaveType)] = [
            (Array("FLASH1M_V".utf8), .flash128k),
            (Array("FLASH512_V".utf8), .flash64k),
            (Array("FLASH_V".utf8), .flash64k),
            (Array("EEPROM_V".utf8), .eeprom8k),
            (Array("SRAM_F_V".utf8), .sram),
            (Array("SRAM_V".utf8), .sram),
        ]

        // One pass over the ROM rather than one per marker. Every marker starts
        // with F, E or S, so the overwhelming majority of positions are
        // rejected on a single comparison.
        var candidates = Set<UInt8>()
        for (marker, _) in markers { candidates.insert(marker[0]) }

        let longest = markers.map { $0.0.count }.max() ?? 0
        guard bytes.count >= longest else { return .flash64k }
        let limit = bytes.count - longest

        var best: SaveType?

        bytes.withUnsafeBufferPointer { buffer in
            var index = 0
            while index <= limit {
                let byte = buffer[index]
                if candidates.contains(byte) {
                    for (marker, type) in markers where marker[0] == byte {
                        var matched = true
                        for offset in 1..<marker.count {
                            if buffer[index + offset] != marker[offset] {
                                matched = false
                                break
                            }
                        }
                        if matched {
                            best = type
                            return
                        }
                    }
                }
                index += 1
            }
        }

        if let best { return best }

        // Nothing found. 64 KB flash is the most common configuration, and a
        // too-large buffer is harmless where a too-small one truncates saves.
        return .flash64k
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

    /// Advance the medium's own clock. Programming and erasing flash take real
    /// time on the chip, and drivers watch for the busy signal that implies.
    func advance(_ cycles: Int)

    func encodeState(into w: inout StateWriter)
    func decodeState(from r: inout StateReader) throws
}

/// Plain battery-backed static RAM. Directly addressable, no protocol.
final class SRAMBackup: BackupMedium {
    private(set) var storage: [UInt8]
    var isDirty = false

    func advance(_ cycles: Int) {}

    func encodeState(into w: inout StateWriter) {
        w.mark("SRAM"); w.write(storage)
    }

    func decodeState(from r: inout StateReader) throws {
        try r.expect("SRAM"); storage = try r.readBytes()
    }

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

    /// Programming and erasing are not instantaneous on real hardware, and a
    /// driver waits to observe the chip go busy before waiting for it to
    /// finish. Completing immediately means that busy state never appears and
    /// the wait never ends.
    private var busyCyclesRemaining = 0
    /// Which 4 KB sector is settling; reads elsewhere are unaffected.
    private var settlingSector = -1

    private enum Timing {
        static let program = 650
        static let erase = 30_000
    }

    func advance(_ cycles: Int) {
        guard busyCyclesRemaining > 0 else { return }
        busyCyclesRemaining -= cycles
        if busyCyclesRemaining <= 0 {
            busyCyclesRemaining = 0
            settlingSector = -1
        }
    }

    func encodeState(into w: inout StateWriter) {
        w.mark("FLSH")
        w.write(storage)
        w.write(bank); w.write(idMode); w.write(eraseArmed)
        w.write(writeArmed); w.write(bankSwitchArmed)
        w.write(phaseCode); w.write(busyCyclesRemaining); w.write(settlingSector)
    }

    func decodeState(from r: inout StateReader) throws {
        try r.expect("FLSH")
        storage = try r.readBytes()
        bank = try r.readInt(); idMode = try r.readBool(); eraseArmed = try r.readBool()
        writeArmed = try r.readBool(); bankSwitchArmed = try r.readBool()
        phaseCode = try r.readInt()
        busyCyclesRemaining = try r.readInt(); settlingSector = try r.readInt()
    }

    /// The command phase as a plain integer, so the snapshot has no dependency
    /// on the enum's declaration order.
    private var phaseCode: Int {
        get {
            switch phase {
            case .ready: return 0
            case .unlock1: return 1
            case .unlock2: return 2
            case .eraseUnlock1: return 3
            case .eraseUnlock2: return 4
            }
        }
        set {
            switch newValue {
            case 1: phase = .unlock1
            case 2: phase = .unlock2
            case 3: phase = .eraseUnlock1
            case 4: phase = .eraseUnlock2
            default: phase = .ready
            }
        }
    }

    private func beginOperation(sector: Int, cycles: Int) {
        settlingSector = sector
        busyCyclesRemaining = cycles
    }

    /// Macronix 128 KB device. Emerald reads these two bytes to size the chip,
    /// and reporting the wrong pair makes it refuse to save.
    private let manufacturerID: UInt8
    private let deviceID: UInt8

    init(size: Int) {
        self.size = size
        self.storage = [UInt8](repeating: 0xFF, count: size)
        if size > 64 * 1024 {
            // Sanyo LE26FV10N1TS, the 128 KB part these games expect.
            self.manufacturerID = 0x62
            self.deviceID = 0x13
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

        // While the sector is settling the chip reports progress rather than
        // data: bit 7 reads back inverted until the operation completes.
        if busyCyclesRemaining > 0, (offset >> 12) == settlingSector {
            return (storage[index] ^ 0x80) & 0x80
        }
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
                // Programming does not mark the sector busy. A byte written
                // here is expected to read back immediately, and reporting
                // busy for it breaks that.
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
                beginOperation(sector: 0, cycles: Timing.erase)
            } else if value == 0x30 {
                // Sector erase: 4 KB containing this address.
                let sectorBase = bank * 0x10000 + Int(offset & 0xF000)
                for i in sectorBase..<min(sectorBase + 0x1000, storage.count) {
                    storage[i] = 0xFF
                }
                isDirty = true
                beginOperation(sector: Int(offset) >> 12, cycles: Timing.erase)
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

    func advance(_ cycles: Int) {}

    func encodeState(into w: inout StateWriter) {
        w.mark("EEPR"); w.write(storage)
    }

    func decodeState(from r: inout StateReader) throws {
        try r.expect("EEPR"); storage = try r.readBytes()
    }

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
