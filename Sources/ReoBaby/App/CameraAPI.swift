import Foundation

/// Reolink HTTP API (`/api.cgi`, JSON over POST, token login).
/// Cameras serve a self-signed certificate; it is trusted for this exact host only.
/// Commands may run concurrently: camera controls stop the camera while a move is still being answered.
final class CameraAPI: NSObject, URLSessionDelegate, @unchecked Sendable {
    enum APIError: Error {
        case badResponse
        case failed(code: Int, detail: String)
    }

    struct Detection: Equatable {
        var motion = false
        var person = false
        var vehicle = false
        var animal = false

        var any: Bool { motion || person || vehicle || animal }
    }

    let host: String
    var userName: String { user }
    private let user: String
    let password: String
    struct ONVIFState { var client: ONVIFClient? }
    /// Nil until looked up.
    let onvifState = Locked<ONVIFState?>(nil)
    /// ONVIF cameras close the connection after every answer; a session of its own keeps that apart.
    private(set) lazy var onvifSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        return URLSession(configuration: config)
    }()
    private var session: URLSession!
    private let lock = NSLock()
    private var _base: URL?
    private var _token: String?
    private var base: URL? {
        get { lock.withLock { _base } }
        set { lock.withLock { _base = newValue } }
    }
    private var token: String? {
        get { lock.withLock { _token } }
        set { lock.withLock { _token = newValue } }
    }

    init(host: String, user: String, password: String, timeout: TimeInterval = 6) {
        self.host = host
        self.user = user
        self.password = password
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
        onvifSession.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host == host,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // MARK: - Commands

    /// The camera's own name (Settings ▸ Device name in the Reolink app). Completion runs on main.
    func deviceName(completion: @escaping (String?) -> Void) {
        Task {
            var name: String?
            if let value = try? await value(of: ["cmd": "GetDevName", "action": 0, "param": ["channel": 0]]),
               let n = (value["DevName"] as? [String: Any])?["name"] as? String, !n.isEmpty {
                name = n
            }
            await logout()
            DispatchQueue.main.async { completion(name) }
        }
    }

    /// Whether this host answers like a Reolink camera. Without a login the API still replies,
    /// asking to log in first, in its own JSON shape: that is enough to recognize it.
    func isReolink() async -> Bool {
        let body: [[String: Any]] = [["cmd": "GetDevInfo", "action": 0, "param": [:] as [String: Any]]]
        for url in ["https", "http"].compactMap({ URL(string: "\($0)://\(host)") }) {
            if let reply = try? await post(base: url, cmd: "GetDevInfo", token: nil, body: body),
               reply.first?["cmd"] as? String == "GetDevInfo" {
                return true
            }
        }
        return false
    }

    /// Logs in and returns the camera's own name, or the reason it failed.
    func check() async -> Result<String?, Error> {
        do {
            let value = try await value(of: ["cmd": "GetDevName", "action": 0, "param": ["channel": 0]])
            let name = (value["DevName"] as? [String: Any])?["name"] as? String
            await logout()
            return .success(name?.isEmpty == false ? name : nil)
        } catch {
            return .failure(error)
        }
    }

    /// Current motion and AI detection state, as judged by the camera.
    func detection() async throws -> Detection {
        let results = try await run([
            ["cmd": "GetMdState", "action": 0, "param": ["channel": 0]],
            ["cmd": "GetAiState", "action": 0, "param": ["channel": 0]],
        ])
        var d = Detection()
        if let md = results.first?["value"] as? [String: Any] {
            d.motion = (md["state"] as? Int ?? 0) != 0
        } else {
            throw APIError.badResponse
        }
        if results.count > 1, let ai = results[1]["value"] as? [String: Any] {
            func alarm(_ key: String) -> Bool { ((ai[key] as? [String: Any])?["alarm_state"] as? Int ?? 0) != 0 }
            d.person = alarm("people")
            d.vehicle = alarm("vehicle")
            d.animal = alarm("dog_cat")
        }
        return d
    }

    /// A JPEG still from the main stream.
    func snapshot() async throws -> Data {
        for attempt in 0..<2 {
            if token == nil { try await login() }
            guard let base, let token else { throw APIError.badResponse }
            var components = URLComponents(url: base.appendingPathComponent("cgi-bin/api.cgi"), resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "cmd", value: "Snap"),
                URLQueryItem(name: "channel", value: "0"),
                URLQueryItem(name: "rs", value: String(UInt32.random(in: 0...UInt32.max), radix: 36)),
                URLQueryItem(name: "token", value: token),
            ]
            let (data, response) = try await session.data(from: components.url!)
            if (response as? HTTPURLResponse)?.mimeType?.hasPrefix("image/") == true || data.starts(with: [0xFF, 0xD8]) {
                return data
            }
            if attempt == 0 { self.token = nil } // probably an expired token: log in again
        }
        throw APIError.badResponse
    }

    /// Any command, answered as the camera answers it. For `ReoBaby --api`.
    func raw(_ cmd: String, action: Int = 0, param: [String: Any]) async throws -> [[String: Any]] {
        try await run([["cmd": cmd, "action": action, "param": param]])
    }

    /// Any commands, as the camera answers them: for `ReoBaby --api-poll`.
    func raw(_ commands: [[String: Any]]) async throws -> [[String: Any]] {
        try await run(commands)
    }

    func logout() async {
        guard let token, let base else { return }
        self.token = nil
        _ = try? await post(base: base, cmd: "Logout", token: token, body: [["cmd": "Logout", "param": [:] as [String: Any]]])
    }

    // MARK: - Transport

    func value(of command: [String: Any]) async throws -> [String: Any] {
        let result = try await run([command])
        guard let first = result.first else { throw APIError.badResponse }
        if let error = Self.error(in: first) { throw error }
        return first["value"] as? [String: Any] ?? [:]
    }

    /// Runs a batch of commands, logging in (again) when the token is missing or expired.
    func run(_ commands: [[String: Any]]) async throws -> [[String: Any]] {
        for attempt in 0..<2 {
            if token == nil { try await login() }
            guard let base, let token else { throw APIError.badResponse }
            let cmd = commands.first?["cmd"] as? String ?? ""
            let result = try await post(base: base, cmd: cmd, token: token, body: commands)
            let needsLogin = result.contains { item in
                if case .failed(let code, _)? = Self.error(in: item) { return code == -6 } // "please login first"
                return false
            }
            if needsLogin && attempt == 0 {
                self.token = nil
                continue
            }
            return result
        }
        throw APIError.badResponse
    }

    private func login() async throws {
        let body: [[String: Any]] = [[
            "cmd": "Login",
            "param": ["User": ["Version": "0", "userName": user, "password": password]],
        ]]
        var lastError: Error = APIError.badResponse
        let candidates = base.map { [$0] } ?? ["https", "http"].compactMap { URL(string: "\($0)://\(host)") }
        for url in candidates {
            do {
                let result = try await post(base: url, cmd: "Login", token: nil, body: body)
                guard let first = result.first else { throw APIError.badResponse }
                if let error = Self.error(in: first) { throw error }
                guard let token = ((first["value"] as? [String: Any])?["Token"] as? [String: Any])?["name"] as? String else {
                    throw APIError.badResponse
                }
                self.base = url
                self.token = token
                return
            } catch let error as URLError {
                lastError = error // HTTPS off or unreachable: try plain HTTP
            }
        }
        throw lastError
    }

    private func post(base: URL, cmd: String, token: String?, body: [[String: Any]]) async throws -> [[String: Any]] {
        var components = URLComponents(url: base.appendingPathComponent("cgi-bin/api.cgi"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "cmd", value: cmd)]
        if let token { components.queryItems?.append(URLQueryItem(name: "token", value: token)) }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await session.data(for: request)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw APIError.badResponse
        }
        return result
    }

    static func error(in item: [String: Any]) -> APIError? {
        guard (item["code"] as? Int ?? 0) != 0 else { return nil }
        let error = item["error"] as? [String: Any]
        return .failed(code: error?["rspCode"] as? Int ?? -1, detail: error?["detail"] as? String ?? "")
    }
}
