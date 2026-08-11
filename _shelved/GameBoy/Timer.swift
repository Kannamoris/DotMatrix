import Foundation

/// DIV / TIMA / TMA / TAC.
///
/// The hardware has a single free-running 16-bit counter. DIV is just its top
/// byte, and TIMA is clocked by the *falling edge* of one selected bit of that
/// counter ANDed with the enable flag. Modelling it that way (rather than as a
/// countdown) gets the quirks right for free: writing to DIV resets the counter
/// and can itself clock TIMA, and changing TAC mid-flight can too.
final class GBTimer {
    /// The internal counter. DIV reads back as the high byte.
    private(set) var systemCounter: UInt16 = 0

    var tima: UInt8 = 0
    var tma: UInt8 = 0
    var tac: UInt8 = 0xF8

    /// TIMA overflow doesn't reload immediately — there are four T-cycles where
    /// TIMA reads zero before TMA is copied in and the interrupt fires.
    private var overflowCountdown: Int = -1

    private var lastEdgeInput = false

    /// Set when the timer wants an interrupt; the MMU drains this into IF.
    var interruptRequested = false

    var div: UInt8 {
        UInt8(systemCounter >> 8)
    }

    func resetDIV() {
        systemCounter = 0
        updateEdge()
    }

    func writeTAC(_ value: UInt8) {
        tac = value | 0xF8
        updateEdge()
    }

    func writeTIMA(_ value: UInt8) {
        // A write during the reload delay cancels the pending reload.
        if overflowCountdown > 0 {
            overflowCountdown = -1
        }
        tima = value
    }

    func writeTMA(_ value: UInt8) {
        tma = value
        // Writing TMA on the cycle the reload happens loads the new value.
        if overflowCountdown == 0 {
            tima = value
        }
    }

    /// Advance by `cycles` T-cycles.
    func tick(_ cycles: Int) {
        for _ in 0..<cycles {
            if overflowCountdown >= 0 {
                overflowCountdown -= 1
                if overflowCountdown < 0 {
                    tima = tma
                    interruptRequested = true
                }
            }
            systemCounter = systemCounter &+ 1
            updateEdge()
        }
    }

    /// Which bit of the system counter drives TIMA at the current TAC setting.
    private var selectedBit: UInt16 {
        switch tac & 0x03 {
        case 0: return 1 << 9    // 4096 Hz
        case 1: return 1 << 3    // 262144 Hz
        case 2: return 1 << 5    // 65536 Hz
        default: return 1 << 7   // 16384 Hz
        }
    }

    private func updateEdge() {
        let enabled = tac & 0x04 != 0
        let input = enabled && (systemCounter & selectedBit) != 0
        // Falling edge: was high, now low.
        if lastEdgeInput && !input {
            incrementTIMA()
        }
        lastEdgeInput = input
    }

    private func incrementTIMA() {
        if tima == 0xFF {
            tima = 0
            overflowCountdown = 4
        } else {
            tima &+= 1
        }
    }
}
