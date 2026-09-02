package com.thatcube.mozz

import android.app.Application
import coil3.ImageLoader
import coil3.PlatformContext
import coil3.SingletonImageLoader
import coil3.network.okhttp.OkHttpNetworkFetcherFactory
import coil3.util.DebugLogger
import com.thatcube.mozz.analysis.SonicAnalysisController
import com.thatcube.mozz.analysis.SonicAnalysisWorker
import com.thatcube.mozz.core.MozzCore
import com.thatcube.mozz.core.MozzLibrary
import com.thatcube.mozz.core.MozzServer
import com.thatcube.mozz.core.SecretStore
import com.thatcube.mozz.playback.PlayerController
import com.thatcube.mozz.ui.ToastCenter
import com.thatcube.mozz.ui.theme.MozzSettings
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.MainScope
import okhttp3.Dispatcher
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Response
import java.io.File
import java.io.IOException

/**
 * The core session, opened once for the life of the process.
 *
 * `MozzCore` owns the database connection pool, and paging a list means hundreds
 * of reads a second — so this is deliberately not per-screen or per-view-model.
 * It is never closed: the process ending is what closes it, and Android gives no
 * reliable "app is quitting" callback to do it in.
 */
class MozzApplication : Application(), SingletonImageLoader.Factory {

    override fun onCreate() {
        super.onCreate()
        // A library is hours of work and nobody keeps a music app open for
        // hours, so the scheduler owns this rather than the screen. Constrained
        // to charging + unmetered; idempotent, so this costs nothing on every
        // launch after the first.
        SonicAnalysisWorker.schedule(this)
    }

    /**
     * Coil's loader, built here rather than left to its defaults.
     *
     * The network fetcher is registered explicitly rather than left to
     * `ServiceLoader` discovery, which does not survive this build: without it
     * every cover in the app failed to load, silently, because Coil treats a
     * missing fetcher the same as an image that has not arrived yet.
     *
     * The logger is debug-only on purpose. Artwork URLs carry the Plex token as a
     * query parameter, and logcat is readable by more than this app — a token in
     * a release log is a credential leak, not a diagnostic.
     */
    override fun newImageLoader(context: PlatformContext): ImageLoader =
        ImageLoader.Builder(context)
            .components { add(OkHttpNetworkFetcherFactory(callFactory = { artworkHttpClient })) }
            .apply { if (BuildConfig.DEBUG) logger(DebugLogger()) }
            .build()

    /**
     * The client every cover is fetched through.
     *
     * Two departures from the defaults, both for the same reason: a Plex server
     * reached over Plex's relay drops connections under load. Scrolling a list of
     * songs asks for a dozen covers at once and the relay closes the TLS
     * handshake on several of them — `SSLHandshakeException: connection closed` —
     * leaving a page of grey squares while the same covers load fine one at a
     * time elsewhere in the app.
     *
     * So: fewer at once, and a second chance. Neither is a fix for the relay —
     * the fix is not being on it — but a dropped handshake is exactly the kind of
     * failure a retry is for, and four in flight is still more than a scrolling
     * list can consume.
     */
    private val artworkHttpClient: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .dispatcher(Dispatcher().apply { maxRequestsPerHost = ARTWORK_PARALLELISM })
            .addInterceptor(RetryOnDroppedConnection(attempts = 3))
            .build()
    }

    /**
     * How the app is meant to look. Application-scoped so a theme change survives
     * the activity being recreated — which a fold does on this hardware.
     */
    val settings: MozzSettings by lazy { MozzSettings(this) }

    val core: MozzCore by lazy {
        MozzCore.open(File(filesDir, "library.sqlite").absolutePath)
    }

    val library: MozzLibrary by lazy { MozzLibrary(core) }

    /**
     * Where anything in the app says a short thing to the person using it.
     *
     * Application-scoped for the same reason playback is: the thing with news
     * to report often outlives the screen that was open when it happened. A
     * playback failure is exactly that — it arrives from a media session that
     * does not know or care which tab is showing.
     */
    val toasts: ToastCenter by lazy { ToastCenter(MainScope()) }

    /**
     * Playback outlives any one screen — that is what a media session is for —
     * so the controller is owned here rather than by a ViewModel.
     */
    val playback: PlayerController by lazy {
        PlayerController(
            context = this,
            server = server,
            library = library,
            toasts = toasts,
            scope = MainScope(),
        )
    }

    /**
     * Analyzes the library's audio when the device can afford it — see
     * [SonicAnalysisController]. Application-scoped because the pass outlives
     * any one screen, and driven by the activity's lifecycle.
     */
    val sonicAnalysis: SonicAnalysisController by lazy {
        SonicAnalysisController(context = this, server = server, scope = MainScope())
    }

    val server: MozzServer by lazy {
        MozzServer(
            core = core,
            secrets = SecretStore(this),
            accountsFile = File(filesDir, "accounts.json"),
        )
    }
}

/** OkHttp's default is five per host, which the relay cannot keep up with. */
private const val ARTWORK_PARALLELISM = 4

/**
 * Try again when the connection dies before an answer.
 *
 * OkHttp retries some connection failures on its own, but not a TLS handshake the
 * peer closes mid-way, which is the shape the relay's failures take. The backoff
 * is short and the ceiling low: this is for a flaky hop, not for a server that is
 * genuinely down, and three attempts that all fail should fail quickly.
 */
private class RetryOnDroppedConnection(private val attempts: Int) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        var failure: IOException? = null
        repeat(attempts) { attempt ->
            if (attempt > 0) Thread.sleep(BACKOFF_MS * attempt)
            try {
                return chain.proceed(chain.request())
            } catch (error: IOException) {
                failure = error
            }
        }
        throw failure ?: IOException("request failed")
    }

    private companion object {
        const val BACKOFF_MS = 180L
    }
}
