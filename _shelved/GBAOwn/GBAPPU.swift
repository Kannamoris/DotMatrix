import Foundation

/// The GBA picture processing unit.
///
/// Rendering is per scanline, at the point the hardware enters HBlank. Games
/// reprogram scroll, affine and blend registers between lines constantly — that
/// is how most GBA effects are built — so the granularity matters, but nothing
/// commercial depends on changes *within* a line.
final class GBAPPU {
    static let width = 240
    static let height = 160

    /// Finished frame, 0xAARRGGBB — byte order matches `.bgra8Unorm`.
    private(set) var framebuffer = [UInt32](repeating: 0xFF00_0000, count: width * height)
    private(set) var frameComplete = false

    // MARK: Memory

    private var palette = [UInt8](repeating: 0, count: 0x400)   // 1 KB
    private var vram = [UInt8](repeating: 0, count: 0x18000)    // 96 KB
    private var oam = [UInt8](repeating: 0, count: 0x400)       // 1 KB

    // MARK: Registers

    private var dispcnt: UInt16 = 0x0080   // starts in forced blank
    private var dispstat: UInt16 = 0
    private var vcount: UInt16 = 0

    private var bgControl = [UInt16](repeating: 0, count: 4)
    private var bgHorizontalOffset = [UInt16](repeating: 0, count: 4)
    private var bgVerticalOffset = [UInt16](repeating: 0, count: 4)

    /// Affine parameters for BG2 and BG3, indexed 0 and 1.
    private var affineA = [Int16](repeating: 256, count: 2)
    private var affineB = [Int16](repeating: 0, count: 2)
    private var affineC = [Int16](repeating: 0, count: 2)
    private var affineD = [Int16](repeating: 256, count: 2)
    private var affineRefX = [Int32](repeating: 0, count: 2)
    private var affineRefY = [Int32](repeating: 0, count: 2)
    /// Running accumulators, latched from the reference points each frame and
    /// stepped by B and D per scanline.
    private var affineCurrentX = [Int32](repeating: 0, count: 2)
    private var affineCurrentY = [Int32](repeating: 0, count: 2)

    private var windowH = [UInt16](repeating: 0, count: 2)
    private var windowV = [UInt16](repeating: 0, count: 2)
    private var windowIn: UInt16 = 0
    private var windowOut: UInt16 = 0

    private var mosaic: UInt16 = 0
    private var blendControl: UInt16 = 0
    private var blendAlpha: UInt16 = 0
    private var blendBrightness: UInt16 = 0

    // MARK: Timing

    private var dot = 0
    /// Counts, not flags. A single peripheral batch can span several scanlines
    /// — the deferred-cycle drain hands over thousands of cycles at once after
    /// a DMA — and HBlank DMA must run once per scanline. Collapsing several
    /// into one silently drops transfers.
    private var hblankTriggers = 0
    private var vblankTriggers = 0

    private let interrupts: InterruptController

    // MARK: Scanline scratch buffers
    //
    // Allocated once and reused; a per-line allocation here would dominate the
    // frame cost.

    private var bgColor = [[UInt16]](repeating: [UInt16](repeating: 0, count: width), count: 4)
    private var bgOpaque = [[Bool]](repeating: [Bool](repeating: false, count: width), count: 4)

    private var objColor = [UInt16](repeating: 0, count: width)
    private var objOpaque = [Bool](repeating: false, count: width)
    private var objPriority = [UInt8](repeating: 4, count: width)
    private var objSemiTransparent = [Bool](repeating: false, count: width)
    private var objIsWindow = [Bool](repeating: false, count: width)

    init(interrupts: InterruptController) {
        self.interrupts = interrupts
    }

    // MARK: Register decoding helpers

    private var videoMode: Int { Int(dispcnt & 0x7) }
    private var forcedBlank: Bool { dispcnt & 0x0080 != 0 }
    private var objectsEnabled: Bool { dispcnt & 0x1000 != 0 }
    /// 1D mapping lays sprite tiles out consecutively; 2D uses a 32-tile grid.
    private var oneDimensionalOBJMapping: Bool { dispcnt & 0x0040 != 0 }

    private func backgroundEnabled(_ index: Int) -> Bool {
        dispcnt & (0x0100 << UInt16(index)) != 0
    }

    /// Sprite tile data starts higher in VRAM in the bitmap modes, because the
    /// bitmap itself occupies the lower region.
    var objectVRAMBase: UInt32 {
        videoMode >= 3 ? 0x14000 : 0x10000
    }

    // MARK: Stepping

    func step(_ cycles: Int) {
        // `frameComplete` is deliberately not cleared here. The bus drains
        // deferred cycles by calling this repeatedly within a single CPU step,
        // so clearing on entry erases a frame boundary that the caller has not
        // observed yet — the frame loop then overshoots or returns having run
        // almost nothing, which makes audio arrive in bursts. The flag is
        // sticky until `consumeFrameComplete()` takes it.
        var remaining = cycles
        while remaining > 0 {
            // A scanline is 308 dots of 4 cycles each: 240 visible, 68 blank.
            let step = min(remaining, 1232 - dot)
            dot += step
            remaining -= step

            if dot >= 1232 {
                dot = 0
                advanceScanline()
            } else if dot >= 960 && !hblankFlagSet {
                enterHBlank()
            }
        }
    }

    private var hblankFlagSet: Bool { dispstat & 0x0002 != 0 }

    private func enterHBlank() {
        dispstat |= 0x0002

        // Render at HBlank, once every register this line depends on has
        // settled to its final value.
        if vcount < UInt16(Self.height) {
            renderScanline(Int(vcount))
        }

        if dispstat & 0x0010 != 0 {
            interrupts.request(.hblank)
        }
        // HBlank DMA does not run during VBlank.
        if vcount < UInt16(Self.height) {
            hblankTriggers += 1
        }
    }

    private func advanceScanline() {
        dispstat &= ~0x0002   // leave HBlank
        vcount += 1

        if vcount == UInt16(Self.height) {
            dispstat |= 0x0001
            if dispstat & 0x0008 != 0 {
                interrupts.request(.vblank)
            }
            vblankTriggers += 1
            frameComplete = true
        } else if vcount >= 228 {
            vcount = 0
            dispstat &= ~0x0001
            // The affine accumulators reload from their reference points once
            // per frame, not once per line.
            for i in 0..<2 {
                affineCurrentX[i] = affineRefX[i]
                affineCurrentY[i] = affineRefY[i]
            }
        }

        // VCOUNT match, compared against the high byte of DISPSTAT.
        let target = UInt16((dispstat >> 8) & 0xFF)
        if vcount == target {
            dispstat |= 0x0004
            if dispstat & 0x0020 != 0 {
                interrupts.request(.vcount)
            }
        } else {
            dispstat &= ~0x0004
        }
    }

    /// Take the completed-frame flag, clearing it. Mirrors the DMA triggers:
    /// the flag survives until whoever cares has acted on it.
    func consumeFrameComplete() -> Bool {
        defer { frameComplete = false }
        return frameComplete
    }

    /// Take the pending HBlank count, clearing it. Each one owes a DMA pass.
    func consumeHBlankTriggers() -> Int {
        defer { hblankTriggers = 0 }
        return hblankTriggers
    }

    func consumeVBlankTriggers() -> Int {
        defer { vblankTriggers = 0 }
        return vblankTriggers
    }

    // MARK: Scanline rendering

    private func renderScanline(_ line: Int) {
        let base = line * Self.width

        if forcedBlank {
            for x in 0..<Self.width { framebuffer[base + x] = 0xFFFF_FFFF }
            stepAffineAccumulators()
            return
        }

        // Clear the scratch buffers for this line.
        for layer in 0..<4 {
            for x in 0..<Self.width { bgOpaque[layer][x] = false }
        }
        for x in 0..<Self.width {
            objOpaque[x] = false
            objPriority[x] = 4
            objSemiTransparent[x] = false
            objIsWindow[x] = false
        }

        switch videoMode {
        case 0:
            for layer in 0..<4 where backgroundEnabled(layer) {
                renderTextBackground(layer, line: line)
            }
        case 1:
            for layer in 0..<2 where backgroundEnabled(layer) {
                renderTextBackground(layer, line: line)
            }
            if backgroundEnabled(2) { renderAffineBackground(2, line: line) }
        case 2:
            if backgroundEnabled(2) { renderAffineBackground(2, line: line) }
            if backgroundEnabled(3) { renderAffineBackground(3, line: line) }
        case 3:
            if backgroundEnabled(2) { renderBitmapMode3(line) }
        case 4:
            if backgroundEnabled(2) { renderBitmapMode4(line) }
        case 5:
            if backgroundEnabled(2) { renderBitmapMode5(line) }
        default:
            break
        }

        if objectsEnabled {
            renderSprites(line)
        }

        composite(line)
        stepAffineAccumulators()
    }

    /// Affine backgrounds advance by (B, D) per scanline — the vertical step of
    /// the transform.
    private func stepAffineAccumulators() {
        for i in 0..<2 {
            affineCurrentX[i] &+= Int32(affineB[i])
            affineCurrentY[i] &+= Int32(affineD[i])
        }
    }

    // MARK: Text (regular) backgrounds

    private func renderTextBackground(_ layer: Int, line: Int) {
        let control = bgControl[layer]
        let charBase = Int((control >> 2) & 0x3) * 0x4000
        let screenBase = Int((control >> 8) & 0x1F) * 0x800
        let is256Color = control & 0x0080 != 0
        let size = Int((control >> 14) & 0x3)

        let scrollX = Int(bgHorizontalOffset[layer] & 0x1FF)
        let scrollY = Int(bgVerticalOffset[layer] & 0x1FF)

        var effectiveLine = line
        if control & 0x0040 != 0 {
            // Vertical mosaic snaps the sampled line to a block boundary.
            let vSize = Int((mosaic >> 4) & 0xF) + 1
            effectiveLine = (line / vSize) * vSize
        }

        let textureY = (effectiveLine + scrollY) & 0x1FF

        // Sizes 0-3 are 256x256, 512x256, 256x512 and 512x512 pixels.
        let wide = (size == 1 || size == 3)
        let tall = (size == 2 || size == 3)

        for x in 0..<Self.width {
            let textureX = (x + scrollX) & (wide ? 0x1FF : 0xFF)
            let wrappedY = textureY & (tall ? 0x1FF : 0xFF)

            // Each 256x256 quadrant is its own 2 KB screen block.
            var blockIndex = 0
            if wide && textureX >= 256 { blockIndex += 1 }
            if tall && wrappedY >= 256 { blockIndex += wide ? 2 : 1 }

            let tileX = (textureX & 0xFF) >> 3
            let tileY = (wrappedY & 0xFF) >> 3

            let entryAddress = screenBase + blockIndex * 0x800 + (tileY * 32 + tileX) * 2
            guard entryAddress + 1 < vram.count else { continue }
            let entry = UInt16(vram[entryAddress]) | (UInt16(vram[entryAddress + 1]) << 8)

            let tileNumber = Int(entry & 0x03FF)
            let flipX = entry & 0x0400 != 0
            let flipY = entry & 0x0800 != 0
            let paletteBank = Int((entry >> 12) & 0xF)

            var pixelX = textureX & 7
            var pixelY = wrappedY & 7
            if flipX { pixelX = 7 - pixelX }
            if flipY { pixelY = 7 - pixelY }

            let colorIndex: Int
            if is256Color {
                let address = charBase + tileNumber * 64 + pixelY * 8 + pixelX
                guard address < vram.count else { continue }
                colorIndex = Int(vram[address])
            } else {
                let address = charBase + tileNumber * 32 + pixelY * 4 + (pixelX >> 1)
                guard address < vram.count else { continue }
                let byte = vram[address]
                colorIndex = Int(pixelX & 1 == 0 ? byte & 0x0F : byte >> 4)
            }

            guard colorIndex != 0 else { continue }

            let paletteIndex = is256Color ? colorIndex : paletteBank * 16 + colorIndex
            bgColor[layer][x] = paletteEntry(paletteIndex)
            bgOpaque[layer][x] = true
        }

        applyHorizontalMosaic(layer)
    }

    private func applyHorizontalMosaic(_ layer: Int) {
        guard bgControl[layer] & 0x0040 != 0 else { return }
        let hSize = Int(mosaic & 0xF) + 1
        guard hSize > 1 else { return }

        // Each block takes the colour of its leftmost pixel.
        var blockStart = 0
        while blockStart < Self.width {
            let color = bgColor[layer][blockStart]
            let opaque = bgOpaque[layer][blockStart]
            for offset in 1..<hSize {
                let x = blockStart + offset
                guard x < Self.width else { break }
                bgColor[layer][x] = color
                bgOpaque[layer][x] = opaque
            }
            blockStart += hSize
        }
    }

    // MARK: Affine backgrounds

    private func renderAffineBackground(_ layer: Int, line: Int) {
        let index = layer - 2
        let control = bgControl[layer]
        let charBase = Int((control >> 2) & 0x3) * 0x4000
        let screenBase = Int((control >> 8) & 0x1F) * 0x800
        let size = Int((control >> 14) & 0x3)
        let wrap = control & 0x2000 != 0

        // Sizes are 128, 256, 512 and 1024 pixels square.
        let mapSize = 128 << size
        let tilesPerRow = mapSize >> 3

        var x = affineCurrentX[index]
        var y = affineCurrentY[index]

        for screenX in 0..<Self.width {
            // The accumulators are 8.8 fixed point.
            var textureX = Int(x >> 8)
            var textureY = Int(y >> 8)

            x &+= Int32(affineA[index])
            y &+= Int32(affineC[index])

            if wrap {
                textureX = ((textureX % mapSize) + mapSize) % mapSize
                textureY = ((textureY % mapSize) + mapSize) % mapSize
            } else if textureX < 0 || textureX >= mapSize || textureY < 0 || textureY >= mapSize {
                // Outside the map and not wrapping: transparent.
                continue
            }

            let tileIndexAddress = screenBase + (textureY >> 3) * tilesPerRow + (textureX >> 3)
            guard tileIndexAddress < vram.count else { continue }
            let tileNumber = Int(vram[tileIndexAddress])

            // Affine backgrounds are always 256-colour and never flipped.
            let address = charBase + tileNumber * 64 + (textureY & 7) * 8 + (textureX & 7)
            guard address < vram.count else { continue }
            let colorIndex = Int(vram[address])
            guard colorIndex != 0 else { continue }

            bgColor[layer][screenX] = paletteEntry(colorIndex)
            bgOpaque[layer][screenX] = true
        }
    }

    // MARK: Bitmap modes

    private func renderBitmapMode3(_ line: Int) {
        // 240x160, one 15-bit colour per pixel, no page flipping.
        let rowBase = line * Self.width * 2
        for x in 0..<Self.width {
            let address = rowBase + x * 2
            guard address + 1 < vram.count else { break }
            bgColor[2][x] = UInt16(vram[address]) | (UInt16(vram[address + 1]) << 8)
            bgOpaque[2][x] = true
        }
    }

    private func renderBitmapMode4(_ line: Int) {
        // 240x160 paletted, double buffered — DISPCNT bit 4 picks the page.
        let pageBase = (dispcnt & 0x0010) != 0 ? 0xA000 : 0x0000
        let rowBase = pageBase + line * Self.width
        for x in 0..<Self.width {
            let address = rowBase + x
            guard address < vram.count else { break }
            let colorIndex = Int(vram[address])
            guard colorIndex != 0 else { continue }
            bgColor[2][x] = paletteEntry(colorIndex)
            bgOpaque[2][x] = true
        }
    }

    private func renderBitmapMode5(_ line: Int) {
        // 160x128 direct colour, double buffered. Outside that area the layer
        // is simply absent.
        guard line < 128 else { return }
        let pageBase = (dispcnt & 0x0010) != 0 ? 0xA000 : 0x0000
        let rowBase = pageBase + line * 160 * 2
        for x in 0..<160 {
            let address = rowBase + x * 2
            guard address + 1 < vram.count else { break }
            bgColor[2][x] = UInt16(vram[address]) | (UInt16(vram[address + 1]) << 8)
            bgOpaque[2][x] = true
        }
    }

    // MARK: Sprites

    private func renderSprites(_ line: Int) {
        // Sprite dimensions indexed by [shape][size].
        let dimensions: [[(Int, Int)]] = [
            [(8, 8), (16, 16), (32, 32), (64, 64)],     // square
            [(16, 8), (32, 8), (32, 16), (64, 32)],     // wide
            [(8, 16), (8, 32), (16, 32), (32, 64)],     // tall
        ]

        // OAM is scanned in order and lower indices win, so drawing back to
        // front means iterating in reverse.
        for entry in (0..<128).reversed() {
            let attributeBase = entry * 8
            let attr0 = UInt16(oam[attributeBase]) | (UInt16(oam[attributeBase + 1]) << 8)
            let attr1 = UInt16(oam[attributeBase + 2]) | (UInt16(oam[attributeBase + 3]) << 8)
            let attr2 = UInt16(oam[attributeBase + 4]) | (UInt16(oam[attributeBase + 5]) << 8)

            let affine = attr0 & 0x0100 != 0
            let disabled = !affine && (attr0 & 0x0200 != 0)
            guard !disabled else { continue }

            let shape = Int((attr0 >> 14) & 0x3)
            let sizeCode = Int((attr1 >> 14) & 0x3)
            guard shape < 3 else { continue }
            let (spriteWidth, spriteHeight) = dimensions[shape][sizeCode]

            // The double-size flag doubles the sampled area for affine sprites
            // so a rotation doesn't clip its own corners.
            let doubleSize = affine && (attr0 & 0x0200 != 0)
            let boxWidth = doubleSize ? spriteWidth * 2 : spriteWidth
            let boxHeight = doubleSize ? spriteHeight * 2 : spriteHeight

            // Y is 8-bit and the comparison wraps at 256, which is what lets a
            // sprite hang off the top of the screen. Masking reproduces that
            // directly; treating Y as signed around the screen height instead
            // gets tall sprites wrong.
            let spriteY = Int(attr0 & 0xFF)
            let rowInBox = (line - spriteY) & 0xFF
            guard rowInBox < boxHeight else { continue }

            // X is 9-bit two's complement, so the sign boundary is 256 — not
            // the screen width. Extending at 240 relocated any sprite placed at
            // X 240-255 to roughly -260, which is off the left edge: a scaled
            // battler positioned near the right of the screen vanished.
            var spriteX = Int(attr1 & 0x1FF)
            if spriteX >= 256 { spriteX -= 512 }

            let mode = Int((attr0 >> 10) & 0x3)
            let is256Color = attr0 & 0x2000 != 0
            let tileNumber = Int(attr2 & 0x03FF)
            let priority = UInt8((attr2 >> 10) & 0x3)
            let paletteBank = Int((attr2 >> 12) & 0xF)

            // Affine parameters live interleaved in the unused OAM words.
            var pa: Int32 = 256, pb: Int32 = 0, pc: Int32 = 0, pd: Int32 = 256
            if affine {
                let group = Int((attr1 >> 9) & 0x1F)
                pa = Int32(readOAMHalfSigned(group * 32 + 6))
                pb = Int32(readOAMHalfSigned(group * 32 + 14))
                pc = Int32(readOAMHalfSigned(group * 32 + 22))
                pd = Int32(readOAMHalfSigned(group * 32 + 30))
            }

            let flipX = !affine && (attr1 & 0x1000 != 0)
            let flipY = !affine && (attr1 & 0x2000 != 0)

            // MOSAIC bits 8-11 and 12-15 hold the OBJ block size, minus one.
            let useMosaic = attr0 & 0x1000 != 0
            let objMosaicWidth = Int((mosaic >> 8) & 0xF) + 1
            let objMosaicHeight = Int((mosaic >> 12) & 0xF) + 1

            let halfWidth = boxWidth / 2
            let halfHeight = boxHeight / 2

            // Vertical mosaic snaps the source row, so a block of scanlines all
            // sample the same line of the sprite.
            let sampledRow = useMosaic
                ? rowInBox - (rowInBox % objMosaicHeight)
                : rowInBox

            // Horizontal mosaic is keyed on the *output* pixel, not the source:
            // the transform keeps advancing and the sampled coordinate is only
            // refreshed when screen X crosses a block boundary. Snapping the
            // texture coordinate instead warps the sampling — it distorts the
            // sprite rather than blocking it.
            var heldTextureX = 0
            var heldTextureY = 0
            var holdingSample = false

            for columnInBox in 0..<boxWidth {
                let screenX = spriteX + columnInBox
                guard screenX >= 0 && screenX < Self.width else { continue }

                var textureX: Int
                var textureY: Int

                if affine {
                    // Transform around the centre of the bounding box, mapping
                    // to the centre of the sprite.
                    let offsetX = Int32(columnInBox - halfWidth)
                    let offsetY = Int32(sampledRow - halfHeight)
                    textureX = Int(((pa * offsetX + pb * offsetY) >> 8)) + spriteWidth / 2
                    textureY = Int(((pc * offsetX + pd * offsetY) >> 8)) + spriteHeight / 2
                } else {
                    textureX = columnInBox
                    textureY = sampledRow
                    if flipX { textureX = spriteWidth - 1 - textureX }
                    if flipY { textureY = spriteHeight - 1 - textureY }
                }

                if useMosaic {
                    if !holdingSample || screenX % objMosaicWidth == 0 {
                        heldTextureX = textureX
                        heldTextureY = textureY
                        holdingSample = true
                    }
                    textureX = heldTextureX
                    textureY = heldTextureY
                }

                guard textureX >= 0, textureX < spriteWidth,
                      textureY >= 0, textureY < spriteHeight else { continue }

                // Locate the 8x8 tile within the sprite.
                let tileColumn = textureX >> 3
                let tileRow = textureY >> 3
                let tileStride = oneDimensionalOBJMapping
                    ? (spriteWidth >> 3) * (is256Color ? 2 : 1)
                    : 32

                var tile = tileNumber + tileRow * tileStride + tileColumn * (is256Color ? 2 : 1)
                // Sprite tile numbers wrap within the 1024-entry space.
                tile &= 0x3FF

                let address: Int
                let colorIndex: Int
                if is256Color {
                    address = Int(objectVRAMBase) + tile * 32 + (textureY & 7) * 8 + (textureX & 7)
                    guard address < vram.count else { continue }
                    colorIndex = Int(vram[address])
                } else {
                    address = Int(objectVRAMBase) + tile * 32 + (textureY & 7) * 4 + ((textureX & 7) >> 1)
                    guard address < vram.count else { continue }
                    let byte = vram[address]
                    colorIndex = Int((textureX & 1) == 0 ? byte & 0x0F : byte >> 4)
                }

                guard colorIndex != 0 else { continue }

                // Mode 2 sprites don't draw — they define the object window.
                if mode == 2 {
                    objIsWindow[screenX] = true
                    continue
                }

                // Lower priority value wins; ties go to the lower OAM index,
                // which the reverse iteration already handles.
                guard priority <= objPriority[screenX] || !objOpaque[screenX] else { continue }

                // Sprite palettes occupy the upper half of palette RAM.
                let paletteIndex = is256Color ? 256 + colorIndex : 256 + paletteBank * 16 + colorIndex
                objColor[screenX] = paletteEntry(paletteIndex)
                objOpaque[screenX] = true
                objPriority[screenX] = priority
                objSemiTransparent[screenX] = (mode == 1)
            }
        }
    }

    private func readOAMHalfSigned(_ offset: Int) -> Int16 {
        guard offset + 1 < oam.count else { return 0 }
        return Int16(bitPattern: UInt16(oam[offset]) | (UInt16(oam[offset + 1]) << 8))
    }

    // MARK: Compositing

    private func composite(_ line: Int) {
        let base = line * Self.width
        let backdrop = paletteEntry(0)

        let window0Enabled = dispcnt & 0x2000 != 0
        let window1Enabled = dispcnt & 0x4000 != 0
        let objWindowEnabled = dispcnt & 0x8000 != 0
        let anyWindowEnabled = window0Enabled || window1Enabled || objWindowEnabled

        for x in 0..<Self.width {
            // Decide which layers this pixel is allowed to see.
            let layerMask: UInt16
            if anyWindowEnabled {
                if window0Enabled && insideWindow(0, x: x, y: line) {
                    layerMask = windowIn & 0x3F
                } else if window1Enabled && insideWindow(1, x: x, y: line) {
                    layerMask = (windowIn >> 8) & 0x3F
                } else if objWindowEnabled && objIsWindow[x] {
                    layerMask = (windowOut >> 8) & 0x3F
                } else {
                    layerMask = windowOut & 0x3F
                }
            } else {
                layerMask = 0x3F
            }

            // Walk the priorities to find the top two visible layers.
            var topColor = backdrop
            var topLayer = 5          // 5 = backdrop
            var secondColor = backdrop
            var secondLayer = 5
            var found = 0

            priorityLoop: for priority in 0..<4 {
                // Sprites sit above backgrounds of the same priority.
                if objOpaque[x], objPriority[x] == UInt8(priority), layerMask & 0x10 != 0 {
                    if found == 0 {
                        topColor = objColor[x]; topLayer = 4
                    } else {
                        secondColor = objColor[x]; secondLayer = 4
                        break priorityLoop
                    }
                    found += 1
                }
                for layer in 0..<4 {
                    guard bgOpaque[layer][x],
                          Int(bgControl[layer] & 0x3) == priority,
                          layerMask & (1 << UInt16(layer)) != 0 else { continue }
                    if found == 0 {
                        topColor = bgColor[layer][x]; topLayer = layer
                    } else {
                        secondColor = bgColor[layer][x]; secondLayer = layer
                        break priorityLoop
                    }
                    found += 1
                }
            }

            // Effects are suppressed inside a window that disables them.
            let effectsAllowed = !anyWindowEnabled || (layerMask & 0x20) != 0
            let color = applyBlend(
                topColor: topColor, topLayer: topLayer,
                secondColor: secondColor, secondLayer: secondLayer,
                semiTransparentSprite: topLayer == 4 && objSemiTransparent[x],
                effectsAllowed: effectsAllowed
            )

            framebuffer[base + x] = convert(color)
        }
    }

    private func insideWindow(_ index: Int, x: Int, y: Int) -> Bool {
        let horizontal = windowH[index]
        let vertical = windowV[index]

        let left = Int(horizontal >> 8)
        var right = Int(horizontal & 0xFF)
        let top = Int(vertical >> 8)
        var bottom = Int(vertical & 0xFF)

        // A right/bottom edge past the screen, or before the left/top edge,
        // means the window extends to the edge of the display.
        if right > Self.width || right < left { right = Self.width }
        if bottom > Self.height || bottom < top { bottom = Self.height }

        return x >= left && x < right && y >= top && y < bottom
    }

    // MARK: Blending

    private func applyBlend(topColor: UInt16, topLayer: Int,
                            secondColor: UInt16, secondLayer: Int,
                            semiTransparentSprite: Bool,
                            effectsAllowed: Bool) -> UInt16 {
        let effect = Int((blendControl >> 6) & 0x3)

        let isFirstTarget = blendControl & (1 << UInt16(topLayer)) != 0
        let isSecondTarget = blendControl & (1 << UInt16(secondLayer + 8)) != 0

        // A semi-transparent sprite forces alpha blending regardless of the
        // configured effect, provided the layer beneath is a second target.
        if semiTransparentSprite && isSecondTarget && effectsAllowed {
            return alphaBlend(topColor, secondColor)
        }

        guard effectsAllowed, effect != 0, isFirstTarget else { return topColor }

        switch effect {
        case 1:
            guard isSecondTarget else { return topColor }
            return alphaBlend(topColor, secondColor)
        case 2:
            return adjustBrightness(topColor, towardsWhite: true)
        default:
            return adjustBrightness(topColor, towardsWhite: false)
        }
    }

    private func alphaBlend(_ top: UInt16, _ bottom: UInt16) -> UInt16 {
        // Coefficients are 1/16 steps, saturating at 16/16.
        let weightTop = min(Int(blendAlpha & 0x1F), 16)
        let weightBottom = min(Int((blendAlpha >> 8) & 0x1F), 16)

        var result: UInt16 = 0
        for shift in stride(from: 0, to: 15, by: 5) {
            let topChannel = Int((top >> UInt16(shift)) & 0x1F)
            let bottomChannel = Int((bottom >> UInt16(shift)) & 0x1F)
            let blended = min(31, (topChannel * weightTop + bottomChannel * weightBottom) >> 4)
            result |= UInt16(blended) << UInt16(shift)
        }
        return result
    }

    private func adjustBrightness(_ color: UInt16, towardsWhite: Bool) -> UInt16 {
        let weight = min(Int(blendBrightness & 0x1F), 16)

        var result: UInt16 = 0
        for shift in stride(from: 0, to: 15, by: 5) {
            let channel = Int((color >> UInt16(shift)) & 0x1F)
            let adjusted = towardsWhite
                ? channel + (((31 - channel) * weight) >> 4)
                : channel - ((channel * weight) >> 4)
            result |= UInt16(max(0, min(31, adjusted))) << UInt16(shift)
        }
        return result
    }

    // MARK: Colour

    private func paletteEntry(_ index: Int) -> UInt16 {
        let offset = (index * 2) & 0x3FE
        return UInt16(palette[offset]) | (UInt16(palette[offset + 1]) << 8)
    }

    /// BGR555 to 8-bit RGB.
    ///
    /// The GBA's screen was notoriously dim and unsaturated. A straight 5-to-8
    /// bit scale looks harshly oversaturated on a modern display, so this
    /// applies the usual channel-mixing correction.
    private func convert(_ color: UInt16) -> UInt32 {
        let r = Int(color & 0x1F)
        let g = Int((color >> 5) & 0x1F)
        let b = Int((color >> 10) & 0x1F)

        let red = min(255, (r * 26 + g * 4 + b * 2) >> 2)
        let green = min(255, (g * 24 + b * 8) >> 2)
        let blue = min(255, (r * 6 + g * 4 + b * 22) >> 2)

        return 0xFF00_0000 | UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue)
    }

    // MARK: Memory access

    func readPalette(_ offset: UInt32) -> UInt8 { palette[Int(offset) & 0x3FF] }

    func writePalette16(_ offset: UInt32, _ value: UInt16) {
        let index = Int(offset) & 0x3FE
        palette[index] = UInt8(value & 0xFF)
        palette[index + 1] = UInt8(value >> 8)
    }

    func readVRAM(_ offset: UInt32) -> UInt8 {
        let index = Int(offset)
        return index < vram.count ? vram[index] : 0
    }

    func writeVRAM16(_ offset: UInt32, _ value: UInt16) {
        let index = Int(offset)
        guard index + 1 < vram.count else { return }
        vram[index] = UInt8(value & 0xFF)
        vram[index + 1] = UInt8(value >> 8)
    }

    func readOAM(_ offset: UInt32) -> UInt8 { oam[Int(offset) & 0x3FF] }

    func writeOAM16(_ offset: UInt32, _ value: UInt16) {
        let index = Int(offset) & 0x3FE
        oam[index] = UInt8(value & 0xFF)
        oam[index + 1] = UInt8(value >> 8)
    }

    func clearPalette() { for i in palette.indices { palette[i] = 0 } }
    func clearVRAM() { for i in vram.indices { vram[i] = 0 } }
    func clearOAM() { for i in oam.indices { oam[i] = 0 } }

    // MARK: Register file

    func readRegister(_ register: UInt32) -> UInt16 {
        switch register {
        case 0x000: return dispcnt
        case 0x004: return dispstat
        case 0x006: return vcount
        case 0x008: return bgControl[0]
        case 0x00A: return bgControl[1]
        case 0x00C: return bgControl[2]
        case 0x00E: return bgControl[3]
        case 0x048: return windowIn
        case 0x04A: return windowOut
        case 0x050: return blendControl
        case 0x052: return blendAlpha
        default: return 0
        }
    }

    func writeRegister(_ register: UInt32, _ value: UInt16) {
        switch register {
        case 0x000: dispcnt = value
        case 0x004:
            // The low three bits are status flags the CPU can't set.
            dispstat = (dispstat & 0x0007) | (value & 0xFF38)
        case 0x008, 0x00A, 0x00C, 0x00E:
            bgControl[Int((register - 0x008) / 2)] = value
        case 0x010, 0x014, 0x018, 0x01C:
            bgHorizontalOffset[Int((register - 0x010) / 4)] = value
        case 0x012, 0x016, 0x01A, 0x01E:
            bgVerticalOffset[Int((register - 0x012) / 4)] = value

        case 0x020: affineA[0] = Int16(bitPattern: value)
        case 0x022: affineB[0] = Int16(bitPattern: value)
        case 0x024: affineC[0] = Int16(bitPattern: value)
        case 0x026: affineD[0] = Int16(bitPattern: value)
        case 0x028: setAffineReferenceLow(0, isY: false, value)
        case 0x02A: setAffineReferenceHigh(0, isY: false, value)
        case 0x02C: setAffineReferenceLow(0, isY: true, value)
        case 0x02E: setAffineReferenceHigh(0, isY: true, value)

        case 0x030: affineA[1] = Int16(bitPattern: value)
        case 0x032: affineB[1] = Int16(bitPattern: value)
        case 0x034: affineC[1] = Int16(bitPattern: value)
        case 0x036: affineD[1] = Int16(bitPattern: value)
        case 0x038: setAffineReferenceLow(1, isY: false, value)
        case 0x03A: setAffineReferenceHigh(1, isY: false, value)
        case 0x03C: setAffineReferenceLow(1, isY: true, value)
        case 0x03E: setAffineReferenceHigh(1, isY: true, value)

        case 0x040: windowH[0] = value
        case 0x042: windowH[1] = value
        case 0x044: windowV[0] = value
        case 0x046: windowV[1] = value
        case 0x048: windowIn = value
        case 0x04A: windowOut = value
        case 0x04C: mosaic = value
        case 0x050: blendControl = value
        case 0x052: blendAlpha = value
        case 0x054: blendBrightness = value
        default: break
        }
    }

    /// The reference points are 28-bit signed, 8.8 fixed point, written as two
    /// halves. Writing either half restarts the accumulator immediately —
    /// that's what makes mid-frame repositioning work.
    private func setAffineReferenceLow(_ index: Int, isY: Bool, _ value: UInt16) {
        if isY {
            affineRefY[index] = (affineRefY[index] & ~0xFFFF) | Int32(value)
            affineCurrentY[index] = signExtend28(affineRefY[index])
            affineRefY[index] = affineCurrentY[index]
        } else {
            affineRefX[index] = (affineRefX[index] & ~0xFFFF) | Int32(value)
            affineCurrentX[index] = signExtend28(affineRefX[index])
            affineRefX[index] = affineCurrentX[index]
        }
    }

    private func setAffineReferenceHigh(_ index: Int, isY: Bool, _ value: UInt16) {
        let high = Int32(value & 0x0FFF) << 16
        if isY {
            affineRefY[index] = (affineRefY[index] & 0xFFFF) | high
            affineCurrentY[index] = signExtend28(affineRefY[index])
            affineRefY[index] = affineCurrentY[index]
        } else {
            affineRefX[index] = (affineRefX[index] & 0xFFFF) | high
            affineCurrentX[index] = signExtend28(affineRefX[index])
            affineRefX[index] = affineCurrentX[index]
        }
    }

    private func signExtend28(_ value: Int32) -> Int32 {
        (value & 0x0800_0000) != 0 ? value | Int32(bitPattern: 0xF000_0000) : value & 0x0FFF_FFFF
    }

    // MARK: Snapshot

    func encodeState(into w: inout StateWriter) {
        w.mark("PPU ")
        w.write(palette); w.write(vram); w.write(oam)
        w.write(dispcnt); w.write(dispstat); w.write(vcount)
        w.write(bgControl); w.write(bgHorizontalOffset); w.write(bgVerticalOffset)
        w.write(affineA); w.write(affineB); w.write(affineC); w.write(affineD)
        w.write(affineRefX); w.write(affineRefY)
        w.write(affineCurrentX); w.write(affineCurrentY)
        w.write(windowH); w.write(windowV); w.write(windowIn); w.write(windowOut)
        w.write(mosaic); w.write(blendControl); w.write(blendAlpha); w.write(blendBrightness)
        w.write(dot); w.write(frameComplete)
    }

    func decodeState(from r: inout StateReader) throws {
        try r.expect("PPU ")
        palette = try r.readBytes(); vram = try r.readBytes(); oam = try r.readBytes()
        dispcnt = try r.readUInt16(); dispstat = try r.readUInt16(); vcount = try r.readUInt16()
        bgControl = try r.readUInt16Array()
        bgHorizontalOffset = try r.readUInt16Array()
        bgVerticalOffset = try r.readUInt16Array()
        affineA = try r.readInt16Array(); affineB = try r.readInt16Array()
        affineC = try r.readInt16Array(); affineD = try r.readInt16Array()
        affineRefX = try r.readInt32Array(); affineRefY = try r.readInt32Array()
        affineCurrentX = try r.readInt32Array(); affineCurrentY = try r.readInt32Array()
        windowH = try r.readUInt16Array(); windowV = try r.readUInt16Array()
        windowIn = try r.readUInt16(); windowOut = try r.readUInt16()
        mosaic = try r.readUInt16(); blendControl = try r.readUInt16()
        blendAlpha = try r.readUInt16(); blendBrightness = try r.readUInt16()
        dot = try r.readInt(); frameComplete = try r.readBool()
    }
}
