package com.thatcube.mozz.playback

import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService

/**
 * The thing that actually makes sound, and keeps making it once Mozz is not on
 * screen.
 *
 * A `MediaSessionService` rather than an `ExoPlayer` held by an Activity,
 * because everything a music player is expected to do off-screen comes from the
 * session: the notification transport, the lock screen, Bluetooth and headset
 * buttons, and — later — Android Auto and Wear. An Activity-owned player is
 * killed the moment the user switches apps.
 */
class MozzPlaybackService : MediaSessionService() {

    private var session: MediaSession? = null

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

        session = MediaSession.Builder(this, player).build()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session

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
        session?.run {
            player.release()
            release()
        }
        session = null
        super.onDestroy()
    }
}
