import Foundation

/// Gets decoded audio into the one shape the analyzer accepts: mono, at a fixed
/// sample rate.
///
/// This lives on the client rather than being asked of the server on purpose.
/// Jellyfin will resample and downmix on request; Plex's universal transcoder
/// takes its output rate from a client profile, and Subsonic has no standard
/// parameter for either. Doing it here means the analyzer's input does not
/// depend on which server a track came from or what that server felt like
/// emitting.
public enum AudioPreparation {
    /// Average the channels.
    ///
    /// Averaging, not left-only: a track with a hard-panned instrument would
    /// otherwise be analyzed with that instrument missing entirely.
    public static func downmix(_ audio: DecodedAudio) -> [Float] {
        guard audio.channels > 1 else { return audio.samples }
        let channels = audio.channels
        let frames = audio.frameCount
        var mono = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(channels)
        for frame in 0..<frames {
            var sum: Float = 0
            let base = frame * channels
            for channel in 0..<channels { sum += audio.samples[base + channel] }
            mono[frame] = sum * scale
        }
        return mono
    }

    /// Windowed-sinc resampling.
    ///
    /// Not linear interpolation: going from 44.1 kHz to 16 kHz throws away
    /// everything above 8 kHz, and without a low-pass first that content folds
    /// back down as aliasing — straight into the spectral centroid, rolloff and
    /// flatness features, which is to say into exactly the numbers this is for.
    /// A sinc kernel cut off at the *output* Nyquist filters and resamples in
    /// one pass.
    public static func resample(_ input: [Float], from inputRate: Int, to outputRate: Int) -> [Float] {
        guard inputRate > 0, outputRate > 0, !input.isEmpty else { return [] }
        guard inputRate != outputRate else { return input }

        // Below 1 when downsampling: it widens the kernel in input samples,
        // which is the low-pass. At or above 1 (upsampling) the kernel stays at
        // the input's own bandwidth and this is pure interpolation.
        let cutoff = Swift.min(1.0, Double(outputRate) / Double(inputRate))
        let halfWidth = Swift.max(4, Int((16.0 / cutoff).rounded(.up)))
        let step = Double(inputRate) / Double(outputRate)
        let outputCount = Int((Double(input.count) / step).rounded(.down))
        guard outputCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: outputCount)
        for n in 0..<outputCount {
            let position = Double(n) * step
            let centre = Int(position.rounded(.down))
            var accumulated = 0.0
            var weightSum = 0.0
            for k in (centre - halfWidth)...(centre + halfWidth) {
                guard k >= 0, k < input.count else { continue }
                let distance = Double(k) - position
                // Blackman window over the kernel's own span, so the taps taper
                // to zero instead of being cut off (which would ring).
                let windowPosition = (distance / Double(halfWidth) + 1) / 2
                guard windowPosition >= 0, windowPosition <= 1 else { continue }
                let window = 0.42
                    - 0.5 * cos(2 * Double.pi * windowPosition)
                    + 0.08 * cos(4 * Double.pi * windowPosition)
                let weight = sinc(cutoff * distance) * window
                accumulated += Double(input[k]) * weight
                weightSum += weight
            }
            // Normalizing by the realized weight sum keeps the gain flat at the
            // edges, where the kernel is clipped by the ends of the buffer.
            output[n] = weightSum > 1e-9 ? Float(accumulated / weightSum) : 0
        }
        return output
    }

    /// Decoded audio, ready for `SonicAnalyzer.analyze`.
    public static func prepare(_ audio: DecodedAudio, sampleRate: Int) -> [Float] {
        resample(downmix(audio), from: audio.sampleRate, to: sampleRate)
    }

    private static func sinc(_ x: Double) -> Double {
        guard abs(x) > 1e-9 else { return 1 }
        let pix = Double.pi * x
        return sin(pix) / pix
    }
}
