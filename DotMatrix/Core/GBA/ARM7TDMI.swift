import Foundation

/// Memory interface the CPU drives. Implemented by `GBABus`.
protocol ARMBus: AnyObject {
    func read8(_ address: UInt32, sequential: Bool) -> UInt8
    func read16(_ address: UInt32, sequential: Bool) -> UInt16
    func read32(_ address: UInt32, sequential: Bool) -> UInt32

    func write8(_ address: UInt32, _ value: UInt8, sequential: Bool)
    func write16(_ address: UInt32, _ value: UInt16, sequential: Bool)
    func write32(_ address: UInt32, _ value: UInt32, sequential: Bool)

    /// Burn internal cycles that aren't memory accesses.
    func idle(_ cycles: Int)

    /// True while an enabled, unmasked interrupt is asserted.
    var irqPending: Bool { get }

    /// Handle a BIOS software interrupt without the real BIOS image.
    /// Returns false if the call should fall through to a real BIOS vector.
    func handleSWI(comment: UInt32, cpu: ARM7TDMI) -> Bool

    /// An interrupt is being dispatched. Lets the bus track the BIOS state that
    /// games can observe by reading the BIOS region.
    func noteInterruptDispatch()
}

/// Processor operating modes. The low five bits of CPSR.
enum CPUMode: UInt32 {
    case user       = 0x10
    case fiq        = 0x11
    case irq        = 0x12
    case supervisor = 0x13
    case abort      = 0x17
    case undefined  = 0x1B
    case system     = 0x1F

    /// Which register bank this mode uses. User and System share one.
    var bankIndex: Int {
        switch self {
        case .user, .system: return 0
        case .fiq:           return 1
        case .irq:           return 2
        case .supervisor:    return 3
        case .abort:         return 4
        case .undefined:     return 5
        }
    }

    /// User and System have no SPSR to save the caller's CPSR into.
    var hasSPSR: Bool {
        switch self {
        case .user, .system: return false
        default: return true
        }
    }
}

/// The ARM7TDMI core: ARMv4T, so both the 32-bit ARM and 16-bit Thumb
/// instruction sets.
///
/// The pipeline is modelled by convention rather than simulated: `pc` always
/// holds the address of the instruction being executed, and any read of R15
/// adds the pipeline offset the hardware would have already applied. That keeps
/// PC-relative addressing correct without carrying a fetch queue around.
final class ARM7TDMI {
    // MARK: Register file

    /// The 16 currently visible registers. R15 is the program counter.
    var registers = [UInt32](repeating: 0, count: 16)

    /// Banked R13/R14, indexed by `CPUMode.bankIndex`.
    private var bankedSP = [UInt32](repeating: 0, count: 6)
    private var bankedLR = [UInt32](repeating: 0, count: 6)
    /// FIQ additionally banks R8-R12.
    private var bankedFIQ = [UInt32](repeating: 0, count: 5)
    /// Saved user-mode R8-R12, parked while in FIQ.
    private var savedUserR8R12 = [UInt32](repeating: 0, count: 5)
    /// SPSR per bank; index 0 is unused.
    private var bankedSPSR = [UInt32](repeating: 0, count: 6)

    // MARK: Status

    private(set) var mode: CPUMode = .system
    var spsr: UInt32 {
        get { mode.hasSPSR ? bankedSPSR[mode.bankIndex] : cpsr }
        set { if mode.hasSPSR { bankedSPSR[mode.bankIndex] = newValue } }
    }

    var negative = false
    var zero = false
    var carry = false
    var overflow = false

    var irqDisabled = true
    var fiqDisabled = true
    var thumb = false

    /// Packed CPSR, assembled on demand.
    var cpsr: UInt32 {
        get {
            var value: UInt32 = mode.rawValue
            if negative { value |= 1 << 31 }
            if zero     { value |= 1 << 30 }
            if carry    { value |= 1 << 29 }
            if overflow { value |= 1 << 28 }
            if irqDisabled { value |= 1 << 7 }
            if fiqDisabled { value |= 1 << 6 }
            if thumb       { value |= 1 << 5 }
            return value
        }
        set {
            negative = newValue & (1 << 31) != 0
            zero     = newValue & (1 << 30) != 0
            carry    = newValue & (1 << 29) != 0
            overflow = newValue & (1 << 28) != 0
            irqDisabled = newValue & (1 << 7) != 0
            fiqDisabled = newValue & (1 << 6) != 0
            thumb       = newValue & (1 << 5) != 0
            if let newMode = CPUMode(rawValue: newValue & 0x1F) {
                switchMode(to: newMode)
            }
        }
    }

    /// Program counter — the address of the instruction being executed.
    var pc: UInt32 {
        get { registers[15] }
        set { registers[15] = newValue }
    }

    /// Set by any instruction that writes R15, so `step` doesn't advance past it.
    var branched = false

    /// Set while the CPU is parked in a low-power state awaiting an interrupt.
    var halted = false

    let bus: ARMBus

    /// True when the next instruction fetch follows the previous one in memory,
    /// which the wait-state logic charges less for.
    private var nextFetchSequential = false

    init(bus: ARMBus) {
        self.bus = bus
    }

    // MARK: Register access with pipeline offset

    /// Read a register as an instruction operand. R15 reads ahead by the
    /// pipeline depth: two instructions, so +8 in ARM and +4 in Thumb.
    @inline(__always)
    func readRegister(_ index: Int) -> UInt32 {
        index == 15 ? pc &+ (thumb ? 4 : 8) : registers[index]
    }

    @inline(__always)
    func writeRegister(_ index: Int, _ value: UInt32) {
        if index == 15 {
            // Writing PC flushes the pipeline; alignment is forced by the
            // current instruction width.
            pc = thumb ? (value & ~1) : (value & ~3)
            branched = true
        } else {
            registers[index] = value
        }
    }

    // MARK: Mode switching

    func switchMode(to newMode: CPUMode) {
        guard newMode != mode else { return }

        let oldBank = mode.bankIndex
        let newBank = newMode.bankIndex

        // Park the outgoing mode's stack and link registers.
        bankedSP[oldBank] = registers[13]
        bankedLR[oldBank] = registers[14]

        // FIQ swaps R8-R12 as well.
        if mode == .fiq && newMode != .fiq {
            for i in 0..<5 {
                bankedFIQ[i] = registers[8 + i]
                registers[8 + i] = savedUserR8R12[i]
            }
        } else if mode != .fiq && newMode == .fiq {
            for i in 0..<5 {
                savedUserR8R12[i] = registers[8 + i]
                registers[8 + i] = bankedFIQ[i]
            }
        }

        registers[13] = bankedSP[newBank]
        registers[14] = bankedLR[newBank]
        mode = newMode
    }

    // MARK: Exceptions

    /// Vector addresses, indexed the same way the hardware lays them out.
    private enum Vector: UInt32 {
        case reset          = 0x00
        case undefined      = 0x04
        case softwareInterrupt = 0x08
        case prefetchAbort  = 0x0C
        case dataAbort      = 0x10
        case irq            = 0x18
        case fiq            = 0x1C
    }

    private func enterException(_ vector: Vector, mode newMode: CPUMode, returnOffset: UInt32) {
        let savedCPSR = cpsr
        // The return address is expressed relative to the *next* instruction,
        // which differs per exception type.
        let returnAddress = pc &+ returnOffset

        switchMode(to: newMode)
        bankedSPSR[newMode.bankIndex] = savedCPSR
        registers[14] = returnAddress

        thumb = false
        irqDisabled = true
        if newMode == .fiq { fiqDisabled = true }

        pc = vector.rawValue
        branched = true
        nextFetchSequential = false
    }

    func raiseUndefined() {
        enterException(.undefined, mode: .undefined, returnOffset: thumb ? 2 : 4)
    }

    func raiseSWI() {
        enterException(.softwareInterrupt, mode: .supervisor, returnOffset: thumb ? 2 : 4)
    }

    private func raiseIRQ() {
        bus.noteInterruptDispatch()
        // IRQ returns to the instruction after the interrupted one, plus the
        // pipeline offset the hardware would have had in LR.
        enterException(.irq, mode: .irq, returnOffset: thumb ? 4 : 4)
    }

    // MARK: Condition codes

    /// Evaluate the 4-bit condition field carried by every ARM instruction.
    @inline(__always)
    func evaluateCondition(_ code: UInt32) -> Bool {
        switch code {
        case 0x0: return zero                              // EQ
        case 0x1: return !zero                             // NE
        case 0x2: return carry                             // CS/HS
        case 0x3: return !carry                            // CC/LO
        case 0x4: return negative                          // MI
        case 0x5: return !negative                         // PL
        case 0x6: return overflow                          // VS
        case 0x7: return !overflow                         // VC
        case 0x8: return carry && !zero                    // HI
        case 0x9: return !carry || zero                    // LS
        case 0xA: return negative == overflow              // GE
        case 0xB: return negative != overflow              // LT
        case 0xC: return !zero && (negative == overflow)   // GT
        case 0xD: return zero || (negative != overflow)    // LE
        case 0xE: return true                              // AL
        default:  return false                             // NV — unpredictable
        }
    }

    // MARK: Barrel shifter

    /// Result of a shift, along with the carry it produced.
    struct ShiftResult {
        var value: UInt32
        var carry: Bool
    }

    /// Apply one of the four shift types.
    ///
    /// `byRegister` matters because a zero shift amount means something
    /// different depending on where it came from: an immediate 0 encodes a
    /// special case (RRX for ROR, 32 for LSR/ASR), whereas a register holding 0
    /// really is a no-op that leaves the carry alone.
    func applyShift(type: UInt32, amount: UInt32, value: UInt32,
                    byRegister: Bool, currentCarry: Bool) -> ShiftResult {
        if byRegister && amount == 0 {
            return ShiftResult(value: value, carry: currentCarry)
        }

        switch type {
        case 0:  // LSL
            if amount == 0 {
                return ShiftResult(value: value, carry: currentCarry)
            } else if amount < 32 {
                let carryOut = (value >> (32 - amount)) & 1 != 0
                return ShiftResult(value: value << amount, carry: carryOut)
            } else if amount == 32 {
                return ShiftResult(value: 0, carry: value & 1 != 0)
            } else {
                return ShiftResult(value: 0, carry: false)
            }

        case 1:  // LSR — an immediate 0 encodes a shift of 32
            let shift = (!byRegister && amount == 0) ? 32 : amount
            if shift == 0 {
                return ShiftResult(value: value, carry: currentCarry)
            } else if shift < 32 {
                let carryOut = (value >> (shift - 1)) & 1 != 0
                return ShiftResult(value: value >> shift, carry: carryOut)
            } else if shift == 32 {
                return ShiftResult(value: 0, carry: value & 0x8000_0000 != 0)
            } else {
                return ShiftResult(value: 0, carry: false)
            }

        case 2:  // ASR — an immediate 0 also encodes 32
            let shift = (!byRegister && amount == 0) ? 32 : amount
            let signed = Int32(bitPattern: value)
            if shift == 0 {
                return ShiftResult(value: value, carry: currentCarry)
            } else if shift < 32 {
                let carryOut = (value >> (shift - 1)) & 1 != 0
                return ShiftResult(value: UInt32(bitPattern: signed >> Int32(shift)), carry: carryOut)
            } else {
                // Everything shifts out; the result is all sign bits.
                let sign = value & 0x8000_0000 != 0
                return ShiftResult(value: sign ? 0xFFFF_FFFF : 0, carry: sign)
            }

        default: // ROR — an immediate 0 encodes RRX, a 33-bit rotate through carry
            if !byRegister && amount == 0 {
                let result = (value >> 1) | (currentCarry ? 0x8000_0000 : 0)
                return ShiftResult(value: result, carry: value & 1 != 0)
            }
            let rotation = amount & 31
            if rotation == 0 {
                // A multiple of 32 leaves the value alone but still sets carry
                // from the top bit.
                return ShiftResult(value: value, carry: value & 0x8000_0000 != 0)
            }
            let result = (value >> rotation) | (value << (32 - rotation))
            return ShiftResult(value: result, carry: (value >> (rotation - 1)) & 1 != 0)
        }
    }

    // MARK: Flag helpers

    @inline(__always)
    func setLogicalFlags(_ result: UInt32, carryOut: Bool) {
        negative = result & 0x8000_0000 != 0
        zero = result == 0
        carry = carryOut
    }

    @inline(__always)
    func setAddFlags(result: UInt32, lhs: UInt32, rhs: UInt32, carryIn: UInt32 = 0) {
        negative = result & 0x8000_0000 != 0
        zero = result == 0
        // Carry out of bit 31, computed in 64 bits to avoid the wrap.
        carry = (UInt64(lhs) + UInt64(rhs) + UInt64(carryIn)) > 0xFFFF_FFFF
        // Overflow when both operands share a sign that the result contradicts.
        overflow = ((lhs ^ result) & (rhs ^ result) & 0x8000_0000) != 0
    }

    @inline(__always)
    func setSubFlags(result: UInt32, lhs: UInt32, rhs: UInt32, borrowIn: UInt32 = 1) {
        negative = result & 0x8000_0000 != 0
        zero = result == 0
        carry = (UInt64(lhs) + UInt64(~rhs) + UInt64(borrowIn)) > 0xFFFF_FFFF
        // Overflow when the operands differ in sign and the result follows the
        // subtrahend rather than the minuend.
        overflow = ((lhs ^ rhs) & (lhs ^ result) & 0x8000_0000) != 0
    }

    // MARK: Stepping

    /// Execute one instruction. Cycle accounting happens inside the bus.
    func step() {
        // An asserted interrupt both wakes the CPU and, if unmasked, vectors.
        if bus.irqPending {
            halted = false
            if !irqDisabled {
                raiseIRQ()
                return
            }
        }

        if halted {
            // Let timers, DMA and the PPU advance while the CPU idles.
            bus.idle(1)
            return
        }

        branched = false

        if thumb {
            let instruction = bus.read16(pc, sequential: nextFetchSequential)
            executeThumb(instruction)
            if !branched {
                pc &+= 2
                nextFetchSequential = true
            } else {
                nextFetchSequential = false
            }
        } else {
            let instruction = bus.read32(pc, sequential: nextFetchSequential)
            executeARM(instruction)
            if !branched {
                pc &+= 4
                nextFetchSequential = true
            } else {
                nextFetchSequential = false
            }
        }
    }

    /// Jump, selecting instruction set from the low bit of the target — the
    /// mechanism behind BX and every Thumb/ARM interworking return.
    func branchAndExchange(to address: UInt32) {
        thumb = address & 1 != 0
        pc = thumb ? (address & ~1) : (address & ~3)
        branched = true
    }

    /// Reset into the state the BIOS hands over in, so no BIOS image is needed.
    func reset(entryPoint: UInt32) {
        registers = [UInt32](repeating: 0, count: 16)
        bankedSP = [UInt32](repeating: 0, count: 6)
        bankedLR = [UInt32](repeating: 0, count: 6)
        bankedSPSR = [UInt32](repeating: 0, count: 6)

        // Stack pointers the real BIOS installs before jumping to the ROM.
        bankedSP[CPUMode.supervisor.bankIndex] = 0x0300_7FE0
        bankedSP[CPUMode.irq.bankIndex] = 0x0300_7FA0
        bankedSP[CPUMode.user.bankIndex] = 0x0300_7F00

        mode = .system
        registers[13] = bankedSP[CPUMode.user.bankIndex]

        thumb = false
        irqDisabled = false
        fiqDisabled = true
        negative = false; zero = false; carry = false; overflow = false
        halted = false

        pc = entryPoint
        branched = true
        nextFetchSequential = false
    }
}
