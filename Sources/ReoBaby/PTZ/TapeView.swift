import AppKit

/// A scale that slides under a fixed mark, like a gimbal's or an aircraft's heading tape: pan,
/// tilt and zoom in camera controls. The value under the mark is where the camera is going; a
/// small triangle shows where it is while it gets there, and a bar what the picture covers.
/// Drag or scroll the scale to move it, click a value to go there, double-click the readout to
/// type one.
final class TapeView: NSView {
    enum Orientation {
        case horizontal
        /// Ticks along the left edge, readout pointing left: the scale on the picture's right.
        case verticalRight
        /// The mirror image, for the picture's left.
        case verticalLeft
    }

    struct Scale {
        var range: ClosedRange<Double>
        /// How much of the scale shows, end to end; in natural-log units on a logarithmic scale.
        var span: Double
        var logarithmic = false
        /// Values with a tick, and which of them have a label.
        var ticks: (ClosedRange<Double>) -> [(value: Double, major: Bool)]
        var label: (Double) -> String
        var readout: (Double) -> String

        /// Ticks every `minor`, labelled every `major`.
        static func linear(range: ClosedRange<Double>, span: Double, minor: Double, major: Double,
                           label: @escaping (Double) -> String, readout: @escaping (Double) -> String) -> Scale {
            Scale(range: range, span: span, ticks: { visible in
                stride(from: (visible.lowerBound / minor).rounded(.down) * minor, through: visible.upperBound, by: minor).map {
                    ($0, abs(($0 / major).rounded() * major - $0) < minor / 10)
                }
            }, label: label, readout: readout)
        }
    }

    let orientation: Orientation
    /// Values grow down a vertical tape, or left on a horizontal one.
    let reversed: Bool
    var scale: Scale { didSet { canvas.needsDisplay = true } }
    var value = 0.0 { didSet { if value != oldValue { canvas.needsDisplay = true } } }
    var actual: Double? { didSet { if actual != oldValue { canvas.needsDisplay = true } } }
    var band: ClosedRange<Double>? { didSet { if band != oldValue { canvas.needsDisplay = true } } }
    /// The camera is moving: the readout turns yellow.
    var active = false { didSet { if active != oldValue { canvas.needsDisplay = true } } }

    /// A new value from a drag, scroll or click; `done` once the gesture has ended.
    var onScrub: ((Double, _ done: Bool) -> Void)?
    var onEdit: (() -> Void)?
    private(set) var isScrubbing = false

    private let background = NSVisualEffectView()
    private let canvas = Canvas()
    private let fade = CAGradientLayer()
    private var grab: (point: NSPoint, value: Double)?
    private var scrollEnd: DispatchWorkItem?

    static let thickness: CGFloat = 34

    init(_ orientation: Orientation, reversed: Bool = false, scale: Scale) {
        self.orientation = orientation
        self.reversed = reversed
        self.scale = scale
        super.init(frame: .zero)
        wantsLayer = true
        background.material = .hudWindow
        background.blendingMode = .withinWindow
        background.state = .active
        background.appearance = NSAppearance(named: .darkAqua)
        background.wantsLayer = true
        background.layer?.cornerRadius = 11
        background.layer?.masksToBounds = true
        addSubview(background)
        canvas.tape = self
        canvas.wantsLayer = true
        canvas.layer?.mask = fade
        addSubview(canvas)
        if orientation == .horizontal {
            fade.startPoint = CGPoint(x: 0, y: 0.5)
            fade.endPoint = CGPoint(x: 1, y: 0.5)
        } else {
            fade.startPoint = CGPoint(x: 0.5, y: 0)
            fade.endPoint = CGPoint(x: 0.5, y: 1)
        }
        fade.colors = [NSColor.clear, .black, .black, .clear].map(\.cgColor)
        fade.locations = [0, 0.16, 0.84, 1]
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        background.frame = bounds
        canvas.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = bounds
        CATransaction.commit()
    }

    // MARK: - Geometry

    private var length: CGFloat { orientation == .horizontal ? bounds.width : bounds.height }
    /// Points along the tape per unit of value, negative when values grow the other way.
    private var pointsPerUnit: Double { Double(length) / scale.span * (reversed ? -1 : 1) }
    private func t(_ v: Double) -> Double { scale.logarithmic ? log(max(v, 1e-6)) : v }
    private func v(_ t: Double) -> Double { scale.logarithmic ? exp(t) : t }

    /// Where a value is along the tape, from its start.
    fileprivate func offset(of v: Double) -> CGFloat {
        CGFloat((t(v) - t(value)) * pointsPerUnit) + length / 2
    }

    private func value(at offset: CGFloat) -> Double {
        v(t(value) + Double(offset - length / 2) / pointsPerUnit)
    }

    private func along(_ point: NSPoint) -> CGFloat { orientation == .horizontal ? point.x : point.y }

    fileprivate var visible: ClosedRange<Double> {
        let a = value(at: 0), b = value(at: length)
        return min(a, b)...max(a, b)
    }

    fileprivate var readoutRect: NSRect {
        let width = readoutText.size().width.rounded(.up)
        switch orientation {
        case .horizontal:
            let w = max(width + 14, 50)
            return NSRect(x: (bounds.midX - w / 2).rounded(), y: 13, width: w, height: 19)
        case .verticalRight, .verticalLeft:
            let w = min(width + 12, bounds.width - 4)
            return NSRect(x: (bounds.midX - w / 2).rounded(), y: (bounds.midY - 9.5).rounded(), width: w, height: 19)
        }
    }

    fileprivate var readoutText: NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: orientation == .horizontal ? 11 : 10.5, weight: .semibold)
        return NSAttributedString(string: scale.readout(value), attributes: [
            .font: font, .foregroundColor: NSColor.black.withAlphaComponent(0.85),
        ])
    }

    var readoutFrame: NSRect { readoutRect }

    // MARK: - Input

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01 else { return nil }
        return frame.contains(point) ? self : nil
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isScrubbing ? .closedHand : .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, readoutRect.insetBy(dx: -4, dy: -4).contains(point) {
            onEdit?()
            return
        }
        grab = (point, value)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grab else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !isScrubbing {
            guard abs(along(point) - along(grab.point)) > 2 else { return }
            isScrubbing = true
            NSCursor.closedHand.set()
        }
        // The scale follows the pointer, like a map.
        let moved = Double(along(point) - along(grab.point))
        scrub(to: v(t(grab.value) - moved / pointsPerUnit), done: false)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            grab = nil
            isScrubbing = false
            window?.invalidateCursorRects(for: self)
        }
        if isScrubbing {
            onScrub?(value, true)
        } else if grab != nil {
            let point = convert(event.locationInWindow, from: nil)
            guard !readoutRect.contains(point) else { return }
            scrub(to: value(at: along(point)), done: true)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // Content follows the fingers, as in any scroll view.
        let moved = orientation == .horizontal
            ? Double(event.scrollingDeltaX != 0 ? event.scrollingDeltaX : -event.scrollingDeltaY)
            : Double(-event.scrollingDeltaY)
        guard moved != 0 else { return }
        let points = event.hasPreciseScrollingDeltas ? moved : moved * 6
        isScrubbing = true
        scrub(to: v(t(value) - points / pointsPerUnit), done: false)
        scrollEnd?.cancel()
        let end = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isScrubbing = false
            self.onScrub?(self.value, true)
        }
        scrollEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: end)
    }

    private func scrub(to new: Double, done: Bool) {
        value = min(max(new, scale.range.lowerBound), scale.range.upperBound)
        onScrub?(value, done)
    }
}

private final class Canvas: NSView {
    weak var tape: TapeView?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let tape, let context = NSGraphicsContext.current?.cgContext else { return }
        let horizontal = tape.orientation == .horizontal
        let mirrored = tape.orientation == .verticalLeft
        let scale = tape.scale
        let length = horizontal ? bounds.width : bounds.height
        let depth = horizontal ? bounds.height : bounds.width

        /// A point `along` the tape and `across` it, from the edge the ticks stand on.
        func point(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
            switch tape.orientation {
            case .horizontal: return CGPoint(x: along, y: across)
            case .verticalRight: return CGPoint(x: across, y: along)
            case .verticalLeft: return CGPoint(x: depth - across, y: along)
            }
        }

        // Beyond the end stops: hatched.
        let low = tape.offset(of: scale.range.lowerBound), high = tape.offset(of: scale.range.upperBound)
        let first = min(low, high), last = max(low, high)
        context.saveGState()
        NSColor.white.withAlphaComponent(0.13).setStroke()
        for region in [(CGFloat(-depth), first), (last, length + depth)] where region.0 < region.1 {
            let rect = horizontal
                ? NSRect(x: region.0, y: 0, width: region.1 - region.0, height: depth)
                : NSRect(x: 0, y: region.0, width: depth, height: region.1 - region.0)
            context.saveGState()
            context.clip(to: rect.intersection(bounds))
            let path = NSBezierPath()
            var s = region.0 - depth
            while s < region.1 + depth {
                path.move(to: point(s, 0))
                path.line(to: point(s + depth, depth))
                s += 6
            }
            path.lineWidth = 1
            path.stroke()
            context.restoreGState()
        }
        context.restoreGState()
        for edge in [low, high] where edge > 0 && edge < length {
            NSColor.white.withAlphaComponent(0.55).setStroke()
            let path = NSBezierPath()
            path.move(to: point(edge, 3))
            path.line(to: point(edge, depth - 3))
            path.lineWidth = 1
            path.stroke()
        }

        // What the picture covers.
        if let band = tape.band {
            let a = tape.offset(of: band.lowerBound), b = tape.offset(of: band.upperBound)
            let start = max(min(a, b), -4), end = min(max(a, b), length + 4)
            if end > start {
                let rect = horizontal
                    ? NSRect(x: start, y: 1, width: end - start, height: 2.5)
                    : NSRect(x: mirrored ? depth - 3.5 : 1, y: start, width: 2.5, height: end - start)
                NSColor.white.withAlphaComponent(0.42).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 1.25, yRadius: 1.25).fill()
            }
        }

        // Ticks and labels.
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
        let labelColor = NSColor.white.withAlphaComponent(0.62)
        let readout = tape.readoutRect.insetBy(dx: -3, dy: -2)
        for tick in scale.ticks(tape.visible) where scale.range.contains(tick.value) || abs(tick.value - scale.range.upperBound) < 1e-9 {
            let at = tape.offset(of: tick.value)
            guard at > -10, at < length + 10 else { continue }
            let path = NSBezierPath()
            path.move(to: point(at, 5))
            path.line(to: point(at, tick.major ? 12 : 8.5))
            path.lineWidth = tick.major ? 1.2 : 1
            NSColor.white.withAlphaComponent(tick.major ? 0.85 : 0.4).setStroke()
            path.stroke()
            guard tick.major else { continue }
            let text = NSAttributedString(string: scale.label(tick.value), attributes: [.font: font, .foregroundColor: labelColor])
            let size = text.size()
            let origin: CGPoint
            switch tape.orientation {
            case .horizontal: origin = CGPoint(x: at - size.width / 2, y: 15)
            case .verticalRight: origin = CGPoint(x: 15, y: at - size.height / 2)
            case .verticalLeft: origin = CGPoint(x: depth - 15 - size.width, y: at - size.height / 2)
            }
            let rect = NSRect(origin: origin, size: size)
            if !rect.intersects(readout) { text.draw(at: origin) }
        }

        // Where the camera is, while it gets to the value under the mark.
        if let actual = tape.actual {
            let at = tape.offset(of: actual)
            if abs(at - length / 2) > 1.5, at > 0, at < length {
                let path = NSBezierPath()
                path.move(to: point(at, 6))
                path.line(to: point(at - 4, 0))
                path.line(to: point(at + 4, 0))
                path.close()
                NSColor.white.setFill()
                path.fill()
            }
        }

        // The mark: a caret and the readout.
        let accent = tape.active ? NSColor.systemYellow : NSColor.white
        if horizontal {
            let caret = NSBezierPath()
            caret.move(to: point(length / 2, 8))
            caret.line(to: point(length / 2 - 4, 13.5))
            caret.line(to: point(length / 2 + 4, 13.5))
            caret.close()
            accent.setFill()
            caret.fill()
        }
        let pill = tape.readoutRect
        accent.withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        let text = tape.readoutText
        let size = text.size()
        text.draw(at: CGPoint(x: pill.midX - size.width / 2, y: pill.midY - size.height / 2))
    }
}
