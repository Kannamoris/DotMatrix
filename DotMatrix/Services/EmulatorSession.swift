import Foundation
import os

/// Owns a running core: the emulation thread, input state, audio and saves.
///
/// Emulation runs on its own thread rather than a display link so that video
/// and audio can't fight over the same clock. Pacing comes from the depth of
/// the audio queue, which is the only clock in the system that must not drift.
///
/// The class is deliberately *not* `@MainActor`. The core is touched only by
/// the emulation thread; everything the UI can reach is either lock-protected
/// or a `@Published` property republished onto the main queue.
final class EmulatorSession: ObservableObject, @unchecked Sendable {
    @Published private(set) var isRunning = false
    @Published private(set) var isPaused = false
    @Published private(set) var measuredFPS: Double = 0

    /// Live PPU register state, refreshed a few times a second. Exists so a
    /// screenshot of a misrendered frame carries the hardware configuration
    /// that produced it, instead of leaving the cause to be guessed at.
    @Published private(set) var videoDiagnostics: String = ""

    let displayTitle: String
    let contentID: String
    let screenWidth: Int
    let screenHeight: Int

    /// Owned by the emulation thread once `start()` returns.
    private let core: any EmulatorCore
    private let audio = AudioEngine()
    private let saves = SaveManager()

    private struct ControlState {
        var running = false
        var paused = false
        var fastForward = false
        var audioActive = false
        var forceFlushRequested = false
        var buttons = GBAButtons()
    }

    private let control = OSAllocatedUnfairLock(initialState: ControlState())

    /// Signalled by the emulation thread as it exits, so `stop()` can join.
    private let threadExited = DispatchSemaphore(value: 0)

    /// Latest completed frame, handed to the renderer.
    private var frontBuffer: [UInt32]
    private let frameLock = OSAllocatedUnfairLock(initialState: ())

    init(core: any EmulatorCore, contentID: String) {
        self.core = core
        self.contentID = contentID
        self.displayTitle = core.displayTitle
        self.screenWidth = core.screenWidth
        self.screenHeight = core.screenHeight
        self.frontBuffer = [UInt32](repeating: 0xFFFFFFFF, count: core.screenWidth * core.screenHeight)

        // Restore the in-game save before the CPU ever runs.
        saves.load(into: core, contentID: contentID)
        audio.attach(core: core)
    }

    deinit {
        // Belt and braces: never leave the thread spinning on a dropped session.
        control.withLock { $0.running = false }
    }

    // MARK: Lifecycle

    @MainActor
    func start() {
        guard !isRunning else { return }

        audio.start()
        control.withLock {
            $0.running = true
            $0.paused = false
            $0.audioActive = audio.isRunning
        }

        let thread = Thread { [weak self] in
            self?.emulationLoop()
        }
        thread.name = "com.dotmatrix.emulation"
        // Above default so a busy UI thread can't starve the audio producer.
        thread.qualityOfService = .userInteractive
        thread.stackSize = 512 * 1024
        thread.start()

        isRunning = true
        isPaused = false
    }

    @MainActor
    func pause() {
        guard isRunning, !isPaused else { return }
        // Ask the emulation thread to write the save out; it owns the core.
        control.withLock {
            $0.paused = true
            $0.forceFlushRequested = true
        }
        audio.stop()
        control.withLock { $0.audioActive = false }
        isPaused = true
    }

    @MainActor
    func resume() {
        guard isRunning, isPaused else { return }
        core.flushAudio()
        audio.start()
        control.withLock {
            $0.paused = false
            $0.audioActive = audio.isRunning
        }
        isPaused = false
    }

    @MainActor
    func stop() {
        guard isRunning else { return }

        control.withLock { $0.running = false }
        // Wait for the loop to unwind so the core is unowned before the final
        // save. The timeout keeps a wedged core from blocking app termination.
        _ = threadExited.wait(timeout: .now() + 2.0)

        audio.stop()
        audio.deactivateSession()

        // Safe to touch the core directly now that the thread has exited.
        saves.forceFlush(core, contentID: contentID)

        isRunning = false
        isPaused = false
    }

    /// Request an out-of-band save write, e.g. when heading to the background.
    func requestSaveFlush() {
        control.withLock { $0.forceFlushRequested = true }
    }

    var isFastForwarding: Bool {
        get { control.withLock { $0.fastForward } }
        set {
            control.withLock { $0.fastForward = newValue }
            if newValue { core.flushAudio() }
        }
    }

    // MARK: Input

    func setButtons(_ buttons: GBAButtons) {
        control.withLock { $0.buttons = buttons }
    }

    // MARK: Frame handoff

    /// Copy the newest frame into `destination`. Called on the render thread.
    func copyLatestFrame(into destination: UnsafeMutableRawPointer, byteCount: Int) {
        frameLock.withLock { _ in
            frontBuffer.withUnsafeBytes { source in
                guard let base = source.baseAddress else { return }
                memcpy(destination, base, min(byteCount, source.count))
            }
        }
    }

    // MARK: Emulation thread

    private func emulationLoop() {
        defer { threadExited.signal() }

        // Keep roughly 30 ms of audio queued: enough to absorb a scheduling
        // hiccup, short enough that input still feels immediate.
        let targetQueuedFrames = Int(AudioEngine.sampleRate * 0.030)

        var framesThisSecond = 0
        var secondMarker = CFAbsoluteTimeGetCurrent()
        var lastSaveCheck = secondMarker

        // Fallback pacing for when audio is unavailable (the engine failed to
        // start, or output is routed somewhere that stalled) — otherwise the
        // loop would spin free and run at whatever speed the CPU allows.
        var nextFrameDeadline = CFAbsoluteTimeGetCurrent()

        while true {
            let state = control.withLock { $0 }
            guard state.running else { break }

            if state.forceFlushRequested {
                control.withLock { $0.forceFlushRequested = false }
                saves.forceFlush(core, contentID: contentID)
            }

            if state.paused {
                Thread.sleep(forTimeInterval: 0.016)
                nextFrameDeadline = CFAbsoluteTimeGetCurrent()
                continue
            }

            if !state.fastForward {
                if state.audioActive {
                    if core.queuedAudioFrameCount > targetQueuedFrames {
                        Thread.sleep(forTimeInterval: 0.001)
                        continue
                    }
                } else {
                    let now = CFAbsoluteTimeGetCurrent()
                    if now < nextFrameDeadline {
                        Thread.sleep(forTimeInterval: nextFrameDeadline - now)
                    }
                    nextFrameDeadline += 1.0 / core.refreshRate
                    // Don't try to catch up after a long stall.
                    if nextFrameDeadline < now { nextFrameDeadline = now }
                }
            }

            core.setButtons(state.buttons)
            core.runFrame()
            publishFrame()

            framesThisSecond += 1
            let now = CFAbsoluteTimeGetCurrent()

            if now - secondMarker >= 1.0 {
                let fps = Double(framesThisSecond) / (now - secondMarker)
                framesThisSecond = 0
                secondMarker = now
                // Sampled on this thread, which owns the core, and published
                // to the main queue.
                let diagnostics = formatVideoDiagnostics()
                DispatchQueue.main.async { [weak self] in
                    self?.measuredFPS = fps
                    self?.videoDiagnostics = diagnostics
                }
            }

            // Write SRAM out periodically so a crash costs at most a second of
            // progress. `flushIfNeeded` is a no-op unless the game touched it.
            if now - lastSaveCheck >= 1.0 {
                lastSaveCheck = now
                saves.flushIfNeeded(core, contentID: contentID)
            }
        }

        // Final write on the way out, in case we were stopped mid-frame.
        saves.flushIfNeeded(core, contentID: contentID)
    }

    /// Read the video registers straight out of emulated I/O space and lay them
    /// out in the terms the renderer actually branches on.
    private func formatVideoDiagnostics() -> String {
        let io = core.readMemory(0x0400_0000, count: 0x58)
        guard io.count >= 0x58 else { return "" }

        func half(_ offset: Int) -> UInt16 {
            UInt16(io[offset]) | (UInt16(io[offset + 1]) << 8)
        }
        func hex(_ v: UInt16) -> String { String(format: "%04X", v) }

        let dispcnt = half(0x00)
        let mode = dispcnt & 0x7
        var layers: [String] = []
        for bg in 0..<4 where dispcnt & (0x0100 << UInt16(bg)) != 0 {
            layers.append("BG\(bg)")
        }
        if dispcnt & 0x1000 != 0 { layers.append("OBJ") }

        var flags: [String] = []
        if dispcnt & 0x0080 != 0 { flags.append("FORCED-BLANK") }
        if dispcnt & 0x0040 != 0 { flags.append("OBJ-1D") } else { flags.append("OBJ-2D") }
        if dispcnt & 0x2000 != 0 { flags.append("WIN0") }
        if dispcnt & 0x4000 != 0 { flags.append("WIN1") }
        if dispcnt & 0x8000 != 0 { flags.append("OBJWIN") }

        let blend = half(0x50)
        let effect = ["none", "alpha", "brighten", "darken"][Int((blend >> 6) & 0x3)]

        var lines: [String] = []
        lines.append("DISPCNT \(hex(dispcnt))  mode \(mode)")
        lines.append("layers  \(layers.isEmpty ? "none" : layers.joined(separator: " "))")
        lines.append("flags   \(flags.joined(separator: " "))")

        for bg in 0..<4 {
            let control = half(0x08 + bg * 2)
            let priority = control & 0x3
            let charBase = (control >> 2) & 0x3
            let screenBase = (control >> 8) & 0x1F
            let depth = control & 0x0080 != 0 ? "256c" : "16c"
            let size = (control >> 14) & 0x3
            let mosaic = control & 0x0040 != 0 ? " mos" : ""
            lines.append("BG\(bg) \(hex(control)) pri\(priority) cb\(charBase) sb\(screenBase) \(depth) sz\(size)\(mosaic)")
        }

        lines.append("BLD \(hex(blend)) \(effect) EVA/EVB \(hex(half(0x52))) EVY \(hex(half(0x54)))")
        lines.append("WIN in \(hex(half(0x48))) out \(hex(half(0x4A))) MOSAIC \(hex(half(0x4C)))")
        lines.append("SCROLL \(hex(half(0x10)))/\(hex(half(0x12))) \(hex(half(0x14)))/\(hex(half(0x16)))")

        return lines.joined(separator: "\n")
    }

    private func publishFrame() {
        frameLock.withLock { _ in
            core.withFramebuffer { source in
                frontBuffer.withUnsafeMutableBufferPointer { destination in
                    guard let src = source.baseAddress,
                          let dst = destination.baseAddress else { return }
                    dst.update(from: src, count: min(source.count, destination.count))
                }
            }
        }
    }
}
