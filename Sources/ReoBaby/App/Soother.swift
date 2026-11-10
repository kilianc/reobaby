import Foundation

/// Soothing Sounds: noise made on the fly, played on the speaker of the camera you're watching
/// (or on this Mac), and faded out by a sleep timer. Its settings are user defaults, so
/// Settings ▸ Soothing, the moon's menu and the player's popover all change the same thing, and
/// what's playing follows right away.
///
/// Nothing starts, stops or switches suddenly near a sleeping baby: every start and stop fades
/// over `fadeSeconds`, a camera switch fades out on one and in on the other, and quitting fades
/// out before ReoBaby goes.
@MainActor
final class Soother: ObservableObject {
    static let shared = Soother()

    enum Output: String, CaseIterable, Identifiable {
        case camera, mac
        var id: String { rawValue }
    }

    enum Status: Equatable {
        case off
        case connecting
        case playing
        case retrying(String)
        case failed(String)
    }

    /// Stop-after choices, in minutes. "All night" stops after 8 hours: paediatricians advise
    /// against sound machines running around the clock.
    static let timerChoices: [Double] = [15, 30, 45, 60, 90, 120, 480]
    /// The timer's fade-out, in seconds: by the time it ends the baby is most likely asleep, so
    /// it takes the sound away more slowly than any other fade, never in less than 2 minutes.
    static let fadeOutChoices: [Double] = [120, 180, 300, 600]
    /// How long every start, stop and switch fades.
    nonisolated static let fadeSeconds = 10.0

    static let defaults: [String: Any] = [
        "sootheNoise": SoothingSettings.defaults.noise.rawValue, "sootheVolume": SoothingSettings.defaults.volume,
        "sootheWarmth": SoothingSettings.defaults.warmth, "sootheHeartbeat": SoothingSettings.defaults.heartbeat,
        "sootheHeartRate": SoothingSettings.defaults.heartRate, "sootheShushing": SoothingSettings.defaults.shushing,
        "sootheWaves": SoothingSettings.defaults.waves, "sootheHeartLevel": SoothingSettings.defaults.heartLevel,
        "sootheShushLevel": SoothingSettings.defaults.shushLevel, "sootheWavesLevel": SoothingSettings.defaults.wavesLevel,
        "sootheTimer": 45.0,
        "sootheFadeOut": 120.0, "sootheOutput": Output.camera.rawValue,
    ]

    @Published private(set) var status: Status = .off
    /// Stop was pressed and the sound is fading out: no longer on, so Play shows at once, but
    /// still going out. Play brings it back up.
    @Published private(set) var isFadingOut = false
    /// The sound as set plays on this Mac only, to choose by ear before playing it in the nursery.
    @Published private(set) var isPreviewing = false
    /// When the timer stops the sound.
    @Published private(set) var endsAt: Date?
    /// The camera it plays on: the one being watched, or none while paused or on No Camera.
    @Published private(set) var cameraName: String?

    /// The sound's level on the camera changed: sound notifications should relearn the room for
    /// this many seconds rather than take the change for a cry.
    var onBackgroundChange: ((Double) -> Void)?

    private var camera: RTSPEndpoint?
    private var synth: SoothingSynth?
    private var talk: SpeakerLink?
    /// How it reaches a camera's speaker; `--soothe-app-check` puts stand-ins here.
    var makeLink: (RTSPEndpoint) -> SpeakerLink = {
        BaichuanTalk(host: $0.host, user: $0.user ?? "admin", password: $0.password ?? "")
    }
    private var mac: MacSpeaker?
    private var playingOn: Output?
    private var fadeOutWork: DispatchWorkItem?
    private var endWork: DispatchWorkItem?
    private var stopping: DispatchWorkItem?
    private var settings = SoothingSettings.current
    private var timerMinutes = Soother.timerMinutes
    /// The timer has begun its fade-out.
    private var timerFadingOut = false
    private var preview: MacSpeaker?
    private var previewEnd: DispatchWorkItem?
    /// A preview fades in and out, and takes each change, this quickly: it plays on this Mac, so
    /// there's no baby to startle, and comparing sounds shouldn't mean waiting.
    static let previewFade = 1.5
    /// A preview forgotten stops by itself after this long.
    static let previewSeconds = 60.0

    var isOn: Bool {
        guard !isFadingOut else { return false }
        switch status {
        case .off, .failed: return false
        default: return true
        }
    }

    /// Sound still goes out, perhaps fading: quitting waits for it.
    var isSounding: Bool { synth != nil }

    static var output: Output {
        UserDefaults.standard.string(forKey: "sootheOutput").flatMap(Output.init) ?? .camera
    }

    private static func number(_ key: String) -> Double {
        let d = UserDefaults.standard
        return d.object(forKey: key) == nil ? defaults[key] as? Double ?? 0 : d.double(forKey: key)
    }

    static var timerMinutes: Double { number("sootheTimer") }
    static var fadeOut: Double { max(fadeOutChoices[0], number("sootheFadeOut")) }
    /// What the camera already holds plays on after a change: sound notifications allow for it.
    private static let cameraDelay = BaichuanTalk.lead + 1

    // MARK: - Control

    func toggle() {
        isOn ? stop() : play()
    }

    /// Preview is for choosing; once it plays on this Mac for real, there's nothing to preview.
    var canPreview: Bool { !(isSounding && playingOn == .mac) }

    func togglePreview() {
        isPreviewing ? stopPreview() : startPreview()
    }

    /// Plays the sound as set on this Mac, whatever plays on the camera, for up to a minute.
    func startPreview() {
        guard preview == nil, canPreview else { return }
        let speaker = MacSpeaker(changeSeconds: Self.previewFade)
        speaker.synth.fade(to: 1, over: Self.previewFade)
        speaker.start()
        preview = speaker
        isPreviewing = true
        let end = DispatchWorkItem { [weak self] in self?.stopPreview() }
        previewEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.previewSeconds, execute: end)
    }

    func stopPreview() {
        previewEnd?.cancel()
        previewEnd = nil
        guard let speaker = preview else { return }
        preview = nil
        isPreviewing = false
        speaker.synth.fade(to: 0, over: Self.previewFade)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.previewFade + 0.1) { speaker.stop() }
    }

    func play() {
        let output = Self.output
        if output == .camera && camera == nil {
            status = .failed("Choose a camera to play on its speaker")
            return
        }
        stopPreview()
        cancelStop()
        if let synth, playingOn == output {
            // Already playing, or fading out after Stop or at the timer's end: come back up and
            // restart the timer.
            isFadingOut = false
            synth.fade(to: 1, over: Self.fadeSeconds)
            scheduleTimer()
            return
        }
        retire()
        settings = SoothingSettings.current
        playingOn = output
        start(on: output)
        scheduleTimer()
    }

    private func start(on output: Output) {
        switch output {
        case .camera:
            guard let camera else { return }
            let synth = SoothingSynth(sampleRate: 16000, lowestFrequency: BaichuanTalk.lowestFrequency)
            self.synth = synth
            synth.fade(to: 1, over: Self.fadeSeconds)
            connect(to: camera, synth: synth)
            onBackgroundChange?(Self.fadeSeconds + Self.cameraDelay + 2)
        case .mac:
            let speaker = MacSpeaker()
            mac = speaker
            synth = speaker.synth
            speaker.synth.fade(to: 1, over: Self.fadeSeconds)
            speaker.start()
            status = .playing
        }
    }

    /// Fades out over `fade` seconds, then hangs up.
    func stop(fade: Double = Soother.fadeSeconds) {
        guard isOn else {
            // Clears a failure; a fade already under way goes on.
            if synth == nil { status = .off }
            return
        }
        cancelTimer()
        endsAt = nil
        synth?.fade(to: 0, over: fade)
        cancelStop()
        isFadingOut = true
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hangUp()
            self.isFadingOut = false
            self.status = .off
            if self.playingOn == .camera { self.onBackgroundChange?(Self.cameraDelay + 2) }
            self.playingOn = nil
        }
        stopping = work
        DispatchQueue.main.asyncAfter(deadline: .now() + fade, execute: work)
    }

    /// ReoBaby is about to quit: fades out, lets the camera play out what it holds, then `done`.
    func fadeOutForQuit(_ done: @escaping () -> Void) {
        guard synth != nil else { return done() }
        cancelTimer()
        cancelStop()
        endsAt = nil
        retire { done() }
    }

    /// ReoBaby is quitting: hang up now, freeing the camera's speaker.
    func shutdown() {
        preview?.stop()
        preview = nil
        cancelTimer()
        talk?.stop()
        talk = nil
        mac?.stop()
        mac = nil
    }

    /// The camera being watched. Sound on the camera moves with it; with none, it stops.
    func setCamera(name: String?, endpoint: RTSPEndpoint?) {
        let changed = endpoint != camera
        camera = endpoint
        cameraName = endpoint == nil ? nil : name
        guard changed, playingOn == .camera, isOn, stopping == nil else { return }
        // The sound fades out on the camera it leaves, and in on the next; unless the timer is
        // already fading it out, when coming back up on the next camera would only wake the baby.
        retire()
        if endpoint != nil, !timerFadingOut {
            start(on: .camera)
        } else {
            // Paused, No Camera, or the timer ending: once it has faded, ReoBaby keeps no
            // connection to any camera.
            cancelTimer()
            endsAt = nil
            playingOn = nil
            status = .off
        }
    }

    /// A setting changed, most likely in Settings or a menu: what's playing follows.
    func settingsChanged() {
        preview?.synth.update(SoothingSettings.current)
        guard isOn, stopping == nil else { return }
        let new = SoothingSettings.current
        if new != settings {
            let louder = new.gain > settings.gain * 1.4 || new.noise != settings.noise
                || (new.heartbeat && !settings.heartbeat) || (new.shushing && !settings.shushing) || (new.waves && !settings.waves)
                || (new.heartbeat && new.heartLevel > settings.heartLevel + 0.05)
                || (new.shushing && new.shushLevel > settings.shushLevel + 0.05)
                || (new.waves && new.wavesLevel > settings.wavesLevel + 0.05)
            settings = new
            synth?.update(new)
            if louder, playingOn == .camera { onBackgroundChange?(SoothingSynth.changeSeconds + Self.cameraDelay + 2) }
        }
        if Self.output != playingOn {
            play()
        } else if Self.timerMinutes != timerMinutes {
            scheduleTimer()
        }
    }

    // MARK: - Outputs

    private func connect(to endpoint: RTSPEndpoint, synth: SoothingSynth) {
        let talk = makeLink(endpoint)
        talk.render = { buffer in buffer.withUnsafeMutableBufferPointer { synth.render($0) } }
        talk.onState = { [weak self, weak talk] state in
            guard let self, let talk, talk === self.talk else { return }
            switch state {
            case .connecting: if self.status != .playing { self.status = .connecting }
            case .playing:
                // Back after a dropped connection: fade in again, as at the start.
                if case .retrying = self.status, self.stopping == nil { synth.fade(to: 1, over: Self.fadeSeconds) }
                self.status = .playing
            case .retrying(let why):
                // Nothing reaches the camera meanwhile: start from silence when it's back.
                synth.fade(to: 0, over: 0)
                self.status = .retrying(why)
            case .failed(let why):
                self.hangUp()
                self.cancelTimer()
                self.endsAt = nil
                self.playingOn = nil
                self.status = .failed(why)
            }
        }
        self.talk = talk
        if status != .playing { status = .connecting }
        talk.start()
    }

    private func hangUp() {
        if let talk {
            // Sends a moment of silence first, so the camera's buffer plays out quietly.
            talk.finish()
            self.talk = nil
        }
        mac?.stop()
        mac = nil
        synth = nil
    }

    /// Fades out what plays now and hangs it up after, while something else may start.
    private func retire(then done: (() -> Void)? = nil) {
        guard let synth else {
            hangUp()
            done?()
            return
        }
        synth.fade(to: 0, over: Self.fadeSeconds)
        let talk = self.talk, mac = self.mac
        self.talk = nil
        self.mac = nil
        self.synth = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeSeconds) {
            mac?.stop()
            if let talk { talk.finish { done?() } } else { done?() }
        }
    }

    private func cancelStop() {
        stopping?.cancel()
        stopping = nil
    }

    // MARK: - Timer

    private func scheduleTimer() {
        cancelTimer()
        timerMinutes = Self.timerMinutes
        let total = timerMinutes * 60
        let end = Date().addingTimeInterval(total)
        endsAt = end
        let fade = min(Self.fadeOut, total / 2)
        let fadeWork = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.timerFadingOut = true
            self.synth?.fade(to: 0, over: fade)
            // Hangs up once the fade has finished, however late this ran: a timer this long may
            // fire a little late, and the end must never cut the fade short.
            let endWork = DispatchWorkItem { [weak self] in self?.stop(fade: 0.5) }
            self.endWork = endWork
            DispatchQueue.main.asyncAfter(deadline: .now() + fade, execute: endWork)
        }
        fadeOutWork = fadeWork
        DispatchQueue.main.asyncAfter(deadline: .now() + total - fade, execute: fadeWork)
    }

    private func cancelTimer() {
        timerFadingOut = false
        fadeOutWork?.cancel()
        endWork?.cancel()
        fadeOutWork = nil
        endWork = nil
    }

    // MARK: - Words

    /// "Playing on White Knight", "Connecting to White Knight…", …
    var statusText: String {
        let place = playingOn == .mac || (playingOn == nil && Self.output == .mac)
            ? "this Mac" : (cameraName ?? "the camera")
        if isFadingOut { return "Fading out on \(place)…" }
        switch status {
        case .off: return "Off"
        case .connecting: return "Connecting to \(place)…"
        case .playing: return "Playing on \(place)"
        case .retrying(let why): return why
        case .failed(let why): return why
        }
    }

    /// "until 8:45 PM", while playing.
    var untilText: String? {
        guard isOn, let endsAt else { return nil }
        return "until " + endsAt.formatted(date: .omitted, time: .shortened)
    }

    static func describeTimer(_ minutes: Double) -> String {
        if minutes >= 480 { return "All night (8 hours)" }
        if minutes >= 60 {
            let hours = minutes / 60
            return hours == hours.rounded() ? (hours == 1 ? "1 hour" : "\(Int(hours)) hours") : String(format: "%g hours", hours)
        }
        return "\(Int(minutes)) minutes"
    }

    static func describeSeconds(_ seconds: Double) -> String {
        seconds >= 60 ? (seconds == 60 ? "1 minute" : "\(Int(seconds / 60)) minutes") : "\(Int(seconds)) seconds"
    }
}

/// What Soothing Sounds needs of a camera's speaker: BaichuanTalk, or a stand-in that measures.
protocol SpeakerLink: AnyObject {
    /// Called on main.
    var onState: ((BaichuanTalk.State) -> Void)? { get set }
    var render: ((inout [Float]) -> Void)? { get set }
    func start()
    /// Hangs up at once.
    func stop()
    /// Lets the camera play out what it holds, then hangs up.
    func finish(completion: (() -> Void)?)
}

extension SpeakerLink {
    func finish() { finish(completion: nil) }
}

extension BaichuanTalk: SpeakerLink {}
