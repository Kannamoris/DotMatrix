import Foundation

/// The GBA system bus: memory map, wait states, I/O dispatch and DMA.
final class GBABus: ARMBus {
    // MARK: Memory

    /// 16 KB BIOS region. Nintendo's image is copyrighted and not shipped; this
    /// holds a small dispatcher written here (see `installSyntheticBIOS`).
    private var bios = [UInt8](repeating: 0, count: 0x4000)
    private var ewram = [UInt8](repeating: 0, count: 0x40000)   // 256 KB
    private var iwram = [UInt8](repeating: 0, count: 0x8000)    // 32 KB

    let cartridge: GBACartridge
    let ppu: GBAPPU
    let apu: GBAAPU
    let interrupts = InterruptController()
    let timers: TimerUnit
    let dma: DMAController

    // MARK: State

    private var buttons: GBAButtons = []
    private var keyControl: UInt16 = 0
    private var waitControl: UInt16 = 0
    private var postFlag: UInt8 = 0

    /// Set by HALTCNT; cleared when an interrupt asserts.
    private(set) var halted = false

    /// Last value on the bus, returned for reads of unmapped regions.
    private var openBus: UInt32 = 0

    private(set) var totalCycles = 0

    /// Guards against a DMA that re-triggers itself through a register write.
    private var dmaInProgress = false

    weak var cpu: ARM7TDMI?

    init(cartridge: GBACartridge, sampleRate: Double) {
        self.cartridge = cartridge
        self.timers = TimerUnit(interrupts: interrupts)
        self.dma = DMAController(interrupts: interrupts)
        self.ppu = GBAPPU(interrupts: interrupts)
        self.apu = GBAAPU(sampleRate: sampleRate)
        installSyntheticBIOS()
    }

    /// The hardware's IRQ vector lives in BIOS, so with no BIOS image there is
    /// nothing to jump to. This installs a dispatcher — written here, not
    /// extracted — implementing the documented behaviour: save scratch
    /// registers, then jump through the handler pointer the game parks at
    /// 0x03007FFC.
    private func installSyntheticBIOS() {
        func writeWord(_ offset: Int, _ value: UInt32) {
            bios[offset]     = UInt8(value & 0xFF)
            bios[offset + 1] = UInt8((value >> 8) & 0xFF)
            bios[offset + 2] = UInt8((value >> 16) & 0xFF)
            bios[offset + 3] = UInt8((value >> 24) & 0xFF)
        }

        // 0x018: b 0x128
        writeWord(0x018, 0xEA00_0042)

        // 0x128: stmfd r13!, {r0-r3, r12, r14}
        writeWord(0x128, 0xE92D_500F)
        // 0x12C: mov r0, #0x04000000
        writeWord(0x12C, 0xE3A0_0301)
        // 0x130: add r14, r15, #0        — return address for the handler
        writeWord(0x130, 0xE28F_E000)
        // 0x134: ldr r15, [r0, #-4]      — jump via [0x03FFFFFC]
        writeWord(0x134, 0xE510_F004)
        // 0x138: ldmfd r13!, {r0-r3, r12, r14}
        writeWord(0x138, 0xE8BD_500F)
        // 0x13C: subs r15, r14, #4       — return, restoring CPSR from SPSR
        writeWord(0x13C, 0xE25E_F004)
    }

    // MARK: Cycle accounting

    /// Guards against re-entering peripheral stepping.
    private var insideTick = false
    /// Cycles banked by a re-entrant call, drained by the outer one.
    private var deferredCycles = 0

    /// Advance every peripheral. The PPU can raise DMA-triggering events, so
    /// those are serviced here rather than by the caller.
    func tick(_ cycles: Int) {
        guard cycles > 0 else { return }
        totalCycles += cycles

        // Stepping the PPU can start a DMA, and that DMA's memory accesses come
        // straight back through here. Rather than recursing — which is
        // unbounded, since each transfer costs cycles that trigger more
        // stepping — bank the cycles and let the outer call drain them.
        if insideTick {
            deferredCycles += cycles
            return
        }

        insideTick = true
        defer { insideTick = false }

        var pending = cycles
        while pending > 0 {
            advancePeripherals(pending)
            pending = deferredCycles
            deferredCycles = 0
        }
    }

    private func advancePeripherals(_ cycles: Int) {
        timers.step(cycles)
        // Timer overflows clock the sound FIFOs, which pull more samples in.
        // Only timers 0 and 1 can drive Direct Sound.
        for timer in 0...1 {
            let overflows = timers.overflowedThisStep[timer]
            guard overflows > 0 else { continue }
            apu.timerOverflow(timer, times: overflows) { runSoundDMA(timer: timer) }
        }

        apu.step(cycles)

        ppu.step(cycles)
        if ppu.consumeHBlankTrigger() { runDMA(timing: .hblank) }
        if ppu.consumeVBlankTrigger() { runDMA(timing: .vblank) }
    }

    func idle(_ cycles: Int) {
        tick(cycles)
    }

    var irqPending: Bool {
        interrupts.hasPendingRequest
    }

    // MARK: Wait states

    /// Cycles a given access costs, by region. ROM timings come from WAITCNT.
    private func waitCycles(for address: UInt32, width: Int, sequential: Bool) -> Int {
        switch (address >> 24) & 0xF {
        case 0x0, 0x3, 0x4, 0x7:
            // BIOS, IWRAM, I/O and OAM sit on a 32-bit bus with no wait states.
            return 1
        case 0x2:
            // EWRAM is a 16-bit bus behind two wait states.
            return width == 4 ? 6 : 3
        case 0x5, 0x6:
            // Palette RAM and VRAM are 16-bit, so a word access costs double.
            return width == 4 ? 2 : 1
        case 0x8, 0x9, 0xA, 0xB, 0xC, 0xD:
            let region = Int(((address >> 24) & 0xF) - 0x8) / 2
            let cost = romWaitCycles(region: region, sequential: sequential)
            // A 32-bit ROM read is two 16-bit accesses, the second sequential.
            return width == 4 ? cost + romWaitCycles(region: region, sequential: true) : cost
        case 0xE, 0xF:
            return sramWaitCycles()
        default:
            return 1
        }
    }

    private static let nonSequentialTable = [4, 3, 2, 8]

    private func romWaitCycles(region: Int, sequential: Bool) -> Int {
        switch region {
        case 0:
            if sequential { return (waitControl & 0x0010) != 0 ? 2 : 3 }
            return Self.nonSequentialTable[Int((waitControl >> 2) & 0x3)] + 1
        case 1:
            if sequential { return (waitControl & 0x0080) != 0 ? 2 : 5 }
            return Self.nonSequentialTable[Int((waitControl >> 5) & 0x3)] + 1
        default:
            if sequential { return (waitControl & 0x0400) != 0 ? 2 : 9 }
            return Self.nonSequentialTable[Int((waitControl >> 8) & 0x3)] + 1
        }
    }

    private func sramWaitCycles() -> Int {
        Self.nonSequentialTable[Int(waitControl & 0x3)] + 1
    }

    // MARK: ARMBus — reads

    func read8(_ address: UInt32, sequential: Bool) -> UInt8 {
        tick(waitCycles(for: address, width: 1, sequential: sequential))
        return readByte(address)
    }

    func read16(_ address: UInt32, sequential: Bool) -> UInt16 {
        tick(waitCycles(for: address, width: 2, sequential: sequential))
        let aligned = address & ~1
        return UInt16(readByte(aligned)) | (UInt16(readByte(aligned &+ 1)) << 8)
    }

    func read32(_ address: UInt32, sequential: Bool) -> UInt32 {
        tick(waitCycles(for: address, width: 4, sequential: sequential))
        let aligned = address & ~3
        var value = UInt32(readByte(aligned))
        value |= UInt32(readByte(aligned &+ 1)) << 8
        value |= UInt32(readByte(aligned &+ 2)) << 16
        value |= UInt32(readByte(aligned &+ 3)) << 24
        openBus = value
        return value
    }

    /// Read a byte without advancing the clock or touching open-bus state.
    ///
    /// Used by the overlay to inspect game memory between frames. Going through
    /// `read8` instead would charge wait states for accesses the emulated CPU
    /// never made, and would drift the whole machine's timing.
    func peek(_ address: UInt32) -> UInt8 {
        readByte(address)
    }

    private func readByte(_ address: UInt32) -> UInt8 {
        switch (address >> 24) & 0xF {
        case 0x0:
            let offset = Int(address & 0x3FFF)
            return offset < bios.count ? bios[offset] : 0
        case 0x2:
            return ewram[Int(address & 0x3FFFF)]
        case 0x3:
            return iwram[Int(address & 0x7FFF)]
        case 0x4:
            return readIOByte(address)
        case 0x5:
            return ppu.readPalette(address & 0x3FF)
        case 0x6:
            return ppu.readVRAM(vramOffset(address))
        case 0x7:
            return ppu.readOAM(address & 0x3FF)
        case 0x8, 0x9, 0xA, 0xB, 0xC, 0xD:
            let offset = Int(address & 0x01FF_FFFF)
            return offset < cartridge.rom.count ? cartridge.rom[offset] : 0
        case 0xE, 0xF:
            return cartridge.backup.read(address & 0xFFFF)
        default:
            return UInt8(openBus & 0xFF)
        }
    }

    /// VRAM is 96 KB in a 128 KB window: the last 32 KB block is mirrored twice.
    private func vramOffset(_ address: UInt32) -> UInt32 {
        var offset = address & 0x1FFFF
        if offset >= 0x18000 { offset -= 0x8000 }
        return offset
    }

    // MARK: ARMBus — writes

    func write8(_ address: UInt32, _ value: UInt8, sequential: Bool) {
        tick(waitCycles(for: address, width: 1, sequential: sequential))

        switch (address >> 24) & 0xF {
        case 0x2: ewram[Int(address & 0x3FFFF)] = value
        case 0x3: iwram[Int(address & 0x7FFF)] = value
        case 0x4: writeIOByte(address, value)
        case 0x5:
            // Palette RAM and VRAM have no byte lanes: an 8-bit write is
            // mirrored across the halfword. OAM ignores byte writes entirely.
            ppu.writePalette16(address & 0x3FE, UInt16(value) << 8 | UInt16(value))
        case 0x6:
            let offset = vramOffset(address)
            // Byte writes to the sprite region are dropped by the hardware.
            if offset < ppu.objectVRAMBase {
                ppu.writeVRAM16(offset & ~1, UInt16(value) << 8 | UInt16(value))
            }
        case 0x7:
            break
        case 0xE, 0xF:
            cartridge.backup.write(address & 0xFFFF, value)
        default:
            break
        }
    }

    func write16(_ address: UInt32, _ value: UInt16, sequential: Bool) {
        tick(waitCycles(for: address, width: 2, sequential: sequential))
        writeHalf(address & ~1, value)
    }

    func write32(_ address: UInt32, _ value: UInt32, sequential: Bool) {
        tick(waitCycles(for: address, width: 4, sequential: sequential))
        let aligned = address & ~3
        writeHalf(aligned, UInt16(value & 0xFFFF))
        writeHalf(aligned &+ 2, UInt16(value >> 16))
    }

    private func writeHalf(_ address: UInt32, _ value: UInt16) {
        switch (address >> 24) & 0xF {
        case 0x2:
            let offset = Int(address & 0x3FFFF)
            ewram[offset] = UInt8(value & 0xFF)
            ewram[offset + 1] = UInt8(value >> 8)
        case 0x3:
            let offset = Int(address & 0x7FFF)
            iwram[offset] = UInt8(value & 0xFF)
            iwram[offset + 1] = UInt8(value >> 8)
        case 0x4:
            writeIO(address & ~1, value)
        case 0x5:
            ppu.writePalette16(address & 0x3FE, value)
        case 0x6:
            ppu.writeVRAM16(vramOffset(address) & ~1, value)
        case 0x7:
            ppu.writeOAM16(address & 0x3FE, value)
        case 0xE, 0xF:
            cartridge.backup.write(address & 0xFFFF, UInt8(value & 0xFF))
        default:
            break
        }
    }

    // MARK: I/O

    private func readIOByte(_ address: UInt32) -> UInt8 {
        let half = readIO(address & ~1)
        return address & 1 == 0 ? UInt8(half & 0xFF) : UInt8(half >> 8)
    }

    private func writeIOByte(_ address: UInt32, _ value: UInt8) {
        let aligned = address & ~1
        let existing = readIO(aligned)
        let merged: UInt16 = address & 1 == 0
            ? (existing & 0xFF00) | UInt16(value)
            : (existing & 0x00FF) | (UInt16(value) << 8)
        writeIO(aligned, merged)
    }

    private func readIO(_ address: UInt32) -> UInt16 {
        let register = address & 0xFFF

        switch register {
        case 0x000...0x056:
            return ppu.readRegister(register)

        case 0x060...0x0A6:
            return apu.readRegister(register)

        case 0x0B0...0x0DE:
            let channel = Int((register - 0x0B0) / 12)
            let field = (register - 0x0B0) % 12
            guard channel < 4 else { return 0 }
            // Source, destination and word count are write-only.
            return field == 10 ? dma.channels[channel].control : 0

        case 0x100...0x10E:
            let timer = Int((register - 0x100) / 4)
            return (register - 0x100) % 4 == 0
                ? timers.readCounter(timer)
                : timers.readControl(timer)

        case 0x130:
            // KEYINPUT is active-low: a held button reads as 0.
            return ~buttons.rawValue & 0x03FF
        case 0x132:
            return keyControl

        case 0x200: return interrupts.enable
        case 0x202: return interrupts.flags
        case 0x204: return waitControl
        case 0x208: return interrupts.masterEnable ? 1 : 0
        case 0x300: return UInt16(postFlag)

        default:
            return UInt16(openBus & 0xFFFF)
        }
    }

    private func writeIO(_ address: UInt32, _ value: UInt16) {
        let register = address & 0xFFF

        switch register {
        case 0x000...0x056:
            ppu.writeRegister(register, value)

        case 0x060...0x0A6:
            apu.writeRegister(register, value)

        case 0x0B0...0x0DE:
            let channel = Int((register - 0x0B0) / 12)
            guard channel < 4 else { return }
            switch (register - 0x0B0) % 12 {
            case 0: dma.channels[channel].source =
                (dma.channels[channel].source & 0xFFFF_0000) | UInt32(value)
            case 2: dma.channels[channel].source =
                (dma.channels[channel].source & 0x0000_FFFF) | (UInt32(value) << 16)
            case 4: dma.channels[channel].destination =
                (dma.channels[channel].destination & 0xFFFF_0000) | UInt32(value)
            case 6: dma.channels[channel].destination =
                (dma.channels[channel].destination & 0x0000_FFFF) | (UInt32(value) << 16)
            case 8: dma.channels[channel].wordCount = value
            default:
                dma.writeControl(channel, value)
                // An immediate-timing channel starts the moment it's enabled.
                if dma.channels[channel].enabled,
                   dma.channels[channel].timing == .immediate {
                    runDMA(timing: .immediate)
                }
            }

        case 0x100...0x10E:
            let timer = Int((register - 0x100) / 4)
            if (register - 0x100) % 4 == 0 {
                timers.writeReload(timer, value)
            } else {
                timers.writeControl(timer, value)
            }

        case 0x132:
            keyControl = value

        case 0x200:
            interrupts.enable = value & 0x3FFF
        case 0x202:
            // Write-1-to-clear.
            interrupts.acknowledge(value)
        case 0x204:
            waitControl = value
        case 0x208:
            interrupts.masterEnable = value & 1 != 0
        case 0x300:
            postFlag = UInt8(value & 0xFF)
        case 0x301:
            // HALTCNT: bit 15 clear halts the CPU until an interrupt arrives.
            if value & 0x8000 == 0 {
                halted = true
                cpu?.halted = true
            }

        default:
            break
        }
    }

    // MARK: DMA

    private func runDMA(timing: DMATiming) {
        guard !dmaInProgress else { return }
        dmaInProgress = true
        defer { dmaInProgress = false }

        while let channel = dma.pendingChannel(for: timing) {
            dma.run(channel) { source, destination, is32Bit in
                if is32Bit {
                    let word = self.read32(source, sequential: true)
                    self.write32(destination, word, sequential: true)
                } else {
                    let half = self.read16(source, sequential: true)
                    self.write16(destination, half, sequential: true)
                }
            }
            // `run` clears the channel, so a non-repeating one won't re-match.
            if !dma.channels[channel].active { continue }
            break
        }
    }

    /// Refill a sound FIFO from whichever DMA channel is feeding it.
    private func runSoundDMA(timer: Int) {
        for channel in 1...2 {
            let config = dma.channels[channel]
            guard config.enabled, config.active, config.timing == .special else { continue }
            // FIFO A is at 0x040000A0, FIFO B at 0x040000A4.
            let target = config.destination & 0xFFFF_FFFC
            let isFIFOA = target == 0x0400_00A0
            guard apu.fifoWantsRefill(a: isFIFOA, drivenBy: timer) else { continue }

            dma.runSoundFIFO(channel) { source, destination, _ in
                let word = self.read32(source, sequential: true)
                self.apu.pushFIFO(word, toA: destination & 0xFFFF_FFFC == 0x0400_00A0)
            }
        }
    }

    // MARK: Input

    func setButtons(_ newButtons: GBAButtons) {
        buttons = newButtons

        // KEYCNT bit 14 enables the keypad interrupt; bit 15 picks AND vs OR.
        guard keyControl & 0x4000 != 0 else { return }
        let mask = keyControl & 0x03FF
        let held = newButtons.rawValue & mask
        let requireAll = keyControl & 0x8000 != 0
        if (requireAll && held == mask && mask != 0) || (!requireAll && held != 0) {
            interrupts.request(.keypad)
        }
    }

    // MARK: BIOS calls

    /// The BIOS routines, implemented directly rather than run from Nintendo's
    /// image. Emerald leans on the decompression and memory-copy calls heavily.
    func handleSWI(comment: UInt32, cpu: ARM7TDMI) -> Bool {
        switch comment {
        case 0x00:  // SoftReset
            cpu.reset(entryPoint: 0x0800_0000)
            return true

        case 0x01:  // RegisterRamReset
            registerRAMReset(flags: cpu.registers[0])
            return true

        case 0x02:  // Halt
            halted = true
            cpu.halted = true
            return true

        case 0x03:  // Stop — treated as halt; the only wake source is the keypad
            halted = true
            cpu.halted = true
            return true

        case 0x04:  // IntrWait
            fallthrough
        case 0x05:  // VBlankIntrWait
            // Park the CPU; the dispatcher resumes it when the IRQ lands.
            if comment == 0x05 {
                cpu.registers[0] = 1
                cpu.registers[1] = UInt32(IRQSource.vblank.rawValue)
            }
            halted = true
            cpu.halted = true
            return true

        case 0x06:  // Div
            let numerator = Int32(bitPattern: cpu.registers[0])
            let denominator = Int32(bitPattern: cpu.registers[1])
            guard denominator != 0 else { return true }
            // Int32.min / -1 overflows; the hardware wraps rather than trapping.
            let quotient = (numerator == Int32.min && denominator == -1)
                ? Int32.min
                : numerator / denominator
            let remainder = (denominator == -1) ? 0 : numerator % denominator
            cpu.registers[0] = UInt32(bitPattern: quotient)
            cpu.registers[1] = UInt32(bitPattern: remainder)
            cpu.registers[3] = UInt32(bitPattern: abs(quotient))
            return true

        case 0x07:  // DivArm — same, operands reversed
            let denominator = Int32(bitPattern: cpu.registers[0])
            let numerator = Int32(bitPattern: cpu.registers[1])
            guard denominator != 0 else { return true }
            let quotient = (numerator == Int32.min && denominator == -1)
                ? Int32.min
                : numerator / denominator
            let remainder = (denominator == -1) ? 0 : numerator % denominator
            cpu.registers[0] = UInt32(bitPattern: quotient)
            cpu.registers[1] = UInt32(bitPattern: remainder)
            cpu.registers[3] = UInt32(bitPattern: abs(quotient))
            return true

        case 0x08:  // Sqrt
            cpu.registers[0] = UInt32(Double(cpu.registers[0]).squareRoot())
            return true

        case 0x09:  // ArcTan
            let value = Double(Int16(truncatingIfNeeded: Int32(bitPattern: cpu.registers[0]))) / 16384.0
            let result = atan(value) * 16384.0 / (.pi / 2) * 0.25
            cpu.registers[0] = UInt32(bitPattern: Int32(result))
            return true

        case 0x0A:  // ArcTan2
            let x = Double(Int16(truncatingIfNeeded: Int32(bitPattern: cpu.registers[0])))
            let y = Double(Int16(truncatingIfNeeded: Int32(bitPattern: cpu.registers[1])))
            var angle = atan2(y, x)
            if angle < 0 { angle += 2 * .pi }
            cpu.registers[0] = UInt32(angle / (2 * .pi) * 65536.0) & 0xFFFF
            return true

        case 0x0B:  // CpuSet
            cpuSet(cpu: cpu, fast: false)
            return true

        case 0x0C:  // CpuFastSet
            cpuSet(cpu: cpu, fast: true)
            return true

        case 0x0E:  // BgAffineSet
            return true

        case 0x11, 0x12:  // LZ77UnCompWram / LZ77UnCompVram
            decompressLZ77(source: cpu.registers[0], destination: cpu.registers[1],
                           toVRAM: comment == 0x12)
            return true

        case 0x13:  // HuffUnComp
            decompressHuffman(source: cpu.registers[0], destination: cpu.registers[1])
            return true

        case 0x14, 0x15:  // RLUnCompWram / RLUnCompVram
            decompressRLE(source: cpu.registers[0], destination: cpu.registers[1],
                          toVRAM: comment == 0x15)
            return true

        default:
            // Anything unimplemented is a no-op rather than a vector into a
            // BIOS that isn't there.
            return true
        }
    }

    private func registerRAMReset(flags: UInt32) {
        if flags & 0x01 != 0 { for i in ewram.indices { ewram[i] = 0 } }
        if flags & 0x02 != 0 {
            // The top 0x200 bytes hold the stacks and IRQ vector; the BIOS
            // leaves them intact.
            for i in 0..<(iwram.count - 0x200) { iwram[i] = 0 }
        }
        if flags & 0x04 != 0 { ppu.clearPalette() }
        if flags & 0x08 != 0 { ppu.clearVRAM() }
        if flags & 0x10 != 0 { ppu.clearOAM() }
    }

    private func cpuSet(cpu: ARM7TDMI, fast: Bool) {
        let source = cpu.registers[0]
        let destination = cpu.registers[1]
        let control = cpu.registers[2]

        let count = Int(control & 0x001F_FFFF)
        let fixedSource = control & 0x0100_0000 != 0
        // CpuFastSet is always 32-bit and works in blocks of eight words.
        let use32Bit = fast || (control & 0x0400_0000 != 0)

        guard count > 0 else { return }

        if use32Bit {
            let word = fixedSource ? read32(source, sequential: false) : 0
            for i in 0..<count {
                let offset = UInt32(i) * 4
                let value = fixedSource ? word : read32(source &+ offset, sequential: true)
                write32(destination &+ offset, value, sequential: true)
            }
        } else {
            let half = fixedSource ? read16(source, sequential: false) : 0
            for i in 0..<count {
                let offset = UInt32(i) * 2
                let value = fixedSource ? half : read16(source &+ offset, sequential: true)
                write16(destination &+ offset, value, sequential: true)
            }
        }
    }

    // MARK: Decompression
    //
    // These formats are documented parts of the BIOS interface. Emerald stores
    // most of its graphics compressed, so a game will not render at all without
    // at least LZ77.

    private func decompressLZ77(source: UInt32, destination: UInt32, toVRAM: Bool) {
        let header = read32(source, sequential: false)
        let size = Int(header >> 8)
        guard size > 0 else { return }

        var readPointer = source &+ 4
        var written = 0
        // VRAM can't take byte writes, so output is staged a halfword at a time.
        var pending: UInt8 = 0
        var hasPending = false

        func emit(_ byte: UInt8) {
            guard written < size else { return }
            let target = destination &+ UInt32(written)
            if toVRAM {
                if hasPending {
                    write16(target &- 1, UInt16(pending) | (UInt16(byte) << 8), sequential: true)
                    hasPending = false
                } else {
                    pending = byte
                    hasPending = true
                }
            } else {
                write8(target, byte, sequential: true)
            }
            written += 1
        }

        while written < size {
            let flags = read8(readPointer, sequential: true)
            readPointer &+= 1

            for bit in (0..<8).reversed() {
                guard written < size else { break }

                if flags & (1 << UInt8(bit)) == 0 {
                    // Literal byte.
                    emit(read8(readPointer, sequential: true))
                    readPointer &+= 1
                } else {
                    // Back-reference: 4-bit length, 12-bit distance.
                    let first = read8(readPointer, sequential: true)
                    let second = read8(readPointer &+ 1, sequential: true)
                    readPointer &+= 2

                    let length = Int(first >> 4) + 3
                    let distance = (Int(first & 0x0F) << 8 | Int(second)) + 1

                    for _ in 0..<length {
                        guard written < size else { break }
                        let sourceIndex = written - distance
                        guard sourceIndex >= 0 else { emit(0); continue }
                        // Read back what was already written, which is how the
                        // format expresses runs longer than the distance.
                        let byte = readDecompressedByte(destination: destination,
                                                        index: sourceIndex,
                                                        pending: pending,
                                                        hasPending: hasPending,
                                                        written: written)
                        emit(byte)
                    }
                }
            }
        }

        // Flush a trailing odd byte.
        if toVRAM && hasPending {
            let target = destination &+ UInt32(written) &- 1
            write16(target, UInt16(pending), sequential: true)
        }
    }

    /// Read a byte already emitted by the current decompression run.
    private func readDecompressedByte(destination: UInt32, index: Int,
                                      pending: UInt8, hasPending: Bool,
                                      written: Int) -> UInt8 {
        // The most recent byte may still be staged rather than committed.
        if hasPending && index == written - 1 { return pending }
        return readByte(destination &+ UInt32(index))
    }

    private func decompressRLE(source: UInt32, destination: UInt32, toVRAM: Bool) {
        let header = read32(source, sequential: false)
        let size = Int(header >> 8)
        guard size > 0 else { return }

        var readPointer = source &+ 4
        var written = 0
        var pending: UInt8 = 0
        var hasPending = false

        func emit(_ byte: UInt8) {
            guard written < size else { return }
            let target = destination &+ UInt32(written)
            if toVRAM {
                if hasPending {
                    write16(target &- 1, UInt16(pending) | (UInt16(byte) << 8), sequential: true)
                    hasPending = false
                } else {
                    pending = byte
                    hasPending = true
                }
            } else {
                write8(target, byte, sequential: true)
            }
            written += 1
        }

        while written < size {
            let control = read8(readPointer, sequential: true)
            readPointer &+= 1

            if control & 0x80 != 0 {
                // Compressed run: one byte repeated.
                let length = Int(control & 0x7F) + 3
                let byte = read8(readPointer, sequential: true)
                readPointer &+= 1
                for _ in 0..<length { emit(byte) }
            } else {
                // Literal run.
                let length = Int(control & 0x7F) + 1
                for _ in 0..<length {
                    emit(read8(readPointer, sequential: true))
                    readPointer &+= 1
                }
            }
        }

        if toVRAM && hasPending {
            write16(destination &+ UInt32(written) &- 1, UInt16(pending), sequential: true)
        }
    }

    private func decompressHuffman(source: UInt32, destination: UInt32) {
        let header = read32(source, sequential: false)
        let size = Int(header >> 8)
        let symbolBits = Int(header & 0x0F)
        guard size > 0, symbolBits > 0 else { return }

        let treeSize = (Int(read8(source &+ 4, sequential: false)) + 1) * 2
        let treeBase = source &+ 5
        var streamPointer = source &+ 4 &+ UInt32(treeSize)

        var output = [UInt8]()
        output.reserveCapacity(size)

        var nodeOffset = 0
        var currentByte: UInt32 = 0
        var accumulated = 0
        var accumulatedBits = 0

        var bitBuffer = read32(streamPointer, sequential: false)
        streamPointer &+= 4
        var bitsLeft = 32

        while output.count < size {
            if bitsLeft == 0 {
                bitBuffer = read32(streamPointer, sequential: true)
                streamPointer &+= 4
                bitsLeft = 32
            }

            let bit = (bitBuffer >> 31) & 1
            bitBuffer <<= 1
            bitsLeft -= 1

            let node = read8(treeBase &+ UInt32(nodeOffset), sequential: true)
            // Child nodes sit at the next even offset plus the branch index.
            let nextOffset = ((nodeOffset >> 1) + Int(node & 0x3F) + 1) << 1 | Int(bit)
            let isLeaf = bit == 0 ? (node & 0x80) != 0 : (node & 0x40) != 0

            if isLeaf {
                let symbol = read8(treeBase &+ UInt32(nextOffset), sequential: true)
                accumulated |= Int(symbol) << accumulatedBits
                accumulatedBits += symbolBits

                if accumulatedBits >= 8 {
                    output.append(UInt8(accumulated & 0xFF))
                    accumulated >>= 8
                    accumulatedBits -= 8
                }
                nodeOffset = 0
            } else {
                nodeOffset = nextOffset
            }

            currentByte &+= 1
            // Guard against a malformed stream spinning forever.
            if currentByte > UInt32(size) * 64 { break }
        }

        for (index, byte) in output.enumerated() where index < size {
            write8(destination &+ UInt32(index), byte, sequential: true)
        }
    }

    // MARK: Halt

    /// Called by the system loop after each step to clear halt on an interrupt.
    func updateHaltState() {
        if halted && interrupts.hasPendingRequest {
            halted = false
            cpu?.halted = false
        }
    }
}
