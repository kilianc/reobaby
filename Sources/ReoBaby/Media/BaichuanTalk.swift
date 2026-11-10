import CommonCrypto
import CryptoKit
import Foundation
import Network

/// Plays sound on a Reolink camera's speaker the way Reolink's own app does: "Baichuan", the
/// camera's native protocol on TCP port 9000. ReoBaby logs in, asks the camera how it wants
/// sound (IMA ADPCM, 16 kHz, 1024 samples a block, on Reolink's cameras), and sends one block
/// at a time in real time. The camera confirms every block, so ReoBaby never runs far ahead.
///
/// After neolink (github.com/QuantumEntangledAndy/neolink) and reolink_aio's talk support, which
/// worked the protocol out.
final class BaichuanTalk {
    enum State: Equatable {
        case connecting
        case playing
        case retrying(String)
        case failed(String)
    }

    enum Failure: Error {
        case auth
        case busy
        case message(String)
    }

    static let port: UInt16 = 9000
    /// About where a camera's tiny speaker starts to play anything.
    static let lowestFrequency = 150.0

    /// Called on main.
    var onState: ((State) -> Void)?
    /// Fills a buffer with the next samples, mono at `sampleRate`. Called on the talk queue.
    var render: ((inout [Float]) -> Void)?
    /// What the camera asked for; known once talking. Reolink cameras ask for 16 kHz.
    private(set) var sampleRate = 16000.0

    private let host: String
    private let user: String
    private let password: String
    private let queue = DispatchQueue(label: "reobaby.talk", qos: .userInteractive)
    private var connection: NWConnection?
    private var inbox: [UInt8] = []
    private var waiting: [UInt16: (Message) -> Void] = [:]
    private var nextNumber: UInt16 = 0
    private var cipher = Cipher.none
    private var running = false
    private var silent = false
    private var failures = 0
    private var timer: DispatchSourceTimer?
    private var retryWork: DispatchWorkItem?

    // Talking.
    private var talkNumber: UInt16 = 0
    private var blockSamples = 1024
    private var encoder = IMAADPCM()
    private var buffer: [Float] = []
    private var began: UInt64 = 0
    private var sentSamples = 0
    private var unacked = 0
    private var acked = false
    /// REOBABY_TALK_DEBUG: how sending keeps up, once a second.
    private var sentAt: [UInt64] = []
    private var lastTick: UInt64 = 0
    private var window = (start: UInt64(0), gap: 0.0, rtt: 0.0, minAhead: 9.0, maxUnacked: 0, skipped: 0)
    /// What TCP did in the second being measured: resent bytes tell a lossy network from a busy camera.
    private var transfer: NWConnection.PendingDataTransferReport?

    /// How far ahead of the clock sound goes out, which the camera keeps and plays from through
    /// a short hiccup. It holds only so much: sent further ahead, it drops some at the start.
    /// (Now and then it stalls for a second or two anyway, and the sound stutters; no lead helps.)
    static let lead = ProcessInfo.processInfo.environment["REOBABY_TALK_LEAD"].flatMap(Double.init) ?? 1.0
    /// Blocks sent without the camera's confirmation before ReoBaby waits for it: about 8 seconds,
    /// well past the lead and the longest stall, so it never holds sound back.
    private static let maxUnacked = 128

    init(host: String, user: String, password: String) {
        self.host = host
        self.user = user
        self.password = password
    }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            connect()
        }
    }

    /// Hangs up at once.
    func stop() {
        queue.sync {
            running = false
            hangUp(reset: true)
        }
    }

    /// Sends silence until the camera has played out what it holds, then hangs up. Fade out first:
    /// what was sent before this still plays.
    func finish(completion: (() -> Void)? = nil) {
        queue.async { [self] in
            guard running else {
                DispatchQueue.main.async { completion?() }
                return
            }
            silent = true
            queue.asyncAfter(deadline: .now() + Self.lead + 0.8) { [self] in
                running = false
                hangUp(reset: true)
                DispatchQueue.main.async { completion?() }
            }
        }
    }

    // MARK: - Connection

    private func connect() {
        report(failures == 0 ? .connecting : .retrying("Reconnecting to the speaker…"))
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 6
        tcp.noDelay = true
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: Self.port)!,
                                using: NWParameters(tls: nil, tcp: tcp))
        connection = conn
        inbox = []
        waiting = [:]
        cipher = .none
        conn.stateUpdateHandler = { [weak self] state in
            guard let self, self.connection === conn else { return }
            switch state {
            case .ready:
                self.receive()
                self.logIn()
            case .waiting(let error), .failed(let error):
                self.failed(.message("Can’t reach \(self.host)’s speaker (\(error.localizedDescription))"))
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func hangUp(reset: Bool) {
        timer?.cancel()
        timer = nil
        retryWork?.cancel()
        retryWork = nil
        guard let conn = connection else { return }
        connection = nil
        if reset, acked, conn.state == .ready {
            // TalkReset frees the speaker for other apps; then close.
            let msg = encode(id: 11, number: talkNumber, extensionXML: Self.channelExtension, payload: nil)
            conn.send(content: Data(msg), completion: .contentProcessed { _ in conn.cancel() })
        } else {
            conn.cancel()
        }
        acked = false
    }

    private func failed(_ failure: Failure) {
        guard connection != nil else { return }
        hangUp(reset: false)
        guard running else { return }
        let message: String
        switch failure {
        case .auth: message = "The camera rejected the password"
        case .busy: message = "Someone else is talking on this camera"
        case .message(let text): message = text
        }
        if case .auth = failure {
            running = false
            report(.failed(message))
            return
        }
        failures += 1
        report(.retrying(message))
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.connect()
        }
        retryWork = work
        queue.asyncAfter(deadline: .now() + min(30, pow(2, Double(min(failures, 5)))), execute: work)
    }

    private func report(_ state: State) {
        DispatchQueue.main.async { [weak self] in self?.onState?(state) }
    }

    // MARK: - Login and talk setup

    private func logIn() {
        // 1. Ask for a nonce, offering AES.
        let number = takeNumber()
        var header = Self.header(id: 1, bodyLength: 0, number: number, code: 0xdc12, messageClass: 0x6514)
        header.removeLast(4) // legacy header: 20 bytes, no payload offset
        expect(number) { [weak self] reply in self?.gotNonce(reply) }
        send(header)
    }

    private func gotNonce(_ reply: Message) {
        let xml = String(decoding: Cipher.xor.decrypt(reply.payload, offset: reply.channel), as: UTF8.self)
        guard let nonce = Self.value("nonce", in: xml) else {
            return failed(.message("The camera's speaker didn't answer as expected"))
        }
        switch reply.code & 0xff {
        case 0x02, 0x12: cipher = .aes(Self.aesKey(nonce: nonce, password: password))
        case 0x01: cipher = .xor
        default: cipher = .none
        }
        // 2. Log in with hashes of the name and password: the login body is always XOR'd.
        let login = """
        <?xml version="1.0" encoding="UTF-8" ?>
        <body>
        <LoginUser version="1.1">
        <userName>\(Self.hash(user + nonce))</userName>
        <password>\(Self.hash(password + nonce))</password>
        <userVer>1</userVer>
        </LoginUser>
        <LoginNet version="1.1">
        <type>LAN</type>
        <udpPort>0</udpPort>
        </LoginNet>
        </body>

        """
        let number = takeNumber()
        let body = Cipher.xor.encrypt(Array(login.utf8), offset: 0)
        var msg = Self.header(id: 1, bodyLength: body.count, number: number, code: 0, messageClass: 0x6414)
        msg += body
        expect(number) { [weak self] reply in
            guard let self else { return }
            guard reply.code == 200 else { return self.failed(reply.code == 401 || reply.code == 400 ? .auth : .message("Login failed (\(reply.code))")) }
            self.askAbility()
        }
        send(msg)
    }

    private func askAbility() {
        let number = takeNumber()
        expect(number) { [weak self] reply in
            guard let self else { return }
            guard reply.code == 200 else { return self.failed(.message("This camera has no speaker ReoBaby can play to (\(reply.code))")) }
            let xml = String(decoding: self.cipher.decrypt(reply.payload, offset: reply.channel), as: UTF8.self)
            self.configure(ability: xml, retried: false)
        }
        send(encode(id: 10, number: number, extensionXML: Self.channelExtension, payload: nil))
    }

    private func configure(ability xml: String, retried: Bool) {
        let rate = Self.value("sampleRate", in: xml).flatMap(Double.init) ?? 16000
        let length = Self.value("lengthPerEncoder", in: xml).flatMap(Int.init) ?? 1024
        let duplex = Self.value("duplex", in: xml) ?? "FDX"
        let mode = Self.value("audioStreamMode", in: xml) ?? "followVideoStream"
        sampleRate = rate
        blockSamples = length
        let config = """
        <?xml version="1.0" encoding="UTF-8" ?>
        <body>
        <TalkConfig version="1.1">
        <channelId>0</channelId>
        <duplex>\(duplex)</duplex>
        <audioStreamMode>\(mode)</audioStreamMode>
        <audioConfig>
        <audioType>adpcm</audioType>
        <sampleRate>\(Int(rate))</sampleRate>
        <samplePrecision>16</samplePrecision>
        <lengthPerEncoder>\(length)</lengthPerEncoder>
        <soundTrack>mono</soundTrack>
        </audioConfig>
        </TalkConfig>
        </body>

        """
        let number = takeNumber()
        expect(number) { [weak self] reply in
            guard let self else { return }
            if reply.code == 422 || reply.code == 421 {
                // Busy: maybe our own last session. Reset it once and try again.
                guard !retried else { return self.failed(.busy) }
                self.send(self.encode(id: 11, number: self.takeNumber(), extensionXML: Self.channelExtension, payload: nil))
                self.queue.asyncAfter(deadline: .now() + 0.5) { self.configure(ability: xml, retried: true) }
                return
            }
            guard reply.code == 200 else { return self.failed(.message("The camera's speaker refused (\(reply.code))")) }
            self.startTalking()
        }
        send(encode(id: 201, number: number, extensionXML: Self.channelExtension, payload: Array(config.utf8)))
    }

    // MARK: - Talking

    private func startTalking() {
        acked = true
        talkNumber = takeNumber()
        // Every block's confirmation comes back with the session's number.
        waiting[talkNumber] = nil
        encoder = IMAADPCM()
        buffer = []
        unacked = 0
        sentSamples = 0
        began = DispatchTime.now().uptimeNanoseconds
        transfer = nil
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func tick() {
        guard running, connection != nil else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = Double(now - began) / 1e9
        let due = Int((elapsed + Self.lead) * sampleRate)
        let perBlock = blockSamples + 1
        // After a long stall (a sleeping Mac), skip ahead rather than send a burst.
        if due - sentSamples > Int(Self.lead * sampleRate) + perBlock * 8 {
            sentSamples = due - Int(Self.lead * sampleRate)
            window.skipped += 1
        }
        while sentSamples + perBlock <= due, unacked < Self.maxUnacked {
            if buffer.count != perBlock { buffer = [Float](repeating: 0, count: perBlock) }
            if silent {
                for i in buffer.indices { buffer[i] = 0 }
            } else {
                render?(&buffer)
            }
            let block = encoder.encode(buffer)
            send(encode(id: 202, number: talkNumber, extensionXML: Self.dataExtension, payload: Self.frame(block), encryptPayload: false))
            unacked += 1
            sentSamples += perBlock
            if Self.debug { sentAt.append(now) }
            if sentSamples == perBlock {
                failures = 0
                report(.playing)
            }
        }
        if Self.debug { measure(now: now, elapsed: elapsed) }
    }

    private func measure(now: UInt64, elapsed: Double) {
        if lastTick > 0 { window.gap = max(window.gap, Double(now - lastTick) / 1e9) }
        lastTick = now
        if window.start == 0 { window.start = now }
        window.minAhead = min(window.minAhead, Double(sentSamples) / sampleRate - elapsed)
        window.maxUnacked = max(window.maxUnacked, unacked)
        guard now - window.start >= 1_000_000_000 else { return }
        let line = String(format: "talk %6.1fs  tick gap %3.0f ms  ack rtt %4.0f ms  ahead ≥ %4.0f ms  unacked ≤ %2d%@", elapsed,
                          window.gap * 1000, window.rtt * 1000, window.minAhead * 1000, window.maxUnacked,
                          window.skipped > 0 ? "  SKIPPED \(window.skipped)" : "")
        window = (now, 0, 0, 9, 0, 0)
        if let transfer {
            transfer.collect(queue: queue) { report in
                let path = report.aggregatePathReport
                print(line + String(format: "  tcp resent %4d B  dup %4d B  rtt %3.0f ms", path.retransmittedTransportByteCount,
                                    path.receivedTransportDuplicateByteCount, path.transportSmoothedRTT * 1000))
            }
        } else {
            print(line)
        }
        transfer = connection?.startDataTransferReport()
    }

    /// A block of ADPCM in Reolink's media framing ("01wb", an audio frame).
    private static func frame(_ block: [UInt8]) -> [UInt8] {
        let size = UInt16(block.count + 4)
        var f: [UInt8] = Array("01wb".utf8)
        f += size.littleEndianBytes + size.littleEndianBytes
        f += UInt16(0x0100).littleEndianBytes + UInt16(2).littleEndianBytes
        f += block
        while f.count % 8 != 0 { f.append(0) }
        return f
    }

    // MARK: - Messages

    struct Message {
        var id: UInt32
        var channel: UInt8
        var number: UInt16
        var code: UInt16
        var messageClass: UInt16
        var extensionBytes: [UInt8]
        var payload: [UInt8]
    }

    private static let channelExtension = """
    <?xml version="1.0" encoding="UTF-8" ?>
    <Extension version="1.1">
    <channelId>0</channelId>
    </Extension>

    """

    private static let dataExtension = """
    <?xml version="1.0" encoding="UTF-8" ?>
    <Extension version="1.1">
    <binaryData>1</binaryData>
    <channelId>0</channelId>
    </Extension>

    """

    private func takeNumber() -> UInt16 {
        nextNumber &+= 1
        return nextNumber
    }

    private func expect(_ number: UInt16, _ handler: @escaping (Message) -> Void) {
        waiting[number] = handler
    }

    /// A modern message: 24-byte header, then the extension XML, then the payload.
    private func encode(id: UInt32, number: UInt16, extensionXML: String, payload: [UInt8]?, encryptPayload: Bool = true) -> [UInt8] {
        let ext = cipher.encrypt(Array(extensionXML.utf8), offset: 0)
        let body = payload.map { encryptPayload ? cipher.encrypt($0, offset: 0) : $0 } ?? []
        var msg = Self.header(id: id, bodyLength: ext.count + body.count, number: number, code: 0, messageClass: 0x6414,
                              payloadOffset: UInt32(ext.count))
        msg += ext
        msg += body
        return msg
    }

    private static func header(id: UInt32, bodyLength: Int, number: UInt16, code: UInt16, messageClass: UInt16,
                               payloadOffset: UInt32 = 0) -> [UInt8] {
        var h: [UInt8] = UInt32(0x0abcdef0).littleEndianBytes
        h += id.littleEndianBytes
        h += UInt32(bodyLength).littleEndianBytes
        h += [0, 0] // channel 0 (also the XOR offset), stream 0
        h += number.littleEndianBytes
        h += code.littleEndianBytes
        h += messageClass.littleEndianBytes
        h += payloadOffset.littleEndianBytes
        return h
    }

    private func send(_ bytes: [UInt8]) {
        connection?.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            guard let self, let error else { return }
            self.queue.async { self.failed(.message("Send failed (\(error.localizedDescription))")) }
        })
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, self.connection != nil else { return }
            if let data, !data.isEmpty {
                self.inbox += data
                self.parse()
            }
            if let error {
                self.failed(.message("Connection lost (\(error.localizedDescription))"))
            } else if isComplete {
                self.failed(.message("The camera closed the connection"))
            } else {
                self.receive()
            }
        }
    }

    private func parse() {
        while inbox.count >= 20 {
            let magic = UInt32(littleEndianBytes: inbox[0..<4])
            guard magic == 0x0abcdef0 || magic == 0x0fedcba0 else {
                return failed(.message("The camera's speaker sent something unexpected"))
            }
            let messageClass = UInt16(littleEndianBytes: inbox[18..<20])
            let hasOffset = messageClass == 0x6414 || messageClass == 0x0000
            let headerLength = hasOffset ? 24 : 20
            let bodyLength = Int(UInt32(littleEndianBytes: inbox[8..<12]))
            guard inbox.count >= headerLength + bodyLength else { return }
            let offset = hasOffset ? min(Int(UInt32(littleEndianBytes: inbox[20..<24])), bodyLength) : 0
            let body = Array(inbox[headerLength..<headerLength + bodyLength])
            let message = Message(id: UInt32(littleEndianBytes: inbox[4..<8]), channel: inbox[12],
                                  number: UInt16(littleEndianBytes: inbox[14..<16]),
                                  code: UInt16(littleEndianBytes: inbox[16..<18]), messageClass: messageClass,
                                  extensionBytes: Array(body[..<offset]), payload: Array(body[offset...]))
            inbox.removeFirst(headerLength + bodyLength)
            handle(message)
        }
    }

    private static let debug = ProcessInfo.processInfo.environment["REOBABY_TALK_DEBUG"] != nil

    private func handle(_ message: Message) {
        if Self.debug, !(message.id == 202 && acked) {
            let text = String(decoding: cipher.decrypt(message.payload, offset: message.channel), as: UTF8.self)
            print(String(format: "talk ← msg %d #%d code %d (0x%04x) class 0x%04x ext %d payload %d", message.id, message.number,
                         message.code, message.code, message.messageClass, message.extensionBytes.count, message.payload.count)
                  + (text.contains("<") ? "\n" + text.prefix(600) : ""))
        }
        if message.id == 202, message.number == talkNumber, acked {
            unacked = max(0, unacked - 1)
            if Self.debug, !sentAt.isEmpty {
                window.rtt = max(window.rtt, Double(DispatchTime.now().uptimeNanoseconds - sentAt.removeFirst()) / 1e9)
            }
            return
        }
        waiting.removeValue(forKey: message.number)?(message)
    }

    // MARK: - Helpers

    /// Uppercase hex MD5, cut to 31 characters, as the camera compares it.
    static func hash(_ text: String) -> String {
        String(Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02X", $0) }.joined().prefix(31))
    }

    static func aesKey(nonce: String, password: String) -> [UInt8] {
        let hex = Insecure.MD5.hash(data: Data("\(nonce)-\(password)".utf8)).map { String(format: "%02X", $0) }.joined()
        return Array(hex.utf8.prefix(16))
    }

    static func value(_ tag: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(tag)>"), let end = xml.range(of: "</\(tag)>", range: start.upperBound..<xml.endIndex) else {
            return nil
        }
        return String(xml[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// How Baichuan scrambles message bodies.
enum Cipher {
    case none
    case xor
    case aes([UInt8])

    private static let key: [UInt8] = [0x1F, 0x2D, 0x3C, 0x4B, 0x5A, 0x69, 0x78, 0xFF]

    func encrypt(_ bytes: [UInt8], offset: UInt8) -> [UInt8] { crypt(bytes, offset: offset, operation: CCOperation(kCCEncrypt)) }
    func decrypt(_ bytes: [UInt8], offset: UInt8) -> [UInt8] { crypt(bytes, offset: offset, operation: CCOperation(kCCDecrypt)) }

    private func crypt(_ bytes: [UInt8], offset: UInt8, operation: CCOperation) -> [UInt8] {
        switch self {
        case .none:
            return bytes
        case .xor:
            return bytes.enumerated().map { i, b in b ^ Self.key[(Int(offset) + i) % 8] ^ offset }
        case .aes(let key):
            guard !bytes.isEmpty else { return bytes }
            // AES-128 in 128-bit cipher feedback, starting afresh from the same IV every time.
            let iv = Array("0123456789abcdef".utf8)
            var cryptor: CCCryptorRef?
            guard CCCryptorCreateWithMode(operation, CCMode(kCCModeCFB), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                                          iv, key, key.count, nil, 0, 0, 0, &cryptor) == kCCSuccess, let cryptor else { return bytes }
            defer { CCCryptorRelease(cryptor) }
            var out = [UInt8](repeating: 0, count: bytes.count)
            var moved = 0
            CCCryptorUpdate(cryptor, bytes, bytes.count, &out, out.count, &moved)
            return out
        }
    }
}

/// IMA ADPCM, as Reolink's cameras take it: blocks that start with the first sample and the
/// step index, then one 4-bit code per further sample, the first of each pair in the high nibble.
struct IMAADPCM {
    private static let steps: [Int] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97,
        107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
        876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871,
        5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623,
        27086, 29794, 32767,
    ]
    private static let indexChange: [Int] = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8]

    private var predictor = 0
    private var index = 0

    /// One block from `samples`: the first goes in the header, the rest (an even count) as codes.
    mutating func encode(_ samples: [Float]) -> [UInt8] {
        let pcm = samples.map { Int(max(-1, min(1, $0)) * 32767) }
        predictor = pcm[0]
        var block = Int16(pcm[0]).littleEndianBytes + [UInt8(index), 0]
        var i = 1
        while i + 1 < pcm.count {
            let high = code(pcm[i]), low = code(pcm[i + 1])
            block.append(high << 4 | low)
            i += 2
        }
        return block
    }

    private mutating func code(_ sample: Int) -> UInt8 {
        var step = Self.steps[index]
        var diff = sample - predictor
        var nibble = 0
        if diff < 0 { nibble = 8; diff = -diff }
        var delta = step >> 3
        if diff >= step { nibble |= 4; diff -= step; delta += step }
        step >>= 1
        if diff >= step { nibble |= 2; diff -= step; delta += step }
        step >>= 1
        if diff >= step { nibble |= 1; delta += step }
        predictor += nibble & 8 != 0 ? -delta : delta
        predictor = max(-32768, min(32767, predictor))
        index = max(0, min(88, index + Self.indexChange[nibble]))
        return UInt8(nibble)
    }
}

extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] { withUnsafeBytes(of: littleEndian) { Array($0) } }

    init<C: Collection>(littleEndianBytes bytes: C) where C.Element == UInt8 {
        var value: Self = 0
        for (i, b) in bytes.enumerated() { value |= Self(b) << (8 * i) }
        self = value
    }
}
