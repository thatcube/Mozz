package com.thatcube.mozz.playback

import android.content.ComponentName
import android.content.Context
import androidx.core.net.toUri
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.google.common.util.concurrent.MoreExecutors
import com.thatcube.mozz.core.MozzServer
import com.thatcube.mozz.core.PlayEventKind
import com.thatcube.mozz.core.MozzLibrary
import com.thatcube.mozz.core.Track
import com.thatcube.mozz.ui.ToastAction
import com.thatcube.mozz.ui.ToastCenter
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

/** What the UI needs to know about playback, and nothing more. */
data class PlaybackState(
    val track: Track? = null,
    val queue: List<Track> = emptyList(),
    val indexInQueue: Int = 0,
    val isPlaying: Boolean = false,
    /**
     * What the player is *trying* to do, which is not the same as what it is
     * doing: `isPlaying` goes false the moment a track starts buffering. Anything
     * in the UI that reacts to "is this playing" wants this instead, or it
     * flickers on every track change.
     */
    val intendsToPlay: Boolean = false,
    val positionMillis: Long = 0,
    val durationMillis: Long = 0,
    val shuffle: Boolean = false,
    val repeat: RepeatMode = RepeatMode.OFF,
    val hasNext: Boolean = false,
    val hasPrevious: Boolean = false,
) {
    /** 0f..1f, and 0 rather than NaN before the duration is known. */
    val progress: Float
        get() = if (durationMillis > 0) {
            (positionMillis.toFloat() / durationMillis).coerceIn(0f, 1f)
        } else {
            0f
        }
}

enum class RepeatMode { OFF, ALL, ONE }

/**
 * The bridge between "the user tapped a song" and the media session.
 *
 * Stream URLs are resolved through the core, not built here — `streamURL` is
 * where transcoding decisions and the server's own addressing live, and every
 * client asks the same way.
 */
class PlayerController(
    private val context: Context,
    private val server: MozzServer,
    private val library: MozzLibrary,
    private val toasts: ToastCenter,
    private val scope: CoroutineScope,
) {
    private var controller: MediaController? = null
    private var queue: List<Track> = emptyList()

    /** The retry schedule currently working against a failure, if any. */
    private var retryJob: Job? = null
    private var attemptsSpent = 0

    private val _state = MutableStateFlow(PlaybackState())
    val state: StateFlow<PlaybackState> = _state.asStateFlow()

    /** The device id this installation reports in listening history. */
    /**
     * This installation's id, as history and likes attribute them.
     *
     * Exposed because a like is a recommender signal too, and it is attributed
     * the same way a play is.
     */
    val deviceId: String by lazy {
        android.provider.Settings.Secure.getString(
            context.contentResolver,
            android.provider.Settings.Secure.ANDROID_ID,
        ) ?: "android"
    }

    suspend fun connect() {
        // `!= null` is not the same as usable. When the session goes away — the
        // service stopped while nothing was playing, say — the controller we
        // hold stays non-null and every command on it becomes a silent no-op.
        // Left unchecked that is a player which never works again and never says
        // why, until the app is killed.
        controller?.let {
            if (it.isConnected) return
            it.release()
            controller = null
        }
        val token = SessionToken(
            context,
            ComponentName(context, MozzPlaybackService::class.java),
        )
        val media = suspendCancellableCoroutine<MediaController?> { continuation ->
            val future = MediaController.Builder(context, token).buildAsync()
            future.addListener(
                { continuation.resume(runCatching { future.get() }.getOrNull()) },
                MoreExecutors.directExecutor(),
            )
        } ?: return

        controller = media
        media.addListener(object : Player.Listener {
            override fun onEvents(player: Player, events: Player.Events) {
                publish(player)
            }

            override fun onPlayerError(error: PlaybackException) {
                // The only breadcrumb anyone gets when this happens on a phone
                // that is not plugged in. The error code is the part worth
                // having: the message shown to the user is deliberately vague,
                // and the code is what says whether it was the network, the
                // server, or the file.
                android.util.Log.w(
                    "MozzPlayback",
                    "playback failed (code ${error.errorCode} ${error.errorCodeName})",
                    error,
                )
                noteFailure(describe(error))
            }

            override fun onPlaybackStateChanged(playbackState: Int) {
                // Sound came out, so whatever went wrong is over. Clearing on
                // READY rather than on the retry call means a retry that fails
                // again never gets credited with fixing anything.
                if (playbackState == Player.STATE_READY) clearFailure()
            }

            override fun onMediaItemTransition(item: MediaItem?, reason: Int) {
                // A track that ran out rather than being skipped is a completed
                // play, and the history log is what play counts and the
                // recommender are built from — on every platform, from the same
                // events. See ADR-0011.
                if (reason == Player.MEDIA_ITEM_TRANSITION_REASON_AUTO) {
                    val finished = queue.getOrNull(previousIndex(media))
                    if (finished != null) record(finished, PlayEventKind.COMPLETED)
                }
                publish(media)
            }
        })
        publish(media)

        // Player.Listener fires on events, not on the passage of time, so a
        // scrubber needs its own clock. Only while playing: a paused player's
        // position does not move, and a timer that runs anyway is a timer that
        // runs all night.
        scope.launch {
            while (true) {
                delay(POSITION_TICK_MS)
                val player = controller ?: continue
                if (player.isPlaying) publish(player)
            }
        }
    }

    private fun previousIndex(player: Player): Int =
        (player.currentMediaItemIndex - 1).coerceAtLeast(0)

    /**
     * Play [tracks] starting at [startIndex].
     *
     * The tapped track is resolved and started *first*, on its own, and the rest
     * of the queue is filled in behind it. Resolving the whole queue up front
     * meant a tap on a 158-song list waited for 158 `streamURL` round trips
     * before making a sound — which read exactly like the app ignoring you, and
     * then playing a song you had given up on.
     *
     * The order is preserved: tracks after the tapped one are appended, tracks
     * before it are inserted ahead of it. Media3 keeps playing the current item
     * through both, so the queue grows around the song without interrupting it.
     */
    fun play(tracks: List<Track>, startIndex: Int) = scope.launch {
        connect()
        val media = controller ?: return@launch
        val window = tracks.take(MAX_QUEUE)
        if (window.isEmpty()) return@launch
        val start = startIndex.coerceIn(0, window.size - 1)

        clearFailure()
        val first = window[start]
        val firstItem = mediaItem(first)
        if (firstItem == null) {
            // No address for the very track that was tapped. Silently returning
            // here is what made an unreachable server look like an app that
            // ignores you.
            noteFailure(UNREACHABLE)
            return@launch
        }

        queue = listOf(first)
        media.setMediaItems(listOf(firstItem), 0, 0)
        media.prepare()
        media.play()
        record(first, PlayEventKind.STARTED)

        // Everything after the tapped track, in order, appended as it resolves.
        val after = window.drop(start + 1).map { it to async(Dispatchers.IO) { mediaItem(it) } }
        val resolvedAfter = after.mapNotNull { (track, item) -> item.await()?.let { track to it } }
        if (resolvedAfter.isNotEmpty()) {
            media.addMediaItems(resolvedAfter.map { it.second })
            queue = queue + resolvedAfter.map { it.first }
        }

        // Then what came before it, inserted ahead so "previous" works.
        val before = window.take(start).map { it to async(Dispatchers.IO) { mediaItem(it) } }
        val resolvedBefore = before.mapNotNull { (track, item) -> item.await()?.let { track to it } }
        if (resolvedBefore.isNotEmpty()) {
            media.addMediaItems(0, resolvedBefore.map { it.second })
            queue = resolvedBefore.map { it.first } + queue
        }

        publish(media)
    }

    /**
     * One track, addressed and described.
     *
     * Returns null when the URL will not resolve, and the caller drops the track
     * rather than leaving a hole in the queue that stops playback dead when it is
     * reached.
     */
    private suspend fun mediaItem(track: Track): MediaItem? = runCatching {
        val source = server.stream(track.serverId, track.remoteId)
        // The same artwork the app shows, so the notification, the lock screen
        // and Mozz's own player agree. Without this the system surfaces fall
        // back to whatever art is embedded in the file, which is often absent
        // and sometimes a different picture than the server's.
        val artwork = track.artworkKey?.let { key ->
            runCatching { server.artworkUrl(track.serverId, key, ARTWORK_SIZE) }.getOrNull()
        }
        MediaItem.Builder()
            .setUri(source.url)
            .setMediaId(track.remoteId)
            .setMediaMetadata(
                MediaMetadata.Builder()
                    .setTitle(track.title)
                    .setArtist(track.artistName)
                    .setAlbumTitle(track.albumTitle)
                    .apply { artwork?.let { setArtworkUri(it.toUri()) } }
                    .build()
            )
            .build()
    }.getOrNull()

    // MARK: Failure and recovery

    /**
     * Media3 parks the player in IDLE after a fatal error, and IDLE ignores
     * everything: play, seek and skip all return without doing anything. Only
     * `prepare()` gets it moving again, so every control that could be pressed
     * in this state has to check for it first. Without that, one dropped
     * connection leaves the whole transport dead until the app is restarted —
     * which is exactly what it looks like from the outside.
     */
    private fun Player.isStalled(): Boolean =
        playbackState == Player.STATE_IDLE && playerError != null

    /**
     * Say what went wrong, and start — or continue — working on it.
     *
     * At most two toasts per outage, which is the whole point of counting the
     * attempts. The first says what happened while the automatic retries run
     * quietly behind it; the last, once those are spent, is the one that offers
     * the button. A toast per attempt would be three apologies for one problem.
     */
    private fun noteFailure(message: String) {
        val willRetry = attemptsSpent < RETRY_DELAYS_MS.size
        if (attemptsSpent == 0) {
            toasts.show(message)
        } else if (!willRetry) {
            toasts.show(message, ToastAction("Retry") { retry() })
        }
        if (!willRetry) return

        val delayMs = RETRY_DELAYS_MS[attemptsSpent]
        attemptsSpent++
        retryJob?.cancel()
        retryJob = scope.launch {
            delay(delayMs)
            reload()
        }
    }

    private fun clearFailure() {
        retryJob?.cancel()
        retryJob = null
        attemptsSpent = 0
    }

    /**
     * Try the current track again, with a freshly resolved URL.
     *
     * Re-resolving rather than just re-preparing, because the URL is the thing
     * most likely to have gone stale: it carries the server's token and, on a
     * transcode, a session id. Preparing the same dead address again would only
     * reproduce the same failure more slowly.
     *
     * The position is kept, so a drop-out thirty seconds into a song resumes
     * thirty seconds into the song.
     */
    private suspend fun reload() {
        val media = controller ?: return
        val index = media.currentMediaItemIndex
        val position = media.currentPosition.coerceAtLeast(0)
        val track = queue.getOrNull(index)

        if (track != null) {
            val fresh = mediaItem(track)
            if (fresh == null) {
                // Could not even get an address. Same failure, next backoff.
                noteFailure(UNREACHABLE)
                return
            }
            media.replaceMediaItem(index, fresh)
        }
        media.seekTo(index, position)
        media.prepare()
        media.play()
    }

    /**
     * The person asked for this one, so the backoff starts over.
     *
     * A retry someone pressed is worth more patience than the third automatic
     * one: they have new information — they can see the wifi is back — that the
     * schedule cannot.
     */
    fun retry() = scope.launch {
        connect()
        attemptsSpent = 0
        retryJob?.cancel()
        reload()
    }

    /** What went wrong, in a form worth putting in front of someone. */
    private fun describe(error: PlaybackException): String = when (error.errorCode) {
        PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS -> "The server refused this track"
        PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND -> "This track is not on the server"
        // Everything else in the IO family is some flavour of "the bytes never
        // arrived", and the distinctions below that are not ones anybody
        // holding a phone can act on. Deliberately the whole range rather than
        // the two or three codes seen so far: a failure classified as "unknown"
        // because it was a socket error nobody had enumerated is how this ends
        // up saying nothing useful again.
        in PlaybackException.ERROR_CODE_IO_UNSPECIFIED..
            PlaybackException.ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE -> UNREACHABLE
        else -> "This track would not play"
    }

    fun togglePlayPause() {
        val media = controller ?: return
        // Play, on a player stopped by an error, means "try again" — which is
        // what anyone pressing it after a failure is asking for.
        if (media.isStalled()) retry()
        else if (media.isPlaying) media.pause() else media.play()
    }

    fun next() {
        val media = controller ?: return
        media.seekToNextMediaItem()
        if (media.isStalled()) media.prepare()
    }

    /**
     * Restart the track, or go back one if it has only just started.
     *
     * What every music player does, and what people expect: "previous" a minute
     * into a song means "play this from the top", not "skip the song I am
     * listening to".
     */
    fun previous() {
        val media = controller ?: return
        if (media.currentPosition > RESTART_THRESHOLD_MS || !media.hasPreviousMediaItem()) {
            media.seekTo(0)
        } else {
            media.seekToPreviousMediaItem()
        }
        if (media.isStalled()) media.prepare()
    }

    fun seekTo(millis: Long) {
        controller?.seekTo(millis.coerceAtLeast(0))
    }

    /** Seek by fraction, for a scrubber that knows where it is but not how long. */
    fun seekToFraction(fraction: Float) {
        val media = controller ?: return
        val duration = media.duration
        if (duration > 0) media.seekTo((duration * fraction.coerceIn(0f, 1f)).toLong())
    }

    fun toggleShuffle() {
        val media = controller ?: return
        media.shuffleModeEnabled = !media.shuffleModeEnabled
    }

    /** Off, then all, then one — the order every player cycles them in. */
    fun cycleRepeat() {
        val media = controller ?: return
        media.repeatMode = when (media.repeatMode) {
            Player.REPEAT_MODE_OFF -> Player.REPEAT_MODE_ALL
            Player.REPEAT_MODE_ALL -> Player.REPEAT_MODE_ONE
            else -> Player.REPEAT_MODE_OFF
        }
    }

    /** Jump within the queue that is already loaded. */
    fun playQueueIndex(index: Int) {
        val media = controller ?: return
        if (index in queue.indices) {
            media.seekTo(index, 0)
            if (media.isStalled()) media.prepare()
            media.play()
        }
    }

    /**
     * Move a track within the queue.
     *
     * Both lists move together. Media3 owns the playback order and `queue` is the
     * Track-level mirror the UI reads from; letting them drift by one means the
     * row you dragged is not the song that plays.
     */
    fun moveQueueItem(from: Int, to: Int) {
        val media = controller ?: return
        if (from !in queue.indices || to !in queue.indices || from == to) return
        queue = queue.toMutableList().apply { add(to, removeAt(from)) }
        media.moveMediaItem(from, to)
        publish(media)
    }

    /** Drop everything already played, leaving the current track at the top. */
    fun clearHistory() {
        val media = controller ?: return
        val current = media.currentMediaItemIndex
        if (current <= 0) return
        queue = queue.drop(current)
        media.removeMediaItems(0, current)
        publish(media)
    }

    /** Drop everything after the current track, leaving it playing. */
    fun clearQueue() {
        val media = controller ?: return
        val current = media.currentMediaItemIndex
        val end = media.mediaItemCount
        if (current + 1 >= end) return
        queue = queue.take(current + 1)
        media.removeMediaItems(current + 1, end)
        publish(media)
    }

    fun release() {
        retryJob?.cancel()
        retryJob = null
        controller?.release()
        controller = null
    }

    private fun publish(player: Player) {
        _state.value = PlaybackState(
            track = queue.getOrNull(player.currentMediaItemIndex),
            queue = queue,
            indexInQueue = player.currentMediaItemIndex,
            isPlaying = player.isPlaying,
            // Distinct from `isPlaying`, which goes false the moment a track
            // starts buffering. Anything that reacts to "is this playing" in the
            // UI wants this instead, or it flickers on every track change.
            intendsToPlay = player.playWhenReady,
            positionMillis = player.currentPosition.coerceAtLeast(0),
            durationMillis = player.duration.takeIf { it > 0 } ?: 0,
            shuffle = player.shuffleModeEnabled,
            repeat = when (player.repeatMode) {
                Player.REPEAT_MODE_ALL -> RepeatMode.ALL
                Player.REPEAT_MODE_ONE -> RepeatMode.ONE
                else -> RepeatMode.OFF
            },
            hasNext = player.hasNextMediaItem(),
            hasPrevious = player.hasPreviousMediaItem(),
        )
    }

    private fun record(track: Track, kind: PlayEventKind) = scope.launch {
        runCatching {
            library.recordPlayEvent(
                serverId = track.serverId,
                remoteId = track.remoteId,
                kind = kind,
                deviceId = deviceId,
                deviceName = android.os.Build.MODEL,
                durationSeconds = track.durationSeconds,
            )
        }
    }

    private companion object {
        // A screen's worth of queue, not a whole library. 200 resolved URLs is
        // fast; 20,000 would not be, and nobody queues their entire collection
        // from a tap.
        const val MAX_QUEUE = 200
        const val POSITION_TICK_MS = 500L
        // Big enough for a lock screen on a tall phone, small enough that a
        // queue's worth of them is not a download.
        const val ARTWORK_SIZE = 768
        const val RESTART_THRESHOLD_MS = 3000L

        /**
         * What a server that will not answer is called, wherever we have to say
         * it. One phrase, because it is one situation however we found out.
         */
        const val UNREACHABLE = "Can't reach the server"

        /**
         * How long to wait before each automatic retry.
         *
         * Three tries over about twenty seconds, widening as they go. Short
         * enough that a wifi handover or a server hiccup is fixed before anyone
         * reaches for the phone; finite because a server that is genuinely down
         * should not be polled all night, and the play button is a better retry
         * than a loop nobody asked for.
         */
        val RETRY_DELAYS_MS = longArrayOf(2_000, 6_000, 15_000)
    }
}
