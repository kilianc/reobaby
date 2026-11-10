import AVFoundation
import CoreMedia
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
