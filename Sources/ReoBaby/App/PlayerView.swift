import AppKit
import AVFoundation

/// The video, in an AVSampleBufferDisplayLayer that can be scaled up for digital zoom.
final class VideoView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()

    /// Crops into the middle of the picture: 1 shows all of it.
    var digitalZoom: CGFloat = 1 {
        didSet {
            guard digitalZoom != oldValue else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.25)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            displayLayer.setAffineTransform(CGAffineTransform(scaleX: digitalZoom, y: digitalZoom))
            CATransaction.commit()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.bounds = bounds
        displayLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class HUDButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

final class HUDSlider: NSSlider {
    override class var cellClass: AnyClass? {
        get { HUDSliderCell.self }
        set {}
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// White track and knob, QuickTime-style. The stock slider turns grey whenever its
/// window isn't key, which a floating player almost never is.
final class HUDSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let bar = NSRect(x: rect.minX, y: rect.midY - 1.5, width: rect.width, height: 3)
        NSColor.white.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        var filled = bar
        filled.size.width = max(0, min(bar.width, knobRect(flipped: flipped).midX - bar.minX))
        NSColor.white.setFill()
        NSBezierPath(roundedRect: filled, xRadius: 1.5, yRadius: 1.5).fill()
    }

    override func drawKnob(_ knobRect: NSRect) {
        let d: CGFloat = 11
        let knob = NSRect(x: knobRect.midX - d / 2, y: knobRect.midY - d / 2, width: d, height: d)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Video plus a QuickTime-style floating control strip that appears on hover.
final class PlayerView: NSView {
    let videoView = VideoView()
    let ptzOverlay = PTZOverlayView()
    private let hud = NSVisualEffectView()
    private let cameraButton = HUDButton()
    private let aimButton = HUDButton()
    private let positionsButton = HUDButton()
    private let pauseButton = HUDButton()
    private let muteButton = HUDButton()
    private let pinButton = HUDButton()
    private let volumeSlider = HUDSlider()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var hideTimer: Timer?
    private var controlsShown = false

    var onPause: (() -> Void)?
    var onMute: (() -> Void)?
    var onPin: (() -> Void)?
    var onVolume: ((Float) -> Void)?
    var cameraMenu: (() -> NSMenu?)?
    var contextMenu: (() -> NSMenu?)?
    var onKey: ((NSEvent) -> Bool)?
    var onControlsVisible: ((Bool) -> Void)?
    var onAim: (() -> Void)?
    var positionsMenu: (() -> NSMenu?)?

    /// The video's own size, for where the picture sits in the view.
    var videoSize: CGSize = CGSize(width: 16, height: 9) {
        didSet { ptzOverlay.videoSize = videoSize }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        videoView.frame = bounds
        videoView.autoresizingMask = [.width, .height]
        addSubview(videoView)
        ptzOverlay.frame = bounds
        ptzOverlay.autoresizingMask = [.width, .height]
        ptzOverlay.isHidden = true
        ptzOverlay.alphaValue = 0
        addSubview(ptzOverlay)

        statusLabel.alignment = .center
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let shadow = NSShadow()
        shadow.shadowColor = .black
        shadow.shadowBlurRadius = 4
        statusLabel.shadow = shadow
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        configure(cameraButton, symbol: nil, tip: "Switch camera", action: #selector(cameraClicked))
        cameraButton.image = symbol("chevron.up.chevron.down", size: 9, weight: .bold)
        cameraButton.imagePosition = .imageTrailing
        cameraButton.font = .systemFont(ofSize: 12, weight: .semibold)
        cameraButton.lineBreakMode = .byTruncatingTail
        cameraButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configure(pauseButton, symbol: "pause.fill", tip: "Pause (Space)", action: #selector(pauseClicked))
        configure(muteButton, symbol: "speaker.slash.fill", tip: "Mute (M)", action: #selector(muteClicked))
        configure(pinButton, symbol: "pin.fill", tip: "Float on top (T)", action: #selector(pinClicked))
        configure(aimButton, symbol: "scope", tip: "Camera controls (C)", action: #selector(aimClicked))
        configure(positionsButton, symbol: "bookmark", tip: "Saved positions", action: #selector(positionsClicked))
        aimButton.isHidden = true
        positionsButton.isHidden = true

        volumeSlider.minValue = 0
        volumeSlider.maxValue = 1
        volumeSlider.controlSize = .small
        volumeSlider.isContinuous = true
        volumeSlider.toolTip = "Volume (↑ ↓)"
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged)
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        volumeSlider.widthAnchor.constraint(equalToConstant: 64).isActive = true

        let stack = NSStackView(views: [cameraButton, pauseButton, muteButton, volumeSlider, aimButton, positionsButton, pinButton])
        stack.setCustomSpacing(6, after: volumeSlider)
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false

        hud.material = .hudWindow
        hud.blendingMode = .withinWindow
        hud.state = .active
        hud.appearance = NSAppearance(named: .darkAqua)
        hud.wantsLayer = true
        hud.layer?.cornerRadius = 15
        hud.layer?.masksToBounds = true
        hud.translatesAutoresizingMaskIntoConstraints = false
        controlsShown = ProcessInfo.processInfo.environment["REOBABY_PIN_CONTROLS"] == "1"
        hud.alphaValue = controlsShown ? 1 : 0
        hud.addSubview(stack)
        addSubview(hud)

        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),

            stack.leadingAnchor.constraint(equalTo: hud.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: hud.trailingAnchor),
            stack.topAnchor.constraint(equalTo: hud.topAnchor),
            stack.bottomAnchor.constraint(equalTo: hud.bottomAnchor),

            hud.centerXAnchor.constraint(equalTo: centerXAnchor),
            hud.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            hud.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -16),
            cameraButton.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            cameraButton.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func symbol(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .medium) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }

    private func configure(_ button: HUDButton, symbol name: String?, tip: String, action: Selector) {
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .white
        button.toolTip = tip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        if let name {
            button.image = symbol(name)
            button.imagePosition = .imageOnly
            button.widthAnchor.constraint(equalToConstant: 30).isActive = true
            button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
    }

    func update(cameraName: String?, paused: Bool, muted: Bool, volume: Float, pinned: Bool) {
        cameraButton.title = cameraName ?? "No camera"
        cameraButton.isHidden = cameraName == nil
        pauseButton.image = symbol(paused ? "play.fill" : "pause.fill")
        pauseButton.toolTip = paused ? "Resume (Space)" : "Pause (Space)"
        let speaker = muted ? "speaker.slash.fill"
            : volume < 0.01 ? "speaker.fill"
            : volume < 0.34 ? "speaker.wave.1.fill"
            : volume < 0.67 ? "speaker.wave.2.fill"
            : "speaker.wave.3.fill"
        muteButton.image = symbol(speaker)
        volumeSlider.floatValue = volume
        muteButton.toolTip = muted ? "Unmute (M)" : "Mute (M)"
        pinButton.image = symbol(pinned ? "pin.fill" : "pin.slash")
        pinButton.toolTip = pinned ? "Stop floating on top (T)" : "Float on top (T)"
    }

    /// Whether the camera has controls, and whether they are on screen.
    func setCameraControls(available: Bool, shown: Bool, positions: Bool) {
        aimButton.isHidden = !available
        positionsButton.isHidden = !(shown && positions)
        aimButton.image = symbol("scope", weight: shown ? .bold : .medium)
        aimButton.contentTintColor = shown ? .systemYellow : .white
        aimButton.toolTip = shown ? "Hide camera controls (C)" : "Camera controls (C)"
        guard shown != !ptzOverlay.isHidden || ptzOverlay.alphaValue != (shown ? 1 : 0) else { return }
        if shown {
            ptzOverlay.isHidden = false
            ptzOverlay.needsLayout = true
            window?.invalidateCursorRects(for: ptzOverlay)
        } else {
            ptzOverlay.reset()
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = shown ? 0.18 : 0.25
            ptzOverlay.animator().alphaValue = shown ? 1 : 0
        }, completionHandler: { [weak self] in
            guard let self, !shown, self.ptzOverlay.alphaValue == 0 else { return }
            self.ptzOverlay.isHidden = true
            self.window?.invalidateCursorRects(for: self.ptzOverlay)
        })
    }

    func showStatus(_ text: String?) {
        statusLabel.stringValue = text ?? ""
        statusLabel.isHidden = text == nil
    }

    @objc private func cameraClicked() {
        guard let menu = cameraMenu?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: cameraButton.bounds.height + 4), in: cameraButton)
        poke()
    }

    @objc private func aimClicked() { onAim?() }

    @objc private func positionsClicked() {
        guard let menu = positionsMenu?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: positionsButton.bounds.height + 4), in: positionsButton)
        poke()
    }

    @objc private func pauseClicked() { onPause?() }
    @objc private func muteClicked() { onMute?() }
    @objc private func volumeChanged() { onVolume?(volumeSlider.floatValue) }

    override func layout() {
        super.layout()
        // Too narrow for a slider: the speaker button alone still mutes.
        volumeSlider.isHidden = bounds.width < 250
    }
    @objc private func pinClicked() { onPin?() }

    // MARK: - Hover

    override var mouseDownCanMoveWindow: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { poke() }
    override func mouseMoved(with event: NSEvent) { poke() }

    override func mouseExited(with event: NSEvent) {
        hideTimer?.invalidate()
        setControls(visible: false)
    }

    private func poke() {
        setControls(visible: true)
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            self?.idleHide()
        }
    }

    private func idleHide() {
        guard let window else { return }
        let point = hud.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if hud.bounds.contains(point) {
            poke()
        } else {
            setControls(visible: false)
        }
    }

    private func setControls(visible: Bool) {
        // Debug aid for screenshots: REOBABY_PIN_CONTROLS=1 keeps the controls up.
        let visible = visible || ProcessInfo.processInfo.environment["REOBABY_PIN_CONTROLS"] == "1"
        guard visible != controlsShown else { return }
        controlsShown = visible
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = visible ? 0.15 : 0.4
            hud.animator().alphaValue = visible ? 1 : 0
        }
        ptzOverlay.setScales(visible: visible)
        onControlsVisible?(visible)
    }

    // MARK: - Input

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}

final class PlayerWindow: NSWindow {
    init(contentView view: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 480, height: 270),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "ReoBaby"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        backgroundColor = .black
        isReleasedWhenClosed = false
        contentMinSize = NSSize(width: 192, height: 108)
        contentView = view
        setTrafficLights(visible: false, animated: false)
    }

    func setTrafficLights(visible: Bool, animated: Bool = true) {
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = standardWindowButton(type) else { continue }
            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = visible ? 0.15 : 0.4
                    button.animator().alphaValue = visible ? 1 : 0
                }
            } else {
                button.alphaValue = visible ? 1 : 0
            }
        }
    }
}
