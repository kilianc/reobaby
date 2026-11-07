import Foundation

/// One RTP packet (RFC 3550) with header fields parsed and the payload copied out.
struct RTPPacket {
    let marker: Bool
    let payloadType: UInt8
    let sequence: UInt16
    let timestamp: UInt32
    let payload: [UInt8]

    init?(_ b: [UInt8]) {
        guard b.count >= 12, b[0] >> 6 == 2 else { return nil }
        let hasPadding = b[0] & 0x20 != 0
        let hasExtension = b[0] & 0x10 != 0
        let csrcCount = Int(b[0] & 0x0F)
        marker = b[1] & 0x80 != 0
        payloadType = b[1] & 0x7F
        sequence = UInt16(b[2]) << 8 | UInt16(b[3])
        timestamp = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])
        var offset = 12 + csrcCount * 4
        if hasExtension {
            guard b.count >= offset + 4 else { return nil }
            let words = Int(b[offset + 2]) << 8 | Int(b[offset + 3])
            offset += 4 + words * 4
        }
        var end = b.count
        if hasPadding, let pad = b.last { end -= Int(pad) }
        guard offset <= end else { return nil }
        payload = Array(b[offset..<end])
    }
}

/// Unwraps 32-bit RTP timestamps into a monotonic 64-bit counter.
struct RTPTimeline {
    let clockRate: Int32
    private var last: UInt32?
    private var extended: Int64 = 0

    init(clockRate: Int) {
        self.clockRate = Int32(max(clockRate, 1))
    }

    mutating func unwrap(_ ts: UInt32) -> Int64 {
        if let last {
            extended += Int64(Int32(bitPattern: ts &- last))
        } else {
            extended = Int64(ts)
        }
        last = ts
        return extended
    }
}

struct BitReader {
    private let bytes: [UInt8]
    private var bit = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func read(_ n: Int) -> Int {
        var value = 0
        for _ in 0..<n {
            let index = bit >> 3
            let b = index < bytes.count ? Int(bytes[index] >> UInt8(7 - (bit & 7))) & 1 : 0
            value = value << 1 | b
            bit += 1
        }
        return value
    }
}

extension Array where Element == UInt8 {
    init?(hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 65...70: return c - 55
            case 97...102: return c - 87
            default: return nil
            }
        }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        self = out
    }

    /// Base64 decode that tolerates missing padding (common in SDP sprop values).
    init?(base64Unpadded s: String) {
        var str = s.trimmingCharacters(in: .whitespaces)
        while str.count % 4 != 0 { str += "=" }
        guard let data = Data(base64Encoded: str) else { return nil }
        self = [UInt8](data)
    }
}
