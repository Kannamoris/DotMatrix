import Foundation

/// A cartridge memory bank controller: the chip on the cartridge that maps its
/// ROM and SRAM into the CPU's 16-bit address space.
protocol MemoryBankController: AnyObject {
    /// Read from 0x0000...0x7FFF.
    func readROM(_ addr: UInt16) -> UInt8
    /// Write to 0x0000...0x7FFF — no memory there, these are mapper commands.
    func writeControl(_ addr: UInt16, _ value: UInt8)
    /// Read from 0xA000...0xBFFF.
    func readRAM(_ addr: UInt16) -> UInt8
    /// Write to 0xA000...0xBFFF.
    func writeRAM(_ addr: UInt16, _ value: UInt8)

    var ram: [UInt8] { get }
    func loadRAM(_ bytes: [UInt8])

    var hasBattery: Bool { get set }
    /// Set whenever SRAM changes, cleared by the save layer once flushed.
    var ramDirty: Bool { get set }

    /// RTC state for mappers that have a clock; empty otherwise.
    func rtcSnapshot() -> [String: Int]
    func restoreRTC(_ snapshot: [String: Int])
}

// Note: the RTC defaults live on `BaseMBC` rather than in a protocol extension.
// Conformance is declared on `BaseMBC`, so a protocol-extension default would be
// bound statically there and a subclass's version would never be dispatched
// through the witness table.

/// Shared storage and bank-index arithmetic.
class BaseMBC: MemoryBankController {
    let rom: [UInt8]
    private(set) var sram: [UInt8]
    let romBankMask: Int

    var hasBattery: Bool = false
    var ramDirty: Bool = false
    var ramEnabled: Bool = false

    init(rom: [UInt8], ramSize: Int) {
        self.rom = rom
        // SRAM powers up as 0xFF on real hardware; games that check for an
        // uninitialised save rely on it not being all-zero.
        self.sram = ramSize > 0 ? [UInt8](repeating: 0xFF, count: ramSize) : []
        let banks = max(2, rom.count / 0x4000)
        // Round up to a power of two so masking wraps the way the hardware does.
        var mask = 1
        while mask < banks { mask <<= 1 }
        self.romBankMask = mask - 1
    }

    var ram: [UInt8] { sram }

    func loadRAM(_ bytes: [UInt8]) {
        guard !sram.isEmpty else { return }
        for i in 0..<min(bytes.count, sram.count) { sram[i] = bytes[i] }
        ramDirty = false
    }

    /// Fetch from a ROM bank, tolerating dumps that are shorter than the mask.
    final func romByte(bank: Int, offset: Int) -> UInt8 {
        let index = (bank & romBankMask) * 0x4000 + offset
        return index < rom.count ? rom[index] : 0xFF
    }

    final func sramByte(bank: Int, offset: Int) -> UInt8 {
        guard ramEnabled, !sram.isEmpty else { return 0xFF }
        let index = (bank * 0x2000 + offset) % sram.count
        return sram[index]
    }

    final func setSRAMByte(bank: Int, offset: Int, _ value: UInt8) {
        guard ramEnabled, !sram.isEmpty else { return }
        let index = (bank * 0x2000 + offset) % sram.count
        sram[index] = value
        ramDirty = true
    }

    func readROM(_ addr: UInt16) -> UInt8 { 0xFF }
    func writeControl(_ addr: UInt16, _ value: UInt8) {}
    func readRAM(_ addr: UInt16) -> UInt8 { 0xFF }
    func writeRAM(_ addr: UInt16, _ value: UInt8) {}

    func rtcSnapshot() -> [String: Int] { [:] }
    func restoreRTC(_ snapshot: [String: Int]) {}
}

// MARK: - No mapper

/// 32 KB cartridges with the ROM wired straight to the bus.
final class NoMBC: BaseMBC {
    override func readROM(_ addr: UInt16) -> UInt8 {
        Int(addr) < rom.count ? rom[Int(addr)] : 0xFF
    }

    override func writeControl(_ addr: UInt16, _ value: UInt8) {
        // Some of these carts do have a small RAM chip with no enable line.
        if !sram.isEmpty { ramEnabled = true }
    }

    override func readRAM(_ addr: UInt16) -> UInt8 {
        guard !sram.isEmpty else { return 0xFF }
        ramEnabled = true
        return sramByte(bank: 0, offset: Int(addr - 0xA000))
    }

    override func writeRAM(_ addr: UInt16, _ value: UInt8) {
        guard !sram.isEmpty else { return }
        ramEnabled = true
        setSRAMByte(bank: 0, offset: Int(addr - 0xA000), value)
    }
}

// MARK: - MBC1

/// Up to 2 MB ROM / 32 KB RAM. The upper two bank bits are shared between ROM
/// and RAM, and which they apply to depends on the banking mode.
final class MBC1: BaseMBC {
    private var bankLow: UInt8 = 1     // 5 bits
    private var bankHigh: UInt8 = 0    // 2 bits
    private var advancedMode = false   // 0x6000 latch

    override func readROM(_ addr: UInt16) -> UInt8 {
        if addr < 0x4000 {
            // In advanced mode the high bits also move the "fixed" low bank —
            // this is how 1 MB+ carts reach their upper menus.
            let bank = advancedMode ? Int(bankHigh) << 5 : 0
            return romByte(bank: bank, offset: Int(addr))
        }
        let bank = (Int(bankHigh) << 5) | Int(bankLow)
        return romByte(bank: bank, offset: Int(addr - 0x4000))
    }

    override func writeControl(_ addr: UInt16, _ value: UInt8) {
        switch addr {
        case 0x0000...0x1FFF:
            ramEnabled = (value & 0x0F) == 0x0A
        case 0x2000...0x3FFF:
            // Bank 0 is not selectable here; the hardware substitutes bank 1.
            let v = value & 0x1F
            bankLow = v == 0 ? 1 : v
        case 0x4000...0x5FFF:
            bankHigh = value & 0x03
        default:
            advancedMode = (value & 0x01) == 1
        }
    }

    private var ramBank: Int { advancedMode ? Int(bankHigh) : 0 }

    override func readRAM(_ addr: UInt16) -> UInt8 {
        sramByte(bank: ramBank, offset: Int(addr - 0xA000))
    }

    override func writeRAM(_ addr: UInt16, _ value: UInt8) {
        setSRAMByte(bank: ramBank, offset: Int(addr - 0xA000), value)
    }
}

// MARK: - MBC2

/// 256 KB ROM max, with 512 x 4-bit of RAM built into the mapper itself.
final class MBC2: BaseMBC {
    private var romBank: UInt8 = 1

    init(rom: [UInt8]) {
        super.init(rom: rom, ramSize: 512)
    }

    override func readROM(_ addr: UInt16) -> UInt8 {
        addr < 0x4000
            ? romByte(bank: 0, offset: Int(addr))
            : romByte(bank: Int(romBank), offset: Int(addr - 0x4000))
    }

    override func writeControl(_ addr: UInt16, _ value: UInt8) {
        guard addr < 0x4000 else { return }
        // Address bit 8 picks which register is being written.
        if addr & 0x0100 == 0 {
            ramEnabled = (value & 0x0F) == 0x0A
        } else {
            let v = value & 0x0F
            romBank = v == 0 ? 1 : v
        }
    }

    override func readRAM(_ addr: UInt16) -> UInt8 {
        guard ramEnabled else { return 0xFF }
        // Only 9 address lines are decoded, so the 512 bytes echo through the
        // whole A000-BFFF window, and the upper nibble reads back as 1s.
        return sramByte(bank: 0, offset: Int(addr) & 0x01FF) | 0xF0
    }

    override func writeRAM(_ addr: UInt16, _ value: UInt8) {
        setSRAMByte(bank: 0, offset: Int(addr) & 0x01FF, value & 0x0F)
    }
}

// MARK: - MBC3

/// Up to 2 MB ROM, 32 KB RAM, plus an optional battery-backed real-time clock.
final class MBC3: BaseMBC {
    private var romBank: UInt8 = 1
    private var ramSelect: UInt8 = 0   // 0x00-0x03 = RAM bank, 0x08-0x0C = RTC
    private let hasRTC: Bool

    // Live clock.
    private var rtcSeconds = 0, rtcMinutes = 0, rtcHours = 0
    private var rtcDays = 0, rtcDayCarry = false, rtcHalted = false
    private var lastTick = Date()

    // Latched copy exposed to the game between 0x6000 latch writes.
    private var latched = (s: 0, m: 0, h: 0, d: 0, carry: false)
    private var lastLatchValue: UInt8 = 0xFF

    init(rom: [UInt8], ramSize: Int, hasRTC: Bool) {
        self.hasRTC = hasRTC
        super.init(rom: rom, ramSize: ramSize)
    }

    override func readROM(_ addr: UInt16) -> UInt8 {
        addr < 0x4000
            ? romByte(bank: 0, offset: Int(addr))
            : romByte(bank: Int(romBank), offset: Int(addr - 0x4000))
    }

    override func writeControl(_ addr: UInt16, _ value: UInt8) {
        switch addr {
        case 0x0000...0x1FFF:
            ramEnabled = (value & 0x0F) == 0x0A
        case 0x2000...0x3FFF:
            let v = value & 0x7F
            romBank = v == 0 ? 1 : v
        case 0x4000...0x5FFF:
            ramSelect = value
        default:
            // Writing 0 then 1 copies the running clock into the latch.
            if lastLatchValue == 0x00 && value == 0x01 {
                advanceClock()
                latched = (rtcSeconds, rtcMinutes, rtcHours, rtcDays, rtcDayCarry)
            }
            lastLatchValue = value
        }
    }

    override func readRAM(_ addr: UInt16) -> UInt8 {
        guard ramEnabled else { return 0xFF }
        if hasRTC, ramSelect >= 0x08, ramSelect <= 0x0C {
            switch ramSelect {
            case 0x08: return UInt8(latched.s)
            case 0x09: return UInt8(latched.m)
            case 0x0A: return UInt8(latched.h)
            case 0x0B: return UInt8(latched.d & 0xFF)
            default:
                var v: UInt8 = UInt8((latched.d >> 8) & 0x01)
                if rtcHalted { v |= 0x40 }
                if latched.carry { v |= 0x80 }
                return v
            }
        }
        return sramByte(bank: Int(ramSelect & 0x03), offset: Int(addr - 0xA000))
    }

    override func writeRAM(_ addr: UInt16, _ value: UInt8) {
        guard ramEnabled else { return }
        if hasRTC, ramSelect >= 0x08, ramSelect <= 0x0C {
            advanceClock()
            switch ramSelect {
            case 0x08: rtcSeconds = Int(value & 0x3F)
            case 0x09: rtcMinutes = Int(value & 0x3F)
            case 0x0A: rtcHours = Int(value & 0x1F)
            case 0x0B: rtcDays = (rtcDays & 0x100) | Int(value)
            default:
                rtcDays = (rtcDays & 0xFF) | (Int(value & 0x01) << 8)
                rtcHalted = value & 0x40 != 0
                rtcDayCarry = value & 0x80 != 0
            }
            ramDirty = true
            return
        }
        setSRAMByte(bank: Int(ramSelect & 0x03), offset: Int(addr - 0xA000), value)
    }

    /// Roll the clock forward by however much wall time has passed.
    private func advanceClock() {
        let now = Date()
        defer { lastTick = now }
        guard hasRTC, !rtcHalted else { return }

        var elapsed = Int(now.timeIntervalSince(lastTick))
        guard elapsed > 0 else { return }

        elapsed += rtcSeconds
        rtcSeconds = elapsed % 60
        var carry = elapsed / 60

        carry += rtcMinutes
        rtcMinutes = carry % 60
        carry /= 60

        carry += rtcHours
        rtcHours = carry % 24
        carry /= 24

        rtcDays += carry
        if rtcDays > 0x1FF {
            rtcDayCarry = true
            rtcDays &= 0x1FF
        }
    }

    override func rtcSnapshot() -> [String: Int] {
        guard hasRTC else { return [:] }
        advanceClock()
        return [
            "s": rtcSeconds, "m": rtcMinutes, "h": rtcHours,
            "d": rtcDays, "carry": rtcDayCarry ? 1 : 0,
            "halted": rtcHalted ? 1 : 0,
            "epoch": Int(lastTick.timeIntervalSince1970),
        ]
    }

    override func restoreRTC(_ snapshot: [String: Int]) {
        guard hasRTC, let epoch = snapshot["epoch"] else { return }
        rtcSeconds = snapshot["s"] ?? 0
        rtcMinutes = snapshot["m"] ?? 0
        rtcHours = snapshot["h"] ?? 0
        rtcDays = snapshot["d"] ?? 0
        rtcDayCarry = (snapshot["carry"] ?? 0) == 1
        rtcHalted = (snapshot["halted"] ?? 0) == 1
        // Restoring the old timestamp lets the clock catch up for the time the
        // app was closed, which is what a real battery-backed cart does.
        lastTick = Date(timeIntervalSince1970: TimeInterval(epoch))
        latched = (rtcSeconds, rtcMinutes, rtcHours, rtcDays, rtcDayCarry)
    }
}

// MARK: - MBC5

/// Up to 8 MB ROM / 128 KB RAM. Bank 0 is directly selectable, unlike MBC1/3.
final class MBC5: BaseMBC {
    private var romBank: Int = 1
    private var ramBank: Int = 0

    override func readROM(_ addr: UInt16) -> UInt8 {
        addr < 0x4000
            ? romByte(bank: 0, offset: Int(addr))
            : romByte(bank: romBank, offset: Int(addr - 0x4000))
    }

    override func writeControl(_ addr: UInt16, _ value: UInt8) {
        switch addr {
        case 0x0000...0x1FFF:
            ramEnabled = (value & 0x0F) == 0x0A
        case 0x2000...0x2FFF:
            romBank = (romBank & 0x100) | Int(value)
        case 0x3000...0x3FFF:
            romBank = (romBank & 0x0FF) | (Int(value & 0x01) << 8)
        case 0x4000...0x5FFF:
            ramBank = Int(value & 0x0F)
        default:
            break
        }
    }

    override func readRAM(_ addr: UInt16) -> UInt8 {
        sramByte(bank: ramBank, offset: Int(addr - 0xA000))
    }

    override func writeRAM(_ addr: UInt16, _ value: UInt8) {
        setSRAMByte(bank: ramBank, offset: Int(addr - 0xA000), value)
    }
}
