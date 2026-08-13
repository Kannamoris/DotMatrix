import Foundation

/// What the UI layer needs from an emulated system.
///
/// The app talks to this and never to a concrete core directly, so the renderer,
/// audio, input and save plumbing stay independent of the console being
/// emulated.
protocol EmulatorCore: AnyObject {
    /// Native screen size in pixels.
    var screenWidth: Int { get }
    var screenHeight: Int { get }

    /// Frames per second this system runs at.
    var refreshRate: Double { get }

    /// Human-readable description of the loaded software.
    var displayTitle: String { get }

    /// Run until the next complete frame is ready.
    func runFrame()

    /// The most recent frame, row-major, byte order R,G,B,X per pixel (RGBA8
    /// with an unused/undefined alpha byte).
    func withFramebuffer<T>(_ body: (UnsafeBufferPointer<UInt32>) -> T) -> T

    /// Replace the current input state.
    func setButtons(_ buttons: GBAButtons)

    /// Pull rendered audio. Returns frames written; caller zero-fills the rest.
    func readAudio(into left: UnsafeMutablePointer<Float>,
                   _ right: UnsafeMutablePointer<Float>,
                   frameCount: Int) -> Int

    /// Discard buffered audio, e.g. after a pause.
    func flushAudio()

    /// Stereo frames currently queued for output. The session paces emulation
    /// against this, so it is the effective master clock.
    var queuedAudioFrameCount: Int { get }

    /// Battery-backed cartridge save, or nil if this cartridge has none.
    var batteryRAM: [UInt8]? { get }
    func loadBatteryRAM(_ bytes: [UInt8])

    /// True when the save has changed since the last flush.
    var needsBatteryFlush: Bool { get }
    func markBatteryFlushed()

    /// Extra mapper state to persist alongside the save. Unused on GBA.
    var auxiliarySaveData: [String: Int] { get }
    func restoreAuxiliarySaveData(_ data: [String: Int])

    /// Read emulated memory, for the game-aware overlay. Returns 0 outside any
    /// mapped region.
    func readMemory(_ address: UInt32, count: Int) -> [UInt8]

    /// Capture the entire machine, for a snapshot that can be reloaded later.
    func captureState() -> Data

    /// Restore a snapshot. Throws if it doesn't match this cartridge or this
    /// build's format.
    func restoreState(_ data: Data) throws
}

extension EmulatorCore {
    var auxiliarySaveData: [String: Int] { [:] }
    func restoreAuxiliarySaveData(_ data: [String: Int]) {}
}
