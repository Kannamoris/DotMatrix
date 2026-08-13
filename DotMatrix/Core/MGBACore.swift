import Foundation

/// The emulator, backed by mGBA.
///
/// Everything above this — renderer, audio, session pacing, saves, snapshots,
/// the battle overlay — is unchanged. `EmulatorCore` existed precisely so the
/// core underneath could be swapped, and this is that swap: a mature, widely
/// tested implementation in place of the hand-written one.
final class MGBACore: EmulatorCore {
    private let handle: OpaquePointer
    private var audioLeft: [Float]
    private var audioRight: [Float]

    let displayTitle: String
    let gameCode: String

    /// Fails if the image isn't a usable cartridge.
    init?(rom: Data) {
        guard let handle = rom.withUnsafeBytes({ buffer -> OpaquePointer? in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return OpaquePointer(dm_core_create(base, buffer.count))
        }) else {
            return nil
        }
        self.handle = handle

        self.audioLeft = [Float](repeating: 0, count: 4096)
        self.audioRight = [Float](repeating: 0, count: 4096)

        var title = [CChar](repeating: 0, count: 32)
        dm_core_game_title(UnsafeMutableRawPointer(handle).assumingMemoryBound(to: DMCore.self), &title, 32)
        let parsed = String(cString: title).trimmingCharacters(in: .whitespaces)
        self.displayTitle = parsed.isEmpty ? "Untitled Cartridge" : parsed

        var code = [CChar](repeating: 0, count: 16)
        dm_core_game_code(UnsafeMutableRawPointer(handle).assumingMemoryBound(to: DMCore.self), &code, 16)
        self.gameCode = String(cString: code).trimmingCharacters(in: .whitespaces)
    }

    deinit {
        dm_core_destroy(core)
    }

    /// The shim's handle, typed the way its functions expect.
    private var core: UnsafeMutablePointer<DMCore> {
        UnsafeMutableRawPointer(handle).assumingMemoryBound(to: DMCore.self)
    }

    // MARK: EmulatorCore

    var screenWidth: Int { Int(DM_SCREEN_WIDTH) }
    var screenHeight: Int { Int(DM_SCREEN_HEIGHT) }

    /// 16777216 / 280896.
    var refreshRate: Double { 59.7275 }

    func runFrame() {
        dm_core_run_frame(core)
    }

    func withFramebuffer<T>(_ body: (UnsafeBufferPointer<UInt32>) -> T) -> T {
        let pixels = dm_core_framebuffer(core)
        let count = screenWidth * screenHeight
        return body(UnsafeBufferPointer(start: pixels, count: count))
    }

    func setButtons(_ buttons: GBAButtons) {
        // The shim's bit order matches KEYINPUT, as does GBAButtons.
        dm_core_set_keys(core, UInt32(buttons.rawValue))
    }

    func readAudio(into left: UnsafeMutablePointer<Float>,
                   _ right: UnsafeMutablePointer<Float>,
                   frameCount: Int) -> Int {
        Int(dm_core_read_audio(core, left, right, frameCount))
    }

    func flushAudio() {
        dm_core_flush_audio(core)
    }

    var queuedAudioFrameCount: Int {
        Int(dm_core_queued_audio(core))
    }

    var batteryRAM: [UInt8]? {
        let size = Int(dm_core_save_size(core))
        guard size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let written = bytes.withUnsafeMutableBufferPointer {
            Int(dm_core_save_read(core, $0.baseAddress!, size))
        }
        return written > 0 ? Array(bytes.prefix(written)) : nil
    }

    func loadBatteryRAM(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        bytes.withUnsafeBufferPointer {
            dm_core_save_write(core, $0.baseAddress!, bytes.count)
        }
    }

    var needsBatteryFlush: Bool { dm_core_save_is_dirty(core) }

    func markBatteryFlushed() { dm_core_save_clear_dirty(core) }

    func readMemory(_ address: UInt32, count: Int) -> [UInt8] {
        guard count > 0, count <= 0x10000 else { return [] }
        var bytes = [UInt8](repeating: 0, count: count)
        bytes.withUnsafeMutableBufferPointer {
            dm_core_read_memory(core, address, $0.baseAddress!, count)
        }
        return bytes
    }

    func captureState() -> Data {
        let size = Int(dm_core_state_size(core))
        guard size > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: size)
        let ok = bytes.withUnsafeMutableBufferPointer {
            dm_core_state_save(core, $0.baseAddress!, size)
        }
        return ok ? Data(bytes) : Data()
    }

    func restoreState(_ data: Data) throws {
        let expected = Int(dm_core_state_size(core))
        guard data.count >= expected, expected > 0 else {
            throw SnapshotError.wrongSize(expected: expected, found: data.count)
        }
        let ok = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return false }
            return dm_core_state_load(core, base, buffer.count)
        }
        guard ok else { throw SnapshotError.rejected }
        flushAudio()
    }

    enum SnapshotError: LocalizedError {
        case wrongSize(expected: Int, found: Int)
        case rejected

        var errorDescription: String? {
            switch self {
            case .wrongSize(let expected, let found):
                return "That snapshot is \(found) bytes; this build expects \(expected)."
            case .rejected:
                return "The core refused that snapshot. It may be from a different cartridge."
            }
        }
    }
}
