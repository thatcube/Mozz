package com.thatcube.mozz.ui

import android.graphics.Bitmap
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalInspectionMode
import androidx.core.graphics.get
import coil3.ImageLoader
import coil3.SingletonImageLoader
import coil3.request.ImageRequest
import coil3.request.allowHardware
import coil3.toBitmap
import com.thatcube.mozz.core.ArtworkTone
import com.thatcube.mozz.core.ArtworkTones
import com.thatcube.mozz.core.MozzLibrary
import com.thatcube.mozz.core.MozzServer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * The backdrop behind the player: a field of colour sampled from the artwork,
 * drifting slowly.
 *
 * A direct port of `Sources/MozzApp/NowPlaying/PlayerBackground.swift`, tuning
 * constants included, because this is the thing that makes the player feel like
 * Mozz rather than like a generic player — and two platforms guessing separately
 * at "colours from the artwork" would drift apart immediately.
 *
 * The one thing that could not be ported literally is the mesh itself: SwiftUI
 * has `MeshGradient` and Compose does not. But the iOS grid is *row-uniform* —
 * each of the three rows is a single tone — so a vertical gradient reproduces it
 * exactly, and the drift becomes movement of the stops plus two soft accent
 * blobs rather than displacement of nine mesh points.
 */
/**
 * Reduce artwork to the pixels the core wants to see.
 *
 * The scoring lives in `MozzCore.ArtworkPalette` so iOS and Android cannot drift
 * apart on what an album looks like. What stays here is the part that genuinely
 * cannot be shared: Android decodes its own images.
 */
private object ArtworkSampling {
    /** 48×48 ≈ 2.3k pixels — plenty to characterise a cover, cheap to scale. */
    const val SAMPLE_DIM = 48

    /** Small on purpose: this image is histogrammed, never shown. */
    const val REQUEST_SIZE = 240

    /** Drift amplitude as a fraction of the frame: alive without folding. */
    const val DRIFT_AMPLITUDE = 0.16f

    /** Horizontal drift is scaled down against vertical — a portrait screen has
     *  little side-to-side room, so the field flows top to bottom. */
    const val DRIFT_HORIZONTAL_SCALE = 0.3f

    /** Tightly packed RGBA, which is the layout the core reads. */
    fun rgba(bitmap: Bitmap): ByteArray {
        val scaled = if (bitmap.width == SAMPLE_DIM && bitmap.height == SAMPLE_DIM) bitmap
        else Bitmap.createScaledBitmap(bitmap, SAMPLE_DIM, SAMPLE_DIM, true)

        val pixels = IntArray(SAMPLE_DIM * SAMPLE_DIM)
        scaled.getPixels(pixels, 0, SAMPLE_DIM, 0, 0, SAMPLE_DIM, SAMPLE_DIM)

        val bytes = ByteArray(pixels.size * 4)
        pixels.forEachIndexed { index, pixel ->
            val at = index * 4
            bytes[at] = ((pixel shr 16) and 0xFF).toByte()
            bytes[at + 1] = ((pixel shr 8) and 0xFF).toByte()
            bytes[at + 2] = (pixel and 0xFF).toByte()
            bytes[at + 3] = ((pixel ushr 24) and 0xFF).toByte()
        }
        return bytes
    }
}

/**
 * Paints the artwork-derived field, drifting.
 *
 * Three periods that do not divide into each other, so the motion never visibly
 * loops — the point is a field that feels alive, and anything that repeats on a
 * noticeable cycle reads as a screensaver instead.
 */
@Composable
fun PlayerBackground(
    server: MozzServer,
    library: MozzLibrary,
    serverId: String,
    artworkKey: String?,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val fallback = androidx.compose.material3.MaterialTheme.colorScheme.background
    var tones by remember(artworkKey) { mutableStateOf<ArtworkTones?>(null) }

    LaunchedEffect(serverId, artworkKey) {
        tones = artworkKey?.let { key ->
            runCatching {
                val pixels = withContext(Dispatchers.IO) {
                    val url = server.artworkUrl(serverId, key, ArtworkSampling.REQUEST_SIZE)
                        ?: return@withContext null
                    val loader: ImageLoader = SingletonImageLoader.get(context)
                    val request = ImageRequest.Builder(context)
                        .data(url)
                        // Hardware bitmaps cannot be read back pixel by pixel,
                        // and reading pixels is the entire point here.
                        .allowHardware(false)
                        .build()
                    loader.execute(request).image?.let { ArtworkSampling.rgba(it.toBitmap()) }
                } ?: return@runCatching null
                library.artworkTones(pixels, ArtworkSampling.SAMPLE_DIM, ArtworkSampling.SAMPLE_DIM)
            }.getOrNull()
        }
    }

    val palette = tones
    if (palette == null) {
        Canvas(modifier = modifier.fillMaxSize()) { drawRect(fallback) }
        return
    }

    fun ArtworkTone.compose() = Color(red.toFloat(), green.toFloat(), blue.toFloat())
    val top = palette.top.compose()
    val middle = palette.middle.compose()
    val bottom = palette.bottom.compose()
    val still = LocalInspectionMode.current
    val transition = rememberInfiniteTransition(label = "backdrop")

    @Composable
    fun phase(periodMillis: Int, label: String): Float = if (still) 0f else
        transition.animateFloat(
            initialValue = 0f,
            targetValue = (2 * Math.PI).toFloat(),
            animationSpec = infiniteRepeatable(
                animation = tween(periodMillis, easing = LinearEasing),
                repeatMode = RepeatMode.Restart,
            ),
            label = label,
        ).value

    val slow = phase(23_000, "slow")
    val medium = phase(17_000, "medium")
    val fast = phase(11_000, "fast")

    Canvas(modifier = modifier.fillMaxSize()) {
        val height = size.height
        val width = size.width
        val drift = ArtworkSampling.DRIFT_AMPLITUDE

        // The three bands, with their boundaries breathing up and down.
        val upper = (0.34f + sin(slow) * drift * 0.5f).coerceIn(0.08f, 0.6f)
        val lower = (0.66f + sin(medium) * drift * 0.5f).coerceIn(0.4f, 0.95f)

        drawRect(
            brush = Brush.verticalGradient(
                0f to top,
                upper to middle,
                lower to middle,
                1f to bottom,
            )
        )

        // Two soft accent blobs roaming over the field. This is what replaces
        // the mesh's wandering control points: the same "paint in water" motion,
        // achieved with radial washes instead of a mesh Compose does not have.
        val horizontal = drift * ArtworkSampling.DRIFT_HORIZONTAL_SCALE
        drawRect(
            brush = Brush.radialGradient(
                colors = listOf(top.copy(alpha = 0.55f), Color.Transparent),
                center = Offset(
                    width * (0.5f + sin(fast) * horizontal),
                    height * (0.18f + sin(medium) * drift),
                ),
                radius = max(width, height) * 0.7f,
            )
        )
        drawRect(
            brush = Brush.radialGradient(
                colors = listOf(bottom.copy(alpha = 0.55f), Color.Transparent),
                center = Offset(
                    width * (0.5f - sin(medium) * horizontal),
                    height * (0.86f - sin(slow) * drift),
                ),
                radius = max(width, height) * 0.7f,
            )
        )

        // A legibility scrim. The brightness clamp above keeps the field dark
        // enough for white text on its own, but the controls sit at the bottom
        // where the accent is strongest.
        drawRect(
            brush = Brush.verticalGradient(
                0f to Color.Black.copy(alpha = 0.25f),
                0.45f to Color.Transparent,
                1f to Color.Black.copy(alpha = 0.35f),
            ),
            size = Size(width, height),
        )
    }
}
