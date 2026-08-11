import Foundation

/// The picture processing unit.
///
/// Rendering is done a whole scanline at a time, at the point the real hardware
/// would enter mode 3. That is not enough for effects that change registers
/// *within* a line, but it is exact for the far more common mid-frame changes
/// (status bars, parallax, window reveals) that games actually rely on, and it
/// is dramatically cheaper than a pixel FIFO.
final class PPU {
    static let width = 160
    static let height = 144

    /// Finished frame, 0xAARRGGBB per pixel — byte order matches `.bgra8Unorm`.
    private(set) var framebuffer = [UInt32](repeating: 0xFFFFFFFF, count: width * height)

    /// Raised for one step when the last scanline of the frame completes.
    private(set) var frameComplete = false
    /// Raised on each entry into HBlank, so HDMA can advance.
    private(set) var enteredHBlank = false

    var vram = [UInt8](repeating: 0, count: 0x4000)   // two 8 KB banks
    var oam = [UInt8](repeating: 0, count: 0xA0)

    var vramBank: Int = 0
    let isCGB: Bool

    // MARK: Registers

    var lcdc: UInt8 = 0x91
    var scy: UInt8 = 0
    var scx: UInt8 = 0
    var lyc: UInt8 = 0
    var bgp: UInt8 = 0xFC
    var obp0: UInt8 = 0xFF
    var obp1: UInt8 = 0xFF
    var wy: UInt8 = 0
    var wx: UInt8 = 0

    private(set) var ly: UInt8 = 0
    private var statEnables: UInt8 = 0     // bits 3-6 of STAT
    private(set) var mode: UInt8 = 2

    var vblankInterruptRequested = false
    var statInterruptRequested = false

    // CGB palette memory: 8 palettes x 4 colours x 2 bytes.
    var bgPaletteRAM = [UInt8](repeating: 0xFF, count: 64)
    var objPaletteRAM = [UInt8](repeating: 0xFF, count: 64)
    var bgPaletteIndex: UInt8 = 0
    var objPaletteIndex: UInt8 = 0

    /// CGB "compatibility" palettes, used when a DMG game runs on CGB hardware.
    /// Left at the boot ROM's greyscale defaults here.
    private var dmgShades: [UInt32] = [0xFFE0F8D0, 0xFF88C070, 0xFF346856, 0xFF081820]

    // MARK: Internal timing

    private var dot: Int = 0
    /// Counts only the lines the window actually drew on, which is what the
    /// hardware uses to index into the window tile map.
    private var windowLine: Int = 0
    private var windowWasVisibleThisFrame = false
    private var statLine = false

    /// Per-pixel bookkeeping for the current scanline, so sprites can resolve
    /// priority against the background without re-reading tile data.
    private var lineBGColorIndex = [UInt8](repeating: 0, count: width)
    private var lineBGPriority = [Bool](repeating: false, count: width)

    init(isCGB: Bool) {
        self.isCGB = isCGB
    }

    /// Swap in a palette for a monochrome game. `shades` is lightest to darkest.
    func setMonochromePalette(_ shades: [UInt32]) {
        guard shades.count == 4 else { return }
        dmgShades = shades
    }

    // MARK: Register access

    var stat: UInt8 {
        get {
            var v = statEnables & 0x78
            if ly == lyc { v |= 0x04 }
            v |= (lcdEnabled ? mode : 0) & 0x03
            return v | 0x80
        }
        set {
            statEnables = newValue & 0x78
            updateSTATLine()
        }
    }

    private var lcdEnabled: Bool { lcdc & 0x80 != 0 }

    func writeLCDC(_ value: UInt8) {
        let wasEnabled = lcdEnabled
        lcdc = value
        if wasEnabled && !lcdEnabled {
            // Turning the LCD off resets the sequencer and blanks the panel.
            ly = 0
            dot = 0
            mode = 0
            windowLine = 0
            let white = isCGB ? 0xFFFFFFFF : dmgShades[0]
            for i in framebuffer.indices { framebuffer[i] = white }
            frameComplete = true
            updateSTATLine()
        } else if !wasEnabled && lcdEnabled {
            dot = 0
            ly = 0
            mode = 2
            windowLine = 0
            updateSTATLine()
        }
    }

    // MARK: Stepping

    /// Advance the dot clock by `cycles` T-cycles.
    func tick(_ cycles: Int) {
        frameComplete = false
        enteredHBlank = false
        guard lcdEnabled else { return }

        var remaining = cycles
        while remaining > 0 {
            // Work in chunks up to the next mode boundary so long CPU
            // instructions can't overshoot a transition.
            let boundary = nextBoundary()
            let step = min(remaining, boundary - dot)
            dot += step
            remaining -= step

            if dot >= 456 {
                dot -= 456
                advanceLine()
            } else {
                updateMode()
            }
        }
    }

    private func nextBoundary() -> Int {
        if ly >= 144 { return 456 }
        if dot < 80 { return 80 }
        if dot < 80 + 172 { return 80 + 172 }
        return 456
    }

    private func advanceLine() {
        ly &+= 1

        if ly == 144 {
            mode = 1
            vblankInterruptRequested = true
            frameComplete = true
            windowLine = 0
            windowWasVisibleThisFrame = false
        } else if ly > 153 {
            ly = 0
            mode = 2
        } else if ly < 144 {
            mode = 2
        }
        updateSTATLine()
    }

    private func updateMode() {
        guard ly < 144 else { return }

        let newMode: UInt8
        if dot < 80 {
            newMode = 2
        } else if dot < 80 + 172 {
            newMode = 3
        } else {
            newMode = 0
        }

        guard newMode != mode else { return }

        // Draw once, on the 2 -> 3 transition, when all the registers the line
        // depends on have settled.
        if newMode == 3 {
            renderScanline(Int(ly))
        }
        if newMode == 0 {
            enteredHBlank = true
        }
        mode = newMode
        updateSTATLine()
    }

    /// STAT fires on the *rising edge* of the OR of its enabled sources. Games
    /// that enable several sources at once depend on not being re-triggered.
    private func updateSTATLine() {
        guard lcdEnabled else { statLine = false; return }
        var line = false
        if statEnables & 0x08 != 0 && mode == 0 { line = true }
        if statEnables & 0x10 != 0 && mode == 1 { line = true }
        if statEnables & 0x20 != 0 && mode == 2 { line = true }
        if statEnables & 0x40 != 0 && ly == lyc { line = true }

        if line && !statLine {
            statInterruptRequested = true
        }
        statLine = line
    }

    func lycChanged() {
        updateSTATLine()
    }

    // MARK: Rendering

    private func renderScanline(_ line: Int) {
        // On DMG, LCDC bit 0 blanks background and window entirely. On CGB the
        // same bit instead demotes them below sprites.
        let bgAllowed = isCGB || (lcdc & 0x01) != 0

        if bgAllowed {
            renderBackground(line)
        } else {
            let base = line * Self.width
            let white = isCGB ? 0xFFFFFFFF : dmgShades[0]
            for x in 0..<Self.width {
                framebuffer[base + x] = white
                lineBGColorIndex[x] = 0
                lineBGPriority[x] = false
            }
        }

        if lcdc & 0x02 != 0 {
            renderSprites(line)
        }
    }

    private func renderBackground(_ line: Int) {
        let windowEnabled = (lcdc & 0x20) != 0
        let winX = Int(wx) - 7
        let windowStartsOnThisLine = windowEnabled && line >= Int(wy) && winX < Self.width

        if windowStartsOnThisLine {
            windowWasVisibleThisFrame = true
        }

        let bgMapBase = (lcdc & 0x08) != 0 ? 0x1C00 : 0x1800
        let winMapBase = (lcdc & 0x40) != 0 ? 0x1C00 : 0x1800
        let signedTiles = (lcdc & 0x10) == 0

        let base = line * Self.width
        var usedWindow = false

        for x in 0..<Self.width {
            let inWindow = windowStartsOnThisLine && x >= winX
            if inWindow { usedWindow = true }

            let mapBase: Int
            let texX: Int
            let texY: Int
            if inWindow {
                mapBase = winMapBase
                texX = x - winX
                texY = windowLine
            } else {
                mapBase = bgMapBase
                texX = (Int(scx) + x) & 0xFF
                texY = (Int(scy) + line) & 0xFF
            }

            let tileCol = texX >> 3
            let tileRow = texY >> 3
            let mapIndex = mapBase + tileRow * 32 + tileCol

            let tileNumber = vram[mapIndex]
            // Tile attributes live at the same address in VRAM bank 1 on CGB.
            let attr: UInt8 = isCGB ? vram[0x2000 + mapIndex] : 0

            let tileBank = isCGB && (attr & 0x08) != 0 ? 0x2000 : 0
            let flipX = isCGB && (attr & 0x20) != 0
            let flipY = isCGB && (attr & 0x40) != 0

            let tileAddr: Int
            if signedTiles {
                tileAddr = 0x1000 + Int(Int8(bitPattern: tileNumber)) * 16
            } else {
                tileAddr = Int(tileNumber) * 16
            }

            let rowInTile = flipY ? 7 - (texY & 7) : (texY & 7)
            let lo = vram[tileBank + tileAddr + rowInTile * 2]
            let hi = vram[tileBank + tileAddr + rowInTile * 2 + 1]

            let bitIndex = flipX ? (texX & 7) : 7 - (texX & 7)
            let colorIndex = ((hi >> bitIndex) & 1) << 1 | ((lo >> bitIndex) & 1)

            lineBGColorIndex[x] = colorIndex
            // CGB attribute bit 7 puts this tile in front of sprites, unless
            // LCDC bit 0 has demoted the whole background.
            lineBGPriority[x] = isCGB && (attr & 0x80) != 0 && (lcdc & 0x01) != 0

            if isCGB {
                framebuffer[base + x] = cgbColor(
                    paletteRAM: bgPaletteRAM,
                    palette: Int(attr & 0x07),
                    index: Int(colorIndex)
                )
            } else {
                let shade = (bgp >> (colorIndex * 2)) & 0x03
                framebuffer[base + x] = dmgShades[Int(shade)]
            }
        }

        if usedWindow {
            windowLine += 1
        }
    }

    private func renderSprites(_ line: Int) {
        let spriteHeight = (lcdc & 0x04) != 0 ? 16 : 8

        // The hardware scans OAM in order and keeps at most the first ten
        // sprites that intersect this line.
        var visible: [(oamIndex: Int, x: Int, y: Int)] = []
        visible.reserveCapacity(10)
        for i in 0..<40 {
            let y = Int(oam[i * 4]) - 16
            guard line >= y && line < y + spriteHeight else { continue }
            visible.append((i, Int(oam[i * 4 + 1]) - 8, y))
            if visible.count == 10 { break }
        }

        // Draw back-to-front so the highest-priority sprite lands last.
        // On DMG the smaller X wins; on CGB it is purely the OAM index.
        if isCGB {
            visible.sort { $0.oamIndex > $1.oamIndex }
        } else {
            visible.sort { $0.x != $1.x ? $0.x > $1.x : $0.oamIndex > $1.oamIndex }
        }

        let base = line * Self.width

        for sprite in visible {
            let attrs = oam[sprite.oamIndex * 4 + 3]
            var tile = oam[sprite.oamIndex * 4 + 2]
            // In 8x16 mode the low bit of the tile number is ignored.
            if spriteHeight == 16 { tile &= 0xFE }

            let flipX = attrs & 0x20 != 0
            let flipY = attrs & 0x40 != 0
            let behindBG = attrs & 0x80 != 0

            var rowInSprite = line - sprite.y
            if flipY { rowInSprite = spriteHeight - 1 - rowInSprite }

            let bank = isCGB && (attrs & 0x08) != 0 ? 0x2000 : 0
            let tileAddr = bank + Int(tile) * 16 + rowInSprite * 2
            let lo = vram[tileAddr]
            let hi = vram[tileAddr + 1]

            for px in 0..<8 {
                let x = sprite.x + px
                guard x >= 0 && x < Self.width else { continue }

                let bitIndex = flipX ? px : 7 - px
                let colorIndex = ((hi >> bitIndex) & 1) << 1 | ((lo >> bitIndex) & 1)
                // Colour 0 is transparent for sprites.
                guard colorIndex != 0 else { continue }

                // Background wins if the tile claims priority (CGB) or the
                // sprite defers and the background pixel is non-zero.
                if lineBGPriority[x] && lineBGColorIndex[x] != 0 { continue }
                if behindBG && lineBGColorIndex[x] != 0 { continue }

                if isCGB {
                    framebuffer[base + x] = cgbColor(
                        paletteRAM: objPaletteRAM,
                        palette: Int(attrs & 0x07),
                        index: Int(colorIndex)
                    )
                } else {
                    let palette = (attrs & 0x10) != 0 ? obp1 : obp0
                    let shade = (palette >> (colorIndex * 2)) & 0x03
                    framebuffer[base + x] = dmgShades[Int(shade)]
                }
            }
        }
    }

    /// Decode a 15-bit BGR555 entry out of CGB palette RAM.
    private func cgbColor(paletteRAM: [UInt8], palette: Int, index: Int) -> UInt32 {
        let offset = palette * 8 + index * 2
        let raw = UInt16(paletteRAM[offset]) | (UInt16(paletteRAM[offset + 1]) << 8)
        let r = Int(raw & 0x1F)
        let g = Int((raw >> 5) & 0x1F)
        let b = Int((raw >> 10) & 0x1F)

        // The GBC's screen was much less saturated than a naive 5->8 bit scale
        // suggests. This is the widely used channel-mixing correction; without
        // it everything looks garishly oversaturated on a modern display.
        let rr = min(255, (r * 26 + g * 4 + b * 2) >> 2)
        let gg = min(255, (g * 24 + b * 8) >> 2)
        let bb = min(255, (r * 6 + g * 4 + b * 22) >> 2)

        return 0xFF00_0000 | UInt32(rr) << 16 | UInt32(gg) << 8 | UInt32(bb)
    }

    // MARK: CGB palette port access

    func writeBGPaletteData(_ value: UInt8) {
        bgPaletteRAM[Int(bgPaletteIndex & 0x3F)] = value
        if bgPaletteIndex & 0x80 != 0 {
            bgPaletteIndex = (bgPaletteIndex & 0x80) | ((bgPaletteIndex &+ 1) & 0x3F)
        }
    }

    func writeOBJPaletteData(_ value: UInt8) {
        objPaletteRAM[Int(objPaletteIndex & 0x3F)] = value
        if objPaletteIndex & 0x80 != 0 {
            objPaletteIndex = (objPaletteIndex & 0x80) | ((objPaletteIndex &+ 1) & 0x3F)
        }
    }

    func readBGPaletteData() -> UInt8 { bgPaletteRAM[Int(bgPaletteIndex & 0x3F)] }
    func readOBJPaletteData() -> UInt8 { objPaletteRAM[Int(objPaletteIndex & 0x3F)] }

    // MARK: VRAM / OAM bus access
    //
    // Real hardware blocks the CPU from VRAM during mode 3 and from OAM during
    // modes 2 and 3. Enforcing that breaks more games than it fixes when the
    // renderer is scanline-based rather than dot-based, so reads and writes are
    // allowed through and the timing is left to the mode counters.

    func readVRAM(_ addr: UInt16) -> UInt8 {
        vram[vramBank * 0x2000 + Int(addr - 0x8000)]
    }

    func writeVRAM(_ addr: UInt16, _ value: UInt8) {
        vram[vramBank * 0x2000 + Int(addr - 0x8000)] = value
    }

    func readOAM(_ addr: UInt16) -> UInt8 { oam[Int(addr - 0xFE00)] }
    func writeOAM(_ addr: UInt16, _ value: UInt8) { oam[Int(addr - 0xFE00)] = value }
}
