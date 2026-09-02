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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
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
}
