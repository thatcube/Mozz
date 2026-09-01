package com.thatcube.mozz.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// The wire contract with the Swift core. Deliberately mirrors the Wire* types in
// Sources/MozzFFI/MozzSession.swift and MozzSessionServer.swift, and the C#
// mirror in clients/desktop/Core/Models.cs — a change on one side has to be made
// on all of them, which is why the shapes are kept small and obvious.

/**
 * One command to the core.
 *
 * Every field is nullable and defaults to null, and the encoder is configured to
 * omit nulls, so a request carries only the keys its command needs. The Swift
 * decoder ignores keys it does not know, but sending `"password": null` to
 * `streamURL` would be noise on every call.
 */
@Serializable
data class CoreRequest(
    val cmd: String,
    val id: Int? = null,
    val serverId: String? = null,
    val offset: Int? = null,
    val limit: Int? = null,
    val query: String? = null,
    val remoteId: String? = null,
    val artistRemoteId: String? = null,
    val groupKey: String? = null,
    val genre: String? = null,
    /** Opaque resume position from a previous page's `nextCursor`. */
    val cursor: String? = null,

    // Sign-in, sync and streaming.
    val kind: String? = null,
    val baseURL: String? = null,
    val username: String? = null,
    val password: String? = null,
    val apiKey: String? = null,
    val token: String? = null,
    val userID: String? = null,
    val serverName: String? = null,
    val clientIdentifier: String? = null,
    val musicSectionID: String? = null,
    val pinId: Int? = null,
    val code: String? = null,
    /** Plex's account token — for `plexResolve` only. */
    val accountToken: String? = null,
    /** The Plex **server's** machine identifier, so re-resolution stays on it. */
    val machineIdentifier: String? = null,
    val artworkKey: String? = null,
    val size: Int? = null,
    val maxBitrateKbps: Int? = null,
    val useLRCLIB: Boolean? = null,
    /** Which precomputed mix — a home mix or Mozz Weekly — a command is about. */
    val setId: String? = null,
    /** Base64 RGBA, 8 bits per channel, `width * height * 4` bytes. */
    val pixels: String? = null,
    val width: Int? = null,
    val height: Int? = null,

    // Likes and ratings.
    val liked: Boolean? = null,
    val stars: Double? = null,
    val itemType: String? = null,

    // Listening history.
    val eventKind: String? = null,
    val positionSeconds: Double? = null,
    val durationSeconds: Double? = null,
    val deviceId: String? = null,
    val deviceName: String? = null,
)

/**
 * The response envelope. `nextCursor` rides here rather than in the payload, so
 * one shape covers both paged and unpaged commands.
 */
@Serializable
data class Envelope<T>(
    val ok: Boolean,
    val cmd: String? = null,
    val payload: T? = null,
    val error: String? = null,
    val id: Int? = null,
    val nextCursor: String? = null,
)

/** A listing plus where to resume it. `nextCursor` is null on the last page. */
data class Page<T>(val rows: T?, val nextCursor: String?)

// MARK: - Library

@Serializable
data class Artist(
    /** 0 for an artist that arrived as a header — identify by [remoteId]. */
    val id: Long = 0,
    val remoteId: String,
    val serverId: String,
    val name: String,
    val artworkKey: String? = null,
    val heroArtworkKey: String? = null,
    val sortName: String? = null,
    val albumCount: Int? = null,
    val genres: List<String>? = null,
    val isFavorite: Boolean = false,
)

@Serializable
data class Album(
    /**
     * The local row id, or 0 for an album that arrived as a *header*.
     *
     * "Appears On" is answered from a projection that carries no row id, because
     * nothing needs one there. Identify an album by [remoteId] (with [groupKey]
     * where there is one) rather than by this — that pair is what the core itself
     * treats as the album's identity.
     */
    val id: Long = 0,
    val remoteId: String,
    val serverId: String,
    val title: String,
    val artistName: String,
    val artistRemoteId: String? = null,
    val year: Int? = null,
    val trackCount: Int? = null,
    val artworkKey: String? = null,
    val groupKey: String = "",
    val sortTitle: String? = null,
    val genres: List<String>? = null,
    val isFavorite: Boolean = false,
    val addedAt: Double? = null,
    val releaseKind: String? = null,
    @SerialName("isSingleOrEP") val isSingleOrEp: Boolean? = null,
)

@Serializable
data class Track(
    val id: Long,
    val remoteId: String,
    val serverId: String,
    val title: String,
    val artistName: String,
    val albumTitle: String? = null,
    val albumRemoteId: String? = null,
    /** Who made it, as a reference — so a row can offer "go to artist". */
    val artistRemoteId: String? = null,
    val trackNumber: Int? = null,
    val discNumber: Int? = null,
    val durationSeconds: Double = 0.0,
    val artworkKey: String? = null,
    val isFavorite: Boolean = false,
    /**
     * The star rating, where the backend keeps one.
     *
     * Carried alongside [isFavorite] because on a ratings backend that flag is
     * always false and this is what "liked" actually means — see [isLiked].
     */
    val rating: Double? = null,
    /** Codec and bitrate as the server reported them. */
    val codec: String? = null,
    val bitrateKbps: Int? = null,
    val normalizationGainDB: Double? = null,
) {
    /**
     * Whether this counts as liked, by the same rule every Mozz client uses.
     *
     * A Plex track has no boolean favourite: four stars or more is a like, which
     * also means ratings someone set in Plexamp years ago already show up as
     * liked here. The threshold matches `LikePolicy` in the core.
     */
    val isLiked: Boolean get() = isFavorite || (rating ?: 0.0) >= LIKE_RATING_THRESHOLD

    /** A short format badge — "FLAC", "AAC" — or null when the server said nothing. */
    val format: String? get() = codec?.takeIf { it.isNotBlank() }?.uppercase()

    /** m:ss, the form every music player uses. */
    val duration: String
        get() {
            if (durationSeconds <= 0 || durationSeconds.isNaN()) return "--:--"
            val total = durationSeconds.toLong()
            val hours = total / 3600
            val minutes = (total % 3600) / 60
            val seconds = total % 60
            return if (hours >= 1) "%d:%02d:%02d".format(hours, minutes, seconds)
            else "%d:%02d".format(minutes, seconds)
        }
}

/**
 * A page of albums that arrived as headers — the shape `artistAppearsOn` answers
 * in. Distinct from [Page] because this cursor rides the payload rather than the
 * envelope.
 */
@Serializable
data class AlbumPage(
    val items: List<Album> = emptyList(),
    val nextCursor: String? = null,
)

/**
 * One precomputed shortcut on the home screen: a Daily Mix, Replay, Mozz Weekly.
 *
 * Generated on a schedule from the play log rather than fetched, so the grid is
 * instant and works offline. [id] is the set id the tracks are read back with.
 */
@Serializable
data class HomeMix(
    val id: String,
    val title: String,
    val subtitle: String? = null,
    val kind: String,
    val artworkKey: String? = null,
    val generatedAt: Double = 0.0,
)

@Serializable
data class Playlist(
    val id: Long,
    val remoteId: String,
    val serverId: String,
    val title: String,
    val trackCount: Int? = null,
    val artworkKey: String? = null,
    val description: String? = null,
)

/** One line of lyrics. [start] is seconds from the start; null when unsynced. */
@Serializable
data class LyricLine(val text: String, val start: Double? = null)

@Serializable
data class Lyrics(
    val lines: List<LyricLine> = emptyList(),
    val isSynced: Boolean = false,
    val source: String? = null,
    /**
     * When there are no lines, whether to stay quiet rather than say "no lyrics".
     *
     * True for a negative the core does not trust — offline, LRCLIB throttled, a
     * source never asked. Asserting "this song has no lyrics" then would be a
     * lie, and a sticky one.
     */
    val staySilent: Boolean = false,
) {
    val isEmpty: Boolean get() = lines.all { it.text.isBlank() }

    /** The index of the line being sung at [seconds], or null before the first. */
    fun lineIndex(seconds: Double): Int? {
        if (!isSynced) return null
        var found: Int? = null
        lines.forEachIndexed { index, line ->
            val start = line.start ?: return@forEachIndexed
            if (start <= seconds) found = index
        }
        return found
    }
}

/** A colour in 0..1 sRGB, as the core reports it. */
@Serializable
data class ArtworkTone(val red: Double, val green: Double, val blue: Double)

/**
 * The player's backdrop, top to bottom.
 *
 * Derived by the core from the artwork's pixels, so every Mozz client paints the
 * same album the same way. The tuning that decides these — how hard vibrancy is
 * rewarded, how far accents are pulled toward the dominant, how bright a tone may
 * get before white text stops being legible — lives in `MozzCore.ArtworkPalette`
 * rather than being guessed at per platform.
 */
@Serializable
data class ArtworkTones(
    val top: ArtworkTone,
    val middle: ArtworkTone,
    val bottom: ArtworkTone,
)

@Serializable
data class LibraryCounts(val artists: Int, val albums: Int, val tracks: Int)

@Serializable
data class SearchResults(
    val artists: List<Artist> = emptyList(),
    val albums: List<Album> = emptyList(),
    val tracks: List<Track> = emptyList(),
)

@Serializable
data class Server(val id: String, val kind: String, val name: String, val baseUrl: String)

// MARK: - Connection, sync and playback

@Serializable
data class MusicLibrary(val id: String, val name: String)

@Serializable
data class SyncStart(val started: Boolean, val reason: String? = null)

@Serializable
data class SyncStatus(
    val running: Boolean = false,
    val finished: Boolean = false,
    val phase: String? = null,
    val itemsSynced: Int = 0,
    val total: Int? = null,
    val error: String? = null,
    val artists: Int? = null,
    val albums: Int? = null,
    val tracks: Int? = null,
    val playlists: Int? = null,
) {
    /** Short label for a progress row, e.g. "Songs 3,712 / 20,004". */
    fun describe(): String {
        val label = when (phase) {
            "capabilities" -> "Connecting"
            "artists" -> "Artists"
            "albums" -> "Albums"
            "tracks" -> "Songs"
            "playlists" -> "Playlists"
            "pruning" -> "Finishing up"
            "done" -> "Done"
            else -> "Syncing"
        }
        val done = "%,d".format(itemsSynced)
        val all = total?.takeIf { it > 0 }?.let { "%,d".format(it) }
        return if (all != null) "$label $done / $all" else "$label $done"
    }
}

@Serializable
data class StreamSource(
    val url: String,
    val isTranscoded: Boolean = false,
    val sessionID: String? = null,
)

/**
 * A signed-in session.
 *
 * Every field defaults, which looks lax but is the contract: `plexPinCheck`
 * answers `{"url": null}` while the user has not approved the link yet, and that
 * is a *normal* poll result, not a malformed response. A decoder that required
 * `serverId` would turn the ordinary first few seconds of linking into a crash.
 * "Did it work" is [token] being non-empty, and [MozzServer.connect] checks the
 * rest rather than trusting a defaulted value.
 */
@Serializable
internal data class SessionPayload(
    val serverId: String = "",
    val kind: String = "",
    val baseURL: String = "",
    val token: String = "",
    val userID: String? = null,
    val serverName: String = "",
    val clientIdentifier: String = "",
    val accountToken: String? = null,
    /** The server's own machine identifier — see [ServerAccount.machineIdentifier]. */
    val machineIdentifier: String? = null,
)

@Serializable
internal data class PlexPinPayload(
    val pinId: Int,
    val code: String,
    val clientIdentifier: String,
    val linkURL: String? = null,
)

@Serializable
internal data class UrlPayload(val url: String? = null)

@Serializable
internal data class LikePayload(val liked: Boolean = false)

/**
 * What the attached server can do.
 *
 * The like control is why this exists: Jellyfin has a heart, Plex has five
 * stars, Subsonic has both. Asking the core beats guessing from the backend's
 * name, which would be wrong the first time a server grew a feature.
 */
@Serializable
data class ServerCapabilities(
    val backend: String = "",
    val serverVersion: String? = null,
    val supportsFavorites: Boolean = false,
    val supportsRatings: Boolean = false,
    val supportsLyrics: Boolean = false,
    val supportsTranscoding: Boolean = false,
    val supportsOriginalFileDownload: Boolean = false,
) {
    /** A heart where the server has favourites, a star where it has ratings. */
    val likeGlyph: LikeGlyph
        get() = if (supportsFavorites) LikeGlyph.HEART else LikeGlyph.STAR
}

/** How "liked" is drawn, which is a property of the server, not the client. */
enum class LikeGlyph { HEART, STAR }

/** Four stars or more is a like. Matches `LikePolicy.ratingThreshold`. */
private const val LIKE_RATING_THRESHOLD = 4.0

// MARK: - Saved accounts

enum class BackendKind(val wire: String, val display: String) {
    PLEX("plex", "Plex"),
    JELLYFIN("jellyfin", "Jellyfin"),
    SUBSONIC("subsonic", "Subsonic");

    companion object {
        fun parse(wire: String): BackendKind = entries.firstOrNull { it.wire == wire }
            ?: throw MozzCoreException("unknown backend: $wire")
    }
}

/** A saved server, minus its secret. The token lives in the keystore. */
@Serializable
data class ServerAccount(
    val serverId: String,
    val kind: BackendKind,
    val baseUrl: String,
    val serverName: String,
    val clientIdentifier: String,
    val userId: String? = null,
    val username: String? = null,
    val musicSectionId: String? = null,
    /**
     * The Plex **server's** machine identifier — not this app's, which is
     * [clientIdentifier].
     *
     * A Plex server has several addresses and none of them is the server; this
     * is what stays the same when the address changes, so it is what
     * re-resolution matches on. Null for accounts linked before it was recorded.
     */
    val machineIdentifier: String? = null,
)

/**
 * One thing the user has told the app to stop recommending.
 *
 * [scope] is `"track"` or `"artist"`; [ref] is that thing's remote id, which is
 * what reverses the suppression.
 */
@Serializable
data class Suppression(
    val scope: String,
    val ref: String,
    val createdAt: Double = 0.0,
    /** The name, resolved by the core. Falls back to [ref] when the catalogue no longer has the row. */
    val title: String = "",
    /** The artist name, for a track. Null for an artist. */
    val subtitle: String? = null,
    val artworkKey: String? = null,
) {
    val isArtist: Boolean get() = scope == "artist"
    val label: String get() = title.ifEmpty { ref }
}

/** An in-progress Plex link: show [linkUrl] to the user, then poll. */
data class PlexLink(
    val pinId: Int,
    val code: String,
    val clientIdentifier: String,
    val linkUrl: String?,
)
