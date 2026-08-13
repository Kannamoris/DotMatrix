import Foundation

/// A complete emulated Game Boy Advance.
final class GBASystem: EmulatorCore {
    let cartridge: GBACartridge
    let bus: GBABus
    let cpu: ARM7TDMI

    /// One frame is 228 scanlines of 1232 cycles.
    private static let cyclesPerFrame = 280_896

    /// Where the cartridge's entry point lives.
    private static let romEntryPoint: UInt32 = 0x0800_0000

    init(cartridge: GBACartridge, sampleRate: Double = 48000) {
        self.cartridge = cartridge
        self.bus = GBABus(cartridge: cartridge, sampleRate: sampleRate)
        self.cpu = ARM7TDMI(bus: bus)
        bus.cpu = cpu

        // No BIOS image is executed, so the CPU starts in the state the BIOS
        // would have handed over in, with the ROM's entry point in PC.
        cpu.reset(entryPoint: Self.romEntryPoint)
    }

    // MARK: EmulatorCore

    var screenWidth: Int { GBAPPU.width }
    var screenHeight: Int { GBAPPU.height }

    /// 16777216 / 280896.
    var refreshRate: Double { 59.7275 }

    var displayTitle: String {
        cartridge.title.isEmpty ? "Untitled Cartridge" : cartridge.title
    }

    func runFrame() {
        let startCycles = bus.totalCycles
        // Bound the loop so a wedged ROM can't hang the emulation thread.
        let budget = Self.cyclesPerFrame * 2

        while bus.totalCycles - startCycles < budget {
            cpu.step()
            // HALTCNT and the IntrWait calls park the CPU; an asserted
            // interrupt is what releases it.
            bus.updateHaltState()
            if bus.ppu.consumeFrameComplete() { break }
        }
    }

    func withFramebuffer<T>(_ body: (UnsafeBufferPointer<UInt32>) -> T) -> T {
        bus.ppu.framebuffer.withUnsafeBufferPointer(body)
    }

    func setButtons(_ buttons: GBAButtons) {
        bus.setButtons(buttons)
    }

    func readAudio(into left: UnsafeMutablePointer<Float>,
                   _ right: UnsafeMutablePointer<Float>,
                   frameCount: Int) -> Int {
        bus.apu.read(into: left, right, frameCount: frameCount)
    }

    func flushAudio() {
        bus.apu.clearBuffer()
    }

    var queuedAudioFrameCount: Int { bus.apu.availableFrames }

    var batteryRAM: [UInt8]? {
        let data = cartridge.backup.data
        return data.isEmpty ? nil : data
    }

    func loadBatteryRAM(_ bytes: [UInt8]) {
        cartridge.backup.load(bytes)
    }

    var needsBatteryFlush: Bool { cartridge.backup.isDirty }

    func markBatteryFlushed() { cartridge.backup.isDirty = false }

    func readMemory(_ address: UInt32, count: Int) -> [UInt8] {
        guard count > 0, count <= 0x10000 else { return [] }
        var result = [UInt8](repeating: 0, count: count)
        for offset in 0..<count {
            // Peek without disturbing wait-state accounting or open-bus state.
            result[offset] = bus.peek(address &+ UInt32(offset))
        }
        return result
    }
}
