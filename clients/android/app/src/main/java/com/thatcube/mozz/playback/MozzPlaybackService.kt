package com.thatcube.mozz.playback

import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.LibraryResult
import androidx.media3.session.MediaLibraryService
import androidx.media3.session.MediaSession
import androidx.media3.session.SessionError
import com.google.common.collect.ImmutableList
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.google.common.util.concurrent.SettableFuture
import com.thatcube.mozz.MozzApplication
import com.thatcube.mozz.core.Track
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * The thing that actually makes sound, and keeps making it once Mozz is not on
 * screen.
 *
 * A service rather than an `ExoPlayer` held by an Activity, because everything
 * a music player is expected to do off-screen comes from the session: the
 * notification transport, the lock screen, Bluetooth and headset buttons, and
 * the car. An Activity-owned player is killed the moment the user switches
 * apps.
 *
 * A `MediaLibraryService` and not merely a `MediaSessionService`, because a car
 * does not have Mozz's screen — Android Auto draws its own list from whatever
 * the session says its library contains, and a session with nothing to browse
 * appears in a car as an app you can only see what is already playing on. The
 * tree below is the same shape CarPlay gets on the iPhone.
 */
class MozzPlaybackService : MediaLibraryService() {

    private var session: MediaLibrarySession? = null

    /** Browsing is I/O; the car's callbacks are not a place to block. */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val app: MozzApplication get() = application as MozzApplication

    override fun onCreate() {
        super.onCreate()
        val player = ExoPlayer.Builder(this)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
                    .setUsage(C.USAGE_MEDIA)
                    .build(),
                // Handle audio focus: duck for a navigation prompt, pause for a
                // call, and do not fight whatever else wants the speaker.
                /* handleAudioFocus = */ true,
            )
            .setHandleAudioBecomingNoisy(true)
            .build()

        session = MediaLibrarySession.Builder(this, player, LibraryCallback()).build()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaLibrarySession? =
        session

    /**
     * Stop when the user swipes the app away *and* nothing is playing. A music
     * app that dies mid-song because its task was dismissed is a bug; one that
     * lingers paused in the notification shade forever is also a bug.
     */
    override fun onTaskRemoved(rootIntent: android.content.Intent?) {
        val player = session?.player
        if (player == null || !player.playWhenReady || player.mediaItemCount == 0) {
            stopSelf()
        }
    }

    override fun onDestroy() {
        scope.cancel()
        session?.run {
            player.release()
            release()
        }
        session = null
        super.onDestroy()
    }

    private inner class LibraryCallback : MediaLibrarySession.Callback {

        override fun onGetLibraryRoot(
            session: MediaLibrarySession,
            browser: MediaSession.ControllerInfo,
            params: LibraryParams?,
        ): ListenableFuture<LibraryResult<MediaItem>> =
            Futures.immediateFuture(
                LibraryResult.ofItem(browsable(ROOT, "Mozz"), params)
            )

        override fun onGetChildren(
            session: MediaLibrarySession,
            browser: MediaSession.ControllerInfo,
            parentId: String,
            page: Int,
            pageSize: Int,
            params: LibraryParams?,
        ): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> = settle {
            val serverId = attachedServerId()
                ?: return@settle LibraryResult.ofError(
                    SessionError.ERROR_SESSION_AUTHENTICATION_EXPIRED
                )
            val children = runCatching { children(parentId, serverId) }.getOrDefault(emptyList())
            LibraryResult.ofItemList(ImmutableList.copyOf(children), params)
        }

        override fun onGetItem(
            session: MediaLibrarySession,
            browser: MediaSession.ControllerInfo,
            mediaId: String,
        ): ListenableFuture<LibraryResult<MediaItem>> =
            Futures.immediateFuture(LibraryResult.ofItem(browsable(mediaId, mediaId), null))

        /**
         * Turn what the car asked for into something that will play.
         *
         * A browsed item arrives carrying its id and nothing else — no stream
         * URL, because the car never had one. Resolving here is what makes a
         * tap in a car actually make a sound; without it the session accepts
         * the item and plays silence.
         */
        override fun onAddMediaItems(
            mediaSession: MediaSession,
            controller: MediaSession.ControllerInfo,
            mediaItems: MutableList<MediaItem>,
        ): ListenableFuture<MutableList<MediaItem>> = settle {
            val serverId = attachedServerId() ?: return@settle mediaItems
            mediaItems.map { item ->
                if (item.localConfiguration != null) return@map item
                val remoteId = item.mediaId.removePrefix("$TRACK/")
                val track = runCatching { app.library.track(serverId, remoteId) }.getOrNull()
                    ?: return@map item
                playable(track) ?: item
            }.toMutableList()
        }
    }

    /**
     * Run [work] off the callback thread and hand the car a future for it.
     *
     * Media3 wants a Guava `ListenableFuture` and coroutines produce a
     * `CompletableFuture`; settling one by hand is smaller than a dependency
     * whose only job would be to convert between them.
     */
    private fun <T> settle(work: suspend () -> T): ListenableFuture<T> {
        val future = SettableFuture.create<T>()
        scope.launch {
            runCatching { work() }
                .onSuccess { future.set(it) }
                .onFailure { future.setException(it) }
        }
        return future
    }

    // MARK: The tree

    private suspend fun children(parentId: String, serverId: String): List<MediaItem> =
        when {
            parentId == ROOT -> listOf(
                browsable(LIKED, "Liked Songs"),
                browsable(RECENT, "Recently Played"),
                browsable(ALBUMS, "Albums"),
                browsable(ARTISTS, "Artists"),
                browsable(PLAYLISTS, "Playlists"),
            )

            parentId == LIKED ->
                app.library.likedTracks(serverId, limit = CAR_PAGE).map(::playableStub)

            parentId == RECENT ->
                app.library.recentlyPlayedTracks(serverId, limit = CAR_PAGE).map(::playableStub)

            parentId == ALBUMS -> app.library.albums(serverId, limit = CAR_PAGE).rows.orEmpty()
                .map { browsable("$ALBUM/${it.remoteId}", it.title, it.artistName) }

            parentId == ARTISTS -> app.library.artists(serverId, limit = CAR_PAGE).rows.orEmpty()
                .map { browsable("$ARTIST/${it.remoteId}", it.name) }

            parentId == PLAYLISTS -> app.library.playlists(serverId)
                .map { browsable("$PLAYLIST/${it.remoteId}", it.title) }

            parentId.startsWith("$ALBUM/") ->
                app.library.albumTracks(serverId, parentId.removePrefix("$ALBUM/"))
                    .map(::playableStub)

            parentId.startsWith("$ARTIST/") ->
                app.library.artistTopTracks(serverId, parentId.removePrefix("$ARTIST/"))
                    .map(::playableStub)

            parentId.startsWith("$PLAYLIST/") ->
                app.library.playlistTracks(serverId, parentId.removePrefix("$PLAYLIST/"))
                    .map(::playableStub)

            else -> emptyList()
        }

    private fun attachedServerId(): String? =
        app.server.savedAccounts().firstOrNull()?.serverId

    private fun browsable(id: String, title: String, subtitle: String? = null) =
        MediaItem.Builder()
            .setMediaId(id)
            .setMediaMetadata(
                MediaMetadata.Builder()
                    .setTitle(title)
                    .setSubtitle(subtitle)
                    .setIsBrowsable(true)
                    .setIsPlayable(false)
                    .setMediaType(MediaMetadata.MEDIA_TYPE_FOLDER_MIXED)
                    .build()
            )
            .build()

    /**
     * A row in the car's list: enough to draw, and no stream URL.
     *
     * Resolving a URL costs a round trip per track, and a list of fifty is
     * fifty of them for the one the driver will actually tap. The URL is
     * fetched in `onAddMediaItems`, when there is a tap to justify it.
     */
    private fun playableStub(track: Track) = MediaItem.Builder()
        .setMediaId("$TRACK/${track.remoteId}")
        .setMediaMetadata(
            MediaMetadata.Builder()
                .setTitle(track.title)
                .setArtist(track.artistName)
                .setAlbumTitle(track.albumTitle)
                .setIsBrowsable(false)
                .setIsPlayable(true)
                .setMediaType(MediaMetadata.MEDIA_TYPE_MUSIC)
                .build()
        )
        .build()

    private suspend fun playable(track: Track): MediaItem? {
        val url = runCatching {
            app.server.stream(track.serverId, track.remoteId).url
        }.getOrNull() ?: return null
        return playableStub(track).buildUpon().setUri(url).build()
    }

    private companion object {
        const val ROOT = "root"
        const val LIKED = "liked"
        const val RECENT = "recent"
        const val ALBUMS = "albums"
        const val ARTISTS = "artists"
        const val PLAYLISTS = "playlists"
        const val ALBUM = "album"
        const val ARTIST = "artist"
        const val PLAYLIST = "playlist"
        const val TRACK = "track"

        /**
         * How many rows a car gets. Deliberately short: a driver scrolling a
         * thousand albums is a driver not looking at the road, and every car
         * OEM caps the list anyway.
         */
        const val CAR_PAGE = 100
    }
}
