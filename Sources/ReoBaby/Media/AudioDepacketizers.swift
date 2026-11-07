import AudioToolbox
import CoreMedia
import Foundation

protocol AudioDepacketizer: AnyObject {
    var label: String { get }
    var clockRate: Int32 { get }
    /// `pts` maps an RTP timestamp to a presentation time; call it at most once per packet, in order.
    func push(_ packet: RTPPacket, pts: (UInt32) -> CMTime) -> CMSampleBuffer?
}

func makeAudioDepacketizer(_ m: MediaDescription) -> AudioDepacketizer? {
    switch m.encoding {
    case "MPEG4-GENERIC": return AACDepacketizer(m)
    case "PCMA", "PCMU": return G711Depacketizer(m)
    default: return nil
    }
}

/// AAC in RTP, RFC 3640 (mpeg4-generic, AAC-hbr/lbr). Compressed packets go
/// straight to the renderer, which decodes them.
final class AACDepacketizer: AudioDepacketizer {
    let label: String
    let clockRate: Int32
    private let sizeLength: Int
    private let indexLength: Int
    private let indexDeltaLength: Int
    private let format: CMAudioFormatDescription
    private var fragment: [UInt8] = []
    private var fragmentSize = 0
    private var fragmentTimestamp: UInt32 = 0

    init?(_ m: MediaDescription) {
        guard let hex = m.fmtp["config"], let asc = [UInt8](hex: hex), asc.count >= 2 else { return nil }
        sizeLength = Int(m.fmtp["sizelength"] ?? "") ?? 13
        indexLength = Int(m.fmtp["indexlength"] ?? "") ?? 3
        indexDeltaLength = Int(m.fmtp["indexdeltalength"] ?? "") ?? 3

        var r = BitReader(asc)
        var objectType = r.read(5)
        if objectType == 31 { objectType = 32 + r.read(6) }
        let freqIndex = r.read(4)
        let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        let sampleRate = freqIndex == 15 ? r.read(24) : (freqIndex < rates.count ? rates[freqIndex] : m.clockRate)
        let channelConfig = r.read(4)
        let channels = channelConfig == 0 ? max(m.channels, 1) : (channelConfig == 7 ? 8 : channelConfig)
        clockRate = Int32(m.clockRate > 0 ? m.clockRate : sampleRate)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate), mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: UInt32(objectType), mBytesPerPacket: 0, mFramesPerPacket: 1024,
            mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        let cookie = Self.esdsCookie(asc)
        var fd: CMAudioFormatDescription?
        let status = cookie.withUnsafeBytes {
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                magicCookieSize: cookie.count, magicCookie: $0.baseAddress, extensions: nil,
                formatDescriptionOut: &fd)
        }
        guard status == noErr, let fd else { return nil }
        format = fd
        label = "AAC \(sampleRate) Hz \(channels)ch"
    }

    /// MPEG-4 ES_Descriptor wrapping the AudioSpecificConfig, the magic cookie CoreAudio expects.
    private static func esdsCookie(_ asc: [UInt8]) -> [UInt8] {
        func descriptor(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] { [tag, UInt8(body.count)] + body }
        let decoderSpecific = descriptor(0x05, asc)
        let decoderConfig = descriptor(0x04, [0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] + decoderSpecific)
        let slConfig = descriptor(0x06, [0x02])
        return descriptor(0x03, [0x00, 0x00, 0x00] + decoderConfig + slConfig)
    }

    func push(_ packet: RTPPacket, pts: (UInt32) -> CMTime) -> CMSampleBuffer? {
        let p = packet.payload
        guard p.count >= 2, sizeLength > 0 else { return nil }
        let headerBits = Int(p[0]) << 8 | Int(p[1])
        let headerBytes = (headerBits + 7) / 8
        guard p.count >= 2 + headerBytes else { return nil }
        var reader = BitReader(Array(p[2..<2 + headerBytes]))
        var sizes: [Int] = []
        var used = 0
        while true {
            let idx = sizes.isEmpty ? indexLength : indexDeltaLength
            guard used + sizeLength + idx <= headerBits else { break }
            sizes.append(reader.read(sizeLength))
            _ = reader.read(idx)
            used += sizeLength + idx
        }
        var offset = 2 + headerBytes

        // One AU split across several packets.
        if sizes.count == 1, offset + sizes[0] > p.count {
            if fragment.isEmpty || fragmentTimestamp != packet.timestamp {
                fragment = []
                fragmentSize = sizes[0]
                fragmentTimestamp = packet.timestamp
            }
            fragment += p[offset...]
            guard packet.marker, fragment.count >= fragmentSize else { return nil }
            let frame = Array(fragment.prefix(fragmentSize))
            fragment = []
            return makeBuffer([frame], pts: pts(packet.timestamp))
        }
        fragment = []

        var frames: [[UInt8]] = []
        for size in sizes {
            guard size > 0, offset + size <= p.count else { break }
            frames.append(Array(p[offset..<offset + size]))
            offset += size
        }
        guard !frames.isEmpty else { return nil }
        return makeBuffer(frames, pts: pts(packet.timestamp))
    }

    private func makeBuffer(_ frames: [[UInt8]], pts: CMTime) -> CMSampleBuffer? {
        guard let block = makeBlockBuffer(frames.flatMap { $0 }) else { return nil }
        var descriptions: [AudioStreamPacketDescription] = []
        var offset: Int64 = 0
        for f in frames {
            descriptions.append(AudioStreamPacketDescription(
                mStartOffset: offset, mVariableFramesInPacket: 0, mDataByteSize: UInt32(f.count)))
            offset += Int64(f.count)
        }
        var sb: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: frames.count, presentationTimeStamp: pts,
            packetDescriptions: descriptions, sampleBufferOut: &sb)
        return status == noErr ? sb : nil
    }
}

/// G.711 A-law / µ-law, decoded to 16-bit PCM.
final class G711Depacketizer: AudioDepacketizer {
    let label: String
    let clockRate: Int32
    private let table: [Int16]
    private let format: CMAudioFormatDescription

    init?(_ m: MediaDescription) {
        let aLaw = m.encoding == "PCMA"
        table = (0...255).map { aLaw ? Self.decodeALaw(UInt8($0)) : Self.decodeULaw(UInt8($0)) }
        let rate = m.clockRate > 0 ? m.clockRate : 8000
        clockRate = Int32(rate)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(rate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var fd: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd) == noErr,
            let fd else { return nil }
        format = fd
        label = "\(aLaw ? "G.711 A-law" : "G.711 µ-law") \(rate) Hz"
    }

    func push(_ packet: RTPPacket, pts: (UInt32) -> CMTime) -> CMSampleBuffer? {
        guard !packet.payload.isEmpty else { return nil }
        let samples = packet.payload.map { table[Int($0)] }
        let bytes = samples.withUnsafeBytes { Array($0) }
        guard let block = makeBlockBuffer(bytes) else { return nil }
        var sb: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: samples.count, presentationTimeStamp: pts(packet.timestamp),
            packetDescriptions: nil, sampleBufferOut: &sb)
        return status == noErr ? sb : nil
    }

    private static func decodeULaw(_ u: UInt8) -> Int16 {
        let x = ~u
        let exponent = Int((x >> 4) & 0x07)
        var sample = (Int(x & 0x0F) << 3) + 0x84
        sample <<= exponent
        sample -= 0x84
        return Int16(x & 0x80 != 0 ? -sample : sample)
    }

    private static func decodeALaw(_ a: UInt8) -> Int16 {
        let x = a ^ 0x55
        var t = Int(x & 0x0F) << 4
        let segment = Int((x & 0x70) >> 4)
        switch segment {
        case 0: t += 8
        case 1: t += 0x108
        default: t += 0x108; t <<= segment - 1
        }
        return Int16(x & 0x80 != 0 ? t : -t)
    }
}
