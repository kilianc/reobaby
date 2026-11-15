#if canImport(CoreMedia)
// Apple platforms only.
import AVFoundation
import CoreMedia

public protocol MediaSink: AnyObject {
    func reset(clearImage: Bool)
    /// Starts the clock so that a sample stamped "now" (host time) plays `latency` seconds later.
    func start(latency: Double)
    func enqueueVideo(_ sample: CMSampleBuffer)
    func enqueueAudio(_ sample: CMSampleBuffer)
    var videoFailed: Bool { get }
    func flushVideo()
}

public func hostNow() -> CMTime {
    CMClockGetTime(CMClockGetHostTimeClock())
}

/// Hardware-decoded video into an AVSampleBufferDisplayLayer plus audio, kept in
/// sync by one render synchronizer.
public final class RendererSink: MediaSink {
    let video: AVSampleBufferVideoRenderer
    let audio = AVSampleBufferAudioRenderer()
    let synchronizer = AVSampleBufferRenderSynchronizer()
    private let processor = AudioProcessor()

    public init(layer: AVSampleBufferDisplayLayer) {
        video = layer.sampleBufferRenderer
        synchronizer.addRenderer(video)
        synchronizer.addRenderer(audio)
    }

    public var muted: Bool {
        get { audio.isMuted }
        set { audio.isMuted = newValue }
    }

    public var volume: Float {
        get { audio.volume }
        set { audio.volume = newValue }
    }

    public func reset(clearImage: Bool) {
        synchronizer.rate = 0
        video.flush(removingDisplayedImage: clearImage, completionHandler: nil)
        audio.flush()
        processor.reset()
    }

    public func start(latency: Double) {
        let now = hostNow()
        synchronizer.setRate(1, time: now - CMTime(seconds: latency, preferredTimescale: 1_000_000_000), atHostTime: now)
    }

    public func enqueueVideo(_ sample: CMSampleBuffer) {
        video.enqueue(sample)
    }

    public func enqueueAudio(_ sample: CMSampleBuffer) {
        if let processed = processor.process(sample) { audio.enqueue(processed) }
    }

    public var videoFailed: Bool {
        video.status == .failed || video.requiresFlushToResumeDecoding
    }

    public func flushVideo() {
        video.flush()
    }
}
#endif
