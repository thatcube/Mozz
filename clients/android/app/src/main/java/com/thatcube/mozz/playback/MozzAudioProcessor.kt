package com.thatcube.mozz.playback

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Where Mozz's equaliser sits in ExoPlayer's pipeline.
 *
 * ExoPlayer keeps everything it is good at — decoding, HLS for Plex transcodes,
 * the media session the car and the lock screen come from — and hands each
 * buffer through here on its way to the device. The filtering itself is the
 * shared Rust bank in [MozzDsp], so the phone and the desktop apply the same
 * coefficients rather than two sets that nothing forces to agree.
 *
 * Only 16-bit PCM is claimed. That is what ExoPlayer produces by default, and
 * declaring an encoding this cannot actually filter would mean silently passing
 * audio through while a curve sits on screen doing nothing.
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class MozzAudioProcessor : BaseAudioProcessor() {

    private var dsp: MozzDsp? = null

    /** Reused: this runs hundreds of times a second and must not allocate. */
    private var scratch = ByteArray(0)

    private var gainsDb = DoubleArray(BAND_COUNT)
    private var preampDb = 0.0
    private var enabled = false
    private var trackGainDb = 0.0

    /**
     * Set the curve. Safe to call while playing — the next buffer uses it, and
     * a listener dragging a slider expects to hear the result, not to hear it
     * after the song changes.
     */
    fun setEqualizer(gainsDb: DoubleArray, preampDb: Double, enabled: Boolean) {
        if (gainsDb.size != BAND_COUNT) return
        this.gainsDb = gainsDb.copyOf()
        this.preampDb = preampDb
        this.enabled = enabled
        dsp?.setEqualizer(this.gainsDb, preampDb, enabled)
    }

    /** The levelling gain for the track now playing, in dB. */
    fun setTrackGainDb(gainDb: Double) {
        trackGainDb = gainDb
        dsp?.setGainDb(gainDb)
    }

    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT) {
            // Declining rather than pretending: a processor that claims a format
            // it cannot filter passes audio through with a curve on screen.
            throw AudioProcessor.UnhandledAudioFormatException(inputAudioFormat)
        }
        release()
        dsp = MozzDsp.create(inputAudioFormat.sampleRate, inputAudioFormat.channelCount)?.also {
            it.setEqualizer(gainsDb, preampDb, enabled)
            it.setGainDb(trackGainDb)
        }
        // Same format out as in: this changes the samples, never their shape.
        return inputAudioFormat
    }

    /**
     * True only when there is something to do.
     *
     * ExoPlayer skips a processor that is not active, so a listener who has
     * touched nothing gets the file bit-for-bit rather than a round trip
     * through a flat filter bank.
     */
    override fun isActive(): Boolean =
        dsp != null && (enabled || trackGainDb != 0.0)

    override fun queueInput(inputBuffer: ByteBuffer) {
        val length = inputBuffer.remaining()
        if (length == 0) return
        val dsp = this.dsp
        if (dsp == null) {
            replaceOutputBuffer(length).put(inputBuffer).flip()
            return
        }

        if (scratch.size < length) scratch = ByteArray(length)
        inputBuffer.get(scratch, 0, length)
        // A refusal means the buffer is untouched, which is the right answer:
        // an equaliser that cannot run should leave the music playing.
        dsp.process(scratch, length)
        replaceOutputBuffer(length)
            .order(ByteOrder.nativeOrder())
            .put(scratch, 0, length)
            .flip()
    }

    override fun onReset() = release()

    private fun release() {
        dsp?.close()
        dsp = null
    }

    private companion object {
        /** The ten ISO bands the core defines. */
        const val BAND_COUNT = 10
    }
}
