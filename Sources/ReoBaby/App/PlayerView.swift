import AppKit
import AVFoundation

/// View backed directly by an AVSampleBufferDisplayLayer.
final class VideoView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        return layer
    }

    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

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
    private let hud = NSVisualEffectView()
    private let cameraButton = HUDButton()
    private let muteButton = HUDButton()
    private let pinButton = HUDButton()
    private let volumeSlider = HUDSlider()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var hideTimer: Timer?
    private var controlsShown = false

    var onMute: (() -> Void)?
    var onPin: (() -> Void)?
    var onVolume: ((Float) -> Void)?
    var cameraMenu: (() -> NSMenu?)?
    var contextMenu: (() -> NSMenu?)?
    var onKey: ((NSEvent) -> Bool)?
    var onControlsVisible: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        videoView.frame = bounds
        videoView.autoresizingMask = [.width, .height]
        addSubview(videoView)

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
        configure(muteButton, symbol: "speaker.slash.fill", tip: "Mute (M)", action: #selector(muteClicked))
        configure(pinButton, symbol: "pin.fill", tip: "Float on top (T)", action: #selector(pinClicked))

        volumeSlider.minValue = 0
        volumeSlider.maxValue = 1
        volumeSlider.controlSize = .small
        volumeSlider.isContinuous = true
        volumeSlider.toolTip = "Volume (↑ ↓)"
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged)
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        volumeSlider.widthAnchor.constraint(equalToConstant: 64).isActive = true

        let stack = NSStackView(views: [cameraButton, muteButton, volumeSlider, pinButton])
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

    func update(cameraName: String?, muted: Bool, volume: Float, pinned: Bool) {
        cameraButton.title = cameraName ?? "No camera"
        cameraButton.isHidden = cameraName == nil
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

    func showStatus(_ text: String?) {
        statusLabel.stringValue = text ?? ""
        statusLabel.isHidden = text == nil
    }

    @objc private func cameraClicked() {
        guard let menu = cameraMenu?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: cameraButton.bounds.height + 4), in: cameraButton)
        poke()
    }

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
