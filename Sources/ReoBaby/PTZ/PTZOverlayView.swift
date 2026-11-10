import AppKit
import AVFoundation

/// Camera controls over the picture: click to center, drag a box to frame, scroll or pinch to
/// zoom, and sliding scales for pan, tilt and zoom along the edges.
final class PTZOverlayView: NSView {
    weak var controller: PTZController? {
        didSet { configureScales() }
    }

    /// The video's own size, for where the picture is inside the view.
    var videoSize = CGSize(width: 16, height: 9) {
        didSet { if videoSize != oldValue { needsLayout = true } }
    }

    private let panTape: TapeView
    private let tiltTape: TapeView
    private let zoomTape: TapeView
    private let centerMark = CAShapeLayer()
    private let reticle = CAShapeLayer()
    private let box = CAShapeLayer()
    private let boxLabel = CATextLayer()
    private let hint = NSTextField(labelWithString: "")
    private var hintWork: DispatchWorkItem?
    private var editor: NSTextField?
    private var editing: TapeView?

    private var press: NSPoint?
    private var boxing = false
    private var shownAbility: PTZAbility?
    /// What the reticle or the box marks, in camera units, while the camera turns to it.
    private var marked: (target: PTZPosition, focal: Double, size: CGSize?)?

    /// The picture trails the camera's own position reports by about this much.
    private let pictureDelay = CameraPlayer.latency + 0.25

    override init(frame: NSRect) {
        let blank = TapeView.Scale.linear(range: 0...1, span: 1, minor: 1, major: 1, label: { _ in "" }, readout: { _ in "" })
        panTape = TapeView(.horizontal, scale: blank)
        tiltTape = TapeView(.verticalRight, scale: blank)
        // Values grow downwards, so that dragging or scrolling up zooms in, as scrolling on the picture does.
        zoomTape = TapeView(.verticalLeft, reversed: true, scale: blank)
        super.init(frame: frame)
        wantsLayer = true

        for layer in [centerMark, reticle, box] {
            layer.fillColor = nil
            layer.lineCap = .round
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.55
            layer.shadowRadius = 2
            layer.shadowOffset = .zero
            self.layer?.addSublayer(layer)
        }
        centerMark.strokeColor = NSColor.white.withAlphaComponent(0.75).cgColor
        centerMark.lineWidth = 1.5
        reticle.strokeColor = NSColor.systemYellow.cgColor
        reticle.lineWidth = 1.5
        reticle.opacity = 0
        box.strokeColor = NSColor.systemYellow.cgColor
        box.lineWidth = 2
        box.opacity = 0
        boxLabel.fontSize = 11
        boxLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        boxLabel.foregroundColor = NSColor.systemYellow.cgColor
        boxLabel.alignmentMode = .center
        boxLabel.shadowOpacity = 0.7
        boxLabel.shadowRadius = 2
        boxLabel.shadowOffset = .zero
        boxLabel.opacity = 0
        layer?.addSublayer(boxLabel)

        hint.font = .systemFont(ofSize: 11.5, weight: .medium)
        hint.textColor = NSColor.white.withAlphaComponent(0.9)
        hint.alignment = .center
        hint.maximumNumberOfLines = 3
        hint.lineBreakMode = .byWordWrapping
        hint.alphaValue = 0
        let shadow = NSShadow()
        shadow.shadowColor = .black
        shadow.shadowBlurRadius = 3
        hint.shadow = shadow
        addSubview(hint)

        for tape in [panTape, tiltTape, zoomTape] { addSubview(tape) }
        panTape.onScrub = { [weak self] value, _ in self?.controller?.go(panDegrees: value) }
        tiltTape.onScrub = { [weak self] value, _ in self?.controller?.go(tiltDegrees: value) }
        zoomTape.onScrub = { [weak self] value, _ in self?.controller?.setMagnification(value) }
        for tape in [panTape, tiltTape, zoomTape] {
            tape.onEdit = { [weak self, weak tape] in if let tape { self?.edit(tape) } }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func configureScales() {
        guard let controller else { return }
        let g = controller.geometry
        panTape.scale = .linear(range: 0...g.degrees(g.panRange.upperBound), span: 100, minor: 5, major: 15,
                                label: { "\(Int($0.rounded()))" }, readout: { String(format: "%.1f°", $0) })
        tiltTape.scale = .linear(range: 0...g.degrees(g.tiltRange.upperBound), span: 66, minor: 5, major: 15,
                                 label: { "\(Int($0.rounded()))" }, readout: { String(format: "%.1f°", $0) })
        let stops: [(Double, Bool)] = [(1, true), (1.25, false), (1.5, true), (1.75, false), (2, true), (2.5, false),
                                       (3, true), (3.5, false), (4, true), (5, true), (6, true)]
        zoomTape.scale = TapeView.Scale(range: 1...g.maxMagnification, span: log(g.maxMagnification) * 1.25, logarithmic: true,
                                        ticks: { _ in stops.map { ($0.0, $0.1) } },
                                        label: { $0 == $0.rounded() ? "\(Int($0))×" : String(format: "%.1f×", $0) },
                                        readout: { String(format: "%.1f×", $0) })
    }

    // MARK: - Layout

    /// Where the picture is, inside the view.
    var videoRect: NSRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return bounds }
        return AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
    }

    override func layout() {
        super.layout()
        let video = videoRect
        let side: CGFloat = 54
        // Clear of the traffic lights on the left and the controls strip at the bottom.
        let top = video.maxY - 10 - TapeView.thickness
        let panWidth = min(video.width - 2 * 88, 460)
        panTape.isHidden = panWidth < 150 || !(controller?.state.ability?.panTilt ?? false)
        panTape.frame = NSRect(x: (video.midX - panWidth / 2).rounded(), y: top, width: panWidth, height: TapeView.thickness)
        let bottom = video.minY + 50
        let sideHeight = min(top - 10 - bottom, 240)
        let sideY = (bottom + (top - 10 - bottom - sideHeight) / 2).rounded()
        let roomForSides = sideHeight >= 110 && video.width >= 330
        tiltTape.isHidden = !roomForSides || !(controller?.state.ability?.panTilt ?? false)
        zoomTape.isHidden = !roomForSides || !(controller?.state.available ?? false)
        tiltTape.frame = NSRect(x: video.maxX - 10 - side, y: sideY, width: side, height: max(sideHeight, 0))
        zoomTape.frame = NSRect(x: video.minX + 10, y: sideY, width: side, height: max(sideHeight, 0))

        let hintWidth = min(hint.attributedStringValue.size().width + 20, video.width - 24)
        hint.preferredMaxLayoutWidth = hintWidth
        let hintHeight = hint.sizeThatFits(NSSize(width: hintWidth, height: 200)).height
        hint.frame = NSRect(x: video.midX - hintWidth / 2, y: video.minY + 52, width: hintWidth, height: hintHeight)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let center = CGPoint(x: video.midX, y: video.midY)
        let mark = CGMutablePath()
        for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
            mark.move(to: CGPoint(x: center.x + dx * 5, y: center.y + dy * 5))
            mark.addLine(to: CGPoint(x: center.x + dx * 12, y: center.y + dy * 12))
        }
        centerMark.path = mark
        CATransaction.commit()
        if let editing, let editor { editor.frame = editorFrame(for: editing) }
        update()
    }

    override func resetCursorRects() {
        addCursorRect(videoRect, cursor: .crosshair)
    }

    // MARK: - State

    /// Shows what the controller knows.
    func update() {
        guard let controller else { return }
        let state = controller.state
        let g = controller.geometry
        let focal = controller.focal
        if let position = state.position {
            let target = state.target ?? position
            if !panTape.isScrubbing {
                panTape.value = g.degrees(target.pan)
                panTape.actual = state.target == nil ? nil : g.degrees(position.pan)
            }
            if !tiltTape.isScrubbing {
                tiltTape.value = g.degrees(target.tilt)
                tiltTape.actual = state.target == nil ? nil : g.degrees(position.tilt)
            }
            let across = g.fieldOfView(focal: focal)
            let video = videoRect
            let up = 2 * atan(0.5 * Double(video.height / max(video.width, 1)) / focal) * 180 / .pi
            panTape.band = (g.degrees(position.pan) - across / 2)...(g.degrees(position.pan) + across / 2)
            tiltTape.band = (g.degrees(position.tilt) - up / 2)...(g.degrees(position.tilt) + up / 2)
        }
        if state.ability != shownAbility {
            shownAbility = state.ability
            needsLayout = true
        }
        panTape.active = state.moving
        tiltTape.active = state.moving
        if !zoomTape.isScrubbing {
            zoomTape.value = controller.targetMagnification
            zoomTape.actual = state.zoomTarget == nil ? nil : controller.currentMagnification
        }
        zoomTape.band = 1...(state.ability?.zoom == true ? g.maxOpticalMagnification : 1)
        zoomTape.active = state.zoomTarget != nil
        followMark()
    }

    /// Moves the reticle or box to where its target is in the picture now.
    private func followMark() {
        guard let controller, let marked, let position = controller.state.position else { return }
        let video = videoRect
        let focal = controller.focal
        guard let offset = controller.geometry.offset(of: marked.target, from: position, focal: focal) else { return }
        let point = CGPoint(x: video.midX + offset.x * video.width, y: video.midY + offset.y * video.width)
        let grow = focal / marked.focal
        DispatchQueue.main.asyncAfter(deadline: .now() + pictureDelay) { [weak self] in
            guard let self, self.marked?.target == marked.target else { return }
            if let size = marked.size {
                self.place(box: NSRect(x: point.x - size.width * grow / 2, y: point.y - size.height * grow / 2,
                                       width: size.width * grow, height: size.height * grow), duration: 0.5)
            } else {
                self.move(self.reticle, to: point, duration: 0.5)
            }
        }
    }

    /// The camera stopped.
    func moveEnded(_ result: PTZController.MoveResult) {
        guard let marked else { return }
        let target = marked.target
        DispatchQueue.main.asyncAfter(deadline: .now() + pictureDelay + 0.2) { [weak self] in
            guard let self, self.marked?.target == target else { return }
            self.marked = nil
            let video = self.videoRect
            if marked.size != nil {
                if result == .arrived { self.place(box: video.insetBy(dx: 6, dy: 6), duration: 0.35) }
                self.fade(self.box, after: 0.4)
                self.fade(self.boxLabel, after: 0.1)
            } else {
                if result == .arrived {
                    self.move(self.reticle, to: CGPoint(x: video.midX, y: video.midY), duration: 0.3)
                    let lock = CAKeyframeAnimation(keyPath: "transform.scale")
                    lock.values = [1, 0.72, 1]
                    lock.keyTimes = [0, 0.5, 1]
                    lock.beginTime = CACurrentMediaTime() + 0.3
                    lock.duration = 0.3
                    self.reticle.add(lock, forKey: "lock")
                }
                self.fade(self.reticle, after: result == .arrived ? 0.7 : 0)
            }
        }
    }

    // MARK: - Pointer

    private func offset(of point: NSPoint) -> CGPoint {
        let video = videoRect
        return CGPoint(x: (point.x - video.midX) / video.width, y: (point.y - video.midY) / video.width)
    }

    override func mouseDown(with event: NSEvent) {
        endEditing(commit: true)
        let point = convert(event.locationInWindow, from: nil)
        // The strip where a title bar would be still moves the window.
        if point.y > bounds.maxY - 26 {
            window?.performDrag(with: event)
            return
        }
        guard videoRect.contains(point) else { return }
        press = point
        boxing = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press, controller?.state.ability?.panTilt == true else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !boxing {
            guard hypot(point.x - press.x, point.y - press.y) > 6 else { return }
            boxing = true
            marked = nil
            reticle.removeAllAnimations()
            reticle.opacity = 0
            box.removeAllAnimations()
            box.opacity = 1
            boxLabel.opacity = 1
        }
        let video = videoRect
        let end = NSPoint(x: min(max(point.x, video.minX), video.maxX), y: min(max(point.y, video.minY), video.maxY))
        let rect = NSRect(x: min(press.x, end.x), y: min(press.y, end.y), width: abs(end.x - press.x), height: abs(end.y - press.y))
        place(box: rect, duration: 0)
        if let controller {
            let zoom = min(controller.currentMagnification / fraction(of: rect), controller.geometry.maxMagnification)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            boxLabel.string = String(format: "%.1f×", zoom)
            CATransaction.commit()
        }
    }

    /// How much of the picture a box takes, the tighter way.
    private func fraction(of rect: NSRect) -> Double {
        let video = videoRect
        return max(rect.width / video.width, rect.height / video.height, 0.02)
    }

    override func mouseUp(with event: NSEvent) {
        defer { press = nil; boxing = false }
        guard let press, let controller, controller.state.position != nil, controller.state.ability?.panTilt == true else { return }
        let video = videoRect
        if boxing, let path = box.path {
            let rect = path.boundingBoxOfPath
            guard rect.width > 8 || rect.height > 8 else {
                fade(box, after: 0)
                fade(boxLabel, after: 0)
                return
            }
            let center = offset(of: NSPoint(x: rect.midX, y: rect.midY))
            controller.frame(center: center, width: fraction(of: rect))
            if let target = controller.state.target {
                marked = (target, controller.focal, rect.size)
            }
        } else {
            let point = press
            guard video.contains(point) else { return }
            controller.aim(at: offset(of: point))
            guard let target = controller.state.target else { return }
            marked = (target, controller.focal, nil)
            showReticle(at: point)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let controller, controller.state.available else { return super.scrollWheel(with: event) }
        // Pushing away zooms in, whichever way the system scrolls.
        let delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        guard delta != 0 else { return }
        controller.zoom(by: exp(delta * (event.hasPreciseScrollingDeltas ? 0.006 : 0.08)))
    }

    override func magnify(with event: NSEvent) {
        controller?.zoom(by: 1 + event.magnification)
    }

    // MARK: - Reticle and box

    private func showReticle(at point: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = CGMutablePath()
        path.addEllipse(in: CGRect(x: -17, y: -17, width: 34, height: 34))
        for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
            path.move(to: CGPoint(x: dx * 17, y: dy * 17))
            path.addLine(to: CGPoint(x: dx * 24, y: dy * 24))
        }
        reticle.path = path
        reticle.bounds = .zero
        reticle.removeAllAnimations()
        reticle.position = point
        reticle.opacity = 1
        CATransaction.commit()
        let appear = CABasicAnimation(keyPath: "transform.scale")
        appear.fromValue = 1.6
        appear.toValue = 1
        appear.duration = 0.22
        appear.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.duration = 0.15
        reticle.add(appear, forKey: "appear")
        reticle.add(fadeIn, forKey: "fadeIn")
    }

    private func move(_ layer: CALayer, to point: CGPoint, duration: Double) {
        let from = layer.presentation()?.position ?? layer.position
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position = point
        CATransaction.commit()
        guard duration > 0 else { return }
        let animation = CABasicAnimation(keyPath: "position")
        animation.fromValue = NSValue(point: from)
        animation.toValue = NSValue(point: point)
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "position")
    }

    /// Corner brackets around a rectangle, with the zoom it stands for underneath.
    private func place(box rect: NSRect, duration: Double) {
        let path = CGMutablePath()
        let arm = min(14, rect.width / 3, rect.height / 3)
        for (corner, dx, dy) in [(CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0), (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
                                 (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0), (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0)] {
            path.move(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
        }
        let from = box.presentation()?.path ?? box.path
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        box.path = path
        boxLabel.frame = CGRect(x: rect.midX - 40, y: rect.minY - 20, width: 80, height: 16)
        boxLabel.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
        guard duration > 0, let from else { return }
        let animation = CABasicAnimation(keyPath: "path")
        animation.fromValue = from
        animation.toValue = path
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        box.add(animation, forKey: "path")
    }

    private func fade(_ layer: CALayer, after delay: Double) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = layer.presentation()?.opacity ?? layer.opacity
        animation.toValue = 0
        animation.beginTime = CACurrentMediaTime() + delay
        animation.duration = 0.35
        animation.fillMode = .backwards
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 0
        CATransaction.commit()
        layer.add(animation, forKey: "fade")
    }

    // MARK: - Hint

    /// A line of text above the controls strip for a few seconds.
    func showHint(_ text: String, for seconds: Double = 3) {
        hint.stringValue = text
        needsLayout = true
        hintWork?.cancel()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; hint.animator().alphaValue = 1 }
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { $0.duration = 0.6; self?.hint.animator().alphaValue = 0 }
        }
        hintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// The scales come and go with the controls strip, so the picture is clear while nobody is using it.
    func setScales(visible: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = visible ? 0.15 : 0.4
            for tape in [panTape, tiltTape, zoomTape] where !(tape.isScrubbing && !visible) {
                tape.animator().alphaValue = visible ? 1 : 0
            }
        }
    }

    /// Clears what a move left on screen, when the controls are put away.
    func reset() {
        endEditing(commit: false)
        marked = nil
        for layer in [reticle, box, boxLabel] {
            layer.removeAllAnimations()
            layer.opacity = 0
        }
        hintWork?.cancel()
        hint.alphaValue = 0
    }

    // MARK: - Typing a value

    private func editorFrame(for tape: TapeView) -> NSRect {
        let pill = tape.convert(tape.readoutFrame, to: self)
        return pill.insetBy(dx: -6, dy: -1)
    }

    private func edit(_ tape: TapeView) {
        endEditing(commit: false)
        let field = NSTextField()
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        field.alignment = .center
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = true
        field.backgroundColor = .white
        field.textColor = .black
        field.wantsLayer = true
        field.layer?.cornerRadius = 6
        field.stringValue = String(format: "%.1f", tape.value)
        field.target = self
        field.action = #selector(editorCommitted)
        field.delegate = self
        field.frame = editorFrame(for: tape)
        addSubview(field)
        editor = field
        editing = tape
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    @objc private func editorCommitted() {
        endEditing(commit: true)
    }

    private func endEditing(commit: Bool) {
        guard let editor, let tape = editing else { return }
        let text = editor.stringValue.replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: CharacterSet(charactersIn: "0123456789.-").inverted)
        self.editor = nil
        editing = nil
        editor.removeFromSuperview()
        window?.makeFirstResponder(superview)
        guard commit, let value = Double(text), let controller else { return }
        if tape === panTape {
            controller.go(panDegrees: value)
        } else if tape === tiltTape {
            controller.go(tiltDegrees: value)
        } else {
            controller.setMagnification(value)
        }
    }
}

extension PTZOverlayView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            endEditing(commit: false)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        endEditing(commit: true)
    }
}
