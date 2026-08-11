import Foundation

/// Errors surfaced when a user-supplied ROM file cannot be interpreted.
enum CartridgeError: LocalizedError {
    case fileTooSmall(Int)
    case truncatedHeader
    case unsupportedMapper(UInt8)
    case sizeMismatch(declared: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .fileTooSmall(let n):
            return "This file is only \(n) bytes. A Game Boy ROM is at least 32 KB."
        case .truncatedHeader:
            return "The cartridge header is incomplete. The file may be corrupt or not a Game Boy ROM."
        case .unsupportedMapper(let id):
            return String(format: "Unsupported cartridge mapper (type 0x%02X).", id)
        case .sizeMismatch(let declared, let actual):
            return "The header declares \(declared) bytes of ROM but the file holds \(actual)."
        }
    }
}

/// Which hardware the cartridge header asks for.
enum ColorSupport {
    /// Original monochrome Game Boy only.
    case dmgOnly
    /// Runs on both, with colour enhancements on a CGB.
    case cgbCompatible
    /// Refuses to boot on a monochrome Game Boy.
    case cgbOnly
}

/// A parsed, user-supplied ROM image plus its mapper.
///
/// This type holds no game content of its own — every byte comes from the file
/// the user imported.
final class Cartridge {
    let rom: [UInt8]
    let mbc: MemoryBankController

    let title: String
    let mapperName: String
    let colorSupport: ColorSupport
    let romBankCount: Int
    let ramByteCount: Int
    let hasBattery: Bool

    /// Stable identity for save files, derived from the header rather than the
    /// filename so a renamed ROM keeps its save.
    let contentID: String

    init(data: Data) throws {
        guard data.count >= 0x8000 else { throw CartridgeError.fileTooSmall(data.count) }
        guard data.count > 0x014F else { throw CartridgeError.truncatedHeader }

        let bytes = [UInt8](data)
        self.rom = bytes

        // 0x0134...0x0143 is the title field. On later cartridges the tail of it
        // was repurposed for the CGB flag and manufacturer code, so stop at the
        // first NUL and drop anything non-printable.
        let titleBytes = bytes[0x0134...0x0142].prefix { $0 != 0 }
        self.title = String(decoding: titleBytes.filter { (0x20...0x7E).contains($0) }, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)

        switch bytes[0x0143] {
        case 0x80: self.colorSupport = .cgbCompatible
        case 0xC0: self.colorSupport = .cgbOnly
        default:   self.colorSupport = .dmgOnly
        }

        let cartType = bytes[0x0147]

        // Header ROM size is `32KB << n`. Trust the file over the header if they
        // disagree — dumps are sometimes padded, and a wrong bank count is fatal
        // whereas extra bytes are harmless.
        let declaredROM = 0x8000 << Int(bytes[0x0148])
        if declaredROM > bytes.count {
            throw CartridgeError.sizeMismatch(declared: declaredROM, actual: bytes.count)
        }
        self.romBankCount = max(2, bytes.count / 0x4000)

        // MBC2 has 512 nibbles of RAM built into the mapper and reports 0 here.
        let ramSize: Int
        if cartType == 0x05 || cartType == 0x06 {
            ramSize = 512
        } else {
            switch bytes[0x0149] {
            case 0x02: ramSize = 0x2000        // 1 bank
            case 0x03: ramSize = 0x8000        // 4 banks
            case 0x04: ramSize = 0x20000       // 16 banks
            case 0x05: ramSize = 0x10000       // 8 banks
            default:   ramSize = 0
            }
        }
        self.ramByteCount = ramSize

        switch cartType {
        case 0x00, 0x08, 0x09:
            self.mbc = NoMBC(rom: bytes, ramSize: ramSize)
            self.mapperName = "ROM"
        case 0x01, 0x02, 0x03:
            self.mbc = MBC1(rom: bytes, ramSize: ramSize)
            self.mapperName = "MBC1"
        case 0x05, 0x06:
            self.mbc = MBC2(rom: bytes)
            self.mapperName = "MBC2"
        case 0x0F, 0x10, 0x11, 0x12, 0x13:
            let rtc = (cartType == 0x0F || cartType == 0x10)
            self.mbc = MBC3(rom: bytes, ramSize: ramSize, hasRTC: rtc)
            self.mapperName = rtc ? "MBC3+RTC" : "MBC3"
        case 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E:
            self.mbc = MBC5(rom: bytes, ramSize: ramSize)
            self.mapperName = "MBC5"
        default:
            throw CartridgeError.unsupportedMapper(cartType)
        }

        // Battery-backed types are the ones that persist SRAM across power-off.
        self.hasBattery = [0x03, 0x06, 0x09, 0x0F, 0x10, 0x13, 0x1B, 0x1E].contains(cartType)
        self.mbc.hasBattery = self.hasBattery

        // Header checksum + global checksum + title gives a collision-resistant
        // identity without hashing the whole (multi-MB) file.
        let global = (UInt16(bytes[0x014E]) << 8) | UInt16(bytes[0x014F])
        self.contentID = String(
            format: "%@-%02X%04X-%X",
            self.title.isEmpty ? "UNTITLED" : self.title,
            bytes[0x014D], global, bytes.count
        ).replacingOccurrences(of: "/", with: "_")
    }

    /// True when the header checksum matches, i.e. the dump is intact.
    /// A mismatch is reported but not treated as fatal — some homebrew skips it.
    var headerChecksumValid: Bool {
        var sum: UInt8 = 0
        for addr in 0x0134...0x014C {
            sum = sum &- rom[addr] &- 1
        }
        return sum == rom[0x014D]
    }

    /// Battery-backed SRAM, for writing to disk.
    var batteryRAM: [UInt8] {
        get { mbc.ram }
        set { mbc.loadRAM(newValue) }
    }
}
