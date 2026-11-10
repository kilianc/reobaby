import AppKit

let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--probe") {
    let target = i + 1 < arguments.count ? arguments[i + 1] : ""
    let seconds = i + 2 < arguments.count ? Double(arguments[i + 2]) ?? 8 : 8
    exit(Probe.run(target: target, seconds: seconds))
}

if let i = arguments.firstIndex(of: "--soothe"), i + 1 < arguments.count {
    // A setting tried as an argument (`-sootheNoise brown`) is not a list of steps.
    let steps = i + 3 < arguments.count && !arguments[i + 3].hasPrefix("-")
        ? arguments[i + 3].split(separator: ",").map(String.init) : []
    exit(Probe.soothe(target: arguments[i + 1], stepSeconds: i + 2 < arguments.count ? Double(arguments[i + 2]) ?? 30 : 30,
                      steps: steps))
}

if arguments.contains("--soothe-check") {
    exit(Probe.sootheCheck())
}

if arguments.contains("--soothe-app-check") {
    exit(MainActor.assumeIsolated { Probe.sootheAppCheck() })
}

if let i = arguments.firstIndex(of: "--render"), i + 2 < arguments.count {
    exit(MainActor.assumeIsolated { Probe.render(arguments[i + 1], to: arguments[i + 2], dark: arguments.contains("dark")) })
}

if let i = arguments.firstIndex(of: "--api-poll"), i + 2 < arguments.count {
    exit(Probe.apiPoll(target: arguments[i + 1], commands: arguments[i + 2],
                   seconds: i + 3 < arguments.count ? Double(arguments[i + 3]) ?? 0 : 0))
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

if let i = arguments.firstIndex(of: "--api"), i + 2 < arguments.count {
    let param = i + 3 < arguments.count ? arguments[i + 3] : "{\"channel\":0}"
    let action = i + 4 < arguments.count ? Int(arguments[i + 4]) ?? 0 : 0
    exit(Probe.api(target: arguments[i + 1], cmd: arguments[i + 2], param: param, action: action))
}

if let i = arguments.firstIndex(of: "--ptz"), i + 1 < arguments.count {
    exit(Probe.ptz(target: arguments[i + 1], arguments: Array(arguments[(i + 2)...])))
}

if let i = arguments.firstIndex(of: "--install-update") {
    exit(Updater.finishInstall(arguments: Array(arguments[(i + 1)...])))
}

if arguments.contains("--discover") {
    exit(Probe.discover())
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
