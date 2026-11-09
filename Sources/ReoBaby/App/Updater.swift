import AppKit
import Security

/// Keeps ReoBaby up to date from its GitHub releases. A newer release is downloaded in the
/// background and installed when ReoBaby quits, or right away with "Restart to Update".
/// It is installed only if it's signed by the same developer as the running copy.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle
        case busy
        case ready(version: String, app: URL)
    }

    @Published private(set) var state: State = .idle
    private var timer: Timer?
    private var relaunch = false

    /// `REOBABY_UPDATE_URL` points at another release feed, for testing.
    private static let feed = ProcessInfo.processInfo.environment["REOBABY_UPDATE_URL"]
        .flatMap(URL.init(string:))
        ?? URL(string: "https://api.github.com/repos/kilianc/reobaby/releases/latest")!

    static let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    static let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"

    private var automatic: Bool {
        UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true
    }

    // MARK: - Menu

    var menuTitle: String {
        switch state {
        case .idle: "Check for Updates…"
        case .busy: "Checking for Updates…"
        case .ready(let version, _): "Restart to Update to \(version)"
        }
    }

    var menuEnabled: Bool { state != .busy }

    // MARK: - Settings

    var settingsButtonTitle: String {
        if case .ready = state { return "Restart to Update" }
        return "Check Now"
    }

    var settingsStatus: String {
        switch state {
        case .idle: Self.blocker ?? "Updates come from ReoBaby's releases on GitHub."
        case .busy: "Checking for updates…"
        case .ready(let version, _): "ReoBaby \(version) is downloaded and installs when ReoBaby quits."
        }
    }

    /// Settings ▸ General ▸ Check for updates automatically.
    func setAutomatic(_ on: Bool) {
        if on {
            start()
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    func menuAction() {
        if case .ready = state {
            restartToUpdate()
        } else {
            Task { await check(interactive: true) }
        }
    }

    // MARK: - Checking

    /// Checks shortly after launch, then every six hours.
    func start() {
        guard automatic, Self.blocker == nil, timer == nil else { return }
        Task {
            try? await Task.sleep(for: .seconds(30))
            await check(interactive: false)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in await Updater.shared.check(interactive: false) }
        }
        timer?.tolerance = 600
    }

    func check(interactive: Bool) async {
        guard state != .busy else { return }
        if let blocker = Self.blocker {
            if interactive { Self.show("ReoBaby can't update itself", blocker) }
            return
        }
        let previous = state
        state = .busy
        do {
            let release = try await Self.latestRelease()
            let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
            if case .ready(let staged, _) = previous, staged == version {
                state = previous
            } else if version.compare(Self.currentVersion, options: .numeric) == .orderedDescending {
                guard let asset = release.assets.first(where: { $0.name == "ReoBaby.zip" }) else {
                    throw UpdateError("The \(version) release has no ReoBaby.zip.")
                }
                let app = try await Self.download(asset.browser_download_url, version: version)
                if case .ready(_, let old) = previous { Self.discard(old) }
                state = .ready(version: version, app: app)
            } else {
                state = previous
                if interactive {
                    Self.show("ReoBaby is up to date", "\(Self.currentVersion) is the latest version.")
                    return
                }
            }
        } catch {
            state = previous
            NSLog("ReoBaby update: %@", error.localizedDescription)
            if interactive { Self.show("Couldn't check for updates", error.localizedDescription) }
            return
        }
        if interactive, case .ready(let version, _) = state {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "ReoBaby \(version) is ready"
            alert.informativeText = "It installs the next time ReoBaby quits. Restart now to install it right away."
            alert.addButton(withTitle: "Restart Now")
            alert.addButton(withTitle: "Later")
            alert.window.hidesOnDeactivate = false
            if alert.runModal() == .alertFirstButtonReturn { restartToUpdate() }
        }
    }

    // MARK: - Installing

    func restartToUpdate() {
        guard case .ready = state else { return }
        relaunch = true
        NSApp.terminate(nil)
    }

    /// Called as ReoBaby quits: hands a downloaded update to a helper that swaps it in once
    /// this process has exited.
    func installIfReady() {
        guard case .ready(_, let app) = state else { return }
        let target = Bundle.main.bundleURL
        let helper = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let args = [helper, "--install-update", "\(getpid())", app.path, target.path, relaunch ? "1" : "0"]

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own session, so it outlives this process.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, helper, nil, &attributes, &argv, environ)
        if status != 0 { NSLog("ReoBaby update: couldn't start the installer (%d)", status) }
    }

    /// `--install-update <pid> <new app> <installed app> <relaunch>`: waits for ReoBaby to quit,
    /// then swaps the new app in for the installed one in a single step.
    nonisolated static func finishInstall(arguments: [String]) -> Int32 {
        guard arguments.count == 4, let pid = pid_t(arguments[0]) else { return 2 }
        let new = URL(fileURLWithPath: arguments[1])
        let installed = URL(fileURLWithPath: arguments[2])
        let deadline = Date().addingTimeInterval(60)
        while kill(pid, 0) == 0 {
            guard Date() < deadline else { return 1 }
            usleep(100_000)
        }
        guard isSignedLikeSelf(new) else {
            NSLog("ReoBaby update: %@ isn't signed like this copy", new.path)
            return 1
        }
        // Both apps stay whole the whole time: the swap is atomic, then the old one is removed.
        guard renamex_np(new.path, installed.path, UInt32(RENAME_SWAP)) == 0 else {
            NSLog("ReoBaby update: couldn't replace %@: %s", installed.path, strerror(errno))
            return 1
        }
        try? FileManager.default.removeItem(at: new.deletingLastPathComponent())
        if arguments[3] == "1" {
            var open = ["-n"]
            // A demo copy comes back as the demo copy.
            if let dir = ProcessInfo.processInfo.environment["REOBABY_CONFIG_DIR"] {
                open += ["--env", "REOBABY_CONFIG_DIR=\(dir)"]
            }
            run("/usr/bin/open", open + [installed.path])
        }
        return 0
    }

    // MARK: - Helpers

    struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let assets: [Asset]
    }

    /// Why this copy can't replace itself, if it can't.
    static var blocker: String? {
        guard teamIdentifier != nil else {
            return "This copy was built without a signing certificate, so ReoBaby can't tell a genuine update from another app."
        }
        let bundle = Bundle.main.bundleURL
        if bundle.path.contains("/AppTranslocation/") {
            return "Move ReoBaby to your Applications folder and open it from there."
        }
        let folder = bundle.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            return "ReoBaby can't write to \(folder.path). Move it to your Applications folder."
        }
        return nil
    }

    private static func latestRelease() async throws -> Release {
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ReoBaby/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError("GitHub answered \(http.statusCode).")
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    /// Downloads and unzips a release next to the installed app (same volume, so the swap is
    /// atomic), and returns the new app once it checks out.
    nonisolated private static func download(_ url: URL, version: String) async throws -> URL {
        let (zip, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: zip) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError("The download failed (\(http.statusCode)).")
        }
        let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                 appropriateFor: Bundle.main.bundleURL, create: true)
        let app = folder.appendingPathComponent("ReoBaby.app")
        do {
            guard run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path]) == 0,
                  FileManager.default.fileExists(atPath: app.path) else {
                throw UpdateError("The download isn't a ReoBaby.zip.")
            }
            let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
            guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
                  info?["CFBundleShortVersionString"] as? String == version else {
                throw UpdateError("The download isn't ReoBaby \(version).")
            }
            guard isSignedLikeSelf(app) else {
                throw UpdateError("ReoBaby \(version) isn't signed by the same developer as this copy, so it wasn't installed.")
            }
            // Downloads by ReoBaby itself aren't quarantined, but a quarantined zip would carry it.
            run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
            return app
        } catch {
            discard(app)
            throw error
        }
    }

    nonisolated private static func discard(_ app: URL) {
        try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
    }

    private static func show(_ title: String, _ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        // Stays visible if ReoBaby isn't frontmost, instead of blocking the app unseen.
        alert.window.hidesOnDeactivate = false
        alert.runModal()
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: - Code signing

    nonisolated private static func ownCode() -> SecStaticCode? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess else { return nil }
        return staticCode
    }

    nonisolated static var teamIdentifier: String? {
        guard let code = ownCode() else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// True when `app` is intact and meets this copy's designated requirement: same bundle id,
    /// signed by the same developer certificate.
    nonisolated static func isSignedLikeSelf(_ app: URL) -> Bool {
        guard let own = ownCode() else { return false }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(own, [], &requirement) == errSecSuccess, let requirement else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }
}
