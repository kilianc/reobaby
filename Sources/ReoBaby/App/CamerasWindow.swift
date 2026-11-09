import AppKit
import SwiftUI

/// Settings ▸ Cameras: the cameras saved in ReoBaby, and the Reolink cameras on the network it could add.
/// A new camera is added the way Wi-Fi joins a network: its row opens a login form, ReoBaby logs
/// in to check it, then the camera goes into cameras.json and its password into the login keychain.
/// A saved camera's row opens a form to rename it, change its picture or login, or remove it.
final class CamerasController {
    /// cameras.json changed.
    var onChange: (() -> Void)?
    /// "Open cameras.json".
    var onOpenFile: (() -> Void)?

    let model = CamerasModel()
    private var discovered: [String] = []
    private var added: [String] = []

    init() {
        model.onSearch = { [weak self] in self?.search() }
        model.onAdd = { [weak self] in self?.add() }
        model.onSave = { [weak self] in self?.save() }
        model.onRemove = { [weak self] in self?.remove() }
        model.onAddAddress = { [weak self] in self?.addAddress() }
        model.onOpenFile = { [weak self] in self?.onOpenFile?() }
    }

    /// The pane is on screen: shows the saved cameras and looks for new ones on the network.
    func appear() {
        reloadSaved()
        if !model.searching { search() }
    }

    /// Settings closed: closes any open form and returns the URLs of the cameras added meanwhile.
    func finish() -> [String] {
        defer { added = [] }
        model.form = nil
        return added
    }

    // MARK: - Lists

    private func reloadSaved() {
        do {
            model.saved = try ConfigStore.load().map(CamerasModel.Saved.init)
            model.fileError = nil
        } catch {
            model.saved = []
            model.fileError = "cameras.json has a mistake in it, so cameras can't be changed here. Open it to fix it."
        }
        let savedHosts = Set(model.saved.map(\.host))
        let typed = model.found.filter(\.typed).map(\.host)
        model.found = (discovered + typed.filter { !discovered.contains($0) })
            .filter { !savedHosts.contains($0) }
            .map { host in model.found.first { $0.host == host } ?? .init(host: host, name: DeviceNames.get(host)) }
        if case .add(let host)? = model.form, savedHosts.contains(host) { model.form = nil }
    }

    private func search() {
        model.searching = true
        Task { @MainActor in
            let result = await Discovery.find()
            discovered = result.hosts
            model.blocked = result.blocked
            model.searching = false
            reloadSaved()
        }
    }

    private func addAddress() {
        let host = model.address.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        model.address = ""
        if model.saved.contains(where: { $0.host == host }) { return }
        if !model.found.contains(where: { $0.host == host }) {
            model.found.append(.init(host: host, name: DeviceNames.get(host), typed: true))
        }
        model.openAdd(host, user: defaultUser)
    }

    private var defaultUser: String { model.saved.first?.user ?? "admin" }

    // MARK: - Add, save, remove

    private func add() {
        guard case .add(let host)? = model.form else { return }
        let user = model.user.trimmingCharacters(in: .whitespaces)
        let password = model.password
        guard !user.isEmpty, !password.isEmpty else { return }
        login(host: host, user: user, password: password) { [self] name in
            let camera = Camera(name: nil, url: "rtsp://\(host):554/Preview_01_main", user: user, password: nil)
            try ConfigStore.add([camera])
            if let account = camera.keychainAccount { Keychain.setPassword(password, account: account) }
            added.append(camera.url)
        }
    }

    private func save() {
        guard case .edit(let url)? = model.form, let saved = model.saved.first(where: { $0.url == url }) else { return }
        let user = model.user.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty else { return model.error = "Enter the user you set up in the Reolink app." }
        do {
            var list = try ConfigStore.load()
            guard let i = list.firstIndex(where: { $0.url == url }) else { return }
            let old = list[i]
            var camera = old
            let name = model.name.trimmingCharacters(in: .whitespaces)
            camera.name = name.isEmpty ? nil : name
            if let quality = saved.quality, quality != model.quality {
                camera.url = String(camera.url.dropLast(quality.suffix.count)) + model.quality.suffix
            }
            camera.user = user
            let loginChanged = user != saved.user || !model.password.isEmpty
            guard loginChanged else {
                list[i] = camera
                try ConfigStore.save(list)
                return finishEdit()
            }
            // A new login is checked on the camera before it's saved.
            guard let password = model.password.isEmpty ? old.endpoint()?.password : model.password else {
                return model.error = "Enter the password for this user."
            }
            camera.password = nil // the keychain holds it from now on
            login(host: saved.host, user: user, password: password) { [self] _ in
                list[i] = camera
                try ConfigStore.save(list)
                if let account = camera.keychainAccount { Keychain.setPassword(password, account: account) }
                if let previous = old.keychainAccount, previous != camera.keychainAccount { Keychain.deletePassword(account: previous) }
            }
        } catch {
            model.error = "Couldn't save cameras.json: \(error.localizedDescription)"
        }
    }

    private func remove() {
        guard case .edit(let url)? = model.form else { return }
        do {
            var list = try ConfigStore.load()
            guard let camera = list.first(where: { $0.url == url }) else { return }
            list.removeAll { $0.url == url }
            try ConfigStore.save(list)
            if let account = camera.keychainAccount { Keychain.deletePassword(account: account) }
            added.removeAll { $0 == url }
            finishEdit()
        } catch {
            model.error = "Couldn't save cameras.json: \(error.localizedDescription)"
        }
    }

    private func finishEdit() {
        model.form = nil
        reloadSaved()
        onChange?()
    }

    /// Logs in to check the user and password; when they work, `commit` saves the change.
    private func login(host: String, user: String, password: String, commit: @escaping (String?) throws -> Void) {
        model.error = nil
        model.busy = true
        Task { @MainActor in
            let result = await CameraAPI(host: host, user: user, password: password).check()
            model.busy = false
            switch result {
            case .success(let name):
                if let name { DeviceNames.set(name, host: host) }
                do {
                    try commit(name)
                    finishEdit()
                } catch {
                    model.error = "Couldn't save cameras.json: \(error.localizedDescription)"
                }
            case .failure(let error):
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

final class CamerasModel: ObservableObject {
    enum Quality: Hashable {
        case high, low
        var suffix: String { self == .high ? "_main" : "_sub" }
    }

    /// A camera in cameras.json.
    struct Saved: Identifiable {
        var id: String { url }
        let url: String
        let host: String
        let title: String
        let name: String?
        let user: String
        /// nil when the URL isn't a Reolink main or sub stream.
        let quality: Quality?

        init(_ camera: Camera) {
            url = camera.url
            host = camera.host ?? camera.url
            title = camera.displayName
            name = camera.name
            user = camera.user ?? RTSPEndpoint(camera.url)?.user ?? "admin"
            quality = camera.url.hasSuffix("_main") ? .high : camera.url.hasSuffix("_sub") ? .low : nil
        }
    }

    /// A Reolink camera on the network that isn't saved yet.
    struct Found: Identifiable {
        var id: String { host }
        let host: String
        var name: String?
        var typed = false
        var title: String { name ?? "Reolink camera" }
    }

    enum Form: Equatable {
        case add(String)  // host
        case edit(String) // url
    }

    @Published var saved: [Saved] = []
    @Published var found: [Found] = []
    @Published var searching = false
    @Published var blocked = false
    @Published var address = ""
    @Published var fileError: String?

    /// The form that's open, and what's typed in it.
    @Published var form: Form?
    @Published var name = ""
    @Published var quality = Quality.high
    @Published var user = ""
    @Published var password = ""
    @Published var error: String?
    @Published var busy = false

    var onSearch: () -> Void = {}
    var onAdd: () -> Void = {}
    var onSave: () -> Void = {}
    var onRemove: () -> Void = {}
    var onAddAddress: () -> Void = {}
    var onOpenFile: () -> Void = {}

    func openAdd(_ host: String, user: String) {
        form = .add(host)
        self.user = user
        password = ""
        error = nil
    }

    func openEdit(_ camera: Saved) {
        form = .edit(camera.url)
        name = camera.name ?? ""
        quality = camera.quality ?? .high
        user = camera.user
        password = ""
        error = nil
    }
}

// MARK: - Views

struct CamerasView: View {
    @ObservedObject var model: CamerasModel

    var body: some View {
        PaneStack {
            if let fileError = model.fileError {
                Text(fileError)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.saved.isEmpty {
                GroupedSection {
                    Text("Your cameras")
                } content: {
                    ForEach(Array(model.saved.enumerated()), id: \.element.id) { index, camera in
                        if index > 0 { Divider().padding(.leading, 54) }
                        SavedRow(camera: camera, model: model)
                    }
                }
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
                    }
                }
            } content: {
                if model.blocked && model.found.isEmpty {
                    BlockedRow()
                    Divider()
                } else if model.found.isEmpty && !model.searching {
                    Text(model.saved.isEmpty ? "No Reolink cameras found." : "No other cameras found.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    Divider()
                }
                ForEach(model.found) { camera in
                    FoundRow(camera: camera, model: model)
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
                Button("Open cameras.json", action: model.onOpenFile)
                    .buttonStyle(.link)
                    .font(.callout)
                    .help("For what this pane doesn't cover")
                Spacer()
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.form)
    }
}

/// A rounded group of rows, like System Settings.
struct GroupedSection<Header: View, Content: View, Footer: View>: View {
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

extension GroupedSection where Footer == EmptyView {
    init(@ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content) {
        self.init(header: header, content: content, footer: { EmptyView() })
    }
}

private struct CameraIcon: View {
    var dimmed = false

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.55, green: 0.47, blue: 0.93), Color(red: 0.36, green: 0.29, blue: 0.75)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: 30, height: 30)
            .overlay(Image(systemName: "video.fill").font(.system(size: 13)).foregroundStyle(.white))
            .opacity(dimmed ? 0.55 : 1)
    }
}

/// Icon, name and address, with something on the right; a form opens underneath.
private struct CameraRowLayout<Trailing: View, Editor: View>: View {
    let title: String
    let host: String
    let isOpen: Bool
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var form: Editor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                CameraIcon()
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(host).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                if !isOpen { trailing }
            }
            if isOpen {
                form
                    .padding(.leading, 42)
                    .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 48)
    }
}

private struct SavedRow: View {
    let camera: CamerasModel.Saved
    @ObservedObject var model: CamerasModel
    @State private var confirmRemove = false

    var body: some View {
        CameraRowLayout(title: camera.title, host: camera.host, isOpen: model.form == .edit(camera.url)) {
            Button("Edit") { model.openEdit(camera) }
                .disabled(model.busy)
        } form: {
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Name").gridColumnAlignment(.trailing)
                        TextField("", text: $model.name, prompt: Text(DeviceNames.get(camera.host) ?? "Nursery"))
                    }
                    if camera.quality != nil {
                        GridRow {
                            Text("Picture")
                            Picker("", selection: $model.quality) {
                                Text("High").tag(CamerasModel.Quality.high)
                                Text("Low").tag(CamerasModel.Quality.low)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                    GridRow {
                        Text("User")
                        TextField("", text: $model.user, prompt: Text("admin"))
                    }
                    GridRow {
                        Text("Password")
                        SecureField("", text: $model.password, prompt: Text("Unchanged"))
                    }
                }
                .textFieldStyle(.roundedBorder)
                .disabled(model.busy)
                FormButtons(model: model, primary: "Save", action: model.onSave, canSubmit: !model.user.isEmpty) {
                    Button("Remove…", role: .destructive) { confirmRemove = true }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                }
            }
            .confirmationDialog("Remove \(camera.title)?", isPresented: $confirmRemove) {
                Button("Remove", role: .destructive, action: model.onRemove)
            } message: {
                Text("ReoBaby stops watching it and forgets its password.")
            }
        }
    }
}

private struct FoundRow: View {
    let camera: CamerasModel.Found
    @ObservedObject var model: CamerasModel
    @FocusState private var focused: Bool

    var body: some View {
        CameraRowLayout(title: camera.title, host: camera.host, isOpen: model.form == .add(camera.host)) {
            Button("Add") { model.openAdd(camera.host, user: model.saved.first?.user ?? "admin") }
                .disabled(model.busy)
        } form: {
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("User").gridColumnAlignment(.trailing)
                        TextField("", text: $model.user, prompt: Text("admin"))
                    }
                    GridRow {
                        Text("Password")
                        SecureField("", text: $model.password, prompt: Text("Set in the Reolink app"))
                            .focused($focused)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .disabled(model.busy)
                FormButtons(model: model, primary: "Add Camera", action: model.onAdd,
                            canSubmit: !model.user.isEmpty && !model.password.isEmpty) { EmptyView() }
            }
            // After the row has grown, or the address field keeps the focus.
            .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focused = true } }
            .onChange(of: model.error) { if model.error != nil { focused = true } }
        }
    }
}

/// Status or error on the left, Cancel and the form's action on the right.
private struct FormButtons<Leading: View>: View {
    @ObservedObject var model: CamerasModel
    let primary: String
    let action: () -> Void
    let canSubmit: Bool
    @ViewBuilder var leading: Leading

    var body: some View {
        HStack {
            if model.busy {
                ProgressView().controlSize(.small)
                Text("Logging in…").foregroundStyle(.secondary)
            } else if let error = model.error {
                Text(error).foregroundStyle(.red)
            } else {
                leading
            }
            Spacer()
            Button("Cancel") { model.form = nil }
                .keyboardShortcut(.cancelAction)
            Button(primary, action: action)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit || model.busy)
        }
        .font(.callout)
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
