// Composes the website hero: a drawn Mac desktop with a real capture of the tiny ReoBaby window
// (playing the demo camera) and a notification.
// Usage: swift tools/hero-shot.swift <window.png> <nursery.png> <icon.png> <out.png>
//   window.png: `screencapture -l<window id>` of a 480×270 player window
import AppKit

let args = CommandLine.arguments
guard args.count == 5, let window = NSImage(contentsOfFile: args[1]), let scene = NSImage(contentsOfFile: args[2]),
      let icon = NSImage(contentsOfFile: args[3]) else {
    print("usage: swift tools/hero-shot.swift <window.png> <nursery.png> <icon.png> <out.png>"); exit(1)
}
let W: CGFloat = 1440, H: CGFloat = 900, scale: CGFloat = 2

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
func rrect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
}
func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
}
func fill(_ path: NSBezierPath, _ hex: UInt32, _ alpha: CGFloat = 1) { color(hex, alpha).setFill(); path.fill() }
func shadowed(_ alpha: CGFloat, blur: CGFloat, dy: CGFloat, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow(); s.shadowColor = NSColor(white: 0, alpha: alpha); s.shadowBlurRadius = blur
    s.shadowOffset = NSSize(width: 0, height: dy); s.set()
    body()
    NSGraphicsContext.restoreGraphicsState()
}
func text(_ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular,
          _ hex: UInt32 = 0x16142E, _ alpha: CGFloat = 0.92, rightAligned: Bool = false) {
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color(hex, alpha)]
    let str = s as NSString
    str.draw(at: CGPoint(x: rightAligned ? x - str.size(withAttributes: attrs).width : x, y: y), withAttributes: attrs)
}
func symbol(_ name: String, center: CGPoint, size: CGFloat, _ hex: UInt32 = 0x16142E) {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium).applying(.init(paletteColors: [color(hex, 0.9)]))
    guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
    img.draw(in: NSRect(x: center.x - img.size.width / 2, y: center.y - img.size.height / 2, width: img.size.width, height: img.size.height))
}
func star(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    for i in 0..<8 {
        let a = CGFloat(i) * .pi / 4 + .pi / 2, rr = i % 2 == 0 ? r : r * 0.35
        let pt = CGPoint(x: x + cos(a) * rr, y: y + sin(a) * rr)
        i == 0 ? p.move(to: pt) : p.line(to: pt)
    }
    p.close(); return p
}

func drawDesktop() {
    // Wallpaper: dusk sky over soft hills, with a small moon.
    NSGradient(colors: [color(0x5B50C8), color(0x9A86E8), color(0xF0B2D0), color(0xFFD3A8)])!
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)
    for (x, y, r) in [(980.0, 760.0, 5.0), (1120.0, 700.0, 3.5), (900.0, 640.0, 3.0), (1250.0, 620.0, 4.0), (60.0, 800.0, 4.0)] {
        fill(star(x, y, r), 0xFFFFFF, 0.7)
    }
    NSGradient(starting: color(0xFFF1C9, 0.35), ending: color(0xFFF1C9, 0))!
        .draw(fromCenter: CGPoint(x: 1010, y: 560), radius: 0, toCenter: CGPoint(x: 1010, y: 560), radius: 120, options: [])
    NSGraphicsContext.saveGraphicsState()
    circle(1010, 560, 40).addClip()
    let bite = NSBezierPath(rect: NSRect(x: 0, y: 0, width: W, height: H))
    bite.append(circle(1032, 574, 35)); bite.windingRule = .evenOdd
    fill(bite, 0xFFF1C9)
    NSGraphicsContext.restoreGraphicsState()
    for (hex, a, b, c1, c2) in [
        (0xB59BEA as UInt32, CGPoint(x: 0, y: 330), CGPoint(x: W, y: 300), CGPoint(x: 380, y: 430), CGPoint(x: 900, y: 210)),
        (0x8C76DA, CGPoint(x: 0, y: 220), CGPoint(x: W, y: 250), CGPoint(x: 500, y: 100), CGPoint(x: 1000, y: 340)),
        (0x6A57C2, CGPoint(x: 0, y: 110), CGPoint(x: W, y: 90), CGPoint(x: 420, y: 200), CGPoint(x: 1000, y: 10)),
    ] {
        let hill = NSBezierPath()
        hill.move(to: a); hill.curve(to: b, controlPoint1: c1, controlPoint2: c2)
        hill.line(to: CGPoint(x: W, y: 0)); hill.line(to: .zero); hill.close()
        fill(hill, hex)
    }

    // Menu bar.
    fill(NSBezierPath(rect: NSRect(x: 0, y: H - 32, width: W, height: 32)), 0xFFFFFF, 0.3)
    text("Finder", 22, H - 24, size: 13.5, weight: .bold)
    var x: CGFloat = 86
    for item in ["File", "Edit", "View", "Go", "Window", "Help"] {
        text(item, x, H - 24, size: 13.5)
        x += (item as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13.5)]).width + 22
    }
    text("Sat Nov 7  9:14 PM", W - 18, H - 24, size: 13.5, weight: .medium, rightAligned: true)
    symbol("switch.2", center: CGPoint(x: W - 170, y: H - 16), size: 13)
    symbol("wifi", center: CGPoint(x: W - 204, y: H - 16), size: 13)
    symbol("battery.75percent", center: CGPoint(x: W - 244, y: H - 16), size: 14)
    // ReoBaby's menu bar icon: a lens ring with a crescent moon (same shapes as StatusBarController).
    let g = CGPoint(x: W - 290, y: H - 25)
    color(0x16142E, 0.9).setStroke(); color(0x16142E, 0.9).setFill()
    let ring = NSBezierPath(ovalIn: NSRect(x: g.x + 1.6, y: g.y + 1.6, width: 14.8, height: 14.8))
    ring.lineWidth = 1.6; ring.stroke()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(ovalIn: NSRect(x: g.x + 4.5, y: g.y + 4.5, width: 9, height: 9)).addClip()
    let crescent = NSBezierPath(rect: NSRect(x: g.x, y: g.y, width: 18, height: 18))
    crescent.append(NSBezierPath(ovalIn: NSRect(x: g.x + 7.2, y: g.y + 6.5, width: 7.8, height: 7.8)))
    crescent.windingRule = .evenOdd; crescent.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Notification, as ReoBaby posts it: camera name, event, and a snapshot.
    let n = NSRect(x: W - 14 - 356, y: H - 32 - 12 - 76, width: 356, height: 76)
    shadowed(0.22, blur: 24, dy: -6) { fill(rrect(n.minX, n.minY, n.width, n.height, 22), 0xFBFAFF, 0.94) }
    icon.draw(in: NSRect(x: n.minX + 12, y: n.minY + 16, width: 44, height: 44))
    text("Nursery", n.minX + 64, n.minY + 42, size: 13, weight: .semibold)
    text("Sound detected", n.minX + 64, n.minY + 22, size: 13, 0x16142E, 0.85)
    text("now", n.maxX - 74, n.minY + 44, size: 11.5, 0x16142E, 0.5, rightAligned: true)
    let thumb = NSRect(x: n.maxX - 14 - 50, y: n.minY + 13, width: 50, height: 50)
    NSGraphicsContext.saveGraphicsState()
    rrect(thumb.minX, thumb.minY, thumb.width, thumb.height, 9).addClip()
    let sw = scene.size.width, sh = scene.size.height
    scene.draw(in: thumb, from: NSRect(x: sw * 0.32, y: sh * 0.40, width: sh * 0.40, height: sh * 0.40), operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    // The tiny player window, floating bottom right. The capture includes its shadow margin.
    // The shadow margin is even left and right, and deeper below than above (about 1.6×).
    let pts = window.size, side = (pts.width - 480) / 2, below = (pts.height - 270) * 0.66
    window.draw(in: NSRect(x: W - 28 - 480 - side, y: 28 - below, width: pts.width, height: pts.height))
}

// The capture is 2x pixels; NSImage reports it in points only if the PNG says 144 dpi, so normalise.
if let rep = window.representations.first {
    window.size = NSSize(width: CGFloat(rep.pixelsWide) / scale, height: CGFloat(rep.pixelsHigh) / scale)
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)
drawDesktop()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[4]))
