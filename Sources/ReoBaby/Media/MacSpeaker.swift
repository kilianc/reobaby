import AVFoundation

/// Plays Soothing Sounds on this Mac's sound output.
final class MacSpeaker {
    let synth: SoothingSynth
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?

    /// `changeSeconds`: how long a new setting takes to arrive; quicker for a preview.
    init(changeSeconds: Double = SoothingSynth.changeSeconds) {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        synth = SoothingSynth(sampleRate: rate > 0 ? rate : 48000, lowestFrequency: 30, changeSeconds: changeSeconds)
    }

    func start() {
        guard node == nil else { return }
        let synth = self.synth
        let format = AVAudioFormat(standardFormatWithSampleRate: synth.sampleRate, channels: 1)!
        let source = AVAudioSourceNode(format: format) { _, _, frames, buffers in
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            guard let first = list.first, let data = first.mData else { return noErr }
            let samples = UnsafeMutableBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: Int(frames))
            synth.render(samples)
            // Every channel plays the same mono sound.
            for buffer in list.dropFirst() {
                buffer.mData?.copyMemory(from: data, byteCount: Int(frames) * MemoryLayout<Float>.size)
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        node = source
        do { try engine.start() } catch { print("Mac speaker: \(error)") }
    }

    func stop() {
        engine.stop()
        if let node { engine.detach(node) }
        node = nil
    }
}
