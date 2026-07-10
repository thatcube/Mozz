import Foundation

/// A backend-agnostic reference to a piece of artwork.
///
/// The catalog stores only *references* to artwork, never the image bytes.
/// A reference is a small, token-free string whose meaning is private to the
/// backend that produced it (for Plex it is a `thumb`/`art` path, for Jellyfin
/// it is an `itemId|imageTag` pair). The owning ``MusicBackend`` turns a
/// reference plus a desired pixel size into a concrete, tokenized URL at
/// display time via ``MusicBackend/artworkURL(for:size:)``.
///
/// Keeping artwork as a reference (rather than a baked URL) means the catalog
/// stays valid across token rotation and server address changes, and lets the
/// UI request exactly the pixel size it needs.
public struct ArtworkRef: Codable, Sendable, Hashable {
    /// Opaque, backend-private identifier. Never contains a token.
    public var key: String

    public init(key: String) {
        self.key = key
    }
}

/// A named genre/tag attached to catalog items.
public struct Genre: Codable, Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public init(name: String) { self.name = name }
}

/// An artist as returned by a backend during catalog sync.
///
/// `id` is the *provider* identifier (Plex `ratingKey`, Jellyfin `Id`). It is
/// unique only within a single server; the database pairs it with the server
/// id to form a globally-unique key.
public struct Artist: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var sortName: String?
    public var artwork: ArtworkRef?
    public var albumCount: Int?
    public var genres: [String]
    public var isFavorite: Bool

    public init(
        id: String,
        name: String,
        sortName: String? = nil,
        artwork: ArtworkRef? = nil,
        albumCount: Int? = nil,
        genres: [String] = [],
        isFavorite: Bool = false
    ) {
        self.id = id
        self.name = name
        self.sortName = sortName
        self.artwork = artwork
        self.albumCount = albumCount
        self.genres = genres
        self.isFavorite = isFavorite
    }
}

/// An album as returned by a backend during catalog sync.
public struct Album: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var sortTitle: String?
    /// Display name of the album artist (denormalized for fast list rendering).
    public var artistName: String
    /// Provider id of the album artist, when the backend exposes it.
    public var artistID: String?
    public var year: Int?
    public var artwork: ArtworkRef?
    public var trackCount: Int?
    public var genres: [String]
    public var isFavorite: Bool
    /// When the album was added to the server library, if known.
    public var addedAt: Date?

    public init(
        id: String,
        title: String,
        sortTitle: String? = nil,
        artistName: String,
        artistID: String? = nil,
        year: Int? = nil,
        artwork: ArtworkRef? = nil,
        trackCount: Int? = nil,
        genres: [String] = [],
        isFavorite: Bool = false,
        addedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.sortTitle = sortTitle
        self.artistName = artistName
        self.artistID = artistID
        self.year = year
        self.artwork = artwork
        self.trackCount = trackCount
        self.genres = genres
        self.isFavorite = isFavorite
        self.addedAt = addedAt
    }
}

/// The physical/technical description of a track's best audio stream.
///
/// Captured at sync time so the app can make direct-play vs transcode
/// decisions offline and show format badges without another round-trip.
public struct AudioFormat: Codable, Sendable, Hashable {
    /// Container as reported by the server (e.g. `flac`, `m4a`, `mp3`).
    public var container: String?
    /// Codec (e.g. `flac`, `aac`, `alac`, `mp3`).
    public var codec: String?
    /// Nominal bitrate in kbps.
    public var bitrateKbps: Int?
    public var sampleRateHz: Int?
    public var channels: Int?
    public var bitDepth: Int?

    public init(
        container: String? = nil,
        codec: String? = nil,
        bitrateKbps: Int? = nil,
        sampleRateHz: Int? = nil,
        channels: Int? = nil,
        bitDepth: Int? = nil
    ) {
        self.container = container
        self.codec = codec
        self.bitrateKbps = bitrateKbps
        self.sampleRateHz = sampleRateHz
        self.channels = channels
        self.bitDepth = bitDepth
    }
}

public extension AudioFormat {
    /// Compact technical label for Now Playing. Known FFmpeg/Plex/Jellyfin aliases
    /// get familiar names; unknown values fall back to the server-provided codec so
    /// newly supported formats appear automatically without an app update.
    var nowPlayingLabel: String? {
        guard let codecLabel else { return nil }
        guard let sampleRateLabel else { return codecLabel }
        return "\(codecLabel) · \(sampleRateLabel)"
    }

    var codecLabel: String? {
        guard let raw = nonEmpty(codec) ?? nonEmpty(container) else { return nil }
        let normalized = raw.lowercased()

        if normalized == "pcm" || normalized.hasPrefix("pcm_") { return "PCM" }
        if normalized == "dca" || normalized == "dts" { return "DTS" }
        if normalized == "dsd" || normalized.hasPrefix("dsd_") { return "DSD" }

        switch normalized {
        case "aac", "mp4a", "mp4a.40.2": return "AAC"
        case "ac3": return "AC-3"
        case "eac3", "e-ac3": return "E-AC-3"
        case "alac": return "ALAC"
        case "ape": return "APE"
        case "flac": return "FLAC"
        case "mlp": return "MLP"
        case "mp2": return "MP2"
        case "mp3": return "MP3"
        case "opus": return "OPUS"
        case "truehd": return "TrueHD"
        case "vorbis": return "Vorbis"
        case "wavpack", "wv": return "WavPack"
        case "wmav1", "wmav2": return "WMA"
        case "wmapro": return "WMA Pro"
        default:
            return raw.replacingOccurrences(of: "_", with: " ").uppercased()
        }
    }

    private var sampleRateLabel: String? {
        guard let sampleRateHz, sampleRateHz > 0 else { return nil }
        guard sampleRateHz >= 1_000 else { return "\(sampleRateHz) Hz" }

        let whole = sampleRateHz / 1_000
        let remainder = sampleRateHz % 1_000
        guard remainder != 0 else { return "\(whole) kHz" }

        var fraction = String(format: "%03d", remainder)
        while fraction.last == "0" { fraction.removeLast() }
        return "\(whole).\(fraction) kHz"
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// A track as returned by a backend during catalog sync.
///
/// Fields are denormalized (album title, artist name) so track lists render
/// without joins, matching how the database stores them for read performance.
public struct Track: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var sortTitle: String?

    public var albumTitle: String?
    public var albumID: String?
    public var artistName: String
    public var artistID: String?
    /// Album-artist name, which can differ from the track artist on
    /// compilations. Used to group correctly under an album.
    public var albumArtistName: String?

    public var trackNumber: Int?
    public var discNumber: Int?
    /// Duration in seconds.
    public var duration: TimeInterval

    public var format: AudioFormat
    /// Size of the original file in bytes, when the server reports it.
    public var fileSizeBytes: Int64?
    /// Backend-private key used to build the original-file download URL and
    /// the stream URL. For Plex this is the `Part.key`; for Jellyfin it is the
    /// item id (reused as `id`, so kept optional here).
    public var mediaKey: String?

    public var artwork: ArtworkRef?
    public var genres: [String]
    public var isFavorite: Bool
    /// User's star rating 0–5 in half-star increments, when the backend exposes
    /// ratings (Plex). `nil` = unrated. Jellyfin has no per-track ratings — it
    /// uses `isFavorite` instead — so this stays `nil` there.
    public var rating: Double?
    /// ReplayGain / normalization gain in dB, when the server exposes it.
    public var normalizationGainDB: Double?
    public var addedAt: Date?
    /// MusicBrainz *recording* MBID, when the backend embeds one (Plex `Guid`,
    /// Jellyfin `ProviderIds.MusicBrainzTrack`). Captured during sync into
    /// `track_features.mbid`; `nil` when the server exposes none.
    public var mbid: String?
    /// MusicBrainz artist MBID for this track's primary artist, when embedded
    /// (Jellyfin `ProviderIds.MusicBrainzArtist`). Plex does not carry it on the
    /// track item, so it stays `nil` there until name-search resolves it.
    public var artistMbid: String?

    public init(
        id: String,
        title: String,
        sortTitle: String? = nil,
        albumTitle: String? = nil,
        albumID: String? = nil,
        artistName: String,
        artistID: String? = nil,
        albumArtistName: String? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        duration: TimeInterval = 0,
        format: AudioFormat = AudioFormat(),
        fileSizeBytes: Int64? = nil,
        mediaKey: String? = nil,
        artwork: ArtworkRef? = nil,
        genres: [String] = [],
        isFavorite: Bool = false,
        rating: Double? = nil,
        normalizationGainDB: Double? = nil,
        addedAt: Date? = nil,
        mbid: String? = nil,
        artistMbid: String? = nil
    ) {
        self.id = id
        self.title = title
        self.sortTitle = sortTitle
        self.albumTitle = albumTitle
        self.albumID = albumID
        self.artistName = artistName
        self.artistID = artistID
        self.albumArtistName = albumArtistName
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration
        self.format = format
        self.fileSizeBytes = fileSizeBytes
        self.mediaKey = mediaKey
        self.artwork = artwork
        self.genres = genres
        self.isFavorite = isFavorite
        self.rating = rating
        self.normalizationGainDB = normalizationGainDB
        self.addedAt = addedAt
        self.mbid = mbid
        self.artistMbid = artistMbid
    }
}

/// A playlist header (its items are synced separately and ordered).
public struct Playlist: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var trackCount: Int?
    public var durationSeconds: TimeInterval?
    public var artwork: ArtworkRef?
    public var isSmart: Bool

    public init(
        id: String,
        title: String,
        trackCount: Int? = nil,
        durationSeconds: TimeInterval? = nil,
        artwork: ArtworkRef? = nil,
        isSmart: Bool = false
    ) {
        self.id = id
        self.title = title
        self.trackCount = trackCount
        self.durationSeconds = durationSeconds
        self.artwork = artwork
        self.isSmart = isSmart
    }
}
