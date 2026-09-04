package com.thatcube.mozz.analysis

import android.content.Context
import android.util.Log
import java.io.File

/**
 * The learned analyzer's weights, made into something the core can open.
 *
 * The core reads a path, because it does not know what an asset manager is and
 * because nine megabytes has no business crossing a JSON boundary. Android
 * assets are not files — they live compressed inside the APK — so they are
 * copied out once, on first use, and the copy is what gets named.
 *
 * The copy is keyed by size: an app update that ships different weights
 * replaces the extracted file rather than leaving the old model in place, which
 * would be the worst kind of bug to find, since analysis would carry on
 * succeeding with the wrong network.
 */
object SonicWeights {
    private const val ASSET = "vggish-trunk.bin"
    private const val TAG = "MozzSonic"

    /** The extracted path, or null when the weights are unavailable. */
    fun path(context: Context): String? {
        val target = File(context.filesDir, ASSET)
        return runCatching {
            // `openFd` works only on assets stored uncompressed, which the build
            // arranges (see `noCompress` in build.gradle.kts). If that ever
            // stops being true the size check is skipped rather than the
            // weights being abandoned — a stale copy is worth catching, but not
            // at the cost of no weights at all.
            val expected = runCatching { context.assets.openFd(ASSET).use { it.length } }.getOrNull()
            if (!target.exists() || (expected != null && target.length() != expected)) {
                context.assets.open(ASSET).use { input ->
                    target.outputStream().use { output -> input.copyTo(output) }
                }
                Log.i(TAG, "extracted analyzer weights (${target.length()} bytes)")
            }
            target.absolutePath
        }.getOrElse {
            // Not fatal: the core falls back to the DSP engine, which is worse
            // but real.
            Log.w(TAG, "no analyzer weights; falling back to the DSP engine", it)
            null
        }
    }
}
