import AppKit
import SwiftUI

/// Settings ▸ Cameras: the cameras saved in ReoBaby, and the Reolink cameras on the network it could add.
/// A new camera is added the way Wi-Fi joins a network: Add… asks for its login, ReoBaby logs in
/// to check it, then the camera goes into cameras.json and its password into the login keychain.
/// A saved camera's Details… renames it, changes its picture or login, or removes it.
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

    /// The sheet that's open.
    enum Form: Hashable, Identifiable {
        case add(String)  // host
        case edit(String) // url
        var id: Self { self }
    }

    @Published var saved: [Saved] = []
    @Published var found: [Found] = []
    @Published var searching = false
    @Published var blocked = false
    @Published var address = ""
    @Published var fileError: String?

    /// The sheet that's open, and what's typed in it.
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
        PaneForm {
            if let fileError = model.fileError {
                Section {
                    Label {
                        Text(fileError)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                    }
                }
            }

            if !model.saved.isEmpty {
                Section("My Cameras") {
                    ForEach(model.saved) { camera in
                        CameraRow(icon: .camera, title: camera.title, host: camera.host) {
                            Button("Details…") { model.openEdit(camera) }
                        }
                    }
                }
            }

            Section {
                if model.blocked && model.found.isEmpty {
                    BlockedRow()
                } else if model.found.isEmpty {
                    Text(model.searching ? "Looking for cameras…"
                         : model.saved.isEmpty ? "No Reolink cameras found." : "No other cameras found.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.found) { camera in
                    CameraRow(icon: .foundCamera, title: camera.title, host: camera.host) {
                        Button("Add…") { model.openAdd(camera.host, user: model.saved.first?.user ?? "admin") }
                    }
                }
                AddressRow(model: model)
            } header: {
                HStack {
                    Text("On Your Network")
                    Spacer()
                    if model.searching {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(action: model.onSearch) { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                            .help("Look again")
                    }
                }
                .frame(height: 16)
            } footer: {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    SectionNote("ReoBaby logs in to each camera to check its password, then keeps it in your keychain.")
                    Button("Open cameras.json", action: model.onOpenFile)
                        .buttonStyle(.link)
                        .font(.subheadline)
                        .help("For what this pane doesn't cover")
                }
            }
        }
        .sheet(item: $model.form) { form in
            CameraSheet(form: form, model: model)
        }
    }
}

/// A camera's icon, name and address, with a button on the right.
private struct CameraRow<Trailing: View>: View {
    let icon: IconTile
    let title: String
    let host: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            icon.size(26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(host)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

/// Adds a camera that discovery doesn't find, by its address.
private struct AddressRow: View {
    @ObservedObject var model: CamerasModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 26 * 0.225, style: .continuous).fill(.quaternary))
            TextField("Address", text: $model.address, prompt: Text("Add by address, like 10.0.0.52"))
                .labelsHidden()
                .textFieldStyle(.plain)
                .onSubmit(model.onAddAddress)
            Button("Add…", action: model.onAddAddress)
                .disabled(model.address.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

private struct BlockedRow: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .symbolRenderingMode(.multicolor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("Local Network access is off")
                Text("ReoBaby needs it to look for cameras. You can still add one by its address.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Open Settings…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
            }
        }
    }
}

/// Add… asks for a new camera's login; Details… changes a saved camera's name, picture or
/// login, or removes it.
private struct CameraSheet: View {
    let form: CamerasModel.Form
    @ObservedObject var model: CamerasModel
    @State private var confirmRemove = false
    @FocusState private var focus: Field?

    private enum Field { case name, password }

    private var isAdd: Bool {
        if case .add = form { return true }
        return false
    }

    private var saved: CamerasModel.Saved? {
        guard case .edit(let url) = form else { return nil }
        return model.saved.first { $0.url == url }
    }

    private var host: String {
        switch form {
        case .add(let host): host
        case .edit(let url): saved?.host ?? url
        }
    }

    private var title: String {
        saved?.title ?? model.found.first { $0.host == host }?.title ?? "Reolink camera"
    }

    private var canSubmit: Bool {
        let hasUser = !model.user.trimmingCharacters(in: .whitespaces).isEmpty
        return isAdd ? hasUser && !model.password.isEmpty : hasUser
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                (isAdd ? IconTile.foundCamera : .camera).size(40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isAdd ? "Add \(title)" : title)
                        .font(.headline)
                    Text(host)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

            Form {
                Section {
                    if !isAdd {
                        TextField("Name", text: $model.name, prompt: Text(DeviceNames.get(host) ?? "Nursery"))
                            .focused($focus, equals: .name)
                        if saved?.quality != nil {
                            Picker("Picture", selection: $model.quality) {
                                Text("High").tag(CamerasModel.Quality.high)
                                Text("Low").tag(CamerasModel.Quality.low)
                            }
                            .pickerStyle(.segmented)
                            .fixedSize()
                        }
                    }
                    TextField("User", text: $model.user, prompt: Text("admin"))
                    SecureField("Password", text: $model.password, prompt: Text(isAdd ? "Required" : "Unchanged"))
                        .focused($focus, equals: .password)
                } footer: {
                    if isAdd {
                        SectionNote("The user and password set up for this camera in the Reolink app.")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .disabled(model.busy)

            HStack(spacing: 8) {
                if model.busy {
                    ProgressView().controlSize(.small)
                    Text("Logging in…").foregroundStyle(.secondary)
                } else if let error = model.error {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                } else if !isAdd {
                    Button("Remove…", role: .destructive) { confirmRemove = true }
                }
                Spacer(minLength: 12)
                Button("Cancel") { model.form = nil }
                    .keyboardShortcut(.cancelAction)
                Button(isAdd ? "Add Camera" : "Save", action: isAdd ? model.onAdd : model.onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit || model.busy)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 420)
        .defaultFocus($focus, isAdd ? .password : .name)
        .onChange(of: model.error) { if model.error != nil { focus = .password } }
        .confirmationDialog("Remove \(title)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive, action: model.onRemove)
        } message: {
            Text("ReoBaby stops watching it and forgets its password.")
        }
    }
}
