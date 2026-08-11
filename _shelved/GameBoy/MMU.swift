import Foundation

/// The system bus.
///
/// Every CPU memory access goes through here, and every access also advances
/// the rest of the machine by one M-cycle. Driving the peripherals from the
/// memory bus rather than from a post-instruction cycle count is what keeps the
/// timer, the PPU and DMA in step with the CPU without a separate schedule.
final class MMU {
    let cartridge: Cartridge
    let ppu: PPU
    let apu: APU
    let timer = GBTimer()
    let joypad = Joypad()

    let isCGB: Bool

    private var wram: [UInt8]
    private var hram = [UInt8](repeating: 0, count: 0x7F)
    private var wramBank = 1

    /// Interrupt flag / enable, 0xFF0F and 0xFFFF.
    var interruptFlag: UInt8 = 0xE1
    var interruptEnable: UInt8 = 0x00

    // Serial. There is no link cable, so a transfer just clocks in 0xFF —
    // which is what a real Game Boy sees with nothing plugged in.
    private var serialData: UInt8 = 0
    private var serialControl: UInt8 = 0x7E
    private var serialCountdown = 0

    // CGB speed switch.
    private(set) var doubleSpeed = false
    private var speedSwitchArmed = false

    // OAM DMA.
    private var dmaSource: UInt16 = 0
    private var dmaIndex = 0
    private var dmaActive = false
    private var dmaStartDelay = 0

    // CGB HDMA / GDMA.
    private var hdmaSource: UInt16 = 0
    private var hdmaDest: UInt16 = 0
    private var hdmaLength = 0
    private var hdmaActive = false

    /// Cycles consumed by an HDMA block, to be charged to the CPU.
    private(set) var stolenCycles = 0

    /// T-cycles elapsed on the CPU clock since the machine started.
    private(set) var totalCycles = 0
    /// Leftover when halving the CPU clock for the PPU/APU in double speed.
    private var halfCycleRemainder = 0

    init(cartridge: Cartridge, preferCGB: Bool, sampleRate: Double) {
        self.cartridge = cartridge
        switch cartridge.colorSupport {
        case .cgbOnly:
            // Refuses to run any other way.
            self.isCGB = true
        case .cgbCompatible:
            self.isCGB = preferCGB
        case .dmgOnly:
            // A monochrome-only cartridge never writes CGB palette RAM, so in
            // colour mode it would render pure white. Real hardware papers over
            // this with a compatibility palette installed by the boot ROM,
            // which is Nintendo's code and is not shipped here — so these
            // cartridges always run as a monochrome Game Boy and get their
            // colours from the user's chosen palette instead.
            self.isCGB = false
        }
        self.ppu = PPU(isCGB: self.isCGB)
        self.apu = APU(sampleRate: sampleRate)
        // CGB has 8 switchable 4 KB WRAM banks; DMG has a flat 8 KB.
        self.wram = [UInt8](repeating: 0, count: self.isCGB ? 0x8000 : 0x2000)
    }

    // MARK: Clock

    /// Advance every peripheral by `cycles` CPU T-cycles.
    func tick(_ cycles: Int) {
        totalCycles += cycles

        // DIV and the timer are driven by the CPU clock, so they double too.
        timer.tick(cycles)
        if timer.interruptRequested {
            timer.interruptRequested = false
            interruptFlag |= 0x04
        }

        stepOAMDMA(cycles)
        stepSerial(cycles)

        // The PPU and APU keep running at the original 4.19 MHz regardless.
        var displayCycles = cycles
        if doubleSpeed {
            halfCycleRemainder += cycles
            displayCycles = halfCycleRemainder / 2
            halfCycleRemainder %= 2
        }

        if displayCycles > 0 {
            ppu.tick(displayCycles)
            apu.tick(displayCycles)

            if ppu.vblankInterruptRequested {
                ppu.vblankInterruptRequested = false
                interruptFlag |= 0x01
            }
            if ppu.statInterruptRequested {
                ppu.statInterruptRequested = false
                interruptFlag |= 0x02
            }
            if ppu.enteredHBlank {
                stepHDMA()
            }
        }

        if joypad.interruptRequested {
            joypad.interruptRequested = false
            interruptFlag |= 0x10
        }
    }

    /// One M-cycle. Called by the CPU for each bus access and internal delay.
    @inline(__always)
    func tickCycle() {
        tick(4)
    }

    // MARK: Reads and writes
    //
    // These do *not* tick; the CPU calls `tickCycle()` around them so that the
    // ordering of the access relative to peripheral state stays explicit.

    func read(_ addr: UInt16) -> UInt8 {
        switch addr {
        case 0x0000...0x7FFF:
            return cartridge.mbc.readROM(addr)
        case 0x8000...0x9FFF:
            return ppu.readVRAM(addr)
        case 0xA000...0xBFFF:
            return cartridge.mbc.readRAM(addr)
        case 0xC000...0xCFFF:
            return wram[Int(addr - 0xC000)]
        case 0xD000...0xDFFF:
            return wram[wramBank * 0x1000 + Int(addr - 0xD000)]
        case 0xE000...0xFDFF:
            // Echo RAM mirrors C000-DDFF.
            return read(addr - 0x2000)
        case 0xFE00...0xFE9F:
            // OAM is inaccessible to the CPU while a DMA is in flight.
            return dmaActive ? 0xFF : ppu.readOAM(addr)
        case 0xFEA0...0xFEFF:
            return 0x00
        case 0xFF00...0xFF7F:
            return readIO(addr)
        case 0xFF80...0xFFFE:
            return hram[Int(addr - 0xFF80)]
        default:
            return interruptEnable
        }
    }

    func write(_ addr: UInt16, _ value: UInt8) {
        switch addr {
        case 0x0000...0x7FFF:
            cartridge.mbc.writeControl(addr, value)
        case 0x8000...0x9FFF:
            ppu.writeVRAM(addr, value)
        case 0xA000...0xBFFF:
            cartridge.mbc.writeRAM(addr, value)
        case 0xC000...0xCFFF:
            wram[Int(addr - 0xC000)] = value
        case 0xD000...0xDFFF:
            wram[wramBank * 0x1000 + Int(addr - 0xD000)] = value
        case 0xE000...0xFDFF:
            write(addr - 0x2000, value)
        case 0xFE00...0xFE9F:
            if !dmaActive { ppu.writeOAM(addr, value) }
        case 0xFEA0...0xFEFF:
            break
        case 0xFF00...0xFF7F:
            writeIO(addr, value)
        case 0xFF80...0xFFFE:
            hram[Int(addr - 0xFF80)] = value
        default:
            interruptEnable = value
        }
    }

    // MARK: I/O

    private func readIO(_ addr: UInt16) -> UInt8 {
        switch addr {
        case 0xFF00: return joypad.read()
        case 0xFF01: return serialData
        case 0xFF02: return serialControl | (isCGB ? 0x7C : 0x7E)
        case 0xFF04: return timer.div
        case 0xFF05: return timer.tima
        case 0xFF06: return timer.tma
        case 0xFF07: return timer.tac
        case 0xFF0F: return interruptFlag | 0xE0
        case 0xFF10...0xFF3F: return apu.read(addr)

        case 0xFF40: return ppu.lcdc
        case 0xFF41: return ppu.stat
        case 0xFF42: return ppu.scy
        case 0xFF43: return ppu.scx
        case 0xFF44: return ppu.ly
        case 0xFF45: return ppu.lyc
        case 0xFF46: return UInt8(dmaSource >> 8)
        case 0xFF47: return ppu.bgp
        case 0xFF48: return ppu.obp0
        case 0xFF49: return ppu.obp1
        case 0xFF4A: return ppu.wy
        case 0xFF4B: return ppu.wx

        case 0xFF4D:
            guard isCGB else { return 0xFF }
            return (doubleSpeed ? 0x80 : 0x00) | (speedSwitchArmed ? 0x01 : 0x00) | 0x7E
        case 0xFF4F:
            guard isCGB else { return 0xFF }
            return UInt8(ppu.vramBank) | 0xFE

        case 0xFF51: return isCGB ? UInt8(hdmaSource >> 8) : 0xFF
        case 0xFF52: return isCGB ? UInt8(hdmaSource & 0xFF) : 0xFF
        case 0xFF53: return isCGB ? UInt8(hdmaDest >> 8) : 0xFF
        case 0xFF54: return isCGB ? UInt8(hdmaDest & 0xFF) : 0xFF
        case 0xFF55:
            guard isCGB else { return 0xFF }
            // Bit 7 low means a transfer is still running.
            let remaining = UInt8((max(0, hdmaLength) / 0x10).saturatingByte)
            return hdmaActive ? (remaining &- 1) & 0x7F : 0xFF

        case 0xFF68: return isCGB ? ppu.bgPaletteIndex | 0x40 : 0xFF
        case 0xFF69: return isCGB ? ppu.readBGPaletteData() : 0xFF
        case 0xFF6A: return isCGB ? ppu.objPaletteIndex | 0x40 : 0xFF
        case 0xFF6B: return isCGB ? ppu.readOBJPaletteData() : 0xFF
        case 0xFF70: return isCGB ? UInt8(wramBank) | 0xF8 : 0xFF

        default:
            return 0xFF
        }
    }

    private func writeIO(_ addr: UInt16, _ value: UInt8) {
        switch addr {
        case 0xFF00: joypad.write(value)
        case 0xFF01: serialData = value
        case 0xFF02:
            serialControl = value & 0x83
            if value & 0x80 != 0 && value & 0x01 != 0 {
                // Internal clock: 8 bits at 8192 Hz.
                serialCountdown = 512 * 8
            }
        case 0xFF04: timer.resetDIV()
        case 0xFF05: timer.writeTIMA(value)
        case 0xFF06: timer.writeTMA(value)
        case 0xFF07: timer.writeTAC(value)
        case 0xFF0F: interruptFlag = value & 0x1F
        case 0xFF10...0xFF3F: apu.write(addr, value)

        case 0xFF40: ppu.writeLCDC(value)
        case 0xFF41: ppu.stat = value
        case 0xFF42: ppu.scy = value
        case 0xFF43: ppu.scx = value
        case 0xFF44: break   // LY is read-only
        case 0xFF45:
            ppu.lyc = value
            ppu.lycChanged()
        case 0xFF46:
            dmaSource = UInt16(value) << 8
            dmaIndex = 0
            dmaActive = true
            // The transfer begins after a short delay, during which OAM is
            // still readable.
            dmaStartDelay = 8
        case 0xFF47: ppu.bgp = value
        case 0xFF48: ppu.obp0 = value
        case 0xFF49: ppu.obp1 = value
        case 0xFF4A: ppu.wy = value
        case 0xFF4B: ppu.wx = value

        case 0xFF4D:
            guard isCGB else { return }
            speedSwitchArmed = value & 0x01 != 0
        case 0xFF4F:
            guard isCGB else { return }
            ppu.vramBank = Int(value & 0x01)

        case 0xFF51: hdmaSource = (hdmaSource & 0x00FF) | (UInt16(value) << 8)
        case 0xFF52: hdmaSource = (hdmaSource & 0xFF00) | UInt16(value & 0xF0)
        case 0xFF53: hdmaDest = (hdmaDest & 0x00FF) | (UInt16(value & 0x1F) << 8)
        case 0xFF54: hdmaDest = (hdmaDest & 0xFF00) | UInt16(value & 0xF0)
        case 0xFF55:
            guard isCGB else { return }
            startHDMA(value)

        case 0xFF68: ppu.bgPaletteIndex = value
        case 0xFF69: ppu.writeBGPaletteData(value)
        case 0xFF6A: ppu.objPaletteIndex = value
        case 0xFF6B: ppu.writeOBJPaletteData(value)
        case 0xFF70:
            guard isCGB else { return }
            // Bank 0 is an alias for bank 1.
            wramBank = max(1, Int(value & 0x07))

        default:
            break
        }
    }

    // MARK: Speed switch

    /// Called by the CPU when it executes STOP with a switch armed.
    /// Returns true if the speed actually changed.
    @discardableResult
    func performSpeedSwitch() -> Bool {
        guard isCGB, speedSwitchArmed else { return false }
        doubleSpeed.toggle()
        speedSwitchArmed = false
        halfCycleRemainder = 0
        return true
    }

    // MARK: OAM DMA

    private func stepOAMDMA(_ cycles: Int) {
        guard dmaActive else { return }

        var remaining = cycles
        if dmaStartDelay > 0 {
            let consumed = min(dmaStartDelay, remaining)
            dmaStartDelay -= consumed
            remaining -= consumed
        }

        // One byte per M-cycle, 160 bytes total.
        while remaining >= 4 && dmaIndex < 0xA0 {
            let src = dmaSource &+ UInt16(dmaIndex)
            // DMA reads bypass the OAM lock but otherwise use the normal map.
            let byte: UInt8
            switch src {
            case 0x0000...0x7FFF: byte = cartridge.mbc.readROM(src)
            case 0x8000...0x9FFF: byte = ppu.readVRAM(src)
            case 0xA000...0xBFFF: byte = cartridge.mbc.readRAM(src)
            case 0xC000...0xCFFF: byte = wram[Int(src - 0xC000)]
            case 0xD000...0xDFFF: byte = wram[wramBank * 0x1000 + Int(src - 0xD000)]
            default:              byte = 0xFF
            }
            ppu.oam[dmaIndex] = byte
            dmaIndex += 1
            remaining -= 4
        }

        if dmaIndex >= 0xA0 {
            dmaActive = false
        }
    }

    // MARK: HDMA (CGB)

    private func startHDMA(_ value: UInt8) {
        let length = (Int(value & 0x7F) + 1) * 0x10

        if value & 0x80 == 0 {
            if hdmaActive {
                // Writing with bit 7 clear during an HBlank transfer cancels it.
                hdmaActive = false
                return
            }
            // General-purpose DMA: the whole block moves at once and the CPU
            // is stalled for the duration.
            copyHDMABlock(bytes: length)
            hdmaLength = 0
            stolenCycles += (length / 0x10) * (doubleSpeed ? 64 : 32)
        } else {
            hdmaLength = length
            hdmaActive = true
        }
    }

    private func stepHDMA() {
        guard hdmaActive, hdmaLength > 0 else { return }
        copyHDMABlock(bytes: 0x10)
        hdmaLength -= 0x10
        stolenCycles += doubleSpeed ? 64 : 32
        if hdmaLength <= 0 {
            hdmaActive = false
            hdmaLength = 0
        }
    }

    private func copyHDMABlock(bytes: Int) {
        for _ in 0..<bytes {
            let src = hdmaSource
            let dst = 0x8000 | (hdmaDest & 0x1FFF)

            let byte: UInt8
            switch src {
            case 0x0000...0x7FFF: byte = cartridge.mbc.readROM(src)
            case 0xA000...0xBFFF: byte = cartridge.mbc.readRAM(src)
            case 0xC000...0xCFFF: byte = wram[Int(src - 0xC000)]
            case 0xD000...0xDFFF: byte = wram[wramBank * 0x1000 + Int(src - 0xD000)]
            default:              byte = 0xFF   // VRAM is not a legal source
            }
            ppu.writeVRAM(dst, byte)

            hdmaSource = hdmaSource &+ 1
            hdmaDest = hdmaDest &+ 1
        }
    }

    func consumeStolenCycles() -> Int {
        defer { stolenCycles = 0 }
        return stolenCycles
    }

    // MARK: Serial

    private func stepSerial(_ cycles: Int) {
        guard serialCountdown > 0 else { return }
        serialCountdown -= cycles
        guard serialCountdown <= 0 else { return }
        serialCountdown = 0
        // Nothing is connected, so every bit shifted in reads as 1.
        serialData = 0xFF
        serialControl &= 0x7F
        interruptFlag |= 0x08
    }

    // MARK: Post-boot state
    //
    // No boot ROM is shipped — it is Nintendo's copyrighted code. Instead the
    // registers are set to the values the boot ROM would have left behind, and
    // execution starts at 0x0100 as it would on handoff.

    func applyPostBootState() {
        write(0xFF05, 0x00)   // TIMA
        write(0xFF06, 0x00)   // TMA
        write(0xFF07, 0x00)   // TAC
        interruptFlag = 0xE1

        // Sound: powered on with the boot chime's register values.
        apu.write(0xFF26, 0x80)
        let soundDefaults: [(UInt16, UInt8)] = [
            (0xFF10, 0x80), (0xFF11, 0xBF), (0xFF12, 0xF3), (0xFF14, 0xBF),
            (0xFF16, 0x3F), (0xFF17, 0x00), (0xFF19, 0xBF),
            (0xFF1A, 0x7F), (0xFF1B, 0xFF), (0xFF1C, 0x9F), (0xFF1E, 0xBF),
            (0xFF20, 0xFF), (0xFF21, 0x00), (0xFF22, 0x00), (0xFF23, 0xBF),
            (0xFF24, 0x77), (0xFF25, 0xF3),
        ]
        for (addr, value) in soundDefaults {
            apu.write(addr, value)
        }

        ppu.writeLCDC(0x91)
        ppu.scy = 0
        ppu.scx = 0
        ppu.lyc = 0
        ppu.bgp = 0xFC
        ppu.obp0 = 0xFF
        ppu.obp1 = 0xFF
        ppu.wy = 0
        ppu.wx = 0
        interruptEnable = 0x00

        if isCGB {
            // The CGB boot ROM leaves both palette memories filled with white,
            // which matters for games that draw before setting a palette.
            for i in 0..<64 {
                ppu.bgPaletteRAM[i] = 0xFF
                ppu.objPaletteRAM[i] = 0xFF
            }
        }
    }
}

private extension Int {
    /// Clamp to a byte without trapping, for register read-back.
    var saturatingByte: Int { Swift.max(0, Swift.min(255, self)) }
}
