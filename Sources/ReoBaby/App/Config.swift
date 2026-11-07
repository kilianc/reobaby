import Foundation
import Security

struct Camera: Codable, Equatable {
    /// Optional: when omitted, the name configured on the camera itself is used.
    var name: String?
    /// rtsp://host[:port]/path. Credentials may be embedded but `user` + keychain is preferred.
    var url: String
    var user: String?
    /// Optional plaintext fallback; the keychain entry wins when present.
    var password: String?

    var host: String? { RTSPEndpoint(url)?.host }

    var displayName: String {
        name ?? host.flatMap(DeviceNames.get) ?? host ?? url
    }

    /// Endpoint without touching the keychain.
    private func baseEndpoint() -> RTSPEndpoint? {
        guard var ep = RTSPEndpoint(url) else { return nil }
        if let user, !user.isEmpty { ep.user = user }
        if ep.user == nil { ep.user = "admin" }
        return ep
    }

    /// Keychain account holding this camera's password.
    var keychainAccount: String? {
        baseEndpoint().map(Self.keychainAccount)
    }

    func endpoint() -> RTSPEndpoint? {
        guard var ep = baseEndpoint() else { return nil }
        if let saved = Keychain.password(account: Self.keychainAccount(ep)) {
            ep.password = saved
        } else if let password, !password.isEmpty {
            ep.password = password
        }
        return ep
    }

    static func keychainAccount(_ ep: RTSPEndpoint) -> String {
        "\(ep.user ?? "")@\(ep.host):\(ep.port)"
    }
}

private struct CameraFile: Codable {
    var cameras: [Camera]
}

enum ConfigStore {
    /// `REOBABY_CONFIG_DIR` points at another folder, for demos and testing.
    static let directory = ProcessInfo.processInfo.environment["REOBABY_CONFIG_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/reobaby", isDirectory: true)
    static let file = directory.appendingPathComponent("cameras.json")

    static func read() throws -> Data {
        try Data(contentsOf: file)
    }

    static func decode(_ data: Data) throws -> [Camera] {
        try JSONDecoder().decode(CameraFile.self, from: data).cameras
    }

    /// The example camera a new cameras.json starts with. It is never a real camera.
    static let templateURL = "rtsp://192.168.1.50:554/Preview_01_main"

    /// The cameras in cameras.json, without the example camera; none when there is no file.
    /// Throws when the file doesn't parse: it may hold edits in progress, so it must not be overwritten.
    static func load() throws -> [Camera] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try decode(read()).filter { $0.url != templateURL }
    }

    static func save(_ cameras: [Camera]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(CameraFile(cameras: cameras)).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Appends cameras to cameras.json, skipping hosts already there.
    static func add(_ new: [Camera]) throws {
        var list = try load()
        let hosts = Set(list.compactMap(\.host))
        list += new.filter { $0.host.map { !hosts.contains($0) } ?? false }
        try save(list)
    }

    static func writeTemplateIfMissing() {
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let template = CameraFile(cameras: [
            Camera(name: nil, url: templateURL, user: "admin", password: nil)
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let data = try? encoder.encode(template) {
            FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }
}

/// Names reported by the cameras themselves, cached per host.
enum DeviceNames {
    private static let key = "deviceNames"

    static func get(_ host: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[host]
    }

    static func set(_ name: String, host: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        all[host] = name
        UserDefaults.standard.set(all, forKey: key)
    }
}

/// Camera passwords in the login keychain. Each entry is read at most once per launch:
/// every read of an entry that hasn't granted ReoBaby access shows a macOS prompt, and
/// a prompt blocks the reading thread until it is answered.
enum Keychain {
    // Kept from when the app was called Cam, so existing passwords are still found.
    private static let service = "Cam camera password"
    private static let lock = NSLock()
    private static var cache: [String: String?] = [:]

    static func isLoaded(_ account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cache[account] != nil
    }

    static func password(account: String) -> String? {
        // Held across the read so two threads never prompt for the same entry.
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[account] { return hit }
        let value = read(account: account)
        cache[account] = .some(value)
        return value
    }

    private static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deletePassword(account: String) {
        lock.lock()
        cache[account] = .some(nil)
        lock.unlock()
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }

    static func setPassword(_ password: String, account: String) {
        lock.lock()
        cache[account] = .some(password)
        lock.unlock()
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(password.utf8)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "ReoBaby: \(account)"
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
