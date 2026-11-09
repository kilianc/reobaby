import Accelerate
import AVFoundation
import CoreMedia

/// Camera sound settings: `defaults write com.kilianciuffolo.cam <key> -float <dB>`.
enum SoundSettings {
    /// How far steady background noise (a fan, a white-noise machine, mic hiss) is turned down
    /// for listening. Gentle, because more starts to sound metallic, and the background is
    /// kept quiet anyway by not boosting it. 0 turns noise reduction off.
    static var noiseReductionDB: Double { value("noiseReduction", default: 12) }
    /// Sound notifications listen through more noise reduction: how it sounds doesn't matter
    /// there, only that a cry stands out. Off when noise reduction is off.
    static var detectionReductionDB: Double { noiseReductionDB > 0 ? max(noiseReductionDB, 24) : 0 }
    /// How much quiet sounds are raised. Louder sounds are raised less, so everything ends up
    /// clearly audible without loud sounds blasting. 0 turns this off.
    static var boostDB: Double { value("audioBoost", default: 40) }
    /// Sounds louder than this (dBFS, before the boost) are raised less.
    static var thresholdDB: Double { value("compressorThreshold", default: -50) }
    /// Above the threshold, this many dB louder in is 1 dB louder out.
    static var ratio: Double { value("compressorRatio", default: 2) }

    static var summary: String {
        String(format: "noise reduction %g dB, boost %g dB, compressing above %g dBFS at %g:1",
               noiseReductionDB, boostDB, thresholdDB, ratio)
    }

    private static func value(_ key: String, default value: Double) -> Double {
        UserDefaults.standard.object(forKey: key) == nil ? value : UserDefaults.standard.double(forKey: key)
    }
}

/// Makes camera sound clearer and louder: noise reduction, then a compressor that raises quiet
/// sounds more than loud ones, then a limiter so nothing distorts. Reolink microphones are quiet
/// and the renderer's volume stops at 1, so ReoBaby does this to the decoded sound itself.
final class AudioProcessor {
    private let decoder = AudioDecoder()
    private let cleaner = NoiseCleaner()
    private var compressor = Compressor(makeupDB: 0, thresholdDB: 0, ratio: 1)
    private var limiter = Limiter()
    private var reduction: Float = 0
    /// Decoded frames in and processed frames out since the stream began; noise reduction
    /// hands sound back a little later than it arrives.
    private var framesIn = 0
    private var framesOut = 0
    private var output: (rate: Double, channels: Int, format: CMAudioFormatDescription)?

    init() { reset() }

    var isEnabled: Bool { reduction > 0 || compressor.makeupDB > 0 }

    /// Called before each new stream; picks up changed settings.
    func reset() {
        decoder.reset()
        reduction = Float(max(SoundSettings.noiseReductionDB, 0))
        cleaner.reset(reductionDB: reduction)
        compressor = Compressor(makeupDB: Float(max(SoundSettings.boostDB, 0)), thresholdDB: Float(SoundSettings.thresholdDB),
                                ratio: Float(max(SoundSettings.ratio, 1)))
        limiter = Limiter()
        framesIn = 0
        framesOut = 0
    }

    /// The buffer processed, as float PCM. The buffer itself when processing is off or its format
    /// can't be decoded; nil when there is nothing to play yet.
    func process(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard isEnabled else { return sample }
        guard let pcm = decoder.decode(sample) else { return decoder.canDecode ? nil : sample }
        guard !pcm.samples.isEmpty else { return nil }
        let first = framesIn
        let out = process(pcm)
        guard !out.samples.isEmpty else { return nil }
        // The output starts `framesIn - framesOut` frames before this buffer's first frame.
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            + CMTime(value: Int64(framesOut - first), timescale: CMTimeScale(pcm.sampleRate))
        framesOut += out.samples.count / out.channels
        return makeBuffer(out, pts: pts)
    }

    /// The same processing on decoded samples (for `--process`). Advances `framesIn` only;
    /// `framesOut` is the caller's to advance.
    /// Noise reduction takes most from where the noise is loudest, usually the low mids, which
    /// leaves sounds thin and bright. A gentle tilt (+3 dB below 400 Hz, -4 dB above 3 kHz)
    /// puts the warmth back. Mono streams only; per channel state would be needed otherwise.
    private var tone: (rate: Double, low: Shelf, high: Shelf)?

    func process(_ pcm: AudioDecoder.PCM) -> AudioDecoder.PCM {
        framesIn += pcm.samples.count / pcm.channels
        var out = reduction > 0 ? cleaner.clean(pcm) : pcm
        if reduction > 0, out.channels == 1, !out.samples.isEmpty {
            if tone?.rate != out.sampleRate {
                tone = (out.sampleRate, Shelf(low: true, hz: 400, gainDB: 3, rate: out.sampleRate),
                        Shelf(low: false, hz: 3000, gainDB: -4, rate: out.sampleRate))
            }
            for i in out.samples.indices {
                out.samples[i] = tone!.high.process(tone!.low.process(out.samples[i]))
            }
        }
        if compressor.makeupDB > 0 {
            compressor.process(&out)
            limiter.process(&out)
        }
        return out
    }

    private func makeBuffer(_ pcm: AudioDecoder.PCM, pts: CMTime) -> CMSampleBuffer? {
        if output.map({ $0.rate != pcm.sampleRate || $0.channels != pcm.channels }) ?? true {
            let frameBytes = UInt32(4 * pcm.channels)
            var asbd = AudioStreamBasicDescription(
                mSampleRate: pcm.sampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: frameBytes, mFramesPerPacket: 1, mBytesPerFrame: frameBytes,
                mChannelsPerFrame: UInt32(pcm.channels), mBitsPerChannel: 32, mReserved: 0)
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = pcm.channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
            let hasLayout = pcm.channels <= 2
            var fd: CMAudioFormatDescription?
            let status = withUnsafePointer(to: &layout) { layoutPointer in
                CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault, asbd: &asbd,
                    layoutSize: hasLayout ? MemoryLayout<AudioChannelLayout>.size : 0,
                    layout: hasLayout ? layoutPointer : nil,
                    magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
            }
            guard status == noErr, let fd else { return nil }
            output = (pcm.sampleRate, pcm.channels, fd)
        }
        guard let output, let block = makeBlockBuffer(pcm.samples.withUnsafeBytes { Array($0) }) else { return nil }
        var sb: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: output.format,
            sampleCount: pcm.samples.count / pcm.channels, presentationTimeStamp: pts,
            packetDescriptions: nil, sampleBufferOut: &sb)
        return status == noErr ? sb : nil
    }
}

/// Rumble filter plus noise suppression for every channel of a stream. The sound comes back
/// `NoiseSuppressor`'s latency later, in whole hops, so a call can return fewer or no samples.
final class NoiseCleaner {
    private var reductionDB: Float = 24
    private var format: (rate: Double, channels: Int)?
    private var filters: [HighPass] = []
    private var suppressors: [NoiseSuppressor] = []

    func reset(reductionDB: Float) {
        self.reductionDB = reductionDB
        format = nil
    }

    func clean(_ pcm: AudioDecoder.PCM) -> AudioDecoder.PCM {
        let channels = pcm.channels
        if format.map({ $0.rate != pcm.sampleRate || $0.channels != channels }) ?? true {
            format = (pcm.sampleRate, channels)
            filters = (0..<channels).map { _ in HighPass(cutoff: 100, sampleRate: pcm.sampleRate) }
            suppressors = (0..<channels).map { _ in NoiseSuppressor(sampleRate: pcm.sampleRate, reductionDB: reductionDB) }
        }
        let frames = pcm.samples.count / channels
        var cleaned: [[Float]] = []
        for c in 0..<channels {
            var channel = [Float](repeating: 0, count: frames)
            for i in 0..<frames { channel[i] = filters[c].process(pcm.samples[i * channels + c]) }
            cleaned.append(suppressors[c].process(channel))
        }
        let out = cleaned[0].count
        var samples = [Float](repeating: 0, count: out * channels)
        for c in 0..<channels {
            for i in 0..<out { samples[i * channels + c] = cleaned[c][i] }
        }
        return AudioDecoder.PCM(samples: samples, channels: channels, sampleRate: pcm.sampleRate)
    }
}

/// RBJ cookbook shelving filter (slope 1).
struct Shelf {
    private let b0, b1, b2, a1, a2: Float
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    init(low: Bool, hz: Double, gainDB: Float, rate: Double) {
        let A = pow(10, Double(gainDB) / 40)
        let w = 2 * Double.pi * hz / rate
        let alpha = sin(w) / 2 * sqrt(2.0)
        let c = cos(w), s = 2 * sqrt(A) * alpha
        let (nb0, nb1, nb2, na0, na1, na2): (Double, Double, Double, Double, Double, Double) = low
            ? (A * ((A + 1) - (A - 1) * c + s), 2 * A * ((A - 1) - (A + 1) * c), A * ((A + 1) - (A - 1) * c - s),
               (A + 1) + (A - 1) * c + s, -2 * ((A - 1) + (A + 1) * c), (A + 1) + (A - 1) * c - s)
            : (A * ((A + 1) + (A - 1) * c + s), -2 * A * ((A - 1) + (A + 1) * c), A * ((A + 1) + (A - 1) * c - s),
               (A + 1) - (A - 1) * c + s, 2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - s)
        b0 = Float(nb0 / na0); b1 = Float(nb1 / na0); b2 = Float(nb2 / na0)
        a1 = Float(na1 / na0); a2 = Float(na2 / na0)
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }
}

/// Second-order high-pass (RBJ cookbook, Butterworth Q): takes out rumble and hum below
/// the cutoff, which only eats into the headroom the boost needs.
struct HighPass {
    private let b0, b1, b2, a1, a2: Float
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    init(cutoff: Double, sampleRate: Double) {
        let w = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w) / (2 * 0.7071)
        let a0 = 1 + alpha
        b0 = Float((1 + cos(w)) / 2 / a0)
        b1 = Float(-(1 + cos(w)) / a0)
        b2 = b0
        a1 = Float(-2 * cos(w) / a0)
        a2 = Float((1 - alpha) / a0)
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }
}

/// Turns steady background noise down while keeping sounds that come and go.
///
/// The sound is cut into 32 ms frames, overlapping by half. In each frequency band the noise is
/// the quietest that band has been over the last few seconds (minimum statistics), so a crying
/// baby, who has to breathe, is never mistaken for noise. Each band is then turned down by how
/// little it rises above that noise, with a decision-directed Wiener gain, which avoids the
/// warbling "musical noise" of plain spectral subtraction.
final class NoiseSuppressor {
    /// Seconds of sound the noise estimate looks back over.
    private static let memory = 4.0
    /// Sub-windows the look-back is kept in, so an old minimum ages out in steps.
    private static let windows = 8
    /// The minimum of a noisy spectrum sits below its average; this lifts it back.
    private static let bias: Float = 2.5
    /// How much the previous frame's clean estimate steers the gain (the "decision-directed" weight).
    private static let carry: Float = 0.98

    private let size: Int
    private let hop: Int
    private let bins: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private let minGain: Float
    private let scale: Float

    private var input: [Float]
    private var filled = 0
    private var accumulator: [Float]
    private let frame: UnsafeMutablePointer<Float>
    private let re: UnsafeMutablePointer<Float>
    private let im: UnsafeMutablePointer<Float>

    /// Neighbouring bands each side whose gains are blended in.
    private static let spread = 3
    /// How slowly a band's gain falls back after rising (per frame).
    private static let fade: Float = 0.7

    private var fading: [Float]
    private var power: [Float]
    private var smoothed: [Float]
    private var noise: [Float]
    private var clean: [Float]
    private var minimum: [Float]
    private var minima: [Float]
    private var minimaFilled = 0
    private var minimaNext = 0
    private var framesPerWindow: Int
    private var framesInWindow = 0
    /// Frames averaged into the first noise estimate, and how many so far.
    private let warmup: Int
    private var warmed = 0

    init(sampleRate: Double, reductionDB: Float) {
        // About 32 ms: 256 samples at 8 kHz, 512 at 16 kHz, 1024 at 32 kHz.
        let bits = max(6, Int(log2(sampleRate * 0.032).rounded()))
        let size = 1 << bits
        self.size = size
        hop = size / 2
        bins = size / 2 + 1
        log2n = vDSP_Length(bits)
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        // Periodic sqrt-Hann for analysis and synthesis: the two multiply to a Hann window,
        // which sums to exactly 1 at half overlap.
        window = (0..<size).map { sqrtf(0.5 - 0.5 * cosf(2 * .pi * Float($0) / Float(size))) }
        minGain = powf(10, -max(reductionDB, 0) / 20)
        // vDSP's real FFT scales by 2 going forward and by n coming back.
        scale = 1 / Float(2 * size)

        input = [Float](repeating: 0, count: size)
        accumulator = [Float](repeating: 0, count: size)
        frame = .allocate(capacity: size)
        re = .allocate(capacity: size / 2)
        im = .allocate(capacity: size / 2)

        power = [Float](repeating: 0, count: bins)
        fading = [Float](repeating: 1, count: bins)
        smoothed = power
        noise = power
        clean = power
        minimum = [Float](repeating: .greatestFiniteMagnitude, count: bins)
        minima = [Float](repeating: .greatestFiniteMagnitude, count: bins * Self.windows)
        let framesPerSecond = sampleRate / Double(size / 2)
        framesPerWindow = max(1, Int(Self.memory * framesPerSecond) / Self.windows)
        warmup = max(1, Int(0.5 * framesPerSecond))
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        frame.deallocate()
        re.deallocate()
        im.deallocate()
    }

    /// Samples in, cleaned samples out, `size - hop` samples behind.
    func process(_ samples: [Float]) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(samples.count + hop)
        for x in samples {
            input[filled] = x
            filled += 1
            guard filled == size else { continue }
            processFrame()
            out.append(contentsOf: accumulator[0..<hop])
            accumulator.replaceSubrange(0..<size, with: accumulator[hop...] + repeatElement(0, count: hop))
            input.replaceSubrange(0..<size, with: input[hop...] + repeatElement(0, count: hop))
            filled = size - hop
        }
        return out
    }

    private func processFrame() {
        for i in 0..<size { frame[i] = input[i] * window[i] }
        var split = DSPSplitComplex(realp: re, imagp: im)
        frame.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

        // Packed: DC in re[0], Nyquist in im[0].
        power[0] = re[0] * re[0]
        power[bins - 1] = im[0] * im[0]
        for k in 1..<(bins - 1) { power[k] = re[k] * re[k] + im[k] * im[k] }

        trackNoise()

        var gains = [Float](repeating: 1, count: bins)
        for k in 0..<bins {
            let n = max(noise[k], 1e-12)
            let posterior = power[k] / n
            let prior = Self.carry * clean[k] / n + (1 - Self.carry) * max(posterior - 1, 0)
            let g = max(prior / (1 + prior), minGain)
            gains[k] = g
            clean[k] = g * g * power[k]
        }
        // Bands switching up and down on their own is what sounds metallic ("musical noise"):
        // blend each band's gain with its neighbours', and let gains fall back only gradually.
        var blended = gains
        for k in 0..<bins {
            var sum: Float = 0, weight: Float = 0
            for j in max(0, k - Self.spread)...min(bins - 1, k + Self.spread) {
                let w = Float(Self.spread + 1 - abs(j - k))
                sum += w * gains[j]
                weight += w
            }
            blended[k] = sum / weight
        }
        for k in 0..<bins {
            fading[k] = Self.fade * fading[k] + (1 - Self.fade) * blended[k]
            gains[k] = max(blended[k], fading[k])
        }
        re[0] *= gains[0]
        im[0] *= gains[bins - 1]
        for k in 1..<(bins - 1) {
            re[k] *= gains[k]
            im[k] *= gains[k]
        }

        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
        frame.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
            vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(size / 2))
        }
        for i in 0..<size { accumulator[i] += frame[i] * window[i] * scale }
    }

    /// Minimum statistics: a smoothed spectrum, and its minimum over the last `memory` seconds.
    ///
    /// The first half second is averaged instead. A single frame's spectrum is ragged (any band
    /// can dip far below its noise), and a minimum taken from it would hold the noise estimate
    /// far too low for the whole look-back, letting most of the noise through for seconds after
    /// every connect.
    private func trackNoise() {
        if warmed < warmup {
            warmed += 1
            for k in 0..<bins {
                smoothed[k] += (power[k] - smoothed[k]) / Float(warmed)
                noise[k] = smoothed[k]
            }
            if warmed == warmup { minimum = smoothed }
            return
        }
        for k in 0..<bins {
            smoothed[k] = 0.8 * smoothed[k] + 0.2 * power[k]
            minimum[k] = min(minimum[k], smoothed[k])
        }
        framesInWindow += 1
        if framesInWindow == framesPerWindow {
            let base = minimaNext * bins
            for k in 0..<bins { minima[base + k] = minimum[k] }
            minimaNext = (minimaNext + 1) % Self.windows
            minimaFilled = min(minimaFilled + 1, Self.windows)
            minimum = smoothed
            framesInWindow = 0
        }
        for k in 0..<bins {
            var lowest = minimum[k]
            for w in 0..<minimaFilled { lowest = min(lowest, minima[w * bins + k]) }
            noise[k] = Self.bias * lowest
        }
    }
}

/// Raises quiet sounds by `makeupDB` and loud ones by less: above `threshold`, every `ratio` dB
/// louder in is only 1 dB louder out.
///
/// What's left of the background after noise reduction isn't raised: sound within a few dB of
/// the quietest the room has been recently gets up to `expansion` dB less boost (a downward
/// expander), so the room stays as quiet as the camera hears it while sounds come up clearly.
struct Compressor {
    let makeupDB: Float
    private let threshold: Float
    private let ratio: Float
    private let knee: Float = 10
    /// Boost held back from the background, and how far above it sound gets the full boost.
    private let expansion: Float = 30
    private let closed: Float = 4, open: Float = 10
    private var envelope: Float = 0
    /// A slower envelope (20 ms attack, 800 ms release) that decides how much boost to hold back.
    /// Steady noise barely moves it, so the background doesn't pump; a sound lifts it at once.
    private var steady: Float = 0
    /// The room's background level after noise reduction, in dBFS: follows `steady` down within
    /// a second, and up by only 0.5 dB a second so a long cry doesn't become the new background.
    private var floor: Float?
    /// Samples left in the first second, when the background just follows `steady`: sound
    /// fades in from silence as noise reduction starts, and starting low would leave the
    /// background rising for many seconds.
    private var settling: Int?
    private var coefficients: (rate: Double, attack: Float, release: Float,
                               steadyAttack: Float, steadyRelease: Float, fall: Float, rise: Float)?

    init(makeupDB: Float, thresholdDB: Float, ratio: Float) {
        self.makeupDB = makeupDB
        threshold = thresholdDB
        self.ratio = ratio
    }

    mutating func process(_ pcm: inout AudioDecoder.PCM) {
        if coefficients?.rate != pcm.sampleRate {
            // 10 ms attack, 300 ms release.
            let rate = Float(pcm.sampleRate)
            coefficients = (pcm.sampleRate, expf(-1 / (0.010 * rate)), expf(-1 / (0.300 * rate)),
                            expf(-1 / (0.020 * rate)), expf(-1 / (0.800 * rate)),
                            1 - expf(-1 / (1.0 * rate)), 0.5 / rate)
        }
        guard let (_, attack, release, steadyAttack, steadyRelease, fall, rise) = coefficients else { return }
        let channels = pcm.channels
        // Start from the first buffer's level, not silence.
        if floor == nil, !pcm.samples.isEmpty {
            envelope = pcm.meanSquare
            steady = envelope
            floor = 10 * log10f(envelope + 1e-12)
            settling = Int(pcm.sampleRate)
        }
        var i = 0
        while i < pcm.samples.count {
            var square: Float = 0
            for c in 0..<channels { square += pcm.samples[i + c] * pcm.samples[i + c] }
            square /= Float(channels)
            let a = square > envelope ? attack : release
            envelope = a * envelope + (1 - a) * square
            let s = square > steady ? steadyAttack : steadyRelease
            steady = s * steady + (1 - s) * square
            let level = 10 * log10f(envelope + 1e-12)
            let steadyLevel = 10 * log10f(steady + 1e-12)
            var background = floor ?? steadyLevel
            if let left = settling, left > 0 {
                background = steadyLevel
                settling = left - 1
            } else {
                background = steadyLevel < background ? background + (steadyLevel - background) * fall : background + rise
            }
            floor = background
            let gain = powf(10, (makeupDB + reduction(level) - heldBack(steadyLevel - background)) / 20)
            for c in 0..<channels { pcm.samples[i + c] *= gain }
            i += channels
        }
    }

    /// Boost held back from sound `over` dB above the background; never more than the boost,
    /// so the room is never made quieter than the camera hears it.
    private func heldBack(_ over: Float) -> Float {
        let most = min(expansion, makeupDB)
        if over >= open { return 0 }
        if over <= closed { return most }
        return most * (open - over) / (open - closed)
    }

    /// Gain change in dB for a level, with a soft knee.
    private func reduction(_ level: Float) -> Float {
        let over = level - threshold
        let slope = 1 / ratio - 1
        if 2 * over < -knee { return 0 }
        if 2 * over > knee { return slope * over }
        let x = over + knee / 2
        return slope * x * x / (2 * knee)
    }
}

/// Holds peaks under -1 dBFS: instant attack, 150 ms release.
struct Limiter {
    private let ceiling: Float = 0.89
    private var envelope: Float = 0

    mutating func process(_ pcm: inout AudioDecoder.PCM) {
        let release = expf(-1 / (0.15 * Float(pcm.sampleRate) * Float(pcm.channels)))
        for i in pcm.samples.indices {
            let y = pcm.samples[i]
            envelope = max(abs(y), envelope * release)
            if envelope > ceiling { pcm.samples[i] = y * ceiling / envelope }
        }
    }
}
