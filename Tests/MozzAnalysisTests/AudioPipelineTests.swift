import XCTest
@testable import MozzAnalysis

/// The path from "bytes off a server" to "samples the analyzer accepts":
/// vendored MP3 decode, downmix, resample.
final class AudioPipelineTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "mp3", subdirectory: "Fixtures"),
            "missing fixture \(name).mp3")
        return try Data(contentsOf: url)
    }

    // MARK: Decoding

    func testDecodesARealMP3() throws {
        let audio = try XCTUnwrap(MP3Decoder.decode(try fixture("tone-440-6s")))
        XCTAssertEqual(audio.sampleRate, 44_100)
        XCTAssertEqual(audio.channels, 1)
        // MP3 frames are 1,152 samples and encoders pad, so this is close to six
        // seconds rather than exactly six.
        XCTAssertEqual(audio.seconds, 6, accuracy: 0.2)
        XCTAssertFalse(audio.samples.contains { !$0.isFinite })
    }

    func testDecodingRefusesThingsThatAreNotMP3() {
        // The realistic failures: an HTML error page, an empty body, a truncated
        // response. None of them should reach the analyzer as "audio".
        XCTAssertNil(MP3Decoder.decode(Data("<html><body>404</body></html>".utf8)))
        XCTAssertNil(MP3Decoder.decode(Data()))
        XCTAssertNil(MP3Decoder.decode(Data(repeating: 0, count: 4096)))
    }

    // MARK: Downmix

    func testDownmixAveragesChannelsRatherThanTakingOne() {
        // Hard-panned content must survive: taking the left channel would
        // analyze a track with an instrument missing.
        let stereo = DecodedAudio(samples: [1.0, 0.0, 0.5, -0.5, 0.2, 0.4],
                                  sampleRate: 44_100, channels: 2)
        let mono = AudioPreparation.downmix(stereo)
        XCTAssertEqual(mono.count, 3)
        XCTAssertEqual(mono[0], 0.5, accuracy: 1e-6)    // (1.0 + 0.0) / 2
        XCTAssertEqual(mono[1], 0.0, accuracy: 1e-6)    // (0.5 + -0.5) / 2
        XCTAssertEqual(mono[2], 0.3, accuracy: 1e-6)    // (0.2 + 0.4) / 2
    }

    func testDownmixLeavesMonoAlone() {
        let mono = DecodedAudio(samples: [0.1, 0.2, 0.3], sampleRate: 16_000, channels: 1)
        XCTAssertEqual(AudioPreparation.downmix(mono), [0.1, 0.2, 0.3])
    }

    // MARK: Resampling

    func testResamplingProducesTheExpectedLength() {
        let input = Signal.sine(hz: 440, seconds: 2)   // 16 kHz
        let out = AudioPreparation.resample(input, from: 16_000, to: 8_000)
        XCTAssertEqual(out.count, input.count / 2)
        XCTAssertEqual(AudioPreparation.resample(input, from: 16_000, to: 16_000), input,
                       "a no-op rate change must not touch the samples")
    }

    func testResamplingLowPassesInsteadOfAliasing() {
        // The reason this is a windowed sinc and not linear interpolation. A
        // 12 kHz tone cannot exist below an 8 kHz Nyquist: it must be filtered
        // OUT, not folded down to 4 kHz where it would land in the middle of the
        // spectral features and read as real content.
        let rate = 44_100
        let count = rate * 2
        let tone = (0..<count).map { i in
            Float(0.5 * sin(2 * Double.pi * 12_000 * Double(i) / Double(rate)))
        }
        let resampled = AudioPreparation.resample(tone, from: rate, to: 16_000)
        let inputRMS = rms(tone)
        let outputRMS = rms(resampled)
        XCTAssertLessThan(outputRMS, inputRMS * 0.1,
                          "above-Nyquist content must be attenuated, not aliased down")
    }

    func testResamplingPreservesAToneBelowNyquist() {
        let rate = 44_100
        let count = rate * 2
        let tone = (0..<count).map { i in
            Float(0.5 * sin(2 * Double.pi * 440 * Double(i) / Double(rate)))
        }
        let resampled = AudioPreparation.resample(tone, from: rate, to: 16_000)
        // Same energy, give or take the filter's transition band.
        XCTAssertEqual(rms(resampled), rms(tone), accuracy: 0.03)
    }

    // MARK: End to end

    func testAServerMP3AnalyzesLikeTheToneItIs() throws {
        let audio = try XCTUnwrap(MP3Decoder.decode(try fixture("tone-440-6s")))
        let analyzer = SonicAnalyzer()
        let prepared = AudioPreparation.prepare(audio, sampleRate: analyzer.configuration.sampleRate)
        XCTAssertEqual(Double(prepared.count) / 16_000, 6, accuracy: 0.2)

        let decoded = try XCTUnwrap(analyzer.analyze(prepared))
        let synthetic = try XCTUnwrap(analyzer.analyze(Signal.sine(hz: 440, seconds: 6)))
        let noise = try XCTUnwrap(analyzer.analyze(Signal.noise(seconds: 6)))

        let toTone = try XCTUnwrap(decoded.similarity(to: synthetic))
        let toNoise = try XCTUnwrap(decoded.similarity(to: noise))
        XCTAssertGreaterThan(toTone, toNoise,
                             "a 440 Hz tone through a real encoder, a real decoder and a resampler must still read as that tone")
        XCTAssertGreaterThan(toTone, 0.8, "measured \(toTone)")
    }

    private func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(samples.count)).squareRoot()
    }
}
