package com.thatcube.mozz.continuity

import android.util.Log
import com.thatcube.mozz.core.ContinuityDescriptor
import com.thatcube.mozz.core.ContinuityItemInput
import com.thatcube.mozz.core.ContinuityQueueInput
import com.thatcube.mozz.core.ContinuitySnapshot
import com.thatcube.mozz.core.MozzContinuity
import com.thatcube.mozz.core.ServerAccount
import com.thatcube.mozz.core.Track
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID

/** Why a checkpoint is being written. */
enum class CheckpointReason { TRACK_CHANGED, SEEKED, TRANSPORT_CHANGED, QUEUE_CHANGED, PERIODIC }

/** A resume this device is willing to offer, already phrased for a person. */
data class ContinuityOffer(
    val snapshot: ContinuitySnapshot,
    val headline: String,
    val subtitle: String,
    val artworkKey: String?,
)

/**
 * Cross-device resume, from this phone's side (ADR-0010).
 *
 * Two halves that barely touch: publishing where this device got to, and
 * deciding whether what another device published is worth offering. Both are
 * deliberately incapable of stopping playback — a checkpoint carries resume
 * information and never ownership, which is what makes one shared slot with
 * last-writer-wins safe.
 *
 * Jellyfin and Subsonic hold the slot. Plex has no store for it: the core
 * answers that as a failure, and every call here treats a failure as "nothing
 * there" rather than as something to report. A Plex user should see no sign
 * this exists.
 */
class ContinuityCoordinator(
    private val continuity: MozzContinuity,
    private val deviceId: String,
    private val deviceName: String,
) {

    /** One write at a time: transitions fire faster than a round trip returns. */
    private val gate = Mutex()

    /** Identifies this run of playback. Re-minted whenever a new one starts. */
    private var runId = UUID.randomUUID().toString()
    private var sequence = 0L
    private var lastPeriodicMS = 0L

    /**
     * The hash of the queue last written, so an unchanged queue is not sent
     * again. A queue is the expensive half of a checkpoint and changes far
     * less often than a position does.
     */
    private var writtenQueueHash: String? = null

    /**
     * Nothing is published before the remote state has been read once.
     *
     * A phone paused in a pocket while another device took over would otherwise
     * come back and clobber the newer session with what it remembered.
     */
    private var reconciled = false

    fun beginRun() {
        runId = UUID.randomUUID().toString()
        sequence = 0
        lastPeriodicMS = 0
        writtenQueueHash = null
    }

    /**
     * Read the shared slot and decide whether to offer what is there.
     *
     * Returns null for every ordinary reason as well as every failure: no
     * checkpoint, this device's own, too old, or something is already playing
     * here.
     */
    suspend fun reconcile(
        serverId: String,
        isPlayingLocally: Boolean,
        nowMS: Long = System.currentTimeMillis(),
    ): ContinuityOffer? {
        val snapshot = runCatching { continuity.load(serverId) }.getOrNull()
        reconciled = true
        return offerFor(snapshot, deviceId, isPlayingLocally, nowMS)
    }

    /**
     * Write where this device has got to.
     *
     * Best effort throughout. A checkpoint that does not land is superseded by
     * the next one, and there is nothing a listener could do about a failure.
     */
    suspend fun checkpoint(
        reason: CheckpointReason,
        account: ServerAccount,
        queue: List<Track>,
        indexInQueue: Int,
        positionMS: Long,
        isPlaying: Boolean,
        repeatMode: String,
        isShuffled: Boolean,
        nowMS: Long = System.currentTimeMillis(),
    ) {
        if (!reconciled) return
        val current = queue.getOrNull(indexInQueue) ?: return
        // A steadily playing track re-checkpoints on a timer rather than on
        // every position tick, which arrives twice a second.
        if (reason == CheckpointReason.PERIODIC && nowMS - lastPeriodicMS < PERIODIC_INTERVAL_MS) return

        gate.withLock {
            if (reason == CheckpointReason.PERIODIC) lastPeriodicMS = nowMS
            sequence += 1

            val input = queueInput(account, queue, indexInQueue, repeatMode, isShuffled)
            val hash = runCatching { continuity.queueHash(input) }.getOrNull()?.queueHash
            // Send the queue only when it is not the one already stored. The
            // position moves constantly; the queue rarely does.
            val queueChanged = hash == null || hash != writtenQueueHash

            val saved = runCatching {
                continuity.save(
                    serverId = account.serverId,
                    playbackRunId = runId,
                    deviceId = deviceId,
                    deviceName = deviceName,
                    cursorSequence = sequence,
                    capturedAtMS = nowMS,
                    state = if (isPlaying) "playing" else "paused",
                    currentRemoteId = current.remoteId,
                    currentAbsoluteIndex = indexInQueue,
                    positionMS = positionMS,
                    queue = if (queueChanged) input else null,
                )
            }.onFailure {
                // Plex has no store, so this is the ordinary state there and
                // not worth a line every twenty seconds.
                Log.d(TAG, "no continuity store for ${account.serverName}")
            }.getOrNull()

            if (queueChanged) writtenQueueHash = saved?.queueHash ?: hash
        }
    }

    private fun queueInput(
        account: ServerAccount,
        queue: List<Track>,
        indexInQueue: Int,
        repeatMode: String,
        isShuffled: Boolean,
    ) = ContinuityQueueInput(
        descriptor = ContinuityDescriptor(kind = "queue"),
        items = queue.mapIndexed { index, track ->
            ContinuityItemInput(
                remoteId = track.remoteId,
                backend = account.kind.wire,
                // The server's own identity, not the row id derived from the
                // address it answers at today: a checkpoint has to survive the
                // same library being reached over a different route.
                serverId = account.machineIdentifier.orEmpty(),
                accountId = account.userId ?: account.username.orEmpty(),
                baseOrdinal = index,
                title = track.title,
                artist = track.artistName,
                durationMS = (track.durationSeconds * 1000).toLong(),
                artworkKey = track.artworkKey,
            )
        },
        repeatMode = repeatMode,
        isShuffled = isShuffled,
        totalCount = queue.size,
        startAbsoluteIndex = indexInQueue,
    )

    companion object {
        private const val TAG = "MozzContinuity"

        /** How often a steadily playing track re-checkpoints. Matches iOS. */
        const val PERIODIC_INTERVAL_MS = 20_000L

        /** Older than this and nobody is coming back to it. Matches both shells. */
        const val MAX_OFFER_AGE_MS = 14L * 24 * 60 * 60 * 1000

        /**
         * Whether a snapshot is worth putting in front of someone.
         *
         * The same four rules the iPhone and the desktop apply, in the same
         * order — this is a third statement of them, which is a drift risk
         * worth naming: see `ContinuityCoordinator.reconcile` in Swift and
         * `ContinuityPresentation.OfferFor` in C#.
         */
        fun offerFor(
            snapshot: ContinuitySnapshot?,
            localDeviceId: String,
            isPlayingLocally: Boolean,
            nowMS: Long,
        ): ContinuityOffer? {
            if (snapshot == null) return null
            val cursor = snapshot.cursor
            if (cursor.current.remoteId.isEmpty()) return null
            // Never offer to continue what this device itself last wrote.
            if (cursor.deviceId.isNotEmpty() && cursor.deviceId == localDeviceId) return null
            // A device already playing is never interrupted: an offer there is
            // an invitation to stop what you are listening to.
            if (isPlayingLocally) return null
            if (cursor.capturedAtMS > 0 && nowMS - cursor.capturedAtMS > MAX_OFFER_AGE_MS) return null

            val item = snapshot.queue?.items?.firstOrNull { it.locator.remoteId == cursor.current.remoteId }
            val hydrated = snapshot.hydratedTracks.firstOrNull { it.remoteId == cursor.current.remoteId }
            val title = item?.title?.ifBlank { null } ?: hydrated?.title
            val artist = item?.artist?.ifBlank { null } ?: hydrated?.artistName
            val subtitle = buildString {
                append(
                    when {
                        title == null -> "Track and position"
                        artist.isNullOrBlank() -> title
                        else -> "$title · $artist"
                    }
                )
                if (snapshot.queue == null || snapshot.isQueueMissing) append(" — track only")
            }
            val device = cursor.deviceName.trim().ifEmpty { "another device" }
            return ContinuityOffer(
                snapshot = snapshot,
                headline = "Resume from $device, ${age(cursor.capturedAtMS, nowMS)} ago",
                subtitle = subtitle,
                artworkKey = hydrated?.artworkKey ?: item?.artworkKey,
            )
        }

        /** "just now", "6 minutes", "2 hours", "3 days" — as on the desktop. */
        fun age(capturedAtMS: Long, nowMS: Long): String {
            if (capturedAtMS <= 0) return "just now"
            val seconds = ((nowMS - capturedAtMS) / 1000).coerceAtLeast(0)
            return when {
                seconds < 60 -> "just now"
                seconds < 3600 -> unit(Math.round(seconds / 60.0).toInt(), "minute")
                seconds < 86_400 -> unit(Math.round(seconds / 3600.0).toInt(), "hour")
                else -> unit(Math.round(seconds / 86_400.0).toInt(), "day")
            }
        }

        private fun unit(count: Int, noun: String) =
            if (count == 1) "1 $noun" else "$count ${noun}s"
    }
}
