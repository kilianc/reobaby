import AppKit

let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--probe") {
    let target = i + 1 < arguments.count ? arguments[i + 1] : ""
    let seconds = i + 2 < arguments.count ? Double(arguments[i + 2]) ?? 8 : 8
    exit(Probe.run(target: target, seconds: seconds))
}

if let i = arguments.firstIndex(of: "--monitor") {
    let target = i + 1 < arguments.count ? arguments[i + 1] : ""
    let seconds = i + 2 < arguments.count ? Double(arguments[i + 2]) ?? 20 : 20
    exit(Probe.monitor(target: target, seconds: seconds))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
