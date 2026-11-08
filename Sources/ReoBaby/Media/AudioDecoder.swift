import AVFoundation
import CoreMedia

/// Decodes camera audio (AAC, or 16-bit or float PCM) to interleaved Float32 samples.
final class AudioDecoder {
    struct PCM {
        var samples: [Float]
        let channels: Int
        let sampleRate: Double

        var meanSquare: Float {
            samples.isEmpty ? 0 : samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)
        }
    }

    /// False when the stream is in a format this can't decode.
    private(set) var canDecode = true
    private var format: CMFormatDescription?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?

    /// Forgets the previous stream's audio, before decoding a new one.
    func reset() {
        converter?.reset()
    }

    /// The decoded samples; empty while the decoder is still filling up, nil if the buffer can't be decoded.
    func decode(_ sample: CMSampleBuffer) -> PCM? {
        guard let fd = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee,
              let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return nil }
        let channels = Int(max(asbd.mChannelsPerFrame, 1))

        if asbd.mFormatID == kAudioFormatLinearPCM {
            let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            canDecode = isFloat ? asbd.mBitsPerChannel == 32 : asbd.mBitsPerChannel == 16
            guard canDecode else { return nil }
            if isFloat {
                var floats = [Float](repeating: 0, count: length / 4)
                guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: floats.count * 4,
                                                 destination: &floats) == kCMBlockBufferNoErr else { return nil }
                return PCM(samples: floats, channels: channels, sampleRate: asbd.mSampleRate)
            }
            var ints = [Int16](repeating: 0, count: length / 2)
            guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: ints.count * 2,
                                             destination: &ints) == kCMBlockBufferNoErr else { return nil }
            return PCM(samples: ints.map { Float($0) / 32768 }, channels: channels, sampleRate: asbd.mSampleRate)
        }

        if format.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: fd) }) ?? true {
            format = fd
            inputFormat = AVAudioFormat(cmAudioFormatDescription: fd)
            outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: asbd.mSampleRate,
                                         channels: AVAudioChannelCount(channels), interleaved: true)
            converter = inputFormat.flatMap { input in outputFormat.flatMap { AVAudioConverter(from: input, to: $0) } }
            canDecode = converter != nil
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
        guard error == nil else { return nil }
        // Interleaved: one pointer to every channel's samples.
        let count = Int(pcm.frameLength) * channels
        let samples = pcm.floatChannelData.map { Array(UnsafeBufferPointer(start: $0[0], count: count)) } ?? []
        return PCM(samples: samples, channels: channels, sampleRate: outputFormat.sampleRate)
    }
}
