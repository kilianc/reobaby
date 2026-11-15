import AppKit
import ReoBabyKit

// Camera tools from the command line are `reobaby`, the CLI in Contents/Helpers.
let arguments = CommandLine.arguments

if let i = arguments.firstIndex(of: "--render"), i + 2 < arguments.count {
    exit(MainActor.assumeIsolated { Render.run(arguments[i + 1], to: arguments[i + 2], dark: arguments.contains("dark")) })
}

if let i = arguments.firstIndex(of: "--install-update") {
    exit(Updater.finishInstall(arguments: Array(arguments[(i + 1)...])))
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
