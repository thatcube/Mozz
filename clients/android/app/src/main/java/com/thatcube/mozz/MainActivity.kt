package com.thatcube.mozz

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.core.net.toUri
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.launch
import com.thatcube.mozz.ui.FailedScreen
import com.thatcube.mozz.ui.MozzShell
import com.thatcube.mozz.ui.LibraryPickerScreen
import com.thatcube.mozz.ui.LinkingScreen
import com.thatcube.mozz.ui.SignInScreen
import com.thatcube.mozz.ui.StartingScreen
import com.thatcube.mozz.ui.SyncingScreen
import com.thatcube.mozz.ui.theme.LocalMozzSettings
import com.thatcube.mozz.ui.theme.MozzTheme

class MainActivity : ComponentActivity() {

    private val viewModel: AppViewModel by viewModels { AppViewModel.Factory }

    /**
     * The transport notification *is* the foreground service's notification, so
     * without this permission playback still works but the lock-screen and shade
     * controls do not appear. Asked for once, at launch, and never insisted on:
     * denying it costs the notification, not the music.
     */
    private val notificationPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    /**
     * Reaching a server on the listener's own network.
     *
     * Unlike the notification permission, this one is close to the point of the
     * app. Android 16 brought in Local Network Protections and by Android 17
     * they bite: without this, the phone can talk to the public internet but
     * not to 192.168.x.x, so a Plex or Jellyfin server sitting on the same wifi
     * is unreachable — and the failure is silent and misleading, because every
     * other app on the phone can reach it and the client quietly falls back to
     * a relay. Denying it does not break Mozz; it makes it slower and, on a
     * server with no remote access at all, useless.
     */
    private val localNetworkPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        // Named as a string rather than through `Manifest.permission`: the
        // constant only exists in the SDK this shipped in, and compiling
        // against an older one would fail rather than degrade. Asking for a
        // permission the platform has never heard of is a no-op.
        if (checkSelfPermission(LOCAL_NETWORK_PERMISSION) != PackageManager.PERMISSION_GRANTED) {
            localNetworkPermission.launch(LOCAL_NETWORK_PERMISSION)
        }
        val settings = (application as MozzApplication).settings
        // Analysis runs only while the app is on screen (and only on a charger,
        // on an unmetered network — the controller decides). Tied to STARTED so
        // it stops the moment the app is backgrounded rather than running on
        // somebody's battery behind their back.
        val sonicAnalysis = (application as MozzApplication).sonicAnalysis
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                try {
                    viewModel.state.collect { state ->
                        if (state is AppState.Ready) sonicAnalysis.start(state.account.serverId)
                    }
                } finally {
                    sonicAnalysis.stop()
                }
            }
        }
        setContent {
            MozzTheme(settings) {
                // Provided rather than passed down: the only thing that reads it
                // is the appearance page, and threading it through six screens to
                // reach one would be worse than a local.
                CompositionLocalProvider(LocalMozzSettings provides settings) {
                    val state by viewModel.state.collectAsStateWithLifecycle()
                    Root(state)
                }
            }
        }
    }

    @Composable
    private fun Root(state: AppState) {
        when (state) {
            AppState.Starting -> StartingScreen()

            AppState.SignedOut -> SignInScreen(onConnectPlex = viewModel::beginPlexLink)

            is AppState.Linking -> LinkingScreen(
                onOpenBrowser = { openLink(state.link.linkUrl) },
                onCancel = viewModel::signOut,
            )

            is AppState.ChoosingLibrary -> LibraryPickerScreen(
                serverName = state.account.serverName,
                libraries = state.libraries,
                onSelect = { viewModel.selectLibrary(state.account, it.id) },
            )

            is AppState.Syncing -> SyncingScreen(state.serverName, state.status)

            is AppState.Ready -> MozzShell(
                account = state.account,
                library = (application as MozzApplication).library,
                server = (application as MozzApplication).server,
                playback = (application as MozzApplication).playback,
                toasts = (application as MozzApplication).toasts,
                onResync = viewModel::resync,
                onSignOut = viewModel::signOut,
            )

            is AppState.Failed -> FailedScreen(
                message = state.message,
                canRetry = state.canRetry,
                onRetry = viewModel::retry,
                onSignOut = viewModel::signOut,
            )
        }
    }

    /**
     * Hand the Plex approval to a browser rather than an in-app WebView. The
     * user signs in to Plex on Plex's own origin, with their own session and
     * password manager, and Mozz never sees a credential.
     */
    private fun openLink(url: String?) {
        val target = url?.takeIf { it.isNotBlank() }?.toUri()
            ?: "https://plex.tv/link".toUri()
        startActivity(Intent(Intent.ACTION_VIEW, target))
    }
    private companion object {
        const val LOCAL_NETWORK_PERMISSION = "android.permission.ACCESS_LOCAL_NETWORK"
    }

}
