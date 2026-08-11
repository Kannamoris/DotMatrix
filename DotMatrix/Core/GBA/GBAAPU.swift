import Foundation
import os

/// GBA sound.
///
/// Two distinct systems share the output stage: the four PSG channels carried
/// over from the Game Boy, and the two "Direct Sound" channels, which are just
/// 8-bit PCM FIFOs drained by a hardware timer and refilled by DMA. Games do
/// their own software mixing into a buffer and stream it through Direct Sound,
/// so that path carries essentially all the music.
final class GBAAPU {
    static let masterClock = 16_777_216.0

    private let sampleRate: Double
    private let cyclesPerSample: Double
    private var sampleAccumulator = 0.0

    // MARK: Registers

    private var psgControl: UInt16 = 0      // SOUNDCNT_L
    private var mixControl: UInt16 = 0      // SOUNDCNT_H
    private var masterEnable = false        // SOUNDCNT_X
    private var soundBias: UInt16 = 0x0200

    // MARK: PSG channels

    private let square1 = GBASquareChannel(hasSweep: true)
    private let square2 = GBASquareChannel(hasSweep: false)
    private let wave = GBAWaveChannel()
    private let noise = GBANoiseChannel()

    private var frameSequencerCounter = 0
    private var frameSequencerStep = 0

    // MARK: Direct Sound

    /// Each FIFO is 32 bytes of signed 8-bit PCM.
    private var fifoA = FIFO()
    private var fifoB = FIFO()
    private var currentSampleA: Int8 = 0
    private var currentSampleB: Int8 = 0

    // MARK: Output ring

    private var ring: [Float]
    private var writeIndex = 0
    private var readIndex = 0
    private let ringCapacity: Int
    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)

    private var capacitorL: Double = 0
    private var capacitorR: Double = 0
    private let capacitorDecay: Double

    init(sampleRate: Double = 48000) {
        self.sampleRate = sampleRate
        self.cyclesPerSample = Self.masterClock / sampleRate
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

    func step(_ cycles: Int) {
        for _ in 0..<cycles {
            // The PSG channels run off the original 4.19 MHz clock, which is
            // the GBA master clock divided by four.
            psgSubCycle += 1
            if psgSubCycle >= 4 {
                psgSubCycle = 0
                square1.tickTimer()
                square2.tickTimer()
                wave.tickTimer()
                noise.tickTimer()

                frameSequencerCounter += 1
                if frameSequencerCounter >= 8192 {
                    frameSequencerCounter = 0
                    clockFrameSequencer()
                }
            }

            sampleAccumulator += 1
            if sampleAccumulator >= cyclesPerSample {
                sampleAccumulator -= cyclesPerSample
                emitSample()
            }
        }
    }

    private var psgSubCycle = 0

    private func clockFrameSequencer() {
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

    // MARK: Direct Sound plumbing

    /// A timer overflowed. Advance whichever FIFOs are clocked from it, and ask
    /// for a DMA refill when one runs low.
    func timerOverflow(_ timer: Int, requestRefill: () -> Void) {
        var needsRefill = false

        if directSoundTimer(forA: true) == timer {
            currentSampleA = fifoA.pop() ?? 0
            if fifoA.count <= 16 { needsRefill = true }
        }
        if directSoundTimer(forA: false) == timer {
            currentSampleB = fifoB.pop() ?? 0
            if fifoB.count <= 16 { needsRefill = true }
        }

        if needsRefill { requestRefill() }
    }

    private func directSoundTimer(forA: Bool) -> Int {
        // SOUNDCNT_H bit 10 selects channel A's timer, bit 14 channel B's.
        let bit: UInt16 = forA ? 0x0400 : 0x4000
        return mixControl & bit != 0 ? 1 : 0
    }

    func fifoWantsRefill(a isA: Bool, drivenBy timer: Int) -> Bool {
        guard directSoundTimer(forA: isA) == timer else { return false }
        return (isA ? fifoA.count : fifoB.count) <= 16
    }

    /// DMA delivers four bytes at a time.
    func pushFIFO(_ word: UInt32, toA: Bool) {
        for shift in stride(from: 0, through: 24, by: 8) {
            let byte = Int8(bitPattern: UInt8((word >> UInt32(shift)) & 0xFF))
            if toA { fifoA.push(byte) } else { fifoB.push(byte) }
        }
    }

    // MARK: Mixing

    private func emitSample() {
        guard masterEnable else {
            push(0, 0)
            return
        }

        // PSG output, scaled by the master volume in SOUNDCNT_L.
        var psgLeft = 0.0
        var psgRight = 0.0

        let outputs = [square1.output(), square2.output(), wave.output(), noise.output()]
        for (index, value) in outputs.enumerated() {
            if psgControl & (0x0100 << UInt16(index)) != 0 { psgRight += value }
            if psgControl & (0x1000 << UInt16(index)) != 0 { psgLeft += value }
        }

        let leftVolume = Double((psgControl >> 4) & 0x7) + 1
        let rightVolume = Double(psgControl & 0x7) + 1
        psgLeft = psgLeft / 4.0 * leftVolume / 8.0
        psgRight = psgRight / 4.0 * rightVolume / 8.0

        // SOUNDCNT_H bits 0-1 attenuate the PSG mix against Direct Sound.
        let psgScale: Double
        switch mixControl & 0x3 {
        case 0: psgScale = 0.25
        case 1: psgScale = 0.5
        default: psgScale = 1.0
        }
        psgLeft *= psgScale
        psgRight *= psgScale

        // Direct Sound is signed 8-bit, at either half or full volume.
        let volumeA = mixControl & 0x0004 != 0 ? 1.0 : 0.5
        let volumeB = mixControl & 0x0008 != 0 ? 1.0 : 0.5
        let sampleA = Double(currentSampleA) / 128.0 * volumeA
        let sampleB = Double(currentSampleB) / 128.0 * volumeB

        var left = psgLeft
        var right = psgRight
        if mixControl & 0x0200 != 0 { left += sampleA }
        if mixControl & 0x0100 != 0 { right += sampleA }
        if mixControl & 0x2000 != 0 { left += sampleB }
        if mixControl & 0x1000 != 0 { right += sampleB }

        // Direct Sound can contribute two full-scale channels on top of the
        // PSG mix, so scale back to keep headroom.
        left *= 0.4
        right *= 0.4

        // Block the DC offset the mixer sits on.
        let outL = left - capacitorL
        let outR = right - capacitorR
        capacitorL = left - outL * capacitorDecay
        capacitorR = right - outR * capacitorDecay

        push(Float(max(-1.0, min(1.0, outL))), Float(max(-1.0, min(1.0, outR))))
    }

    // MARK: Ring buffer

    private func push(_ l: Float, _ r: Float) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let next = (writeIndex + 2) % ringCapacity
        guard next != readIndex else { return }
        ring[writeIndex] = l
        ring[writeIndex + 1] = r
        writeIndex = next
    }

    var availableFrames: Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let diff = writeIndex - readIndex
        return (diff >= 0 ? diff : diff + ringCapacity) / 2
    }

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

    func readRegister(_ register: UInt32) -> UInt16 {
        switch register {
        case 0x060: return UInt16(square1.read(0))
        case 0x062: return UInt16(square1.read(1)) | (UInt16(square1.read(2)) << 8)
        case 0x064: return UInt16(square1.read(4)) << 8
        case 0x068: return UInt16(square2.read(1)) | (UInt16(square2.read(2)) << 8)
        case 0x06C: return UInt16(square2.read(4)) << 8
        case 0x070: return UInt16(wave.read(0))
        case 0x072: return UInt16(wave.read(2)) << 8
        case 0x074: return UInt16(wave.read(4)) << 8
        case 0x078: return UInt16(noise.read(2)) << 8
        case 0x07C: return UInt16(noise.read(3)) | (UInt16(noise.read(4)) << 8)
        case 0x080: return psgControl
        case 0x082: return mixControl
        case 0x084:
            var value: UInt16 = masterEnable ? 0x0080 : 0
            if square1.isActive { value |= 0x01 }
            if square2.isActive { value |= 0x02 }
            if wave.isActive { value |= 0x04 }
            if noise.isActive { value |= 0x08 }
            return value
        case 0x088: return soundBias
        case 0x090...0x09E:
            let index = Int(register - 0x090)
            return UInt16(wave.readRAM(index)) | (UInt16(wave.readRAM(index + 1)) << 8)
        default:
            return 0
        }
    }

    func writeRegister(_ register: UInt32, _ value: UInt16) {
        let low = UInt8(value & 0xFF)
        let high = UInt8(value >> 8)

        // Only the master enable and the FIFOs respond while sound is off.
        if !masterEnable, register != 0x084, !(0x0A0...0x0A7).contains(register) {
            return
        }

        switch register {
        case 0x060: square1.write(0, low)
        case 0x062: square1.write(1, low); square1.write(2, high)
        case 0x064: square1.write(3, low); square1.write(4, high)
        case 0x068: square2.write(1, low); square2.write(2, high)
        case 0x06C: square2.write(3, low); square2.write(4, high)
        case 0x070: wave.write(0, low)
        case 0x072: wave.write(1, low); wave.write(2, high)
        case 0x074: wave.write(3, low); wave.write(4, high)
        case 0x078: noise.write(1, low); noise.write(2, high)
        case 0x07C: noise.write(3, low); noise.write(4, high)

        case 0x080: psgControl = value
        case 0x082:
            mixControl = value
            // Bits 11 and 15 are one-shot FIFO resets.
            if value & 0x0800 != 0 { fifoA.reset(); currentSampleA = 0 }
            if value & 0x8000 != 0 { fifoB.reset(); currentSampleB = 0 }
        case 0x084:
            let enabled = value & 0x0080 != 0
            if !enabled && masterEnable {
                square1.reset(); square2.reset(); wave.reset(); noise.reset()
                psgControl = 0
                frameSequencerStep = 0
            }
            masterEnable = enabled
        case 0x088:
            soundBias = value

        case 0x090...0x09E:
            let index = Int(register - 0x090)
            wave.writeRAM(index, low)
            wave.writeRAM(index + 1, high)

        case 0x0A0, 0x0A2:
            // A 16-bit write to the FIFO port queues two samples.
            fifoA.push(Int8(bitPattern: low))
            fifoA.push(Int8(bitPattern: high))
        case 0x0A4, 0x0A6:
            fifoB.push(Int8(bitPattern: low))
            fifoB.push(Int8(bitPattern: high))

        default:
            break
        }
    }
}

// MARK: - FIFO

/// A 32-byte circular queue of signed PCM samples.
private struct FIFO {
    private var storage = [Int8](repeating: 0, count: 32)
    private var head = 0
    private var tail = 0
    private(set) var count = 0

    mutating func push(_ sample: Int8) {
        // A full FIFO drops the incoming byte, as the hardware does.
        guard count < 32 else { return }
        storage[tail] = sample
        tail = (tail + 1) & 31
        count += 1
    }

    mutating func pop() -> Int8? {
        guard count > 0 else { return nil }
        let sample = storage[head]
        head = (head + 1) & 31
        count -= 1
        return sample
    }

    mutating func reset() {
        head = 0
        tail = 0
        count = 0
    }
}

// MARK: - PSG channels
//
// These are the Game Boy's original sound channels, carried into the GBA
// unchanged apart from the wave channel gaining a second bank.

private struct GBAEnvelope {
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

    var dacEnabled: Bool { initialVolume > 0 || increasing }
}

private final class GBASquareChannel {
    private static let dutyTable: [[Double]] = [
        [-1, -1, -1, -1, -1, -1, -1,  1],
        [ 1, -1, -1, -1, -1, -1, -1,  1],
        [ 1, -1, -1, -1, -1,  1,  1,  1],
        [-1,  1,  1,  1,  1,  1,  1, -1],
    ]

    private let hasSweep: Bool
    private var duty = 2
    private var dutyStep = 0
    private var frequency = 0
    private var timer = 0
    private var envelope = GBAEnvelope()
    private var lengthCounter = 0
    private var lengthEnabled = false

    private var sweepPeriod = 0
    private var sweepNegate = false
    private var sweepShift = 0
    private var sweepTimer = 0
    private var sweepShadow = 0
    private var sweepActive = false

    private(set) var isActive = false

    init(hasSweep: Bool) { self.hasSweep = hasSweep }

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

    func clockEnvelope() { envelope.clock() }

    func clockSweep() {
        guard hasSweep, sweepActive, sweepPeriod > 0 else { return }
        sweepTimer -= 1
        guard sweepTimer <= 0 else { return }
        sweepTimer = sweepPeriod

        let updated = calculateSweep()
        if updated <= 2047 && sweepShift > 0 {
            sweepShadow = updated
            frequency = updated
            _ = calculateSweep()
        }
    }

    private func calculateSweep() -> Int {
        var updated = sweepShadow >> sweepShift
        updated = sweepNegate ? sweepShadow - updated : sweepShadow + updated
        if updated > 2047 { isActive = false }
        return updated
    }

    func read(_ index: Int) -> UInt8 {
        switch index {
        case 0:
            guard hasSweep else { return 0 }
            return UInt8((sweepPeriod << 4) | (sweepNegate ? 0x08 : 0) | sweepShift)
        case 1: return UInt8(duty << 6)
        case 2:
            return UInt8(envelope.initialVolume << 4)
                 | (envelope.increasing ? 0x08 : 0)
                 | UInt8(envelope.period)
        default: return lengthEnabled ? 0x40 : 0
        }
    }

    func write(_ index: Int, _ value: UInt8) {
        switch index {
        case 0:
            guard hasSweep else { return }
            sweepPeriod = Int((value >> 4) & 0x07)
            sweepNegate = value & 0x08 != 0
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
            if sweepShift > 0 { _ = calculateSweep() }
        }
    }

    func reset() {
        duty = 0; dutyStep = 0; frequency = 0; timer = 0
        envelope = GBAEnvelope()
        lengthCounter = 0; lengthEnabled = false
        sweepPeriod = 0; sweepNegate = false; sweepShift = 0
        sweepTimer = 0; sweepShadow = 0; sweepActive = false
        isActive = false
    }
}

private final class GBAWaveChannel {
    private var dacOn = false
    private var frequency = 0
    private var timer = 0
    private var position = 0
    private var volumeShift = 0
    private var lengthCounter = 0
    private var lengthEnabled = false
    private var sampleBuffer: UInt8 = 0

    /// The GBA has two switchable banks of 32 samples, unlike the Game Boy's
    /// single bank.
    private var waveRAM = [UInt8](repeating: 0, count: 32)
    private var bank = 0
    private var useBothBanks = false

    private(set) var isActive = false

    func tickTimer() {
        timer -= 1
        guard timer <= 0 else { return }
        timer = (2048 - frequency) * 2

        let limit = useBothBanks ? 64 : 32
        position = (position + 1) % limit
        let effective = useBothBanks ? position : bank * 32 + position
        let byteIndex = (effective >> 1) & 31
        sampleBuffer = effective & 1 == 0 ? (waveRAM[byteIndex] >> 4) : (waveRAM[byteIndex] & 0x0F)
    }

    func output() -> Double {
        guard isActive, dacOn, volumeShift > 0 else { return 0 }
        let level: Int
        switch volumeShift {
        case 1: level = Int(sampleBuffer)
        case 2: level = Int(sampleBuffer) >> 1
        default: level = Int(sampleBuffer) >> 2
        }
        return (Double(level) / 7.5) - 1.0
    }

    func clockLength() {
        guard lengthEnabled, lengthCounter > 0 else { return }
        lengthCounter -= 1
        if lengthCounter == 0 { isActive = false }
    }

    func read(_ index: Int) -> UInt8 {
        switch index {
        case 0: return (dacOn ? 0x80 : 0) | (useBothBanks ? 0x20 : 0) | UInt8(bank << 6)
        case 2: return UInt8(volumeShift << 5)
        default: return lengthEnabled ? 0x40 : 0
        }
    }

    func write(_ index: Int, _ value: UInt8) {
        switch index {
        case 0:
            useBothBanks = value & 0x20 != 0
            bank = Int((value >> 6) & 1)
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

    func readRAM(_ index: Int) -> UInt8 { waveRAM[index & 31] }
    func writeRAM(_ index: Int, _ value: UInt8) { waveRAM[index & 31] = value }

    func reset() {
        dacOn = false; frequency = 0; timer = 0; position = 0
        volumeShift = 0; lengthCounter = 0; lengthEnabled = false
        sampleBuffer = 0; isActive = false
    }
}

private final class GBANoiseChannel {
    private static let divisors = [8, 16, 32, 48, 64, 80, 96, 112]

    private var envelope = GBAEnvelope()
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

        let feedback = (lfsr & 1) ^ ((lfsr >> 1) & 1)
        lfsr >>= 1
        lfsr |= feedback << 14
        if widthMode7Bit {
            lfsr = (lfsr & ~0x40) | (feedback << 6)
        }
    }

    func output() -> Double {
        guard isActive, envelope.dacEnabled else { return 0 }
        return ((lfsr & 1) == 0 ? 1.0 : -1.0) * Double(envelope.volume) / 15.0
    }

    func clockLength() {
        guard lengthEnabled, lengthCounter > 0 else { return }
        lengthCounter -= 1
        if lengthCounter == 0 { isActive = false }
    }

    func clockEnvelope() { envelope.clock() }

    func read(_ index: Int) -> UInt8 {
        switch index {
        case 2:
            return UInt8(envelope.initialVolume << 4)
                 | (envelope.increasing ? 0x08 : 0)
                 | UInt8(envelope.period)
        case 3:
            return UInt8(clockShift << 4) | (widthMode7Bit ? 0x08 : 0) | UInt8(divisorCode)
        default:
            return lengthEnabled ? 0x40 : 0
        }
    }

    func write(_ index: Int, _ value: UInt8) {
        switch index {
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
        default:
            lengthEnabled = value & 0x40 != 0
            if value & 0x80 != 0 { trigger() }
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
        envelope = GBAEnvelope()
        lengthCounter = 0; lengthEnabled = false
        clockShift = 0; widthMode7Bit = false; divisorCode = 0
        timer = 0; lfsr = 0x7FFF; isActive = false
    }
}
