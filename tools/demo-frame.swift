// Stamps a Reolink-style on-screen clock and camera name onto a photo, producing the frame the
// demo camera streams (`make test-server`, path `nursery`). Used for screenshots, so no real camera
// footage ends up in the repo. The baby in test/demo is AI-generated.
// Usage: swift tools/demo-frame.swift <photo> <out.png> [camera name]
import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let photo = NSImage(contentsOfFile: args[1]) else {
    print("usage: swift tools/demo-frame.swift <photo> <out.png> [camera name]"); exit(1)
}
let name = args.count > 3 ? args[3] : "Nursery"
let W = 1920, H = 1080

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
photo.draw(in: NSRect(x: 0, y: 0, width: W, height: H))
let shadow = NSShadow()
shadow.shadowColor = .black; shadow.shadowBlurRadius = 3; shadow.shadowOffset = NSSize(width: 0, height: -1)
let osd: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 36, weight: .medium),
    .foregroundColor: NSColor(white: 1, alpha: 0.9), .shadow: shadow,
]
let stamp = DateFormatter()
stamp.dateFormat = "yyyy-MM-dd  HH:mm:ss"
(stamp.string(from: Date()) as NSString).draw(at: CGPoint(x: 44, y: H - 74), withAttributes: osd)
let label = name as NSString
label.draw(at: CGPoint(x: CGFloat(W) - 44 - label.size(withAttributes: osd).width, y: 34), withAttributes: osd)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
