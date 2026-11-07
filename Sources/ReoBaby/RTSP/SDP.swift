import Foundation

struct MediaDescription {
    var kind: String
    var payloadType: Int
    var encoding = ""
    var clockRate = 0
    var channels = 1
    var fmtp: [String: String] = [:]
    var control: String?

    var isSupportedVideo: Bool {
        kind == "video" && ["H264", "H265", "HEVC"].contains(encoding)
    }

    var isSupportedAudio: Bool {
        guard kind == "audio" else { return false }
        if encoding == "PCMA" || encoding == "PCMU" { return true }
        return encoding == "MPEG4-GENERIC" && fmtp["config"] != nil
    }

    var summary: String {
        "\(kind) \(encoding)/\(clockRate)\(kind == "audio" ? "/\(channels)" : "")"
    }
}

struct SessionDescription {
    var control: String?
    var media: [MediaDescription] = []

    init(_ text: String) {
        var current: MediaDescription?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("m=") {
                if let c = current { media.append(c) }
                let parts = line.dropFirst(2).split(separator: " ")
                let pt = parts.count > 3 ? Int(parts[3]) ?? -1 : -1
                var m = MediaDescription(kind: parts.first.map(String.init) ?? "", payloadType: pt)
                // Static payload types that may appear without an rtpmap line.
                if pt == 0 { m.encoding = "PCMU"; m.clockRate = 8000 }
                if pt == 8 { m.encoding = "PCMA"; m.clockRate = 8000 }
                current = m
            } else if line.hasPrefix("a=") {
                let attr = line.dropFirst(2)
                guard let colon = attr.firstIndex(of: ":") else { continue }
                let key = attr[..<colon].lowercased()
                let value = String(attr[attr.index(after: colon)...])
                switch key {
                case "control":
                    if current != nil { current!.control = value } else { control = value }
                case "rtpmap":
                    guard current != nil, let sp = value.firstIndex(of: " "),
                          Int(value[..<sp]) == current!.payloadType else { continue }
                    let enc = value[value.index(after: sp)...].split(separator: "/")
                    guard !enc.isEmpty else { continue }
                    current!.encoding = enc[0].uppercased()
                    if enc.count > 1 { current!.clockRate = Int(enc[1]) ?? 0 }
                    if enc.count > 2 { current!.channels = Int(enc[2]) ?? 1 }
                case "fmtp":
                    guard current != nil, let sp = value.firstIndex(of: " "),
                          Int(value[..<sp]) == current!.payloadType else { continue }
                    for pair in value[value.index(after: sp)...].split(separator: ";") {
                        let kv = pair.trimmingCharacters(in: .whitespaces)
                        guard let eq = kv.firstIndex(of: "=") else { continue }
                        current!.fmtp[kv[..<eq].lowercased()] =
                            String(kv[kv.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                    }
                default:
                    break
                }
            }
        }
        if let c = current { media.append(c) }
    }
}
