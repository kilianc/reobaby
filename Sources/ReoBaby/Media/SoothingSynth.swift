import Foundation
import os

/// What Soothing Sounds plays, from Settings ▸ Soothing. Every setting is a user default.
struct SoothingSettings: Equatable {
    enum Noise: String, CaseIterable, Identifiable {
        case white, pink, brown

        var id: String { rawValue }

        var title: String {
            switch self {
            case .white: "White"
            case .pink: "Pink"
            case .brown: "Brown"
            }
        }
    }

    var noise: Noise = .pink
    /// 0...1; see `gain`.
    var volume = 0.5
    /// 0...1: how much of the treble a low-pass filter takes away.
    var warmth = 0.65
    var heartbeat = false
    /// Beats per minute.
    var heartRate = 70.0
    /// 0...1: how loud the heartbeat is against the noise; see `layerGain`.
    var heartLevel = 0.5
    var shushing = false
    /// 0...1: how loud the shush is against the noise.
    var shushLevel = 0.5
    var waves = false
    /// 0...1: how far the noise swells and falls.
    var wavesLevel = 0.5

    static let defaults = SoothingSettings()

    static var current: SoothingSettings {
        let d = UserDefaults.standard
        func double(_ key: String, _ fallback: Double) -> Double { d.object(forKey: key) == nil ? fallback : d.double(forKey: key) }
        func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) == nil ? fallback : d.bool(forKey: key) }
        let base = defaults
        return SoothingSettings(
            noise: d.string(forKey: "sootheNoise").flatMap(Noise.init) ?? base.noise,
            volume: double("sootheVolume", base.volume),
            warmth: double("sootheWarmth", base.warmth),
            heartbeat: bool("sootheHeartbeat", base.heartbeat),
            heartRate: double("sootheHeartRate", base.heartRate),
            heartLevel: double("sootheHeartLevel", base.heartLevel),
            shushing: bool("sootheShushing", base.shushing),
            shushLevel: double("sootheShushLevel", base.shushLevel),
            waves: bool("sootheWaves", base.waves),
            wavesLevel: double("sootheWavesLevel", base.wavesLevel))
    }

    /// Volume as a gain: 0 is silent, and the rest of the slider spans 40 dB, so each step
    /// sounds about as big as the last.
    var gain: Float { volume <= 0.001 ? 0 : Float(pow(10, -40 * (1 - volume) / 20)) }

    /// A layer's level as a gain: none at 0, as it was designed at a half, four times that
    /// (12 dB more) at 1.
    static func layerGain(_ level: Float) -> Float { 4 * level * level }

    /// The low-pass cutoff: 12 kHz (as good as none) at 0, 300 Hz at 1.
    var cutoff: Double { 12000 * pow(300 / 12000, warmth) }
}

/// Synthesises soothing sounds: a bed of white, pink or brown noise, warmed by a low-pass
/// filter, with optional layers of a heartbeat, rhythmic shushing and slow ocean-like swells.
/// Everything is made here from random numbers and maths: no recordings.
///
/// Nothing changes abruptly, so nothing startles a sleeping baby: a new colour crossfades with
/// the old, layers fade in, out and to a new level, and volume ramps, each over 10 seconds;
/// warmth glides.
///
/// `render` runs on an audio thread, so settings and fades are handed over through a lock it
/// never waits for.
final class SoothingSynth {
    let sampleRate: Double

    /// How long a change of colour or layer takes, as long as a fade.
    static let changeSeconds = 10.0
    /// How long a change takes here: `changeSeconds`, or quicker for a preview on this Mac.
    let changeSeconds: Double

    private struct Control {
        var settings = SoothingSettings.current
        var revision = 0
        /// Where the fade envelope is heading, and how fast (per sample).
        var fadeTarget: Float = 0
        var fadeStep: Float = 1
    }

    private let control = OSAllocatedUnfairLock(initialState: Control())
    private var seen = -1

    // State owned by the render thread.
    private var settings = SoothingSettings.current
    private var random = Random()
    private var pink = PinkNoise()
    private var brown: Float = 0
    private var brownPole: Float
    /// Each colour's share of the bed, 0...1, crossfading; and its calibrated gain.
    private var colourMix: [Float] = [0, 0, 0]
    private var colourGain: [Float] = [1, 1, 1]
    private var colourGainTarget: [Float] = [1, 1, 1]
    private var warm = Biquad()
    private var cutoff: Double
    private var highPass: Biquad
    private var volume: Float = 0
    private var fade: Float = 0
    private var fadeTarget: Float = 0
    private var fadeStep: Float = 1
    private var time = 0.0
    private var heartbeat = Heartbeat()
    private var shushFilter = Biquad()
    /// Each layer's level, 0...1 as its slider has it and 0 while it's off, gliding.
    private var heartLevel = Glide()
    private var shushLevel = Glide()
    private var wavesLevel = Glide()
    private var limiter: Float = 1
    /// Per-sample steps and followers that keep every change smooth.
    private let changeStep: Float
    /// Volume, in decibels, ramps evenly to a new setting over `changeSeconds`.
    private var volumeDB: Float = -80
    private var volumeTargetDB: Float = -80
    private var volumeStepDB: Float = 0
    private let gainSmoothing: Float
    private let cutoffSmoothing: Double
    private var sinceFilterUpdate = 0

    /// `lowestFrequency`: what the speaker can play; lower sound is filtered out instead of
    /// wasting its power (a camera's tiny speaker starts around 150 Hz).
    init(sampleRate: Double, lowestFrequency: Double, changeSeconds: Double = SoothingSynth.changeSeconds) {
        self.sampleRate = sampleRate
        self.changeSeconds = changeSeconds
        brownPole = Float(exp(-2 * Double.pi * 8 / sampleRate))
        highPass = Biquad.highPass(frequency: lowestFrequency, q: 0.707, rate: sampleRate)
        shushFilter = Biquad.bandPass(frequency: min(2200, sampleRate * 0.33), q: 1.1, rate: sampleRate)
        changeStep = Float(1 / (changeSeconds * sampleRate))
        gainSmoothing = Float(1 - exp(-1 / (1.5 * sampleRate)))
        cutoffSmoothing = 1 - exp(-32 / (1.5 * sampleRate))
        let start = SoothingSettings.current
        cutoff = Self.clamped(start.cutoff, rate: sampleRate)
        warm = Biquad.lowPass(frequency: cutoff, q: 0.707, rate: sampleRate)
        settings = start
        // The first settings start where they are, not crossfading from nothing: the fade-in
        // takes care of the start.
        colourMix[Self.index(start.noise)] = 1
        heartLevel = Glide(start.heartbeat ? Float(start.heartLevel) : 0)
        shushLevel = Glide(start.shushing ? Float(start.shushLevel) : 0)
        wavesLevel = Glide(start.waves ? Float(start.wavesLevel) : 0)
        recalibrate()
        colourGain = colourGainTarget
        volumeTargetDB = Self.decibels(start.gain)
        volumeDB = volumeTargetDB
        volume = start.gain
    }

    /// New settings take effect smoothly, over a couple of seconds.
    func update(_ settings: SoothingSettings) {
        control.withLock {
            if $0.settings != settings {
                $0.settings = settings
                $0.revision += 1
            }
        }
    }

    /// Fades to `level` (0...1) over `seconds`.
    func fade(to level: Float, over seconds: Double) {
        let step = Float(1 / max(seconds * sampleRate, 1))
        control.withLock {
            $0.fadeTarget = level
            $0.fadeStep = step
            $0.revision += 1
        }
    }

    /// Fills `buffer` with the next mono samples.
    func render(_ buffer: UnsafeMutableBufferPointer<Float>) {
        if let new = control.withLockIfAvailable({ $0 }), new.revision != seen {
            seen = new.revision
            fadeTarget = new.fadeTarget
            fadeStep = new.fadeStep
            if new.settings != settings { apply(new.settings) }
        }
        let dt = 1 / sampleRate
        let targetDB = Self.decibels(settings.gain)
        if targetDB != volumeTargetDB {
            volumeTargetDB = targetDB
            volumeStepDB = abs(targetDB - volumeDB) / Float(changeSeconds * sampleRate)
        }
        let selected = Self.index(settings.noise)
        let targetCutoff = Self.clamped(settings.cutoff, rate: sampleRate)
        let changeSamples = Float(changeSeconds * sampleRate)
        heartLevel.aim(settings.heartbeat ? Float(settings.heartLevel) : 0, samples: changeSamples)
        shushLevel.aim(settings.shushing ? Float(settings.shushLevel) : 0, samples: changeSamples)
        wavesLevel.aim(settings.waves ? Float(settings.wavesLevel) : 0, samples: changeSamples)
        for i in buffer.indices {
            if volumeDB != volumeTargetDB {
                volumeDB = Self.toward(volumeDB, volumeTargetDB, step: volumeStepDB)
                volume = volumeDB <= -79.9 ? 0 : Float(pow(10, Double(volumeDB) / 20))
            }
            if fade < fadeTarget { fade = min(fadeTarget, fade + fadeStep) } else if fade > fadeTarget { fade = max(fadeTarget, fade - fadeStep) }
            let heart = SoothingSettings.layerGain(heartLevel.next())
            let shush = SoothingSettings.layerGain(shushLevel.next())
            // Waves at a half swell as designed; at 1, twice as far in decibels.
            let waves = wavesLevel.next() * 2

            // Warmth glides: the filter follows its new cutoff a little at a time.
            sinceFilterUpdate += 1
            if sinceFilterUpdate >= 32 {
                sinceFilterUpdate = 0
                if abs(cutoff - targetCutoff) > 0.5 {
                    cutoff = exp(log(cutoff) + (log(targetCutoff) - log(cutoff)) * cutoffSmoothing)
                    warm.setCoefficients(from: Biquad.lowPass(frequency: cutoff, q: 0.707, rate: sampleRate))
                }
            }

            // The bed: one colour, or two crossfading at equal power.
            var bed: Float = 0
            let w = random.white()
            let p = pink.next(w, random: &random)
            brown = brownPole * brown + (1 - brownPole) * w
            for c in 0..<3 {
                colourMix[c] = Self.toward(colourMix[c], c == selected ? 1 : 0, step: changeStep)
                colourGain[c] += (colourGainTarget[c] - colourGain[c]) * gainSmoothing
                guard colourMix[c] > 0 else { continue }
                let x: Float = c == 0 ? w : c == 1 ? p : brown
                bed += x * colourGain[c] * Float(sin(Double(colourMix[c]) * .pi / 2))
            }
            bed = warm.process(bed)
            if waves > 0 { bed *= powf(Self.swell(time), waves) }

            var out = bed
            if heart > 0 {
                let (thump, pulse) = heartbeat.next(time: time, rate: settings.heartRate, random: &random)
                // In the womb the heartbeat comes with a whoosh of blood: the bed swells with it.
                out = out * (1 + min(heart, 1) * (-0.18 + 0.3 * pulse)) + thump * 0.30 * heart
            }
            if shush > 0 {
                // The bed steps back a little, and the shush sits just above it: a shush is where
                // ears and small speakers are most sensitive, so it needs less level than it seems.
                out = out * (1 - 0.3 * min(shush, 1)) + shushFilter.process(random.white()) * Self.shush(time) * 0.195 * shush
            }
            out = highPass.process(out)

            // An equal-power fade: smooth at both ends, as a sound machine dims.
            let level = fade * fade * (3 - 2 * fade)
            var sample = out * volume * level
            // A gentle limiter keeps peaks under full scale, so nothing ever crackles.
            let peak = abs(sample)
            if peak * limiter > 0.89 { limiter = 0.89 / peak } else { limiter += (1 - limiter) * 0.0005 }
            sample *= limiter
            buffer[i] = sample
            time += dt
        }
        if time > 86400 { time -= 86400 } // stay precise all night, and the next
    }

    /// Whether the fade has finished at silence: then the output can stop.
    var isSilent: Bool { control.withLock { $0.fadeTarget == 0 } && fade == 0 }

    // MARK: - Sound

    private static func index(_ noise: SoothingSettings.Noise) -> Int {
        switch noise {
        case .white: 0
        case .pink: 1
        case .brown: 2
        }
    }

    private static func decibels(_ gain: Float) -> Float { gain > 0 ? max(-80, 20 * log10(gain)) : -80 }

    private static func toward(_ value: Float, _ target: Float, step: Float) -> Float {
        value < target ? min(target, value + step) : max(target, value - step)
    }

    /// The warmth filter's cutoff, kept where a filter at this rate can follow it.
    private static func clamped(_ cutoff: Double, rate: Double) -> Double {
        min(max(cutoff, 40), rate * 0.45)
    }

    private func apply(_ new: SoothingSettings) {
        let recalibrate = new.noise != settings.noise || new.warmth != settings.warmth
        settings = new
        if recalibrate { self.recalibrate() }
    }

    /// Each colour's gain at the new warmth.
    private func recalibrate() {
        let filter = Biquad.lowPass(frequency: Self.clamped(settings.cutoff, rate: sampleRate), q: 0.707, rate: sampleRate)
        for c in 0..<3 where c == Self.index(settings.noise) || colourMix[c] > 0 {
            colourGainTarget[c] = calibrate(colour: c, filter: filter)
        }
    }

    /// The gain that brings a colour, as the speaker plays it, to -11 dBFS RMS at full volume,
    /// so every colour and warmth is about as loud. A camera's speaker is small: it takes most of
    /// full scale to fill a nursery.
    private func calibrate(colour: Int, filter: Biquad) -> Float {
        var rng = Random(seed: 7)
        var p = PinkNoise()
        var b: Float = 0
        var lp = filter, hp = highPass
        lp.reset(); hp.reset()
        var sum: Double = 0
        let count = Int(sampleRate * 0.6)
        let skip = Int(sampleRate * 0.1)
        for n in 0..<count {
            let w = rng.white()
            var x: Float
            switch colour {
            case 0: x = w
            case 1: x = p.next(w, random: &rng)
            default:
                b = brownPole * b + (1 - brownPole) * w
                x = b
            }
            x = hp.process(lp.process(x))
            if n >= skip { sum += Double(x * x) }
        }
        let rms = sqrt(sum / Double(count - skip))
        return rms > 1e-9 ? Float(0.28 / rms) : 1
    }

    /// Slow swells, like waves on a beach: about every 9 seconds, never quite silent.
    private static func swell(_ t: Double) -> Float {
        let a = sin(2 * Double.pi * t / 9.3)
        let b = sin(2 * Double.pi * t / 13.7 + 1.3)
        let shape = 0.5 + 0.5 * (0.7 * a + 0.3 * b)
        return Float(0.45 + 0.75 * shape * shape)
    }

    /// "Shhh… shhh…": one long shush every 1.8 seconds.
    private static func shush(_ t: Double) -> Float {
        let period = 1.8
        let p = t.truncatingRemainder(dividingBy: period)
        let attack = 0.12, hold = 0.75, release = 0.45
        let env: Double
        if p < attack { env = p / attack }
        else if p < attack + hold { env = 1 - 0.15 * (p - attack) / hold }
        else if p < attack + hold + release { env = 0.85 * (1 - (p - attack - hold) / release) }
        else { env = 0 }
        return Float(env * env)
    }
}

// MARK: - Building blocks

/// A value that reaches each new target in a fixed time, however far it is.
struct Glide {
    private(set) var value: Float
    private var target: Float
    private var step: Float = 0

    init(_ value: Float = 0) {
        self.value = value
        target = value
    }

    /// Heads for `target`, to arrive `samples` from now.
    mutating func aim(_ target: Float, samples: Float) {
        guard target != self.target else { return }
        self.target = target
        step = abs(target - value) / max(samples, 1)
    }

    mutating func next() -> Float {
        if value < target { value = min(target, value + step) } else if value > target { value = max(target, value - step) }
        return value
    }
}

/// xorshift: fast, and plenty random for noise.
struct Random {
    private var state: UInt64

    init(seed: UInt64 = UInt64.random(in: 1...UInt64.max)) { state = seed }

    /// Uniform in -1...1.
    mutating func uniform() -> Float {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Float(Int64(bitPattern: state) >> 40) / Float(1 << 23)
    }

    /// Roughly Gaussian, about unit RMS, as white noise should sound.
    mutating func white() -> Float {
        (uniform() + uniform() + uniform()) * 1.0
    }
}

/// Pink noise (-3 dB per octave) by the Voss–McCartney method: rows of random values, each
/// updated half as often as the one before, summed.
struct PinkNoise {
    private var rows = [Float](repeating: 0, count: 16)
    private var sum: Float = 0
    private var counter: UInt32 = 0

    mutating func next(_ white: Float, random: inout Random) -> Float {
        counter &+= 1
        let row = min(counter.trailingZeroBitCount, rows.count - 1)
        let value = random.white()
        sum += value - rows[row]
        rows[row] = value
        return (sum + white) / 5
    }
}

/// A heart beating "lub-dub": two soft, low thumps a third of a second apart, with a pulse
/// that swells after each.
struct Heartbeat {
    private var phase = 0.0
    private var lastTime = 0.0
    private var lowPass: Float = 0

    mutating func next(time: Double, rate: Double, random: inout Random) -> (thump: Float, pulse: Float) {
        let period = 60 / max(rate, 30)
        phase += (time - lastTime) / period
        lastTime = time
        if phase >= 1 || phase < 0 { phase -= phase.rounded(.down) }
        let t = phase * period
        let gap = min(0.32, period * 0.42)
        var thump = Self.beat(t, pitch: 68) + 0.7 * Self.beat(t - gap, pitch: 78)
        // A little filtered noise gives the thumps body, and lets them through small speakers.
        lowPass += (random.white() - lowPass) * 0.06
        thump += lowPass * (Self.envelope(t, decay: 0.03) + 0.7 * Self.envelope(t - gap, decay: 0.025)) * 0.8
        // The pulse: quick rise after the beat, slow fall.
        let pulse = Float(t < 0.08 ? t / 0.08 : exp(-(t - 0.08) / (period * 0.35)))
        return (thump, pulse)
    }

    private static func envelope(_ t: Double, decay: Double) -> Float {
        guard t >= 0 else { return 0 }
        let attack = 0.012
        return Float(t < attack ? t / attack : exp(-(t - attack) / decay))
    }

    /// One thump: a low tone that drops in pitch as it fades, saturated so its overtones carry.
    private static func beat(_ t: Double, pitch: Double) -> Float {
        guard t >= 0, t < 0.4 else { return 0 }
        let f = pitch * (1 + 0.35 * exp(-t / 0.03))
        let x = sin(2 * Double.pi * f * t)
        return Float(tanh(2.6 * x)) * envelope(t, decay: 0.055) * 2.2
    }
}

/// A second-order filter (RBJ's cookbook).
struct Biquad {
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    static func lowPass(frequency: Double, q: Double, rate: Double) -> Biquad {
        let w = 2 * Double.pi * frequency / rate, alpha = sin(w) / (2 * q), c = cos(w)
        return Biquad(b: [(1 - c) / 2, 1 - c, (1 - c) / 2], a: [1 + alpha, -2 * c, 1 - alpha])
    }

    static func highPass(frequency: Double, q: Double, rate: Double) -> Biquad {
        let w = 2 * Double.pi * frequency / rate, alpha = sin(w) / (2 * q), c = cos(w)
        return Biquad(b: [(1 + c) / 2, -(1 + c), (1 + c) / 2], a: [1 + alpha, -2 * c, 1 - alpha])
    }

    static func bandPass(frequency: Double, q: Double, rate: Double) -> Biquad {
        let w = 2 * Double.pi * frequency / rate, alpha = sin(w) / (2 * q), c = cos(w)
        return Biquad(b: [alpha, 0, -alpha], a: [1 + alpha, -2 * c, 1 - alpha])
    }

    init() {}

    private init(b: [Double], a: [Double]) {
        b0 = Float(b[0] / a[0]); b1 = Float(b[1] / a[0]); b2 = Float(b[2] / a[0])
        a1 = Float(a[1] / a[0]); a2 = Float(a[2] / a[0])
    }

    /// Takes another filter's response, keeping this one's state, so a change doesn't click.
    mutating func setCoefficients(from other: Biquad) {
        b0 = other.b0; b1 = other.b1; b2 = other.b2; a1 = other.a1; a2 = other.a2
    }

    mutating func reset() { x1 = 0; x2 = 0; y1 = 0; y2 = 0 }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }
}
