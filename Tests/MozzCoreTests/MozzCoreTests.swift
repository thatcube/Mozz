import XCTest
@testable import MozzCore

final class DomainModelTests: XCTestCase {
    func testTrackCodableRoundTrip() throws {
        let track = Track(
            id: "42",
            title: "Paranoid Android",
            sortTitle: "Paranoid Android",
            albumTitle: "OK Computer",
            albumID: "7",
            artistName: "Radiohead",
            artistID: "3",
            albumArtistName: "Radiohead",
            trackNumber: 2,
            discNumber: 1,
            duration: 383.0,
            format: AudioFormat(container: "flac", codec: "flac", bitrateKbps: 900, sampleRateHz: 44100, channels: 2, bitDepth: 16),
            fileSizeBytes: 40_000_000,
            mediaKey: "/library/parts/99/file.flac",
            artwork: ArtworkRef(key: "/library/metadata/7/thumb/123"),
            genres: ["Alternative", "Rock"],
            isFavorite: true,
            normalizationGainDB: -6.5,
            addedAt: Date(timeIntervalSince1970: 1_600_000_000)
        )

        let data = try JSONEncoder().encode(track)
        let decoded = try JSONDecoder().decode(Track.self, from: data)
        XCTAssertEqual(track, decoded)
    }

    func testAlbumAndArtistCodableRoundTrip() throws {
        let artist = Artist(id: "1", name: "Boards of Canada", albumCount: 4, genres: ["Electronic"], isFavorite: true)
        let album = Album(id: "9", title: "Music Has the Right to Children", artistName: "Boards of Canada", artistID: "1", year: 1998, trackCount: 17)

        let a = try JSONDecoder().decode(Artist.self, from: JSONEncoder().encode(artist))
        let b = try JSONDecoder().decode(Album.self, from: JSONEncoder().encode(album))
        XCTAssertEqual(artist, a)
        XCTAssertEqual(album, b)
    }

    func testDefaultsAreSane() {
        let track = Track(id: "x", title: "t", artistName: "a")
        XCTAssertEqual(track.duration, 0)
        XCTAssertFalse(track.isFavorite)
        XCTAssertTrue(track.genres.isEmpty)
        XCTAssertNil(track.artwork)
    }

    func testNowPlayingAudioFormatLabels() {
        XCTAssertEqual(
            AudioFormat(codec: "flac", sampleRateHz: 44_100).nowPlayingLabel,
            "FLAC · 44.1 kHz"
        )
        XCTAssertEqual(
            AudioFormat(codec: "pcm_s24le", sampleRateHz: 96_000).nowPlayingLabel,
            "PCM · 96 kHz"
        )
        XCTAssertEqual(AudioFormat(codec: "dca").nowPlayingLabel, "DTS")
        XCTAssertEqual(AudioFormat(codec: "future_codec").nowPlayingLabel, "FUTURE CODEC")
        XCTAssertEqual(AudioFormat(container: "m4a").nowPlayingLabel, "M4A")
        XCTAssertNil(AudioFormat().nowPlayingLabel)
    }
}

final class PlaybackModeTests: XCTestCase {
    func testRepeatModeCycles() {
        XCTAssertEqual(RepeatMode.off.next, .all)
        XCTAssertEqual(RepeatMode.all.next, .one)
        XCTAssertEqual(RepeatMode.one.next, .off)
    }

    func testShuffleToggle() {
        var mode = ShuffleMode.off
        mode.toggle()
        XCTAssertEqual(mode, .on)
        mode.toggle()
        XCTAssertEqual(mode, .off)
    }
}

final class CapabilityResolverTests: XCTestCase {
    func testDetectedWinsAndPersists() {
        let detected = ServerCapabilities(backend: .jellyfin, supportsSyncedLyrics: true)
        let cached = ServerCapabilities(backend: .jellyfin, supportsSyncedLyrics: false)
        let r = CapabilityResolver.resolve(detected: detected, cached: cached, backend: .jellyfin)
        XCTAssertEqual(r.source, .detected)
        XCTAssertTrue(r.capabilities.supportsSyncedLyrics)
        XCTAssertTrue(r.shouldPersist)
    }

    func testCachedKeptWhenOfflineAndNotPersisted() {
        // The bug this guards: an offline launch must NOT overwrite the
        // last-known detected capabilities with generic defaults.
        let cached = ServerCapabilities(backend: .jellyfin, supportsSyncedLyrics: true, supportsNormalizationGain: true)
        let r = CapabilityResolver.resolve(detected: nil, cached: cached, backend: .jellyfin)
        XCTAssertEqual(r.source, .cached)
        XCTAssertTrue(r.capabilities.supportsSyncedLyrics)
        XCTAssertTrue(r.capabilities.supportsNormalizationGain)
        XCTAssertFalse(r.shouldPersist, "cached capabilities must not be re-persisted")
    }

    func testFallbackWhenNothingKnown() {
        let r = CapabilityResolver.resolve(detected: nil, cached: nil, backend: .plex)
        XCTAssertEqual(r.source, .fallback)
        XCTAssertEqual(r.capabilities.backend, .plex)
        XCTAssertTrue(r.shouldPersist)
    }
}

final class NormalizationGainTests: XCTestCase {
    func testZeroGainIsUnity() {
        XCTAssertEqual(NormalizationGain.linearScalar(gainDB: 0), 1.0, accuracy: 0.0001)
    }

    func testNegativeGainAttenuates() {
        // -6 dB ≈ 0.501, -20 dB = 0.1.
        XCTAssertEqual(NormalizationGain.linearScalar(gainDB: -6), 0.501, accuracy: 0.005)
        XCTAssertEqual(NormalizationGain.linearScalar(gainDB: -20), 0.1, accuracy: 0.0005)
    }

    func testPositiveGainBoosts() {
        // +6 dB ≈ 1.995.
        XCTAssertEqual(NormalizationGain.linearScalar(gainDB: 6), 1.995, accuracy: 0.005)
    }

    func testPreampShiftsGain() {
        // gain 0 + preamp -6 == gain -6.
        XCTAssertEqual(NormalizationGain.linearScalar(gainDB: 0, preampDB: -6),
                       NormalizationGain.linearScalar(gainDB: -6), accuracy: 0.0001)
    }

    func testExtremeGainIsClampedToCeiling() {
        // A bogus +100 dB tag must not blow out the output.
        XCTAssertEqual(NormalizationGain.linearScalar(gainDB: 100), 4.0, accuracy: 0.0001)
    }
}

final class EqualizerSettingsTests: XCTestCase {
    func testFlatIsNeutral() {
        let flat = EqualizerSettings.flat
        XCTAssertTrue(flat.isFlat)
        XCTAssertEqual(flat.gains.count, EqualizerSettings.bandCount)
        XCTAssertTrue(flat.gains.allSatisfy { $0 == 0 })
        XCTAssertEqual(flat.preampDB, 0)
    }

    func testInitNormalizesGainLength() {
        // Too few → padded with 0; too many → truncated. Always bandCount long.
        XCTAssertEqual(EqualizerSettings(gains: [1, 2, 3]).gains.count, EqualizerSettings.bandCount)
        XCTAssertEqual(EqualizerSettings(gains: Array(repeating: 1, count: 40)).gains.count,
                       EqualizerSettings.bandCount)
        let padded = EqualizerSettings(gains: [3, 3]).gains
        XCTAssertEqual(padded[0], 3)
        XCTAssertEqual(padded[2], 0)
    }

    func testGainsAreClampedToRange() {
        let s = EqualizerSettings(gains: Array(repeating: 999, count: EqualizerSettings.bandCount),
                                  preampDB: -999)
        XCTAssertTrue(s.gains.allSatisfy { $0 == EqualizerSettings.gainRange.upperBound })
        XCTAssertEqual(s.preampDB, EqualizerSettings.gainRange.lowerBound)
    }

    func testNonFiniteBecomesZero() {
        var s = EqualizerSettings.flat
        s.setGain(.nan, forBand: 0)
        s.setPreamp(.infinity)
        XCTAssertEqual(s.gains[0], 0)
        XCTAssertEqual(s.preampDB, 0)
    }

    func testSetGainOutOfRangeIndexIsIgnored() {
        var s = EqualizerSettings.flat
        s.setGain(6, forBand: 999)   // no crash, no change
        XCTAssertTrue(s.isFlat)
        s.setGain(6, forBand: -1)
        XCTAssertTrue(s.isFlat)
    }

    func testCodableRoundTrip() throws {
        let original = EqualizerPreset.bassBoost.settings
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EqualizerSettings.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testCodableDecodeNormalizesMalformedBlob() throws {
        // A tampered/legacy blob: too-short gains + out-of-range values. Decode
        // must pad, clamp, and never crash (the synthesized decoder would not).
        let json = Data(#"{"gains":[3.0,99.0],"preampDB":-99.0}"#.utf8)
        let s = try JSONDecoder().decode(EqualizerSettings.self, from: json)
        XCTAssertEqual(s.gains.count, EqualizerSettings.bandCount)
        XCTAssertEqual(s.gains[0], 3.0)
        XCTAssertEqual(s.gains[1], EqualizerSettings.gainRange.upperBound)   // 99 → +12
        XCTAssertEqual(s.gains[2], 0)                                         // padded
        XCTAssertEqual(s.preampDB, EqualizerSettings.gainRange.lowerBound)   // -99 → -12
    }

    func testCodableDecodeMissingFieldsIsFlat() throws {
        let s = try JSONDecoder().decode(EqualizerSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(s.isFlat)
        XCTAssertEqual(s.gains.count, EqualizerSettings.bandCount)
    }

    func testPresetsAreValidAndDistinct() {
        for preset in EqualizerPreset.allCases {
            let s = preset.settings
            XCTAssertEqual(s.gains.count, EqualizerSettings.bandCount, "\(preset) wrong band count")
            XCTAssertTrue(s.gains.allSatisfy { EqualizerSettings.gainRange.contains($0) },
                          "\(preset) has an out-of-range band")
        }
        XCTAssertTrue(EqualizerPreset.flat.settings.isFlat)
        XCTAssertFalse(EqualizerPreset.bassBoost.settings.isFlat)
    }

    func testMatchingRecognizesPresetsAndCustom() {
        XCTAssertEqual(EqualizerPreset.matching(EqualizerPreset.vocal.settings), .vocal)
        XCTAssertEqual(EqualizerPreset.matching(.flat), .flat)
        var custom = EqualizerSettings.flat
        custom.setGain(7, forBand: 4)
        XCTAssertNil(EqualizerPreset.matching(custom))
    }

    func testFrequencyLabels() {
        XCTAssertEqual(EqualizerSettings.frequencyLabel(31), "31")
        XCTAssertEqual(EqualizerSettings.frequencyLabel(500), "500")
        XCTAssertEqual(EqualizerSettings.frequencyLabel(1_000), "1k")
        XCTAssertEqual(EqualizerSettings.frequencyLabel(16_000), "16k")
        XCTAssertEqual(EqualizerSettings.frequencyLabel(forBand: 0), "31")
        XCTAssertEqual(EqualizerSettings.frequencyLabel(forBand: EqualizerSettings.bandCount - 1), "16k")
    }
}

final class BiquadFilterTests: XCTestCase {
    func testZeroGainIsIdentity() {
        let c = BiquadCoefficients.peakingEQ(frequency: 1_000, gainDB: 0, q: 1.4, sampleRate: 44_100)
        XCTAssertEqual(c, .identity)
    }

    func testIdentityPassesSignalThrough() {
        var filter = Biquad(coefficients: .identity)
        let input: [Float] = [0, 0.5, -0.5, 1, -1, 0.25]
        for x in input {
            XCTAssertEqual(filter.process(x), x, accuracy: 1e-6)
        }
    }

    func testResetClearsMemory() {
        let boost = BiquadCoefficients.peakingEQ(frequency: 1_000, gainDB: 12, q: 1.4, sampleRate: 44_100)
        var a = Biquad(coefficients: boost)
        for _ in 0..<64 { _ = a.process(1.0) }   // load up filter state
        a.reset()
        var fresh = Biquad(coefficients: boost)
        // After reset, response to a new impulse matches a fresh filter.
        XCTAssertEqual(a.process(1.0), fresh.process(1.0), accuracy: 1e-6)
    }

    func testFlatEqualizerIsTransparent() {
        // A flat curve → every band identity → a cascade is a perfect passthrough.
        let coeffs = EqualizerSettings.flat.biquadCoefficients(sampleRate: 48_000)
        XCTAssertEqual(coeffs.count, EqualizerSettings.bandCount)
        var filters = coeffs.map { Biquad(coefficients: $0) }
        let input: [Float] = [0.1, -0.3, 0.7, -0.9, 0.42, -0.1]
        for x in input {
            var y = x
            for i in filters.indices { y = filters[i].process(y) }
            XCTAssertEqual(y, x, accuracy: 1e-5)
        }
    }

    func testBoostRaisesGainAtCenterFrequency() {
        // Drive a +12 dB / 1 kHz filter with a 1 kHz sine and confirm the output
        // amplitude grows relative to the input (a boost really boosts).
        let sampleRate = 48_000.0
        let freq = 1_000.0
        let c = BiquadCoefficients.peakingEQ(frequency: freq, gainDB: 12, q: 1.4, sampleRate: sampleRate)
        var filter = Biquad(coefficients: c)
        var inPeak: Float = 0
        var outPeak: Float = 0
        let n = 4_800   // settle over 0.1s
        for i in 0..<n {
            let x = Float(sin(2.0 * Double.pi * freq * Double(i) / sampleRate))
            let y = filter.process(x)
            if i > n / 2 {   // measure after transient settles
                inPeak = max(inPeak, abs(x))
                outPeak = max(outPeak, abs(y))
            }
        }
        // +12 dB ≈ 4x amplitude; allow slack for band Q. Must clearly exceed input.
        XCTAssertGreaterThan(outPeak, inPeak * 1.8)
    }

    func testCutLowersGainAtCenterFrequency() {
        let sampleRate = 48_000.0
        let freq = 1_000.0
        let c = BiquadCoefficients.peakingEQ(frequency: freq, gainDB: -12, q: 1.4, sampleRate: sampleRate)
        var filter = Biquad(coefficients: c)
        var inPeak: Float = 0
        var outPeak: Float = 0
        let n = 4_800
        for i in 0..<n {
            let x = Float(sin(2.0 * Double.pi * freq * Double(i) / sampleRate))
            let y = filter.process(x)
            if i > n / 2 {
                inPeak = max(inPeak, abs(x))
                outPeak = max(outPeak, abs(y))
            }
        }
        XCTAssertLessThan(outPeak, inPeak * 0.6)
    }

    func testStabilityAtExtremes() {
        // Extreme gains across all bands must stay finite (no filter blow-up).
        let boosted = EqualizerSettings(gains: Array(repeating: 12, count: EqualizerSettings.bandCount))
        var filters = boosted.biquadCoefficients(sampleRate: 44_100).map { Biquad(coefficients: $0) }
        var value: Float = 0
        for i in 0..<44_100 {
            let x = Float(sin(2.0 * Double.pi * 440.0 * Double(i) / 44_100.0))
            var y = x
            for j in filters.indices { y = filters[j].process(y) }
            value = y
            XCTAssertTrue(y.isFinite)
        }
        XCTAssertTrue(value.isFinite)
    }
}

final class MozzErrorTests: XCTestCase {
    func testRetryability() {
        XCTAssertTrue(MozzError.serverUnreachable.isRetryable)
        XCTAssertTrue(MozzError.transport("x").isRetryable)
        XCTAssertTrue(MozzError.badStatus(503).isRetryable)
        XCTAssertTrue(MozzError.badStatus(429).isRetryable)
        XCTAssertFalse(MozzError.badStatus(404).isRetryable)
        XCTAssertFalse(MozzError.unauthorized.isRetryable)
        XCTAssertFalse(MozzError.notFound.isRetryable)
        XCTAssertFalse(MozzError.decodingFailed("x").isRetryable)
    }

    func testReachabilityClassification() {
        XCTAssertTrue(MozzError.serverUnreachable.isReachabilityFailure)
        XCTAssertTrue(MozzError.transport("x").isReachabilityFailure)
        XCTAssertFalse(MozzError.unauthorized.isReachabilityFailure)
        XCTAssertFalse(MozzError.badStatus(500).isReachabilityFailure)
    }

    func testLocalizedDescriptionSurfacesDetail() {
        // `unsupported`/`transport`/`decodingFailed` carry a human message that
        // must reach `localizedDescription` (used in the sync-failed banner) —
        // otherwise it falls back to the opaque "error N" NSError text.
        XCTAssertEqual(
            MozzError.unsupported("No music library on ‘X’").errorDescription,
            "No music library on ‘X’")
        XCTAssertEqual(MozzError.transport("timed out").errorDescription, "timed out")
        let localized = (MozzError.unsupported("why") as Error).localizedDescription
        XCTAssertEqual(localized, "why")
        XCTAssertFalse(localized.contains("error 2"))
    }
}

final class CredentialStoreTests: XCTestCase {
    func testTokenLifecycle() throws {
        let store = InMemoryCredentialStore()
        XCTAssertNil(try store.token(for: "srv1"))

        try store.setToken("abc123", for: "srv1")
        XCTAssertEqual(try store.token(for: "srv1"), "abc123")

        try store.setToken(nil, for: "srv1")
        XCTAssertNil(try store.token(for: "srv1"))
    }

    func testClientIdentifierIsStable() throws {
        let store = InMemoryCredentialStore()
        let first = try store.clientIdentifier()
        let second = try store.clientIdentifier()
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, second, "client identifier must never be regenerated")
    }

    func testClientIdentifierNotGeneratedWhenSuppressed() throws {
        let store = InMemoryCredentialStore()
        XCTAssertEqual(try store.clientIdentifier(generatingIfMissing: false), "")
        // And it should not have been persisted.
        XCTAssertNil(try store.string(forKey: "clientIdentifier"))
    }
}

final class PlexAuthURLTests: XCTestCase {
    func testAuthAppURLContainsCodeAndClientID() throws {
        let session = PlexPinSession(id: 1, code: "WXYZ", clientIdentifier: "client-uuid-123")
        let info = ClientInfo(product: "Mozz", version: "1.0", deviceName: "iPhone", platform: "iOS", platformVersion: "17.0")
        let url = try XCTUnwrap(session.authAppURL(clientInfo: info))
        let string = url.absoluteString
        XCTAssertTrue(string.hasPrefix("https://app.plex.tv/auth#?"))
        XCTAssertTrue(string.contains("code=WXYZ"))
        XCTAssertTrue(string.contains("clientID=client-uuid-123"))
        XCTAssertTrue(string.contains("Mozz"))
    }

    func testAuthAppURLContextParamsAreSingleEncoded() throws {
        // Regression: the fragment was percent-encoded twice, turning the
        // `context[device][product]` brackets into "%255B"/"%255D" — Plex then
        // rejected the link ("we were unable to complete this request"). Brackets
        // must be encoded exactly once (%5B/%5D).
        let session = PlexPinSession(id: 1, code: "WXYZ", clientIdentifier: "cid")
        let info = ClientInfo(product: "Mozz", version: "1.0", deviceName: "iPhone", platform: "iOS", platformVersion: "17.0")
        let string = try XCTUnwrap(session.authAppURL(clientInfo: info)).absoluteString
        XCTAssertFalse(string.contains("%255"), "fragment must not be double percent-encoded")
        XCTAssertTrue(string.contains("context%5Bdevice%5D%5Bproduct%5D=Mozz"),
                      "context param name must be single-encoded")
    }
}
