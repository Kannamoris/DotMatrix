import Foundation
import os

/// The four-channel sound hardware.
///
/// Each channel runs its own frequency timer at the 4.19 MHz master clock; a
/// 512 Hz "frame sequencer" clocks the length counters, envelopes and sweep on
/// top of that. Output is mixed and resampled down to the host sample rate with
/// a running average, which is a cheap but effective low-pass — the raw signal
/// aliases badly otherwise.
final class APU {
    static let masterClock = 4_194_304.0

    private let sampleRate: Double
    private let cyclesPerSample: Double
    private var sampleAccumulator = 0.0

    // Running average between output samples.
    private var mixAccumulatorL = 0.0
    private var mixAccumulatorR = 0.0
    private var mixCount = 0

    private var frameSequencerCounter = 0
    private var frameSequencerStep = 0

    private var enabled = false
    private var leftVolume = 7
    private var rightVolume = 7
    private var panning: UInt8 = 0xF3

    private let square1 = SquareChannel(hasSweep: true)
    private let square2 = SquareChannel(hasSweep: false)
    private let wave = WaveChannel()
    private let noise = NoiseChannel()

    /// Interleaved stereo output waiting to be consumed by the audio device.
    ///
    /// The producer is the emulation thread and the consumer is the realtime
    /// audio render callback, so this uses `os_unfair_lock` rather than
    /// `NSLock` — the critical sections are a handful of instructions and the
    /// audio thread must not block on a lock that can be held across a syscall.
    private var ring: [Float]
    private var writeIndex = 0
    private var readIndex = 0
    private let ringCapacity: Int
    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)

    /// High-pass state, mirroring the DC blocking capacitor on real hardware.
    private var capacitorL: Double = 0
    private var capacitorR: Double = 0
    private let capacitorDecay: Double

    init(sampleRate: Double = 48000) {
        self.sampleRate = sampleRate
        self.cyclesPerSample = Self.masterClock / sampleRate
        // Two seconds of slack; the consumer normally stays far ahead of this.
        self.ringCapacity = Int(sampleRate) * 2 * 2
        self.ring = [Float](repeating: 0, count: ringCapacity)
        self.capacitorDecay = pow(0.999958, Self.masterClock / sampleRate)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    // MARK: Clocking

    func tick(_ cycles: Int) {
        for _ in 0..<cycles {
            square1.tickTimer()
            square2.tickTimer()
            wave.tickTimer()
            noise.tickTimer()

            frameSequencerCounter += 1
            if frameSequencerCounter >= 8192 {
                frameSequencerCounter = 0
                clockFrameSequencer()
            }

            accumulateSample()
        }
    }

    private func clockFrameSequencer() {
        // 0 L - - -  1 - - - -  2 L S - -  3 - - - -
        // 4 L - - -  5 - - - -  6 L S - -  7 - - - E
        switch frameSequencerStep {
        case 0, 4:
            clockLengths()
        case 2, 6:
            clockLengths()
            square1.clockSweep()
        case 7:
            square1.clockEnvelope()
            square2.clockEnvelope()
            noise.clockEnvelope()
        default:
            break
        }
        frameSequencerStep = (frameSequencerStep + 1) & 7
    }

    private func clockLengths() {
        square1.clockLength()
        square2.clockLength()
        wave.clockLength()
        noise.clockLength()
    }

    private func accumulateSample() {
        guard enabled else {
            mixCount += 1
            advanceSampleClock(left: 0, right: 0)
            return
        }

        let outputs = [square1.output(), square2.output(), wave.output(), noise.output()]

        var left = 0.0
        var right = 0.0
        for (i, value) in outputs.enumerated() {
            // NR51: low nibble routes to the right, high nibble to the left.
            if panning & (1 << UInt8(i)) != 0 { right += value }
            if panning & (1 << UInt8(i + 4)) != 0 { left += value }
        }

        // Four channels at unit amplitude, scaled by the 3-bit master volume.
        left = left / 4.0 * (Double(leftVolume) + 1) / 8.0
        right = right / 4.0 * (Double(rightVolume) + 1) / 8.0

        advanceSampleClock(left: left, right: right)
    }

    private func advanceSampleClock(left: Double, right: Double) {
        mixAccumulatorL += left
        mixAccumulatorR += right
        mixCount += 1

        sampleAccumulator += 1
        guard sampleAccumulator >= cyclesPerSample else { return }
        sampleAccumulator -= cyclesPerSample

        let n = Double(max(1, mixCount))
        var l = mixAccumulatorL / n
        var r = mixAccumulatorR / n
        mixAccumulatorL = 0
        mixAccumulatorR = 0
        mixCount = 0

        // Remove the DC offset the channels sit on when they are merely enabled.
        let outL = l - capacitorL
        let outR = r - capacitorR
        capacitorL = l - outL * capacitorDecay
        capacitorR = r - outR * capacitorDecay
        l = outL
        r = outR

        push(Float(max(-1.0, min(1.0, l))), Float(max(-1.0, min(1.0, r))))
    }

    // MARK: Ring buffer

    private func push(_ l: Float, _ r: Float) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let next = (writeIndex + 2) % ringCapacity
        // Drop the newest frame rather than overrun the reader; this only
        // happens if audio output has stalled entirely.
        guard next != readIndex else { return }
        ring[writeIndex] = l
        ring[writeIndex + 1] = r
        writeIndex = next
    }

    /// Number of complete stereo frames available.
    var availableFrames: Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let diff = writeIndex - readIndex
        return (diff >= 0 ? diff : diff + ringCapacity) / 2
    }

    /// Drain up to `frameCount` stereo frames into `left`/`right`.
    /// Returns how many were actually written; the caller should zero the rest.
    @discardableResult
    func read(into left: UnsafeMutablePointer<Float>,
              _ right: UnsafeMutablePointer<Float>,
              frameCount: Int) -> Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        var written = 0
        while written < frameCount && readIndex != writeIndex {
            left[written] = ring[readIndex]
            right[written] = ring[readIndex + 1]
            readIndex = (readIndex + 2) % ringCapacity
            written += 1
        }
        return written
    }

    func clearBuffer() {
        os_unfair_lock_lock(lock)
        readIndex = writeIndex
        os_unfair_lock_unlock(lock)
    }

    // MARK: Register file

    func read(_ addr: UInt16) -> UInt8 {
        switch addr {
        case 0xFF10...0xFF14: return square1.read(addr - 0xFF10)
        case 0xFF15...0xFF19: return square2.read(addr - 0xFF15)
        case 0xFF1A...0xFF1E: return wave.read(addr - 0xFF1A)
        case 0xFF1F...0xFF23: return noise.read(addr - 0xFF1F)
        case 0xFF24:
            return UInt8(leftVolume << 4 | rightVolume)
        case 0xFF25:
            return panning
        case 0xFF26:
            var v: UInt8 = enabled ? 0x80 : 0x00
            v |= 0x70   // unused bits read high
            if square1.isActive { v |= 0x01 }
            if square2.isActive { v |= 0x02 }
            if wave.isActive { v |= 0x04 }
            if noise.isActive { v |= 0x08 }
            return v
        case 0xFF30...0xFF3F:
            return wave.readRAM(Int(addr - 0xFF30))
        default:
            return 0xFF
        }
    }

    func write(_ addr: UInt16, _ value: UInt8) {
        // While powered off every register except NR52 and wave RAM is inert.
        if !enabled && addr != 0xFF26 && !(0xFF30...0xFF3F).contains(addr) {
            return
        }

        switch addr {
        case 0xFF10...0xFF14: square1.write(addr - 0xFF10, value)
        case 0xFF15...0xFF19: square2.write(addr - 0xFF15, value)
        case 0xFF1A...0xFF1E: wave.write(addr - 0xFF1A, value)
        case 0xFF1F...0xFF23: noise.write(addr - 0xFF1F, value)
        case 0xFF24:
            leftVolume = Int((value >> 4) & 0x07)
            rightVolume = Int(value & 0x07)
        case 0xFF25:
            panning = value
        case 0xFF26:
            let nowEnabled = value & 0x80 != 0
            if !nowEnabled && enabled {
                // Powering down clears every register and silences everything.
                square1.reset()
                square2.reset()
                wave.reset()
                noise.reset()
                leftVolume = 0
                rightVolume = 0
                panning = 0
                frameSequencerStep = 0
            }
            enabled = nowEnabled
        case 0xFF30...0xFF3F:
            wave.writeRAM(Int(addr - 0xFF30), value)
        default:
            break
        }
    }
}

// MARK: - Envelope

/// The volume envelope shared by the two square channels and the noise channel.
private struct Envelope {
    var initialVolume = 0
    var increasing = false
    var period = 0

    var volume = 0
    var timer = 0

    mutating func trigger() {
        volume = initialVolume
        timer = period == 0 ? 8 : period
    }

    mutating func clock() {
        guard period > 0 else { return }
        timer -= 1
        guard timer <= 0 else { return }
        timer = period
        if increasing && volume < 15 {
            volume += 1
        } else if !increasing && volume > 0 {
            volume -= 1
        }
    }

    /// The DAC is off when the envelope would produce silence with no way back.
    var dacEnabled: Bool { initialVolume > 0 || increasing }
}

// MARK: - Square

private final class SquareChannel {
    private static let dutyTable: [[Double]] = [
        [-1, -1, -1, -1, -1, -1, -1,  1],   // 12.5%
        [ 1, -1, -1, -1, -1, -1, -1,  1],   // 25%
        [ 1, -1, -1, -1, -1,  1,  1,  1],   // 50%
        [-1,  1,  1,  1,  1,  1,  1, -1],   // 75%
    ]

    private let hasSweep: Bool

    private var duty = 2
    private var dutyStep = 0
    private var frequency = 0
    private var timer = 0

    private var envelope = Envelope()
    private var lengthCounter = 0
    private var lengthEnabled = false

    private var sweepPeriod = 0
    private var sweepNegate = false
    private var sweepShift = 0
    private var sweepTimer = 0
    private var sweepShadow = 0
    private var sweepActive = false
    /// Set once a negate-mode calculation has run; clearing negate afterwards
    /// disables the channel on real hardware.
    private var sweepDidNegate = false

    private(set) var isActive = false

    init(hasSweep: Bool) {
        self.hasSweep = hasSweep
    }

    func tickTimer() {
        timer -= 1
        guard timer <= 0 else { return }
        timer = (2048 - frequency) * 4
        dutyStep = (dutyStep + 1) & 7
    }

    func output() -> Double {
        guard isActive, envelope.dacEnabled else { return 0 }
        return Self.dutyTable[duty][dutyStep] * Double(envelope.volume) / 15.0
    }

    func clockLength() {
        guard lengthEnabled, lengthCounter > 0 else { return }
        lengthCounter -= 1
        if lengthCounter == 0 { isActive = false }
    }

    func clockEnvelope() {
        envelope.clock()
    }

    func clockSweep() {
        guard hasSweep, sweepActive else { return }
        sweepTimer -= 1
        guard sweepTimer <= 0 else { return }
        sweepTimer = sweepPeriod == 0 ? 8 : sweepPeriod
        guard sweepPeriod != 0 else { return }

        let newFreq = calculateSweep()
        if newFreq <= 2047 && sweepShift > 0 {
            sweepShadow = newFreq
            frequency = newFreq
            // The overflow check runs a second time, and can still disable us.
            _ = calculateSweep()
        }
    }

    private func calculateSweep() -> Int {
        var new = sweepShadow >> sweepShift
        if sweepNegate {
            new = sweepShadow - new
            sweepDidNegate = true
        } else {
            new = sweepShadow + new
        }
        if new > 2047 {
            isActive = false
        }
        return new
    }

    func read(_ reg: UInt16) -> UInt8 {
        switch reg {
        case 0:
            guard hasSweep else { return 0xFF }
            return UInt8(0x80 | (sweepPeriod << 4) | (sweepNegate ? 0x08 : 0) | sweepShift)
        case 1:
            return UInt8(duty << 6) | 0x3F
        case 2:
            return UInt8(envelope.initialVolume << 4)
                 | (envelope.increasing ? 0x08 : 0)
                 | UInt8(envelope.period)
        case 3:
            return 0xFF
        default:
            return (lengthEnabled ? 0x40 : 0) | 0xBF
        }
    }

    func write(_ reg: UInt16, _ value: UInt8) {
        switch reg {
        case 0:
            guard hasSweep else { return }
            sweepPeriod = Int((value >> 4) & 0x07)
            let negate = value & 0x08 != 0
            if sweepDidNegate && !negate { isActive = false }
            sweepNegate = negate
            sweepShift = Int(value & 0x07)
        case 1:
            duty = Int((value >> 6) & 0x03)
            lengthCounter = 64 - Int(value & 0x3F)
        case 2:
            envelope.initialVolume = Int((value >> 4) & 0x0F)
            envelope.increasing = value & 0x08 != 0
            envelope.period = Int(value & 0x07)
            if !envelope.dacEnabled { isActive = false }
        case 3:
            frequency = (frequency & 0x700) | Int(value)
        default:
            frequency = (frequency & 0x0FF) | (Int(value & 0x07) << 8)
            lengthEnabled = value & 0x40 != 0
            if value & 0x80 != 0 { trigger() }
        }
    }

    private func trigger() {
        isActive = envelope.dacEnabled
        if lengthCounter == 0 { lengthCounter = 64 }
        timer = (2048 - frequency) * 4
        envelope.trigger()

        if hasSweep {
            sweepShadow = frequency
            sweepTimer = sweepPeriod == 0 ? 8 : sweepPeriod
            sweepActive = sweepPeriod > 0 || sweepShift > 0
            sweepDidNegate = false
            // A non-zero shift performs the overflow check immediately.
            if sweepShift > 0 { _ = calculateSweep() }
        }
    }

    func reset() {
        duty = 0; dutyStep = 0; frequency = 0; timer = 0
        envelope = Envelope()
        lengthCounter = 0; lengthEnabled = false
        sweepPeriod = 0; sweepNegate = false; sweepShift = 0
        sweepTimer = 0; sweepShadow = 0; sweepActive = false; sweepDidNegate = false
        isActive = false
    }
}

// MARK: - Wave

private final class WaveChannel {
    private var dacOn = false
    private var frequency = 0
    private var timer = 0
    private var position = 0
    private var volumeShift = 0
    private var lengthCounter = 0
    private var lengthEnabled = false
    private var sampleBuffer: UInt8 = 0

    private var waveRAM = [UInt8](repeating: 0, count: 16)

    private(set) var isActive = false

    func tickTimer() {
        timer -= 1
        guard timer <= 0 else { return }
        // The wave channel steps at twice the rate of the square channels.
        timer = (2048 - frequency) * 2
        position = (position + 1) & 31
        let byte = waveRAM[position >> 1]
        sampleBuffer = position & 1 == 0 ? (byte >> 4) : (byte & 0x0F)
    }

    func output() -> Double {
        guard isActive, dacOn else { return 0 }
        // Shift 0 means mute; 1/2/3 are full, half and quarter volume.
        let level: Int
        switch volumeShift {
        case 0: return 0
        case 1: level = Int(sampleBuffer)
        case 2: level = Int(sampleBuffer) >> 1
        default: level = Int(sampleBuffer) >> 2
        }
        // Map the unsigned 4-bit sample onto a signed swing.
        return (Double(level) / 7.5) - 1.0
    }

    func clockLength() {
        guard lengthEnabled, lengthCounter > 0 else { return }
        lengthCounter -= 1
        if lengthCounter == 0 { isActive = false }
    }

    func read(_ reg: UInt16) -> UInt8 {
        switch reg {
        case 0: return (dacOn ? 0x80 : 0) | 0x7F
        case 1: return 0xFF
        case 2: return UInt8(volumeShift << 5) | 0x9F
        case 3: return 0xFF
        default: return (lengthEnabled ? 0x40 : 0) | 0xBF
        }
    }

    func write(_ reg: UInt16, _ value: UInt8) {
        switch reg {
        case 0:
            dacOn = value & 0x80 != 0
            if !dacOn { isActive = false }
        case 1:
            lengthCounter = 256 - Int(value)
        case 2:
            volumeShift = Int((value >> 5) & 0x03)
        case 3:
            frequency = (frequency & 0x700) | Int(value)
        default:
            frequency = (frequency & 0x0FF) | (Int(value & 0x07) << 8)
            lengthEnabled = value & 0x40 != 0
            if value & 0x80 != 0 { trigger() }
        }
    }

    private func trigger() {
        isActive = dacOn
        if lengthCounter == 0 { lengthCounter = 256 }
        timer = (2048 - frequency) * 2
        position = 0
    }

    func readRAM(_ index: Int) -> UInt8 { waveRAM[index] }
    func writeRAM(_ index: Int, _ value: UInt8) { waveRAM[index] = value }

    func reset() {
        dacOn = false; frequency = 0; timer = 0; position = 0
        volumeShift = 0; lengthCounter = 0; lengthEnabled = false
        sampleBuffer = 0; isActive = false
    }
}

// MARK: - Noise

private final class NoiseChannel {
    private static let divisors = [8, 16, 32, 48, 64, 80, 96, 112]

    private var envelope = Envelope()
    private var lengthCounter = 0
    private var lengthEnabled = false

    private var clockShift = 0
    private var widthMode7Bit = false
    private var divisorCode = 0
    private var timer = 0
    private var lfsr: UInt16 = 0x7FFF

    private(set) var isActive = false

    func tickTimer() {
        timer -= 1
        guard timer <= 0 else { return }
        timer = Self.divisors[divisorCode] << clockShift

        // XOR the bottom two bits, shift right, feed the result into bit 14.
        let feedback = (lfsr & 1) ^ ((lfsr >> 1) & 1)
        lfsr >>= 1
        lfsr |= feedback << 14
        if widthMode7Bit {
            // Width mode also feeds bit 6, giving a shorter, buzzier period.
            lfsr = (lfsr & ~0x40) | (feedback << 6)
        }
    }

    func output() -> Double {
        guard isActive, envelope.dacEnabled else { return 0 }
        // Output is inverted bit 0.
        let bit = (lfsr & 1) == 0 ? 1.0 : -1.0
        return bit * Double(envelope.volume) / 15.0
    }

    func clockLength() {
        guard lengthEnabled, lengthCounter > 0 else { return }
        lengthCounter -= 1
        if lengthCounter == 0 { isActive = false }
    }

    func clockEnvelope() { envelope.clock() }

    func read(_ reg: UInt16) -> UInt8 {
        switch reg {
        case 0, 1: return 0xFF
        case 2:
            return UInt8(envelope.initialVolume << 4)
                 | (envelope.increasing ? 0x08 : 0)
                 | UInt8(envelope.period)
        case 3:
            return UInt8(clockShift << 4) | (widthMode7Bit ? 0x08 : 0) | UInt8(divisorCode)
        default:
            return (lengthEnabled ? 0x40 : 0) | 0xBF
        }
    }

    func write(_ reg: UInt16, _ value: UInt8) {
        switch reg {
        case 1:
            lengthCounter = 64 - Int(value & 0x3F)
        case 2:
            envelope.initialVolume = Int((value >> 4) & 0x0F)
            envelope.increasing = value & 0x08 != 0
            envelope.period = Int(value & 0x07)
            if !envelope.dacEnabled { isActive = false }
        case 3:
            clockShift = Int((value >> 4) & 0x0F)
            widthMode7Bit = value & 0x08 != 0
            divisorCode = Int(value & 0x07)
        case 4:
            lengthEnabled = value & 0x40 != 0
            if value & 0x80 != 0 { trigger() }
        default:
            break
        }
    }

    private func trigger() {
        isActive = envelope.dacEnabled
        if lengthCounter == 0 { lengthCounter = 64 }
        timer = Self.divisors[divisorCode] << clockShift
        lfsr = 0x7FFF
        envelope.trigger()
    }

    func reset() {
        envelope = Envelope()
        lengthCounter = 0; lengthEnabled = false
        clockShift = 0; widthMode7Bit = false; divisorCode = 0
        timer = 0; lfsr = 0x7FFF; isActive = false
    }
}
