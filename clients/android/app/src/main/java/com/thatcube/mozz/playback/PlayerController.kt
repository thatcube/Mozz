package com.thatcube.mozz.playback

import android.content.ComponentName
import android.content.Context
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.google.common.util.concurrent.MoreExecutors
import com.thatcube.mozz.core.MozzServer
import com.thatcube.mozz.core.PlayEventKind
import com.thatcube.mozz.core.MozzLibrary
import com.thatcube.mozz.core.Track
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

/** What the UI needs to know about playback, and nothing more. */
data class PlaybackState(
    val track: Track? = null,
    val isPlaying: Boolean = false,
    val positionMillis: Long = 0,
    val durationMillis: Long = 0,
)

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
    private val scope: CoroutineScope,
) {
    private var controller: MediaController? = null
    private var queue: List<Track> = emptyList()

    private val _state = MutableStateFlow(PlaybackState())
    val state: StateFlow<PlaybackState> = _state.asStateFlow()

    /** The device id this installation reports in listening history. */
    private val deviceId: String by lazy {
        android.provider.Settings.Secure.getString(
            context.contentResolver,
            android.provider.Settings.Secure.ANDROID_ID,
        ) ?: "android"
    }

    suspend fun connect() {
        if (controller != null) return
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
    }

    private fun previousIndex(player: Player): Int =
        (player.currentMediaItemIndex - 1).coerceAtLeast(0)

    /**
     * Play [tracks] starting at [startIndex].
     *
     * Every URL is resolved up front rather than lazily. `streamURL` is a local
     * decision for Plex — it composes an addressed URL, it does not fetch audio —
     * so resolving a screen's worth costs little, and resolving lazily would mean
     * a gap between one track ending and the next being addressable, which is
     * exactly what near-gapless playback must not have.
     */
    fun play(tracks: List<Track>, startIndex: Int) = scope.launch {
        connect()
        val media = controller ?: return@launch
        val window = tracks.take(MAX_QUEUE)
        val start = startIndex.coerceIn(0, (window.size - 1).coerceAtLeast(0))

        val items = window.map { track ->
            async(Dispatchers.IO) {
                runCatching {
                    val source = server.stream(track.serverId, track.remoteId)
                    MediaItem.Builder()
                        .setUri(source.url)
                        .setMediaId(track.remoteId)
                        .setMediaMetadata(
                            MediaMetadata.Builder()
                                .setTitle(track.title)
                                .setArtist(track.artistName)
                                .setAlbumTitle(track.albumTitle)
                                .build()
                        )
                        .build()
                }.getOrNull()
            }
        }.awaitAll()

        // A track whose URL would not resolve is dropped rather than left as a
        // hole that stops playback dead when it is reached.
        val playable = window.zip(items).filter { it.second != null }
        if (playable.isEmpty()) return@launch
        queue = playable.map { it.first }

        val startTrack = window.getOrNull(start)
        val resolvedStart = queue.indexOfFirst { it.remoteId == startTrack?.remoteId }
            .coerceAtLeast(0)

        media.setMediaItems(playable.mapNotNull { it.second }, resolvedStart, 0)
        media.prepare()
        media.play()

        queue.getOrNull(resolvedStart)?.let { record(it, PlayEventKind.STARTED) }
    }

    fun togglePlayPause() {
        val media = controller ?: return
        if (media.isPlaying) media.pause() else media.play()
    }

    fun next() = controller?.seekToNextMediaItem()

    fun previous() = controller?.seekToPreviousMediaItem()

    fun release() {
        controller?.release()
        controller = null
    }

    private fun publish(player: Player) {
        _state.value = PlaybackState(
            track = queue.getOrNull(player.currentMediaItemIndex),
            isPlaying = player.isPlaying,
            positionMillis = player.currentPosition.coerceAtLeast(0),
            durationMillis = player.duration.takeIf { it > 0 } ?: 0,
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
    }
}
