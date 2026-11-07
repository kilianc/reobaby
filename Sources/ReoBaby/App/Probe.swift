import AVFoundation
import CoreMedia
import VideoToolbox

/// `ReoBaby --probe <camera name | number | rtsp://url> [seconds]`
/// Connects headlessly, decodes video with VideoToolbox, and reports what it got.
enum Probe {
    private static func resolve(_ target: String) -> (Camera, RTSPEndpoint)? {
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
        let fps = Double(s.frames) / max(seconds, 1)
        print("""
        video: \(s.frames) frames (\(s.keyframes) key, ~\(String(format: "%.1f", fps)) fps), decoded \(s.decoded), decode errors \(s.errors)\(s.lastError == 0 ? "" : " (last OSStatus \(s.lastError))")
        audio: \(s.audioBuffers) buffers, renderer status \(sink.audio.status.rawValue)\(sink.audio.error.map { " error: \($0)" } ?? "")
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
        var lastError: OSStatus = 0
    }

    let audio = AVSampleBufferAudioRenderer()
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
        update { $0.audioBuffers += 1 }
        audio.enqueue(sample)
    }

    var videoFailed: Bool { false }
    func flushVideo() {}
}
