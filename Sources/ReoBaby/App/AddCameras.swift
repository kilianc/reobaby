import AppKit
import SwiftUI

/// Add Cameras…: lists the Reolink cameras on the network, the way Wi-Fi lists networks.
/// Each camera is added on its own: its row opens a login form, ReoBaby logs in to check it,
/// then the camera goes into cameras.json and its password into the login keychain.
final class AddCamerasController: NSObject, NSWindowDelegate {
    /// Called once the panel closes, with the URLs of the cameras added (possibly none).
    var onFinish: (([String]) -> Void)?

    private let model = AddCamerasModel()
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
                                styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
    /// Cameras already in cameras.json: host → the name ReoBaby shows for it.
    private var configured: [String: String]
    private var added: [String] = []

    init(configured: [String: String], user: String) {
        self.configured = configured
        super.init()
        model.defaultUser = user
        model.onSearch = { [weak self] in self?.search() }
        model.onConnect = { [weak self] in self?.connect() }
        model.onAddAddress = { [weak self] in self?.addAddress() }
        model.onDone = { [weak self] in self?.panel.close() }

        let host = NSHostingController(rootView: AddCamerasView(model: model))
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        panel.title = "Add Cameras"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
    }

    func show() {
        if !panel.isVisible {
            panel.center()
            search()
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        let added = added
        DispatchQueue.main.async { self.onFinish?(added) }
    }

    // MARK: - Search

    private func search() {
        model.searching = true
        Task { @MainActor in
            let result = await Discovery.find()
            // Addresses typed in by hand stay in the list.
            let typed = model.rows.filter { $0.typed && !result.hosts.contains($0.host) }
            model.rows = result.hosts.map(row) + typed
            model.blocked = result.blocked
            model.searching = false
            if let open = model.open, !model.rows.contains(where: { $0.host == open }) { model.open = nil }
        }
    }

    private func row(_ host: String) -> AddCamerasModel.Row {
        if let name = configured[host] { return .init(host: host, name: name, status: .already) }
        return .init(host: host, name: DeviceNames.get(host), status: .new)
    }

    private func addAddress() {
        let host = model.address.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        model.address = ""
        if !model.rows.contains(where: { $0.host == host }) {
            var row = row(host)
            row.typed = true
            model.rows.append(row)
        }
        if model.rows.first(where: { $0.host == host })?.status == .new { model.openLogin(host) }
    }

    // MARK: - Connect

    /// Logs in to the camera whose form is open; adds it if the login works.
    private func connect() {
        guard let host = model.open, let i = model.rows.firstIndex(where: { $0.host == host }) else { return }
        let user = model.user.trimmingCharacters(in: .whitespaces)
        let password = model.password
        guard !user.isEmpty, !password.isEmpty else { return }
        model.error = nil
        model.rows[i].status = .checking
        Task { @MainActor in
            let result = await CameraAPI(host: host, user: user, password: password).check()
            guard let i = model.rows.firstIndex(where: { $0.host == host }) else { return }
            switch result {
            case .success(let name):
                if let name {
                    DeviceNames.set(name, host: host)
                    model.rows[i].name = name
                }
                let camera = Camera(name: nil, url: "rtsp://\(host):554/Preview_01_main", user: user, password: nil)
                do {
                    try ConfigStore.add([camera])
                } catch {
                    model.rows[i].status = .new
                    model.error = "Couldn't save cameras.json: \(error.localizedDescription)"
                    return
                }
                if let account = camera.keychainAccount { Keychain.setPassword(password, account: account) }
                configured[host] = model.rows[i].displayName
                added.append(camera.url)
                model.rows[i].status = .added
                model.open = nil
            case .failure(let error):
                model.rows[i].status = .new
                model.error = Self.describe(error)
                model.password = ""
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case CameraAPI.APIError.failed(let code, let detail):
            if code == -7 || detail.localizedCaseInsensitiveContains("login") || detail.localizedCaseInsensitiveContains("password") {
                return "Wrong user or password."
            }
            return "The camera said “\(detail)”."
        case is URLError:
            return "The camera didn't answer."
        default:
            return "This doesn't look like a Reolink camera."
        }
    }
}

// MARK: - Model

final class AddCamerasModel: ObservableObject {
    enum Status: Equatable { case new, checking, added, already }

    struct Row: Identifiable {
        var id: String { host }
        let host: String
        var name: String?
        var status: Status
        var typed = false

        var displayName: String { name ?? "Reolink camera" }
    }

    @Published var rows: [Row] = []
    @Published var searching = false
    @Published var blocked = false
    @Published var address = ""
    /// The camera whose login form is open, and what's typed in it.
    @Published var open: String?
    @Published var user = ""
    @Published var password = ""
    @Published var error: String?
    var defaultUser = "admin"

    var onSearch: () -> Void = {}
    var onConnect: () -> Void = {}
    var onAddAddress: () -> Void = {}
    var onDone: () -> Void = {}

    func openLogin(_ host: String) {
        open = host
        if user.isEmpty { user = defaultUser }
        password = ""
        error = nil
    }

    var checking: Bool { rows.contains { $0.status == .checking } }

    var subtitle: String {
        if searching && rows.isEmpty { return "Looking for Reolink cameras on your network…" }
        if blocked && rows.isEmpty { return "macOS is keeping ReoBaby off your network." }
        let new = rows.filter { $0.status == .new || $0.status == .checking }.count
        let justAdded = rows.filter { $0.status == .added }.count
        switch (rows.count, new) {
        case (0, _): return "No Reolink cameras found on your network."
        case (_, 0) where justAdded > 0: return justAdded == 1 ? "Camera added." : "\(justAdded) cameras added."
        case (_, 0): return "All your cameras are added."
        case (_, 1): return "Found a new camera on your network."
        default: return "Found \(new) new cameras on your network."
        }
    }
}

// MARK: - Views

struct AddCamerasView: View {
    @ObservedObject var model: AddCamerasModel

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                Text("Add Cameras")
                    .font(.title2.weight(.semibold))
                Text(model.subtitle)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            GroupedSection {
                HStack {
                    Text("On your network")
                    Spacer()
                    if model.searching {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(action: model.onSearch) { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                            .help("Search again")
                            .disabled(model.checking)
                    }
                }
            } content: {
                if model.blocked && model.rows.isEmpty {
                    BlockedRow()
                    Divider()
                }
                ForEach(model.rows) { row in
                    CameraRow(row: row, model: model)
                    Divider().padding(.leading, 54)
                }
                HStack(spacing: 12) {
                    Image(systemName: "plus")
                        .frame(width: 30)
                        .foregroundStyle(.secondary)
                    TextField("Add by address, like 10.0.0.52", text: $model.address)
                        .textFieldStyle(.plain)
                        .onSubmit(model.onAddAddress)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            } footer: {
                Text("ReoBaby logs in to each camera to check its password, then keeps it in your keychain.")
            }

            HStack {
                Spacer()
                Button("Done", action: model.onDone)
                    .keyboardShortcut(model.open == nil ? .defaultAction : nil)
                    .controlSize(.large)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 22)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeOut(duration: 0.18), value: model.open)
    }
}

/// A rounded group of rows, like System Settings.
private struct GroupedSection<Header: View, Content: View, Footer: View>: View {
    let header: Header
    let content: Content
    let footer: Footer

    init(@ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.header = header()
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            footer
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
        }
    }
}

private struct CameraRow: View {
    let row: AddCamerasModel.Row
    @ObservedObject var model: AddCamerasModel
    @FocusState private var focus: Field?
    private enum Field { case user, password }

    private var isOpen: Bool { model.open == row.host }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.55, green: 0.47, blue: 0.93), Color(red: 0.36, green: 0.29, blue: 0.75)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 30, height: 30)
                    .overlay(Image(systemName: "video.fill").font(.system(size: 13)).foregroundStyle(.white))
                    .opacity(row.status == .already ? 0.55 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.displayName)
                    Text(row.host).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                trailing
            }
            if isOpen { form }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 48)
    }

    @ViewBuilder private var trailing: some View {
        switch row.status {
        case .new where !isOpen:
            Button("Add") { model.openLogin(row.host) }
                .disabled(model.checking)
        case .new, .checking:
            EmptyView()
        case .added:
            Label("Added", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .already:
            Text("Added").foregroundStyle(.secondary)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("User").gridColumnAlignment(.trailing)
                    TextField("", text: $model.user, prompt: Text("admin"))
                        .focused($focus, equals: .user)
                }
                GridRow {
                    Text("Password")
                    SecureField("", text: $model.password, prompt: Text("Set in the Reolink app"))
                        .focused($focus, equals: .password)
                }
            }
            .textFieldStyle(.roundedBorder)
            .disabled(row.status == .checking)
            HStack {
                if row.status == .checking {
                    ProgressView().controlSize(.small)
                    Text("Logging in…").foregroundStyle(.secondary)
                } else if let error = model.error {
                    Text(error).foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel") { model.open = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Add Camera", action: model.onConnect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.user.isEmpty || model.password.isEmpty || row.status == .checking)
            }
            .font(.callout)
        }
        .padding(.leading, 42)
        .padding(.bottom, 4)
        // After the row has grown, or the address field keeps the focus.
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focus = .password } }
        .onChange(of: model.error) { if model.error != nil { focus = .password } }
    }
}

private struct BlockedRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ReoBaby needs Local Network access to look for cameras.")
            Button("Open Privacy Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}
