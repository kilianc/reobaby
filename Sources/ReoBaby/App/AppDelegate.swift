import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var window: PlayerWindow!
    private var playerView: PlayerView!
    private var sink: RendererSink!
    private var player: CameraPlayer!
    private var cameras: [Camera] = []
    private var currentIndex = 0
    private var loadedConfig: Data?
    private var configWatcher: DispatchSourceFileSystemObject?
    private var reloadWork: DispatchWorkItem?
    private var promptOpen = false
    private var namesRequested = Set<String>()
    private var statusBar: StatusBarController!
    private var addCameras: AddCamerasController?
    private var offeredAddCameras = false
    private let alerts = Alerts()
    private var monitors: [String: CameraMonitor] = [:]
    private let defaults = UserDefaults.standard

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

    private var currentCamera: Camera? {
        cameras.indices.contains(currentIndex) ? cameras[currentIndex] : nil
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["muted": true, "pinned": true, "volume": 1.0])
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

        playerView.onMute = { [weak self] in self?.toggleMute(nil) }
        playerView.onPin = { [weak self] in self?.togglePin(nil) }
        playerView.onVolume = { [weak self] in self?.setVolume($0) }
        playerView.cameraMenu = { [weak self] in self?.makeCameraMenu() }
        playerView.contextMenu = { [weak self] in self?.makeContextMenu() }
        playerView.onKey = { [weak self] in self?.handleKey($0) ?? false }
        playerView.onControlsVisible = { [weak self] in self?.window.setTrafficLights(visible: $0) }

        volume = defaults.float(forKey: "volume")
        muted = defaults.bool(forKey: "muted")
        pinned = defaults.bool(forKey: "pinned")

        statusBar = StatusBarController(window: window)
        statusBar.populateMenu = { [weak self] in self?.populateStatusMenu($0) }
        statusBar.playerIsFloating = { [weak self] in
            guard let self else { return false }
            return self.pinned && self.window.isVisible && !self.window.isMiniaturized && self.window.isOnActiveSpace
        }
        statusBar.restorePlayerLevel = { [weak self] in self?.applyPinned() }
        alerts.onOpen = { [weak self] url in self?.openCamera(url: url) }
        alerts.onChange = { [weak self] isNew in self?.statusBar.setAlert(isNew) }
        alerts.requestAuthorization()

        reloadCameras(initial: true)
        watchConfig()

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(playerView)
        NSApp.activate()
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
        monitors.values.forEach { $0.stop() }
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
            playerView.showStatus("Waiting for keychain access…")
            DispatchQueue.global(qos: .userInitiated).async {
                for account in Set(accounts) { _ = Keychain.password(account: account) }
                DispatchQueue.main.async { self.reloadCameras(initial: initial, force: true) }
            }
            return
        }

        let previous = currentCamera
        cameras = list
        fetchDeviceNames()
        syncMonitors()
        guard !list.isEmpty else {
            player.stop()
            showNoCameras()
            return
        }
        let wanted = initial ? defaults.string(forKey: "camera") : previous?.url
        let index = list.firstIndex { $0.url == wanted } ?? list.firstIndex { $0.name == wanted } ?? 0
        if initial || list[index] != previous {
            select(index)
        } else {
            currentIndex = index
            refreshControls()
        }
    }

    /// Nothing to play yet: say how to add a camera, and offer to find them once per launch.
    private func showNoCameras() {
        playerView.showStatus("No cameras yet.\nReoBaby ▸ Add Cameras… (⌘N)")
        refreshControls()
        guard !offeredAddCameras else { return }
        offeredAddCameras = true
        DispatchQueue.main.async { self.showAddCameras(nil) }
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
        guard cameras.indices.contains(index) else { return }
        currentIndex = index
        let camera = cameras[index]
        defaults.set(camera.url, forKey: "camera")
        refreshControls()
        guard let endpoint = camera.endpoint() else {
            player.stop()
            playerView.showStatus("“\(camera.displayName)” needs an rtsp:// url")
            return
        }
        player.play(endpoint)
    }

    /// Fills in names for cameras that don't set one in cameras.json, from the camera itself.
    private func fetchDeviceNames() {
        for camera in cameras where camera.name == nil {
            guard let host = camera.host, !namesRequested.contains(host),
                  let ep = camera.endpoint(), let password = ep.password else { continue }
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
    }

    /// One background monitor per camera with a known password; restarted when its settings change.
    private func syncMonitors() {
        var wanted: [String: (Camera, RTSPEndpoint)] = [:]
        for camera in cameras {
            if let ep = camera.endpoint(), ep.password != nil { wanted[camera.url] = (camera, ep) }
        }
        for (url, monitor) in monitors where wanted[url].map({ $0.1 != monitor.endpoint || $0.0 != monitor.camera }) ?? true {
            monitor.stop()
            monitors[url] = nil
        }
        for (url, (camera, ep)) in wanted where monitors[url] == nil {
            let monitor = CameraMonitor(camera: camera, endpoint: ep)
            monitor.onEvent = { [weak self, weak monitor] event in
                guard let self, let monitor else { return }
                self.alerts.handle(event, from: monitor)
            }
            monitors[url] = monitor
            monitor.start()
        }
    }

    private func openCamera(url: String) {
        if let index = cameras.firstIndex(where: { $0.url == url }), index != currentIndex { select(index) }
        showPlayer(nil)
    }

    private func step(_ delta: Int) {
        guard cameras.count > 1 else { return }
        select((currentIndex + delta + cameras.count) % cameras.count)
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
        let name = currentCamera?.displayName ?? "camera"
        switch state {
        case .connecting:
            playerView.showStatus("Connecting to \(name)…")
        case .playing:
            playerView.showStatus(nil)
            fetchDeviceNames()
        case .retrying(let message):
            playerView.showStatus("\(message)\nRetrying…")
        case .authFailed:
            playerView.showStatus("\(name) needs a password")
            promptForPassword()
        }
    }

    private func applyVideoSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
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
            fetchDeviceNames()
            syncMonitors()
        }
    }

    // MARK: - Actions

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
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc func toggleNotifyMotion(_ sender: Any?) { alerts.notifyMotion.toggle() }
    @objc func toggleNotifySound(_ sender: Any?) { alerts.notifySound.toggle() }
    @objc func clearRecent(_ sender: Any?) { alerts.clearRecent() }

    @objc func showAddCameras(_ sender: Any?) {
        if let addCameras { return addCameras.show() }
        var configured: [String: String] = [:]
        for camera in cameras { if let host = camera.host { configured[host] = camera.displayName } }
        let controller = AddCamerasController(configured: configured, user: cameras.first?.user ?? "admin")
        controller.onFinish = { [weak self] added in
            guard let self else { return }
            self.addCameras = nil
            guard let first = added.first else { return }
            self.reloadCameras(force: true)
            self.openCamera(url: first)
        }
        addCameras = controller
        controller.show()
    }

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

    private func refreshControls() {
        playerView?.update(cameraName: currentCamera?.displayName, muted: muted, volume: volume, pinned: pinned)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 123: step(-1); return true // ←
        case 124, 48: step(1); return true // → / tab
        case 126: volumeUp(nil); return true // ↑
        case 125: volumeDown(nil); return true // ↓
        default: break
        }
        if let c = event.charactersIgnoringModifiers, let digit = Int(c), digit >= 1, digit <= cameras.count {
            select(digit - 1)
            return true
        }
        return false
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleMute(_:)):
            item.state = muted ? .on : .off
        case #selector(togglePin(_:)):
            item.state = pinned ? .on : .off
        case #selector(chooseCamera(_:)), #selector(chooseCameraAndShow(_:)):
            item.state = item.tag == currentIndex ? .on : .off
        case #selector(toggleNotifyMotion(_:)):
            item.state = alerts.notifyMotion ? .on : .off
        case #selector(toggleNotifySound(_:)):
            item.state = alerts.notifySound ? .on : .off
        case #selector(nextCamera(_:)), #selector(previousCamera(_:)):
            return cameras.count > 1
        default:
            break
        }
        return true
    }

    // MARK: - Menus

    private func cameraItems(withShortcuts: Bool) -> [NSMenuItem] {
        cameras.enumerated().map { index, camera in
            let key = withShortcuts && index < 9 ? "\(index + 1)" : ""
            let item = NSMenuItem(title: camera.displayName, action: #selector(chooseCamera(_:)), keyEquivalent: key)
            item.tag = index
            item.target = self
            return item
        }
    }

    private func populateStatusMenu(_ menu: NSMenu) {
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
        if !cameras.isEmpty { menu.addItem(.separator()) }
        menu.addItem(item("Show Player", #selector(showPlayer(_:))))
        menu.addItem(item("Float on Top", #selector(togglePin(_:))))
        menu.addItem(item("Mute", #selector(toggleMute(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Notify on Motion", #selector(toggleNotifyMotion(_:))))
        menu.addItem(item("Notify on Sound", #selector(toggleNotifySound(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Add Cameras…", #selector(showAddCameras(_:))))
        menu.addItem(item("Edit Cameras…", #selector(editCameras(_:))))
        let quit = NSMenuItem(title: "Quit ReoBaby", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quit)
    }

    private func makeCameraMenu() -> NSMenu {
        let menu = NSMenu()
        cameraItems(withShortcuts: false).forEach(menu.addItem)
        if !cameras.isEmpty { menu.addItem(.separator()) }
        menu.addItem(item("Add Cameras…", #selector(showAddCameras(_:))))
        menu.addItem(item("Edit Cameras…", #selector(editCameras(_:))))
        return menu
    }

    private func makeContextMenu() -> NSMenu {
        let menu = makeCameraMenu()
        menu.insertItem(.separator(), at: 0)
        menu.insertItem(item("Float on Top", #selector(togglePin(_:))), at: 0)
        menu.insertItem(item("Mute", #selector(toggleMute(_:))), at: 0)
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
        appMenu.addItem(withTitle: "About ReoBaby", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(item("Add Cameras…", #selector(showAddCameras(_:)), "n"))
        appMenu.addItem(item("Edit Cameras…", #selector(editCameras(_:)), ","))
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
        menu.addItem(item("Mute", #selector(toggleMute(_:)), "m", []))
        menu.addItem(item("Volume Up", #selector(volumeUp(_:)), String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), []))
        menu.addItem(item("Volume Down", #selector(volumeDown(_:)), String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), []))
        menu.addItem(item("Float on Top", #selector(togglePin(_:)), "t", []))
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
