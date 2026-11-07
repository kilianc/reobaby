import CoreMedia
import Foundation

/// Watches one camera in the background, whether or not it is on screen:
/// motion/AI state from the camera's API, and loudness from an audio-only RTSP stream.
final class CameraMonitor {
    enum Event {
        case detection(CameraAPI.Detection)
        case sound(level: Float)
    }

    let camera: Camera
    let endpoint: RTSPEndpoint
    /// Called on the main queue.
    var onEvent: ((Event) -> Void)?
    /// Debug: every measured level and the current noise floor (monitor queue).
    var onLevel: ((Float, Float) -> Void)?

    private let queue = DispatchQueue(label: "reobaby.monitor", qos: .utility)
    private let api: CameraAPI?
    private var client: RTSPClient?
    private var audio: AudioDepacketizer?
    private let meter = AudioLevelMeter()
    private var detector = SoundDetector()
    private var lastSoundEvent: CFAbsoluteTime = 0
    private var lastPacket: CFAbsoluteTime = 0
    private var retryDelay = 2.0
    private var watchdog: DispatchSourceTimer?
    private var pollTask: Task<Void, Never>?
    private var stopped = false

    init(camera: Camera, endpoint: RTSPEndpoint) {
        self.camera = camera
        self.endpoint = endpoint
        api = endpoint.password.map { CameraAPI(host: endpoint.host, user: endpoint.user ?? "admin", password: $0) }
    }

    func start() {
        queue.async { [self] in
            connectAudio()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 5, repeating: 5)
            t.setEventHandler { [weak self] in
                guard let self, self.client != nil else { return }
                if CFAbsoluteTimeGetCurrent() - self.lastPacket > 20 { self.audioFailed() }
            }
            t.resume()
            watchdog = t
        }
        startPolling()
    }

    func stop() {
        pollTask?.cancel()
        queue.async { [self] in
            stopped = true
            watchdog?.cancel()
            client?.stop()
            client = nil
        }
    }

    /// A still for notifications; nil if the camera doesn't offer one.
    func snapshot() async -> Data? {
        try? await api?.snapshot()
    }

    // MARK: - Sound

    private func connectAudio() {
        guard !stopped else { return }
        detector.reset()
        lastPacket = CFAbsoluteTimeGetCurrent()
        let c = RTSPClient(endpoint: endpoint, queue: queue, wantsVideo: false)
        c.onTracks = { [weak self] tracks in
            guard let self, let media = tracks.first?.media else { return }
            self.audio = makeAudioDepacketizer(media)
        }
        c.onRTP = { [weak self] _, packet in self?.handle(packet) }
        c.onFailure = { [weak self, weak c] _ in
            guard let self, let c, c === self.client else { return }
            self.audioFailed()
        }
        client = c
        c.start()
    }

    private func audioFailed() {
        client?.onFailure = nil
        client?.stop()
        client = nil
        guard !stopped else { return }
        queue.asyncAfter(deadline: .now() + retryDelay) { [weak self] in self?.connectAudio() }
        retryDelay = min(retryDelay * 2, 60)
    }

    private func handle(_ packet: RTPPacket) {
        let now = CFAbsoluteTimeGetCurrent()
        lastPacket = now
        retryDelay = 2
        guard let audio,
              let sample = audio.push(packet, pts: { _ in .zero }),
              let level = meter.level(of: sample) else { return }
        let frames = CMSampleBufferGetNumSamples(sample)
        let rate = Double(audio.clockRate)
        let isAAC = audio is AACDepacketizer
        let duration = Double(isAAC ? frames * 1024 : frames) / rate
        onLevel?(level, detector.noiseFloor ?? level)
        if detector.feed(level: level, duration: duration, at: now), now - lastSoundEvent > 5 {
            lastSoundEvent = now
            DispatchQueue.main.async { self.onEvent?(.sound(level: level)) }
        }
    }

    // MARK: - Motion

    private func startPolling() {
        guard let api else { return }
        pollTask = Task.detached(priority: .utility) { [weak self] in
            var last = CameraAPI.Detection()
            var failures = 0
            while !Task.isCancelled {
                do {
                    let current = try await api.detection()
                    failures = 0
                    let rising = (current.motion && !last.motion) || (current.person && !last.person)
                        || (current.vehicle && !last.vehicle) || (current.animal && !last.animal)
                    last = current
                    if rising {
                        DispatchQueue.main.async { self?.onEvent?(.detection(current)) }
                    }
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                } catch {
                    failures += 1
                    try? await Task.sleep(nanoseconds: UInt64(min(60, 2 * failures)) * 1_000_000_000)
                }
            }
            await api.logout()
        }
    }
}
