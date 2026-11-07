import AVFoundation
import CoreMedia

/// Decodes audio sample buffers (AAC or 16-bit PCM) just far enough to measure loudness.
final class AudioLevelMeter {
    private var format: CMFormatDescription?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?

    /// RMS level of the buffer in dBFS (0 = full scale, silence ≈ -100), or nil if undecodable.
    func level(of sample: CMSampleBuffer) -> Float? {
        guard let fd = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee,
              let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return nil }

        if asbd.mFormatID == kAudioFormatLinearPCM && asbd.mBitsPerChannel == 16 {
            var samples = [Int16](repeating: 0, count: length / 2)
            guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: samples.count * 2,
                                             destination: &samples) == kCMBlockBufferNoErr else { return nil }
            var sum: Float = 0
            for s in samples { let v = Float(s) / 32768; sum += v * v }
            return Self.decibels(sum / Float(max(samples.count, 1)))
        }

        if format.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: fd) }) ?? true {
            format = fd
            inputFormat = AVAudioFormat(cmAudioFormatDescription: fd)
            outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: asbd.mSampleRate,
                                         channels: 1, interleaved: false)
            converter = inputFormat.flatMap { input in outputFormat.flatMap { AVAudioConverter(from: input, to: $0) } }
        }
        guard let converter, let inputFormat, let outputFormat else { return nil }

        let packets = CMSampleBufferGetNumSamples(sample)
        var descriptions: UnsafePointer<AudioStreamPacketDescription>?
        var descriptionsSize = 0
        guard packets > 0,
              CMSampleBufferGetAudioStreamPacketDescriptionsPtr(sample, packetDescriptionsPointerOut: &descriptions,
                                                                sizeOut: &descriptionsSize) == noErr,
              let descriptions else { return nil }

        let compressed = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: AVAudioPacketCount(packets),
                                                 maximumPacketSize: length)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                         destination: compressed.data) == kCMBlockBufferNoErr else { return nil }
        compressed.byteLength = UInt32(length)
        compressed.packetCount = AVAudioPacketCount(packets)
        compressed.packetDescriptions?.update(from: descriptions, count: packets)

        let framesPerPacket = max(Int(asbd.mFramesPerPacket), 1024)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                         frameCapacity: AVAudioFrameCount(packets * framesPerPacket)) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: pcm, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return compressed
        }
        guard error == nil, pcm.frameLength > 0, let channel = pcm.floatChannelData?[0] else { return nil }
        var sum: Float = 0
        for i in 0..<Int(pcm.frameLength) { sum += channel[i] * channel[i] }
        return Self.decibels(sum / Float(pcm.frameLength))
    }

    private static func decibels(_ meanSquare: Float) -> Float {
        10 * log10(max(meanSquare, 1e-10))
    }
}

/// Flags sounds that stand out from the room's background noise.
struct SoundDetector {
    /// How far above the background a sound must be.
    var thresholdDB: Float = 15
    /// Ignore anything quieter than this, however quiet the room.
    var absoluteFloorDB: Float = -50
    /// Loud audio needed within the last second to count as an event.
    var requiredLoudSeconds: Double = 0.4

    private(set) var noiseFloor: Float?
    private var loud: [(time: CFAbsoluteTime, duration: Double)] = []

    /// Feeds one buffer's level; returns true when a sound event starts.
    mutating func feed(level: Float, duration: Double, at time: CFAbsoluteTime) -> Bool {
        guard let floor = noiseFloor else {
            noiseFloor = level
            return false
        }
        let isLoud = level > max(floor + thresholdDB, absoluteFloorDB)
        // Track the background: adapt quickly downward, slowly upward, barely while loud.
        let rate: Float = level < floor ? 0.05 : (isLoud ? 0.0005 : 0.005)
        noiseFloor = floor + (level - floor) * rate

        if isLoud { loud.append((time, duration)) }
        loud.removeAll { time - $0.time > 1 }
        return loud.reduce(0) { $0 + $1.duration } >= requiredLoudSeconds
    }

    mutating func reset() {
        loud.removeAll()
    }
}
