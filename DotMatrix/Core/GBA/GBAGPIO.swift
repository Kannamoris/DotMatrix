import Foundation

/// The cartridge's GPIO port and the real-time clock behind it.
///
/// Three registers sit in the ROM address space at 0x0C4, 0x0C6 and 0x0C8.
/// They are only live when the control register enables them; otherwise reads
/// of those addresses must return ordinary cartridge data, which is what a
/// cartridge without a GPIO chip does.
///
/// Emerald's clock is a Seiko S-3511A, driven as a three-wire serial device:
/// the game bit-bangs a command byte and then shifts a BCD payload in or out.
final class CartridgeGPIO {
    // Register offsets within the ROM region.
    static let dataRegister: UInt32 = 0xC4
    static let directionRegister: UInt32 = 0xC6
    static let controlRegister: UInt32 = 0xC8

    /// Pin assignments for the clock.
    private enum Pin {
        static let clock: UInt16 = 1 << 0   // SCK
        static let data: UInt16 = 1 << 1    // SIO
        static let select: UInt16 = 1 << 2  // CS
    }

    /// What the game last drove onto the pins.
    private var writtenData: UInt16 = 0
    /// Per-pin direction: a set bit means the game drives that pin.
    private var direction: UInt16 = 0
    /// Control bit 0 exposes the port to reads. While clear, the addresses
    /// read back as ROM.
    private(set) var readable = false

    private let rtc = RealTimeClock()

    // MARK: Register access

    func read(_ register: UInt32) -> UInt16 {
        switch register {
        case Self.dataRegister:
            // Pins the game drives read back what it wrote; the rest are
            // driven by the clock.
            let fromGame = writtenData & direction
            let fromDevice = rtc.pinOutput & ~direction
            return (fromGame | fromDevice) & 0x000F
        case Self.directionRegister:
            return direction & 0x000F
        case Self.controlRegister:
            return readable ? 1 : 0
        default:
            return 0
        }
    }

    func write(_ register: UInt32, _ value: UInt16) {
        switch register {
        case Self.dataRegister:
            writtenData = value & 0x000F
            rtc.update(pins: writtenData, direction: direction)
        case Self.directionRegister:
            direction = value & 0x000F
            rtc.update(pins: writtenData, direction: direction)
        case Self.controlRegister:
            readable = value & 1 != 0
        default:
            break
        }
    }

    // MARK: Persistence

    /// The clock's drift from host time, so the game's sense of time survives
    /// the app being closed rather than restarting from the host clock.
    var saveState: [String: Int] { rtc.saveState }
    func restore(_ state: [String: Int]) { rtc.restore(state) }
}

/// Seiko S-3511A.
///
/// A command byte selects a register and a direction; a fixed-length payload
/// follows, packed as BCD. Everything is clocked by the game toggling SCK, so
/// the model is edge-driven rather than sampled: what matters is the 0→1
/// transition, not how often the emulator happens to look.
private final class RealTimeClock {
    private enum Command: Int {
        case reset = 0
        case status = 1
        case dateTime = 2
        case time = 3
        case alarm = 4
        case forceIRQ = 6

        /// Payload length in bytes.
        var byteCount: Int {
            switch self {
            case .reset, .forceIRQ: return 0
            case .status: return 1
            case .time: return 3
            case .dateTime: return 7
            case .alarm: return 2
            }
        }
    }

    private enum Phase {
        case idle
        case receivingCommand
        case transferring
    }

    private var phase: Phase = .idle
    private var lastClock: UInt16 = 0

    private var shiftRegister: UInt16 = 0
    private var bitsTransferred = 0
    private var byteIndex = 0

    private var command: Command = .reset
    private var isReading = false
    private var payload = [UInt8](repeating: 0, count: 7)

    /// Bit 6 marks 24-hour mode. The power-failure bit stays clear — setting it
    /// is what makes a game report a dead cartridge battery.
    private var status: UInt8 = 0x40

    /// Seconds of offset applied to host time.
    private var offset: TimeInterval = 0

    /// Current level the chip drives onto SIO, if anything.
    private(set) var pinOutput: UInt16 = 0

    // MARK: Pin handling

    func update(pins: UInt16, direction: UInt16) {
        let selected = pins & Pin.select != 0
        let clock = pins & Pin.clock

        guard selected else {
            // Deselecting abandons whatever was in flight.
            phase = .idle
            bitsTransferred = 0
            byteIndex = 0
            shiftRegister = 0
            lastClock = clock
            return
        }

        if phase == .idle {
            phase = .receivingCommand
            bitsTransferred = 0
            shiftRegister = 0
        }

        // Act on the rising edge only.
        let rising = lastClock == 0 && clock != 0
        lastClock = clock
        guard rising else { return }

        switch phase {
        case .idle:
            break

        case .receivingCommand:
            let bit = (pins & Pin.data) != 0 ? 1 : 0
            shiftRegister = (shiftRegister << 1) | UInt16(bit)
            bitsTransferred += 1
            if bitsTransferred == 8 {
                decodeCommand(UInt8(shiftRegister & 0xFF))
            }

        case .transferring:
            if isReading {
                // The bit for this position was already presented; step on.
                advanceReadBit()
            } else {
                let bit = (pins & Pin.data) != 0 ? 1 : 0
                // Payload arrives least-significant bit first.
                payload[byteIndex] |= UInt8(bit << bitsTransferred)
                bitsTransferred += 1
                if bitsTransferred == 8 {
                    bitsTransferred = 0
                    byteIndex += 1
                    if byteIndex >= command.byteCount {
                        applyWrite()
                        phase = .idle
                    }
                }
            }
        }
    }

    private enum Pin {
        static let clock: UInt16 = 1 << 0
        static let data: UInt16 = 1 << 1
        static let select: UInt16 = 1 << 2
    }

    // MARK: Command handling

    private func decodeCommand(_ raw: UInt8) {
        // The identifying nibble is 0110. If it turns up in the low half the
        // byte arrived least-significant bit first, so flip it.
        var byte = raw
        if byte & 0x0F == 0x06 {
            byte = reverseBits(byte)
        }

        isReading = byte & 0x01 != 0
        let code = Int((byte >> 1) & 0x07)
        command = Command(rawValue: code) ?? .reset

        bitsTransferred = 0
        byteIndex = 0

        switch command {
        case .reset:
            offset = 0
            status = 0x40
            phase = .idle
        case .forceIRQ:
            phase = .idle
        default:
            if isReading {
                loadPayload()
                phase = .transferring
                presentReadBit()
            } else {
                for i in payload.indices { payload[i] = 0 }
                phase = .transferring
            }
        }
    }

    private func reverseBits(_ value: UInt8) -> UInt8 {
        var input = value
        var output: UInt8 = 0
        for _ in 0..<8 {
            output = (output << 1) | (input & 1)
            input >>= 1
        }
        return output
    }

    // MARK: Reading

    private func loadPayload() {
        let now = Date().addingTimeInterval(offset)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .weekday], from: now)

        switch command {
        case .status:
            payload[0] = status

        case .time:
            payload[0] = bcd(parts.hour ?? 0)
            payload[1] = bcd(parts.minute ?? 0)
            payload[2] = bcd(parts.second ?? 0)

        case .dateTime:
            // The chip holds a two-digit year; the game supplies its own epoch.
            payload[0] = bcd((parts.year ?? 2000) % 100)
            payload[1] = bcd(parts.month ?? 1)
            payload[2] = bcd(parts.day ?? 1)
            // Calendar numbers Sunday as 1; the chip counts from zero.
            payload[3] = bcd(((parts.weekday ?? 1) - 1) % 7)
            payload[4] = bcd(parts.hour ?? 0)
            payload[5] = bcd(parts.minute ?? 0)
            payload[6] = bcd(parts.second ?? 0)

        default:
            for i in payload.indices { payload[i] = 0 }
        }
    }

    private func presentReadBit() {
        guard byteIndex < payload.count else { pinOutput = 0; return }
        let bit = (payload[byteIndex] >> UInt8(bitsTransferred)) & 1
        pinOutput = bit != 0 ? Pin.data : 0
    }

    private func advanceReadBit() {
        bitsTransferred += 1
        if bitsTransferred == 8 {
            bitsTransferred = 0
            byteIndex += 1
            if byteIndex >= command.byteCount {
                phase = .idle
                pinOutput = 0
                return
            }
        }
        presentReadBit()
    }

    // MARK: Writing

    private func applyWrite() {
        switch command {
        case .status:
            // Keep the power-failure bit clear whatever the game writes, so a
            // save that has seen a real dead battery isn't re-flagged here.
            status = (payload[0] & 0x7F) | 0x40

        case .dateTime, .time:
            var parts = DateComponents()
            let now = Date()
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone.current
            let current = calendar.dateComponents([.year, .month, .day], from: now)

            if command == .dateTime {
                let year = 2000 + Int(fromBCD(payload[0]))
                parts.year = year
                parts.month = Int(fromBCD(payload[1]))
                parts.day = Int(fromBCD(payload[2]))
                parts.hour = Int(fromBCD(payload[4] & 0x7F))
                parts.minute = Int(fromBCD(payload[5]))
                parts.second = Int(fromBCD(payload[6]))
            } else {
                parts.year = current.year
                parts.month = current.month
                parts.day = current.day
                parts.hour = Int(fromBCD(payload[0] & 0x7F))
                parts.minute = Int(fromBCD(payload[1]))
                parts.second = Int(fromBCD(payload[2]))
            }

            if let target = calendar.date(from: parts) {
                // Store the difference rather than a absolute time, so the
                // clock keeps advancing with the host afterwards.
                offset = target.timeIntervalSince(now)
            }

        default:
            break
        }
    }

    private func bcd(_ value: Int) -> UInt8 {
        let clamped = max(0, min(99, value))
        return UInt8((clamped / 10) << 4 | (clamped % 10))
    }

    private func fromBCD(_ value: UInt8) -> Int {
        Int((value >> 4) & 0x0F) * 10 + Int(value & 0x0F)
    }

    // MARK: Persistence

    var saveState: [String: Int] {
        ["rtcOffset": Int(offset), "rtcStatus": Int(status)]
    }

    func restore(_ state: [String: Int]) {
        if let stored = state["rtcOffset"] { offset = TimeInterval(stored) }
        if let stored = state["rtcStatus"] { status = UInt8(truncatingIfNeeded: stored) }
    }
}
