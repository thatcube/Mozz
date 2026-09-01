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

    /**
     * The albums credited to one artist.
     *
     * Sent as `remoteId`, not `artistRemoteId`: this command takes the artist as
     * *the* subject rather than as a filter, and asking under the other name got
     * "artistAlbums needs remoteId and serverId" back — which, because every
     * caller wraps these in `runCatching`, looked exactly like an artist with no
     * albums.
     */
    suspend fun artistAlbums(serverId: String, artistRemoteId: String): List<Album> =
        core.call<List<Album>>(
            CoreRequest(
                cmd = "artistAlbums",
                serverId = serverId,
                remoteId = artistRemoteId,
            )
        ) ?: emptyList()

    /**
     * One artist, by remote id.
     *
     * The core answers with a hero artwork key already resolved: artists
     * frequently have no picture of their own, and it falls back to a
     * representative album cover so the page still has something to bloom from.
     * Doing that here rather than in each client is what keeps the phone and the
     * desktop from choosing different covers for the same artist.
     */
    suspend fun artist(serverId: String, remoteId: String): Artist? =
        core.call<Artist>(
            CoreRequest(cmd = "artist", serverId = serverId, remoteId = remoteId)
        )

    /** One album, by remote id. Arrives as a header, so [Album.id] is 0. */
    suspend fun album(serverId: String, remoteId: String): Album? =
        core.call<Album>(CoreRequest(cmd = "album", serverId = serverId, remoteId = remoteId))

    /**
     * One track, by remote id.
     *
     * For re-resolving a durable reference — a "recently searched" row, a deep
     * link — rather than keeping a snapshot of the row, so titles and artwork
     * stay fresh and anything pruned from the catalogue simply drops out.
     */
    suspend fun track(serverId: String, remoteId: String): Track? =
        core.call<Track>(CoreRequest(cmd = "track", serverId = serverId, remoteId = remoteId))

    /**
     * The songs the core ranks highest for one artist — the artist page's "Top
     * Songs", and the list its Play button plays through.
     */
    suspend fun artistTopTracks(
        serverId: String,
        artistRemoteId: String,
        limit: Int = 500,
    ): List<Track> = core.call<List<Track>>(
        CoreRequest(
            cmd = "artistTopTracks",
            serverId = serverId,
            artistRemoteId = artistRemoteId,
            limit = limit,
        )
    ) ?: emptyList()

    /**
     * Albums this artist appears on without being credited for — compilations,
     * features, soundtracks.
     *
     * These arrive as headers, so their [Album.id] is 0; identify them by
     * `remoteId`.
     */
    suspend fun artistAppearsOn(
        serverId: String,
        artistRemoteId: String,
        limit: Int = 20,
    ): List<Album> = core.call<AlbumPage>(
        CoreRequest(
            cmd = "artistAppearsOn",
            serverId = serverId,
            artistRemoteId = artistRemoteId,
            limit = limit,
        )
    )?.items ?: emptyList()

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

    // MARK: Recommendations

    /**
     * The precomputed shortcuts the home screen shows: Supermix, Daily Mixes,
     * artist mixes, Replay, Mozz Weekly — in the core's own display order.
     *
     * Read only. They are produced by [generateHomeMixes] and [generateMozzWeekly]
     * on a schedule, so opening Home never waits on a generator.
     */
    suspend fun homeMixes(): List<HomeMix> =
        core.call<List<HomeMix>>(CoreRequest(cmd = "homeMixes")) ?: emptyList()

    /** Rebuild the daily mixes. Costly on a large library — see `HomeMixSchedule`. */
    suspend fun generateHomeMixes(serverId: String) {
        core.call<Map<String, Boolean>>(
            CoreRequest(cmd = "generateHomeMixes", serverId = serverId)
        )
    }

    /** Rebuild the weekly rediscovery set. */
    suspend fun generateMozzWeekly(serverId: String, limit: Int = 30) {
        core.call<Map<String, String>>(
            CoreRequest(cmd = "generateMozzWeekly", serverId = serverId, limit = limit)
        )
    }

    /** One mix's tracks, in rank order. */
    suspend fun mixTracks(setId: String): List<Track> =
        core.call<List<Track>>(CoreRequest(cmd = "mixTracks", setId = setId)) ?: emptyList()

    /**
     * Stop recommending one track, or everything by one artist.
     *
     * A hard exclusion the recommender honours from the next batch on, kept in
     * the same store the iPhone writes, so telling one device is telling all of
     * them once they sync. Reversible — see `unsuppress`.
     */
    suspend fun suppressTrack(serverId: String, remoteId: String) {
        core.call<Map<String, Boolean>>(
            CoreRequest(cmd = "suppressTrack", serverId = serverId, remoteId = remoteId)
        )
    }

    /** Sent as `remoteId`: the artist is the subject here, not a filter. */
    suspend fun suppressArtist(serverId: String, artistRemoteId: String) {
        core.call<Map<String, Boolean>>(
            CoreRequest(cmd = "suppressArtist", serverId = serverId, remoteId = artistRemoteId)
        )
    }

    suspend fun unsuppressTrack(serverId: String, remoteId: String) {
        core.call<Map<String, Boolean>>(
            CoreRequest(cmd = "unsuppressTrack", serverId = serverId, remoteId = remoteId)
        )
    }

    suspend fun unsuppressArtist(serverId: String, artistRemoteId: String) {
        core.call<Map<String, Boolean>>(
            CoreRequest(cmd = "unsuppressArtist", serverId = serverId, remoteId = artistRemoteId)
        )
    }

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

    /**
     * Lyrics for one track.
     *
     * Resolved by the core, which asks the server first and falls back to
     * LRCLIB — the same order, and the same caching, as the iPhone. Set
     * [useLRCLIB] to false to honour a "no third-party lookups" preference.
     */
    suspend fun lyrics(
        serverId: String,
        remoteId: String,
        useLRCLIB: Boolean = true,
    ): Lyrics = core.require(
        CoreRequest(
            cmd = "lyrics",
            serverId = serverId,
            remoteId = remoteId,
            useLRCLIB = useLRCLIB,
        )
    )

    /**
     * The player's backdrop tones for one piece of artwork.
     *
     * The caller decodes and downscales the image — that is platform work, and
     * Foundation has no image decoder off Apple — and passes raw RGBA. Returns
     * null when the artwork yields nothing usable, which is a fact about the
     * cover rather than an error.
     */
    suspend fun artworkTones(
        rgba: ByteArray,
        width: Int,
        height: Int,
    ): ArtworkTones? = core.call(
        CoreRequest(
            cmd = "artworkTones",
            pixels = android.util.Base64.encodeToString(rgba, android.util.Base64.NO_WRAP),
            width = width,
            height = height,
        )
    )

    // MARK: History

    /**
     * Append one listening event. Never mutated once written — this log is what
     * play counts, "recently played" and the recommender are built from, and it
     * is the same log the iPhone writes, so the two agree after a sync.
     */
    /**
     * Like or unlike a track.
     *
     * One control for every backend: the core translates it into whatever that
     * server actually has — a boolean favourite on Jellyfin, five stars on Plex.
     * Returns the resulting liked state, which is the local database's answer and
     * therefore immediate: the write to the server is queued behind it and
     * survives being offline.
     *
     * [deviceId] is optional and only used to attribute the like as a
     * recommender signal. A like never fails for want of it.
     */
    suspend fun setLiked(
        serverId: String,
        remoteId: String,
        liked: Boolean,
        deviceId: String? = null,
    ): Boolean =
        core.call<LikePayload>(
            CoreRequest(
                cmd = "setLiked",
                serverId = serverId,
                remoteId = remoteId,
                liked = liked,
                deviceId = deviceId,
            )
        )?.liked ?: liked

    /**
     * Set or clear a granular star rating. Ratings backends only (Plex,
     * Subsonic); the core refuses it elsewhere rather than pretending.
     */
    suspend fun setRating(
        serverId: String,
        remoteId: String,
        stars: Double?,
        deviceId: String? = null,
    ): Boolean =
        core.call<LikePayload>(
            CoreRequest(
                cmd = "setRating",
                serverId = serverId,
                remoteId = remoteId,
                stars = stars,
                deviceId = deviceId,
            )
        )?.liked ?: false

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
