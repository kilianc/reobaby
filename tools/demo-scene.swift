// Renders the stand-in nursery the demo camera streams (`make test-server`, path `nursery`),
// used for screenshots so no real camera footage ends up in the repo.
// Usage: swift tools/demo-scene.swift <out.png> [--zoom 1.45] [--clean]
//   --clean leaves out the on-screen clock, camera name and z's (the website animates its own).
import AppKit

let argv = Array(CommandLine.arguments.dropFirst())
let clean = argv.contains("--clean")
let zoomArg = argv.firstIndex(of: "--zoom").map { CGFloat(Double(argv[$0 + 1])!) } ?? 1.45

let W: CGFloat = 1920, H: CGFloat = 1080

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
}
func rrect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
}
func fill(_ path: NSBezierPath, _ hex: UInt32, _ alpha: CGFloat = 1) {
    color(hex, alpha).setFill(); path.fill()
}
func glow(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ hex: UInt32, _ alpha: CGFloat) {
    NSGradient(starting: color(hex, alpha), ending: color(hex, 0))!
        .draw(fromCenter: CGPoint(x: x, y: y), radius: 0, toCenter: CGPoint(x: x, y: y), radius: r, options: [])
}
func star(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, points: Int = 5, inner: CGFloat = 0.45) -> NSBezierPath {
    let p = NSBezierPath()
    for i in 0..<(points * 2) {
        let a = CGFloat(i) * .pi / CGFloat(points) + .pi / 2
        let rr = i % 2 == 0 ? r : r * inner
        let pt = CGPoint(x: x + cos(a) * rr, y: y + sin(a) * rr)
        i == 0 ? p.move(to: pt) : p.line(to: pt)
    }
    p.close()
    return p
}
func crescent(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ hex: UInt32) {
    NSGraphicsContext.saveGraphicsState()
    circle(x, y, r).addClip()
    let bite = NSBezierPath(rect: NSRect(x: 0, y: 0, width: W, height: H))
    bite.append(circle(x + r * 0.55, y + r * 0.35, r * 0.88))
    bite.windingRule = .evenOdd
    fill(bite, hex)
    NSGraphicsContext.restoreGraphicsState()
}
func line(_ a: CGPoint, _ b: CGPoint, _ hex: UInt32, _ alpha: CGFloat, _ width: CGFloat) {
    let p = NSBezierPath(); p.move(to: a); p.line(to: b)
    p.lineWidth = width; p.lineCapStyle = .round
    color(hex, alpha).setStroke(); p.stroke()
}

/// Deterministic pseudo-random numbers, so every render is identical.
var seed: UInt32 = 7
func rand() -> CGFloat { seed = seed &* 1_103_515_245 &+ 12345; return CGFloat((seed >> 8) & 0xFFFF) / 65535 }

func drawScene() {
    // Frame the crib the way a zoom camera would.
    NSGraphicsContext.saveGraphicsState()
    let zoom = zoomArg, focus = CGPoint(x: 770, y: 530)
    let t = NSAffineTransform()
    t.translateX(by: W / 2, yBy: H / 2); t.scale(by: zoom); t.translateX(by: -focus.x, yBy: -focus.y)
    t.concat()
    // Wall and wallpaper stars.
    NSGradient(colors: [color(0x4A4598), color(0x2C2B6A), color(0x22225A)])!
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 90)
    for _ in 0..<70 {
        let x = rand() * W, y = 300 + rand() * (H - 300)
        fill(star(x, y, 7 + rand() * 6, points: 4, inner: 0.35), 0xFFFFFF, 0.05 + rand() * 0.05)
    }

    // Bunting across the wall.
    let flags: [UInt32] = [0xF6B5CF, 0xFFE3A3, 0xA9D8F2, 0xC8B6F6, 0xB7E4C7]
    let rope = NSBezierPath()
    rope.move(to: CGPoint(x: 60, y: 990))
    rope.curve(to: CGPoint(x: 1180, y: 990), controlPoint1: CGPoint(x: 400, y: 900), controlPoint2: CGPoint(x: 840, y: 900))
    rope.lineWidth = 3; color(0xFFFFFF, 0.35).setStroke(); rope.stroke()
    for i in 0..<11 {
        let t = (CGFloat(i) + 0.5) / 11
        let u = 1 - t
        let px = u*u*u*60 + 3*u*u*t*400 + 3*u*t*t*840 + t*t*t*1180
        let py = u*u*u*990 + 3*u*u*t*900 + 3*u*t*t*900 + t*t*t*990
        let f = NSBezierPath()
        f.move(to: CGPoint(x: px - 34, y: py + 2)); f.line(to: CGPoint(x: px + 34, y: py + 2)); f.line(to: CGPoint(x: px, y: py - 62)); f.close()
        fill(f, flags[i % flags.count], 0.78)
    }

    // Rainbow picture.
    fill(rrect(150, 560, 250, 250, 18), 0xF4EEFF, 0.92)
    fill(rrect(168, 578, 214, 214, 10), 0x5E57B0)
    NSGraphicsContext.saveGraphicsState()
    rrect(168, 578, 214, 214, 10).addClip()
    for (i, hex) in [0xF6B5CF, 0xFFD59E, 0xFFF1A8, 0xB7E4C7, 0xA9D8F2].enumerated() {
        let r = 92 - CGFloat(i) * 14
        let arc = NSBezierPath()
        arc.appendArc(withCenter: CGPoint(x: 275, y: 620), radius: r, startAngle: 0, endAngle: 180)
        arc.lineWidth = 13; color(UInt32(hex), 0.9).setStroke(); arc.stroke()
    }
    fill(circle(205, 625, 26), 0xFFFFFF, 0.95); fill(circle(232, 618, 20), 0xFFFFFF, 0.95)
    fill(circle(345, 625, 26), 0xFFFFFF, 0.95); fill(circle(318, 618, 20), 0xFFFFFF, 0.95)
    NSGraphicsContext.restoreGraphicsState()

    // Window with the moon, curtains and a rod.
    let win = NSRect(x: 1290, y: 500, width: 420, height: 420)
    fill(rrect(win.minX - 18, win.minY - 18, win.width + 36, win.height + 36, 34), 0xEDE7FF, 0.9)
    let glass = rrect(win.minX, win.minY, win.width, win.height, 22)
    NSGradient(colors: [color(0x3F3A92), color(0x1C1C4E)])!.draw(in: glass, angle: 90)
    NSGraphicsContext.saveGraphicsState()
    glass.addClip()
    glow(1560, 800, 220, 0xFFE8A6, 0.25)
    crescent(1560, 800, 70, 0xFFE8A6)
    for (x, y, r) in [(1360.0, 860.0, 9.0), (1430.0, 760.0, 6.0), (1660.0, 640.0, 8.0), (1380.0, 600.0, 5.0), (1500.0, 560.0, 7.0), (1640.0, 880.0, 5.0)] {
        fill(star(x, y, r), 0xFFF4C9, 0.9)
    }
    NSGraphicsContext.restoreGraphicsState()
    fill(NSBezierPath(rect: NSRect(x: win.midX - 6, y: win.minY, width: 12, height: win.height)), 0xEDE7FF, 0.9)
    fill(NSBezierPath(rect: NSRect(x: win.minX, y: win.midY - 6, width: win.width, height: 12)), 0xEDE7FF, 0.9)
    fill(rrect(1200, 958, 600, 14, 7), 0xD8CCF7)
    for side in [-1.0, 1.0] as [CGFloat] {
        let edge: CGFloat = side < 0 ? 1220 : 1780
        let inner: CGFloat = side < 0 ? 1330 : 1670
        let c = NSBezierPath()
        c.move(to: CGPoint(x: edge, y: 965))
        c.line(to: CGPoint(x: inner, y: 965))
        c.curve(to: CGPoint(x: edge + side * -40, y: 640), controlPoint1: CGPoint(x: inner, y: 820), controlPoint2: CGPoint(x: edge + side * -90, y: 700))
        c.curve(to: CGPoint(x: edge + side * -20, y: 420), controlPoint1: CGPoint(x: edge + side * -10, y: 580), controlPoint2: CGPoint(x: edge + side * -50, y: 480))
        c.line(to: CGPoint(x: edge, y: 420))
        c.close()
        NSGradient(colors: [color(0xF7BFD6), color(0xE59BBD)])!.draw(in: c, angle: side < 0 ? 0 : 180)
        fill(rrect(edge + side * -52 - 16, 630, 32, 14, 7), 0xFFE3A3)
    }

    // Floor, baseboard, moonlight and rug.
    NSGradient(colors: [color(0x1D1A44), color(0x2E2A63)])!.draw(in: NSRect(x: 0, y: 0, width: W, height: 270), angle: 90)
    fill(NSBezierPath(rect: NSRect(x: 0, y: 262, width: W, height: 16)), 0x413D88)
    let beam = NSBezierPath()
    beam.move(to: CGPoint(x: 1290, y: 500)); beam.line(to: CGPoint(x: 1710, y: 500))
    beam.line(to: CGPoint(x: 1500, y: 0)); beam.line(to: CGPoint(x: 900, y: 0)); beam.close()
    fill(beam, 0xC9C0FF, 0.06)
    fill(NSBezierPath(ovalIn: NSRect(x: 260, y: 40, width: 1100, height: 190)), 0x6B5DC2, 0.55)
    let ring = NSBezierPath(ovalIn: NSRect(x: 320, y: 64, width: 980, height: 142))
    ring.lineWidth = 6; color(0xB9A9F2, 0.35).setStroke(); ring.stroke()

    // Dresser with a moon lamp, a plant and a plush star.
    glow(1380, 520, 330, 0xFFD69A, 0.32)
    fill(rrect(1240, 196, 480, 250, 16), 0xE6DFFB)
    for row in 0..<2 {
        let y = 222 + CGFloat(row) * 108
        fill(rrect(1266, y, 428, 92, 10), 0xD3C9F3)
        fill(circle(1480, y + 46, 11), 0xB6A6E8)
    }
    fill(rrect(1258, 170, 28, 30, 6), 0xC9BEEE); fill(rrect(1674, 170, 28, 30, 6), 0xC9BEEE)
    fill(rrect(1356, 446, 48, 26, 8), 0xF0E2CF)
    fill(circle(1380, 530, 62), 0xFFE6B0)
    crescent(1380, 530, 62, 0xFFF6DA)
    fill(rrect(1606, 446, 70, 64, 14), 0xF2A27E)
    for (dx, h, lean) in [(-22.0, 120.0, -30.0), (0.0, 150.0, 0.0), (22.0, 115.0, 30.0)] as [(CGFloat, CGFloat, CGFloat)] {
        let leaf = NSBezierPath()
        leaf.move(to: CGPoint(x: 1641 + dx * 0.3, y: 505))
        leaf.curve(to: CGPoint(x: 1641 + dx + lean, y: 505 + h), controlPoint1: CGPoint(x: 1641 + dx - 40, y: 540), controlPoint2: CGPoint(x: 1641 + dx + lean - 30, y: 505 + h - 40))
        leaf.curve(to: CGPoint(x: 1641 + dx * 0.3, y: 505), controlPoint1: CGPoint(x: 1641 + dx + lean + 30, y: 505 + h - 40), controlPoint2: CGPoint(x: 1641 + dx + 40, y: 540))
        fill(leaf, 0x7FC8A0)
    }
    fill(star(1500, 488, 46, inner: 0.55), 0xFFD86E)
    fill(circle(1485, 492, 5), 0x3A2A4A); fill(circle(1515, 492, 5), 0x3A2A4A)

    // Crib: a sleeping baby in a knit hat, a small teddy, and a blanket, behind the bars.
    let cribL: CGFloat = 420, cribR: CGFloat = 1100
    fill(rrect(cribL + 30, 320, cribR - cribL - 60, 70, 12), 0xEDE8FF)
    fill(rrect(470, 390, 230, 80, 34), 0xF8F4FF)
    let skin: UInt32 = 0xF3CDB0
    let b = (x: CGFloat(590), y: CGFloat(500))
    fill(circle(b.x - 62, b.y - 6, 13), skin); fill(circle(b.x + 62, b.y - 6, 13), skin)
    fill(circle(b.x, b.y, 64), skin)
    NSGraphicsContext.saveGraphicsState()
    circle(b.x, b.y, 64).addClip()
    fill(NSBezierPath(rect: NSRect(x: b.x - 70, y: b.y + 20, width: 140, height: 60)), 0xC8B6F6)
    NSGraphicsContext.restoreGraphicsState()
    fill(rrect(b.x - 66, b.y + 10, 132, 22, 11), 0xB3A0EE)
    fill(circle(b.x, b.y + 74, 16), 0xF6B5CF)
    for dx in [-22.0, 22.0] as [CGFloat] {
        let eye = NSBezierPath()
        eye.appendArc(withCenter: CGPoint(x: b.x + dx, y: b.y - 2), radius: 10, startAngle: 200, endAngle: 340)
        eye.lineWidth = 4.5; eye.lineCapStyle = .round; color(0x5A3E48).setStroke(); eye.stroke()
        fill(circle(b.x + dx * 1.6, b.y - 22, 11), 0xF29BB0, 0.5)
    }
    fill(NSBezierPath(ovalIn: NSRect(x: b.x - 4, y: b.y - 22, width: 8, height: 6)), 0xE0A88C)
    fill(NSBezierPath(ovalIn: NSRect(x: b.x - 5, y: b.y - 42, width: 10, height: 8)), 0xC77A84)
    let teddy = (x: CGFloat(964), y: CGFloat(462))
    fill(circle(teddy.x - 26, teddy.y + 26, 14), 0xC69A76); fill(circle(teddy.x + 26, teddy.y + 26, 14), 0xC69A76)
    fill(circle(teddy.x, teddy.y, 36), 0xC69A76)
    fill(NSBezierPath(ovalIn: NSRect(x: teddy.x - 16, y: teddy.y - 20, width: 32, height: 24)), 0xEBCDAE)
    fill(circle(teddy.x, teddy.y - 5, 5), 0x4A3238)
    fill(circle(teddy.x - 13, teddy.y + 10, 4.5), 0x4A3238); fill(circle(teddy.x + 13, teddy.y + 10, 4.5), 0x4A3238)
    let blanket = NSBezierPath()
    blanket.move(to: CGPoint(x: 470, y: 330))
    blanket.line(to: CGPoint(x: 470, y: 420))
    blanket.curve(to: CGPoint(x: 760, y: 470), controlPoint1: CGPoint(x: 560, y: 440), controlPoint2: CGPoint(x: 640, y: 480))
    blanket.curve(to: CGPoint(x: 1050, y: 430), controlPoint1: CGPoint(x: 880, y: 460), controlPoint2: CGPoint(x: 980, y: 450))
    blanket.line(to: CGPoint(x: 1050, y: 330)); blanket.close()
    NSGradient(colors: [color(0x9CC4F2), color(0x7DA9E6)])!.draw(in: blanket, angle: -90)
    NSGraphicsContext.saveGraphicsState()
    blanket.addClip()
    for i in 0..<14 { for j in 0..<3 {
        fill(star(500 + CGFloat(i) * 42 + CGFloat(j % 2) * 21, 350 + CGFloat(j) * 36, 7, points: 5), 0xFFFFFF, 0.5)
    } }
    NSGraphicsContext.restoreGraphicsState()
    // A tiny hand on the blanket, and some z's.
    fill(circle(b.x + 74, b.y - 40, 15), skin)
    for i in 0..<3 { fill(circle(b.x + 64 + CGFloat(i) * 10, b.y - 28, 6), skin) }
    if !clean {
    let rounded = NSFont.systemFont(ofSize: 10, weight: .heavy).fontDescriptor.withDesign(.rounded)!
    for (i, (x, y, size)) in [(680.0, 540.0, 30.0), (712.0, 566.0, 40.0)].enumerated() {
        ("z" as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [
            .font: NSFont(descriptor: rounded, size: size)!,
            .foregroundColor: NSColor(white: 1, alpha: 0.6 + 0.2 * CGFloat(i)),
        ])
    }
    }

    let wood: UInt32 = 0xF3EEFF
    for x in stride(from: CGFloat(495.5), through: 1030, by: 44) {  // a bar on the nose, eyes in the gaps
        fill(rrect(x, 330, 13, 290, 6.5), wood, 0.95)
    }
    fill(rrect(cribL, 600, cribR - cribL, 34, 17), wood)
    fill(rrect(cribL + 20, 300, cribR - cribL - 40, 36, 10), 0xDCD3F7)
    for x in [cribL, cribR - 44] {
        fill(rrect(x, 170, 44, 500, 18), wood)
        fill(circle(x + 22, 680, 26), wood)
    }
    fill(rrect(cribL + 8, 160, 28, 18, 6), 0xC9BEEE); fill(rrect(cribR - 36, 160, 28, 18, 6), 0xC9BEEE)

    // Mobile: arm from the right post, ornaments on strings.
    let arm = NSBezierPath()
    arm.move(to: CGPoint(x: cribR - 22, y: 700))
    arm.curve(to: CGPoint(x: 760, y: 930), controlPoint1: CGPoint(x: cribR - 22, y: 900), controlPoint2: CGPoint(x: 900, y: 930))
    arm.lineWidth = 12; arm.lineCapStyle = .round; color(0xE6DFFB).setStroke(); arm.stroke()
    line(CGPoint(x: 620, y: 880), CGPoint(x: 900, y: 880), 0xE6DFFB, 1, 8)
    line(CGPoint(x: 760, y: 930), CGPoint(x: 760, y: 880), 0xE6DFFB, 1, 6)
    for (x, drop) in [(630.0, 90.0), (713.0, 130.0), (807.0, 105.0), (890.0, 140.0)] as [(CGFloat, CGFloat)] {
        line(CGPoint(x: x, y: 880), CGPoint(x: x, y: 880 - drop), 0xFFFFFF, 0.45, 2)
    }
    crescent(630, 760, 32, 0xFFE8A6)
    fill(star(713, 720, 32), 0xFFD86E)
    fill(circle(795, 745, 22), 0xFFFFFF); fill(circle(822, 752, 26), 0xFFFFFF); fill(circle(848, 743, 19), 0xFFFFFF)
    fill(rrect(788, 724, 72, 28, 14), 0xFFFFFF)
    fill(circle(890, 712, 26), 0xF6B5CF)
    let saturn = NSBezierPath(ovalIn: NSRect(x: 850, y: 702, width: 80, height: 20))
    saturn.lineWidth = 5; color(0xC8B6F6).setStroke(); saturn.stroke()

    NSGraphicsContext.restoreGraphicsState()

    // Camera look: soft vignette and an on-screen display like the real thing.
    NSGradient(starting: color(0x000000, 0), ending: color(0x000000, 0.42))!
        .draw(fromCenter: CGPoint(x: W / 2, y: H / 2), radius: 520, toCenter: CGPoint(x: W / 2, y: H / 2), radius: 1180, options: [])
    guard !clean else { return }
    let osd: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 36, weight: .medium),
        .foregroundColor: NSColor(white: 1, alpha: 0.88),
        .shadow: { let s = NSShadow(); s.shadowColor = .black; s.shadowBlurRadius = 3; s.shadowOffset = NSSize(width: 0, height: -1); return s }(),
    ]
    ("2026-11-07  21:14:03" as NSString).draw(at: CGPoint(x: 44, y: H - 74), withAttributes: osd)
    ("Nursery" as NSString).draw(at: CGPoint(x: W - 200, y: 34), withAttributes: osd)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
drawScene()
NSGraphicsContext.restoreGraphicsState()
let out = argv.enumerated().first { i, a in !a.hasPrefix("--") && (i == 0 || argv[i - 1] != "--zoom") }?.element ?? "nursery.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
