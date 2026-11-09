import CoreMedia
import Foundation

/// Owns one RTSP connection at a time, turns its RTP into timed sample buffers for
/// a MediaSink, and reconnects on failure. Callbacks arrive on the main queue.
final class CameraPlayer {
    enum State: Equatable {
        case connecting
        case playing
        case retrying(String)
        case authFailed
    }

    /// Jitter buffer: how far behind arrival time playback runs.
    static let latency = 0.4
    /// Seamless audio may run up to this much further ahead than `latency` before it's
    /// brought back to the camera's timestamps.
    static let audioSlack = 0.2

    var onState: ((State) -> Void)?
    var onVideoSize: ((CGSize) -> Void)?
    var onStreamInfo: ((String) -> Void)?

    let queue = DispatchQueue(label: "reobaby.player", qos: .userInteractive)
    private let sink: MediaSink
    private var endpoint: RTSPEndpoint?
    private var client: RTSPClient?
    private var retryDelay = 1.0
    private var retryWork: DispatchWorkItem?
    private var watchdog: DispatchSourceTimer?

    // Per-connection state, confined to `queue`.
    private var videoTrack: Int?
    private var audioTrack: Int?
    private var video: H26xDepacketizer?
    private var audio: AudioDepacketizer?
    private var videoTimeline = RTPTimeline(clockRate: 90000)
    private var audioTimeline = RTPTimeline(clockRate: 8000)
    private var videoOrigin: (rtp: Int64, host: CMTime)?
    private var audioOrigin: (rtp: Int64, host: CMTime)?
    /// Where the next audio buffer starts when it follows on seamlessly.
    private var audioNext: CMTime?
    /// For `--probe`: times audio jumped to the camera's timestamps, and the largest difference
    /// from them it played through.
    private(set) var audioResyncs = 0
    private(set) var audioLargestSmoothed = 0.0
    private var drift = CMTime.zero
    private var started = false
    private var connectedAt = CFAbsoluteTimeGetCurrent()
    private var lastPacketAt = CFAbsoluteTimeGetCurrent()
    private var windowStart: CFAbsoluteTime?
    private var windowMaxLateness = -Double.infinity
    private var lastSize: CGSize?

    init(sink: MediaSink) {
        self.sink = sink
    }

    func play(_ endpoint: RTSPEndpoint) {
        queue.async { [self] in
            teardown()
            self.endpoint = endpoint
            retryDelay = 1
            lastSize = nil
            sink.reset(clearImage: true)
            emit(.connecting)
            connect()
        }
    }

    func stop() {
        queue.async { [self] in
            teardown()
            endpoint = nil
            sink.reset(clearImage: true)
        }
    }

    private func teardown() {
        retryWork?.cancel()
        retryWork = nil
        watchdog?.cancel()
        watchdog = nil
        client?.onFailure = nil
        client?.stop()
        client = nil
    }

    private func connect() {
        guard let endpoint else { return }
        videoTrack = nil
        audioTrack = nil
        video = nil
        audio = nil
        videoOrigin = nil
        audioOrigin = nil
        audioNext = nil
        drift = .zero
        started = false
        windowStart = nil
        connectedAt = CFAbsoluteTimeGetCurrent()
        lastPacketAt = connectedAt

        let c = RTSPClient(endpoint: endpoint, queue: queue)
        c.onTracks = { [weak self] in self?.configure($0) }
        c.onRTP = { [weak self] in self?.handle(track: $0, packet: $1) }
        c.onFailure = { [weak self, weak c] failure in
            guard let self, let c, c === self.client else { return }
            self.failed(failure)
        }
        client = c
        startWatchdog()
        c.start()
    }

    private func failed(_ failure: RTSPClient.Failure) {
        teardown()
        switch failure {
        case .auth:
            emit(.authFailed)
        case .message(let message):
            emit(.retrying(message))
            let work = DispatchWorkItem { [weak self] in self?.connect() }
            retryWork = work
            queue.asyncAfter(deadline: .now() + retryDelay, execute: work)
            retryDelay = min(retryDelay * 2, 10)
        }
    }

    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self, self.client != nil else { return }
            let now = CFAbsoluteTimeGetCurrent()
            if !self.started && now - self.connectedAt > 15 {
                self.failed(.message("Timed out waiting for video"))
            } else if self.started && now - self.lastPacketAt > 6 {
                self.failed(.message("Stream stalled"))
            }
        }
        t.resume()
        watchdog = t
    }

    private func configure(_ tracks: [RTSPClient.Track]) {
        var info: [String] = []
        for (i, track) in tracks.enumerated() {
            let m = track.media
            if m.isSupportedVideo {
                let codec: H26xDepacketizer.Codec = m.encoding == "H264" ? .h264 : .h265
                video = H26xDepacketizer(codec: codec, fmtp: m.fmtp)
                videoTrack = i
                videoTimeline = RTPTimeline(clockRate: m.clockRate > 0 ? m.clockRate : 90000)
                info.append(codec.rawValue)
            } else if m.isSupportedAudio, let a = makeAudioDepacketizer(m) {
                audio = a
                audioTrack = i
                audioTimeline = RTPTimeline(clockRate: Int(a.clockRate))
                info.append(a.label)
            }
        }
        let text = info.joined(separator: " + ")
        DispatchQueue.main.async { self.onStreamInfo?(text) }
    }

    private func handle(track: Int, packet: RTPPacket) {
        lastPacketAt = CFAbsoluteTimeGetCurrent()
        if track == videoTrack, let video {
            for au in video.push(packet) { deliver(au, from: video) }
        } else if track == audioTrack, let audio {
            if let sample = audio.push(packet, pts: audioPTS) {
                audioNext = sample.audioDuration.map { CMSampleBufferGetPresentationTimeStamp(sample) + $0 }
                if video == nil && !started { begin() }
                sink.enqueueAudio(sample)
            }
        }
    }

    private func deliver(_ au: H26xDepacketizer.AccessUnit, from video: H26xDepacketizer) {
        let now = hostNow()
        let rtp = videoTimeline.unwrap(au.timestamp)
        if videoOrigin == nil { videoOrigin = (rtp, now) }
        var pts = videoOrigin!.host + CMTime(value: rtp - videoOrigin!.rtp, timescale: videoTimeline.clockRate) + drift

        // Keep the camera clock aligned with ours: shift later when frames would arrive
        // too late to play, and earlier when buffering has grown well beyond `latency`.
        var lateness = (now - pts).seconds
        if lateness > Self.latency - 0.1 {
            drift = drift + CMTime(seconds: lateness, preferredTimescale: 1_000_000_000)
            pts = now
            lateness = 0
        }
        let wall = CFAbsoluteTimeGetCurrent()
        if windowStart == nil { windowStart = wall }
        windowMaxLateness = max(windowMaxLateness, lateness)
        if wall - windowStart! > 5 {
            if windowMaxLateness < -0.15 {
                drift = drift + CMTime(seconds: windowMaxLateness, preferredTimescale: 1_000_000_000)
            }
            windowStart = wall
            windowMaxLateness = -.infinity
        }

        if sink.videoFailed {
            sink.flushVideo()
            if !au.isKeyframe {
                video.needsKeyframe = true
                return
            }
        }
        guard let sample = video.sampleBuffer(for: au, pts: pts) else { return }
        if !started { begin() }
        sink.enqueueVideo(sample)

        if let size = video.dimensions, size != lastSize {
            lastSize = size
            DispatchQueue.main.async { self.onVideoSize?(size) }
        }
    }

    /// Cameras stamp audio with when they captured it, give or take tens of milliseconds
    /// (Reolinks by up to ±60 ms per 64 ms buffer). Played as stamped, that opens gaps and
    /// overlaps, and the sound comes out choppy. So each buffer follows on from the last for
    /// as long as it still arrives in time to play and the delay doesn't pile up. That also
    /// rides out `drift` moving to keep up with late video, which would otherwise cut or
    /// silence a few hundred milliseconds of sound each time.
    private func audioPTS(_ timestamp: UInt32) -> CMTime {
        let rtp = audioTimeline.unwrap(timestamp)
        if audioOrigin == nil { audioOrigin = (rtp, hostNow()) }
        let stamped = audioOrigin!.host + CMTime(value: rtp - audioOrigin!.rtp, timescale: audioTimeline.clockRate) + drift
        guard let next = audioNext else { return stamped }
        // A sample stamped t plays at host time t + latency (see `RendererSink.start`).
        let untilPlayed = (next - hostNow()).seconds + Self.latency
        guard untilPlayed > 0.03, untilPlayed < Self.latency + Self.audioSlack else {
            audioResyncs += 1
            return stamped
        }
        audioLargestSmoothed = max(audioLargestSmoothed, abs((stamped - next).seconds))
        return next
    }

    private func begin() {
        started = true
        retryDelay = 1
        sink.start(latency: Self.latency)
        emit(.playing)
    }

    private func emit(_ state: State) {
        DispatchQueue.main.async { self.onState?(state) }
    }
}
