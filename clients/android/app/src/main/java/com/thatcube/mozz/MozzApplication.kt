package com.thatcube.mozz

import android.app.Application
import coil3.ImageLoader
import coil3.PlatformContext
import coil3.SingletonImageLoader
import coil3.network.okhttp.OkHttpNetworkFetcherFactory
import coil3.util.DebugLogger
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
import java.io.File

/**
 * The core session, opened once for the life of the process.
 *
 * `MozzCore` owns the database connection pool, and paging a list means hundreds
 * of reads a second — so this is deliberately not per-screen or per-view-model.
 * It is never closed: the process ending is what closes it, and Android gives no
 * reliable "app is quitting" callback to do it in.
 */
class MozzApplication : Application(), SingletonImageLoader.Factory {

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
            .components { add(OkHttpNetworkFetcherFactory()) }
            .apply { if (BuildConfig.DEBUG) logger(DebugLogger()) }
            .build()

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

    val server: MozzServer by lazy {
        MozzServer(
            core = core,
            secrets = SecretStore(this),
            accountsFile = File(filesDir, "accounts.json"),
        )
    }
}
