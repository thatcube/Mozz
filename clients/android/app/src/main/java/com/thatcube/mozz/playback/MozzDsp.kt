package com.thatcube.mozz.playback

import android.util.Log

/**
 * The shared equaliser, as reachable from Kotlin.
 *
 * The filters themselves are the ones the desktop uses — the same Rust, the
 * same coefficients — because an equaliser written twice is two equalisers
 * (ADR-0015). What crosses this boundary is buffers, not decisions.
 *
 * Not thread-safe and not meant to be: one instance belongs to one audio
 * processor, which ExoPlayer drives from one thread.
 */
class MozzDsp private constructor(private var handle: Long) : AutoCloseable {

    fun setEqualizer(gainsDb: DoubleArray, preampDb: Double, enabled: Boolean): Boolean =
        handle != 0L && nativeSetEqualizer(handle, gainsDb, preampDb, enabled)

    /** The levelling gain for the track now playing. */
    fun setGainDb(gainDb: Double): Boolean =
        handle != 0L && nativeSetGainDb(handle, gainDb)

    /**
     * Filter one buffer of interleaved 16-bit PCM in place.
     *
     * False means nothing was done, and the caller should pass the buffer
     * through untouched: an equaliser that cannot run must leave the music
     * playing rather than silence it.
     */
    fun process(pcm: ByteArray, length: Int): Boolean =
        handle != 0L && nativeProcess(handle, pcm, length)

    override fun close() {
        if (handle == 0L) return
        nativeFree(handle)
        handle = 0L
    }

    companion object {
        private const val TAG = "MozzDsp"

        /**
         * Whether the shared library loaded.
         *
         * A device whose ABI was not built for gets false, and everything above
         * falls back to passing audio through — no equaliser is a missing
         * feature, a crash on startup is a broken app.
         */
        private val available: Boolean by lazy {
            runCatching { System.loadLibrary("mozz_audio_android") }
                .onFailure { Log.w(TAG, "no audio DSP for this device", it) }
                .isSuccess
        }

        /**
         * A filter bank for one stream format, or null when there is none to be
         * had. Coefficients are computed against a sample rate, so a stream that
         * changes format needs a new one rather than a reconfigured one.
         */
        fun create(sampleRate: Int, channels: Int): MozzDsp? {
            if (!available) return null
            val handle = runCatching { nativeNew(sampleRate, channels) }.getOrDefault(0L)
            return if (handle == 0L) null else MozzDsp(handle)
        }

        @JvmStatic private external fun nativeNew(sampleRate: Int, channels: Int): Long
        @JvmStatic private external fun nativeFree(handle: Long)
        @JvmStatic private external fun nativeSetEqualizer(
            handle: Long,
            gainsDb: DoubleArray,
            preampDb: Double,
            enabled: Boolean,
        ): Boolean
        @JvmStatic private external fun nativeSetGainDb(handle: Long, gainDb: Double): Boolean
        @JvmStatic private external fun nativeProcess(handle: Long, pcm: ByteArray, length: Int): Boolean
    }
}
