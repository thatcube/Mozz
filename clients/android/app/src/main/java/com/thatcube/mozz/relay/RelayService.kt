package com.thatcube.mozz.relay

import android.util.Log
import com.thatcube.mozz.core.MozzPlaybackSettings
import com.thatcube.mozz.core.MozzRelay
import com.thatcube.mozz.core.ServerAccount
import com.thatcube.mozz.pairing.PairingService

/** What one relay run moved, for the log and for the settings screen. */
data class RelayOutcome(
    val importedHistory: Int = 0,
    val importedFeatures: Int = 0,
    val publishedFeatures: Int = 0,
    val importedFavorites: Int = 0,
)

/**
 * Keeping this phone level with the rest of its circle.
 *
 * Nothing runs without a circle, which is what pairing establishes — so this is
 * silent and returns null on a device that has not been paired, rather than
 * treating that as a failure. See ADR-0012 for what the relay is (a dumb store
 * that holds ciphertext and can read none of it) and ADR-0018 for why the
 * vectors in particular are worth moving.
 */
class RelayService(
    private val relay: MozzRelay,
    private val pairing: PairingService,
    private val playbackSettings: MozzPlaybackSettings,
    private val deviceId: String,
    private val deviceName: String,
    /** Told when the circle's settings differ from what this device held. */
    private val onSettingsChanged: (Boolean) -> Unit = {},
) {

    suspend fun sync(account: ServerAccount): RelayOutcome? {
        var circle = pairing.loadCircle() ?: return null

        // History first: it provisions the relay capability when the circle has
        // none, and the catalog run needs one.
        val history = runCatching {
            relay.syncHistory(circle, deviceId, deviceName)
        }.onFailure { Log.w(TAG, "history relay sync failed", it) }.getOrNull()

        history?.relayKey?.takeIf { it.isNotEmpty() && it != circle.relayKey }?.let { renewed ->
            pairing.rememberRelayKey(renewed)
            circle = circle.copy(relayKey = renewed)
        }

        val settings = runCatching {
            val seed = playbackSettings.get() ?: return@runCatching null
            relay.syncPlaybackSettings(circle, deviceId, seed)
        }.onFailure { Log.w(TAG, "playback settings relay sync failed", it) }.getOrNull()

        settings?.relayKey?.takeIf { it.isNotEmpty() && it != circle.relayKey }?.let { renewed ->
            pairing.rememberRelayKey(renewed)
            circle = circle.copy(relayKey = renewed)
        }
        // What the circle agreed, which may be what somebody chose elsewhere.
        if (settings?.changed == true) {
            runCatching { playbackSettings.set(settings.settings) }
            onSettingsChanged(settings.settings.normalizesVolume)
        }

        val catalog = runCatching {
            relay.syncCatalog(
                circle = circle,
                deviceId = deviceId,
                serverId = account.serverId,
                musicSectionIds = account.musicSectionId?.let { listOf(it) },
            )
        }.onFailure { Log.w(TAG, "catalog relay sync failed", it) }.getOrNull()

        catalog?.relayKey?.takeIf { it.isNotEmpty() && it != circle.relayKey }?.let {
            pairing.rememberRelayKey(it)
        }

        if (history == null && catalog == null) return null
        return RelayOutcome(
            importedHistory = history?.imported ?: 0,
            importedFeatures = catalog?.importedFeatures ?: 0,
            publishedFeatures = catalog?.publishedFeatures ?: 0,
            importedFavorites = catalog?.importedFavorites ?: 0,
        ).also {
            // Worth a line: an imported vector is an hour of analysis this
            // phone now never spends, and nothing else on the device says so.
            Log.i(
                TAG,
                "relay: ${it.importedHistory} plays, ${it.importedFeatures} vectors in, " +
                    "${it.publishedFeatures} out",
            )
        }
    }

    private companion object {
        const val TAG = "MozzRelay"
    }
}
