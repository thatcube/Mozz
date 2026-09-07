package com.thatcube.mozz.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// MARK: - What a checkpoint is made of

@Serializable
data class ContinuityFingerprint(
    val backend: String = "",
    @SerialName("serverID") val serverId: String = "",
    @SerialName("accountID") val accountId: String = "",
)

@Serializable
data class ContinuityTrackLocator(
    val server: ContinuityFingerprint = ContinuityFingerprint(),
    @SerialName("remoteID") val remoteId: String = "",
)

@Serializable
data class ContinuityCursor(
    @SerialName("playbackRunID") val playbackRunId: String = "",
    @SerialName("deviceID") val deviceId: String = "",
    val deviceName: String = "",
    val deviceKind: String? = null,
    val cursorSequence: Long = 0,
    val capturedAtMS: Long = 0,
    /** `playing`, `paused` or `stopped`. */
    val state: String = "",
    val current: ContinuityTrackLocator = ContinuityTrackLocator(),
    val currentAbsoluteIndex: Int = 0,
    val positionMS: Long = 0,
    val queueHash: String? = null,
)

@Serializable
data class ContinuityItem(
    val locator: ContinuityTrackLocator = ContinuityTrackLocator(),
    val baseOrdinal: Int = 0,
    val title: String = "",
    val artist: String = "",
    val durationMS: Long = 0,
    val artworkKey: String? = null,
)

@Serializable
data class ContinuityQueue(
    val queueHash: String = "",
    val items: List<ContinuityItem> = emptyList(),
    val startAbsoluteIndex: Int = 0,
    val totalCount: Int = 0,
    val isTruncated: Boolean = false,
    val repeatMode: String = "off",
    val isShuffled: Boolean = false,
)

@Serializable
data class ContinuitySnapshot(
    val cursor: ContinuityCursor = ContinuityCursor(),
    val queue: ContinuityQueue? = null,
    /** The cursor named a queue the store could not pair with it. */
    val isQueueMissing: Boolean = false,
    /**
     * Tracks the store already had. Subsonic's `getPlayQueue` returns whole
     * song entries, so hydration there is free and must not be re-fetched one
     * at a time.
     */
    val hydratedTracks: List<Track> = emptyList(),
)

// MARK: - What this device sends

@Serializable
data class ContinuityDescriptor(
    val kind: String = "queue",
    @SerialName("sourceID") val sourceId: String? = null,
    @SerialName("sourceRevision") val sourceRevision: String? = null,
)

@Serializable
data class ContinuityItemInput(
    @SerialName("remoteID") val remoteId: String,
    val backend: String,
    @SerialName("serverID") val serverId: String,
    @SerialName("accountID") val accountId: String,
    val baseOrdinal: Int,
    val title: String,
    val artist: String,
    val durationMS: Long,
    val artworkKey: String? = null,
)

@Serializable
data class ContinuityQueueInput(
    val descriptor: ContinuityDescriptor,
    val items: List<ContinuityItemInput>,
    val repeatMode: String,
    val isShuffled: Boolean,
    val totalCount: Int,
    @SerialName("startAbsoluteIndex") val startAbsoluteIndex: Int? = null,
    @SerialName("windowStartAbsoluteIndex") val windowStartAbsoluteIndex: Int? = null,
    val isTruncated: Boolean? = null,
)

@Serializable
data class ContinuityHash(
    val queueHash: String = "",
    val canonicalByteCount: Int = 0,
)

@Serializable
data class ContinuitySaveResult(
    val saved: Boolean = false,
    val queueHash: String? = null,
)

/**
 * Cross-device resume (ADR-0010).
 *
 * One shared slot on the user's own server, written by whichever device is
 * playing and read by whichever device is picked up next. Deliberately narrow:
 * it carries resume information and never ownership — nothing read through it
 * may stop playback or make a playing device yield, which is what makes
 * last-writer-wins on a single slot safe.
 *
 * Jellyfin and Subsonic hold the slot. Plex has no store for it, and the core
 * says so rather than pretending; a caller should treat that failure as "not
 * here" and not as an error worth showing anyone.
 */
class MozzContinuity(private val core: MozzCore) {

    /** The stored checkpoint, or null when there is none. */
    suspend fun load(serverId: String): ContinuitySnapshot? =
        core.call(CoreRequest(cmd = "continuityLoad", serverId = serverId))

    /**
     * What a queue hashes to, so an unchanged one is not sent again.
     *
     * A queue is the expensive half of a checkpoint and it changes far less
     * often than a position does.
     */
    suspend fun queueHash(queue: ContinuityQueueInput): ContinuityHash? =
        core.call(CoreRequest(cmd = "continuityQueueHash", queue = queue))

    suspend fun save(
        serverId: String,
        playbackRunId: String,
        deviceId: String,
        deviceName: String,
        deviceKind: String = "phone",
        cursorSequence: Long,
        capturedAtMS: Long,
        state: String,
        currentRemoteId: String,
        currentAbsoluteIndex: Int,
        positionMS: Long,
        queue: ContinuityQueueInput? = null,
    ): ContinuitySaveResult? = core.call(
        CoreRequest(
            cmd = "continuitySave",
            serverId = serverId,
            playbackRunID = playbackRunId,
            deviceId = deviceId,
            deviceName = deviceName,
            kind = deviceKind,
            cursorSequence = cursorSequence,
            capturedAtMS = capturedAtMS,
            state = state,
            currentRemoteID = currentRemoteId,
            currentAbsoluteIndex = currentAbsoluteIndex,
            positionMS = positionMS,
            queue = queue,
        )
    )
}
