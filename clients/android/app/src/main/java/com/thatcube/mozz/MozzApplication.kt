package com.thatcube.mozz

import android.app.Application
import com.thatcube.mozz.core.MozzCore
import com.thatcube.mozz.core.MozzLibrary
import com.thatcube.mozz.core.MozzServer
import com.thatcube.mozz.core.SecretStore
import com.thatcube.mozz.playback.PlayerController
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
class MozzApplication : Application() {

    val core: MozzCore by lazy {
        MozzCore.open(File(filesDir, "library.sqlite").absolutePath)
    }

    val library: MozzLibrary by lazy { MozzLibrary(core) }

    /**
     * Playback outlives any one screen — that is what a media session is for —
     * so the controller is owned here rather than by a ViewModel.
     */
    val playback: PlayerController by lazy {
        PlayerController(
            context = this,
            server = server,
            library = library,
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
