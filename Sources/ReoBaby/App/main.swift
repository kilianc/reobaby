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

if let i = arguments.firstIndex(of: "--record"), i + 3 < arguments.count {
    exit(Probe.record(target: arguments[i + 1], seconds: Double(arguments[i + 2]) ?? 60, to: arguments[i + 3]))
}

if let i = arguments.firstIndex(of: "--process"), i + 1 < arguments.count {
    // A setting tried as an argument (`-audioBoost 30`) is not the output file.
    let output = i + 2 < arguments.count && !arguments[i + 2].hasPrefix("-") ? arguments[i + 2] : nil
    exit(Probe.process(arguments[i + 1], to: output))
}

if let i = arguments.firstIndex(of: "--install-update") {
    exit(Updater.finishInstall(arguments: Array(arguments[(i + 1)...])))
}

if arguments.contains("--discover") {
    exit(Probe.discover())
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
