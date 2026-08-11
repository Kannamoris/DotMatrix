import Foundation

/// Interrupt sources, in IE/IF bit order.
enum IRQSource: UInt16 {
    case vblank   = 0x0001
    case hblank   = 0x0002
    case vcount   = 0x0004
    case timer0   = 0x0008
    case timer1   = 0x0010
    case timer2   = 0x0020
    case timer3   = 0x0040
    case serial   = 0x0080
    case dma0     = 0x0100
    case dma1     = 0x0200
    case dma2     = 0x0400
    case dma3     = 0x0800
    case keypad   = 0x1000
    case gamePak  = 0x2000
}

/// IE / IF / IME.
final class InterruptController {
    /// Which sources are unmasked.
    var enable: UInt16 = 0
    /// Which sources are currently asserting. Cleared by writing 1s.
    var flags: UInt16 = 0
    /// Global enable.
    var masterEnable = false

    func request(_ source: IRQSource) {
        flags |= source.rawValue
    }

    /// Acknowledge: the CPU writes 1 bits to clear, rather than 0 to keep.
    func acknowledge(_ mask: UInt16) {
        flags &= ~mask
    }

    /// True when something is asserting and unmasked. Note this ignores IME —
    /// the CPU needs to distinguish "wake from halt" (which ignores IME) from
    /// "vector to the handler" (which does not).
    var hasPendingRequest: Bool {
        (enable & flags) != 0
    }

    var shouldVector: Bool {
        masterEnable && hasPendingRequest
    }
}

// MARK: - Timers

/// The four hardware timers.
///
/// Each counts up at one of four prescaled rates, or — in cascade mode — once
/// per overflow of the timer below it, which is how 32-bit and longer periods
/// are built out of 16-bit counters.
final class TimerUnit {
    struct Timer {
        var reload: UInt16 = 0
        var counter: UInt16 = 0
        var control: UInt16 = 0

        /// Fractional prescaler accumulator, in CPU cycles.
        var accumulated: Int = 0

        var enabled: Bool { control & 0x0080 != 0 }
        var irqEnabled: Bool { control & 0x0040 != 0 }
        var cascade: Bool { control & 0x0004 != 0 }

        var prescaler: Int {
            switch control & 0x3 {
            case 0: return 1
            case 1: return 64
            case 2: return 256
            default: return 1024
            }
        }
    }

    var timers = [Timer](repeating: Timer(), count: 4)

    /// Overflows produced by the last `step`, so the sound FIFOs can be topped
    /// up by the channels that are clocked from a timer.
    private(set) var overflowedThisStep: [Bool] = [false, false, false, false]

    private let interrupts: InterruptController

    init(interrupts: InterruptController) {
        self.interrupts = interrupts
    }

    func readCounter(_ index: Int) -> UInt16 { timers[index].counter }
    func readControl(_ index: Int) -> UInt16 { timers[index].control }

    func writeReload(_ index: Int, _ value: UInt16) {
        timers[index].reload = value
    }

    func writeControl(_ index: Int, _ value: UInt16) {
        let wasEnabled = timers[index].enabled
        timers[index].control = value
        // A disabled-to-enabled transition reloads the counter; changing other
        // bits while already running does not.
        if !wasEnabled && timers[index].enabled {
            timers[index].counter = timers[index].reload
            timers[index].accumulated = 0
        }
    }

    func step(_ cycles: Int) {
        for i in 0..<4 { overflowedThisStep[i] = false }

        for index in 0..<4 {
            guard timers[index].enabled else { continue }

            var ticks = 0
            if timers[index].cascade && index > 0 {
                // Cascade timers advance once per overflow of the one below,
                // and ignore their own prescaler entirely.
                ticks = overflowedThisStep[index - 1] ? 1 : 0
            } else {
                timers[index].accumulated += cycles
                let prescaler = timers[index].prescaler
                ticks = timers[index].accumulated / prescaler
                timers[index].accumulated %= prescaler
            }

            guard ticks > 0 else { continue }

            var remaining = ticks
            while remaining > 0 {
                let headroom = Int(UInt16.max - timers[index].counter) + 1
                if remaining >= headroom {
                    remaining -= headroom
                    timers[index].counter = timers[index].reload
                    overflowedThisStep[index] = true
                    if timers[index].irqEnabled {
                        interrupts.request(timerSource(index))
                    }
                    // A reload value of 0xFFFF would otherwise spin here.
                    if timers[index].reload == 0xFFFF && remaining > 0 {
                        remaining -= 1
                    }
                } else {
                    timers[index].counter &+= UInt16(remaining)
                    remaining = 0
                }
            }
        }
    }

    private func timerSource(_ index: Int) -> IRQSource {
        switch index {
        case 0: return .timer0
        case 1: return .timer1
        case 2: return .timer2
        default: return .timer3
        }
    }
}

// MARK: - DMA

/// When a channel is allowed to run.
enum DMATiming: UInt16 {
    case immediate = 0
    case vblank    = 1
    case hblank    = 2
    case special   = 3
}

/// The four DMA channels.
///
/// Channels 1 and 2 in `special` timing feed the sound FIFOs; channel 3 in
/// `special` is video capture. Channel 0 is wired to internal memory only, so
/// it can't be used to read the cartridge.
final class DMAController {
    struct Channel {
        var source: UInt32 = 0
        var destination: UInt32 = 0
        var wordCount: UInt16 = 0
        var control: UInt16 = 0

        /// Latched at enable time; the registers stay writable meanwhile.
        var currentSource: UInt32 = 0
        var currentDestination: UInt32 = 0
        var remaining: Int = 0
        var active = false

        var enabled: Bool { control & 0x8000 != 0 }
        var irqOnComplete: Bool { control & 0x4000 != 0 }
        var repeats: Bool { control & 0x0200 != 0 }
        var transfers32Bit: Bool { control & 0x0400 != 0 }
        var timing: DMATiming { DMATiming(rawValue: (control >> 12) & 0x3) ?? .immediate }
        var destinationControl: UInt16 { (control >> 5) & 0x3 }
        var sourceControl: UInt16 { (control >> 7) & 0x3 }
    }

    var channels = [Channel](repeating: Channel(), count: 4)

    private let interrupts: InterruptController

    init(interrupts: InterruptController) {
        self.interrupts = interrupts
    }

    /// Largest transfer each channel can express; channel 3 gets an extra bit.
    private func maximumWords(_ index: Int) -> Int {
        index == 3 ? 0x10000 : 0x4000
    }

    func writeControl(_ index: Int, _ value: UInt16) {
        let wasEnabled = channels[index].enabled
        channels[index].control = value

        if !wasEnabled && channels[index].enabled {
            latch(index)
        } else if wasEnabled && !channels[index].enabled {
            channels[index].active = false
        }
    }

    private func latch(_ index: Int) {
        var channel = channels[index]
        // Address alignment is forced by the transfer width.
        let alignment: UInt32 = channel.transfers32Bit ? ~3 : ~1
        channel.currentSource = channel.source & alignment
        channel.currentDestination = channel.destination & alignment
        channel.remaining = channel.wordCount == 0
            ? maximumWords(index)
            : Int(channel.wordCount)
        channel.active = true
        channels[index] = channel
    }

    /// Re-arm a repeating channel after it completes.
    private func rearm(_ index: Int) {
        var channel = channels[index]
        guard channel.repeats && channel.enabled else {
            channel.active = false
            // A non-repeating channel clears its own enable bit when done.
            channel.control &= ~0x8000
            channels[index] = channel
            return
        }

        channel.remaining = channel.wordCount == 0
            ? maximumWords(index)
            : Int(channel.wordCount)
        // Destination mode 3 reloads the address each repeat, which is what
        // keeps a sound FIFO or a scanline effect pointed at the same target.
        if channel.destinationControl == 3 {
            let alignment: UInt32 = channel.transfers32Bit ? ~3 : ~1
            channel.currentDestination = channel.destination & alignment
        }
        channel.active = true
        channels[index] = channel
    }

    /// Which channel should run now, if any. Lower index wins.
    func pendingChannel(for timing: DMATiming) -> Int? {
        for index in 0..<4 {
            let channel = channels[index]
            if channel.enabled && channel.active && channel.timing == timing {
                return index
            }
        }
        return nil
    }

    /// Perform a whole transfer. `transfer` moves one unit and is supplied by
    /// the bus, which owns the memory map.
    func run(_ index: Int, transfer: (UInt32, UInt32, Bool) -> Void) {
        var channel = channels[index]
        guard channel.active else { return }

        let step: UInt32 = channel.transfers32Bit ? 4 : 2

        while channel.remaining > 0 {
            transfer(channel.currentSource, channel.currentDestination, channel.transfers32Bit)

            switch channel.sourceControl {
            case 0: channel.currentSource = channel.currentSource &+ step
            case 1: channel.currentSource = channel.currentSource &- step
            default: break   // 2 = fixed, 3 = prohibited on the source side
            }

            switch channel.destinationControl {
            case 0, 3: channel.currentDestination = channel.currentDestination &+ step
            case 1:    channel.currentDestination = channel.currentDestination &- step
            default:   break   // fixed — how the sound FIFOs are fed
            }

            channel.remaining -= 1
        }

        channels[index] = channel

        if channel.irqOnComplete {
            interrupts.request(dmaSource(index))
        }
        rearm(index)
    }

    /// Sound FIFO transfers are fixed at four 32-bit words to a fixed address.
    func runSoundFIFO(_ index: Int, transfer: (UInt32, UInt32, Bool) -> Void) {
        var channel = channels[index]
        guard channel.active else { return }

        for _ in 0..<4 {
            transfer(channel.currentSource, channel.destination, true)
            switch channel.sourceControl {
            case 0: channel.currentSource = channel.currentSource &+ 4
            case 1: channel.currentSource = channel.currentSource &- 4
            default: break
            }
        }

        channels[index] = channel

        if channel.irqOnComplete {
            interrupts.request(dmaSource(index))
        }
    }

    private func dmaSource(_ index: Int) -> IRQSource {
        switch index {
        case 0: return .dma0
        case 1: return .dma1
        case 2: return .dma2
        default: return .dma3
        }
    }
}
