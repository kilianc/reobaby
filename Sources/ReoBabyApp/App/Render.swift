import AppKit
import ReoBabyKit
import SwiftUI

enum Render {
    /// `ReoBaby --render <soothing | popover> <out.png> [dark]`: draws a view offscreen, to check
    /// how it looks without showing a window. The popover is always dark, as the player shows it;
    /// offscreen it has no blur.
    @MainActor static func run(_ what: String, to path: String, dark: Bool) -> Int32 {
        _ = NSApplication.shared
        let appearance = NSAppearance(named: dark || what == "popover" ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        // A popover draws its own background; offscreen it needs one, or dark text shows on nothing.
        let content: AnyView = what == "popover"
            ? AnyView(SoothingPopover(soother: .shared) {}.fixedSize().background(Color(nsColor: .windowBackgroundColor)))
            : AnyView(SoothingPane(soother: .shared).frame(width: paneWidth).fixedSize(horizontal: false, vertical: true))
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        window.setContentSize(size)
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 1 }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return 1 }
        try? png.write(to: URL(fileURLWithPath: path))
        print("\(what): \(Int(size.width))×\(Int(size.height)) → \(path)")
        return 0
    }
}
