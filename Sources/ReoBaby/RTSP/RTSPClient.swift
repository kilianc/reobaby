import CryptoKit
import Foundation
import Network

/// rtsp://[user[:password]@]host[:port]/path, with credentials split out.
struct RTSPEndpoint: Equatable {
    var host: String
    var port: UInt16
    var user: String?
    var password: String?
    /// Request URI without credentials.
    var uri: String

    /// Everything before the last "@" is userinfo, so passwords containing
    /// unescaped "@", "/" or ":" still parse.
    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("rtsp://") else { return nil }
        var rest = String(trimmed.dropFirst(7))
        var userinfo: String?
        if let at = rest.lastIndex(of: "@") {
            userinfo = String(rest[..<at])
            rest = String(rest[rest.index(after: at)...])
        }
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        let hostport = String(rest[..<slash])
        let path = String(rest[slash...])
        var h = hostport
        var p: UInt16 = 554
        if let colon = hostport.lastIndex(of: ":"), !hostport.hasSuffix("]") {
            h = String(hostport[..<colon])
            guard let parsed = UInt16(hostport[hostport.index(after: colon)...]) else { return nil }
            p = parsed
        }
        h = h.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !h.isEmpty else { return nil }
        if let ui = userinfo {
            func decode(_ s: Substring) -> String { String(s).removingPercentEncoding ?? String(s) }
            if let c = ui.firstIndex(of: ":") {
                user = decode(ui[..<c])
                password = decode(ui[ui.index(after: c)...])
            } else {
                user = decode(ui[...])
            }
        }
        host = h
        port = p
        uri = "rtsp://\(hostport)\(path.isEmpty ? "/" : path)"
    }
}

struct RTSPResponse {
    var status: Int
    var reason: String
    var headers: [(String, String)]
    var body: [UInt8]

    func header(_ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    func allHeaders(_ name: String) -> [String] {
        headers.filter { $0.0.caseInsensitiveCompare(name) == .orderedSame }.map(\.1)
    }
}

struct AuthChallenge {
    let scheme: String
    let params: [String: String]

    init?(_ header: String) {
        let s = header.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        guard let sp = s.firstIndex(of: " ") else {
            scheme = s.lowercased()
            params = [:]
            return
        }
        scheme = s[..<sp].lowercased()
        var params: [String: String] = [:]
        let chars = Array(s[s.index(after: sp)...])
        var i = 0
        while i < chars.count {
            while i < chars.count, chars[i] == " " || chars[i] == "," { i += 1 }
            var key = ""
            while i < chars.count, chars[i] != "=" { key.append(chars[i]); i += 1 }
            i += 1
            var value = ""
            if i < chars.count, chars[i] == "\"" {
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count { i += 1 }
                    value.append(chars[i])
                    i += 1
                }
                i += 1
            } else {
                while i < chars.count, chars[i] != "," { value.append(chars[i]); i += 1 }
            }
            let k = key.trimmingCharacters(in: .whitespaces).lowercased()
            if !k.isEmpty { params[k] = value.trimmingCharacters(in: .whitespaces) }
        }
        self.params = params
    }
}

/// Minimal RTSP/1.0 client: DESCRIBE → SETUP (RTP interleaved over TCP) → PLAY,
/// Basic/Digest auth, keepalives. All callbacks run on `queue`.
final class RTSPClient {
    struct Track {
        let media: MediaDescription
        let channel: UInt8
    }

    enum Failure: Error {
        case auth
        case message(String)
    }

    var onTracks: (([Track]) -> Void)?
    var onRTP: ((Int, RTPPacket) -> Void)?
    var onFailure: ((Failure) -> Void)?

    private let endpoint: RTSPEndpoint
    private let queue: DispatchQueue
    private let wantsVideo: Bool
    private var connection: NWConnection?
    private var buffer: [UInt8] = []
    private var readIndex = 0
    private var cseq = 0
    private var pending: [Int: (RTSPResponse) -> Void] = [:]
    private var challenge: AuthChallenge?
    private var nonceCount = 0
    private var sessionID: String?
    private var sessionTimeout = 60
    private var keepalive: DispatchSourceTimer?
    private var baseURI = ""
    private var playURI = ""
    private var describeURIs: [String] = []
    private var chosen: [MediaDescription] = []
    private var tracks: [Track] = []
    private var channelToTrack: [UInt8: Int] = [:]
    private var stopped = false

    /// `wantsVideo: false` sets up only the audio track (used for sound monitoring).
    init(endpoint: RTSPEndpoint, queue: DispatchQueue, wantsVideo: Bool = true) {
        self.endpoint = endpoint
        self.queue = queue
        self.wantsVideo = wantsVideo
        describeURIs = [endpoint.uri] + Self.reolinkAlternates(endpoint.uri)
    }

    /// Reolink firmwares disagree on h264Preview_/h265Preview_/Preview_ prefixes;
    /// on 404 we try the siblings.
    private static func reolinkAlternates(_ uri: String) -> [String] {
        let pattern = #"/(h264|h265)?Preview_(\d+)_(main|sub|ext)"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: uri, range: NSRange(uri.startIndex..., in: uri)),
              let r = Range(m.range, in: uri),
              let ch = Range(m.range(at: 2), in: uri),
              let kind = Range(m.range(at: 3), in: uri) else { return [] }
        let suffix = "Preview_\(uri[ch])_\(uri[kind])"
        return ["/\(suffix)", "/h264\(suffix)", "/h265\(suffix)"]
            .map { uri.replacingCharacters(in: r, with: $0) }
            .filter { $0 != uri }
    }

    func start() {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 6
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            fail(.message("Invalid port"))
            return
        }
        let conn = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: params)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self, !self.stopped else { return }
            switch state {
            case .ready:
                self.receive()
                self.describe()
            case .waiting(let error), .failed(let error):
                if case .posix(.ENETDOWN) = error {
                    // What macOS reports when Local Network access is denied or not yet granted.
                    self.fail(.message("ReoBaby needs Local Network access\nSystem Settings ▸ Privacy & Security ▸ Local Network"))
                } else {
                    self.fail(.message("Can’t reach \(self.endpoint.host) (\(error.localizedDescription))"))
                }
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        keepalive?.cancel()
        keepalive = nil
        pending.removeAll()
        guard let conn = connection else { return }
        connection = nil
        if sessionID != nil, conn.state == .ready {
            let msg = buildRequest("TEARDOWN", playURI, headers: [])
            conn.send(content: msg, completion: .contentProcessed { _ in conn.cancel() })
        } else {
            conn.cancel()
        }
    }

    // MARK: - Flow

    private func describe() {
        guard !describeURIs.isEmpty else {
            fail(.message("Stream not found on camera (404)"))
            return
        }
        let uri = describeURIs.removeFirst()
        request("DESCRIBE", uri, headers: [("Accept", "application/sdp")]) { [weak self] resp in
            guard let self else { return }
            if resp.status == 404 {
                self.describe()
                return
            }
            guard resp.status == 200 else {
                self.fail(.message("DESCRIBE failed: \(resp.status) \(resp.reason)"))
                return
            }
            self.baseURI = resp.header("Content-Base") ?? resp.header("Content-Location") ?? uri
            let sdp = SessionDescription(String(decoding: resp.body, as: UTF8.self))
            var picked: [MediaDescription] = []
            if self.wantsVideo, let v = sdp.media.first(where: \.isSupportedVideo) { picked.append(v) }
            if let a = sdp.media.first(where: \.isSupportedAudio) { picked.append(a) }
            guard !picked.isEmpty else {
                let found = sdp.media.map(\.summary).joined(separator: ", ")
                self.fail(.message("Unsupported stream (\(found.isEmpty ? "no media" : found))"))
                return
            }
            self.chosen = picked
            self.playURI = self.resolve(sdp.control)
            self.setup(0)
        }
    }

    private func setup(_ index: Int) {
        let media = chosen[index]
        let ch = UInt8(index * 2)
        let transport = "RTP/AVP/TCP;unicast;interleaved=\(ch)-\(ch + 1)"
        request("SETUP", resolve(media.control), headers: [("Transport", transport)]) { [weak self] resp in
            guard let self else { return }
            guard resp.status == 200 else {
                self.fail(.message("SETUP failed: \(resp.status) \(resp.reason)"))
                return
            }
            if self.sessionID == nil, let s = resp.header("Session") {
                let parts = s.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                self.sessionID = parts.first
                for p in parts.dropFirst() where p.lowercased().hasPrefix("timeout=") {
                    self.sessionTimeout = Int(p.dropFirst(8)) ?? 60
                }
            }
            var actual = ch
            if let t = resp.header("Transport"),
               let r = t.range(of: "interleaved=") {
                let digits = t[r.upperBound...].prefix { $0.isNumber }
                actual = UInt8(digits) ?? ch
            }
            self.tracks.append(Track(media: media, channel: actual))
            self.channelToTrack[actual] = self.tracks.count - 1
            if index + 1 < self.chosen.count {
                self.setup(index + 1)
            } else {
                self.play()
            }
        }
    }

    private func play() {
        onTracks?(tracks)
        request("PLAY", playURI, headers: [("Range", "npt=0.000-")]) { [weak self] resp in
            guard let self else { return }
            guard resp.status == 200 else {
                self.fail(.message("PLAY failed: \(resp.status) \(resp.reason)"))
                return
            }
            self.startKeepalive()
        }
    }

    private func startKeepalive() {
        let interval = max(5.0, Double(sessionTimeout) / 2.0)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.request("GET_PARAMETER", self.playURI, headers: []) { _ in }
        }
        t.resume()
        keepalive = t
    }

    private func resolve(_ control: String?) -> String {
        guard let c = control, !c.isEmpty, c != "*" else { return baseURI }
        if c.lowercased().hasPrefix("rtsp://") { return c }
        return baseURI.hasSuffix("/") ? baseURI + c : baseURI + "/" + c
    }

    private func fail(_ failure: Failure) {
        guard !stopped else { return }
        stop()
        onFailure?(failure)
    }

    // MARK: - Requests

    private func request(_ method: String, _ uri: String, headers: [(String, String)],
                         canRetryAuth: Bool = true, completion: @escaping (RTSPResponse) -> Void) {
        guard let conn = connection, !stopped else { return }
        let msg = buildRequest(method, uri, headers: headers)
        pending[cseq] = { [weak self] resp in
            guard let self else { return }
            if resp.status == 401 {
                let challenges = resp.allHeaders("WWW-Authenticate").compactMap(AuthChallenge.init)
                let next = challenges.first { $0.scheme == "digest" } ?? challenges.first { $0.scheme == "basic" }
                if canRetryAuth, let next, self.endpoint.user != nil {
                    self.challenge = next
                    self.nonceCount = 0
                    self.request(method, uri, headers: headers, canRetryAuth: false, completion: completion)
                } else {
                    self.fail(.auth)
                }
                return
            }
            completion(resp)
        }
        conn.send(content: msg, completion: .contentProcessed { [weak self] error in
            guard let self, let error else { return }
            self.fail(.message("Send failed (\(error.localizedDescription))"))
        })
    }

    private func buildRequest(_ method: String, _ uri: String, headers: [(String, String)]) -> Data {
        cseq += 1
        var s = "\(method) \(uri) RTSP/1.0\r\nCSeq: \(cseq)\r\nUser-Agent: ReoBaby/1.0\r\n"
        if let auth = authorization(method: method, uri: uri) { s += "Authorization: \(auth)\r\n" }
        if let sid = sessionID { s += "Session: \(sid)\r\n" }
        for (k, v) in headers { s += "\(k): \(v)\r\n" }
        s += "\r\n"
        return Data(s.utf8)
    }

    private func authorization(method: String, uri: String) -> String? {
        guard let ch = challenge, let user = endpoint.user else { return nil }
        let pass = endpoint.password ?? ""
        if ch.scheme == "basic" {
            return "Basic " + Data("\(user):\(pass)".utf8).base64EncodedString()
        }
        guard ch.scheme == "digest" else { return nil }
        func md5(_ s: String) -> String {
            Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let realm = ch.params["realm"] ?? ""
        let nonce = ch.params["nonce"] ?? ""
        let ha1 = md5("\(user):\(realm):\(pass)")
        let ha2 = md5("\(method):\(uri)")
        var parts = ["username=\"\(user)\"", "realm=\"\(realm)\"", "nonce=\"\(nonce)\"", "uri=\"\(uri)\""]
        let qops = (ch.params["qop"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if qops.contains("auth") {
            nonceCount += 1
            let nc = String(format: "%08x", nonceCount)
            let cnonce = (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            parts.append("response=\"\(md5("\(ha1):\(nonce):\(nc):\(cnonce):auth:\(ha2)"))\"")
            parts += ["qop=auth", "nc=\(nc)", "cnonce=\"\(cnonce)\""]
        } else {
            parts.append("response=\"\(md5("\(ha1):\(nonce):\(ha2)"))\"")
        }
        if let opaque = ch.params["opaque"] { parts.append("opaque=\"\(opaque)\"") }
        if let alg = ch.params["algorithm"] { parts.append("algorithm=\(alg)") }
        return "Digest " + parts.joined(separator: ", ")
    }

    // MARK: - Reading

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.stopped else { return }
            if let data, !data.isEmpty {
                self.buffer.append(contentsOf: data)
                self.parse()
            }
            if let error {
                self.fail(.message("Connection lost (\(error.localizedDescription))"))
            } else if isComplete {
                self.fail(.message("Camera closed the connection"))
            } else {
                self.receive()
            }
        }
    }

    private func parse() {
        while !stopped {
            let available = buffer.count - readIndex
            guard available > 0 else { break }
            let first = buffer[readIndex]
            if first == 0x24 { // '$' interleaved binary frame
                guard available >= 4 else { break }
                let channel = buffer[readIndex + 1]
                let length = Int(buffer[readIndex + 2]) << 8 | Int(buffer[readIndex + 3])
                guard available >= 4 + length else { break }
                let start = readIndex + 4
                readIndex = start + length
                if let track = channelToTrack[channel], let packet = RTPPacket(Array(buffer[start..<start + length])) {
                    onRTP?(track, packet)
                }
            } else if (65...90).contains(first) { // 'A'...'Z': RTSP response or server request
                guard let headerEnd = findHeaderEnd() else {
                    if available > 64 * 1024 { readIndex += 1 } // garbage; resync
                    break
                }
                let text = String(decoding: buffer[readIndex..<headerEnd], as: UTF8.self)
                var lines = text.components(separatedBy: "\r\n")
                let statusLine = lines.removeFirst()
                var headers: [(String, String)] = []
                for line in lines {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    headers.append((String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                                    String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
                }
                let contentLength = headers.first { $0.0.lowercased() == "content-length" }.flatMap { Int($0.1) } ?? 0
                let bodyStart = headerEnd + 4
                guard buffer.count >= bodyStart + contentLength else { break }
                let body = Array(buffer[bodyStart..<bodyStart + contentLength])
                readIndex = bodyStart + contentLength
                guard statusLine.hasPrefix("RTSP/") else { continue } // ignore server→client requests
                let parts = statusLine.split(separator: " ", maxSplits: 2)
                let status = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
                let reason = parts.count > 2 ? String(parts[2]) : ""
                let response = RTSPResponse(status: status, reason: reason, headers: headers, body: body)
                let seq = headers.first { $0.0.lowercased() == "cseq" }.flatMap { Int($0.1) } ?? -1
                if let handler = pending.removeValue(forKey: seq) { handler(response) }
            } else {
                readIndex += 1 // resync
            }
        }
        if readIndex > 0 && (readIndex >= buffer.count || readIndex > 1 << 20) {
            buffer.removeFirst(readIndex)
            readIndex = 0
        }
    }

    private func findHeaderEnd() -> Int? {
        var i = readIndex
        let n = buffer.count
        while i + 3 < n {
            if buffer[i] == 13 && buffer[i + 1] == 10 && buffer[i + 2] == 13 && buffer[i + 3] == 10 { return i }
            i += 1
        }
        return nil
    }
}
