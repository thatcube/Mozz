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
    val artworkKey: String? = null,
    val size: Int? = null,
    val maxBitrateKbps: Int? = null,

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
    val id: Long,
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
    val id: Long,
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
    val trackNumber: Int? = null,
    val discNumber: Int? = null,
    val durationSeconds: Double = 0.0,
    val artworkKey: String? = null,
    val isFavorite: Boolean = false,
    val normalizationGainDB: Double? = null,
) {
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
)

/** An in-progress Plex link: show [linkUrl] to the user, then poll. */
data class PlexLink(
    val pinId: Int,
    val code: String,
    val clientIdentifier: String,
    val linkUrl: String?,
)
