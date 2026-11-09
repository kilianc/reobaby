import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

/// The panes of Settings, in toolbar order.
enum SettingsPane: String, CaseIterable {
    case general, cameras, notifications, sound, about

    var title: String {
        switch self {
        case .general: "General"
        case .cameras: "Cameras"
        case .notifications: "Notifications"
        case .sound: "Sound"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .cameras: "video"
        case .notifications: "bell.badge"
        case .sound: "speaker.wave.2"
        case .about: "info.circle"
        }
    }
}

final class SettingsModel: ObservableObject {
    @Published var pane: SettingsPane

    init(pane: SettingsPane) { self.pane = pane }
}

/// Settings… (⌘,): a toolbar of panes. Every setting is a user default, so it applies as soon as
/// it changes: AppDelegate watches the defaults, and the sound processing checks for changes.
@MainActor
final class SettingsController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    let cameras = CamerasController()
    /// Settings closed; the URLs of the cameras added while it was open.
    var onClose: (([String]) -> Void)?

    private let model: SettingsModel
    private let window: NSWindow

    override init() {
        let last = UserDefaults.standard.string(forKey: "settingsPane").flatMap(SettingsPane.init) ?? .general
        model = SettingsModel(pane: last)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PaneStack.width, height: 300),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()

        let host = NSHostingController(rootView: SettingsView(model: model, cameras: cameras.model, updater: .shared))
        host.sizingOptions = [.preferredContentSize]
        window.contentViewController = host
        let toolbar = NSToolbar(identifier: "Settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        // The player floats above other windows, so Settings has to as well.
        window.level = .floating
        window.delegate = self
        select(last)
    }

    func show(_ pane: SettingsPane? = nil) {
        if let pane { select(pane) }
        if !window.isVisible {
            window.center()
            if model.pane == .cameras { cameras.appear() }
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func select(_ pane: SettingsPane) {
        let appearing = pane == .cameras && model.pane != .cameras && window.isVisible
        model.pane = pane
        window.title = pane.title
        window.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(pane.rawValue)
        UserDefaults.standard.set(pane.rawValue, forKey: "settingsPane")
        if appearing { cameras.appear() }
    }

    @objc private func choosePane(_ item: NSToolbarItem) {
        if let pane = SettingsPane(rawValue: item.itemIdentifier.rawValue) { select(pane) }
    }

    func windowWillClose(_ notification: Notification) {
        let added = cameras.finish()
        DispatchQueue.main.async { self.onClose?(added) }
    }

    // MARK: - NSToolbarDelegate

    private var identifiers: [NSToolbarItem.Identifier] { SettingsPane.allCases.map { .init($0.rawValue) } }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = SettingsPane(rawValue: id.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(choosePane(_:))
        return item
    }
}

// MARK: - Panes

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    let cameras: CamerasModel
    let updater: Updater

    var body: some View {
        switch model.pane {
        case .general: GeneralPane(updater: updater)
        case .cameras: CamerasView(model: cameras)
        case .notifications: NotificationsPane()
        case .sound: SoundPane()
        case .about: AboutPane()
        }
    }
}

private struct GeneralPane: View {
    @ObservedObject var updater: Updater
    @AppStorage("pinned") private var pinned = true
    @AppStorage("showDockIcon") private var showDockIcon = true
    @AppStorage("autoUpdate") private var autoUpdate = true
    @State private var login = SMAppService.mainApp.status
    @State private var loginError: String?

    var body: some View {
        PaneStack {
            GroupedSection {
                Text("ReoBaby")
            } content: {
                SettingRow("Float on top", detail: "Keep the player above other windows.") {
                    Toggle("", isOn: $pinned).switchStyle()
                }
                RowDivider()
                SettingRow("Show in Dock", detail: "Turned off, ReoBaby lives in the menu bar only.") {
                    Toggle("", isOn: $showDockIcon).switchStyle()
                }
                RowDivider()
                SettingRow("Open at login", detail: loginDetail) {
                    Toggle("", isOn: Binding(get: { login == .enabled || login == .requiresApproval },
                                             set: setOpenAtLogin)).switchStyle()
                }
            }

            GroupedSection {
                Text("Updates")
            } content: {
                SettingRow("Check for updates automatically",
                           detail: "Downloads new versions in the background and installs them when ReoBaby quits.") {
                    Toggle("", isOn: $autoUpdate).switchStyle()
                }
                RowDivider()
                SettingRow("Version \(Updater.currentVersion)", detail: updater.settingsStatus) {
                    Button(updater.settingsButtonTitle) { updater.menuAction() }
                        .disabled(!updater.menuEnabled)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            login = SMAppService.mainApp.status
        }
    }

    private var loginDetail: String {
        if let loginError { return loginError }
        if login == .requiresApproval { return "Allow ReoBaby in System Settings ▸ General ▸ Login Items." }
        return "Start ReoBaby when you log in to your Mac."
    }

    private func setOpenAtLogin(_ on: Bool) {
        loginError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = error.localizedDescription
        }
        login = SMAppService.mainApp.status
        if login == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}

private struct NotificationsPane: View {
    @AppStorage("notifyMotion") private var motion = true
    @AppStorage("notifySound") private var sound = true
    @AppStorage("notifyCooldown") private var cooldown = 300.0
    @State private var denied = false

    private var waits: [Double] {
        let standard: [Double] = [60, 120, 300, 600, 900, 1800]
        return standard.contains(cooldown) ? standard : (standard + [cooldown]).sorted()
    }

    var body: some View {
        PaneStack {
            if denied {
                GroupedSection {
                    Text("Turned off")
                } content: {
                    SettingRow("Notifications are off for ReoBaby",
                               detail: "macOS isn't showing them. Turn them on in System Settings.") {
                        Button("Open System Settings") {
                            let id = Bundle.main.bundleIdentifier ?? "com.kilianciuffolo.cam"
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")!)
                        }
                    }
                }
            }

            GroupedSection {
                Text("Notify me about")
            } content: {
                SettingRow("Motion", detail: "Including people, vehicles and animals, on cameras that tell them apart.") {
                    Toggle("", isOn: $motion).switchStyle()
                }
                RowDivider()
                SettingRow("Sound", detail: "Crying and other sounds that stand out from the room's background noise.") {
                    Toggle("", isOn: $sound).switchStyle()
                }
            } footer: {
                Text("Notifications come from the camera you've chosen, even with the player closed. Pause and No Camera stop them.")
            }

            GroupedSection {
                Text("Quiet period")
            } content: {
                SettingRow("After a notification, wait",
                           detail: "That camera's next events are skipped meanwhile, so someone walking into the room gives one notification, not twenty.") {
                    Picker("", selection: $cooldown) {
                        ForEach(waits, id: \.self) { seconds in
                            Text(Self.describe(seconds)).tag(seconds)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        denied = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    private static func describe(_ seconds: Double) -> String {
        let minutes = seconds / 60
        if minutes == minutes.rounded() { return minutes == 1 ? "1 minute" : "\(Int(minutes)) minutes" }
        return "\(Int(seconds)) seconds"
    }
}

private struct SoundPane: View {
    @AppStorage("noiseReduction") private var reduction = SoundSettings.defaults["noiseReduction"]!
    @AppStorage("audioBoost") private var boost = SoundSettings.defaults["audioBoost"]!
    @AppStorage("compressorThreshold") private var threshold = SoundSettings.defaults["compressorThreshold"]!
    @AppStorage("compressorRatio") private var ratio = SoundSettings.defaults["compressorRatio"]!

    private var isDefault: Bool {
        SoundSettings.defaults.allSatisfy { UserDefaults.standard.object(forKey: $0.key) == nil }
    }

    var body: some View {
        PaneStack {
            GroupedSection {
                Text("Camera sound")
            } content: {
                SliderRow("Noise reduction", value: $reduction, in: 0...36, step: 3,
                          text: reduction == 0 ? "Off" : "\(Int(reduction)) dB",
                          detail: "Turns steady background noise down: a fan, a white-noise machine, microphone hiss. Sound notifications listen through it too.")
                RowDivider()
                SliderRow("Boost quiet sounds", value: $boost, in: 0...50, step: 5,
                          text: boost == 0 ? "Off" : "+\(Int(boost)) dB",
                          detail: "Quiet sounds are raised the most and loud ones less, so a whimper is easy to hear and a cry doesn't distort.")
            } footer: {
                Text("Changes apply right away, so you can adjust them while you listen.")
            }

            GroupedSection {
                Text("Compressor")
            } content: {
                SliderRow("Threshold", value: $threshold, in: -70...(-20), step: 5,
                          text: "\(Int(threshold)) dBFS",
                          detail: "Sounds quieter than this get the whole boost; louder ones get less.")
                RowDivider()
                SliderRow("Ratio", value: $ratio, in: 1...6, step: 0.5,
                          text: String(format: "%g:1", ratio),
                          detail: "Above that level, this many dB louder in comes out 1 dB louder.")
            }

            HStack {
                Spacer()
                Button("Restore Defaults") {
                    SoundSettings.defaults.keys.forEach(UserDefaults.standard.removeObject(forKey:))
                }
                .disabled(isDefault)
            }
        }
    }
}

private struct AboutPane: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("ReoBaby")
                .font(.title.weight(.semibold))
            Text("Version \(Updater.currentVersion) (\(Updater.currentBuild))")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("A tiny window for your Reolink cameras.\nAll local, no cloud.")
                .multilineTextAlignment(.center)
                .padding(.top, 6)
            HStack(spacing: 10) {
                Link("GitHub", destination: URL(string: "https://github.com/kilianc/reobaby")!)
                Text("·").foregroundStyle(.tertiary)
                Link("What's New", destination: URL(string: "https://github.com/kilianc/reobaby/blob/main/CHANGELOG.md")!)
            }
            .padding(.top, 2)
            Text(Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 10)
        }
        .padding(.vertical, 28)
        .frame(width: PaneStack.width)
    }
}

// MARK: - Building blocks

/// A pane's sections, stacked at the width every pane shares.
struct PaneStack<Content: View>: View {
    static var width: CGFloat { 500 }
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 18) { content }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 22)
            .frame(width: Self.width)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A title and an optional explanation on the left, a control on the right.
private struct SettingRow<Control: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder var control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            control
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

/// A slider with its title and value above it.
private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let text: String
    let detail: String

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double, text: String, detail: String) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.text = text
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(text)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
                .controlSize(.small)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct RowDivider: View {
    var body: some View { Divider().padding(.leading, 12) }
}

private extension Toggle {
    func switchStyle() -> some View {
        toggleStyle(.switch).controlSize(.small).labelsHidden()
    }
}
