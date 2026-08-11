import Foundation

/// A complete emulated Game Boy / Game Boy Color.
final class GameBoy: EmulatorCore {
    let cartridge: Cartridge
    let mmu: MMU
    let cpu: CPU

    /// T-cycles in one frame: 154 scanlines x 456 dots.
    private static let cyclesPerFrame = 70224

    init(cartridge: Cartridge,
         preferCGB: Bool = true,
         palette: Palette = .dmgGreen,
         sampleRate: Double = 48000) {
        self.cartridge = cartridge
        self.mmu = MMU(cartridge: cartridge, preferCGB: preferCGB, sampleRate: sampleRate)
        self.cpu = CPU(bus: mmu)
        mmu.applyPostBootState()
        applyPalette(palette)
    }

    /// Recolour a monochrome game. No-op in colour mode, where the cartridge
    /// supplies its own palettes.
    func applyPalette(_ palette: Palette) {
        guard !mmu.isCGB else { return }
        mmu.ppu.setMonochromePalette(palette.shades)
    }

    /// True when this cartridge is running with colour hardware enabled.
    var isRunningInColorMode: Bool { mmu.isCGB }

    // MARK: EmulatorCore

    var screenWidth: Int { PPU.width }
    var screenHeight: Int { PPU.height }

    /// 4194304 / 70224. Not exactly 60 — running at a true 60 Hz makes audio
    /// drift, so the audio clock is what the frame pacing follows.
    var refreshRate: Double { 59.7275 }

    var displayTitle: String {
        cartridge.title.isEmpty ? "Untitled Cartridge" : cartridge.title
    }

    func runFrame() {
        var elapsed = 0
        let startCycles = mmu.totalCycles

        // Bound the loop so a locked-up ROM can't hang the render thread. In
        // double-speed mode the CPU gets through twice as many cycles per frame.
        let budget = Self.cyclesPerFrame * (mmu.doubleSpeed ? 2 : 1) * 2

        while elapsed < budget {
            cpu.step()
            elapsed = mmu.totalCycles - startCycles
            if mmu.ppu.frameComplete { break }
        }
    }

    func withFramebuffer<T>(_ body: (UnsafeBufferPointer<UInt32>) -> T) -> T {
        mmu.ppu.framebuffer.withUnsafeBufferPointer(body)
    }

    func setButtons(_ buttons: GBButtons) {
        mmu.joypad.setPressed(buttons)
    }

    func readAudio(into left: UnsafeMutablePointer<Float>,
                   _ right: UnsafeMutablePointer<Float>,
                   frameCount: Int) -> Int {
        mmu.apu.read(into: left, right, frameCount: frameCount)
    }

    func flushAudio() {
        mmu.apu.clearBuffer()
    }

    var batteryRAM: [UInt8]? {
        guard cartridge.hasBattery, !cartridge.mbc.ram.isEmpty else { return nil }
        return cartridge.mbc.ram
    }

    func loadBatteryRAM(_ bytes: [UInt8]) {
        cartridge.mbc.loadRAM(bytes)
    }

    var needsBatteryFlush: Bool { cartridge.mbc.ramDirty }

    func markBatteryFlushed() { cartridge.mbc.ramDirty = false }

    var auxiliarySaveData: [String: Int] { cartridge.mbc.rtcSnapshot() }

    func restoreAuxiliarySaveData(_ data: [String: Int]) {
        cartridge.mbc.restoreRTC(data)
    }

    var queuedAudioFrameCount: Int { mmu.apu.availableFrames }
}

// MARK: - Monochrome palettes

/// Colour schemes applied to DMG games, which only ever emit four shades.
struct Palette: Identifiable, Hashable {
    let id: String
    let name: String
    /// Lightest to darkest, 0xAARRGGBB.
    let shades: [UInt32]

    static let dmgGreen = Palette(
        id: "dmg", name: "Game Boy",
        shades: [0xFFE0F8D0, 0xFF88C070, 0xFF346856, 0xFF081820])

    static let pocket = Palette(
        id: "pocket", name: "Pocket",
        shades: [0xFFE3E6C9, 0xFFC3C4A5, 0xFF8E8B61, 0xFF4F4F2F])

    static let grey = Palette(
        id: "grey", name: "Grayscale",
        shades: [0xFFFFFFFF, 0xFFAAAAAA, 0xFF555555, 0xFF000000])

    static let lightAmber = Palette(
        id: "amber", name: "Amber",
        shades: [0xFFFFF6D3, 0xFFF9A875, 0xFFEB6B6F, 0xFF7C3F58])

    static let all: [Palette] = [.dmgGreen, .pocket, .grey, .lightAmber]

    static func named(_ id: String) -> Palette {
        all.first { $0.id == id } ?? .dmgGreen
    }
}
