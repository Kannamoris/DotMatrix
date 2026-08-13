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

    /// What the core is currently being handed, and how many presses have
    /// arrived. If a tap never moves these, input is not reaching emulation —
    /// which looks identical to the game being stuck.
    @Published private(set) var inputDiagnostics: String = ""

    /// Result of the last snapshot operation, for surfacing in the UI.
    @Published private(set) var stateMessage: String?
    @Published private(set) var hasSnapshot = false

    let displayTitle: String
    let contentID: String
    let screenWidth: Int
    let screenHeight: Int

    /// Owned by the emulation thread once `start()` returns.
    private let core: any EmulatorCore
    private let audio = AudioEngine()
    private let saves = SaveManager()
    private let states = StateManager()

    private struct ControlState {
        var running = false
        var paused = false
        var fastForward = false
        var audioActive = false
        var forceFlushRequested = false
        /// Snapshot work is done on the emulation thread, which owns the core.
        var snapshotRequested = false
        var restoreRequested = false
        var buttons = GBAButtons()
        /// Counts transitions from nothing-held to something-held.
        var pressCount = 0
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
        hasSnapshot = states.hasState(for: contentID)
    }

    deinit {
        // Belt and braces: never leave the thread spinning on a dropped session.
        control.withLock { $0.running = false }
    }

    // MARK: Lifecycle

    @MainActor
    func start() {
        guard !isRunning else { return }

        audio.start(sampleRate: initialAudioSampleRate())
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
        audio.start(sampleRate: initialAudioSampleRate())
        control.withLock {
            $0.paused = false
            $0.audioActive = audio.isRunning
        }
        isPaused = false
    }

    /// The core's real output rate, once the game has configured its sound
    /// hardware — unknown any earlier than that, hence the fallback.
    private func initialAudioSampleRate() -> Double {
        let rate = Double(core.audioSampleRate)
        return rate > 0 ? rate : AudioEngine.fallbackSampleRate
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

    /// Snapshot the machine. The work happens on the emulation thread.
    func requestSnapshot() {
        control.withLock { $0.snapshotRequested = true }
    }

    /// Reload the snapshot, discarding current progress.
    func requestRestore() {
        control.withLock { $0.restoreRequested = true }
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

    func clearStateMessage() { stateMessage = nil }

    func setButtons(_ buttons: GBAButtons) {
        control.withLock {
            if $0.buttons.isEmpty && !buttons.isEmpty { $0.pressCount += 1 }
            $0.buttons = buttons
        }
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

        // The core's actual output rate — not fixed, see `audioSampleRate` —
        // determines both how much a "queued frame" is worth in real time and
        // how fast production has to run to keep the buffer fed. Getting this
        // wrong doesn't mis-time playback so much as silently cap overall
        // emulation speed, since the pacer below throttles production to
        // match a drain rate that was never the real one.
        var currentAudioRate = initialAudioSampleRate()
        // Keep roughly 30 ms of audio queued: enough to absorb a scheduling
        // hiccup, short enough that input still feels immediate.
        var targetQueuedFrames = Int(currentAudioRate * 0.030)

        var framesThisSecond = 0
        var secondMarker = CFAbsoluteTimeGetCurrent()
        var lastSaveCheck = secondMarker
        // Isolates the core's own cost from pacing sleeps and frame handoff,
        // so a slow device and a slow core don't look the same in the overlay.
        var runFrameSeconds: Double = 0
        var publishSeconds: Double = 0

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

            if state.snapshotRequested {
                control.withLock { $0.snapshotRequested = false }
                let failure = states.save(core, contentID: contentID)
                DispatchQueue.main.async { [weak self] in
                    self?.stateMessage = failure ?? "Snapshot saved."
                    self?.hasSnapshot = failure == nil
                }
            }

            if state.restoreRequested {
                control.withLock { $0.restoreRequested = false }
                let failure = states.load(into: core, contentID: contentID)
                DispatchQueue.main.async { [weak self] in
                    self?.stateMessage = failure ?? "Snapshot loaded."
                }
            }

            if state.paused {
                Thread.sleep(forTimeInterval: 0.016)
                nextFrameDeadline = CFAbsoluteTimeGetCurrent()
                continue
            }

            if !state.fastForward {
                if state.audioActive {
                    let excess = core.queuedAudioFrameCount - targetQueuedFrames
                    if excess > 0 {
                        // Sleep for how long the audio device will actually
                        // take to drain the excess, instead of polling in
                        // fixed 1ms slices. Each wake from a sub-millisecond
                        // sleep pays real scheduler overhead, and this was
                        // looping ~15-20 times per emulated frame — that
                        // overhead, not the core, was the missing speed.
                        let waitSeconds = min(Double(excess) / currentAudioRate, 0.020)
                        Thread.sleep(forTimeInterval: waitSeconds)
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
            let frameStart = CFAbsoluteTimeGetCurrent()
            core.runFrame()
            let runFrameEnd = CFAbsoluteTimeGetCurrent()
            runFrameSeconds += runFrameEnd - frameStart
            publishFrame()
            publishSeconds += CFAbsoluteTimeGetCurrent() - runFrameEnd

            framesThisSecond += 1
            let now = CFAbsoluteTimeGetCurrent()

            if now - secondMarker >= 1.0 {
                let fps = Double(framesThisSecond) / (now - secondMarker)
                let avgRunFrameMs = runFrameSeconds / Double(framesThisSecond) * 1000
                let avgPublishMs = publishSeconds / Double(framesThisSecond) * 1000
                let budgetMs = 1000.0 / core.refreshRate
                framesThisSecond = 0
                runFrameSeconds = 0
                publishSeconds = 0
                secondMarker = now

                // The real rate isn't known until the game configures its own
                // sound hardware, a few frames into boot, and a handful of
                // games change it again later (e.g. for battle music) — so
                // this keeps checking for the life of the session rather than
                // reading it once.
                let liveAudioRate = Double(core.audioSampleRate)
                if liveAudioRate > 0, liveAudioRate != currentAudioRate {
                    currentAudioRate = liveAudioRate
                    targetQueuedFrames = Int(currentAudioRate * 0.030)
                    // AVAudioEngine start/stop happen on the main thread
                    // everywhere else in this class; stay consistent rather
                    // than prove out a new pattern here.
                    DispatchQueue.main.async { [weak self] in
                        self?.audio.syncSampleRate(liveAudioRate)
                    }
                }

                // Sampled on this thread, which owns the core, and published
                // to the main queue.
                let perf = String(format: "PERF runFrame %.2fms  publish %.2fms  budget %.2fms  fps %.1f",
                                   avgRunFrameMs, avgPublishMs, budgetMs, fps)
                let audioLine = String(format: "AUDIO queued %d  target %d  underruns %d  rate %.0fHz",
                                        core.queuedAudioFrameCount, targetQueuedFrames,
                                        audio.underrunCount, currentAudioRate)
                audio.resetUnderrunCount()
                let diagnostics = [perf, audioLine, formatBuildDiagnostics(), formatVideoDiagnostics()]
                    .joined(separator: "\n")
                let input = formatInputDiagnostics(state.buttons, presses: state.pressCount)
                DispatchQueue.main.async { [weak self] in
                    self?.measuredFPS = fps
                    self?.videoDiagnostics = diagnostics
                    self?.inputDiagnostics = input
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

    /// Static build identity, so a screenshot carries which binary produced it
    /// without having to ask what was installed at the time.
    private func formatBuildDiagnostics() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        #if DEBUG
        let config = "Debug"
        #else
        let config = "Release"
        #endif
        return "BUILD v\(version) (\(build)) \(config)  core mGBA  rom \(core.displayTitle)"
    }

    /// Read the video, timer, DMA and interrupt registers straight out of
    /// emulated I/O space and lay them out in the terms the hardware and the
    /// renderer actually branch on — everything short of a full memory dump
    /// that's ever mattered while chasing a rendering or timing bug.
    private func formatVideoDiagnostics() -> String {
        let size = 0x302
        let io = core.readMemory(0x0400_0000, count: size)
        guard io.count >= size else { return "" }

        func half(_ offset: Int) -> UInt16 {
            UInt16(io[offset]) | (UInt16(io[offset + 1]) << 8)
        }
        func hex(_ v: UInt16) -> String { String(format: "%04X", v) }

        let dispcnt = half(0x00)
        let dispstat = half(0x04)
        let vcount = half(0x06) & 0xFF
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
        lines.append("DISPCNT \(hex(dispcnt))  mode \(mode)  VCOUNT \(vcount)  DISPSTAT \(hex(dispstat))")
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
            let hofs = half(0x10 + bg * 4)
            let vofs = half(0x12 + bg * 4)
            lines.append("BG\(bg) \(hex(control)) pri\(priority) cb\(charBase) sb\(screenBase) \(depth) sz\(size)\(mosaic) scroll \(hex(hofs))/\(hex(vofs))")
        }

        lines.append("BLD \(hex(blend)) \(effect) EVA/EVB \(hex(half(0x52))) EVY \(hex(half(0x54)))")
        lines.append("WIN in \(hex(half(0x48))) out \(hex(half(0x4A))) MOSAIC \(hex(half(0x4C)))")

        // Timer control: bit7 enable, bits0-1 prescaler, bit2 cascade, bit6 IRQ.
        var timers: [String] = []
        for t in 0..<4 {
            let base = 0x100 + t * 4
            let ctrl = half(base + 2)
            guard ctrl & 0x80 != 0 else { continue }
            let prescaler = [1, 64, 256, 1024][Int(ctrl & 0x3)]
            let cascade = ctrl & 0x4 != 0 ? " casc" : ""
            let irq = ctrl & 0x40 != 0 ? " irq" : ""
            timers.append("T\(t)=\(hex(half(base)))/\(prescaler)\(cascade)\(irq)")
        }
        lines.append("TIMERS  \(timers.isEmpty ? "none active" : timers.joined(separator: " "))")

        // DMA control: bit15 enable, bits12-13 start timing, bit9 repeat.
        var dmas: [String] = []
        for d in 0..<4 {
            let base = 0x0B0 + d * 0xC
            let cntH = half(base + 0xA)
            guard cntH & 0x8000 != 0 else { continue }
            let count = half(base + 0x8)
            let timing = ["imm", "vblank", "hblank", "special"][Int((cntH >> 12) & 0x3)]
            let repeatFlag = cntH & 0x0200 != 0 ? " rep" : ""
            dmas.append("D\(d)=\(count)@\(timing)\(repeatFlag)")
        }
        lines.append("DMA     \(dmas.isEmpty ? "none active" : dmas.joined(separator: " "))")

        let ie = half(0x200)
        let irqFlags = half(0x202)
        let ime = half(0x208) & 0x1
        lines.append("IRQ IE \(hex(ie))  IF \(hex(irqFlags))  IME \(ime)")

        return lines.joined(separator: "\n")
    }

    /// Render the held buttons the way the hardware register sees them.
    private func formatInputDiagnostics(_ buttons: GBAButtons, presses: Int) -> String {
        let names: [(GBAButtons, String)] = [
            (.a, "A"), (.b, "B"), (.select, "SEL"), (.start, "STA"),
            (.right, "R"), (.left, "L"), (.up, "U"), (.down, "D"),
            (.r, "R1"), (.l, "L1"),
        ]
        let held = names.filter { buttons.contains($0.0) }.map(\.1)
        let keyinput = ~buttons.rawValue & 0x03FF
        return String(format: "KEYS  %@  KEYINPUT=%03X presses=%d",
                      held.isEmpty ? "(none)" : held.joined(separator: "+"),
                      keyinput, presses)
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
