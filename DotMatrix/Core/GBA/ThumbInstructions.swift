import Foundation

/// The 16-bit Thumb instruction set.
///
/// Thumb trades the conditional-execution field and flexible operands of ARM
/// for half the code size, so nearly all GBA game code is compiled to it and
/// only performance-critical or mode-switching routines stay in ARM. Almost
/// every data-processing form here sets the flags unconditionally — there is no
/// S bit to opt out with.
extension ARM7TDMI {

    func executeThumb(_ instruction: UInt16) {
        switch instruction >> 12 {
        case 0b0000, 0b0001:
            // Either a shift by immediate or a three-operand add/subtract.
            if (instruction >> 11) & 0x3 == 0b11 {
                thumbAddSubtract(instruction)
            } else {
                thumbMoveShifted(instruction)
            }

        case 0b0010, 0b0011:
            thumbImmediateOperation(instruction)

        case 0b0100:
            if (instruction >> 11) & 0x1 == 1 {
                thumbPCRelativeLoad(instruction)
            } else if (instruction >> 10) & 0x3 == 0b01 {
                thumbHighRegisterOperation(instruction)
            } else {
                thumbALUOperation(instruction)
            }

        case 0b0101:
            // Bit 9 separates the plain loads from the sign-extending ones.
            if instruction & (1 << 9) != 0 {
                thumbLoadStoreSignExtended(instruction)
            } else {
                thumbLoadStoreRegisterOffset(instruction)
            }

        case 0b0110, 0b0111:
            thumbLoadStoreImmediateOffset(instruction)

        case 0b1000:
            thumbLoadStoreHalfword(instruction)

        case 0b1001:
            thumbStackRelativeLoadStore(instruction)

        case 0b1010:
            thumbLoadAddress(instruction)

        case 0b1011:
            if (instruction >> 8) & 0xF == 0b0000 {
                thumbAdjustStackPointer(instruction)
            } else {
                thumbPushPop(instruction)
            }

        case 0b1100:
            thumbBlockTransfer(instruction)

        case 0b1101:
            let condition = (instruction >> 8) & 0xF
            if condition == 0xF {
                thumbSoftwareInterrupt(instruction)
            } else if condition == 0xE {
                // Undefined in Thumb; there is no "never" conditional branch.
                raiseUndefined()
            } else {
                thumbConditionalBranch(instruction, condition: UInt32(condition))
            }

        case 0b1110:
            thumbUnconditionalBranch(instruction)

        default:
            thumbLongBranchWithLink(instruction)
        }
    }

    // MARK: Format 1 — move shifted register

    private func thumbMoveShifted(_ instruction: UInt16) {
        let shiftType = UInt32((instruction >> 11) & 0x3)
        let amount = UInt32((instruction >> 6) & 0x1F)
        let rs = Int((instruction >> 3) & 0x7)
        let rd = Int(instruction & 0x7)

        let shifted = applyShift(type: shiftType, amount: amount, value: registers[rs],
                                 byRegister: false, currentCarry: carry)
        registers[rd] = shifted.value
        setLogicalFlags(shifted.value, carryOut: shifted.carry)
    }

    // MARK: Format 2 — add/subtract

    private func thumbAddSubtract(_ instruction: UInt16) {
        let isImmediate = instruction & (1 << 10) != 0
        let isSubtract = instruction & (1 << 9) != 0
        let operandField = UInt32((instruction >> 6) & 0x7)
        let rs = Int((instruction >> 3) & 0x7)
        let rd = Int(instruction & 0x7)

        let lhs = registers[rs]
        let rhs = isImmediate ? operandField : registers[Int(operandField)]

        let result: UInt32
        if isSubtract {
            result = lhs &- rhs
            setSubFlags(result: result, lhs: lhs, rhs: rhs)
        } else {
            result = lhs &+ rhs
            setAddFlags(result: result, lhs: lhs, rhs: rhs)
        }
        registers[rd] = result
    }

    // MARK: Format 3 — immediate operations

    private func thumbImmediateOperation(_ instruction: UInt16) {
        let operation = (instruction >> 11) & 0x3
        let rd = Int((instruction >> 8) & 0x7)
        let immediate = UInt32(instruction & 0xFF)

        switch operation {
        case 0b00:  // MOV
            registers[rd] = immediate
            negative = false
            zero = immediate == 0
        case 0b01:  // CMP
            let result = registers[rd] &- immediate
            setSubFlags(result: result, lhs: registers[rd], rhs: immediate)
        case 0b10:  // ADD
            let lhs = registers[rd]
            let result = lhs &+ immediate
            setAddFlags(result: result, lhs: lhs, rhs: immediate)
            registers[rd] = result
        default:    // SUB
            let lhs = registers[rd]
            let result = lhs &- immediate
            setSubFlags(result: result, lhs: lhs, rhs: immediate)
            registers[rd] = result
        }
    }

    // MARK: Format 4 — ALU operations

    private func thumbALUOperation(_ instruction: UInt16) {
        let operation = (instruction >> 6) & 0xF
        let rs = Int((instruction >> 3) & 0x7)
        let rd = Int(instruction & 0x7)

        let lhs = registers[rd]
        let rhs = registers[rs]

        switch operation {
        case 0x0:  // AND
            let result = lhs & rhs
            registers[rd] = result
            setLogicalFlags(result, carryOut: carry)
        case 0x1:  // EOR
            let result = lhs ^ rhs
            registers[rd] = result
            setLogicalFlags(result, carryOut: carry)
        case 0x2, 0x3, 0x4, 0x7:  // LSL, LSR, ASR, ROR by register
            let shiftType: UInt32
            switch operation {
            case 0x2: shiftType = 0
            case 0x3: shiftType = 1
            case 0x4: shiftType = 2
            default:  shiftType = 3
            }
            bus.idle(1)
            let shifted = applyShift(type: shiftType, amount: rhs & 0xFF, value: lhs,
                                     byRegister: true, currentCarry: carry)
            registers[rd] = shifted.value
            setLogicalFlags(shifted.value, carryOut: shifted.carry)
        case 0x5:  // ADC
            let carryIn: UInt32 = carry ? 1 : 0
            let result = lhs &+ rhs &+ carryIn
            setAddFlags(result: result, lhs: lhs, rhs: rhs, carryIn: carryIn)
            registers[rd] = result
        case 0x6:  // SBC
            let borrowIn: UInt32 = carry ? 1 : 0
            let result = lhs &- rhs &- (1 &- borrowIn)
            setSubFlags(result: result, lhs: lhs, rhs: rhs, borrowIn: borrowIn)
            registers[rd] = result
        case 0x8:  // TST
            let result = lhs & rhs
            setLogicalFlags(result, carryOut: carry)
        case 0x9:  // NEG — subtract from zero
            let result = 0 &- rhs
            setSubFlags(result: result, lhs: 0, rhs: rhs)
            registers[rd] = result
        case 0xA:  // CMP
            let result = lhs &- rhs
            setSubFlags(result: result, lhs: lhs, rhs: rhs)
        case 0xB:  // CMN
            let result = lhs &+ rhs
            setAddFlags(result: result, lhs: lhs, rhs: rhs)
        case 0xC:  // ORR
            let result = lhs | rhs
            registers[rd] = result
            setLogicalFlags(result, carryOut: carry)
        case 0xD:  // MUL
            let result = lhs &* rhs
            registers[rd] = result
            negative = result & 0x8000_0000 != 0
            zero = result == 0
            bus.idle(2)
        case 0xE:  // BIC
            let result = lhs & ~rhs
            registers[rd] = result
            setLogicalFlags(result, carryOut: carry)
        default:   // MVN
            let result = ~rhs
            registers[rd] = result
            setLogicalFlags(result, carryOut: carry)
        }
    }

    // MARK: Format 5 — high register operations and BX

    private func thumbHighRegisterOperation(_ instruction: UInt16) {
        let operation = (instruction >> 8) & 0x3
        // The H bits extend the 3-bit register fields to reach R8-R15.
        let rs = Int(((instruction >> 3) & 0x7) | ((instruction >> 3) & 0x8))
        let rd = Int((instruction & 0x7) | ((instruction >> 4) & 0x8))

        switch operation {
        case 0b00:  // ADD — does not set flags
            let result = readRegister(rd) &+ readRegister(rs)
            writeRegister(rd, result)
        case 0b01:  // CMP — the only one here that does
            let lhs = readRegister(rd)
            let rhs = readRegister(rs)
            let result = lhs &- rhs
            setSubFlags(result: result, lhs: lhs, rhs: rhs)
        case 0b10:  // MOV — also silent
            writeRegister(rd, readRegister(rs))
        default:    // BX — the standard route back into ARM code
            branchAndExchange(to: readRegister(rs))
        }
    }

    // MARK: Format 6 — PC-relative load

    private func thumbPCRelativeLoad(_ instruction: UInt16) {
        let rd = Int((instruction >> 8) & 0x7)
        let offset = UInt32(instruction & 0xFF) * 4
        // The literal pool is word-aligned, so bit 1 of PC is forced clear.
        let base = (pc &+ 4) & ~3
        registers[rd] = bus.read32(base &+ offset, sequential: false)
        bus.idle(1)
    }

    // MARK: Format 7 — load/store with register offset

    private func thumbLoadStoreRegisterOffset(_ instruction: UInt16) {
        let isLoad = instruction & (1 << 11) != 0
        let isByte = instruction & (1 << 10) != 0
        let ro = Int((instruction >> 6) & 0x7)
        let rb = Int((instruction >> 3) & 0x7)
        let rd = Int(instruction & 0x7)

        let address = registers[rb] &+ registers[ro]

        if isLoad {
            if isByte {
                registers[rd] = UInt32(bus.read8(address, sequential: false))
            } else {
                let word = bus.read32(address & ~3, sequential: false)
                let rotation = (address & 3) * 8
                registers[rd] = rotation == 0 ? word : (word >> rotation) | (word << (32 - rotation))
            }
            bus.idle(1)
        } else {
            if isByte {
                bus.write8(address, UInt8(registers[rd] & 0xFF), sequential: false)
            } else {
                bus.write32(address & ~3, registers[rd], sequential: false)
            }
        }
    }

    // MARK: Format 8 — sign-extended load/store

    private func thumbLoadStoreSignExtended(_ instruction: UInt16) {
        let hFlag = instruction & (1 << 11) != 0
        let signExtend = instruction & (1 << 10) != 0
        let ro = Int((instruction >> 6) & 0x7)
        let rb = Int((instruction >> 3) & 0x7)
        let rd = Int(instruction & 0x7)

        let address = registers[rb] &+ registers[ro]

        switch (signExtend, hFlag) {
        case (false, false):  // STRH
            bus.write16(address & ~1, UInt16(registers[rd] & 0xFFFF), sequential: false)
        case (false, true):   // LDRH
            let half = bus.read16(address & ~1, sequential: false)
            registers[rd] = (address & 1) != 0
                ? UInt32(half) >> 8 | UInt32(half) << 24
                : UInt32(half)
            bus.idle(1)
        case (true, false):   // LDRSB
            let byte = bus.read8(address, sequential: false)
            registers[rd] = UInt32(bitPattern: Int32(Int8(bitPattern: byte)))
            bus.idle(1)
        case (true, true):    // LDRSH — degrades to a signed byte if misaligned
            if address & 1 != 0 {
                let byte = bus.read8(address, sequential: false)
                registers[rd] = UInt32(bitPattern: Int32(Int8(bitPattern: byte)))
            } else {
                let half = bus.read16(address, sequential: false)
                registers[rd] = UInt32(bitPattern: Int32(Int16(bitPattern: half)))
            }
            bus.idle(1)
        }
    }

    // MARK: Format 9 — load/store with immediate offset

    private func thumbLoadStoreImmediateOffset(_ instruction: UInt16) {
        let isByte = instruction & (1 << 12) != 0
        let isLoad = instruction & (1 << 11) != 0
        let rawOffset = UInt32((instruction >> 6) & 0x1F)
        let rb = Int((instruction >> 3) & 0x7)
        let rd = Int(instruction & 0x7)

        // The offset is scaled by the access width.
        let address = registers[rb] &+ (isByte ? rawOffset : rawOffset * 4)

        if isLoad {
            if isByte {
                registers[rd] = UInt32(bus.read8(address, sequential: false))
            } else {
                let word = bus.read32(address & ~3, sequential: false)
                let rotation = (address & 3) * 8
                registers[rd] = rotation == 0 ? word : (word >> rotation) | (word << (32 - rotation))
            }
            bus.idle(1)
        } else {
            if isByte {
                bus.write8(address, UInt8(registers[rd] & 0xFF), sequential: false)
            } else {
                bus.write32(address & ~3, registers[rd], sequential: false)
            }
        }
    }

    // MARK: Format 10 — halfword load/store

    private func thumbLoadStoreHalfword(_ instruction: UInt16) {
        let isLoad = instruction & (1 << 11) != 0
        let offset = UInt32((instruction >> 6) & 0x1F) * 2
        let rb = Int((instruction >> 3) & 0x7)
        let rd = Int(instruction & 0x7)

        let address = registers[rb] &+ offset

        if isLoad {
            let half = bus.read16(address & ~1, sequential: false)
            registers[rd] = (address & 1) != 0
                ? UInt32(half) >> 8 | UInt32(half) << 24
                : UInt32(half)
            bus.idle(1)
        } else {
            bus.write16(address & ~1, UInt16(registers[rd] & 0xFFFF), sequential: false)
        }
    }

    // MARK: Format 11 — SP-relative load/store

    private func thumbStackRelativeLoadStore(_ instruction: UInt16) {
        let isLoad = instruction & (1 << 11) != 0
        let rd = Int((instruction >> 8) & 0x7)
        let offset = UInt32(instruction & 0xFF) * 4

        let address = registers[13] &+ offset

        if isLoad {
            let word = bus.read32(address & ~3, sequential: false)
            let rotation = (address & 3) * 8
            registers[rd] = rotation == 0 ? word : (word >> rotation) | (word << (32 - rotation))
            bus.idle(1)
        } else {
            bus.write32(address & ~3, registers[rd], sequential: false)
        }
    }

    // MARK: Format 12 — load address

    private func thumbLoadAddress(_ instruction: UInt16) {
        let useStackPointer = instruction & (1 << 11) != 0
        let rd = Int((instruction >> 8) & 0x7)
        let offset = UInt32(instruction & 0xFF) * 4

        if useStackPointer {
            registers[rd] = registers[13] &+ offset
        } else {
            // Same word-alignment rule as the PC-relative load.
            registers[rd] = ((pc &+ 4) & ~3) &+ offset
        }
    }

    // MARK: Format 13 — adjust stack pointer

    private func thumbAdjustStackPointer(_ instruction: UInt16) {
        let offset = UInt32(instruction & 0x7F) * 4
        if instruction & (1 << 7) != 0 {
            registers[13] = registers[13] &- offset
        } else {
            registers[13] = registers[13] &+ offset
        }
    }

    // MARK: Format 14 — push/pop

    private func thumbPushPop(_ instruction: UInt16) {
        let isPop = instruction & (1 << 11) != 0
        // The R bit adds LR to a push, or PC to a pop — the standard function
        // prologue and epilogue pair.
        let includeExtra = instruction & (1 << 8) != 0
        let list = UInt32(instruction & 0xFF)

        var transferred = (0..<8).filter { list & (1 << UInt32($0)) != 0 }

        if isPop {
            if includeExtra { transferred.append(15) }
            var address = registers[13]
            var sequential = false
            for register in transferred {
                let value = bus.read32(address & ~3, sequential: sequential)
                if register == 15 {
                    // A pop into PC can switch instruction set on ARMv4T only
                    // via the low bit, which is how Thumb functions return.
                    branchAndExchange(to: value)
                } else {
                    registers[register] = value
                }
                address = address &+ 4
                sequential = true
            }
            registers[13] = address
            bus.idle(1)
        } else {
            if includeExtra { transferred.append(14) }
            // Push descends: reserve the whole block, then fill upwards.
            var address = registers[13] &- UInt32(transferred.count) * 4
            registers[13] = address
            var sequential = false
            for register in transferred.sorted() {
                bus.write32(address & ~3, registers[register], sequential: sequential)
                address = address &+ 4
                sequential = true
            }
        }
    }

    // MARK: Format 15 — block transfer

    private func thumbBlockTransfer(_ instruction: UInt16) {
        let isLoad = instruction & (1 << 11) != 0
        let rb = Int((instruction >> 8) & 0x7)
        let list = UInt32(instruction & 0xFF)

        var address = registers[rb]

        // As in ARM, an empty list transfers PC and bumps the base by 0x40.
        if list == 0 {
            if isLoad {
                let value = bus.read32(address & ~3, sequential: false)
                pc = value & ~1
                branched = true
            } else {
                bus.write32(address & ~3, pc &+ 4, sequential: false)
            }
            registers[rb] = address &+ 0x40
            return
        }

        let transferred = (0..<8).filter { list & (1 << UInt32($0)) != 0 }
        let writeBackValue = address &+ UInt32(transferred.count) * 4

        var sequential = false
        for register in transferred {
            if isLoad {
                registers[register] = bus.read32(address & ~3, sequential: sequential)
            } else {
                // Storing the base writes back the final value unless the base
                // is the first register in the list.
                let value = (register == rb && transferred.first != rb)
                    ? writeBackValue
                    : registers[register]
                bus.write32(address & ~3, value, sequential: sequential)
            }
            address = address &+ 4
            sequential = true
        }

        // A load that included the base leaves the loaded value in place.
        if !(isLoad && list & (1 << UInt32(rb)) != 0) {
            registers[rb] = writeBackValue
        }

        if isLoad { bus.idle(1) }
    }

    // MARK: Format 16 — conditional branch

    private func thumbConditionalBranch(_ instruction: UInt16, condition: UInt32) {
        guard evaluateCondition(condition) else { return }
        let offset = Int32(Int8(bitPattern: UInt8(instruction & 0xFF))) * 2
        pc = UInt32(bitPattern: Int32(bitPattern: pc &+ 4) &+ offset)
        branched = true
    }

    // MARK: Format 17 — software interrupt

    private func thumbSoftwareInterrupt(_ instruction: UInt16) {
        let comment = UInt32(instruction & 0xFF)
        if !bus.handleSWI(comment: comment, cpu: self) {
            raiseSWI()
        }
    }

    // MARK: Format 18 — unconditional branch

    private func thumbUnconditionalBranch(_ instruction: UInt16) {
        // 11-bit signed offset, doubled.
        let raw = UInt32(instruction & 0x7FF)
        let signed = (raw & 0x400) != 0
            ? Int32(bitPattern: raw | 0xFFFF_F800)
            : Int32(bitPattern: raw)
        pc = UInt32(bitPattern: Int32(bitPattern: pc &+ 4) &+ (signed << 1))
        branched = true
    }

    // MARK: Format 19 — long branch with link

    /// BL is encoded as a pair of instructions so that a 22-bit displacement
    /// fits into 16-bit opcodes: the first stages the high half into LR, the
    /// second adds the low half and swaps LR for the return address.
    private func thumbLongBranchWithLink(_ instruction: UInt16) {
        let raw = UInt32(instruction & 0x7FF)
        let isSecondHalf = instruction & (1 << 11) != 0

        if !isSecondHalf {
            let signed = (raw & 0x400) != 0
                ? Int32(bitPattern: raw | 0xFFFF_F800)
                : Int32(bitPattern: raw)
            registers[14] = UInt32(bitPattern: Int32(bitPattern: pc &+ 4) &+ (signed << 12))
        } else {
            let target = registers[14] &+ (raw << 1)
            // The return address keeps its low bit set to mark Thumb state.
            registers[14] = (pc &+ 2) | 1
            pc = target & ~1
            branched = true
        }
    }
}
