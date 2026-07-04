import Foundation
import MozzCore

/// Generates a large, realistic synthetic catalog directly into the database
/// through the real ``CatalogWriter`` path (so benchmarks measure the true
/// write/index cost, not a shortcut). Items are produced and written in chunks
/// so peak memory stays flat regardless of catalog size.
public struct SyntheticCatalog: Sendable {
    /// The shape of a generated catalog.
    public struct Size: Sendable {
        public var artists: Int
        public var albums: Int
        public var tracks: Int

        public init(artists: Int, albums: Int, tracks: Int) {
            self.artists = artists
            self.albums = albums
            self.tracks = tracks
        }

        /// The performance-bar target: ~100k tracks / ~10k albums.
        public static let large = Size(artists: 2_000, albums: 10_000, tracks: 100_000)
        /// A smaller size for fast test runs.
        public static let small = Size(artists: 50, albums: 200, tracks: 2_000)
    }

    private let database: MusicDatabase
    private let writer: CatalogWriter

    public init(_ database: MusicDatabase) {
        self.database = database
        self.writer = CatalogWriter(database)
    }

    /// A synthetic server id the generator populates under.
    public static let defaultServerID: ServerID = "synthetic-server"

    /// Generate a catalog of the given size. Safe to call on a background task;
    /// does all work off the main thread. `progress` is reported 0…1.
    public func generate(
        serverId: ServerID = SyntheticCatalog.defaultServerID,
        size: Size = .large,
        chunkSize: Int = 5_000,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        // Ensure a server row exists so catalog foreign keys resolve.
        try await writer.saveServer(ServerConnection(
            id: serverId,
            kind: .jellyfin,
            name: "Synthetic Library",
            baseURL: URL(string: "https://synthetic.local")!,
            userID: "synthetic-user",
            clientIdentifier: "synthetic-client"
        ))
        try await writer.saveCapabilities(
            ServerCapabilities(backend: .jellyfin, serverVersion: "10.9.0"),
            serverId: serverId
        )

        let total = Double(size.artists + size.albums + size.tracks)
        var completed = 0.0
        func report(_ n: Int) {
            completed += Double(n)
            progress?(min(1.0, completed / total))
        }

        // Artists
        try await inChunks(size.artists, chunkSize) { start, end in
            let batch = (start..<end).map { Self.makeArtist(index: $0) }
            try await writer.upsertArtists(batch, serverId: serverId)
            report(end - start)
        }

        // Albums (each mapped to an artist)
        let albumsPerArtist = max(1, size.albums / max(1, size.artists))
        try await inChunks(size.albums, chunkSize) { start, end in
            let batch = (start..<end).map {
                Self.makeAlbum(index: $0, artistCount: size.artists, albumsPerArtist: albumsPerArtist)
            }
            try await writer.upsertAlbums(batch, serverId: serverId)
            report(end - start)
        }

        // Tracks (each mapped to an album, inheriting its artist)
        let tracksPerAlbum = max(1, size.tracks / max(1, size.albums))
        try await inChunks(size.tracks, chunkSize) { start, end in
            let batch = (start..<end).map {
                Self.makeTrack(
                    index: $0,
                    albumCount: size.albums,
                    artistCount: size.artists,
                    tracksPerAlbum: tracksPerAlbum,
                    albumsPerArtist: albumsPerArtist
                )
            }
            try await writer.upsertTracks(batch, serverId: serverId)
            report(end - start)
        }
    }

    private func inChunks(
        _ count: Int,
        _ chunkSize: Int,
        _ body: (Int, Int) async throws -> Void
    ) async throws {
        var start = 0
        while start < count {
            let end = min(count, start + chunkSize)
            try await body(start, end)
            start = end
        }
    }

    // MARK: - Deterministic item factories

    private static func makeArtist(index: Int) -> Artist {
        let name = artistName(index)
        return Artist(
            id: "art-\(index)",
            name: name,
            sortName: name,
            artwork: ArtworkRef(key: "art-artwork-\(index)"),
            albumCount: 5,
            genres: [genre(index)],
            isFavorite: index % 37 == 0
        )
    }

    private static func makeAlbum(index: Int, artistCount: Int, albumsPerArtist: Int) -> Album {
        let artistIndex = min(artistCount - 1, index / albumsPerArtist)
        let title = albumTitle(index)
        return Album(
            id: "alb-\(index)",
            title: title,
            sortTitle: title,
            artistName: artistName(artistIndex),
            artistID: "art-\(artistIndex)",
            year: 1965 + (index % 59),
            artwork: ArtworkRef(key: "alb-artwork-\(index)"),
            trackCount: 10,
            genres: [genre(index)],
            isFavorite: index % 53 == 0,
            addedAt: Date(timeIntervalSince1970: 1_500_000_000 + Double(index) * 3600)
        )
    }

    private static func makeTrack(
        index: Int,
        albumCount: Int,
        artistCount: Int,
        tracksPerAlbum: Int,
        albumsPerArtist: Int
    ) -> Track {
        let albumIndex = min(albumCount - 1, index / tracksPerAlbum)
        let artistIndex = min(artistCount - 1, albumIndex / albumsPerArtist)
        let trackNo = (index % tracksPerAlbum) + 1
        let isFlac = index % 2 == 0
        let title = trackTitle(index)
        return Track(
            id: "trk-\(index)",
            title: title,
            sortTitle: title,
            albumTitle: albumTitle(albumIndex),
            albumID: "alb-\(albumIndex)",
            artistName: artistName(artistIndex),
            artistID: "art-\(artistIndex)",
            albumArtistName: artistName(artistIndex),
            trackNumber: trackNo,
            discNumber: 1,
            duration: Double(120 + (index % 360)),
            format: isFlac
                ? AudioFormat(container: "flac", codec: "flac", bitrateKbps: 900, sampleRateHz: 44_100, channels: 2, bitDepth: 16)
                : AudioFormat(container: "mp3", codec: "mp3", bitrateKbps: 320, sampleRateHz: 44_100, channels: 2),
            fileSizeBytes: isFlac ? 35_000_000 : 9_000_000,
            mediaKey: "media-\(index)",
            artwork: ArtworkRef(key: "alb-artwork-\(albumIndex)"),
            genres: [genre(index)],
            isFavorite: index % 101 == 0,
            normalizationGainDB: isFlac ? -6.5 : nil,
            addedAt: Date(timeIntervalSince1970: 1_500_000_000 + Double(index) * 60)
        )
    }

    // MARK: Name pools (small pools + index mixing = realistic variety + repeats)

    private static func pick(_ pool: [String], _ seed: Int) -> String {
        // Knuth multiplicative hash spreads sequential indices across the pool.
        let mixed = (seed &* 2_654_435_761) & 0x7fff_ffff
        return pool[mixed % pool.count]
    }

    private static func artistName(_ index: Int) -> String {
        "\(pick(firstNames, index &* 3 + 1)) \(pick(lastNames, index &* 7 + 2))"
    }

    private static func albumTitle(_ index: Int) -> String {
        "\(pick(adjectives, index &* 5 + 3)) \(pick(nouns, index &* 11 + 4))"
    }

    private static func trackTitle(_ index: Int) -> String {
        "\(pick(verbs, index &* 13 + 5)) the \(pick(nouns, index &* 17 + 6))"
    }

    private static func genre(_ index: Int) -> String { genres[index % genres.count] }

    private static let firstNames = ["Ada", "Ravi", "Mira", "Kai", "Nadia", "Sol", "Ivo", "Lena", "Theo", "Juno", "Omar", "Vera", "Cyrus", "Pia", "Enzo", "Suki"]
    private static let lastNames = ["Rivers", "Vance", "Okafor", "Marsh", "Delacroix", "Nakamura", "Bright", "Solano", "Ashford", "Quinn", "Petrov", "Ozturk"]
    private static let adjectives = ["Silent", "Golden", "Electric", "Hidden", "Crimson", "Northern", "Velvet", "Broken", "Endless", "Distant", "Neon", "Lunar", "Wild", "Sacred", "Frozen", "Analog"]
    private static let nouns = ["Horizon", "Machine", "Garden", "Signal", "Ocean", "Cathedral", "Circuit", "Mirror", "Harvest", "Ember", "Tide", "Compass", "Lantern", "Meridian", "Static", "Bloom"]
    private static let verbs = ["Chasing", "Falling", "Turning", "Waking", "Burning", "Drifting", "Holding", "Breaking", "Finding", "Losing", "Dreaming", "Running"]
    private static let genres = ["Electronic", "Rock", "Jazz", "Ambient", "Hip-Hop", "Classical", "Folk", "Metal", "Pop", "Soul"]
}
