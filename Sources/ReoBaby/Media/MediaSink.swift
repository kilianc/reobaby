import AVFoundation
import CoreMedia

protocol MediaSink: AnyObject {
    func reset(clearImage: Bool)
    /// Starts the clock so that a sample stamped "now" (host time) plays `latency` seconds later.
    func start(latency: Double)
    func enqueueVideo(_ sample: CMSampleBuffer)
    func enqueueAudio(_ sample: CMSampleBuffer)
    var videoFailed: Bool { get }
    func flushVideo()
}

func hostNow() -> CMTime {
    CMClockGetTime(CMClockGetHostTimeClock())
}

/// Hardware-decoded video into an AVSampleBufferDisplayLayer plus audio, kept in
/// sync by one render synchronizer.
final class RendererSink: MediaSink {
    let video: AVSampleBufferVideoRenderer
    let audio = AVSampleBufferAudioRenderer()
    let synchronizer = AVSampleBufferRenderSynchronizer()

    init(layer: AVSampleBufferDisplayLayer) {
        video = layer.sampleBufferRenderer
        synchronizer.addRenderer(video)
        synchronizer.addRenderer(audio)
    }

    var muted: Bool {
        get { audio.isMuted }
        set { audio.isMuted = newValue }
    }

    var volume: Float {
        get { audio.volume }
        set { audio.volume = newValue }
    }

    func reset(clearImage: Bool) {
        synchronizer.rate = 0
        video.flush(removingDisplayedImage: clearImage, completionHandler: nil)
        audio.flush()
    }

    func start(latency: Double) {
        let now = hostNow()
        synchronizer.setRate(1, time: now - CMTime(seconds: latency, preferredTimescale: 1_000_000_000), atHostTime: now)
    }

    func enqueueVideo(_ sample: CMSampleBuffer) {
        video.enqueue(sample)
    }

    func enqueueAudio(_ sample: CMSampleBuffer) {
        audio.enqueue(sample)
    }

    var videoFailed: Bool {
        video.status == .failed || video.requiresFlushToResumeDecoding
    }

    func flushVideo() {
        video.flush()
    }
}
