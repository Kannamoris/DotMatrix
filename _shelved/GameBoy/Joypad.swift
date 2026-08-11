import Foundation

/// The eight buttons, as a bit set the UI can hand to the core.
struct GBButtons: OptionSet, Sendable {
    let rawValue: UInt8

    static let right  = GBButtons(rawValue: 1 << 0)
    static let left   = GBButtons(rawValue: 1 << 1)
    static let up     = GBButtons(rawValue: 1 << 2)
    static let down   = GBButtons(rawValue: 1 << 3)
    static let a      = GBButtons(rawValue: 1 << 4)
    static let b      = GBButtons(rawValue: 1 << 5)
    static let select = GBButtons(rawValue: 1 << 6)
    static let start  = GBButtons(rawValue: 1 << 7)
}

/// P1/JOYP at 0xFF00.
///
/// The register is active-low: a 0 bit means pressed, and the game selects
/// which nibble it wants to see by pulling bit 4 or bit 5 low.
final class Joypad {
    private var pressed: GBButtons = []
    private var selectDirections = false
    private var selectActions = false

    var interruptRequested = false

    func setPressed(_ buttons: GBButtons) {
        let newlyPressed = buttons.subtracting(pressed)
        pressed = buttons
        // A high-to-low transition on any selected line raises the joypad
        // interrupt. It is what wakes the CPU from STOP.
        if !newlyPressed.isEmpty && lineIsSelected(for: newlyPressed) {
            interruptRequested = true
        }
    }

    private func lineIsSelected(for buttons: GBButtons) -> Bool {
        let directionMask: GBButtons = [.right, .left, .up, .down]
        let actionMask: GBButtons = [.a, .b, .select, .start]
        if selectDirections && !buttons.isDisjoint(with: directionMask) { return true }
        if selectActions && !buttons.isDisjoint(with: actionMask) { return true }
        return false
    }

    func write(_ value: UInt8) {
        selectDirections = (value & 0x10) == 0
        selectActions = (value & 0x20) == 0
    }

    func read() -> UInt8 {
        // Bits 6-7 are unused and read as 1.
        var result: UInt8 = 0xCF
        if selectDirections { result &= ~0x10 }
        if selectActions { result &= ~0x20 }

        var low: UInt8 = 0x0F
        if selectDirections {
            if pressed.contains(.right) { low &= ~0x01 }
            if pressed.contains(.left)  { low &= ~0x02 }
            if pressed.contains(.up)    { low &= ~0x04 }
            if pressed.contains(.down)  { low &= ~0x08 }
        }
        if selectActions {
            if pressed.contains(.a)      { low &= ~0x01 }
            if pressed.contains(.b)      { low &= ~0x02 }
            if pressed.contains(.select) { low &= ~0x04 }
            if pressed.contains(.start)  { low &= ~0x08 }
        }
        return (result & 0xF0) | low
    }
}
