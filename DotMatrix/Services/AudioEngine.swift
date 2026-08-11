import AVFoundation

/// Pulls audio out of the core and feeds it to the output device.
///
/// The render callback is the machine's real clock: emulation is paced to keep
/// this buffer fed rather than to a wall-clock timer, which is what keeps the
/// pitch stable and avoids the periodic crackle you get from resampling a
/// free-running core.
final class AudioEngine {
    static let sampleRate: Double = 48000

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private weak var core: (any EmulatorCore)?

    private(set) var isRunning = false

    /// Set when the core failed to supply enough samples, so the pacer can
    /// let emulation run slightly ahead to recover.
    private(set) var underrunCount = 0

    func attach(core: any EmulatorCore) {
        self.core = core
    }

    func start() {
        guard !isRunning else { return }

        configureSession()

        let format = AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate,
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
                self.underrunCount += 1
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
    }

    func resetUnderrunCount() {
        underrunCount = 0
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // `.ambient` lets music from other apps keep playing, and stops the
            // emulator from grabbing the audio focus of the whole device.
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setPreferredSampleRate(Self.sampleRate)
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
