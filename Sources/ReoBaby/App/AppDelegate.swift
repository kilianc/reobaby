import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var window: PlayerWindow!
    private var playerView: PlayerView!
    private var sink: RendererSink!
    private var player: CameraPlayer!
    private var cameras: [Camera] = []
    private var currentIndex = 0
    /// `currentIndex` when No Camera is chosen: the player is closed and no camera is connected.
    /// The "camera" default keeps the last camera watched, for Show Player.
    private static let noCamera = -1
    private var loadedConfig: Data?
    private var configWatcher: DispatchSourceFileSystemObject?
    private var reloadWork: DispatchWorkItem?
    private var promptOpen = false
    private var namesRequested = Set<String>()
    private var statusBar: StatusBarController!
    private var settings: SettingsController?
    private var offeredAddCameras = false
    private let alerts = Alerts()
    /// Motion and sound notifications for the chosen camera, even while the player is closed.
    private var monitor: CameraMonitor?
    private let defaults = UserDefaults.standard
    /// Pan, tilt and zoom for the camera in the player.
    private let ptz = PTZController()
    private var ptzHost: String?
    private var openedControlsAtLaunch = false

    /// Camera controls on screen: click to center, scales for pan, tilt and zoom.
    private var aiming = false {
        didSet {
            guard aiming != oldValue else { return }
            ptz.isActive = aiming
            if aiming {
                playerView.ptzOverlay.showHint("Click to center · Drag to frame · Scroll to zoom")
            }
            refreshControls()
        }
    }

    private var muted = true {
        didSet {
            sink.muted = muted
            defaults.set(muted, forKey: "muted")
            refreshControls()
        }
    }

    private var volume: Float = 1 {
        didSet {
            sink.volume = volume
            defaults.set(volume, forKey: "volume")
            refreshControls()
        }
    }

    private var pinned = true {
        didSet {
            applyPinned()
            defaults.set(pinned, forKey: "pinned")
            refreshControls()
        }
    }

    /// Paused, ReoBaby keeps no connection to any camera: no picture, no sound, no notifications.
    /// It isn't remembered, so ReoBaby always starts watching.
    private var paused = false {
        didSet {
            guard paused != oldValue else { return }
            if paused {
                player.stop()
                connectPTZ(nil)
                if !cameras.isEmpty { showPaused() }
            } else if cameras.isEmpty {
                reloadCameras(force: true)
            } else {
                select(currentIndex)
            }
            syncMonitor()
            refreshControls()
        }
    }

    private var showsDockIcon = true {
        didSet {
            defaults.set(showsDockIcon, forKey: "showDockIcon")
            applyDockIcon()
        }
    }

    private var currentCamera: Camera? {
        cameras.indices.contains(currentIndex) ? cameras[currentIndex] : nil
    }

    // MARK: - Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["muted": true, "pinned": true, "volume": 1.0, "showDockIcon": true])
        showsDockIcon = defaults.bool(forKey: "showDockIcon")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()

        playerView = PlayerView(frame: NSRect(x: 0, y: 0, width: 480, height: 270))
        window = PlayerWindow(contentView: playerView)
        if !window.setFrameUsingName("CamPlayer") {
            placeInCorner()
        }
        window.setFrameAutosaveName("CamPlayer")

        sink = RendererSink(layer: playerView.videoView.displayLayer)
        player = CameraPlayer(sink: sink)
        player.onState = { [weak self] in self?.handle($0) }
        player.onVideoSize = { [weak self] in self?.applyVideoSize($0) }

        playerView.onPause = { [weak self] in self?.togglePause(nil) }
        playerView.onMute = { [weak self] in self?.toggleMute(nil) }
        playerView.onPin = { [weak self] in self?.togglePin(nil) }
        playerView.onVolume = { [weak self] in self?.setVolume($0) }
        playerView.cameraMenu = { [weak self] in self?.makeCameraMenu() }
        playerView.contextMenu = { [weak self] in self?.makeContextMenu() }
        playerView.onKey = { [weak self] in self?.handleKey($0) ?? false }
        playerView.onControlsVisible = { [weak self] in self?.window.setTrafficLights(visible: $0) }
        playerView.onAim = { [weak self] in self?.toggleCameraControls(nil) }
        playerView.positionsMenu = { [weak self] in self?.makePositionsMenu() }
        playerView.ptzOverlay.controller = ptz
        ptz.onChange = { [weak self] in self?.ptzChanged() }
        ptz.onMoveEnded = { [weak self] in self?.playerView.ptzOverlay.moveEnded($0) }
        ptz.onError = { [weak self] in self?.playerView.ptzOverlay.showHint($0) }
        ptz.shouldPoll = { [weak self] in
            guard let self else { return false }
            return self.window.isVisible && !self.window.isMiniaturized
        }

        volume = defaults.float(forKey: "volume")
        muted = defaults.bool(forKey: "muted")
        pinned = defaults.bool(forKey: "pinned")

        statusBar = StatusBarController(window: window)
        statusBar.populateMenu = { [weak self] in self?.populateStatusMenu($0) }
        statusBar.playerIsFloating = { [weak self] in
            guard let self else { return false }
            // With No Camera there's nothing to peek at either.
            if self.currentIndex == Self.noCamera && !self.cameras.isEmpty { return true }
            return self.pinned && self.window.isVisible && !self.window.isMiniaturized && self.window.isOnActiveSpace
        }
        statusBar.restorePlayerLevel = { [weak self] in self?.applyPinned() }
        alerts.onOpen = { [weak self] url in self?.openCamera(url: url) }
        alerts.onChange = { [weak self] isNew in self?.statusBar.setAlert(isNew) }
        alerts.requestAuthorization()

        // Settings writes user defaults; apply what changed.
        SoundSettings.refresh()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.defaultsChanged() }
        }

        reloadCameras(initial: true)
        watchConfig()

        if !Self.noCameraSaved(defaults) { window.makeKeyAndOrderFront(nil) }
        window.makeFirstResponder(playerView)
        // Opens Settings on a pane at launch, in front of the player, for demos and screenshots.
        if let pane = ProcessInfo.processInfo.environment["REOBABY_SETTINGS"].flatMap(SettingsPane.init) {
            openSettings(pane)
        }
        NSApp.activate()
        Updater.shared.start()
    }

    /// Closing the player keeps ReoBaby in the menu bar, still watching for motion and sound.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPlayer(nil)
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if window != nil { reloadCameras() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        player?.stop()
        monitor?.stop()
        Updater.shared.installIfReady()
    }

    private func placeInCorner() {
        guard let screen = NSScreen.main else { return }
        let size = NSSize(width: 480, height: 270)
        let visible = screen.visibleFrame
        window.setFrame(NSRect(x: visible.maxX - size.width - 20, y: visible.minY + 20,
                               width: size.width, height: size.height), display: false)
    }

    // MARK: - Cameras

    private func reloadCameras(initial: Bool = false, force: Bool = false) {
        let data: Data
        do {
            data = try ConfigStore.read()
        } catch {
            ConfigStore.writeTemplateIfMissing()
            loadedConfig = nil
            cameras = []
            player.stop()
            connectPTZ(nil)
            syncMonitor()
            showNoCameras()
            return
        }
        guard data != loadedConfig || initial || force else { return }
        loadedConfig = data

        let list: [Camera]
        do {
            list = try ConfigStore.decode(data).filter { $0.url != ConfigStore.templateURL }
        } catch {
            playerView.showStatus("cameras.json has an error:\n\(Self.describe(error))")
            return
        }
        // Read passwords in the background first, so a keychain prompt never freezes the UI.
        let accounts = list.compactMap(\.keychainAccount).filter { !Keychain.isLoaded($0) }
        if !accounts.isEmpty {
            // Usually instant; worth a word only when macOS stops to ask for keychain access.
            let waiting = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                self?.playerView.showStatus("Waiting for keychain access…")
            }
            DispatchQueue.global(qos: .userInitiated).async {
                for account in Set(accounts) { _ = Keychain.password(account: account) }
                DispatchQueue.main.async {
                    waiting.cancel()
                    self.reloadCameras(initial: initial, force: true)
                }
            }
            return
        }

        let previous = currentCamera
        cameras = list
        guard !list.isEmpty else {
            player.stop()
            connectPTZ(nil)
            syncMonitor()
            showNoCameras()
            return
        }
        let none = initial ? Self.noCameraSaved(defaults) : currentIndex == Self.noCamera
        let wanted = initial ? defaults.string(forKey: "camera") : previous?.url
        let index = none ? Self.noCamera
            : list.firstIndex { $0.url == wanted } ?? list.firstIndex { $0.name == wanted } ?? 0
        if initial || (list.indices.contains(index) ? list[index] : nil) != previous {
            select(index)
        } else {
            currentIndex = index
            syncMonitor()
            refreshControls()
        }
    }

    /// Nothing to play yet: say how to add a camera, and offer to find them once per launch.
    private func showNoCameras() {
        playerView.showStatus("No cameras yet.\nReoBaby ▸ Settings… (⌘,)")
        refreshControls()
        guard !offeredAddCameras else { return }
        offeredAddCameras = true
        DispatchQueue.main.async { self.showCameras(nil) }
    }

    private static func describe(_ error: Error) -> String {
        if case DecodingError.dataCorrupted(let ctx) = error {
            return (ctx.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String ?? ctx.debugDescription
        }
        if case DecodingError.keyNotFound(let key, _) = error { return "missing \"\(key.stringValue)\"" }
        if case DecodingError.typeMismatch(_, let ctx) = error { return ctx.debugDescription }
        return error.localizedDescription
    }

    private func select(_ index: Int) {
        guard index == Self.noCamera || cameras.indices.contains(index) else { return }
        let reopening = currentIndex == Self.noCamera && index != Self.noCamera
        currentIndex = index
        defaults.set(index == Self.noCamera, forKey: "noCamera")
        if let camera = currentCamera { defaults.set(camera.url, forKey: "camera") }
        syncMonitor()
        refreshControls()
        guard let camera = currentCamera else {
            player.stop()
            connectPTZ(nil)
            playerView.showStatus(nil)
            return window.orderOut(nil)
        }
        // A camera chosen while No Camera had closed the player opens it again.
        if reopening { showPlayer(nil) }
        guard !paused else {
            player.stop()
            connectPTZ(nil)
            return showPaused()
        }
        guard let endpoint = camera.endpoint() else {
            player.stop()
            connectPTZ(nil)
            playerView.showStatus("“\(camera.displayName)” needs an rtsp:// url")
            return
        }
        player.play(endpoint)
        connectPTZ(endpoint)
    }

    /// Camera controls talk to the camera in the player, over its HTTP API.
    /// `REOBABY_PTZ_DEMO=1` gives every camera a pretend motor instead, for demos and testing.
    private func connectPTZ(_ endpoint: RTSPEndpoint?) {
        let demo = ProcessInfo.processInfo.environment["REOBABY_PTZ_DEMO"] == "1"
        let key = endpoint.map { "\($0.user ?? "")@\($0.host)/\($0.password ?? "")" }
        guard key != ptzHost else { return }
        ptzHost = key
        guard let endpoint, let password = endpoint.password ?? (demo ? "" : nil) else {
            ptz.connect(nil)
            return
        }
        ptz.connect(demo ? PTZSimulator() : CameraAPI(host: endpoint.host, user: endpoint.user ?? "admin", password: password))
    }

    private func ptzChanged() {
        let state = ptz.state
        if aiming && !state.available { aiming = false }
        // Opens camera controls once at launch, for demos and screenshots.
        if state.available, !openedControlsAtLaunch, ProcessInfo.processInfo.environment["REOBABY_CAMERA_CONTROLS"] == "1" {
            openedControlsAtLaunch = true
            aiming = true
        }
        playerView.videoView.digitalZoom = state.digitalZoom
        playerView.ptzOverlay.update()
        refreshControls()
    }

    /// ReoBaby 1.3.0 saved No Camera as an empty "camera".
    private static func noCameraSaved(_ defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: "noCamera") || defaults.string(forKey: "camera") == ""
    }

    private func showPaused() {
        playerView.showStatus("Paused\nPress Space to resume")
    }

    /// Fills in the chosen camera's name from the camera itself, if cameras.json doesn't set one.
    /// Other cameras keep the name they had when added or last watched: ReoBaby doesn't connect to them.
    private func fetchDeviceName() {
        guard let camera = currentCamera, camera.name == nil, let host = camera.host, !namesRequested.contains(host),
              let ep = camera.endpoint(), let password = ep.password else { return }
        namesRequested.insert(host)
        CameraAPI(host: host, user: ep.user ?? "admin", password: password).deviceName { [weak self] name in
            guard let self else { return }
            guard let name else {
                self.namesRequested.remove(host) // retry on a later trigger
                return
            }
            DeviceNames.set(name, host: host)
            self.refreshControls()
        }
    }

    /// Notifications come from the chosen camera only: ReoBaby keeps no connection to the others,
    /// and none at all with No Camera or while paused. Restarted when the camera's settings change.
    private func syncMonitor() {
        let camera = paused ? nil : currentCamera
        let endpoint = camera?.endpoint().flatMap { $0.password == nil ? nil : $0 }
        if let current = monitor, current.camera != camera || current.endpoint != endpoint {
            current.stop()
            monitor = nil
        }
        if monitor == nil, let camera, let endpoint {
            let new = CameraMonitor(camera: camera, endpoint: endpoint)
            new.onEvent = { [weak self, weak new] event in
                guard let self, let new else { return }
                self.alerts.handle(event, from: new)
            }
            monitor = new
            new.start()
        }
        // Watching nothing looks like Pause on the moon, whichever way it came about.
        statusBar.setPaused(paused || (camera == nil && !cameras.isEmpty))
    }

    private func openCamera(url: String) {
        if let index = cameras.firstIndex(where: { $0.url == url }), index != currentIndex { select(index) }
        showPlayer(nil)
    }

    private func step(_ delta: Int) {
        guard cameras.count > 1 || (currentIndex == Self.noCamera && !cameras.isEmpty) else { return }
        let from = currentIndex == Self.noCamera ? (delta > 0 ? -1 : cameras.count) : currentIndex
        select((from + delta + cameras.count) % cameras.count)
    }

    private func watchConfig() {
        try? FileManager.default.createDirectory(at: ConfigStore.directory, withIntermediateDirectories: true)
        let fd = open(ConfigStore.directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.reloadWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.reloadCameras() }
            self.reloadWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        configWatcher = source
    }

    // MARK: - Player state

    private func handle(_ state: CameraPlayer.State) {
        // A state the player sent just before it was stopped.
        guard !paused, currentCamera != nil else { return }
        let name = currentCamera?.displayName ?? "camera"
        switch state {
        case .connecting:
            playerView.showStatus("Connecting to \(name)…")
        case .playing:
            playerView.showStatus(nil)
            fetchDeviceName()
        case .retrying(let message):
            playerView.showStatus("\(message)\nRetrying…")
        case .authFailed:
            playerView.showStatus("\(name) needs a password")
            promptForPassword()
        }
    }

    private func applyVideoSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        playerView.videoSize = size
        window.contentAspectRatio = size
        guard !window.styleMask.contains(.fullScreen) else { return }
        var frame = window.frame
        let height = (frame.width * size.height / size.width).rounded()
        guard abs(height - frame.height) > 1 else { return }
        frame.origin.y += frame.height - height
        frame.size.height = height
        window.setFrame(frame, display: true, animate: true)
    }

    private func promptForPassword() {
        guard !promptOpen, let camera = currentCamera, let endpoint = camera.endpoint() else { return }
        promptOpen = true
        let index = currentIndex
        DispatchQueue.main.async { [self] in
            defer { promptOpen = false }
            let alert = NSAlert()
            alert.messageText = endpoint.password == nil
                ? "Password for “\(camera.displayName)”"
                : "“\(camera.displayName)” rejected the password"
            alert.informativeText = "Camera login for \(endpoint.user ?? "admin") at \(endpoint.host). Saved to your login keychain."

            let width: CGFloat = 260
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: width, height: 22))
            let applyAll = NSButton(checkboxWithTitle: "Use for all cameras", target: nil, action: nil)
            applyAll.state = .on
            let accessory = NSView()
            if cameras.count > 1 {
                accessory.frame = NSRect(x: 0, y: 0, width: width, height: 52)
                field.frame.origin.y = 30
                applyAll.frame = NSRect(x: 0, y: 0, width: width, height: 20)
                accessory.addSubview(applyAll)
            } else {
                accessory.frame = NSRect(x: 0, y: 0, width: width, height: 22)
            }
            accessory.addSubview(field)
            alert.accessoryView = accessory
            alert.addButton(withTitle: "Connect")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field

            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
            let targets = cameras.count > 1 && applyAll.state == .on ? cameras : [camera]
            for target in targets {
                if let ep = target.endpoint() {
                    Keychain.setPassword(field.stringValue, account: Camera.keychainAccount(ep))
                }
            }
            if currentIndex == index { select(index) }
            syncMonitor()
        }
    }

    // MARK: - Actions

    @objc func togglePause(_ sender: Any?) { paused.toggle() }
    @objc func toggleMute(_ sender: Any?) { muted.toggle() }
    @objc func volumeUp(_ sender: Any?) { setVolume(volume + 0.1) }
    @objc func volumeDown(_ sender: Any?) { setVolume(volume - 0.1) }

    private func setVolume(_ value: Float) {
        let clamped = min(max(value, 0), 1)
        // Raising the volume while muted means "I want to hear it".
        if muted && clamped > volume { muted = false }
        volume = (clamped * 100).rounded() / 100
    }
    @objc func togglePin(_ sender: Any?) { pinned.toggle() }

    @objc func toggleCameraControls(_ sender: Any?) {
        guard ptz.state.available || aiming else { return }
        aiming.toggle()
        if aiming { showPlayer(nil) }
    }

    @objc func goToPosition(_ sender: NSMenuItem) {
        guard let preset = sender.representedObject as? PTZPresetBox else { return }
        ptz.goTo(preset.preset)
    }

    @objc func savePosition(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Save this position"
        alert.informativeText = "The camera keeps it, with the zoom, and the Reolink app shows it too."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        field.stringValue = ptz.nextPositionName
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reolink cameras keep names up to 31 characters.
        ptz.savePosition(named: String((name.isEmpty ? ptz.nextPositionName : name).prefix(31)))
    }

    @objc func removePosition(_ sender: NSMenuItem) {
        guard let preset = (sender.representedObject as? PTZPresetBox)?.preset else { return }
        let alert = NSAlert()
        alert.messageText = "Remove “\(preset.name)”?"
        alert.informativeText = "The camera forgets this position, in the Reolink app too."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ptz.remove(preset)
    }
    @objc func nextCamera(_ sender: Any?) { step(1) }
    @objc func previousCamera(_ sender: Any?) { step(-1) }

    @objc func chooseCamera(_ sender: NSMenuItem) { select(sender.tag) }

    @objc func chooseCameraAndShow(_ sender: NSMenuItem) {
        if sender.tag != currentIndex { select(sender.tag) }
        showPlayer(nil)
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? String { openCamera(url: url) }
    }

    @objc func showPlayer(_ sender: Any?) {
        statusBar?.setAlert(false)
        // The player is closed with No Camera: open it on the last camera watched.
        if currentIndex == Self.noCamera, !cameras.isEmpty {
            let last = defaults.string(forKey: "camera")
            select(cameras.firstIndex { $0.url == last } ?? 0)
        }
        // Without a Dock icon, the menu bar is the only way back after Hide ReoBaby (⌘H).
        if NSApp.isHidden { NSApp.unhide(nil) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc func clearRecent(_ sender: Any?) { alerts.clearRecent() }

    @MainActor @objc func showSettings(_ sender: Any?) { openSettings(nil) }
    @MainActor @objc func showCameras(_ sender: Any?) { openSettings(.cameras) }
    @MainActor @objc func showAbout(_ sender: Any?) { openSettings(.about) }

    @MainActor private func openSettings(_ pane: SettingsPane?) {
        if let settings { return settings.show(pane) }
        let controller = SettingsController()
        controller.cameras.onChange = { [weak self] in self?.reloadCameras(force: true) }
        controller.cameras.onOpenFile = { [weak self] in self?.editCameras(nil) }
        // A camera added in Settings plays once Settings closes.
        controller.onClose = { [weak self] added in
            if let first = added.first { self?.openCamera(url: first) }
        }
        settings = controller
        controller.show(pane)
    }

    /// A setting changed, most likely in Settings.
    @MainActor private func defaultsChanged() {
        let pinnedNow = defaults.bool(forKey: "pinned")
        if pinnedNow != pinned { pinned = pinnedNow }
        let dockNow = defaults.bool(forKey: "showDockIcon")
        if dockNow != showsDockIcon { showsDockIcon = dockNow }
        SoundSettings.refresh()
        Updater.shared.setAutomatic(defaults.object(forKey: "autoUpdate") as? Bool ?? true)
    }

    /// Opens cameras.json in a text editor, for what Settings ▸ Cameras doesn't cover.
    @objc func editCameras(_ sender: Any?) {
        ConfigStore.writeTemplateIfMissing()
        if !NSWorkspace.shared.open(ConfigStore.file),
           let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([ConfigStore.file], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func applyPinned() {
        window.level = pinned ? .floating : .normal
        window.collectionBehavior = pinned
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.fullScreenPrimary]
    }

    /// Without a Dock icon ReoBaby lives in the menu bar only, and leaves ⌘Tab too.
    private func applyDockIcon() {
        let policy: NSApplication.ActivationPolicy = showsDockIcon ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        let wasActive = NSApp.isActive
        NSApp.setActivationPolicy(policy)
        // Switching policy deactivates the app; stay in front if it was.
        if wasActive, window != nil { DispatchQueue.main.async { NSApp.activate() } }
    }

    private func refreshControls() {
        let name = currentCamera?.displayName ?? (cameras.isEmpty ? nil : "No Camera")
        playerView?.update(cameraName: name, paused: paused, muted: muted, volume: volume, pinned: pinned)
        playerView?.setCameraControls(available: ptz.state.available, shown: aiming,
                                      positions: ptz.state.ability?.presets == true)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        if aiming {
            // Arrows turn the camera a degree, ten with Shift; + and - zoom; Esc stops, then puts the controls away.
            let step = event.modifierFlags.contains(.shift) ? 10.0 : 1.0
            switch event.keyCode {
            case 123: ptz.nudge(pan: -step); return true
            case 124: ptz.nudge(pan: step); return true
            case 126: ptz.nudge(tilt: step); return true
            case 125: ptz.nudge(tilt: -step); return true
            case 24, 69: ptz.zoom(by: 1.25); return true // = + and keypad +
            case 27, 78: ptz.zoom(by: 1 / 1.25); return true // - and keypad -
            case 53:
                if ptz.state.moving { ptz.stop() } else { aiming = false }
                return true
            default: break
            }
        }
        if event.charactersIgnoringModifiers?.lowercased() == "c", ptz.state.available || aiming {
            toggleCameraControls(nil)
            return true
        }
        switch event.keyCode {
        case 123: step(-1); return true // ←
        case 124, 48: step(1); return true // → / tab
        case 126: volumeUp(nil); return true // ↑
        case 125: volumeDown(nil); return true // ↓
        case 49: togglePause(nil); return true // space
        default: break
        }
        if let c = event.charactersIgnoringModifiers, let digit = Int(c), !cameras.isEmpty, digit <= cameras.count {
            select(digit == 0 ? Self.noCamera : digit - 1)
            return true
        }
        return false
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(togglePause(_:)):
            item.title = paused ? "Resume" : "Pause"
        case #selector(toggleMute(_:)):
            item.state = muted ? .on : .off
        case #selector(togglePin(_:)):
            item.state = pinned ? .on : .off
        case #selector(toggleCameraControls(_:)):
            item.state = aiming ? .on : .off
            return ptz.state.available
        case #selector(chooseCamera(_:)), #selector(chooseCameraAndShow(_:)):
            item.state = item.tag == currentIndex ? .on : .off
        case #selector(nextCamera(_:)), #selector(previousCamera(_:)):
            return cameras.count > 1
        case #selector(updateAction(_:)):
            item.title = Updater.shared.menuTitle
            return Updater.shared.menuEnabled
        default:
            break
        }
        return true
    }

    @MainActor @objc func updateAction(_ sender: Any?) {
        Updater.shared.menuAction()
    }

    // MARK: - Menus

    /// The cameras, then No Camera.
    private func cameraItems(withShortcuts: Bool) -> [NSMenuItem] {
        guard !cameras.isEmpty else { return [] }
        let names = cameras.map(\.displayName) + ["No Camera"]
        return names.enumerated().map { index, name in
            let none = index == cameras.count
            let key = !withShortcuts ? "" : none ? "0" : index < 9 ? "\(index + 1)" : ""
            let item = NSMenuItem(title: name, action: #selector(chooseCamera(_:)), keyEquivalent: key)
            item.tag = none ? Self.noCamera : index
            item.target = self
            return item
        }
    }

    @MainActor private func populateStatusMenu(_ menu: NSMenu) {
        statusBar.setAlert(false)
        if !alerts.recent.isEmpty {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            for entry in alerts.recent {
                let when = formatter.localizedString(for: entry.date, relativeTo: Date())
                let recent = item("\(entry.text) · \(entry.cameraName) · \(when)", #selector(openRecent(_:)))
                recent.representedObject = entry.cameraURL
                recent.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil)
                menu.addItem(recent)
            }
            menu.addItem(item("Clear", #selector(clearRecent(_:))))
            menu.addItem(.separator())
        }
        for (index, camera) in cameras.enumerated() {
            let entry = item(camera.displayName, #selector(chooseCameraAndShow(_:)))
            entry.tag = index
            menu.addItem(entry)
        }
        if !cameras.isEmpty {
            let none = item("No Camera", #selector(chooseCamera(_:)))
            none.tag = Self.noCamera
            menu.addItem(none)
            menu.addItem(.separator())
        }
        menu.addItem(item("Show Player", #selector(showPlayer(_:))))
        menu.addItem(item(paused ? "Resume" : "Pause", #selector(togglePause(_:))))
        menu.addItem(item("Float on Top", #selector(togglePin(_:))))
        menu.addItem(item("Mute", #selector(toggleMute(_:))))
        menu.addItem(.separator())
        // Without a Dock icon there's no app menu, so Settings (and About in it) is here too.
        menu.addItem(item("Settings…", #selector(showSettings(_:))))
        menu.addItem(item(Updater.shared.menuTitle, #selector(updateAction(_:))))
        let quit = NSMenuItem(title: "Quit ReoBaby", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quit)
    }

    private func makeCameraMenu() -> NSMenu {
        let menu = NSMenu()
        cameraItems(withShortcuts: false).forEach(menu.addItem)
        if !cameras.isEmpty { menu.addItem(.separator()) }
        menu.addItem(item("Cameras…", #selector(showCameras(_:))))
        return menu
    }

    /// The camera's saved positions, and saving or removing one.
    private func makePositionsMenu() -> NSMenu {
        let menu = NSMenu()
        let presets = ptz.state.presets
        if presets.isEmpty {
            let none = NSMenuItem(title: "No Saved Positions", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for preset in presets {
            let go = item(preset.name, #selector(goToPosition(_:)))
            go.representedObject = PTZPresetBox(preset)
            menu.addItem(go)
        }
        menu.addItem(.separator())
        menu.addItem(item("Save Current Position…", #selector(savePosition(_:))))
        if !presets.isEmpty {
            let remove = NSMenuItem(title: "Remove", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for preset in presets {
                let entry = item(preset.name, #selector(removePosition(_:)))
                entry.representedObject = PTZPresetBox(preset)
                submenu.addItem(entry)
            }
            remove.submenu = submenu
            menu.addItem(remove)
        }
        return menu
    }

    private func makeContextMenu() -> NSMenu {
        let menu = makeCameraMenu()
        if ptz.state.available {
            menu.insertItem(.separator(), at: 0)
            if aiming, ptz.state.ability?.presets == true {
                let positions = NSMenuItem(title: "Positions", action: nil, keyEquivalent: "")
                positions.submenu = makePositionsMenu()
                menu.insertItem(positions, at: 0)
            }
            menu.insertItem(item("Camera Controls", #selector(toggleCameraControls(_:))), at: 0)
        }
        menu.insertItem(.separator(), at: 0)
        menu.insertItem(item("Float on Top", #selector(togglePin(_:))), at: 0)
        menu.insertItem(item("Mute", #selector(toggleMute(_:))), at: 0)
        menu.insertItem(item(paused ? "Resume" : "Pause", #selector(togglePause(_:))), at: 0)
        return menu
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "",
                      _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    private func buildMainMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(item("About ReoBaby", #selector(showAbout(_:))))
        appMenu.addItem(item("Check for Updates…", #selector(updateAction(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(showSettings(_:)), ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide ReoBaby", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit ReoBaby", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu, title: "ReoBaby")

        let controls = NSMenu(title: "Controls")
        controls.delegate = self
        main.addItem(submenu: controls, title: "Controls")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu: windowMenu, title: "Window")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
        menuNeedsUpdate(controls)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Controls" else { return }
        menu.removeAllItems()
        // Space is handled by the player itself, so a space typed in Settings never pauses.
        menu.addItem(item(paused ? "Resume" : "Pause", #selector(togglePause(_:))))
        menu.addItem(item("Mute", #selector(toggleMute(_:)), "m", []))
        menu.addItem(item("Volume Up", #selector(volumeUp(_:)), String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), []))
        menu.addItem(item("Volume Down", #selector(volumeDown(_:)), String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), []))
        menu.addItem(item("Float on Top", #selector(togglePin(_:)), "t", []))
        menu.addItem(item("Camera Controls", #selector(toggleCameraControls(_:)), "c", []))
        menu.addItem(.separator())
        menu.addItem(item("Next Camera", #selector(nextCamera(_:)), "]", []))
        menu.addItem(item("Previous Camera", #selector(previousCamera(_:)), "[", []))
        if !cameras.isEmpty {
            menu.addItem(.separator())
            cameraItems(withShortcuts: true).forEach(menu.addItem)
        }
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        submenu.title = title
        item.submenu = submenu
        addItem(item)
    }
}

/// A saved position, carried by a menu item.
final class PTZPresetBox: NSObject {
    let preset: PTZPreset
    init(_ preset: PTZPreset) { self.preset = preset }
}
