// Renders the app icon.
// Usage: swift tools/make-icon.swift <variant: lens (current)|lens-night|dome|movie|moon> <out.iconset> [preview.png]
//        swift tools/make-icon.swift compare <out.png>
import AppKit

let S: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func circle(_ c: CGPoint, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
}

func glow(_ c: CGPoint, _ r: CGFloat, _ hex: UInt32, _ alpha: CGFloat) {
    NSGradient(starting: color(hex, alpha), ending: color(hex, 0))!
        .draw(fromCenter: c, radius: 0, toCenter: c, radius: r, options: [])
}

func withShadow(_ hex: UInt32, alpha: CGFloat, blur: CGFloat, dy: CGFloat, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow()
    s.shadowColor = color(hex, alpha)
    s.shadowBlurRadius = blur
    s.shadowOffset = NSSize(width: 0, height: dy)
    s.set()
    body()
    NSGraphicsContext.restoreGraphicsState()
}

/// Background squircle; returns its path (already clipped to inside `content`).
func tile(_ colors: [NSColor], content: () -> Void) {
    let path = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 186, yRadius: 186)
    NSGradient(colors: colors)!.draw(in: path, angle: -90)
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    glow(CGPoint(x: 330, y: 780), 380, 0xFFFFFF, 0.28)
    content()
    NSGraphicsContext.restoreGraphicsState()
}

// MARK: - Dome: a little ceiling dome camera.

func drawDome() {
    tile([color(0xC8F2E2), color(0xA9D6FF), color(0x9DB7FF)]) {
        let c = CGPoint(x: 512, y: 600)
        // Ceiling plate.
        withShadow(0x3D5A99, alpha: 0.25, blur: 30, dy: -14) {
            color(0xFBFCFF).setFill()
            NSBezierPath(roundedRect: NSRect(x: c.x - 270, y: c.y, width: 540, height: 92), xRadius: 46, yRadius: 46).fill()
        }
        // Dome shell.
        let shell = NSBezierPath()
        shell.appendArc(withCenter: c, radius: 250, startAngle: 180, endAngle: 360)
        shell.close()
        withShadow(0x3D5A99, alpha: 0.3, blur: 40, dy: -22) {
            color(0xFFFFFF).setFill()
            shell.fill()
        }
        NSGradient(starting: color(0xFFFFFF), ending: color(0xDDE5F3))!.draw(in: shell, angle: -90)
        // Smoked glass.
        let glass = NSBezierPath()
        glass.appendArc(withCenter: CGPoint(x: c.x, y: c.y - 18), radius: 192, startAngle: 180, endAngle: 360)
        glass.close()
        NSGradient(starting: color(0x46577F), ending: color(0x161E36))!.draw(in: glass, angle: -90)
        // Reflections.
        let streak = NSBezierPath()
        streak.appendArc(withCenter: CGPoint(x: c.x, y: c.y - 18), radius: 150, startAngle: 196, endAngle: 236)
        streak.lineWidth = 26
        streak.lineCapStyle = .round
        color(0xFFFFFF, 0.55).setStroke()
        streak.stroke()
        color(0xFFFFFF, 0.5).setFill()
        circle(CGPoint(x: c.x + 92, y: c.y - 120), 14).fill()
        // Seam between plate and dome.
        color(0xD7DFEC).setFill()
        NSBezierPath(rect: NSRect(x: c.x - 250, y: c.y - 4, width: 500, height: 12)).fill()
        // Status light.
        glow(CGPoint(x: c.x + 190, y: c.y + 46), 34, 0x2FD18B, 0.55)
        color(0x2FD18B).setFill()
        circle(CGPoint(x: c.x + 190, y: c.y + 46), 13).fill()
    }
}

// MARK: - Movie: a chubby old-school movie camera.

func drawMovie() {
    tile([color(0xFFDDB8), color(0xFFB3A7), color(0xF59AB6)]) {
        let body = NSRect(x: 262, y: 300, width: 400, height: 280)
        func reel(_ c: CGPoint, _ r: CGFloat) {
            withShadow(0x9C3D5A, alpha: 0.25, blur: 24, dy: -10) {
                color(0xFFFFFF).setFill()
                circle(c, r).fill()
            }
            color(0xFFC9C2).setFill()
            for i in 0..<3 {
                let a = (CGFloat(i) * 120 + 90) * .pi / 180
                circle(CGPoint(x: c.x + cos(a) * r * 0.5, y: c.y + sin(a) * r * 0.5), r * 0.2).fill()
            }
            color(0xF0A0A8).setFill()
            circle(c, r * 0.13).fill()
        }
        reel(CGPoint(x: 362, y: 676), 104)
        reel(CGPoint(x: 566, y: 662), 88)

        // Lens hood, flaring to the right.
        let hood = NSBezierPath()
        hood.move(to: CGPoint(x: 640, y: 500))
        hood.line(to: CGPoint(x: 800, y: 566))
        hood.line(to: CGPoint(x: 800, y: 314))
        hood.line(to: CGPoint(x: 640, y: 380))
        hood.close()
        hood.lineJoinStyle = .round
        hood.lineWidth = 44
        color(0x3E4870).setStroke()
        color(0x3E4870).setFill()
        hood.stroke()
        hood.fill()
        color(0x8FB8FF, 0.9).setFill()
        NSBezierPath(roundedRect: NSRect(x: 806, y: 330, width: 18, height: 220), xRadius: 9, yRadius: 9).fill()

        let shell = NSBezierPath(roundedRect: body, xRadius: 76, yRadius: 76)
        withShadow(0x9C3D5A, alpha: 0.3, blur: 40, dy: -20) {
            color(0xFFFFFF).setFill()
            shell.fill()
        }
        NSGradient(starting: color(0xFFFFFF), ending: color(0xF3E6EC))!.draw(in: shell, angle: -90)
        // REC light.
        glow(CGPoint(x: 340, y: 512), 40, 0xFF4D63, 0.45)
        color(0xFF4D63).setFill()
        circle(CGPoint(x: 340, y: 512), 19).fill()
    }
}

// MARK: - Moon: a sleepy crescent keeping watch, with a recording light.

func drawMoon() {
    tile([color(0x4A4FA8), color(0x7A6BE0), color(0xB59CF5)]) {
        // Stars.
        color(0xFFF4C9, 0.9).setFill()
        for (x, y, r) in [(300.0, 760.0, 9.0), (720.0, 800.0, 12.0), (780.0, 640.0, 7.0), (250.0, 520.0, 6.0), (690.0, 300.0, 8.0)] {
            circle(CGPoint(x: x, y: y), r).fill()
        }
        let c = CGPoint(x: 470, y: 510)
        let moon = circle(c, 270)
        NSGraphicsContext.saveGraphicsState()
        moon.addClip()
        let bite = NSBezierPath(rect: NSRect(x: 0, y: 0, width: S, height: S))
        bite.append(circle(CGPoint(x: c.x + 150, y: c.y + 92), 236))
        bite.windingRule = .evenOdd
        withShadow(0x2A2466, alpha: 0.35, blur: 40, dy: -18) {
            color(0xFFE8A6).setFill()
            bite.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        // REC light nestled in the crescent.
        let rec = CGPoint(x: 655, y: 450)
        glow(rec, 70, 0xFF4D63, 0.5)
        color(0xFF4D63).setFill()
        circle(rec, 30).fill()
        color(0xFFFFFF, 0.8).setFill()
        circle(CGPoint(x: rec.x - 9, y: rec.y + 9), 8).fill()
    }
}


// MARK: - Lens: the night sky and a crescent moon seen through a camera lens.

func drawLens(background: [NSColor]) {
    tile(background) {
        let c = CGPoint(x: 512, y: 512)
        // Barrel.
        withShadow(0x1B1640, alpha: 0.45, blur: 50, dy: -26) {
            color(0x2A2D3F).setFill()
            circle(c, 330).fill()
        }
        NSGradient(starting: color(0x4A4F69), ending: color(0x1A1C2B))!.draw(in: circle(c, 330), angle: -90)
        // Grip ridges.
        color(0xFFFFFF, 0.10).setStroke()
        for i in 0..<72 {
            let a = CGFloat(i) * 5 * .pi / 180
            let p = NSBezierPath()
            p.move(to: CGPoint(x: c.x + cos(a) * 304, y: c.y + sin(a) * 304))
            p.line(to: CGPoint(x: c.x + cos(a) * 324, y: c.y + sin(a) * 324))
            p.lineWidth = 6
            p.lineCapStyle = .round
            p.stroke()
        }
        // Inner bevel.
        NSGradient(starting: color(0x1E2133), ending: color(0x5C6380))!.draw(in: circle(c, 290), angle: -90)
        NSGradient(starting: color(0x5C6380), ending: color(0x151726))!.draw(in: circle(c, 272), angle: -90)

        // Glass: night sky.
        let glass = circle(c, 252)
        NSGraphicsContext.saveGraphicsState()
        glass.addClip()
        NSGradient(colors: [color(0x2E3184), color(0x5B4FC4), color(0x9C84EE)])!.draw(in: glass, angle: -90)
        color(0xFFF4C9, 0.9).setFill()
        for (x, y, r) in [(390.0, 650.0, 6.0), (640.0, 690.0, 8.0), (690.0, 560.0, 5.0), (360.0, 420.0, 4.5), (610.0, 360.0, 5.5), (470.0, 700.0, 3.5)] {
            circle(CGPoint(x: x, y: y), r).fill()
        }
        // Crescent.
        // The moon's full disc is centred on the icon.
        let mc = c
        NSGraphicsContext.saveGraphicsState()
        circle(mc, 150).addClip()
        let bite = NSBezierPath(rect: NSRect(x: 0, y: 0, width: S, height: S))
        bite.append(circle(CGPoint(x: mc.x + 82, y: mc.y + 52), 132))
        bite.windingRule = .evenOdd
        withShadow(0xFFE8A6, alpha: 0.6, blur: 40, dy: 0) {
            color(0xFFE8A6).setFill()
            bite.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        // Coating tint at the rim and a soft vignette.
        let rim = circle(c, 246)
        rim.lineWidth = 14
        color(0x7CF5D0, 0.16).setStroke()
        rim.stroke()
        NSGradient(starting: color(0x000000, 0), ending: color(0x0A0820, 0.35))!
            .draw(fromCenter: c, radius: 170, toCenter: c, radius: 256, options: [])
        NSGraphicsContext.restoreGraphicsState()

        // Glass reflections.
        let arc = NSBezierPath()
        arc.appendArc(withCenter: c, radius: 205, startAngle: 112, endAngle: 158)
        arc.lineWidth = 26
        arc.lineCapStyle = .round
        color(0xFFFFFF, 0.38).setStroke()
        arc.stroke()
        color(0xFFFFFF, 0.45).setFill()
        circle(CGPoint(x: c.x - 118, y: c.y + 178), 11).fill()
        let low = NSBezierPath()
        low.appendArc(withCenter: c, radius: 215, startAngle: 292, endAngle: 318)
        low.lineWidth = 12
        low.lineCapStyle = .round
        color(0xFFFFFF, 0.18).setStroke()
        low.stroke()
    }
}

func drawLensLight() { drawLens(background: [color(0xE4DCFF), color(0xC9C0FA), color(0xA9A2F0)]) }
func drawLensNight() { drawLens(background: [color(0x3B3E8F), color(0x5E52C2), color(0x8E78E6)]) }

let variants: [String: () -> Void] = ["dome": drawDome, "movie": drawMovie, "moon": drawMoon,
                                      "lens": drawLensLight, "lens-night": drawLensNight]

func render(_ px: Int, _ draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.cgContext.scaleBy(x: CGFloat(px) / S, y: CGFloat(px) / S)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let args = CommandLine.arguments
if args.count > 2 && args[1] == "compare" {
    // Three variants side by side, plus each at menu-bar-ish and Dock sizes.
    let names = args.count > 3 ? Array(args[3...]) : ["dome", "movie", "moon"]
    let cell = 420, w = cell * 3, h = cell + 60
    let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
    NSColor(white: 0.97, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill()
    for (i, name) in names.enumerated() {
        let big = NSImage(size: NSSize(width: 360, height: 360))
        big.addRepresentation(render(720, variants[name]!))
        big.draw(in: NSRect(x: i * cell + 30, y: 70, width: 360, height: 360))
        let small = NSImage(size: NSSize(width: 64, height: 64))
        small.addRepresentation(render(128, variants[name]!))
        small.draw(in: NSRect(x: i * cell + 30 + 280, y: 10, width: 64, height: 64))
        let label = name as NSString
        label.draw(at: NSPoint(x: i * cell + 40, y: 28),
                   withAttributes: [.font: NSFont.systemFont(ofSize: 26, weight: .semibold), .foregroundColor: NSColor.darkGray])
    }
    NSGraphicsContext.restoreGraphicsState()
    try! sheet.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
    exit(0)
}

guard args.count > 2, let draw = variants[args[1]] else {
    print("usage: make-icon.swift <dome|movie|moon> <out.iconset> [preview.png] | compare <out.png>")
    exit(1)
}
let out = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (px, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"),
                   (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
    try! render(px, draw).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("icon_\(name).png"))
}
if args.count > 3 {
    try! render(512, draw).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
}
