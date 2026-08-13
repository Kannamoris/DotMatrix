import Foundation

/// The parts of a GBA cartridge header the library needs, read straight from
/// the file.
///
/// The emulator core does its own parsing; this exists only so a ROM can be
/// identified and rejected before a core is ever created.
struct CartridgeHeader {
    /// Game code of Pokémon Emerald, at offset 0x0AC.
    static let emeraldGameCode = "BPEE"

    let title: String
    let gameCode: String
    let saveType: String
    let byteCount: Int

    var isPokemonEmerald: Bool { gameCode == Self.emeraldGameCode }

    /// Stable identity for save and snapshot filenames, so renaming the ROM
    /// doesn't orphan them.
    var contentID: String {
        "\(gameCode.isEmpty ? "UNKNOWN" : gameCode)-\(byteCount)"
    }

    enum ParseError: LocalizedError {
        case tooSmall(Int)
        case notPokemonEmerald(title: String, code: String)

        var errorDescription: String? {
            switch self {
            case .tooSmall(let n):
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

    init(data: Data, requireEmerald: Bool) throws {
        guard data.count >= 0xC0 else { throw ParseError.tooSmall(data.count) }
        let bytes = [UInt8](data.prefix(0x100))

        func text(_ range: ClosedRange<Int>) -> String {
            String(decoding: bytes[range].prefix { $0 != 0 }
                .filter { (0x20...0x7E).contains($0) }, as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
        }

        self.title = text(0x0A0...0x0AB)
        self.gameCode = text(0x0AC...0x0AF)
        self.byteCount = data.count

        if requireEmerald && gameCode != Self.emeraldGameCode {
            throw ParseError.notPokemonEmerald(title: title, code: gameCode)
        }

        // The toolchain leaves a marker naming the save hardware; nothing in
        // the header records it. Purely cosmetic here — the core detects it
        // for itself.
        self.saveType = Self.detectSaveType(in: data)
    }

    private static func detectSaveType(in data: Data) -> String {
        let markers: [(String, String)] = [
            ("FLASH1M_V", "Flash 128K"),
            ("FLASH512_V", "Flash 64K"),
            ("FLASH_V", "Flash 64K"),
            ("EEPROM_V", "EEPROM"),
            ("SRAM_V", "SRAM 32K"),
        ]
        let bytes = [UInt8](data)
        for (marker, name) in markers {
            if find(Array(marker.utf8), in: bytes) { return name }
        }
        return "Unknown"
    }

    private static func find(_ marker: [UInt8], in bytes: [UInt8]) -> Bool {
        guard bytes.count >= marker.count, let first = marker.first else { return false }
        let limit = bytes.count - marker.count
        return bytes.withUnsafeBufferPointer { buffer -> Bool in
            var index = 0
            while index <= limit {
                if buffer[index] == first {
                    var matched = true
                    for offset in 1..<marker.count where buffer[index + offset] != marker[offset] {
                        matched = false
                        break
                    }
                    if matched { return true }
                }
                index += 1
            }
            return false
        }
    }
}
