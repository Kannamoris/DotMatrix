import Foundation

/// The Sharp LR35902 core.
///
/// Timing comes from the bus rather than a cycle table: every memory access
/// calls `bus.tickCycle()`, and instructions that burn extra internal M-cycles
/// call it directly. That keeps the CPU and peripherals interleaved correctly
/// without a separate schedule to keep in sync.
final class CPU {
    // MARK: Registers

    var a: UInt8 = 0x01
    var f: UInt8 = 0xB0
    var b: UInt8 = 0x00
    var c: UInt8 = 0x13
    var d: UInt8 = 0x00
    var e: UInt8 = 0xD8
    var h: UInt8 = 0x01
    var l: UInt8 = 0x4D
    var sp: UInt16 = 0xFFFE
    var pc: UInt16 = 0x0100

    var ime = false
    var halted = false
    var stopped = false

    /// EI enables interrupts only *after* the following instruction.
    private var eiDelay = 0
    /// Set when HALT is executed with interrupts pending but IME clear.
    private var haltBug = false

    let bus: MMU

    init(bus: MMU) {
        self.bus = bus
        // Values the boot ROM leaves in the registers on handoff. The CGB boot
        // ROM signals its hardware by putting 0x11 in A, which is how a dual-mode
        // cartridge decides whether to use colour.
        if bus.isCGB {
            a = 0x11; f = 0x80
            b = 0x00; c = 0x00
            d = 0xFF; e = 0x56
            h = 0x00; l = 0x0D
        }
    }

    // MARK: Flags

    private var zFlag: Bool {
        get { f & 0x80 != 0 }
        set { f = newValue ? f | 0x80 : f & ~0x80 }
    }
    private var nFlag: Bool {
        get { f & 0x40 != 0 }
        set { f = newValue ? f | 0x40 : f & ~0x40 }
    }
    private var hFlag: Bool {
        get { f & 0x20 != 0 }
        set { f = newValue ? f | 0x20 : f & ~0x20 }
    }
    private var cFlag: Bool {
        get { f & 0x10 != 0 }
        set { f = newValue ? f | 0x10 : f & ~0x10 }
    }

    private func setFlags(z: Bool, n: Bool, h halfCarry: Bool, c carry: Bool) {
        f = (z ? 0x80 : 0) | (n ? 0x40 : 0) | (halfCarry ? 0x20 : 0) | (carry ? 0x10 : 0)
    }

    // MARK: 16-bit register pairs

    var af: UInt16 {
        get { UInt16(a) << 8 | UInt16(f) }
        // The low nibble of F is not wired up and always reads back as zero.
        set { a = UInt8(newValue >> 8); f = UInt8(newValue & 0xF0) }
    }
    var bc: UInt16 {
        get { UInt16(b) << 8 | UInt16(c) }
        set { b = UInt8(newValue >> 8); c = UInt8(newValue & 0xFF) }
    }
    var de: UInt16 {
        get { UInt16(d) << 8 | UInt16(e) }
        set { d = UInt8(newValue >> 8); e = UInt8(newValue & 0xFF) }
    }
    var hl: UInt16 {
        get { UInt16(h) << 8 | UInt16(l) }
        set { h = UInt8(newValue >> 8); l = UInt8(newValue & 0xFF) }
    }

    // MARK: Bus helpers

    @inline(__always)
    private func read8(_ addr: UInt16) -> UInt8 {
        bus.tickCycle()
        return bus.read(addr)
    }

    @inline(__always)
    private func write8(_ addr: UInt16, _ value: UInt8) {
        bus.tickCycle()
        bus.write(addr, value)
    }

    @inline(__always)
    private func internalCycle() {
        bus.tickCycle()
    }

    @inline(__always)
    private func fetch8() -> UInt8 {
        let value = read8(pc)
        // The HALT bug makes the byte after HALT get read twice.
        if haltBug {
            haltBug = false
        } else {
            pc &+= 1
        }
        return value
    }

    @inline(__always)
    private func fetch16() -> UInt16 {
        let lo = UInt16(fetch8())
        let hi = UInt16(fetch8())
        return hi << 8 | lo
    }

    private func push16(_ value: UInt16) {
        sp &-= 1
        write8(sp, UInt8(value >> 8))
        sp &-= 1
        write8(sp, UInt8(value & 0xFF))
    }

    private func pop16() -> UInt16 {
        let lo = UInt16(read8(sp))
        sp &+= 1
        let hi = UInt16(read8(sp))
        sp &+= 1
        return hi << 8 | lo
    }

    // MARK: Register file indexed by opcode bits

    /// Operand order used throughout the opcode map:
    /// 0=B 1=C 2=D 3=E 4=H 5=L 6=(HL) 7=A
    private func readOperand(_ index: Int) -> UInt8 {
        switch index {
        case 0: return b
        case 1: return c
        case 2: return d
        case 3: return e
        case 4: return h
        case 5: return l
        case 6: return read8(hl)
        default: return a
        }
    }

    private func writeOperand(_ index: Int, _ value: UInt8) {
        switch index {
        case 0: b = value
        case 1: c = value
        case 2: d = value
        case 3: e = value
        case 4: h = value
        case 5: l = value
        case 6: write8(hl, value)
        default: a = value
        }
    }

    // MARK: Stepping

    /// Execute one instruction, or one idle cycle while halted.
    /// Peripheral time is advanced through the bus as a side effect.
    func step() {
        // HDMA stalls the CPU; charge those cycles before doing anything else.
        let stolen = bus.consumeStolenCycles()
        if stolen > 0 {
            bus.tick(stolen)
        }

        if serviceInterrupts() {
            return
        }

        if halted {
            // Nothing to do but let the rest of the machine run.
            internalCycle()
            return
        }

        if stopped {
            internalCycle()
            return
        }

        let opcode = fetch8()
        execute(opcode)

        if eiDelay > 0 {
            eiDelay -= 1
            if eiDelay == 0 { ime = true }
        }
    }

    /// Returns true if an interrupt was dispatched this step.
    private func serviceInterrupts() -> Bool {
        let pending = bus.interruptFlag & bus.interruptEnable & 0x1F

        if pending != 0 {
            // A pending interrupt wakes the CPU whether or not IME is set.
            halted = false
            stopped = false
        }

        guard ime, pending != 0 else { return false }

        ime = false

        // Two internal cycles, then the return address is pushed.
        internalCycle()
        internalCycle()
        push16(pc)

        // Re-check after the push: if it clobbered IE, the dispatch is
        // cancelled and control goes to 0x0000.
        let stillPending = bus.interruptFlag & bus.interruptEnable & 0x1F
        if stillPending == 0 {
            pc = 0x0000
        } else {
            let bit = stillPending.trailingZeroBitCount
            bus.interruptFlag &= ~(UInt8(1) << UInt8(bit))
            pc = UInt16(0x40 + bit * 8)
        }
        internalCycle()

        return true
    }

    // MARK: Decode

    private func execute(_ opcode: UInt8) {
        switch opcode {

        // MARK: 0x00-0x3F misc, 16-bit loads, INC/DEC

        case 0x00:  // NOP
            break

        case 0x10:  // STOP
            _ = fetch8()   // STOP is two bytes; the operand is ignored
            if !bus.performSpeedSwitch() {
                stopped = true
            }

        case 0x76:  // HALT
            let pending = bus.interruptFlag & bus.interruptEnable & 0x1F
            if !ime && pending != 0 {
                // The CPU fails to halt and the next byte is fetched twice.
                haltBug = true
            } else {
                halted = true
            }

        case 0xF3:  // DI
            ime = false
            eiDelay = 0

        case 0xFB:  // EI
            eiDelay = 2

        // LD rr,nn
        case 0x01: bc = fetch16()
        case 0x11: de = fetch16()
        case 0x21: hl = fetch16()
        case 0x31: sp = fetch16()

        // LD (rr),A  /  LD A,(rr)
        case 0x02: write8(bc, a)
        case 0x12: write8(de, a)
        case 0x22: write8(hl, a); hl &+= 1
        case 0x32: write8(hl, a); hl &-= 1
        case 0x0A: a = read8(bc)
        case 0x1A: a = read8(de)
        case 0x2A: a = read8(hl); hl &+= 1
        case 0x3A: a = read8(hl); hl &-= 1

        // INC/DEC rr — no flags, one extra internal cycle
        case 0x03: bc &+= 1; internalCycle()
        case 0x13: de &+= 1; internalCycle()
        case 0x23: hl &+= 1; internalCycle()
        case 0x33: sp &+= 1; internalCycle()
        case 0x0B: bc &-= 1; internalCycle()
        case 0x1B: de &-= 1; internalCycle()
        case 0x2B: hl &-= 1; internalCycle()
        case 0x3B: sp &-= 1; internalCycle()

        // INC r
        case 0x04, 0x0C, 0x14, 0x1C, 0x24, 0x2C, 0x34, 0x3C:
            let index = Int(opcode >> 3) & 0x07
            let value = readOperand(index)
            let result = value &+ 1
            zFlag = result == 0
            nFlag = false
            hFlag = (value & 0x0F) == 0x0F
            writeOperand(index, result)

        // DEC r
        case 0x05, 0x0D, 0x15, 0x1D, 0x25, 0x2D, 0x35, 0x3D:
            let index = Int(opcode >> 3) & 0x07
            let value = readOperand(index)
            let result = value &- 1
            zFlag = result == 0
            nFlag = true
            hFlag = (value & 0x0F) == 0x00
            writeOperand(index, result)

        // LD r,n
        case 0x06, 0x0E, 0x16, 0x1E, 0x26, 0x2E, 0x36, 0x3E:
            let index = Int(opcode >> 3) & 0x07
            let value = fetch8()
            writeOperand(index, value)

        // ADD HL,rr
        case 0x09: addToHL(bc)
        case 0x19: addToHL(de)
        case 0x29: addToHL(hl)
        case 0x39: addToHL(sp)

        // Accumulator rotates. Unlike their CB equivalents these always clear Z.
        case 0x07:  // RLCA
            let carry = a & 0x80 != 0
            a = a << 1 | (carry ? 1 : 0)
            setFlags(z: false, n: false, h: false, c: carry)
        case 0x0F:  // RRCA
            let carry = a & 0x01 != 0
            a = a >> 1 | (carry ? 0x80 : 0)
            setFlags(z: false, n: false, h: false, c: carry)
        case 0x17:  // RLA
            let carry = a & 0x80 != 0
            a = a << 1 | (cFlag ? 1 : 0)
            setFlags(z: false, n: false, h: false, c: carry)
        case 0x1F:  // RRA
            let carry = a & 0x01 != 0
            a = a >> 1 | (cFlag ? 0x80 : 0)
            setFlags(z: false, n: false, h: false, c: carry)

        case 0x27:  // DAA
            daa()

        case 0x2F:  // CPL
            a = ~a
            nFlag = true
            hFlag = true

        case 0x37:  // SCF
            nFlag = false; hFlag = false; cFlag = true

        case 0x3F:  // CCF
            nFlag = false; hFlag = false; cFlag = !cFlag

        case 0x08:  // LD (nn),SP
            let addr = fetch16()
            write8(addr, UInt8(sp & 0xFF))
            write8(addr &+ 1, UInt8(sp >> 8))

        // MARK: Jumps

        case 0x18:  // JR e
            let offset = Int8(bitPattern: fetch8())
            internalCycle()
            pc = UInt16(bitPattern: Int16(bitPattern: pc) &+ Int16(offset))

        case 0x20, 0x28, 0x30, 0x38:  // JR cc,e
            let offset = Int8(bitPattern: fetch8())
            if testCondition(Int(opcode >> 3) & 0x03) {
                internalCycle()
                pc = UInt16(bitPattern: Int16(bitPattern: pc) &+ Int16(offset))
            }

        case 0xC3:  // JP nn
            let addr = fetch16()
            internalCycle()
            pc = addr

        case 0xC2, 0xCA, 0xD2, 0xDA:  // JP cc,nn
            let addr = fetch16()
            if testCondition(Int(opcode >> 3) & 0x03) {
                internalCycle()
                pc = addr
            }

        case 0xE9:  // JP (HL) — no internal cycle, this one is 4 T-states
            pc = hl

        case 0xCD:  // CALL nn
            let addr = fetch16()
            internalCycle()
            push16(pc)
            pc = addr

        case 0xC4, 0xCC, 0xD4, 0xDC:  // CALL cc,nn
            let addr = fetch16()
            if testCondition(Int(opcode >> 3) & 0x03) {
                internalCycle()
                push16(pc)
                pc = addr
            }

        case 0xC9:  // RET
            pc = pop16()
            internalCycle()

        case 0xC0, 0xC8, 0xD0, 0xD8:  // RET cc
            internalCycle()   // the condition test itself costs a cycle
            if testCondition(Int(opcode >> 3) & 0x03) {
                pc = pop16()
                internalCycle()
            }

        case 0xD9:  // RETI
            pc = pop16()
            internalCycle()
            ime = true

        case 0xC7, 0xCF, 0xD7, 0xDF, 0xE7, 0xEF, 0xF7, 0xFF:  // RST
            internalCycle()
            push16(pc)
            pc = UInt16(opcode & 0x38)

        // MARK: Stack

        case 0xC1: bc = pop16()
        case 0xD1: de = pop16()
        case 0xE1: hl = pop16()
        case 0xF1: af = pop16()

        case 0xC5: internalCycle(); push16(bc)
        case 0xD5: internalCycle(); push16(de)
        case 0xE5: internalCycle(); push16(hl)
        case 0xF5: internalCycle(); push16(af)

        case 0xE8:  // ADD SP,e
            let offset = fetch8()
            internalCycle()
            internalCycle()
            sp = addSigned(sp, offset)

        case 0xF8:  // LD HL,SP+e
            let offset = fetch8()
            internalCycle()
            hl = addSigned(sp, offset)

        case 0xF9:  // LD SP,HL
            sp = hl
            internalCycle()

        // MARK: 8-bit loads and high RAM

        case 0xE0:  // LDH (n),A
            let offset = fetch8()
            write8(0xFF00 | UInt16(offset), a)
        case 0xF0:  // LDH A,(n)
            let offset = fetch8()
            a = read8(0xFF00 | UInt16(offset))
        case 0xE2:  // LDH (C),A
            write8(0xFF00 | UInt16(c), a)
        case 0xF2:  // LDH A,(C)
            a = read8(0xFF00 | UInt16(c))
        case 0xEA:  // LD (nn),A
            let addr = fetch16()
            write8(addr, a)
        case 0xFA:  // LD A,(nn)
            let addr = fetch16()
            a = read8(addr)

        // LD r,r' — the whole 0x40-0x7F block bar HALT, handled above.
        case 0x40...0x7F:
            let dest = Int(opcode >> 3) & 0x07
            let src = Int(opcode) & 0x07
            writeOperand(dest, readOperand(src))

        // MARK: ALU

        case 0x80...0xBF:
            let op = Int(opcode >> 3) & 0x07
            let value = readOperand(Int(opcode) & 0x07)
            alu(op, value)

        case 0xC6: alu(0, fetch8())   // ADD n
        case 0xCE: alu(1, fetch8())   // ADC n
        case 0xD6: alu(2, fetch8())   // SUB n
        case 0xDE: alu(3, fetch8())   // SBC n
        case 0xE6: alu(4, fetch8())   // AND n
        case 0xEE: alu(5, fetch8())   // XOR n
        case 0xF6: alu(6, fetch8())   // OR  n
        case 0xFE: alu(7, fetch8())   // CP  n

        case 0xCB:
            executeCB(fetch8())

        // MARK: Unmapped
        //
        // These opcodes do not decode to anything on real hardware and lock the
        // CPU up. Halting here makes a runaway ROM obvious rather than letting
        // it execute garbage.
        case 0xD3, 0xDB, 0xDD, 0xE3, 0xE4, 0xEB, 0xEC, 0xED, 0xF4, 0xFC, 0xFD:
            stopped = true

        default:
            break
        }
    }

    // MARK: CB-prefixed

    private func executeCB(_ opcode: UInt8) {
        let index = Int(opcode) & 0x07
        let bit = Int(opcode >> 3) & 0x07

        switch opcode {
        case 0x00...0x3F:
            let value = readOperand(index)
            let result: UInt8
            switch bit {
            case 0:  // RLC
                let carry = value & 0x80 != 0
                result = value << 1 | (carry ? 1 : 0)
                setFlags(z: result == 0, n: false, h: false, c: carry)
            case 1:  // RRC
                let carry = value & 0x01 != 0
                result = value >> 1 | (carry ? 0x80 : 0)
                setFlags(z: result == 0, n: false, h: false, c: carry)
            case 2:  // RL
                let carry = value & 0x80 != 0
                result = value << 1 | (cFlag ? 1 : 0)
                setFlags(z: result == 0, n: false, h: false, c: carry)
            case 3:  // RR
                let carry = value & 0x01 != 0
                result = value >> 1 | (cFlag ? 0x80 : 0)
                setFlags(z: result == 0, n: false, h: false, c: carry)
            case 4:  // SLA
                let carry = value & 0x80 != 0
                result = value << 1
                setFlags(z: result == 0, n: false, h: false, c: carry)
            case 5:  // SRA — arithmetic, bit 7 is preserved
                let carry = value & 0x01 != 0
                result = (value >> 1) | (value & 0x80)
                setFlags(z: result == 0, n: false, h: false, c: carry)
            case 6:  // SWAP
                result = value << 4 | value >> 4
                setFlags(z: result == 0, n: false, h: false, c: false)
            default: // SRL — logical, bit 7 clears
                let carry = value & 0x01 != 0
                result = value >> 1
                setFlags(z: result == 0, n: false, h: false, c: carry)
            }
            writeOperand(index, result)

        case 0x40...0x7F:  // BIT b,r — reads only, carry untouched
            let value = readOperand(index)
            zFlag = (value & (1 << UInt8(bit))) == 0
            nFlag = false
            hFlag = true

        case 0x80...0xBF:  // RES b,r
            let value = readOperand(index)
            writeOperand(index, value & ~(1 << UInt8(bit)))

        default:           // SET b,r
            let value = readOperand(index)
            writeOperand(index, value | (1 << UInt8(bit)))
        }
    }

    // MARK: ALU helpers

    /// 0=ADD 1=ADC 2=SUB 3=SBC 4=AND 5=XOR 6=OR 7=CP
    private func alu(_ op: Int, _ value: UInt8) {
        switch op {
        case 0:
            let result = UInt16(a) + UInt16(value)
            setFlags(z: UInt8(result & 0xFF) == 0, n: false,
                     h: (a & 0x0F) + (value & 0x0F) > 0x0F,
                     c: result > 0xFF)
            a = UInt8(result & 0xFF)
        case 1:
            let carry: UInt16 = cFlag ? 1 : 0
            let result = UInt16(a) + UInt16(value) + carry
            setFlags(z: UInt8(result & 0xFF) == 0, n: false,
                     h: UInt16(a & 0x0F) + UInt16(value & 0x0F) + carry > 0x0F,
                     c: result > 0xFF)
            a = UInt8(result & 0xFF)
        case 2:
            setFlags(z: a == value, n: true,
                     h: (a & 0x0F) < (value & 0x0F),
                     c: a < value)
            a = a &- value
        case 3:
            let carry: UInt16 = cFlag ? 1 : 0
            let result = Int(a) - Int(value) - Int(carry)
            setFlags(z: UInt8(result & 0xFF) == 0, n: true,
                     h: Int(a & 0x0F) - Int(value & 0x0F) - Int(carry) < 0,
                     c: result < 0)
            a = UInt8(result & 0xFF)
        case 4:
            a &= value
            setFlags(z: a == 0, n: false, h: true, c: false)
        case 5:
            a ^= value
            setFlags(z: a == 0, n: false, h: false, c: false)
        case 6:
            a |= value
            setFlags(z: a == 0, n: false, h: false, c: false)
        default:
            // CP is SUB with the result thrown away.
            setFlags(z: a == value, n: true,
                     h: (a & 0x0F) < (value & 0x0F),
                     c: a < value)
        }
    }

    private func addToHL(_ value: UInt16) {
        let result = UInt32(hl) + UInt32(value)
        // Z is left alone by this instruction.
        nFlag = false
        hFlag = (hl & 0x0FFF) + (value & 0x0FFF) > 0x0FFF
        cFlag = result > 0xFFFF
        hl = UInt16(result & 0xFFFF)
        internalCycle()
    }

    /// SP + signed offset. Half-carry and carry come from the *low byte*,
    /// which is why this sets flags so differently from ADD HL,rr.
    private func addSigned(_ base: UInt16, _ offset: UInt8) -> UInt16 {
        let signed = Int16(Int8(bitPattern: offset))
        setFlags(z: false, n: false,
                 h: (base & 0x0F) + (UInt16(offset) & 0x0F) > 0x0F,
                 c: (base & 0xFF) + UInt16(offset) > 0xFF)
        return UInt16(bitPattern: Int16(bitPattern: base) &+ signed)
    }

    /// Adjust A back into packed BCD after an add or subtract.
    private func daa() {
        var value = a
        var carry = cFlag

        if !nFlag {
            if carry || value > 0x99 {
                value = value &+ 0x60
                carry = true
            }
            if hFlag || (value & 0x0F) > 0x09 {
                value = value &+ 0x06
            }
        } else {
            if carry { value = value &- 0x60 }
            if hFlag { value = value &- 0x06 }
        }

        a = value
        zFlag = value == 0
        hFlag = false
        cFlag = carry
    }

    /// 0=NZ 1=Z 2=NC 3=C
    private func testCondition(_ code: Int) -> Bool {
        switch code {
        case 0: return !zFlag
        case 1: return zFlag
        case 2: return !cFlag
        default: return cFlag
        }
    }
}
