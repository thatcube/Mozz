package com.thatcube.mozz.analysis

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.util.Log
import androidx.core.content.ContextCompat
import com.thatcube.mozz.core.MozzServer
import com.thatcube.mozz.core.SonicProgress
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * Decides when the core may analyze the library, and tells it so.
 *
 * The analyzer itself lives in the Swift core and is the same code on every
 * platform. What is not the same is when it is fair to run: only this side can
 * see a charger and a metered connection, and analyzing a whole library is
 * hours of transcoding, downloading and DSP. So the core analyzes whenever it
 * is asked, and asking is this class's whole job.
 *
 * The terms, which match the iPhone's:
 *  - plugged in,
 *  - on an unmetered network,
 *  - and the app is open.
 *
 * The last one is a limitation rather than a principle — a foreground service
 * or a `WorkManager` job would let a library finish overnight, and is the
 * obvious next step. Until then a pass stops when the app goes away, which
 * costs nothing but time: every analyzed track is already saved, so the next
 * pass resumes where this one stopped.
 */
class SonicAnalysisController(
    context: Context,
    private val server: MozzServer,
    private val scope: CoroutineScope,
) {
    private val appContext = context.applicationContext
    private val connectivity =
        appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    private val _progress = MutableStateFlow<SonicProgress?>(null)
    /** What Settings shows. Null until a pass has been asked for. */
    val progress: StateFlow<SonicProgress?> = _progress.asStateFlow()

    private var serverId: String? = null
    private var watcher: Job? = null
    private var registered = false

    /** True while the mains and the network both say yes. */
    private var unmetered = false

    private val powerReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) = reconsider()
    }

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
            unmetered = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) &&
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
            reconsider()
        }

        override fun onLost(network: Network) {
            unmetered = false
            reconsider()
        }
    }

    /** The app came to the front with a library attached. */
    fun start(serverId: String) {
        this.serverId = serverId
        if (!registered) {
            registered = true
            // Through ContextCompat because Android 14 requires every runtime
            // receiver to declare its exportedness, and this one is ours alone.
            ContextCompat.registerReceiver(
                appContext,
                powerReceiver,
                IntentFilter().apply {
                    addAction(Intent.ACTION_POWER_CONNECTED)
                    addAction(Intent.ACTION_POWER_DISCONNECTED)
                },
                ContextCompat.RECEIVER_NOT_EXPORTED,
            )
            connectivity.registerDefaultNetworkCallback(networkCallback)
            unmetered = currentNetworkIsUnmetered()
        }
        reconsider()
    }

    /** The app went away. Stop asking, and stop the pass that is running. */
    fun stop() {
        if (registered) {
            registered = false
            runCatching { appContext.unregisterReceiver(powerReceiver) }
            runCatching { connectivity.unregisterNetworkCallback(networkCallback) }
        }
        watcher?.cancel()
        watcher = null
        scope.launch { runCatching { server.cancelSonics() } }
    }

    /** Conditions changed — start a pass, or stop the one in flight. */
    private fun reconsider() {
        val serverId = serverId ?: return
        if (isSatisfied()) {
            if (watcher?.isActive == true) return
            watcher = scope.launch {
                runCatching { server.analyzeSonics(serverId) }
                    .onSuccess { _progress.value = it }
                    .onFailure { Log.w(TAG, "could not start analysis", it) }
                // Follow the pass so Settings can show it moving. Cheap: one
                // small database read a few times a minute.
                while (true) {
                    delay(POLL_MS)
                    val progress = runCatching { server.sonicProgress(serverId) }.getOrNull()
                    _progress.value = progress ?: continue
                    if (!progress.running) return@launch
                }
            }
        } else {
            watcher?.cancel()
            watcher = null
            scope.launch { runCatching { server.cancelSonics() } }
        }
    }

    private fun isSatisfied(): Boolean = isCharging() && unmetered

    /**
     * Plugged in — not "actively charging".
     *
     * `BatteryManager.isCharging` is false on a phone sitting at 100% on a
     * charger, and false again while adaptive charging holds it back overnight.
     * Those are the best possible moments to analyze a library, so the question
     * to ask is whether the mains are paying, which is what `EXTRA_PLUGGED`
     * answers.
     */
    private fun isCharging(): Boolean {
        val battery = appContext.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            ?: return false
        return battery.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0
    }

    private fun currentNetworkIsUnmetered(): Boolean {
        val caps = connectivity.getNetworkCapabilities(connectivity.activeNetwork) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) &&
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
    }

    private companion object {
        const val TAG = "MozzSonic"
        const val POLL_MS = 15_000L
    }
}
