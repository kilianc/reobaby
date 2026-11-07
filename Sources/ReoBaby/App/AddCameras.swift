import AppKit

/// Add Cameras…: finds the Reolink cameras on the network, logs in to each one to check its
/// password, then adds them to cameras.json with the password in the login keychain.
/// The shared password is tried on every camera; a camera that turns it down gets a password
/// field of its own, so cameras with different passwords can be added in the same go.
final class AddCamerasController: NSObject, NSWindowDelegate {
    /// Called once the panel closes, with the URLs of the cameras added (possibly none).
    var onFinish: (([String]) -> Void)?

    private final class Row {
        let host: String
        let box: NSButton
        let password = NSSecureTextField()
        let note = NSTextField(labelWithString: "")
        let view: NSStackView

        init(host: String) {
            self.host = host
            box = NSButton(checkboxWithTitle: host, target: nil, action: nil)
            box.state = .on
            password.placeholderString = "Its password"
            password.isHidden = true
            note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            note.textColor = .secondaryLabelColor
            view = NSStackView(views: [box, password, note])
            view.spacing = 8
            view.alignment = .firstBaseline
            box.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
            password.widthAnchor.constraint(equalToConstant: 140).isActive = true
        }

        /// No longer selectable: already in cameras.json, or just added.
        func settle(_ text: String) {
            box.state = .on
            box.isEnabled = false
            password.isHidden = true
            note.textColor = .secondaryLabelColor
            note.stringValue = text
        }

        func fail(_ text: String, askPassword: Bool) {
            note.textColor = .systemRed
            note.stringValue = text
            if askPassword {
                password.stringValue = ""
                password.isHidden = false
            }
        }
    }

    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let content = NSStackView()
    private let spinner = NSProgressIndicator()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let list = NSStackView()
    private let address = NSTextField()
    private let user = NSTextField()
    private let password = NSSecureTextField()
    private let note = NSTextField(wrappingLabelWithString: "")
    private let searchAgain = NSButton(title: "Search Again", target: nil, action: nil)
    private let addButton = NSButton(title: "Add", target: nil, action: nil)
    private var rows: [Row] = []
    private var configured: Set<String>
    private var added: [String] = []
    private let prefilled: Bool

    init(configured: Set<String>, user: String, password knownPassword: String?) {
        self.configured = configured
        prefilled = knownPassword != nil
        super.init()
        panel.title = "Add Cameras"
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false

        spinner.style = .spinning
        spinner.controlSize = .small
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        list.isHidden = true
        address.placeholderString = "Or type an address, like 10.0.0.52"
        self.user.stringValue = user
        password.placeholderString = "Tried on every camera"
        if let knownPassword { password.stringValue = knownPassword }
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        searchAgain.target = self
        searchAgain.action = #selector(search)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        addButton.target = self
        addButton.action = #selector(add)
        addButton.keyEquivalent = "\r"

        let header = NSStackView(views: [spinner, status])
        header.spacing = 8
        let form = NSGridView(views: [
            [NSTextField(labelWithString: "User:"), self.user],
            [NSTextField(labelWithString: "Password:"), password],
        ])
        form.column(at: 0).xPlacement = .trailing
        form.rowAlignment = .firstBaseline
        form.columnSpacing = 8
        form.rowSpacing = 8
        let buttons = NSStackView(views: [searchAgain, NSView(), cancel, addButton])
        buttons.spacing = 8

        content.setViews([header, list, address, form, note, buttons], in: .top)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        content.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(content)
        panel.contentView = root
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.widthAnchor.constraint(equalToConstant: 420),
            status.widthAnchor.constraint(equalToConstant: 352),
            address.widthAnchor.constraint(equalToConstant: 380),
            buttons.widthAnchor.constraint(equalToConstant: 380),
            note.widthAnchor.constraint(equalToConstant: 380),
            self.user.widthAnchor.constraint(equalToConstant: 280),
            password.widthAnchor.constraint(equalTo: self.user.widthAnchor),
        ])
        fit()
    }

    func show() {
        if !panel.isVisible {
            panel.center()
            search()
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - Search

    @objc private func search() {
        setBusy(true, "Looking for Reolink cameras on your network…")
        Task { @MainActor in
            let result = await Discovery.find()
            let typed = rows.filter { !result.hosts.contains($0.host) && !configured.contains($0.host) }
            rows.forEach { $0.view.removeFromSuperview() }
            rows = []
            list.isHidden = true
            for host in result.hosts { appendRow(host) }
            typed.forEach { appendRow($0.host) } // addresses typed in earlier stay

            let new = result.hosts.filter { !configured.contains($0) }.count
            let summary: String
            switch (result.hosts.count, new) {
            case (0, _) where result.blocked:
                summary = "macOS isn't letting ReoBaby look on your network. Turn on ReoBaby in "
                    + "System Settings ▸ Privacy & Security ▸ Local Network, then search again."
            case (0, _): summary = "No Reolink cameras found. If yours is on another network, type its address."
            case (_, 0): summary = "Every camera found is already added."
            case (_, 1): summary = "Found a new camera."
            default: summary = "Found \(new) new cameras."
            }
            setBusy(false, summary)
            if new > 0 && prefilled { hint("The password is filled in from a camera you already added.") }
            panel.makeFirstResponder(password.stringValue.isEmpty ? password : addButton)
        }
    }

    private func appendRow(_ host: String) {
        let row = Row(host: host)
        if configured.contains(host) { row.settle("already added") }
        rows.append(row)
        list.addArrangedSubview(row.view)
        list.isHidden = false
        fit()
    }

    // MARK: - Add

    @objc private func add() {
        let typed = address.stringValue.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty {
            if let row = rows.first(where: { $0.host == typed }) {
                if row.box.isEnabled { row.box.state = .on }
            } else {
                appendRow(typed)
            }
            address.stringValue = ""
        }
        let pending = rows.filter { $0.box.isEnabled && $0.box.state == .on }
        guard !pending.isEmpty else { return hint("Pick a camera, or type its address.", error: true) }
        let login = user.stringValue.trimmingCharacters(in: .whitespaces)
        guard !login.isEmpty else {
            panel.makeFirstResponder(user)
            return hint("Enter the user you set up in the Reolink app, usually admin.", error: true)
        }
        // A camera's own field wins over the shared one.
        let attempts = pending.map { row in (row, row.password.isHidden || row.password.stringValue.isEmpty
                                                ? password.stringValue : row.password.stringValue) }
        if let (row, _) = attempts.first(where: { $0.1.isEmpty }) {
            panel.makeFirstResponder(row.password.isHidden ? password : row.password)
            return hint("Enter the password you set up in the Reolink app.", error: true)
        }

        setBusy(true, pending.count == 1 ? "Logging in to the camera…" : "Logging in to \(pending.count) cameras…")
        Task { @MainActor in
            let results = await withTaskGroup(of: (Int, Result<String?, Error>).self) { group in
                for (i, (row, secret)) in attempts.enumerated() {
                    let host = row.host
                    group.addTask { (i, await CameraAPI(host: host, user: login, password: secret).check()) }
                }
                var all: [(Int, Result<String?, Error>)] = []
                for await result in group { all.append(result) }
                return all.sorted { $0.0 < $1.0 }
            }
            var cameras: [(Camera, Row, String)] = []
            var failed: [Row] = []
            for (i, result) in results {
                let (row, secret) = attempts[i]
                switch result {
                case .success(let name):
                    let camera = Camera(name: nil, url: "rtsp://\(row.host):554/Preview_01_main", user: login, password: nil)
                    if let name { DeviceNames.set(name, host: row.host) }
                    cameras.append((camera, row, secret))
                case .failure(let error):
                    let (text, wrongPassword) = Self.describe(error)
                    row.fail(text, askPassword: wrongPassword)
                    failed.append(row)
                }
            }
            do {
                if !cameras.isEmpty { try ConfigStore.add(cameras.map(\.0)) }
                for (camera, row, secret) in cameras {
                    if let account = camera.keychainAccount { Keychain.setPassword(secret, account: account) }
                    configured.insert(row.host)
                    row.settle("added")
                    added.append(camera.url)
                }
            } catch {
                failed += cameras.map(\.1)
                hint("Couldn't save cameras.json: \(error.localizedDescription)", error: true)
            }
            fit()
            guard !failed.isEmpty else { return panel.close() }
            let summary = cameras.isEmpty ? "Nothing added yet." : "Added \(cameras.count) of \(pending.count)."
            setBusy(false, summary)
            if let row = failed.first(where: { !$0.password.isHidden }) {
                hint("Type the password for each camera that turned it down, then click Add again.")
                panel.makeFirstResponder(row.password)
            }
        }
    }

    @objc private func cancel() { panel.close() }

    func windowWillClose(_ notification: Notification) {
        let added = added
        DispatchQueue.main.async { self.onFinish?(added) }
    }

    // MARK: - Helpers

    private func setBusy(_ busy: Bool, _ text: String) {
        status.stringValue = text
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        spinner.isHidden = !busy
        addButton.isEnabled = !busy
        searchAgain.isEnabled = !busy
        if busy { hint("") }
        fit()
    }

    private func hint(_ text: String, error: Bool = false) {
        note.textColor = error ? .systemRed : .secondaryLabelColor
        note.stringValue = text
        note.isHidden = text.isEmpty
        fit()
    }

    /// Sizes the panel to its content, keeping its top edge in place.
    private func fit() {
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        var frame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: panel.frame.minX, y: panel.frame.maxY - frame.height)
        panel.setFrame(frame, display: true, animate: false)
    }

    private static func describe(_ error: Error) -> (String, wrongPassword: Bool) {
        switch error {
        case CameraAPI.APIError.failed(let code, let detail):
            if code == -7 || detail.localizedCaseInsensitiveContains("login") || detail.localizedCaseInsensitiveContains("password") {
                return ("wrong password", true)
            }
            return ("camera said “\(detail)”", false)
        case is URLError:
            return ("didn't answer", false)
        default:
            return ("not a Reolink camera", false)
        }
    }
}
