import Foundation

/// The ten physical inputs, laid out in KEYINPUT bit order.
///
/// The hardware register is active-low — a 0 bit means held — but this set uses
/// the intuitive polarity and the bus inverts on read.
struct GBAButtons: OptionSet, Sendable {
    let rawValue: UInt16

    static let a      = GBAButtons(rawValue: 1 << 0)
    static let b      = GBAButtons(rawValue: 1 << 1)
    static let select = GBAButtons(rawValue: 1 << 2)
    static let start  = GBAButtons(rawValue: 1 << 3)
    static let right  = GBAButtons(rawValue: 1 << 4)
    static let left   = GBAButtons(rawValue: 1 << 5)
    static let up     = GBAButtons(rawValue: 1 << 6)
    static let down   = GBAButtons(rawValue: 1 << 7)
    static let r      = GBAButtons(rawValue: 1 << 8)
    static let l      = GBAButtons(rawValue: 1 << 9)

    static let directions: GBAButtons = [.up, .down, .left, .right]
    static let faceButtons: GBAButtons = [.a, .b]
    static let shoulders: GBAButtons = [.l, .r]
}
