import Foundation
#if canImport(Network)
import Network
#elseif canImport(Glibc)
import Glibc
#endif

/// A TCP connection to a camera, as RTSP and Reolink's talk protocol use it: Network.framework on
/// Apple platforms, a POSIX socket served by two threads elsewhere. Handlers run on the queue
/// passed to `start`.
public final class TCPConnection: @unchecked Sendable {
    public enum State: Equatable {
        case ready
        /// Couldn't connect, or the connection broke. On macOS it may come back by itself.
        case failed(TCPError)
    }

    public struct TCPError: Error, Equatable, CustomStringConvertible, LocalizedError {
        /// The POSIX error number, or 0 when there isn't one.
        public let code: Int32
        public let message: String
        /// What macOS reports when Local Network access is denied or not yet granted.
        public var isNetworkDown: Bool { code == ENETDOWN }
        public var description: String { message }
        public var errorDescription: String? { message }

        init(code: Int32, message: String) {
            self.code = code
            self.message = message
        }

        init(errno code: Int32) {
            self.init(code: code, message: String(cString: strerror(code)))
        }
    }

    public var stateUpdateHandler: ((State) -> Void)?

#if canImport(Network)
    /// The connection itself, for what only Network.framework offers (transfer reports).
    public let network: NWConnection

    /// Nil when the port is 0.
    public init?(host: String, port: UInt16, connectionTimeout: Int = 6) {
        guard let port = NWEndpoint.Port(rawValue: port) else { return nil }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = connectionTimeout
        tcp.noDelay = true
        network = NWConnection(host: NWEndpoint.Host(host), port: port, using: NWParameters(tls: nil, tcp: tcp))
    }

    public var isReady: Bool { network.state == .ready }

    public func start(queue: DispatchQueue) {
        network.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.stateUpdateHandler?(.ready)
            case .waiting(let error), .failed(let error):
                self.stateUpdateHandler?(.failed(TCPError(error)))
            default:
                break
            }
        }
        network.start(queue: queue)
    }

    public func send(_ data: Data, completion: ((TCPError?) -> Void)? = nil) {
        network.send(content: data, completion: .contentProcessed { error in completion?(error.map(TCPError.init)) })
    }

    /// Whatever has arrived, up to `maximumLength` bytes; `isComplete` once the camera closed.
    public func receive(maximumLength: Int, completion: @escaping (Data?, _ isComplete: Bool, TCPError?) -> Void) {
        network.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
            completion(data, isComplete, error.map(TCPError.init))
        }
    }

    public func cancel() {
        network.cancel()
    }
#else
    private let host: String
    private let port: UInt16
    private let timeout: Int
    private let reading = DispatchQueue(label: "TCPConnection.reading")
    private let writing = DispatchQueue(label: "TCPConnection.writing")
    private let lock = NSLock()
    private var socket: Int32 = -1
    private var cancelled = false
    private var queue = DispatchQueue.main

    /// Nil when the port is 0.
    public init?(host: String, port: UInt16, connectionTimeout: Int = 6) {
        guard port != 0 else { return nil }
        self.host = host
        self.port = port
        timeout = connectionTimeout
    }

    public var isReady: Bool { lock.withLock { socket >= 0 && !cancelled } }

    public func start(queue: DispatchQueue) {
        self.queue = queue
        reading.async { [self] in
            let result = Self.connect(host: host, port: port, timeout: timeout)
            let fd: Int32? = lock.withLock {
                guard case .success(let fd) = result else { return nil }
                if cancelled { close(fd); return nil }
                socket = fd
                return fd
            }
            queue.async { [self] in
                guard !lock.withLock({ cancelled }) else { return }
                switch result {
                case .success: if fd != nil { stateUpdateHandler?(.ready) }
                case .failure(let error): stateUpdateHandler?(.failed(error))
                }
            }
        }
    }

    public func send(_ data: Data, completion: ((TCPError?) -> Void)? = nil) {
        writing.async { [self] in
            let fd = lock.withLock { socket }
            var error: TCPError?
            data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                var sent = 0
                while sent < bytes.count {
                    let n = Glibc.send(fd, bytes.baseAddress! + sent, bytes.count - sent, Int32(MSG_NOSIGNAL))
                    if n < 0 {
                        if errno == EINTR { continue }
                        error = TCPError(errno: errno)
                        return
                    }
                    sent += n
                }
            }
            queue.async { completion?(error) }
        }
    }

    /// Whatever has arrived, up to `maximumLength` bytes; `isComplete` once the camera closed.
    public func receive(maximumLength: Int, completion: @escaping (Data?, _ isComplete: Bool, TCPError?) -> Void) {
        reading.async { [self] in
            let fd = lock.withLock { socket }
            var buffer = [UInt8](repeating: 0, count: maximumLength)
            let n: Int = {
                var n: Int
                repeat { n = recv(fd, &buffer, maximumLength, 0) } while n < 0 && errno == EINTR
                return n
            }()
            let error = n < 0 ? TCPError(errno: errno) : nil
            let data = n > 0 ? Data(buffer[0..<n]) : nil
            queue.async { [self] in
                guard !lock.withLock({ cancelled }) else { return }
                completion(data, n == 0, error)
            }
        }
    }

    public func cancel() {
        let fd: Int32 = lock.withLock {
            cancelled = true
            defer { socket = -1 }
            return socket
        }
        guard fd >= 0 else { return }
        // Wakes a read or write in progress; the socket closes once both are done with it.
        shutdown(fd, Int32(SHUT_RDWR))
        writing.async { [reading] in reading.async { close(fd) } }
    }

    /// Connects within `timeout` seconds, then hands back a blocking socket.
    private static func connect(host: String, port: UInt16, timeout: Int) -> Result<Int32, TCPError> {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        var list: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &list)
        guard rc == 0, let first = list else {
            return .failure(TCPError(code: 0, message: String(cString: gai_strerror(rc))))
        }
        defer { freeaddrinfo(list) }
        var lastError = TCPError(errno: EHOSTUNREACH)
        for entry in sequence(first: first, next: { $0.pointee.ai_next }) {
            let info = entry.pointee
            let fd = Glibc.socket(info.ai_family, info.ai_socktype, info.ai_protocol)
            guard fd >= 0 else { lastError = TCPError(errno: errno); continue }
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            if Glibc.connect(fd, info.ai_addr, info.ai_addrlen) != 0 && errno != EINPROGRESS {
                lastError = TCPError(errno: errno)
                close(fd)
                continue
            }
            var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&poller, 1, Int32(timeout * 1000)) > 0 else {
                lastError = TCPError(errno: ETIMEDOUT)
                close(fd)
                continue
            }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
            guard error == 0 else {
                lastError = TCPError(errno: error)
                close(fd)
                continue
            }
            _ = fcntl(fd, F_SETFL, flags)
            var on: Int32 = 1
            setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
            return .success(fd)
        }
        return .failure(lastError)
    }
#endif
}

#if canImport(Network)
extension TCPConnection.TCPError {
    init(_ error: NWError) {
        if case .posix(let code) = error {
            self.init(code: code.rawValue, message: error.localizedDescription)
        } else {
            self.init(code: 0, message: error.localizedDescription)
        }
    }
}
#endif
