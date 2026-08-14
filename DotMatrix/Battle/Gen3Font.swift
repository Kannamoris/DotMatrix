import Foundation

/// Decodes Pokémon Emerald's own "Normal" menu/dialogue font (FONT_NORMAL)
/// out of ROM, so the battle UI can draw text with the game's real glyph
/// shapes instead of the system font.
///
/// Every constant here is transcribed directly from pret/pokeemerald's
/// src/text.c — `sFontHalfRowOffsets` is copied verbatim (it's a `static
/// const` ROM table, identical on the retail cartridge), and
/// `halfRowLookupTable` reproduces `GenerateFontHalfRowLookupTable` exactly:
/// a pure function of the three FONT_NORMAL palette-index constants
/// (fgColor=2, bgColor=1, shadowColor=3, from `sFontInfos[FONT_NORMAL]`),
/// not something read from RAM or guessed. The only runtime memory read is
/// the glyph pixel data itself (`gFontNormalLatinGlyphs`), at a ROM address
/// cross-checked against EmeraldRecomp's byte-matched symbol table the same
/// way as the battle-state addresses.
enum Gen3Font {
    /// One decoded glyph: a width x 15 grid of pixel classes, row-major.
    struct Glyph {
        var width: Int
        var height: Int
        var pixels: [PixelClass]

        func pixelClass(x: Int, y: Int) -> PixelClass {
            guard x >= 0, x < width, y >= 0, y < height else { return .background }
            return pixels[y * width + x]
        }
    }

    enum PixelClass {
        case background
        case foreground
        case shadow
    }

    /// gFontNormalLatinGlyphs / gFontNormalLatinGlyphWidths, from
    /// EmeraldRecomp's byte-matched ROM symbol table.
    private static let glyphsAddress: UInt32 = 0x0864_C2E4
    private static let glyphWidthsAddress: UInt32 = 0x0865_42E4
    /// DecompressGlyph_Normal: `gFontNormalLatinGlyphs + (0x20 * glyphId)`,
    /// where the source pointer is `const u16 *` — 0x20 u16 elements, so 0x40
    /// bytes per glyph slot.
    private static let glyphStride = 0x40
    /// DecompressGlyph_Normal: `gCurGlyph.height = 15`.
    static let height = 15

    /// Decode the glyph for one Gen 3 character byte (see Gen3Text's
    /// character map for what these bytes mean).
    static func glyph(for characterByte: UInt8, core: any EmulatorCore) -> Glyph? {
        let glyphID = Int(characterByte)
        let widthBytes = core.readMemory(glyphWidthsAddress + UInt32(glyphID), count: 1)
        guard let width = widthBytes.first, width > 0 else { return nil }

        let slot = core.readMemory(glyphsAddress + UInt32(glyphID * glyphStride), count: glyphStride)
        guard slot.count == glyphStride else { return nil }

        var pixels = [PixelClass](repeating: .background, count: Int(width) * height)

        // DecompressGlyph_Normal: <=8px wide uses only the tile at +0x00 (top)
        // and +0x20 (bottom, since +0x10 is in u16 units = 0x20 bytes); wider
        // glyphs additionally use +0x10 (top-right) and +0x30 (bottom-right).
        decodeTile(slot, byteOffset: 0x00, intoX: 0, intoY: 0, width: Int(width), pixels: &pixels)
        decodeTile(slot, byteOffset: 0x20, intoX: 0, intoY: 8, width: Int(width), pixels: &pixels)
        if width > 8 {
            decodeTile(slot, byteOffset: 0x10, intoX: 8, intoY: 0, width: Int(width), pixels: &pixels)
            decodeTile(slot, byteOffset: 0x30, intoX: 8, intoY: 8, width: Int(width), pixels: &pixels)
        }

        return Glyph(width: Int(width), height: height, pixels: pixels)
    }

    /// DecompressGlyphTile: 8 rows, 2 source bytes each (one per half-row),
    /// each byte mapped through sFontHalfRowOffsets into a 4-pixel pattern
    /// from halfRowLookupTable. Writes into an 8-wide region of `pixels`
    /// starting at (intoX, intoY); the bottom tile only contributes 7 rows
    /// (15 - 8), the 8th silently discarded, matching gCurGlyph's height.
    private static func decodeTile(
        _ slot: [UInt8], byteOffset: Int, intoX: Int, intoY: Int, width: Int, pixels: inout [PixelClass]
    ) {
        for row in 0..<8 {
            let y = intoY + row
            guard y < height else { break }

            // temp = byte[A] | (byte[A+1] << 8) on little-endian, so
            // temp & 0xFF = the first byte in memory, temp >> 8 = the second.
            let byteA = slot[byteOffset + row * 2]
            let byteAPlus1 = slot[byteOffset + row * 2 + 1]
            // DecompressGlyphTile: dest = (lookup(byte[A]) << 16) | lookup(byte[A+1]).
            // Standard GBA 4bpp packing has the lowest bits as the leftmost
            // pixel, so the low 16 bits (lookup(byte[A+1])) are the left 4
            // pixels of this row, the high 16 (lookup(byte[A])) the right 4 —
            // and within each 16-bit half, the same rule nests one level
            // down: bits[0:4) is that half's own leftmost pixel.
            let leftHalf = halfRow(byteAPlus1)
            let rightHalf = halfRow(byteA)

            for pixel in 0..<4 {
                setPixel(&pixels, x: intoX + pixel, y: y, width: width,
                         nibble: (leftHalf >> (pixel * 4)) & 0xF)
                setPixel(&pixels, x: intoX + 4 + pixel, y: y, width: width,
                         nibble: (rightHalf >> (pixel * 4)) & 0xF)
            }
        }
    }

    private static func setPixel(_ pixels: inout [PixelClass], x: Int, y: Int, width: Int, nibble: UInt16) {
        guard x < width else { return }
        let index = y * width + x
        guard index < pixels.count else { return }
        switch nibble {
        case UInt16(fgColor): pixels[index] = .foreground
        case UInt16(shadowColor): pixels[index] = .shadow
        default: pixels[index] = .background
        }
    }

    private static func halfRow(_ byte: UInt8) -> UInt16 {
        let offset = sFontHalfRowOffsets[Int(byte)]
        return halfRowLookupTable[Int(offset)]
    }

    // MARK: FONT_NORMAL palette indices (sFontInfos[FONT_NORMAL], src/text.c)

    private static let fgColor: UInt8 = 2
    private static let bgColor: UInt8 = 1
    private static let shadowColor: UInt8 = 3

    /// GenerateFontHalfRowLookupTable(fgColor: 2, bgColor: 1, shadowColor: 3),
    /// reproduced exactly: for z, y, x each ranging over [bg, fg, shadow] (z
    /// outermost, x innermost), emit bg12|temp, fg12|temp, shadow12|temp
    /// where temp = (x<<8)|(y<<4)|z. 3*3*3*3 = 81 entries.
    private static let halfRowLookupTable: [UInt16] = {
        let classes: [UInt16] = [UInt16(bgColor), UInt16(fgColor), UInt16(shadowColor)]
        let bg12 = UInt16(bgColor) << 12
        let fg12 = UInt16(fgColor) << 12
        let shadow12 = UInt16(shadowColor) << 12

        var table: [UInt16] = []
        table.reserveCapacity(81)
        for z in classes {
            for y in classes {
                for x in classes {
                    let temp = (x << 8) | (y << 4) | z
                    table.append(bg12 | temp)
                    table.append(fg12 | temp)
                    table.append(shadow12 | temp)
                }
            }
        }
        return table
    }()

    /// sFontHalfRowOffsets, src/text.c — transcribed verbatim.
    private static let sFontHalfRowOffsets: [UInt8] = [
        0x00, 0x01, 0x02, 0x00, 0x03, 0x04, 0x05, 0x03, 0x06, 0x07, 0x08, 0x06, 0x00, 0x01, 0x02, 0x00,
        0x09, 0x0A, 0x0B, 0x09, 0x0C, 0x0D, 0x0E, 0x0C, 0x0F, 0x10, 0x11, 0x0F, 0x09, 0x0A, 0x0B, 0x09,
        0x12, 0x13, 0x14, 0x12, 0x15, 0x16, 0x17, 0x15, 0x18, 0x19, 0x1A, 0x18, 0x12, 0x13, 0x14, 0x12,
        0x00, 0x01, 0x02, 0x00, 0x03, 0x04, 0x05, 0x03, 0x06, 0x07, 0x08, 0x06, 0x00, 0x01, 0x02, 0x00,
        0x1B, 0x1C, 0x1D, 0x1B, 0x1E, 0x1F, 0x20, 0x1E, 0x21, 0x22, 0x23, 0x21, 0x1B, 0x1C, 0x1D, 0x1B,
        0x24, 0x25, 0x26, 0x24, 0x27, 0x28, 0x29, 0x27, 0x2A, 0x2B, 0x2C, 0x2A, 0x24, 0x25, 0x26, 0x24,
        0x2D, 0x2E, 0x2F, 0x2D, 0x30, 0x31, 0x32, 0x30, 0x33, 0x34, 0x35, 0x33, 0x2D, 0x2E, 0x2F, 0x2D,
        0x1B, 0x1C, 0x1D, 0x1B, 0x1E, 0x1F, 0x20, 0x1E, 0x21, 0x22, 0x23, 0x21, 0x1B, 0x1C, 0x1D, 0x1B,
        0x36, 0x37, 0x38, 0x36, 0x39, 0x3A, 0x3B, 0x39, 0x3C, 0x3D, 0x3E, 0x3C, 0x36, 0x37, 0x38, 0x36,
        0x3F, 0x40, 0x41, 0x3F, 0x42, 0x43, 0x44, 0x42, 0x45, 0x46, 0x47, 0x45, 0x3F, 0x40, 0x41, 0x3F,
        0x48, 0x49, 0x4A, 0x48, 0x4B, 0x4C, 0x4D, 0x4B, 0x4E, 0x4F, 0x50, 0x4E, 0x48, 0x49, 0x4A, 0x48,
        0x36, 0x37, 0x38, 0x36, 0x39, 0x3A, 0x3B, 0x39, 0x3C, 0x3D, 0x3E, 0x3C, 0x36, 0x37, 0x38, 0x36,
        0x00, 0x01, 0x02, 0x00, 0x03, 0x04, 0x05, 0x03, 0x06, 0x07, 0x08, 0x06, 0x00, 0x01, 0x02, 0x00,
        0x09, 0x0A, 0x0B, 0x09, 0x0C, 0x0D, 0x0E, 0x0C, 0x0F, 0x10, 0x11, 0x0F, 0x09, 0x0A, 0x0B, 0x09,
        0x12, 0x13, 0x14, 0x12, 0x15, 0x16, 0x17, 0x15, 0x18, 0x19, 0x1A, 0x18, 0x12, 0x13, 0x14, 0x12,
        0x00, 0x01, 0x02, 0x00, 0x03, 0x04, 0x05, 0x03, 0x06, 0x07, 0x08, 0x06, 0x00, 0x01, 0x02, 0x00,
    ]
}

/// Caches decoded glyphs for a session's lifetime. Decoding needs a live
/// `core` (it's a ROM read), so this follows the same attach-per-session
/// pattern as MoveNameCache/TypeNameCache.
final class Gen3FontCache {
    static let shared = Gen3FontCache()

    private var core: (any EmulatorCore)?
    private var cache: [UInt8: Gen3Font.Glyph] = [:]

    private init() {}

    func attach(_ core: (any EmulatorCore)?) {
        self.core = core
        cache.removeAll()
    }

    /// Decoded glyphs for the given text, one per recognized character
    /// (unrecognized characters — anything outside Gen3Text's mapping — are
    /// silently dropped rather than shown as a placeholder box, since a
    /// missing letter is more honest than a wrong one).
    func glyphs(for text: String) -> [Gen3Font.Glyph] {
        guard let core else { return [] }
        return text.compactMap { character in
            guard let byte = Gen3Text.byte(for: character) else { return nil }
            if let cached = cache[byte] { return cached }
            let glyph = Gen3Font.glyph(for: byte, core: core)
            cache[byte] = glyph
            return glyph
        }
    }
}
