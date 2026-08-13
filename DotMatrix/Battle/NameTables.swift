import SwiftUI

/// Looks up move names in the loaded cartridge.
///
/// Nothing is stored in the app. The tables live in the user's ROM, are read on
/// demand, and are cached only for the lifetime of the session. Until the table
/// address is confirmed this returns nil and callers fall back to showing the
/// numeric identifier, which is honest rather than wrong.
final class MoveNameCache {
    static let shared = MoveNameCache()

    /// Set once a cartridge is loaded and the table location is verified.
    private var reader: CartridgeTextReader?
    private var cache: [Int: String] = [:]

    private init() {}

    func attach(_ reader: CartridgeTextReader?) {
        self.reader = reader
        cache.removeAll()
    }

    func name(for moveID: Int) -> String? {
        if let cached = cache[moveID] { return cached }
        guard let reader, let name = reader.moveName(moveID) else { return nil }
        cache[moveID] = name
        return name
    }
}

/// Type names and the colours used to tint them.
///
/// The names come from the cartridge; the colours are this app's own choice and
/// exist so a move's type is readable at a glance on a small control.
final class TypeNameCache {
    static let shared = TypeNameCache()

    private var reader: CartridgeTextReader?
    private var cache: [Int: String] = [:]

    private init() {}

    func attach(_ reader: CartridgeTextReader?) {
        self.reader = reader
        cache.removeAll()
    }

    func name(for type: Int) -> String? {
        if let cached = cache[type] { return cached }
        guard let reader, let name = reader.typeName(type) else { return nil }
        cache[type] = name
        return name
    }

    /// Chosen here, not derived from the game.
    func colour(for type: Int) -> Color {
        switch type {
        case 0:  return .gray        // normal
        case 1:  return .orange      // fighting
        case 2:  return .indigo      // flying
        case 3:  return .purple      // poison
        case 4:  return .brown       // ground
        case 5:  return Color(red: 0.72, green: 0.63, blue: 0.44)  // rock
        case 6:  return .mint        // bug
        case 7:  return Color(red: 0.45, green: 0.35, blue: 0.60)  // ghost
        case 8:  return Color(red: 0.72, green: 0.72, blue: 0.80)  // steel
        case 10: return .red         // fire
        case 11: return .blue        // water
        case 12: return .green       // grass
        case 13: return .yellow      // electric
        case 14: return .pink        // psychic
        case 15: return .cyan        // ice
        case 16: return Color(red: 0.44, green: 0.34, blue: 0.78)  // dragon
        case 17: return Color(red: 0.35, green: 0.32, blue: 0.36)  // dark
        default: return .secondary
        }
    }
}

/// Decodes strings out of the cartridge.
///
/// Gen 3 stores text in its own single-byte encoding rather than ASCII, ended
/// by a terminator byte. The mapping is a property of the ROM's data format,
/// so decoding is done here and no game text is carried in the app.
struct CartridgeTextReader {
    private let core: any EmulatorCore

    /// Table locations within the ROM. Left unset until confirmed against the
    /// cartridge — a wrong offset yields plausible-looking nonsense, which is
    /// worse than showing an identifier.
    struct TableAddresses {
        var moveNames: UInt32
        var moveNameStride: Int
        var typeNames: UInt32
        var typeNameStride: Int
    }

    /// gMoveNames / gTypeNames, from EmeraldRecomp's byte-matched ROM symbol
    /// table (built directly from the decompiled ELF, cross-checked against
    /// the retail ROM). Strides are MOVE_NAME_LENGTH/TYPE_NAME_LENGTH + 1
    /// terminator byte, straight from include/constants/global.h.
    static let verified = TableAddresses(
        moveNames: 0x0831_977C,
        moveNameStride: 13,
        typeNames: 0x0831_AE38,
        typeNameStride: 7
    )

    var tables: TableAddresses?

    init(core: any EmulatorCore, tables: TableAddresses? = nil) {
        self.core = core
        self.tables = tables
    }

    func moveName(_ moveID: Int) -> String? {
        guard let tables, moveID >= 0 else { return nil }
        let address = tables.moveNames &+ UInt32(moveID * tables.moveNameStride)
        return decodeString(at: address, maxLength: tables.moveNameStride)
    }

    func typeName(_ type: Int) -> String? {
        guard let tables, type >= 0 else { return nil }
        let address = tables.typeNames &+ UInt32(type * tables.typeNameStride)
        return decodeString(at: address, maxLength: tables.typeNameStride)
    }

    /// Translate the cartridge's character set into Unicode.
    private func decodeString(at address: UInt32, maxLength: Int) -> String? {
        let bytes = core.readMemory(address, count: maxLength)
        guard !bytes.isEmpty else { return nil }

        var result = ""
        for byte in bytes {
            // 0xFF terminates a string in this format.
            if byte == 0xFF { break }
            guard let character = Self.characterMap[byte] else { continue }
            result.append(character)
        }
        return result.isEmpty ? nil : result
    }

    /// The subset of the cartridge's character set that appears in names:
    /// space, digits, letters and a few punctuation marks. This is a format
    /// mapping, not content.
    private static let characterMap: [UInt8: Character] = {
        var map: [UInt8: Character] = [0x00: " "]
        // Digits occupy a contiguous run.
        for i in 0..<10 {
            map[UInt8(0xA1 + i)] = Character(String(i))
        }
        // Then upper case, then lower case, each contiguous.
        for i in 0..<26 {
            map[UInt8(0xBB + i)] = Character(UnicodeScalar(UInt8(65 + i)))
            map[UInt8(0xD5 + i)] = Character(UnicodeScalar(UInt8(97 + i)))
        }
        map[0xAB] = "!"
        map[0xAC] = "?"
        map[0xAD] = "."
        map[0xAE] = "-"
        map[0xBA] = "/"
        map[0xB8] = ","
        map[0xB0] = "…"
        map[0xE7] = "'"
        return map
    }()
}
