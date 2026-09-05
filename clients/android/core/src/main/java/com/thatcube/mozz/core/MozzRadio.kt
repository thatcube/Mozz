package com.thatcube.mozz.core

import kotlinx.serialization.Serializable

/**
 * An endless station, driven entirely by the core.
 *
 * The three tiers a station picks from — what the audio actually sounds like,
 * then what other listeners play together, then genre as a floor — live in
 * `RadioStation` in the shared core. This class deliberately holds no seed, no
 * played-set and no logic of its own: the moment it did, Android would be
 * playing something subtly different from the iPhone for the same song, and
 * nothing would report that as a bug.
 *
 * So the shape here is small on purpose. [start] answers with the first batch,
 * [next] with the next one, and the core remembers everything in between.
 */
class MozzRadio(private val core: MozzCore) {

    /**
     * Start a station from a track.
     *
     * The batch that comes back deliberately EXCLUDES the seed: a caller that
     * wants "start radio from this song" plays the song and then this, and one
     * that wants "play me something like this" plays only this.
     */
    suspend fun startFromTrack(serverId: String, remoteId: String, limit: Int = 30): List<Track> =
        core.call<RadioBatchPayload>(
            CoreRequest(cmd = "radioStart", serverId = serverId, remoteId = remoteId, limit = limit)
        )?.tracks ?: emptyList()

    /**
     * Start a station from an artist.
     *
     * Only the id is sent. The seed's genres are derived in the core from the
     * artist's own tracks, which is the vocabulary the candidates are scored
     * in — passing the row's tags instead would compare two different
     * vocabularies and quietly narrow the station.
     */
    suspend fun startFromArtist(serverId: String, artistRemoteId: String, limit: Int = 30): List<Track> =
        core.call<RadioBatchPayload>(
            CoreRequest(
                cmd = "radioStart", serverId = serverId,
                artistRemoteId = artistRemoteId, limit = limit,
            )
        )?.tracks ?: emptyList()

    /**
     * The next batch, excluding everything this station has already played.
     *
     * Empty is an ordinary answer, not a failure: it means no station is
     * running, or that one was started or stopped while this was in flight.
     */
    suspend fun next(limit: Int = 20): List<Track> =
        core.call<RadioBatchPayload>(CoreRequest(cmd = "radioNext", limit = limit))
            ?.tracks ?: emptyList()

    /** Forget the running station — the user played something directly. */
    suspend fun stop() {
        core.call<Map<String, Boolean>>(CoreRequest(cmd = "radioStop"))
    }

    /** What is playing from a station right now, for a label or a stop control. */
    suspend fun state(): RadioState? =
        core.call<RadioState>(CoreRequest(cmd = "radioState"))?.takeIf { it.active }
}

@Serializable
internal data class RadioBatchPayload(
    val remoteIds: List<String> = emptyList(),
    val tracks: List<Track> = emptyList(),
)

/** A running station, as the core describes it. */
@Serializable
data class RadioState(
    val active: Boolean = false,
    /** What it was seeded from — a song title or an artist name. */
    val title: String? = null,
    val serverId: String? = null,
    /** How many tracks it has handed out, so a fresh station reads differently
     *  from one that has been running all afternoon. */
    val surfaced: Int? = null,
)
