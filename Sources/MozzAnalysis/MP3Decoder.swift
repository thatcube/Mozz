import Foundation
import CMozzMP3

/// Decoded PCM, exactly as the file declared it.
public struct DecodedAudio: Sendable {
    /// Interleaved samples. `channels` consecutive values per frame.
    public let samples: [Float]
    public let sampleRate: Int
    public let channels: Int

    public var frameCount: Int { channels > 0 ? samples.count / channels : 0 }
    public var seconds: Double {
        sampleRate > 0 ? Double(frameCount) / Double(sampleRate) : 0
    }
}

/// MP3 in, PCM out, via the vendored minimp3.
///
/// MP3 because it is the one format Plex, Jellyfin and Subsonic all agree to
/// transcode to — see `AnalysisAudioRequest`. The decoder is vendored rather
/// than taken from each platform for the same reason the FFT is written by
/// hand: two decoders produce slightly different samples, and slightly
/// different samples produce different vectors in a shared index.
public enum MP3Decoder {
    /// Returns nil when the data holds no decodable frames — a truncated
    /// response, an HTML error page, a server that ignored the format request.
    public static func decode(_ data: Data) -> DecodedAudio? {
        var info = mozz_mp3_info(sample_rate: 0, channels: 0, frames: 0)
        var buffer: UnsafeMutablePointer<Float>?

        let status = data.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return 1 }
            return mozz_mp3_decode(base.assumingMemoryBound(to: UInt8.self),
                                   raw.count, &buffer, &info)
        }
        guard status == 0, let buffer else { return nil }
        defer { mozz_mp3_free(buffer) }

        let count = Int(info.frames) * Int(info.channels)
        guard count > 0, info.sample_rate > 0, info.channels > 0 else { return nil }
        return DecodedAudio(samples: Array(UnsafeBufferPointer(start: buffer, count: count)),
                            sampleRate: Int(info.sample_rate),
                            channels: Int(info.channels))
    }
}
