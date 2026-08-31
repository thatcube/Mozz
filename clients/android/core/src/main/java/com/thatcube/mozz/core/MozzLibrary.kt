package com.thatcube.mozz.core

/**
 * Reading the mirrored catalog.
 *
 * Every one of these answers from the on-device database, not the server, which
 * is why browsing and searching stay instant when the server is slow, far away
 * or off. Nothing here touches the network.
 *
 * Paging comes in two shapes and they are not interchangeable. Artists, albums
 * and tracks are **cursor**-paged: pass the previous page's `nextCursor`, and a
 * null cursor back means that was the last page. Everything else takes a `limit`
 * and returns the whole answer — those are bounded by their nature (an album's
 * tracks, a playlist, the liked songs).
 */
class MozzLibrary(private val core: MozzCore) {

    suspend fun counts(serverId: String? = null): LibraryCounts =
        core.require(CoreRequest(cmd = "counts", serverId = serverId))

    // MARK: Cursor-paged listings

    suspend fun artists(serverId: String? = null, cursor: String? = null, limit: Int = 100) =
        core.callPage<List<Artist>>(
            CoreRequest(cmd = "artists", serverId = serverId, cursor = cursor, limit = limit)
        )

    suspend fun albums(serverId: String? = null, cursor: String? = null, limit: Int = 100) =
        core.callPage<List<Album>>(
            CoreRequest(cmd = "albums", serverId = serverId, cursor = cursor, limit = limit)
        )

    suspend fun tracks(serverId: String? = null, cursor: String? = null, limit: Int = 100) =
        core.callPage<List<Track>>(
            CoreRequest(cmd = "tracks", serverId = serverId, cursor = cursor, limit = limit)
        )

    // MARK: Whole answers

    /**
     * An album's tracks.
     *
     * Prefer [groupKey] when the album has one: servers — Jellyfin especially —
     * split a single album into several entities, and asking by remote id alone
     * returns a slice of it rather than the record.
     */
    suspend fun albumTracks(
        serverId: String,
        remoteId: String? = null,
        groupKey: String? = null,
    ): List<Track> = core.call<List<Track>>(
        CoreRequest(
            cmd = "albumTracks",
            serverId = serverId,
            remoteId = remoteId,
            groupKey = groupKey,
        )
    ) ?: emptyList()

    suspend fun artistAlbums(serverId: String, artistRemoteId: String): List<Album> =
        core.call<List<Album>>(
            CoreRequest(
                cmd = "artistAlbums",
                serverId = serverId,
                artistRemoteId = artistRemoteId,
            )
        ) ?: emptyList()

    suspend fun playlists(serverId: String): List<Playlist> =
        core.call<List<Playlist>>(CoreRequest(cmd = "playlists", serverId = serverId))
            ?: emptyList()

    suspend fun playlistTracks(serverId: String, remoteId: String): List<Track> =
        core.call<List<Track>>(
            CoreRequest(cmd = "playlistTracks", serverId = serverId, remoteId = remoteId)
        ) ?: emptyList()

    /** The songs someone has favourited on their server. v1's home screen. */
    suspend fun likedTracks(serverId: String? = null, limit: Int = 500): List<Track> =
        core.call<List<Track>>(
            CoreRequest(cmd = "likedTracks", serverId = serverId, limit = limit)
        ) ?: emptyList()

    suspend fun recentlyAddedAlbums(serverId: String, limit: Int = 20): List<Album> =
        core.call<List<Album>>(
            CoreRequest(cmd = "recentlyAddedAlbums", serverId = serverId, limit = limit)
        ) ?: emptyList()

    suspend fun recentlyPlayedTracks(serverId: String? = null, limit: Int = 20): List<Track> =
        core.call<List<Track>>(
            CoreRequest(cmd = "recentlyPlayedTracks", serverId = serverId, limit = limit)
        ) ?: emptyList()

    /**
     * Search across artists, albums and tracks. [limit] is per type, not total.
     *
     * Fast enough to run on every keystroke: 16 ms at the 95th percentile over
     * 100k tracks on Android, measured by the spike.
     */
    suspend fun search(query: String, serverId: String? = null, limit: Int = 20): SearchResults =
        core.require(
            CoreRequest(cmd = "search", query = query, serverId = serverId, limit = limit)
        )

    suspend fun servers(): List<Server> =
        core.call<List<Server>>(CoreRequest(cmd = "servers")) ?: emptyList()

    // MARK: History

    /**
     * Append one listening event. Never mutated once written — this log is what
     * play counts, "recently played" and the recommender are built from, and it
     * is the same log the iPhone writes, so the two agree after a sync.
     */
    suspend fun recordPlayEvent(
        serverId: String,
        remoteId: String,
        kind: PlayEventKind,
        deviceId: String,
        deviceName: String? = null,
        positionSeconds: Double? = null,
        durationSeconds: Double? = null,
    ) {
        core.call<Map<String, String>>(
            CoreRequest(
                cmd = "recordPlayEvent",
                serverId = serverId,
                remoteId = remoteId,
                eventKind = kind.wire,
                deviceId = deviceId,
                deviceName = deviceName,
                positionSeconds = positionSeconds,
                durationSeconds = durationSeconds,
            )
        )
    }
}

/** Mirrors `PlayEventKind` in Sources/MozzCore/PlayEvent.swift. */
enum class PlayEventKind(val wire: String) {
    STARTED("started"),
    COMPLETED("completed"),
    SKIPPED("skipped"),
    SEEK("seek"),
    LIKED("liked"),
    UNLIKED("unliked"),
}
