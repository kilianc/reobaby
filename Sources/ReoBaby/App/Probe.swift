import AVFoundation
import CoreMedia
import SwiftUI
import VideoToolbox

/// `ReoBaby --probe <camera name | number | rtsp://url> [seconds]`
/// Connects headlessly, decodes video with VideoToolbox, and reports what it got.
enum Probe {
    static func resolve(_ target: String) -> (Camera, RTSPEndpoint)? {
        if target.lowercased().hasPrefix("rtsp://") {
            let camera = Camera(name: nil, url: target, user: nil, password: nil)
            return RTSPEndpoint(target).map { (camera, $0) }
        }
        let cameras = (try? ConfigStore.decode(ConfigStore.read())) ?? []
        let camera = Int(target).flatMap { cameras.indices.contains($0 - 1) ? cameras[$0 - 1] : nil }
            ?? cameras.first { $0.displayName.localizedCaseInsensitiveContains(target) || $0.url.contains(target) }
            ?? (target.isEmpty ? cameras.first : nil)
        guard let camera, let ep = camera.endpoint() else { return nil }
        return (camera, ep)
    }

    /// `ReoBaby --discover`: the Reolink cameras on the local network, as the Cameras window finds them.
    static func discover() -> Int32 {
        let configured = Set(((try? ConfigStore.decode(ConfigStore.read())) ?? []).compactMap(\.host))
        let hosts = Discovery.candidateHosts()
        print("Looking at \(hosts.count) addresses…")
        let began = Date()
        let done = DispatchSemaphore(value: 0)
        var result = Discovery.Result(hosts: [], blocked: false)
        Task {
            result = await Discovery.find()
            done.signal()
        }
        done.wait()
        if result.blocked { print("macOS is blocking local network access for this app (Privacy & Security ▸ Local Network)") }
        let found = result.hosts
        print(String(format: "Found %d Reolink camera%@ in %.1fs", found.count, found.count == 1 ? "" : "s", Date().timeIntervalSince(began)))
        for host in found {
            print("  \(host)\(configured.contains(host) ? "  (already added)" : "")")
        }
        return found.isEmpty ? 1 : 0
    }

    /// Runs async work to completion from a command-line entry point.
    static func wait(_ work: @escaping () async -> Int32) -> Int32 {
        final class Box { var value: Int32 = 1 }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await work()
            done.signal()
        }
        done.wait()
        return box.value
    }

    /// `ReoBaby --api <camera> <Command> [json param] [action]`: one command of the camera's HTTP API,
    /// answered as the camera answers it. For finding out what a camera model can do.
    static func api(target: String, cmd: String, param: String, action: Int) -> Int32 {
        guard let (_, endpoint) = resolve(target), let password = endpoint.password else {
            print("No camera with a saved password matching “\(target)”")
            return 2
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(param.utf8)) as? [String: Any] else {
            print("The param must be a JSON object")
            return 2
        }
        let api = CameraAPI(host: endpoint.host, user: endpoint.user ?? "admin", password: password)
        return wait {
            do {
                let reply = try await api.raw(cmd, action: action, param: object)
                let data = try JSONSerialization.data(withJSONObject: reply, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                await api.logout()
                return 0
            } catch {
                print("failed: \(error)")
                await api.logout()
                return 1
            }
        }
    }

    /// `ReoBaby --soothe-check`: renders Soothing Sounds offline, silently, through a fade in,
    /// a change of every colour and layer, a louder and a warmer setting, and a fade out. Each
    /// change must glide: the second after it may differ from the second before by no more than
    /// a little, as it would if the change were a 10-second fade.
    static func sootheCheck() -> Int32 {
        let rate = 16000.0
        var settings = SoothingSettings()
        // The defaults, over whatever the user has chosen, without writing over their choices.
        let defaults = MainActor.assumeIsolated { Soother.defaults }
        UserDefaults.standard.setVolatileDomain(defaults, forName: UserDefaults.argumentDomain)
        let synth = SoothingSynth(sampleRate: rate, lowestFrequency: BaichuanTalk.lowestFrequency)
        var block = [Float](repeating: 0, count: Int(rate / 10))
        var levels: [Double] = []
        func play(_ seconds: Double) {
            for _ in 0..<Int(seconds * 10) {
                block.withUnsafeMutableBufferPointer { synth.render($0) }
                let power = block.reduce(0) { $0 + Double($1 * $1) } / Double(block.count)
                levels.append(10 * log10(power + 1e-12))
            }
        }
        func mean(_ range: Range<Int>) -> Double { range.map { levels[$0] }.reduce(0, +) / Double(range.count) }
        synth.fade(to: 1, over: Soother.fadeSeconds)
        play(1)
        let firstSecond = mean(0..<10)
        play(14)
        let full = mean(140..<150)
        var worst = 0.0
        var failed = false
        print(String(format: "fade in: first second %.1f dB below full", full - firstSecond))
        if full - firstSecond < 15 { failed = true }
        let changes: [(String, (inout SoothingSettings) -> Void)] = [
            ("pink → brown", { $0.noise = .brown }), ("brown → white", { $0.noise = .white }), ("white → pink", { $0.noise = .pink }),
            ("warmer", { $0.warmth = 0.95 }), ("cooler", { $0.warmth = 0.2 }), ("louder", { $0.volume = 0.9 }), ("quieter", { $0.volume = 0.4 }),
            ("heartbeat on", { $0.heartbeat = true }), ("heartbeat to 100%", { $0.heartLevel = 1 }),
            ("heartbeat to 20%", { $0.heartLevel = 0.2 }), ("heartbeat off", { $0.heartbeat = false }),
            ("shushing on", { $0.shushing = true }), ("shushing to 100%", { $0.shushLevel = 1 }),
            ("shushing to 20%", { $0.shushLevel = 0.2 }), ("shushing off", { $0.shushing = false }),
            ("waves on", { $0.waves = true }), ("waves to 100%", { $0.wavesLevel = 1 }),
            ("waves to 20%", { $0.wavesLevel = 0.2 }), ("waves off", { $0.waves = false }),
        ]
        for (name, change) in changes {
            let before = mean(levels.count - 10..<levels.count)
            change(&settings)
            synth.update(settings)
            play(14)
            let n = levels.count
            let after = mean(n - 140..<n - 130)
            let settled = mean(n - 10..<n)
            // In the first second, a 10-second change moves at most a tenth of the way.
            let jump = abs(after - before)
            // The sound's own second-to-second sway (waves swell, a heart beats) is allowed too.
            let start = n - 140
            let sway = (start - 50..<start - 10).map { abs(mean($0..<$0 + 10) - mean($0 + 10..<$0 + 20)) }.max() ?? 0
            let allowed = max(1.5, sway + 1, abs(settled - before) * 0.25 + 1)
            worst = max(worst, jump)
            print(String(format: "%-18@ first second %+5.1f dB, settled %+5.1f dB%@", name as NSString, after - before, settled - before,
                         jump > allowed ? "  ← too sudden" : ""))
            if jump > allowed { failed = true }
        }
        let before = mean(levels.count - 10..<levels.count)
        synth.fade(to: 0, over: Soother.fadeSeconds)
        play(1)
        let fadeFirst = mean(levels.count - 10..<levels.count)
        play(10)
        print(String(format: "fade out: first second %+.1f dB, then %@", fadeFirst - before,
                     synth.isSilent ? "silent" : "NOT silent"))
        if !synth.isSilent || abs(fadeFirst - before) > 1.5 { failed = true }
        print(failed ? "FAILED" : "Every change glides.")
        return failed ? 1 : 0
    }

    /// `ReoBaby --soothe-app-check`: Soothing Sounds' app paths, offline and silently, on stand-in
    /// camera speakers that only measure what they're sent: Stop and Play again while it fades,
    /// switching camera, Pause and resuming, the timer's end, and quitting, while playing and
    /// while fading out. Takes about two minutes.
    @MainActor static func sootheAppCheck() -> Int32 {
        /// The defaults, playing on the camera, with the timer set to this many minutes.
        func timer(_ minutes: Double) {
            var settings = Soother.defaults
            settings["sootheOutput"] = Soother.Output.camera.rawValue
            settings["sootheTimer"] = minutes
            UserDefaults.standard.setVolatileDomain(settings, forName: UserDefaults.argumentDomain)
        }
        timer(60)

        let began = Date()
        func now() -> Double { Date().timeIntervalSince(began) }
        func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

        /// A camera's speaker that takes a tenth of a second of sound ten times a second.
        final class Link: SpeakerLink {
            let camera: String
            var onState: ((BaichuanTalk.State) -> Void)?
            var render: ((inout [Float]) -> Void)?
            private(set) var levels: [(t: Double, db: Double)] = []
            private(set) var hungUpAt: Double?
            private var timer: Timer?
            private let clock: () -> Double

            init(camera: String, clock: @escaping () -> Double) {
                self.camera = camera
                self.clock = clock
            }

            func start() {
                DispatchQueue.main.async { self.onState?(.connecting) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.onState?(.playing)
                    self.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in self.take() }
                }
            }

            private func take() {
                var block = [Float](repeating: 0, count: 1600)
                render?(&block)
                let power = block.reduce(0) { $0 + Double($1 * $1) } / Double(block.count)
                levels.append((clock(), 10 * log10(power + 1e-12)))
            }

            func stop() {
                timer?.invalidate()
                timer = nil
                if hungUpAt == nil { hungUpAt = clock() }
            }

            /// As a camera does, plays out about half a second it holds, then hangs up.
            func finish(completion: (() -> Void)?) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.stop()
                    completion?()
                }
            }

            /// Mean level over a second from `t`, in dB.
            func level(_ t: Double) -> Double {
                let part = levels.filter { $0.t >= t && $0.t < t + 1 }.map(\.db)
                return part.isEmpty ? -120 : part.reduce(0, +) / Double(part.count)
            }

            func quietest(from: Double, to: Double) -> Double {
                levels.filter { $0.t >= from && $0.t < to }.map(\.db).min() ?? -120
            }
        }

        let soother = Soother()
        var links: [Link] = []
        soother.makeLink = { endpoint in
            let link = Link(camera: String(endpoint.uri.split(separator: "/").last ?? ""), clock: now)
            links.append(link)
            return link
        }
        let cameraA = RTSPEndpoint("rtsp://127.0.0.1:1/A")!, cameraB = RTSPEndpoint("rtsp://127.0.0.1:1/B")!
        var failed = false
        func check(_ ok: Bool, _ what: String, _ detail: String = "") {
            print("\(ok ? "ok  " : "FAIL") \(what)\(detail.isEmpty ? "" : ": \(detail)")")
            if !ok { failed = true }
        }
        func dB(_ value: Double) -> String { String(format: "%+.1f dB", value) }
        /// A change glides: its first second is within 1.5 dB of the second before it.
        func glides(_ link: Link, from t: Double) -> (Bool, String) {
            let jump = link.level(t) - link.level(t - 1)
            return (abs(jump) <= 1.5, "first second \(dB(jump))")
        }
        func hangUp(_ link: Link, after t: Double, within range: ClosedRange<Double>) -> (Bool, String) {
            guard let at = link.hungUpAt else { return (false, "still connected") }
            return (range.contains(at - t), String(format: "hung up after %.1f s", at - t))
        }

        // Play on camera A.
        soother.setCamera(name: "A", endpoint: cameraA)
        soother.play()
        wait(12)
        let a = links[0]
        check(a.level(11) - a.level(0) >= 15, "Play fades in", "first second \(dB(a.level(0) - a.level(11))) under full")

        // Stop shows Play at once; Play again before the fade ends comes back up on the same connection.
        var t = now()
        soother.stop()
        check(!soother.isOn && soother.isFadingOut, "Stop shows Play at once", soother.statusText)
        wait(4)
        soother.play()
        check(soother.isOn && !soother.isFadingOut && links.count == 1, "Play while fading out comes back", soother.statusText)
        wait(11)
        check(a.quietest(from: t, to: now()) > -60 && a.hungUpAt == nil, "…without going silent or hanging up",
              "quietest " + String(format: "%.0f dB", a.quietest(from: t, to: now())))
        check(abs(a.level(now() - 1) - a.level(t - 1)) <= 1.5, "…back to where it was",
              dB(a.level(now() - 1) - a.level(t - 1)))

        // Switching camera fades out on A and in on B.
        t = now()
        soother.setCamera(name: "B", endpoint: cameraB)
        wait(12)
        let b = links.count > 1 ? links[1] : a
        let (aGlides, aJump) = glides(a, from: t)
        check(aGlides, "Switching camera fades out on the old one", aJump)
        let (aHung, aWhen) = hangUp(a, after: t, within: 10...12)
        check(aHung, "…then hangs it up", aWhen)
        check(links.count == 2 && b.level(now() - 1) - b.level(t) >= 15, "…and fades in on the new one",
              "first second \(dB(b.level(t) - b.level(now() - 1))) under full")

        // Pause fades it out and leaves it off; resuming doesn't start it.
        t = now()
        soother.setCamera(name: nil, endpoint: nil)
        check(!soother.isOn && soother.status == .off, "Pause shows it off at once")
        wait(11.5)
        let (bGlides, bJump) = glides(b, from: t)
        check(bGlides, "…fades it out", bJump)
        let (bHung, bWhen) = hangUp(b, after: t, within: 10...12)
        check(bHung, "…then hangs up", bWhen)
        soother.setCamera(name: "A", endpoint: cameraA)
        wait(1)
        check(links.count == 2 && !soother.isOn, "Resuming leaves the sound off")

        // The timer fades it out and hangs up when it ends: 15 seconds, fading out over the last 7.5.
        timer(0.25)
        soother.play()
        t = now()
        wait(18)
        let c = links.last!
        check(links.count == 3 && !soother.isOn && soother.status == .off, "The timer stops it")
        check(c.level(t + 13.5) - c.level(t + 6) <= -20, "…after fading it out",
              "\(dB(c.level(t + 13.5) - c.level(t + 6))) over its last 7.5 s")
        let (cHung, cWhen) = hangUp(c, after: t, within: 15...18)
        check(cHung, "…and hangs up", cWhen)

        // Switching camera while the timer fades out ends it rather than starting on the next.
        soother.play()
        t = now()
        wait(10)
        let d = links.last!
        soother.setCamera(name: "B", endpoint: cameraB)
        check(links.count == 4 && !soother.isOn, "Switching camera as the timer fades out ends it")
        wait(11.5)
        let (dHung, dWhen) = hangUp(d, after: t + 10, within: 10...12)
        check(dHung, "…and hangs up", dWhen)

        // Quitting while playing fades out first.
        timer(60)
        soother.play()
        wait(12)
        let e = links.last!
        t = now()
        var quitAt: Double?
        soother.fadeOutForQuit { quitAt = now() }
        while quitAt == nil && now() - t < 15 { wait(0.1) }
        let (eGlides, eJump) = glides(e, from: t)
        check(eGlides, "Quitting while playing fades out", eJump)
        check(quitAt.map { (10...12).contains($0 - t) } ?? false, "…then quits",
              quitAt.map { String(format: "after %.1f s", $0 - t) } ?? "never")

        // Quitting while it fades out after Stop finishes that fade.
        soother.play()
        wait(12)
        let f = links.last!
        soother.stop()
        wait(3)
        t = now()
        quitAt = nil
        soother.fadeOutForQuit { quitAt = now() }
        while quitAt == nil && now() - t < 15 { wait(0.1) }
        check(f.level(t) <= f.level(t - 4) && (quitAt.map { $0 - t <= 12 } ?? false), "Quitting while fading out finishes the fade",
              quitAt.map { String(format: "quit after %.1f s", $0 - t) } ?? "never quit")

        UserDefaults.standard.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        print(failed ? "FAILED" : "Every path fades.")
        return failed ? 1 : 0
    }

    /// `ReoBaby --soothe <camera | mac> <seconds per step> [step,step,…]`: Soothing Sounds as
    /// Settings has them (try others as arguments: `-sootheNoise brown -sootheHeartbeat 1`),
    /// faded in, through each step in turn, faded out. A step is a volume (`0.6`) or changes
    /// joined by `+`: `noise=brown`, `volume=0.6`, `warmth=0.8`, `shush=on`, `waves=off`,
    /// `heart=on`; a layer also takes its level, as in `shush=0.7`. On a camera, its microphone
    /// is logged too.
    static func soothe(target: String, stepSeconds: Double, steps given: [String]) -> Int32 {
        var settings = SoothingSettings.current
        let steps = given.isEmpty ? [""] : given
        /// Applies one step's changes; nil if it has one this doesn't know.
        func apply(_ step: String, to settings: inout SoothingSettings) -> Bool {
            for change in step.split(separator: "+").map(String.init) {
                if let volume = Double(change) { settings.volume = volume; continue }
                let parts = change.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return false }
                let (key, value) = (parts[0].lowercased(), parts[1].lowercased())
                let isLayer = ["shush", "waves", "heart"].contains(key)
                // A layer is on, off, or on at a level.
                let level = ["on", "yes", "true"].contains(value) ? nil : Double(value)
                let on = level.map { $0 > 0 } ?? ["on", "yes", "true"].contains(value)
                guard !isLayer || on || level != nil || ["off", "no", "false"].contains(value) else { return false }
                switch key {
                case "noise":
                    guard let noise = SoothingSettings.Noise(rawValue: value) else { return false }
                    settings.noise = noise
                case "volume": guard let v = Double(value) else { return false }; settings.volume = v
                case "warmth": guard let v = Double(value) else { return false }; settings.warmth = v
                case "shush":
                    settings.shushing = on
                    if let level, on { settings.shushLevel = level }
                case "waves":
                    settings.waves = on
                    if let level, on { settings.wavesLevel = level }
                case "heart":
                    settings.heartbeat = on
                    if let level, on { settings.heartLevel = level }
                default: return false
                }
            }
            return true
        }
        var trial = settings
        if let bad = steps.first(where: { !apply($0, to: &trial) }) {
            print("Can't read the step “\(bad)”")
            return 2
        }
        let onMac = target.lowercased() == "mac"
        var mic: MicListener?
        var talk: BaichuanTalk?
        let synth: SoothingSynth
        let mac: MacSpeaker?
        if onMac {
            mac = MacSpeaker()
            synth = mac!.synth
            print("Soothing Sounds on this Mac")
        } else {
            guard let (camera, endpoint) = resolve(target) else {
                print("No camera or rtsp:// URL matching “\(target)”")
                return 2
            }
            mac = nil
            synth = SoothingSynth(sampleRate: 16000, lowestFrequency: BaichuanTalk.lowestFrequency)
            let t = BaichuanTalk(host: endpoint.host, user: endpoint.user ?? "admin", password: endpoint.password ?? "")
            t.render = { buffer in buffer.withUnsafeMutableBufferPointer { synth.render($0) } }
            talk = t
            if ProcessInfo.processInfo.environment["REOBABY_NO_CAM_MIC"] == nil {
                mic = MicListener(endpoint: endpoint, record: nil)
                mic?.start()
            }
            print("Soothing Sounds on \(camera.displayName)'s speaker (\(endpoint.host))")
        }
        // REOBABY_MAC_MIC=<file.wav>: this Mac's microphone, near the camera, measures what its
        // speaker actually plays, gaps and all.
        let macMic = ProcessInfo.processInfo.environment["REOBABY_MAC_MIC"].map { MacMic(path: $0) }
        if let macMic {
            do { try macMic.start() } catch { print("Mac microphone: \(error)") }
            RunLoop.main.run(until: Date().addingTimeInterval(2))
        }
        // REOBABY_WITH_MONITOR=1: sound notifications listen meanwhile, told about the sound as
        // the app tells them.
        var monitor: CameraMonitor?
        if ProcessInfo.processInfo.environment["REOBABY_WITH_MONITOR"] != nil, !onMac,
           let (camera, endpoint) = resolve(target) {
            let m = CameraMonitor(camera: camera, endpoint: endpoint)
            let start = Date()
            m.onEvent = { event in
                if case .sound(let level) = event { print(String(format: "%5.1fs sound notification (%.0f dB)", Date().timeIntervalSince(start), level)) }
            }
            m.start()
            monitor = m
            RunLoop.main.run(until: Date().addingTimeInterval(5))
            m.expectBackgroundChange(for: 3 + 6)
        }
        var playingAt: Double?
        let began = Date()
        func stamp() -> String {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            return f.string(from: Date()) + String(format: " (+%.0fs)", Date().timeIntervalSince(began))
        }
        print("\(settings.noise.title) noise, warmth \(Int(settings.warmth * 100))%"
              + (settings.heartbeat ? ", heartbeat \(Int(settings.heartRate)) bpm" : "")
              + (settings.shushing ? ", shushing" : "") + (settings.waves ? ", waves" : ""))
        talk?.onState = { state in
            print("\(stamp()) talk: \(state)")
            if state == .playing, playingAt == nil { playingAt = macMic?.now }
        }
        var marks: [(volume: Double, from: Double, to: Double)] = []
        _ = apply(steps[0], to: &settings)
        synth.update(settings)
        synth.fade(to: 1, over: Soother.fadeSeconds)
        talk?.start()
        mac?.start()
        for (n, step) in steps.enumerated() {
            _ = apply(step, to: &settings)
            synth.update(settings)
            print("\(stamp()) step \(n + 1) of \(steps.count): \(step.isEmpty ? "as set" : step), volume \(Int(settings.volume * 100))% (\(String(format: "%.0f", 20 * log10(Double(settings.gain)))) dB)")
            let from = mic?.now ?? 0
            RunLoop.main.run(until: Date().addingTimeInterval(stepSeconds))
            marks.append((settings.volume, from, mic?.now ?? 0))
        }
        let stepsEnd = macMic?.now ?? 0
        synth.fade(to: 0, over: Soother.fadeSeconds)
        RunLoop.main.run(until: Date().addingTimeInterval(Soother.fadeSeconds + 0.2))
        var finished = talk == nil
        talk?.finish { finished = true }
        while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        mac?.stop()
        print("\(stamp()) stopped")
        if let monitor {
            monitor.expectBackgroundChange(for: 4)
            RunLoop.main.run(until: Date().addingTimeInterval(8))
            monitor.stop()
        }
        if let macMic {
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            macMic.stop()
            print("Mac microphone, room before: " + macMic.analyse(from: 0.3, to: 1.8))
            print("Mac microphone, playing:     " + macMic.analyse(from: (playingAt ?? 2) + 4, to: stepsEnd))
        }
        if let mic {
            RunLoop.main.run(until: Date().addingTimeInterval(2))
            mic.stop()
            for mark in marks {
                print("microphone at \(Int(mark.volume * 100))%: " + mic.summary(from: mark.from + 1, to: mark.to))
            }
            print("microphone after: " + mic.summary(from: (marks.last?.to ?? 0) + 4))
            let all = mic.chunks
            let seconds = Int((all.last?.t ?? 0).rounded(.up))
            let arrivals = Dictionary(grouping: all) { Int($0.arrived) }.mapValues(\.count)
            print("microphone quarter-seconds arriving each second: "
                  + (0...Int(mic.now)).map { "\($0):\(arrivals[$0] ?? 0)" }.joined(separator: " "))
            print("microphone each second, median dBFS (share of digital silence):")
            print((0..<seconds).compactMap { second -> String? in
                let part = all.filter { Int($0.t) == second }
                guard !part.isEmpty else { return nil }
                let silent = part.filter { $0.rms <= -99 }.count
                return String(format: "%d:%.0f%@", second, part.map(\.rms).sorted()[part.count / 2], silent > 0 ? "(\(silent)/\(part.count))" : "")
            }.joined(separator: " "))
        }
        return 0
    }

    /// `ReoBaby --render <soothing | popover> <out.png> [dark]`: draws a view offscreen, to check
    /// how it looks without showing a window. The popover is always dark, as the player shows it;
    /// offscreen it has no blur.
    @MainActor static func render(_ what: String, to path: String, dark: Bool) -> Int32 {
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

    /// `ReoBaby --api-poll <camera> <commands> [seconds]`: asks the camera over its HTTP API and prints
    /// the answers. Commands are names to read (`GetPerformance,GetRecV20`) or the API's own JSON
    /// (`[{"cmd":…}]`). With seconds, asks again once a second for that long, one line each.
    static func apiPoll(target: String, commands text: String, seconds: Double) -> Int32 {
        guard let (camera, endpoint) = resolve(target), let password = endpoint.password else {
            print("No camera with a saved password matching “\(target)”")
            return 2
        }
        let commands = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[String: Any]]
            ?? text.split(separator: ",").map { ["cmd": String($0), "action": 0, "param": ["channel": 0]] }
        let api = CameraAPI(host: endpoint.host, user: endpoint.user ?? "admin", password: password)
        final class Box { var code: Int32? }
        let box = Box()
        let began = Date()
        Task {
            do {
                repeat {
                    let asked = Date()
                    let answers = try await api.raw(commands)
                    let pretty = seconds <= 0
                    let data = try JSONSerialization.data(withJSONObject: pretty ? answers : answers.map { $0["value"] ?? $0 },
                                                          options: pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys])
                    let line = String(decoding: data, as: UTF8.self)
                    print(pretty ? "\(camera.displayName)\n\(line)" : String(format: "api %6.1fs  %@", asked.timeIntervalSince(began), line))
                    fflush(stdout)
                    if seconds > 0 { try await Task.sleep(nanoseconds: 1_000_000_000) }
                } while Date().timeIntervalSince(began) < seconds
                box.code = 0
            } catch {
                print("api: \(error)")
                box.code = 1
            }
            await api.logout()
        }
        while box.code == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return box.code ?? 1
    }

    /// `ReoBaby --monitor <camera> [seconds]`: background detection as the menu bar runs it.
    static func monitor(target: String, seconds: Double) -> Int32 {
        guard let (camera, endpoint) = resolve(target) else {
            print("No camera or rtsp:// URL matching “\(target)”")
            return 2
        }
        print("Monitoring \(camera.displayName) for \(Int(seconds))s")
        let monitor = CameraMonitor(camera: camera, endpoint: endpoint)
        let began = Date()
        var lastPrint = Date.distantPast
        monitor.onLevel = { level, floor in
            DispatchQueue.main.async {
                guard Date().timeIntervalSince(lastPrint) > 0.5 else { return }
                lastPrint = Date()
                print(String(format: "%5.1fs level %6.1f dB  floor %6.1f dB", Date().timeIntervalSince(began), level, floor))
            }
        }
        monitor.onEvent = { event in
            print(String(format: "%5.1fs EVENT %@", Date().timeIntervalSince(began), String(describing: event)))
        }
        monitor.start()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        monitor.stop()
        return 0
    }

    /// `ReoBaby --record <camera> <seconds> <file.wav>`: the camera's sound as it arrives, decoded,
    /// to tune the sound processing against (`--process`).
    static func record(target: String, seconds: Double, to path: String) -> Int32 {
        guard let (camera, endpoint) = resolve(target) else {
            print("No camera or rtsp:// URL matching “\(target)”")
            return 2
        }
        print("Recording \(Int(seconds))s of sound from \(camera.displayName) to \(path)")
        let queue = DispatchQueue(label: "reobaby.record")
        let decoder = AudioDecoder()
        var audio: AudioDepacketizer?
        var file: AVAudioFile?
        var frames = 0
        let client = RTSPClient(endpoint: endpoint, queue: queue, wantsVideo: false)
        client.onTracks = { tracks in
            audio = tracks.first.flatMap { makeAudioDepacketizer($0.media) }
            print("track: \(audio?.label ?? "none ReoBaby can decode")")
        }
        client.onRTP = { _, packet in
            guard let sample = audio?.push(packet, pts: { _ in .zero }),
                  let pcm = decoder.decode(sample), !pcm.samples.isEmpty else { return }
            if file == nil {
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: pcm.sampleRate,
                                               AVNumberOfChannelsKey: pcm.channels, AVLinearPCMBitDepthKey: 32,
                                               AVLinearPCMIsFloatKey: true]
                file = try? AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: settings,
                                        commonFormat: .pcmFormatFloat32, interleaved: true)
            }
            guard let file, let buffer = AVAudioPCMBuffer(pcm, format: file.processingFormat) else { return }
            try? file.write(from: buffer)
            frames += pcm.samples.count / pcm.channels
        }
        client.onFailure = { print("failed: \($0)") }
        client.start()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        client.stop()
        queue.sync { file = nil }
        print("wrote \(frames) frames")
        return frames > 0 ? 0 : 1
    }

    /// `ReoBaby --process <in.wav> [out.wav]`: runs a recording through the sound processing and
    /// sound detection, compares detection with and without noise reduction, and writes what you
    /// would hear.
    static func process(_ inPath: String, to outPath: String?) -> Int32 {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: inPath), commonFormat: .pcmFormatFloat32,
                                          interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024) else {
            print("Can't read \(inPath)")
            return 2
        }
        let rate = file.processingFormat.sampleRate
        let channels = Int(file.processingFormat.channelCount)
        var writer: AVAudioFile?
        if let outPath {
            writer = try? AVAudioFile(forWriting: URL(fileURLWithPath: outPath), settings: file.fileFormat.settings,
                                      commonFormat: .pcmFormatFloat32, interleaved: true)
        }
        print(String(format: "%@: %.1fs, %.0f Hz, %d ch", inPath, Double(file.length) / rate, rate, channels))
        print(SoundSettings.summary)

        let processor = AudioProcessor()
        let meter = AudioLevelMeter()
        var plain = SoundDetector(), cleaned = SoundDetector()
        var plainEvents: [Double] = [], cleanedEvents: [Double] = []
        var heard = LevelLog(), clean = LevelLog(), processed = LevelLog()
        var peak: Float = 0
        var position = 0
        func detect(_ detector: inout SoundDetector, _ events: inout [Double], _ level: Float, _ duration: Double, _ t: Double) {
            // As the monitor does: at most one event every 5 s.
            if detector.feed(level: level, duration: duration, at: t), t - (events.last ?? -10) > 5 { events.append(t) }
        }
        while (try? file.read(into: buffer, frameCount: 1024)) != nil, buffer.frameLength > 0 {
            let frames = Int(buffer.frameLength)
            let pcm = AudioDecoder.PCM(samples: Array(UnsafeBufferPointer(start: buffer.floatChannelData![0],
                                                                          count: frames * channels)),
                                       channels: channels, sampleRate: rate)
            let t = Double(position) / rate
            let duration = Double(frames) / rate
            position += frames

            let level = AudioLevelMeter.decibels(pcm.meanSquare)
            heard.add(level)
            detect(&plain, &plainEvents, level, duration, t)
            if let level = meter.level(of: pcm) {
                clean.add(level)
                detect(&cleaned, &cleanedEvents, level, duration, t)
            }
            let out = processor.process(pcm)
            guard !out.samples.isEmpty else { continue }
            processed.add(out)
            peak = max(peak, out.samples.map(abs).max() ?? 0)
            if let writer, let b = AVAudioPCMBuffer(out, format: writer.processingFormat) { try? writer.write(from: b) }
        }
        func times(_ events: [Double]) -> String {
            events.isEmpty ? "none" : events.map { String(format: "%.1fs", $0) }.joined(separator: " ")
        }
        print("noise reduction: " + LevelLog.compare(heard, clean))
        print("as you hear it:  " + LevelLog.compare(heard, processed)
              + String(format: ", peaks %.1f dBFS", AudioLevelMeter.decibels(peak * peak)))
        print("sound events without noise reduction: \(times(plainEvents))")
        print("sound events with noise reduction:    \(times(cleanedEvents))")
        return 0
    }

    static func run(target: String, seconds: Double) -> Int32 {
        guard let (camera, endpoint) = resolve(target) else {
            print("No camera or rtsp:// URL matching “\(target)” (config: \(ConfigStore.file.path))")
            return 2
        }
        let label = camera.displayName
        print("Probing \(label): \(endpoint.uri) user=\(endpoint.user ?? "-") password=\(endpoint.password == nil ? "none" : "set")")

        let sink = ProbeSink()
        let player = CameraPlayer(sink: sink)
        var authFailed = false
        let began = Date()
        func elapsed() -> String { String(format: "%5.2fs", Date().timeIntervalSince(began)) }
        player.onState = { state in
            print("\(elapsed()) state: \(state)")
            if state == .authFailed { authFailed = true }
        }
        player.onStreamInfo = { print("\(elapsed()) tracks: \($0)") }
        player.onVideoSize = { print("\(elapsed()) video: \(Int($0.width))x\(Int($0.height))") }
        player.play(endpoint)

        let end = Date().addingTimeInterval(seconds)
        while Date() < end && !authFailed {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        player.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        let s = sink.stats()
        print(SoundSettings.summary)
        let fps = Double(s.frames) / max(seconds, 1)
        print("""
        video: \(s.frames) frames (\(s.keyframes) key, ~\(String(format: "%.1f", fps)) fps), decoded \(s.decoded), decode errors \(s.errors)\(s.lastError == 0 ? "" : " (last OSStatus \(s.lastError))")
        audio: \(s.audioBuffers) buffers, renderer status \(sink.audio.status.rawValue)\(sink.audio.error.map { " error: \($0)" } ?? "")
        sound: \(s.levels)
        audio timing, as stamped: \(s.timingIn.summary)
        audio timing, as played:  \(s.timingOut.summary)
        sound and picture: \(s.sync.summary)
        """)
        if let password = endpoint.password {
            final class Box { var done = false; var name: String? }
            let box = Box()
            CameraAPI(host: endpoint.host, user: endpoint.user ?? "admin", password: password).deviceName {
                box.name = $0
                box.done = true
            }
            let deadline = Date().addingTimeInterval(10)
            while !box.done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            print("device name: \(box.name ?? "unavailable")")
        }
        if authFailed { return 3 }
        return s.decoded > 0 ? 0 : 1
    }
}

private final class ProbeSink: MediaSink {
    struct Stats {
        var frames = 0, keyframes = 0, decoded = 0, errors = 0, audioBuffers = 0
        var heard = LevelLog(), processed = LevelLog()
        var outPeak: Float = 0
        var lastError: OSStatus = 0
        var timingIn = Timing(), timingOut = Timing()
        var sync = AudioTimeline.Stats()
    }

    /// Whether buffers follow each other seamlessly, and arrive in time to play.
    struct Timing {
        var buffers = 0, gaps = 0, overlaps = 0, late = 0
        var gapSeconds = 0.0, overlapSeconds = 0.0, worstLate = 0.0
        private var end: CMTime?

        mutating func add(_ sample: CMSampleBuffer, now: CMTime) {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard let duration = sample.audioDuration else { return }
            buffers += 1
            if let end {
                let step = (pts - end).seconds
                if step > 0.002 { gaps += 1; gapSeconds += step }
                if step < -0.002 { overlaps += 1; overlapSeconds -= step }
            }
            end = pts + duration
            // Already behind the clock: the renderer can't play it on time.
            let lateBy = (now - pts).seconds
            if now.isValid, lateBy > 0 { late += 1; worstLate = max(worstLate, lateBy) }
        }

        var summary: String {
            String(format: "%d buffers, %d gaps (%.0f ms), %d overlaps (%.0f ms), %d late (worst %.0f ms)",
                   buffers, gaps, gapSeconds * 1000, overlaps, overlapSeconds * 1000, late, worstLate * 1000)
        }
    }

    let audio = AVSampleBufferAudioRenderer()
    private let processor = AudioProcessor()
    private let inDecoder = AudioDecoder()
    private let outDecoder = AudioDecoder()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let lock = NSLock()
    private var counters = Stats()
    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?

    init() {
        audio.isMuted = true
        synchronizer.addRenderer(audio)
    }

    func stats() -> Stats {
        lock.lock()
        defer { lock.unlock() }
        return counters
    }

    private func update(_ change: (inout Stats) -> Void) {
        lock.lock()
        change(&counters)
        lock.unlock()
    }

    func reset(clearImage: Bool) {
        synchronizer.rate = 0
        audio.flush()
        processor.reset()
        inDecoder.reset()
    }

    func start(latency: Double) {
        let now = hostNow()
        synchronizer.setRate(1, time: now - CMTime(seconds: latency, preferredTimescale: 1_000_000_000), atHostTime: now)
    }

    func enqueueVideo(_ sample: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let key = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        update { $0.frames += 1; if key { $0.keyframes += 1 } }

        guard let fd = CMSampleBufferGetFormatDescription(sample) else { return }
        if session == nil || format.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: fd) }) == true {
            if let session { VTDecompressionSessionInvalidate(session) }
            session = nil
            VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: nil,
                                         imageBufferAttributes: nil, outputCallback: nil,
                                         decompressionSessionOut: &session)
            format = fd
        }
        guard let session else {
            update { $0.errors += 1 }
            return
        }
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            [weak self] status, _, image, _, _ in
            self?.update {
                if status == noErr && image != nil { $0.decoded += 1 } else { $0.errors += 1; $0.lastError = status }
            }
        }
        if status != noErr { update { $0.errors += 1; $0.lastError = status } }
    }

    func enqueueAudio(_ sample: CMSampleBuffer) {
        let now = synchronizer.rate > 0 ? synchronizer.currentTime() : .invalid
        update { $0.audioBuffers += 1; $0.timingIn.add(sample, now: now) }
        let processed = processor.process(sample)
        let sync = processor.sync
        update { $0.sync = sync }
        if let processed {
            update { $0.timingOut.add(processed, now: now) }
            audio.enqueue(processed)
        }
        // Levels before and after processing, as you would hear them.
        if let before = inDecoder.decode(sample), !before.samples.isEmpty {
            update { $0.heard.add(before) }
        }
        if let after = processed.flatMap(outDecoder.decode), !after.samples.isEmpty {
            update {
                $0.processed.add(after)
                $0.outPeak = max($0.outPeak, after.samples.map(abs).max() ?? 0)
            }
        }
    }

    var videoFailed: Bool { false }
    func flushVideo() {}
}

private extension AudioTimeline.Stats {
    var summary: String {
        String(format: "apart by %.0f ms on average, at most %.0f ms (%.0f ms without catching up), more than 45 ms for %.1f s; "
               + "%d splices (%.0f ms); %d jumps back to the stamps",
               apartSum / max(seconds, 1e-9) * 1000, worstApart * 1000, worstUncorrected * 1000, apartSeconds,
               splices, spliced * 1000, resyncs)
    }
}

private extension ProbeSink.Stats {
    var levels: String {
        LevelLog.compare(heard, processed) + String(format: ", peaks %.1f dBFS", AudioLevelMeter.decibels(outPeak * outPeak))
    }
}

/// Levels of successive buffers, in dBFS.
struct LevelLog {
    private(set) var values: [Float] = []

    mutating func add(_ pcm: AudioDecoder.PCM) { values.append(AudioLevelMeter.decibels(pcm.meanSquare)) }
    mutating func add(_ level: Float) { values.append(level) }

    /// The level that this fraction of buffers stays under.
    func percentile(_ p: Double) -> Float {
        guard !values.isEmpty else { return -100 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }

    /// "background -52.0 → -40.1 dB, …": the quiet 10%, the median, the loudest 10% and 2%.
    static func compare(_ before: LevelLog, _ after: LevelLog) -> String {
        guard !before.values.isEmpty, !after.values.isEmpty else { return "no levels" }
        return [("background", 0.1), ("median", 0.5), ("busy", 0.9), ("loud", 0.98)].map { name, p in
            String(format: "%@ %.1f → %.1f dB", name, before.percentile(p), after.percentile(p))
        }.joined(separator: ", ")
    }
}

extension AVAudioPCMBuffer {
    /// An interleaved float buffer holding these samples.
    convenience init?(_ pcm: AudioDecoder.PCM, format: AVAudioFormat) {
        let frames = pcm.samples.count / pcm.channels
        self.init(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        frameLength = AVAudioFrameCount(frames)
        guard let data = floatChannelData else { return nil }
        pcm.samples.withUnsafeBufferPointer { data[0].update(from: $0.baseAddress!, count: frames * pcm.channels) }
    }
}

/// A camera's microphone, measured every quarter second in its own time, for checking that
/// the camera hears its speaker.
final class MicListener {
    struct Chunk { var t: Double; var rms: Float; var arrived = 0.0 }

    private let queue = DispatchQueue(label: "reobaby.mic")
    private let client: RTSPClient
    private let decoder = AudioDecoder()
    private var audio: AudioDepacketizer?
    private var file: AVAudioFile?
    private let path: String?
    private var pending: [Float] = []
    private var heard = 0
    private var firstHeard: Double?
    private var list: [Chunk] = []
    private let began = Date()

    var now: Double { Date().timeIntervalSince(began) }
    var chunks: [Chunk] { queue.sync { list } }

    init(endpoint: RTSPEndpoint, record path: String?) {
        self.path = path
        client = RTSPClient(endpoint: endpoint, queue: queue, wantsVideo: false)
        client.onTracks = { [weak self] tracks in self?.audio = tracks.first.flatMap { makeAudioDepacketizer($0.media) } }
        client.onRTP = { [weak self] _, packet in self?.receive(packet) }
        client.onFailure = { print("microphone: \($0)") }
    }

    func start() { client.start() }

    func stop() {
        client.stop()
        queue.sync { file = nil }
    }

    private func receive(_ packet: RTPPacket) {
        guard let sample = audio?.push(packet, pts: { _ in .zero }),
              let pcm = decoder.decode(sample), !pcm.samples.isEmpty else { return }
        let rate = pcm.sampleRate
        if let path, file == nil {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                           AVNumberOfChannelsKey: pcm.channels, AVLinearPCMBitDepthKey: 32,
                                           AVLinearPCMIsFloatKey: true]
            file = try? AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: settings,
                                    commonFormat: .pcmFormatFloat32, interleaved: true)
        }
        if let file, let buffer = AVAudioPCMBuffer(pcm, format: file.processingFormat) { try? file.write(from: buffer) }
        if firstHeard == nil { firstHeard = now }
        pending += stride(from: 0, to: pcm.samples.count, by: pcm.channels).map { pcm.samples[$0] }
        let size = Int(rate / 4)
        while pending.count >= size {
            let chunk = Array(pending.prefix(size))
            pending.removeFirst(size)
            heard += size
            let ms = chunk.reduce(0) { $0 + $1 * $1 } / Float(size)
            list.append(Chunk(t: (firstHeard ?? 0) + Double(heard) / rate, rms: AudioLevelMeter.decibels(ms), arrived: now))
        }
    }

    func summary(from: Double = 0, to: Double = .infinity) -> String {
        let part = chunks.filter { $0.t >= from && $0.t < to }
        guard !part.isEmpty else { return "nothing heard" }
        let levels = part.map(\.rms).sorted()
        return String(format: "quietest %.1f, median %.1f, loudest %.1f dBFS",
                      levels[levels.count / 10], levels[levels.count / 2], levels[levels.count - 1])
    }
}

/// This Mac's microphone: what a camera's speaker really plays, measured from beside it.
final class MacMic {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var rate = 48000.0
    private var began = Date()
    private let path: String

    init(path: String) { self.path = path }

    var now: Double { Date().timeIntervalSince(began) }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        rate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData else { return }
            let chunk = UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))
            self.lock.lock()
            self.samples.append(contentsOf: chunk)
            self.lock.unlock()
        }
        try engine.start()
        began = Date()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        let all = samples
        lock.unlock()
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true]
        guard !all.isEmpty, let file = try? AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: settings,
                                                         commonFormat: .pcmFormatFloat32, interleaved: true),
              let buffer = AVAudioPCMBuffer(AudioDecoder.PCM(samples: all, channels: 1, sampleRate: rate),
                                            format: file.processingFormat) else { return }
        try? file.write(from: buffer)
    }

    /// Level in 10 ms windows: the median, and the dips more than 10 dB under it (gaps in the
    /// sound), with their count, total and longest length.
    func analyse(from: Double, to: Double) -> String {
        lock.lock()
        let all = samples
        lock.unlock()
        let window = Int(rate / 100)
        let first = max(0, Int(from * rate)), last = min(all.count, Int(to * rate))
        guard last - first > window * 10 else { return "too short" }
        var levels: [Float] = []
        var i = first
        while i + window <= last {
            var sum: Float = 0
            for j in i..<i + window { sum += all[j] * all[j] }
            levels.append(AudioLevelMeter.decibels(sum / Float(window)))
            i += window
        }
        let median = levels.sorted()[levels.count / 2]
        var runs: [Int] = []
        var run = 0
        for level in levels {
            if level < median - 10 { run += 1 } else if run > 0 { runs.append(run); run = 0 }
        }
        if run > 0 { runs.append(run) }
        let seconds = Double(levels.count) / 100
        return String(format: "median %.1f dBFS over %.1fs; %d gaps, %.0f%% of the time, longest %d ms, gap lengths %@",
                      median, seconds, runs.count, Double(runs.reduce(0, +)) / Double(levels.count) * 100,
                      (runs.max() ?? 0) * 10, runs.prefix(12).map { "\($0 * 10)" }.joined(separator: ","))
    }
}
