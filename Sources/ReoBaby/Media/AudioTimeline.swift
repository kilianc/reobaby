import CoreMedia
import Foundation

/// Keeps camera sound seamless and in step with the picture.
///
/// Cameras stamp audio with when they captured it, give or take tens of milliseconds
/// (Reolinks by up to ±60 ms per 64 ms buffer). Played as stamped, that opens gaps and
/// overlaps, and the sound comes out choppy. So each buffer follows on from the last, and
/// the difference from the stamps is averaged over about a second, which evens out the
/// jitter. When the picture moves (the player shifts its clock to ride out late video), the
/// average moves with it, and the sound catches up by lengthening or shortening quiet moments
/// a few milliseconds at a time. Only when a buffer would arrive too late to play, or sound
/// and picture are more than a second apart, does the sound jump to the stamps.
struct AudioTimeline {
    /// Corrections start when sound and picture are this far apart, and stop this close.
    static let start = 0.020, done = 0.005

    /// How far behind arrival time playback runs: a buffer stamped t plays at host time
    /// t + latency (see `RendererSink.start`).
    let latency: Double
    /// Where the next buffer starts.
    private var next: CMTime?
    /// Stamped minus played time, averaged over about a second; above 0 while the sound plays
    /// ahead of the picture.
    private var offset = 0.0
    private var correcting = false
    /// Frames added minus frames removed since the last jump, in seconds.
    private var net = 0.0

    /// For `--probe`.
    struct Stats {
        var seconds = 0.0, resyncs = 0, splices = 0, spliced = 0.0
        /// How far apart sound and picture were, and would have been without the splices.
        var apartSum = 0.0, worstApart = 0.0, apartSeconds = 0.0, worstUncorrected = 0.0
    }
    private(set) var stats = Stats()

    init(latency: Double) {
        self.latency = latency
    }

    mutating func reset() {
        next = nil
        offset = 0
        correcting = false
        net = 0
    }

    /// Where a buffer of `frames` frames, stamped `stamped`, starts playing. `splice` is handed
    /// how many frames to add (above 0) or remove (below 0) to catch up with the picture, and
    /// returns how many it did.
    mutating func place(stamped: CMTime, frames: Int, rate: Double, now: CMTime = hostNow(),
                        splice: (Int) -> Int) -> CMTime {
        let seconds = Double(frames) / rate
        var start = stamped
        if let next, (next - now).seconds + latency > 0.03, abs((stamped - next).seconds) < 1 {
            start = next
            offset += ((stamped - next).seconds - offset) * (1 - exp(-seconds))
        } else {
            if next != nil { stats.resyncs += 1 }
            offset = 0
            net = 0
            correcting = false
        }

        stats.seconds += seconds
        stats.apartSum += abs(offset) * seconds
        stats.worstApart = max(stats.worstApart, abs(offset))
        stats.worstUncorrected = max(stats.worstUncorrected, abs(offset + net))
        if abs(offset) > 0.045 { stats.apartSeconds += seconds }

        if abs(offset) > Self.start { correcting = true } else if abs(offset) < Self.done { correcting = false }
        var moved = 0
        if correcting {
            moved = splice(Int((offset * rate).rounded()))
            if moved != 0 {
                offset -= Double(moved) / rate
                net += Double(moved) / rate
                stats.splices += 1
                stats.spliced += abs(Double(moved)) / rate
            }
        }
        next = start + CMTime(value: Int64(frames + moved), timescale: CMTimeScale(rate))
        return start
    }
}

enum Splice {
    /// Lengthens (`wanted` above 0) or shortens interleaved sound by about `wanted` frames
    /// (overshooting by no more than `AudioTimeline.done`), between 2.5 and 16 ms, mid-buffer.
    /// It looks for the distance at which the sound best repeats itself (a pitch period in a
    /// voice; noise matches anywhere about as well) and crossfades over 8 ms across it, so
    /// there's no click and no hole. Returns the frames added or removed, 0 when the buffer is
    /// too short.
    static func apply(_ pcm: inout AudioDecoder.PCM, wanted: Int) -> Int {
        let channels = pcm.channels
        let frames = pcm.samples.count / channels
        let fade = Int(0.008 * pcm.sampleRate)
        let start = (frames - fade) / 2
        let shortest = Int(0.0025 * pcm.sampleRate)
        let longest = min(Int(0.016 * pcm.sampleRate), abs(wanted) + Int(AudioTimeline.done * pcm.sampleRate), start)
        guard fade > 0, shortest > 0, longest >= shortest else { return 0 }

        var mono = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            for c in 0..<channels { mono[i] += pcm.samples[i * channels + c] }
        }
        // To add, the crossfade jumps back to an earlier copy of the sound; to remove, ahead.
        let direction = wanted > 0 ? -1 : 1
        var energy: Float = 0
        for i in start..<start + fade { energy += mono[i] * mono[i] }
        var best = (distance: shortest, correlation: -Float.infinity)
        for distance in shortest...longest {
            let from = start + direction * distance
            var dot: Float = 0, other: Float = 0
            for i in 0..<fade {
                dot += mono[start + i] * mono[from + i]
                other += mono[from + i] * mono[from + i]
            }
            let correlation = dot / (energy * other + 1e-20).squareRoot()
            if correlation > best.correlation { best = (distance, correlation) }
        }

        let from = start + direction * best.distance
        var out: [Float] = []
        out.reserveCapacity((frames + best.distance) * channels)
        out.append(contentsOf: pcm.samples[0..<start * channels])
        // Copies that match add up like one sound: fade linearly. Ones that don't (noise) add
        // up by power: fade along a quarter circle so the level doesn't dip.
        let matched = best.correlation > 0.5
        for i in 0..<fade {
            let t = (Float(i) + 0.5) / Float(fade)
            let out0 = matched ? 1 - t : cosf(t * .pi / 2)
            let in1 = matched ? t : sinf(t * .pi / 2)
            for c in 0..<channels {
                out.append(out0 * pcm.samples[(start + i) * channels + c] + in1 * pcm.samples[(from + i) * channels + c])
            }
        }
        out.append(contentsOf: pcm.samples[(from + fade) * channels..<frames * channels])
        pcm.samples = out
        return -direction * best.distance
    }
}
