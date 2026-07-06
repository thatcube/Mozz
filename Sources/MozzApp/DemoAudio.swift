import Foundation
import MozzCore

/// Generates full-length demo audio on the fly so the offline demo exercises the
/// real playback surface — seek, scrub, elapsed/remaining, lock-screen progress,
/// and gapless advance — over realistic multi-minute tracks, instead of looping a
/// single 3-second bundled clip.
///
/// A track's clip is a low-rate (8 kHz mono) sine tone of *exactly* the track's
/// metadata duration, so the scrubber and end-of-track timing line up. Clips are
/// written to the OS **caches** directory (ephemeral, OS-reclaimable, never
/// committed) and deduped by duration, so only the durations you actually play
/// are materialized — a handful of small files, not a hoard. 8 kHz mono keeps an
/// 8-minute clip well under 8 MB; fidelity is irrelevant for a test tone.
struct DemoAudioProvider: Sendable {
    let cacheDirectory: URL
    /// Bundled short clip, used if generation ever fails (never blocks playback).
    let fallbackURL: URL

    private static let sampleRate = 8_000
    private static let frequency = 220.0

    /// A playable file URL for a clip of `seconds` length, generating and caching
    /// it on first request.
    func clipURL(forDuration seconds: Double) -> URL {
        let secs = max(1, Int(seconds.rounded()))
        let url = cacheDirectory.appendingPathComponent("mozz-demo-tone-\(secs)s.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        do {
            let pcm = SineWAV.render(seconds: secs, sampleRate: Self.sampleRate, frequency: Self.frequency)
            try pcm.write(to: url, options: .atomic)
            return url
        } catch {
            return fallbackURL
        }
    }
}

/// Builds a self-contained 16-bit PCM mono WAV in memory. Pure and
/// dependency-free (no AVFoundation), so it's deterministic and cheap.
enum SineWAV {
    static func render(seconds: Int, sampleRate: Int, frequency: Double, amplitude: Double = 0.2) -> Data {
        let channels = 1
        let bitsPerSample = 16
        let frameCount = max(1, seconds * sampleRate)
        let dataSize = frameCount * channels * (bitsPerSample / 8)
        let byteRate = sampleRate * channels * (bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        var data = Data(capacity: 44 + dataSize)
        func u32(_ v: UInt32) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }

        // RIFF / WAVE header + fmt chunk (PCM) + data chunk.
        ascii("RIFF"); u32(UInt32(36 + dataSize)); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(UInt16(channels))
        u32(UInt32(sampleRate)); u32(UInt32(byteRate)); u16(UInt16(blockAlign)); u16(UInt16(bitsPerSample))
        ascii("data"); u32(UInt32(dataSize))

        let step = 2.0 * Double.pi * frequency / Double(sampleRate)
        let scale = amplitude * Double(Int16.max)
        for n in 0..<frameCount {
            let sample = Int16(sin(Double(n) * step) * scale)
            u16(UInt16(bitPattern: sample))
        }
        return data
    }
}
