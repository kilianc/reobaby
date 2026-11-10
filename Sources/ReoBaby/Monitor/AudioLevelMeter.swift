import AVFoundation
import CoreMedia

/// Measures how loud camera audio is, after the same noise reduction as listening, so a sound
/// stands out against what's left of the background rather than against a fan or white noise.
final class AudioLevelMeter {
    private let decoder = AudioDecoder()
    private let cleaner = NoiseCleaner()
    private var reducesNoise = false
    private var revision = -1

    init() {
        applySettings()
    }

    private func applySettings() {
        revision = SoundSettings.revision
        let reduction = Float(max(SoundSettings.detectionReductionDB, 0))
        if reduction > 0 && !reducesNoise { cleaner.reset(reductionDB: reduction) }
        cleaner.reductionDB = reduction
        reducesNoise = reduction > 0
    }

    /// RMS level of the buffer in dBFS (0 = full scale, silence ≈ -100), or nil if undecodable
    /// or still filling the noise reduction.
    func level(of sample: CMSampleBuffer) -> Float? {
        decoder.decode(sample).flatMap(level)
    }

    func level(of pcm: AudioDecoder.PCM) -> Float? {
        if revision != SoundSettings.revision { applySettings() }
        let cleaned = reducesNoise ? cleaner.clean(pcm) : pcm
        return cleaned.samples.isEmpty ? nil : Self.decibels(cleaned.meanSquare)
    }

    static func decibels(_ meanSquare: Float) -> Float {
        10 * log10(max(meanSquare, 1e-10))
    }
}

/// Flags sounds that stand out from the room's background noise.
struct SoundDetector {
    /// How far above the background a sound must be.
    var thresholdDB: Float = 15
    /// Ignore anything quieter than this, however quiet the room.
    var absoluteFloorDB: Float = -50
    /// Loud audio needed within the last second to count as an event.
    var requiredLoudSeconds: Double = 0.4

    private(set) var noiseFloor: Float?
    private var loud: [(time: CFAbsoluteTime, duration: Double)] = []

    /// Feeds one buffer's level; returns true when a sound event starts.
    mutating func feed(level: Float, duration: Double, at time: CFAbsoluteTime) -> Bool {
        guard let floor = noiseFloor else {
            noiseFloor = level
            return false
        }
        let isLoud = level > max(floor + thresholdDB, absoluteFloorDB)
        // Track the background: adapt quickly downward, slowly upward, barely while loud.
        let rate: Float = level < floor ? 0.05 : (isLoud ? 0.0005 : 0.005)
        noiseFloor = floor + (level - floor) * rate

        if isLoud { loud.append((time, duration)) }
        loud.removeAll { time - $0.time > 1 }
        return loud.reduce(0) { $0 + $1.duration } >= requiredLoudSeconds
    }

    mutating func reset() {
        loud.removeAll()
    }

    /// Forgets the background, to learn it again from what comes next.
    mutating func relearn() {
        noiseFloor = nil
        loud.removeAll()
    }

    /// While the background is changing, follows it closely, up or down.
    mutating func relearn(level: Float) {
        noiseFloor = noiseFloor.map { $0 + (level - $0) * 0.1 } ?? level
        loud.removeAll()
    }
}
