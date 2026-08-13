import Foundation

/// The 32-bit ARM instruction set.
///
/// Decoding is a two-level switch: bits 27-25 pick a broad class, then the
/// classes that overlap are separated by the extra bits that distinguish them.
/// Order matters — several encodings are carved out of the data-processing
/// space and have to be tested before falling through to it.
extension ARM7TDMI {

    func executeARM(_ instruction: UInt32) {
        let condition = instruction >> 28
        // 0xE is unconditional and by far the most common; skip the test.
        if condition != 0xE, !evaluateCondition(condition) {
            return
        }

        switch (instruction >> 25) & 0x7 {
        case 0b000:
            if (instruction & 0x0FFF_FFF0) == 0x012F_FF10 {
                armBranchExchange(instruction)
            } else if (instruction & 0x0FC0_00F0) == 0x0000_0090 {
                armMultiply(instruction)
            } else if (instruction & 0x0F80_00F0) == 0x0080_0090 {
                armMultiplyLong(instruction)
            } else if (instruction & 0x0FB0_0FF0) == 0x0100_0090 {
                armSwap(instruction)
            } else if (instruction & 0x0E00_0090) == 0x0000_0090 {
                armHalfwordTransfer(instruction)
            } else {
                armDataProcessing(instruction, immediateOperand: false)
            }

        case 0b001:
            armDataProcessing(instruction, immediateOperand: true)

        case 0b010:
            armSingleDataTransfer(instruction, registerOffset: false)

        case 0b011:
            // Bit 4 set in this space is the architecturally undefined encoding.
            if instruction & 0x10 != 0 {
                raiseUndefined()
            } else {
                armSingleDataTransfer(instruction, registerOffset: true)
            }

        case 0b100:
            armBlockTransfer(instruction)

        case 0b101:
            armBranch(instruction)

        case 0b111 where (instruction & 0x0F00_0000) == 0x0F00_0000:
            armSoftwareInterrupt(instruction)

        default:
            // Coprocessor space. The GBA has no coprocessor, so anything here
            // is undefined.
            raiseUndefined()
        }
    }

    // MARK: Branches

    private func armBranch(_ instruction: UInt32) {
        // 24-bit offset, word-aligned, sign-extended to 32 bits.
        let rawOffset = instruction & 0x00FF_FFFF
        let signExtended = (rawOffset & 0x0080_0000) != 0
            ? Int32(bitPattern: rawOffset | 0xFF00_0000)
            : Int32(bitPattern: rawOffset)
        let offset = signExtended << 2

        let link = instruction & (1 << 24) != 0
        if link {
            // Return to the instruction after this one.
            registers[14] = pc &+ 4
        }

        // Branches are relative to the pipeline-adjusted PC.
        pc = UInt32(bitPattern: Int32(bitPattern: pc &+ 8) &+ offset)
        branched = true
    }

    private func armBranchExchange(_ instruction: UInt32) {
        let target = readRegister(Int(instruction & 0xF))
        branchAndExchange(to: target)
    }

    // MARK: Data processing

    private func armDataProcessing(_ instruction: UInt32, immediateOperand: Bool) {
        let opcode = (instruction >> 21) & 0xF
        let setFlags = instruction & (1 << 20) != 0

        // TST/TEQ/CMP/CMN with S clear aren't comparisons at all — the
        // encoding is reused for the PSR transfer instructions.
        if !setFlags && opcode >= 0x8 && opcode <= 0xB {
            armPSRTransfer(instruction, immediateOperand: immediateOperand)
            return
        }

        let rn = Int((instruction >> 16) & 0xF)
        let rd = Int((instruction >> 12) & 0xF)

        var shifterCarry = carry
        let operand2: UInt32

        if immediateOperand {
            let value = instruction & 0xFF
            let rotate = ((instruction >> 8) & 0xF) * 2
            if rotate == 0 {
                operand2 = value
            } else {
                operand2 = (value >> rotate) | (value << (32 - rotate))
                shifterCarry = operand2 & 0x8000_0000 != 0
            }
        } else {
            let shiftType = (instruction >> 5) & 0x3
            let byRegister = instruction & (1 << 4) != 0

            let amount: UInt32
            if byRegister {
                // Only the low byte of the shift register is used.
                amount = readRegister(Int((instruction >> 8) & 0xF)) & 0xFF
            } else {
                amount = (instruction >> 7) & 0x1F
            }

            // A register-specified shift costs an internal cycle, and that
            // extra cycle is why R15 reads as +12 rather than +8 here.
            var operandValue = readRegister(Int(instruction & 0xF))
            if byRegister {
                bus.idle(1)
                if (instruction & 0xF) == 15 { operandValue = pc &+ 12 }
            }

            let shifted = applyShift(type: shiftType, amount: amount, value: operandValue,
                                     byRegister: byRegister, currentCarry: carry)
            operand2 = shifted.value
            shifterCarry = shifted.carry
        }

        // Rn also reads +12 when a register shift pushed the pipeline along.
        var lhs = readRegister(rn)
        if !immediateOperand, instruction & (1 << 4) != 0, rn == 15 {
            lhs = pc &+ 12
        }

        var result: UInt32 = 0
        var writesResult = true

        switch opcode {
        case 0x0:  // AND
            result = lhs & operand2
            if setFlags { setLogicalFlags(result, carryOut: shifterCarry) }
        case 0x1:  // EOR
            result = lhs ^ operand2
            if setFlags { setLogicalFlags(result, carryOut: shifterCarry) }
        case 0x2:  // SUB
            result = lhs &- operand2
            if setFlags { setSubFlags(result: result, lhs: lhs, rhs: operand2) }
        case 0x3:  // RSB — reversed operands
            result = operand2 &- lhs
            if setFlags { setSubFlags(result: result, lhs: operand2, rhs: lhs) }
        case 0x4:  // ADD
            result = lhs &+ operand2
            if setFlags { setAddFlags(result: result, lhs: lhs, rhs: operand2) }
        case 0x5:  // ADC
            let carryIn: UInt32 = carry ? 1 : 0
            result = lhs &+ operand2 &+ carryIn
            if setFlags { setAddFlags(result: result, lhs: lhs, rhs: operand2, carryIn: carryIn) }
        case 0x6:  // SBC
            let borrowIn: UInt32 = carry ? 1 : 0
            result = lhs &- operand2 &- (1 &- borrowIn)
            if setFlags { setSubFlags(result: result, lhs: lhs, rhs: operand2, borrowIn: borrowIn) }
        case 0x7:  // RSC
            let borrowIn: UInt32 = carry ? 1 : 0
            result = operand2 &- lhs &- (1 &- borrowIn)
            if setFlags { setSubFlags(result: result, lhs: operand2, rhs: lhs, borrowIn: borrowIn) }
        case 0x8:  // TST
            result = lhs & operand2
            setLogicalFlags(result, carryOut: shifterCarry)
            writesResult = false
        case 0x9:  // TEQ
            result = lhs ^ operand2
            setLogicalFlags(result, carryOut: shifterCarry)
            writesResult = false
        case 0xA:  // CMP
            result = lhs &- operand2
            setSubFlags(result: result, lhs: lhs, rhs: operand2)
            writesResult = false
        case 0xB:  // CMN
            result = lhs &+ operand2
            setAddFlags(result: result, lhs: lhs, rhs: operand2)
            writesResult = false
        case 0xC:  // ORR
            result = lhs | operand2
            if setFlags { setLogicalFlags(result, carryOut: shifterCarry) }
        case 0xD:  // MOV
            result = operand2
            if setFlags { setLogicalFlags(result, carryOut: shifterCarry) }
        case 0xE:  // BIC
            result = lhs & ~operand2
            if setFlags { setLogicalFlags(result, carryOut: shifterCarry) }
        default:   // MVN
            result = ~operand2
            if setFlags { setLogicalFlags(result, carryOut: shifterCarry) }
        }

        if writesResult {
            // S with Rd == R15 restores CPSR from SPSR: this is how an
            // exception handler returns and switches mode in one instruction.
            if rd == 15 && setFlags {
                let restored = spsr
                writeRegister(15, result)
                cpsr = restored
                // The restored T bit decides the instruction set, so re-align.
                pc = thumb ? (pc & ~1) : (pc & ~3)
            } else {
                writeRegister(rd, result)
            }
        } else if rd == 15 && setFlags {
            // The comparison opcodes with S set and Rd = R15 are the ARMv4
            // "P variant" (TSTP/TEQP/CMPP/CMNP): the result is discarded and
            // SPSR is copied into CPSR. Code uses it to drop back to the
            // caller's mode without touching PC. Treating it as an ordinary
            // compare leaves the CPU stuck in whatever mode it was in, running
            // on that mode's banked — and possibly uninitialised — stack.
            cpsr = spsr
        }
    }

    // MARK: PSR transfer

    private func armPSRTransfer(_ instruction: UInt32, immediateOperand: Bool) {
        let useSPSR = instruction & (1 << 22) != 0
        let isMSR = instruction & (1 << 21) != 0

        if !isMSR {
            // MRS — read the status register into Rd.
            let rd = Int((instruction >> 12) & 0xF)
            writeRegister(rd, useSPSR ? spsr : cpsr)
            return
        }

        // MSR — write some or all of the status register.
        let value: UInt32
        if immediateOperand {
            let immediate = instruction & 0xFF
            let rotate = ((instruction >> 8) & 0xF) * 2
            value = rotate == 0 ? immediate : (immediate >> rotate) | (immediate << (32 - rotate))
        } else {
            value = readRegister(Int(instruction & 0xF))
        }

        // The field mask picks which byte lanes are writable.
        var mask: UInt32 = 0
        if instruction & (1 << 16) != 0 { mask |= 0x0000_00FF }
        if instruction & (1 << 17) != 0 { mask |= 0x0000_FF00 }
        if instruction & (1 << 18) != 0 { mask |= 0x00FF_0000 }
        if instruction & (1 << 19) != 0 { mask |= 0xFF00_0000 }

        if useSPSR {
            guard mode.hasSPSR else { return }
            spsr = (spsr & ~mask) | (value & mask)
        } else {
            // User mode can only touch the condition flags, never the control
            // bits — that's what keeps it from escalating its own privilege.
            if mode == .user { mask &= 0xFF00_0000 }
            let updated = (cpsr & ~mask) | (value & mask)
            cpsr = updated
        }
    }

    // MARK: Multiply

    private func armMultiply(_ instruction: UInt32) {
        let rd = Int((instruction >> 16) & 0xF)
        let rn = Int((instruction >> 12) & 0xF)
        let rs = Int((instruction >> 8) & 0xF)
        let rm = Int(instruction & 0xF)

        let accumulate = instruction & (1 << 21) != 0
        let setFlags = instruction & (1 << 20) != 0

        var result = readRegister(rm) &* readRegister(rs)
        if accumulate {
            result = result &+ readRegister(rn)
        }

        writeRegister(rd, result)

        if setFlags {
            negative = result & 0x8000_0000 != 0
            zero = result == 0
            // The carry flag is architecturally unpredictable after a multiply.
        }

        bus.idle(multiplyCycles(for: readRegister(rs)) + (accumulate ? 1 : 0))
    }

    private func armMultiplyLong(_ instruction: UInt32) {
        let rdHi = Int((instruction >> 16) & 0xF)
        let rdLo = Int((instruction >> 12) & 0xF)
        let rs = Int((instruction >> 8) & 0xF)
        let rm = Int(instruction & 0xF)

        let isSigned = instruction & (1 << 22) != 0
        let accumulate = instruction & (1 << 21) != 0
        let setFlags = instruction & (1 << 20) != 0

        let lhs = readRegister(rm)
        let rhs = readRegister(rs)

        var result: UInt64
        if isSigned {
            let product = Int64(Int32(bitPattern: lhs)) * Int64(Int32(bitPattern: rhs))
            result = UInt64(bitPattern: product)
        } else {
            result = UInt64(lhs) * UInt64(rhs)
        }

        if accumulate {
            let existing = (UInt64(readRegister(rdHi)) << 32) | UInt64(readRegister(rdLo))
            result = result &+ existing
        }

        writeRegister(rdLo, UInt32(result & 0xFFFF_FFFF))
        writeRegister(rdHi, UInt32(result >> 32))

        if setFlags {
            negative = result & 0x8000_0000_0000_0000 != 0
            zero = result == 0
        }

        bus.idle(multiplyCycles(for: rhs) + 1 + (accumulate ? 1 : 0))
    }

    /// The multiplier is iterative and stops early once the remaining operand
    /// bits are all sign, so small values cost fewer cycles.
    private func multiplyCycles(for operand: UInt32) -> Int {
        if operand & 0xFFFF_FF00 == 0 || operand & 0xFFFF_FF00 == 0xFFFF_FF00 { return 1 }
        if operand & 0xFFFF_0000 == 0 || operand & 0xFFFF_0000 == 0xFFFF_0000 { return 2 }
        if operand & 0xFF00_0000 == 0 || operand & 0xFF00_0000 == 0xFF00_0000 { return 3 }
        return 4
    }

    // MARK: Single data transfer

    private func armSingleDataTransfer(_ instruction: UInt32, registerOffset: Bool) {
        let preIndexed = instruction & (1 << 24) != 0
        let addOffset = instruction & (1 << 23) != 0
        let isByte = instruction & (1 << 22) != 0
        let writeBack = instruction & (1 << 21) != 0
        let isLoad = instruction & (1 << 20) != 0

        let rn = Int((instruction >> 16) & 0xF)
        let rd = Int((instruction >> 12) & 0xF)

        let offset: UInt32
        if registerOffset {
            let shiftType = (instruction >> 5) & 0x3
            let amount = (instruction >> 7) & 0x1F
            let base = readRegister(Int(instruction & 0xF))
            offset = applyShift(type: shiftType, amount: amount, value: base,
                                byRegister: false, currentCarry: carry).value
        } else {
            offset = instruction & 0xFFF
        }

        let baseAddress = readRegister(rn)
        let offsetAddress = addOffset ? baseAddress &+ offset : baseAddress &- offset
        let address = preIndexed ? offsetAddress : baseAddress

        if isLoad {
            let value: UInt32
            if isByte {
                value = UInt32(bus.read8(address, sequential: false))
            } else {
                // An unaligned word load rotates rather than faulting, which
                // some code relies on deliberately.
                let word = bus.read32(address & ~3, sequential: false)
                let rotation = (address & 3) * 8
                value = rotation == 0 ? word : (word >> rotation) | (word << (32 - rotation))
            }

            // Write-back happens before the load, so a load into the base
            // register wins.
            if writeBack || !preIndexed {
                if rn != rd { writeRegister(rn, offsetAddress) }
            }
            writeRegister(rd, value)
            bus.idle(1)
        } else {
            // Storing R15 writes the pipeline-ahead value, +12 not +8.
            let value = rd == 15 ? pc &+ 12 : readRegister(rd)
            if isByte {
                bus.write8(address, UInt8(value & 0xFF), sequential: false)
            } else {
                bus.write32(address & ~3, value, sequential: false)
            }
            if writeBack || !preIndexed {
                writeRegister(rn, offsetAddress)
            }
        }
    }

    // MARK: Halfword and signed transfers

    private func armHalfwordTransfer(_ instruction: UInt32) {
        let preIndexed = instruction & (1 << 24) != 0
        let addOffset = instruction & (1 << 23) != 0
        let immediateOffset = instruction & (1 << 22) != 0
        let writeBack = instruction & (1 << 21) != 0
        let isLoad = instruction & (1 << 20) != 0

        let rn = Int((instruction >> 16) & 0xF)
        let rd = Int((instruction >> 12) & 0xF)
        let kind = (instruction >> 5) & 0x3

        let offset: UInt32
        if immediateOffset {
            offset = ((instruction >> 4) & 0xF0) | (instruction & 0xF)
        } else {
            offset = readRegister(Int(instruction & 0xF))
        }

        let baseAddress = readRegister(rn)
        let offsetAddress = addOffset ? baseAddress &+ offset : baseAddress &- offset
        let address = preIndexed ? offsetAddress : baseAddress

        if isLoad {
            let value: UInt32
            switch kind {
            case 1:  // LDRH — unsigned halfword, rotated if misaligned
                let half = bus.read16(address & ~1, sequential: false)
                value = (address & 1) != 0
                    ? UInt32(half) >> 8 | UInt32(half) << 24
                    : UInt32(half)
            case 2:  // LDRSB — sign-extended byte
                value = UInt32(bitPattern: Int32(Int8(bitPattern: bus.read8(address, sequential: false))))
            default: // LDRSH — sign-extended halfword. A misaligned address
                     // degrades to a sign-extended *byte* load on this core.
                if address & 1 != 0 {
                    value = UInt32(bitPattern: Int32(Int8(bitPattern: bus.read8(address, sequential: false))))
                } else {
                    let half = bus.read16(address, sequential: false)
                    value = UInt32(bitPattern: Int32(Int16(bitPattern: half)))
                }
            }

            if writeBack || !preIndexed {
                if rn != rd { writeRegister(rn, offsetAddress) }
            }
            writeRegister(rd, value)
            bus.idle(1)
        } else {
            let value = rd == 15 ? pc &+ 12 : readRegister(rd)
            bus.write16(address & ~1, UInt16(value & 0xFFFF), sequential: false)
            if writeBack || !preIndexed {
                writeRegister(rn, offsetAddress)
            }
        }
    }

    // MARK: Swap

    private func armSwap(_ instruction: UInt32) {
        let rn = Int((instruction >> 16) & 0xF)
        let rd = Int((instruction >> 12) & 0xF)
        let rm = Int(instruction & 0xF)
        let isByte = instruction & (1 << 22) != 0

        let address = readRegister(rn)
        let source = readRegister(rm)

        // An atomic read-then-write; the read must complete before the write.
        if isByte {
            let old = bus.read8(address, sequential: false)
            bus.write8(address, UInt8(source & 0xFF), sequential: false)
            writeRegister(rd, UInt32(old))
        } else {
            let word = bus.read32(address & ~3, sequential: false)
            let rotation = (address & 3) * 8
            let old = rotation == 0 ? word : (word >> rotation) | (word << (32 - rotation))
            bus.write32(address & ~3, source, sequential: false)
            writeRegister(rd, old)
        }
        bus.idle(1)
    }

    // MARK: Block transfer

    private func armBlockTransfer(_ instruction: UInt32) {
        let preIndexed = instruction & (1 << 24) != 0
        let addOffset = instruction & (1 << 23) != 0
        let useUserBank = instruction & (1 << 22) != 0
        let writeBack = instruction & (1 << 21) != 0
        let isLoad = instruction & (1 << 20) != 0

        let rn = Int((instruction >> 16) & 0xF)
        let registerList = instruction & 0xFFFF

        // An empty list transfers R15 alone and adjusts the base by a full
        // 16 registers — an edge case real code hits via compiler output.
        let registers: [Int]
        let addressSpan: UInt32
        if registerList == 0 {
            registers = [15]
            addressSpan = 64
        } else {
            registers = (0..<16).filter { registerList & (1 << UInt32($0)) != 0 }
            addressSpan = UInt32(registers.count) * 4
        }

        let base = readRegister(rn)
        // Transfers always run from the lowest address upwards regardless of
        // the addressing mode, so compute the bottom of the block first.
        var address = addOffset ? base : base &- addressSpan
        let finalBase = addOffset ? base &+ addressSpan : base &- addressSpan

        // Pre/post indexing shifts the whole run by one word when counting up,
        // and the other way when counting down.
        if preIndexed == addOffset {
            address = address &+ 4
        }

        // The S bit means "use the user-mode bank", except on an LDM that
        // includes R15, where it instead means "restore CPSR from SPSR".
        let restoresCPSR = useUserBank && isLoad && (registerList & (1 << 15)) != 0
        let usesUserBank = useUserBank && !restoresCPSR
        let savedMode = mode
        if usesUserBank {
            switchMode(to: .user)
        }

        var sequential = false
        for register in registers {
            if isLoad {
                let value = bus.read32(address & ~3, sequential: sequential)
                if register == 15 {
                    pc = value & ~3
                    branched = true
                } else {
                    self.registers[register] = value
                }
            } else {
                // Storing the base register writes its original value only if
                // it's first in the list; otherwise the written-back value.
                let value: UInt32
                if register == 15 {
                    value = pc &+ 12
                } else if register == rn && registers.first != rn && writeBack {
                    value = finalBase
                } else {
                    value = self.registers[register]
                }
                bus.write32(address & ~3, value, sequential: sequential)
            }
            address = address &+ 4
            sequential = true
        }

        if usesUserBank {
            switchMode(to: savedMode)
        }

        if restoresCPSR {
            let restored = spsr
            cpsr = restored
            pc = thumb ? (pc & ~1) : (pc & ~3)
        }

        // On a load that included the base, the loaded value wins over
        // write-back.
        if writeBack {
            if !(isLoad && registerList & (1 << UInt32(rn)) != 0) {
                writeRegister(rn, finalBase)
            }
        }

        if isLoad { bus.idle(1) }
    }

    // MARK: Software interrupt

    private func armSoftwareInterrupt(_ instruction: UInt32) {
        let comment = (instruction >> 16) & 0xFF
        // The BIOS is Nintendo's copyrighted code and isn't shipped, so the
        // calls it would service are implemented directly. Anything the
        // high-level implementation doesn't cover falls through to the vector.
        if !bus.handleSWI(comment: comment, cpu: self) {
            raiseSWI()
        }
    }
}
