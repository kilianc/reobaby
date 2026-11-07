import AppKit

/// Menu bar icon. Hovering it "peeks" the player as a floating window under the icon
/// when the player isn't already floating on screen; clicking opens the menu.
final class StatusBarController: NSResponder, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let window: NSWindow
    private let statusMenu = NSMenu()

    /// Rebuilds the menu's items each time it opens.
    var populateMenu: ((NSMenu) -> Void)?
    /// Whether the player is already floating on top and visible (then hovering does nothing).
    var playerIsFloating: (() -> Bool)?
    /// Restores the player's normal window level/behaviour after a peek.
    var restorePlayerLevel: (() -> Void)?

    private var hoverWork: DispatchWorkItem?
    private var peek: (wasVisible: Bool, frame: NSRect, behavior: NSWindow.CollectionBehavior)?
    private var peekTimer: Timer?
    private var outsideTicks = 0

    init(window: NSWindow) {
        self.window = window
        super.init()
        statusMenu.delegate = self
        item.menu = statusMenu
        item.button?.image = Self.glyph(alert: false)
        item.button?.toolTip = "ReoBaby"
        if let button = item.button {
            button.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                                  owner: self, userInfo: nil))
        }
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey),
                                               name: NSWindow.didBecomeKeyNotification, object: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setAlert(_ on: Bool) {
        item.button?.image = Self.glyph(alert: on)
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        populateMenu?(menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        hoverWork?.cancel()
        endPeek()
    }

    // MARK: - Hover peek

    override func mouseEntered(with event: NSEvent) {
        guard peek == nil, playerIsFloating?() != true else { return }
        let work = DispatchWorkItem { [weak self] in self?.beginPeek() }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        hoverWork?.cancel()
    }

    private func beginPeek() {
        guard peek == nil, let button = item.button, let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }
        peek = (window.isVisible && !window.isMiniaturized, window.frame, window.collectionBehavior)
        setAlert(false)
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = window.frame.size
        let visible = screen.visibleFrame
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let y = visible.maxY - size.height - 6

        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.level = .floating
        window.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)
        window.alphaValue = 0
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; window.animator().alphaValue = 1 }

        outsideTicks = 0
        peekTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.checkPeek() }
    }

    private func checkPeek() {
        guard peek != nil else { return }
        let mouse = NSEvent.mouseLocation
        let overButton = item.button.flatMap { b in b.window.map { $0.convertToScreen(b.convert(b.bounds, to: nil)) } }?
            .insetBy(dx: -4, dy: -4).contains(mouse) ?? false
        let overWindow = window.frame.insetBy(dx: -10, dy: -10).contains(mouse)
        outsideTicks = overButton || overWindow ? 0 : outsideTicks + 1
        if outsideTicks >= 3 { endPeek() }
    }

    /// Clicking into the peeked player keeps it open where it is.
    @objc private func windowBecameKey() {
        guard let state = peek else { return }
        peekTimer?.invalidate()
        peek = nil
        window.collectionBehavior = state.behavior
        restorePlayerLevel?()
    }

    private func endPeek() {
        peekTimer?.invalidate()
        guard let state = peek else { return }
        peek = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; window.animator().alphaValue = 0 }) { [self] in
            window.setFrame(state.frame, display: false)
            window.collectionBehavior = state.behavior
            restorePlayerLevel?()
            if state.wasVisible {
                // Put it back behind whatever app the user is in.
                if let front = Self.frontmostOtherWindow() {
                    window.order(.below, relativeTo: front)
                }
            } else {
                window.orderOut(nil)
            }
            window.alphaValue = 1
        }
    }

    private static func frontmostOtherWindow() -> Int? {
        let pid = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.first {
            ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowOwnerPID as String] as? Int32) != pid
        }?[kCGWindowNumber as String] as? Int
    }

    // MARK: - Icon

    /// The app icon's moon-in-a-lens as a menu bar glyph; with a red dot when something happened.
    private static func glyph(alert: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let ink = alert ? NSColor.labelColor : NSColor.black
            ink.setStroke()
            ink.setFill()
            let ring = NSBezierPath(ovalIn: NSRect(x: 1.6, y: 1.6, width: 14.8, height: 14.8))
            ring.lineWidth = 1.6
            ring.stroke()
            // Crescent: a disc with a bite taken out of its upper right.
            NSGraphicsContext.saveGraphicsState()
            // Moon disc centred in the ring (centre 9, 9).
            NSBezierPath(ovalIn: NSRect(x: 4.5, y: 4.5, width: 9, height: 9)).addClip()
            let crescent = NSBezierPath(rect: NSRect(x: 0, y: 0, width: 18, height: 18))
            crescent.append(NSBezierPath(ovalIn: NSRect(x: 7.2, y: 6.5, width: 7.8, height: 7.8)))
            crescent.windingRule = .evenOdd
            crescent.fill()
            NSGraphicsContext.restoreGraphicsState()
            if alert {
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: NSRect(x: 11.8, y: 11.8, width: 6, height: 6)).fill()
            }
            return true
        }
        image.isTemplate = !alert
        return image
    }
}
