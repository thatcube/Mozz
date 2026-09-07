package com.thatcube.mozz.core

import kotlinx.serialization.Serializable

/** The graphic-EQ curve: ten ISO bands, low to high, plus a preamp. */
@Serializable
data class EqualizerSettings(
    val gains: List<Double> = List(10) { 0.0 },
    val preampDB: Double = 0.0,
)

/**
 * Everything that shapes the *sound* of playback.
 *
 * Core behaviour, not shell behaviour — presentation may differ between
 * platforms, sound may not. Kept in one table and carried between a listener's
 * devices through the relay, which is exactly why a shell must not keep its own
 * copy: a fourth private store is a setting that can never sync.
 */
@Serializable
data class PlaybackSettings(
    val equalizerEnabled: Boolean = false,
    val equalizer: EqualizerSettings = EqualizerSettings(),
    /** `off`, `track` or `album`. Default `track`. */
    val replayGainMode: String = "track",
    val replayGainPreampDB: Double = 0.0,
) {
    /** Whether loudness levelling is on at all, which is the whole of the UI. */
    val normalizesVolume: Boolean get() = replayGainMode != "off"

    /**
     * The same settings with levelling on or off, and **everything else left
     * alone**.
     *
     * The everything-else matters more than it looks: Android has no equalizer
     * screen, so a phone that wrote a flat curve every time somebody touched
     * the volume switch would quietly erase the curve its owner set on their
     * desktop. Whatever the core last stored is carried through untouched.
     */
    fun normalizing(enabled: Boolean): PlaybackSettings =
        copy(replayGainMode = if (enabled) "track" else "off")
}

/** Reading and writing the settings the core owns. */
class MozzPlaybackSettings(private val core: MozzCore) {

    suspend fun get(): PlaybackSettings? =
        core.call(CoreRequest(cmd = "getPlaybackSettings"))

    /**
     * Write, and take back what was actually stored.
     *
     * The store normalizes on the way in — the preamp is clamped, the band
     * count fixed — so the answer is the truth and the request was only a
     * request.
     */
    suspend fun set(settings: PlaybackSettings): PlaybackSettings? =
        core.call(CoreRequest(cmd = "setPlaybackSettings", playbackSettings = settings))
}
