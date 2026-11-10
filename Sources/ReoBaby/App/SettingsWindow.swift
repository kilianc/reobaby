import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

/// The panes of Settings, in toolbar order.
enum SettingsPane: String, CaseIterable {
    case general, cameras, notifications, sound, soothing, about

    var title: String {
        switch self {
        case .general: "General"
        case .cameras: "Cameras"
        case .notifications: "Notifications"
        case .sound: "Sound"
        case .soothing: "Soothing"
        case .about: "About"
        }
    }

    var icon: IconTile {
        switch self {
        case .general: .general
        case .cameras: .camera
        case .notifications: .notifications
        case .sound: .sound
        case .soothing: .soothing
        case .about: .about
        }
    }
}

final class SettingsModel: ObservableObject {
    @Published var pane: SettingsPane
    /// The pane is taller than the screen, so the window scrolls. Otherwise it never does, not
    /// even for the moment the window grows to a taller pane.
    @Published var scrolls = false
    /// The pane's height changed.
    var onHeight: ((CGFloat) -> Void)?

    init(pane: SettingsPane) { self.pane = pane }
}

/// The width every pane shares.
let paneWidth: CGFloat = 500

/// Settings… (⌘,): a toolbar of panes. Every setting is a user default, so it applies as soon as
/// it changes: AppDelegate watches the defaults, and the sound processing checks for changes.
/// The window fits each pane's height, growing and shrinking from its top edge.
@MainActor
final class SettingsController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    let cameras = CamerasController()
    /// Settings closed; the URLs of the cameras added while it was open.
    var onClose: (([String]) -> Void)?

    private let model: SettingsModel
    private let host: NSHostingController<SettingsView>
    private let window: NSWindow
    private var height: CGFloat = 0
    private var resizeScheduled = false
    private var activation: [NSObjectProtocol] = []

    override init() {
        let last = UserDefaults.standard.string(forKey: "settingsPane").flatMap(SettingsPane.init) ?? .general
        model = SettingsModel(pane: last)
        host = NSHostingController(rootView: SettingsView(model: model, cameras: cameras.model, updater: .shared))
        // No sizing constraints: with them, Auto Layout would snap the window to each pane's
        // height. The pane reports its height instead, and the window animates to it.
        host.sizingOptions = []
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: paneWidth, height: 400),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()

        window.contentViewController = host
        model.onHeight = { [weak self] height in
            guard let self, height != self.height else { return }
            self.height = height
            self.fitContent(animated: true)
        }

        let toolbar = NSToolbar(identifier: "Settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        if !window.setFrameUsingName("Settings") { window.center() }
        window.setFrameAutosaveName("Settings")

        // The player can float above other windows, so Settings does too while ReoBaby is in
        // front; behind another app, it's an ordinary window again.
        window.level = .floating
        let center = NotificationCenter.default
        activation = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.window.level = .floating }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.window.level = .normal }
            },
        ]
        select(last)
    }

    func show(_ pane: SettingsPane? = nil) {
        if let pane { select(pane) }
        if !window.isVisible {
            host.view.layoutSubtreeIfNeeded()
            if height == 0 { height = host.view.fittingSize.height }
            fitContent(animated: false)
            if model.pane == .cameras { cameras.appear() }
            Updater.shared.checkIfDue()
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

    /// Sizes the window to the pane, keeping its top edge in place. Animated, the resize waits
    /// for SwiftUI to finish laying out the pane, and a burst of size changes resizes once.
    private func fitContent(animated: Bool) {
        guard animated, window.isVisible else {
            if let frame = fittedFrame() { window.setFrame(frame, display: true) }
            return
        }
        guard !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [self] in
            resizeScheduled = false
            if let frame = fittedFrame() { window.setFrame(frame, display: true, animate: true) }
        }
    }

    private func fittedFrame() -> NSRect? {
        guard height > 0 else { return nil }
        let current = window.frame
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: paneWidth, height: height.rounded(.up)))
        frame.origin = NSPoint(x: current.minX, y: current.maxY - frame.height)
        // A pane taller than the screen scrolls, and the window stays on the screen.
        if let screen = (window.screen ?? NSScreen.main)?.visibleFrame {
            let scrolls = frame.height > screen.height
            if model.scrolls != scrolls { model.scrolls = scrolls }
            frame.size.height = min(frame.height, screen.height)
            frame.origin.y = min(max(current.maxY - frame.height, screen.minY), screen.maxY - frame.height)
        }
        return frame == current ? nil : frame
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
        item.image = pane.icon.image(size: 32)
        item.image?.accessibilityDescription = pane.title
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
        // The window is as tall as the pane, so this scrolls only on a screen too short for it.
        ScrollView(.vertical) {
            Group {
                switch model.pane {
                case .general: GeneralPane(updater: updater)
                case .cameras: CamerasView(model: cameras)
                case .notifications: NotificationsPane()
                case .sound: SoundPane()
                case .soothing: SoothingPane(soother: .shared)
                case .about: AboutPane()
                }
            }
            .frame(width: paneWidth)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { model.onHeight?($0) }
        }
        .scrollDisabled(!model.scrolls)
        .scrollIndicators(model.scrolls ? .automatic : .never)
        .scrollBounceBehavior(.basedOnSize)
        // While the window resizes, the pane stays pinned to its top.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct GeneralPane: View {
    @ObservedObject var updater: Updater
    @AppStorage("pinned") private var pinned = true
    @AppStorage("showDockIcon") private var showDockIcon = true
    @AppStorage("autoUpdate") private var autoUpdate = true
    @State private var login = SMAppService.mainApp.status
    @State private var loginError: String?
    @State private var notesShown = false

    var body: some View {
        PaneForm {
            Section {
                Toggle(isOn: Binding(get: { login == .enabled || login == .requiresApproval }, set: setOpenAtLogin)) {
                    Text("Open at login")
                    Text(loginDetail)
                }
                Toggle(isOn: $showDockIcon) {
                    Text("Show in Dock")
                    Text("When it's off, ReoBaby lives in the menu bar only.")
                }
                Toggle(isOn: $pinned) {
                    Text("Float on top")
                    Text("Keeps the player above other windows, on every Space.")
                }
            }

            Section {
                UpdateRow(updater: updater)
                if let latest = updater.latest, !latest.changes.isEmpty {
                    DisclosureGroup(isExpanded: $notesShown) {
                        ReleaseNotes(changes: latest.changes)
                    } label: {
                        Text("What's New in ReoBaby \(latest.version)")
                    }
                }
                Toggle(isOn: $autoUpdate) {
                    Text("Check for updates automatically")
                    Text("New versions download in the background and install when ReoBaby quits.")
                }
            } header: {
                Text("Software Update")
            } footer: {
                SectionNote("Every version's changes are in the [changelog](https://github.com/kilianc/reobaby/blob/main/CHANGELOG.md).")
            }
        }
        .onAppear {
            updater.checkIfDue()
            notesShown = updater.latest?.isNewer ?? false
        }
        // A new version's notes open by themselves; this version's stay folded.
        .onChange(of: updater.latest) { notesShown = updater.latest?.isNewer ?? false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            login = SMAppService.mainApp.status
        }
    }

    private var loginDetail: String {
        if let loginError { return loginError }
        if login == .requiresApproval { return "Allow ReoBaby in System Settings ▸ General ▸ Login Items." }
        return "Starts ReoBaby when you log in to your Mac."
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
        PaneForm {
            if denied {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.multicolor)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Notifications are off for ReoBaby")
                            Text("Turn them on in System Settings to hear about motion and sound.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("Open Settings…") {
                            let id = Bundle.main.bundleIdentifier ?? "com.kilianciuffolo.cam"
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")!)
                        }
                    }
                }
            }

            Section {
                Toggle(isOn: $motion) {
                    Text("Notify on motion")
                    Text("Including people, vehicles and animals, on cameras that tell them apart.")
                }
                Toggle(isOn: $sound) {
                    Text("Notify on sound")
                    Text("Crying and other sounds that stand out from the room's background noise.")
                }
            } footer: {
                SectionNote("Notifications come from the camera you've chosen, even with the player closed. Pause and No Camera stop them.")
            }

            Section {
                Picker(selection: $cooldown) {
                    ForEach(waits, id: \.self) { seconds in
                        Text(Self.describe(seconds)).tag(seconds)
                    }
                } label: {
                    Text("Quiet period")
                    Text("After a notification, that camera's next events wait this long, so someone walking into the room is one notification, not twenty.")
                }
            }
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        withAnimation { denied = status == .denied }
    }

    private static func describe(_ seconds: Double) -> String {
        let minutes = seconds / 60
        if minutes == minutes.rounded() { return minutes == 1 ? "1 minute" : "\(Int(minutes)) minutes" }
        return "\(Int(seconds)) seconds"
    }
}

private struct SoundPane: View {
    /// What SoundSettings uses while a setting isn't set; Restore Defaults unsets them.
    private static let defaults: [String: Double] = [
        "noiseReduction": 12, "audioBoost": 40, "compressorThreshold": -50, "compressorRatio": 2,
    ]

    @AppStorage("noiseReduction") private var reduction = defaults["noiseReduction"]!
    @AppStorage("audioBoost") private var boost = defaults["audioBoost"]!
    @AppStorage("compressorThreshold") private var threshold = defaults["compressorThreshold"]!
    @AppStorage("compressorRatio") private var ratio = defaults["compressorRatio"]!

    private var isDefault: Bool {
        reduction == Self.defaults["noiseReduction"] && boost == Self.defaults["audioBoost"]
            && threshold == Self.defaults["compressorThreshold"] && ratio == Self.defaults["compressorRatio"]
    }

    var body: some View {
        PaneForm {
            Section {
                SliderRow("Noise reduction", value: $reduction, in: 0...36, step: 3,
                          text: reduction == 0 ? "Off" : "\(Int(reduction)) dB",
                          detail: "Turns steady background noise down as you listen: a fan, a white-noise machine, microphone hiss. Sound notifications listen through at least 24 dB of it, and none when it's off.")
                SliderRow("Boost quiet sounds", value: $boost, in: 0...50, step: 5,
                          text: boost == 0 ? "Off" : "+\(Int(boost)) dB",
                          detail: "Quiet sounds are raised the most and loud ones less, so a whimper is easy to hear and a cry doesn't distort. The room's background noise isn't raised.")
            } header: {
                Text("Camera Sound")
            } footer: {
                SectionNote("Changes apply right away, so you can adjust them while you listen.")
            }

            Section {
                SliderRow("Threshold", value: $threshold, in: -70...(-20), step: 5,
                          text: "\(Int(threshold)) dBFS",
                          detail: "Sounds quieter than this get the whole boost; louder ones get less.")
                SliderRow("Ratio", value: $ratio, in: 1...6, step: 0.5,
                          text: String(format: "%g : 1", ratio),
                          detail: "Above the threshold, this many dB louder in comes out only 1 dB louder.")
            } header: {
                Text("Compressor")
            } footer: {
                HStack {
                    Spacer()
                    Button("Restore Defaults") {
                        withAnimation {
                            Self.defaults.keys.forEach(UserDefaults.standard.removeObject(forKey:))
                        }
                    }
                    .disabled(isDefault)
                }
            }
        }
    }
}

private struct AboutPane: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .accessibilityHidden(true)
            Text("ReoBaby")
                .font(.system(size: 26, weight: .bold))
                .padding(.top, 6)
            Text("Version \(Updater.currentVersion) (\(Updater.currentBuild))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 3)
            Text("A tiny window for your Reolink cameras.\nAll local, no cloud.")
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.top, 16)
            HStack(spacing: 12) {
                Button("GitHub") { openURL(URL(string: "https://github.com/kilianc/reobaby")!) }
                Button("What's New") { openURL(URL(string: "https://github.com/kilianc/reobaby/blob/main/CHANGELOG.md")!) }
            }
            .padding(.top, 20)
            Text(Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? "")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.top, 24)
        }
        .padding(.top, 28)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Software Update

/// ReoBaby's icon with a badge for where updates stand, what that means, and what to do next.
private struct UpdateRow: View {
    @ObservedObject var updater: Updater

    var body: some View {
        HStack(spacing: 12) {
            UpdateIcon(status: updater.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .contentTransition(.opacity)
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if case .ready = updater.status {
                Button("Restart to Update", action: updater.settingsAction)
                    .buttonStyle(.borderedProminent)
            } else {
                Button(isFailed ? "Try Again" : "Check Now", action: updater.settingsAction)
                    .disabled(isBusy || isUnavailable)
            }
        }
        .padding(.vertical, 2)
        .animation(.snappy, value: updater.status)
    }

    private var version: String { Updater.currentVersion }

    private var title: String {
        switch updater.status {
        case .unavailable, .notChecked: "ReoBaby \(version)"
        case .checking: "Checking for updates…"
        case .downloading(let new): "Downloading ReoBaby \(new)…"
        case .upToDate: "ReoBaby is up to date"
        case .ready(let new): "ReoBaby \(new) is ready"
        case .failed: "Couldn't check for updates"
        }
    }

    private var detail: String {
        switch updater.status {
        case .unavailable(let why): why
        case .notChecked: lastChecked.map { "Last checked \($0)." } ?? "Updates come from ReoBaby's releases on GitHub."
        case .checking: "You have version \(version)."
        case .downloading: "It installs when ReoBaby quits."
        case .upToDate: "Version \(version)" + (lastChecked.map { " · Checked \($0)" } ?? "")
        case .ready: "It installs when ReoBaby quits, or restart now."
        case .failed(let error): error
        }
    }

    private var lastChecked: String? {
        guard let date = updater.lastChecked else { return nil }
        if -date.timeIntervalSinceNow < 60 { return "just now" }
        return date.formatted(.relative(presentation: .named))
    }

    private var isBusy: Bool {
        switch updater.status {
        case .checking, .downloading: true
        default: false
        }
    }

    private var isFailed: Bool {
        if case .failed = updater.status { return true }
        return false
    }

    private var isUnavailable: Bool {
        if case .unavailable = updater.status { return true }
        return false
    }
}

/// The app icon, with a small animated badge: spinning arrows while checking, a pulsing arrow
/// while downloading, sparkles once an update is ready, a check mark when there's none.
private struct UpdateIcon: View {
    let status: Updater.Status
    @State private var celebrate = 0

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 42, height: 42)
            .scaleEffect(celebrate.isMultiple(of: 2) ? 1 : 1.08)
            .animation(.spring(response: 0.3, dampingFraction: 0.45), value: celebrate)
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    Circle()
                        .fill(badge.color.gradient)
                        .frame(width: 19, height: 19)
                        .overlay(symbol(badge.symbol))
                        .background(Circle().fill(.background).padding(-1.5))
                        .offset(x: 4, y: 3)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .accessibilityHidden(true)
            .onChange(of: status) { old, new in
                // A little hop when an update turns up.
                if case .ready = new, old != new {
                    celebrate += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { celebrate += 1 }
                }
            }
    }

    @ViewBuilder
    private func symbol(_ name: String) -> some View {
        let image = Image(systemName: name)
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(.white)
        switch status {
        case .checking:
            if #available(macOS 15, *) {
                image.symbolEffect(.rotate.byLayer, options: .repeat(.continuous))
            } else {
                image.symbolEffect(.pulse)
            }
        case .downloading:
            image.symbolEffect(.pulse)
        case .ready:
            image.symbolEffect(.bounce, value: celebrate)
        default:
            image
        }
    }

    private var badge: (symbol: String, color: Color)? {
        switch status {
        case .unavailable, .failed: ("exclamationmark", .orange)
        case .notChecked: nil
        case .checking: ("arrow.triangle.2.circlepath", .blue)
        case .downloading: ("arrow.down", .blue)
        case .upToDate: ("checkmark", .green)
        case .ready: ("sparkles", .pink)
        }
    }
}

/// A release's changes, as a bulleted list.
private struct ReleaseNotes: View {
    let changes: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("•").foregroundStyle(.secondary)
                    Text(Self.markdown(change))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.subheadline)
        .textSelection(.enabled)
        .padding(.vertical, 4)
    }

    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

// MARK: - Building blocks

/// The explanation under a section.
struct SectionNote: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            // In line with the section's header and rows.
            .padding(.horizontal, 10)
    }
}

/// A pane's sections, grouped like System Settings. The window is as tall as the pane, so the
/// form itself never scrolls; on a short screen, the window around it does.
struct PaneForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollDisabled(true)
    }
}

/// A slider the width of the row: its title and value above it, an explanation below.
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                Text(text)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: value))
                    .animation(.snappy(duration: 0.2), value: value)
            }
            Slider(value: $value, in: range, step: step) { Text(title) }
                .labelsHidden()
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// A white symbol on a coloured rounded square, like the icons in System Settings.
struct IconTile: View {
    let symbol: String
    let colors: [Color]
    var size: CGFloat = 26

    static let general = IconTile(symbol: "gearshape.fill", colors: [Color(white: 0.62), Color(white: 0.44)])
    static let camera = IconTile(symbol: "video.fill", colors: [Color(red: 0.64, green: 0.54, blue: 0.99), Color(red: 0.42, green: 0.32, blue: 0.84)])
    /// A camera on the network that isn't added yet.
    static let foundCamera = IconTile(symbol: "video.fill", colors: [Color(white: 0.70), Color(white: 0.52)])
    static let notifications = IconTile(symbol: "bell.badge.fill", colors: [Color(red: 1, green: 0.42, blue: 0.40), Color(red: 0.90, green: 0.19, blue: 0.21)])
    static let sound = IconTile(symbol: "speaker.wave.2.fill", colors: [Color(red: 1, green: 0.40, blue: 0.60), Color(red: 0.90, green: 0.17, blue: 0.40)])
    static let about = IconTile(symbol: "info", colors: [Color(red: 0.32, green: 0.64, blue: 1), Color(red: 0.08, green: 0.42, blue: 0.96)])

    func size(_ size: CGFloat) -> IconTile { IconTile(symbol: symbol, colors: colors, size: size) }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
            )
            .frame(width: size, height: size)
    }

    /// For the toolbar: the tile in a `size` square, at Retina scale. The toolbar puts the image
    /// right at the top of the selected item's highlight, so the tile is smaller than the square
    /// and sits a little low in it: even room above the tile and below its label.
    @MainActor
    func image(size: CGFloat) -> NSImage {
        let tile = self.size(size * 0.75)
            .padding(.top, size * 5 / 32)
            .padding(.bottom, size * 3 / 32)
            .padding(.horizontal, size / 8)
        let renderer = ImageRenderer(content: tile)
        renderer.scale = max(NSScreen.screens.map(\.backingScaleFactor).max() ?? 2, 2)
        return renderer.nsImage ?? NSImage()
    }
}
