import CoreMedia
import Foundation

/// Reassembles H.264 (RFC 6184) / H.265 (RFC 7798) RTP payloads into access units
/// and wraps them as AVCC/HVCC CMSampleBuffers.
final class H26xDepacketizer {
    enum Codec: String {
        case h264 = "H.264"
        case h265 = "H.265"
    }

    struct AccessUnit {
        let nalus: [[UInt8]]
        let timestamp: UInt32
        let isKeyframe: Bool
    }

    let codec: Codec
    private(set) var format: CMVideoFormatDescription?
    /// Frames are dropped until the next intact keyframe while this is set.
    var needsKeyframe = true

    private var vps: [UInt8]?
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var paramsChanged = false
    private var nalus: [[UInt8]] = []
    private var containsKeyframe = false
    private var damaged = false
    private var auTimestamp: UInt32?
    private var fragment: [UInt8]?
    private var lastSequence: UInt16?

    init(codec: Codec, fmtp: [String: String]) {
        self.codec = codec
        let keys = codec == .h264 ? ["sprop-parameter-sets"] : ["sprop-vps", "sprop-sps", "sprop-pps"]
        for key in keys {
            for part in (fmtp[key] ?? "").split(separator: ",") {
                if let nal = [UInt8](base64Unpadded: String(part)) { _ = ingestParameterSet(nal) }
            }
        }
    }

    var dimensions: CGSize? {
        guard let format else { return nil }
        return CMVideoFormatDescriptionGetPresentationDimensions(format, usePixelAspectRatio: true, useCleanAperture: true)
    }

    func push(_ packet: RTPPacket) -> [AccessUnit] {
        var out: [AccessUnit] = []
        if let last = lastSequence, packet.sequence != last &+ 1 {
            damaged = true
            needsKeyframe = true
            fragment = nil
        }
        lastSequence = packet.sequence
        if let ts = auTimestamp, ts != packet.timestamp, let au = finishAccessUnit() {
            out.append(au)
        }
        auTimestamp = packet.timestamp
        switch codec {
        case .h264: depacketizeH264(packet.payload)
        case .h265: depacketizeH265(packet.payload)
        }
        if packet.marker, let au = finishAccessUnit() {
            out.append(au)
        }
        return out
    }

    private func depacketizeH264(_ p: [UInt8]) {
        guard let header = p.first else { return }
        switch header & 0x1F {
        case 1...23:
            add(p)
        case 24: // STAP-A
            var i = 1
            while i + 2 <= p.count {
                let size = Int(p[i]) << 8 | Int(p[i + 1])
                i += 2
                guard size > 0, i + size <= p.count else { break }
                add(Array(p[i..<i + size]))
                i += size
            }
        case 28: // FU-A
            guard p.count > 2 else { return }
            let fu = p[1]
            if fu & 0x80 != 0 {
                fragment = [(header & 0xE0) | (fu & 0x1F)] + p[2...]
            } else if fragment != nil {
                fragment!.append(contentsOf: p[2...])
            } else {
                damaged = true
                return
            }
            if fu & 0x40 != 0, let nal = fragment {
                add(nal)
                fragment = nil
            }
        default:
            break
        }
    }

    private func depacketizeH265(_ p: [UInt8]) {
        guard p.count >= 2 else { return }
        switch (p[0] >> 1) & 0x3F {
        case 48: // Aggregation packet
            var i = 2
            while i + 2 <= p.count {
                let size = Int(p[i]) << 8 | Int(p[i + 1])
                i += 2
                guard size > 0, i + size <= p.count else { break }
                add(Array(p[i..<i + size]))
                i += size
            }
        case 49: // Fragmentation unit
            guard p.count > 3 else { return }
            let fu = p[2]
            if fu & 0x80 != 0 {
                fragment = [(p[0] & 0x81) | ((fu & 0x3F) << 1), p[1]] + p[3...]
            } else if fragment != nil {
                fragment!.append(contentsOf: p[3...])
            } else {
                damaged = true
                return
            }
            if fu & 0x40 != 0, let nal = fragment {
                add(nal)
                fragment = nil
            }
        case 50: // PACI
            break
        default:
            add(p)
        }
    }

    private func add(_ nal: [UInt8]) {
        guard !nal.isEmpty, !ingestParameterSet(nal) else { return }
        switch codec {
        case .h264:
            if nal[0] & 0x1F == 5 { containsKeyframe = true }
        case .h265:
            if (16...21).contains((nal[0] >> 1) & 0x3F) { containsKeyframe = true }
        }
        nalus.append(nal)
    }

    /// Stores VPS/SPS/PPS (and swallows AUDs). Returns true if the NAL was consumed.
    private func ingestParameterSet(_ nal: [UInt8]) -> Bool {
        guard let h = nal.first else { return true }
        func store(_ slot: inout [UInt8]?) {
            if slot != nal { slot = nal; paramsChanged = true }
        }
        switch codec {
        case .h264:
            switch h & 0x1F {
            case 7: store(&sps); return true
            case 8: store(&pps); return true
            case 9: return true
            default: return false
            }
        case .h265:
            switch (h >> 1) & 0x3F {
            case 32: store(&vps); return true
            case 33: store(&sps); return true
            case 34: store(&pps); return true
            case 35: return true
            default: return false
            }
        }
    }

    private func finishAccessUnit() -> AccessUnit? {
        defer {
            nalus = []
            containsKeyframe = false
            damaged = false
            fragment = nil
        }
        guard let ts = auTimestamp, !nalus.isEmpty, !damaged else { return nil }
        if paramsChanged { rebuildFormat() }
        guard format != nil else { return nil }
        if containsKeyframe {
            needsKeyframe = false
        } else if needsKeyframe {
            return nil
        }
        return AccessUnit(nalus: nalus, timestamp: ts, isKeyframe: containsKeyframe)
    }

    private func rebuildFormat() {
        let sets: [[UInt8]]
        switch codec {
        case .h264:
            guard let sps, let pps else { return }
            sets = [sps, pps]
        case .h265:
            guard let vps, let sps, let pps else { return }
            sets = [vps, sps, pps]
        }
        let pointers = sets.map { s -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: s.count)
            p.initialize(from: s, count: s.count)
            return p
        }
        defer { pointers.forEach { $0.deallocate() } }
        let constPointers = pointers.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        var fd: CMFormatDescription?
        let status: OSStatus
        switch codec {
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                parameterSetPointers: constPointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
        case .h265:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                parameterSetPointers: constPointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fd)
        }
        if status == noErr, let fd {
            format = fd
            paramsChanged = false
        }
    }

    func sampleBuffer(for au: AccessUnit, pts: CMTime) -> CMSampleBuffer? {
        guard let format else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(au.nalus.reduce(0) { $0 + $1.count + 4 })
        for nal in au.nalus {
            let n = UInt32(nal.count)
            bytes += [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
            bytes += nal
        }
        guard let block = makeBlockBuffer(bytes) else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var size = bytes.count
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb) == noErr,
            let sb else { return nil }
        if !au.isKeyframe,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }
}

func makeBlockBuffer(_ bytes: [UInt8]) -> CMBlockBuffer? {
    guard !bytes.isEmpty else { return nil }
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
        dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag,
        blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { return nil }
    let status = bytes.withUnsafeBytes {
        CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                      offsetIntoDestination: 0, dataLength: bytes.count)
    }
    return status == kCMBlockBufferNoErr ? block : nil
}
