import AVFoundation
import os

/// Pulls audio out of the core and feeds it to the output device.
///
/// The render callback is the machine's real clock: emulation is paced to keep
/// this buffer fed rather than to a wall-clock timer, which is what keeps the
/// pitch stable and avoids the periodic crackle you get from resampling a
/// free-running core.
final class AudioEngine {
    /// Hint for the physical hardware, unrelated to the rate the core actually
    /// renders at — real output hardware doesn't run at GBA-native rates like
    /// 65536Hz, so this just asks for a normal one. AVAudioEngine resamples
    /// between the source node's declared format and whatever the hardware
    /// settles on; that conversion is what keeps pitch correct regardless.
    static let preferredHardwareSampleRate: Double = 48000

    /// Used before the core's real rate is known (see `EmulatorCore.audioSampleRate`).
    static let fallbackSampleRate: Double = 32768

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private weak var core: (any EmulatorCore)?

    private(set) var isRunning = false
    /// The rate the source node is currently configured for. Set only while
    /// running; `syncSampleRate` is how this tracks the core.
    private(set) var sampleRate: Double = 0

    /// Set when the core failed to supply enough samples, so the pacer can
    /// let emulation run slightly ahead to recover. Written from CoreAudio's
    /// real-time render thread, read and reset from the emulation thread —
    /// the same kind of unsynchronized cross-thread access that crashed the
    /// core's own audio buffer, just quieter here since it's a plain Int
    /// instead of an assert. Locked for the same reason.
    private let underrunLock = OSAllocatedUnfairLock(initialState: 0)

    var underrunCount: Int { underrunLock.withLock { $0 } }

    func attach(core: any EmulatorCore) {
        self.core = core
    }

    /// - Parameter sampleRate: The rate to render audio at. This must match
    ///   what the core is actually producing (`EmulatorCore.audioSampleRate`,
    ///   with a fallback while that's still unknown) — declaring the wrong
    ///   rate here doesn't just mis-pitch playback, it also feeds the wrong
    ///   number into the buffer-depth pacing math in `EmulatorSession`, which
    ///   silently caps overall emulation speed. Call `syncSampleRate` once the
    ///   real rate is known instead of restarting by hand.
    func start(sampleRate: Double = AudioEngine.fallbackSampleRate) {
        guard !isRunning else { return }

        self.sampleRate = sampleRate
        configureSession()

        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 2
        )!

        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)

            guard let self,
                  let core = self.core,
                  buffers.count >= 2,
                  let leftRaw = buffers[0].mData,
                  let rightRaw = buffers[1].mData
            else {
                // Nothing to play — emit silence rather than whatever was in
                // the buffer previously.
                for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
                    memset(buffer.mData, 0, Int(buffer.mDataByteSize))
                }
                return noErr
            }

            let left = leftRaw.assumingMemoryBound(to: Float.self)
            let right = rightRaw.assumingMemoryBound(to: Float.self)

            let written = core.readAudio(into: left, right, frameCount: frames)

            if written < frames {
                // Pad the shortfall with silence and note it for the pacer.
                let remaining = frames - written
                memset(left + written, 0, remaining * MemoryLayout<Float>.size)
                memset(right + written, 0, remaining * MemoryLayout<Float>.size)
                self.underrunLock.withLock { $0 += 1 }
            }

            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node

        do {
            try engine.start()
            isRunning = true
        } catch {
            NSLog("DotMatrix: audio engine failed to start: \(error)")
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.stop()
        if let node = sourceNode {
            engine.detach(node)
        }
        sourceNode = nil
        isRunning = false
        sampleRate = 0
    }

    /// Rebuild the graph if the core's real output rate no longer matches what
    /// it's declared as. That rate isn't known at boot — the game sets it via
    /// SOUNDBIAS a few frames in, and a handful of games change it again later
    /// (e.g. for battle music) — so this is meant to be polled periodically
    /// for the life of the session, not called once.
    func syncSampleRate(_ newRate: Double) {
        guard isRunning, newRate > 0, newRate != sampleRate else { return }
        stop()
        start(sampleRate: newRate)
    }

    func resetUnderrunCount() {
        underrunLock.withLock { $0 = 0 }
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // `.ambient` lets music from other apps keep playing, and stops the
            // emulator from grabbing the audio focus of the whole device.
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setPreferredSampleRate(Self.preferredHardwareSampleRate)
            // A short buffer keeps input latency low; the OS may not honour it.
            try session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
        } catch {
            NSLog("DotMatrix: audio session setup failed: \(error)")
        }
    }

    func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
