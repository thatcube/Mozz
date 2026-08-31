package com.thatcube.mozz

import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.thatcube.mozz.core.MusicLibrary
import com.thatcube.mozz.core.MozzLibrary
import com.thatcube.mozz.core.MozzServer
import com.thatcube.mozz.core.PlexLink
import com.thatcube.mozz.core.ServerAccount
import com.thatcube.mozz.core.SyncStatus
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * Where the app is in getting someone to their music.
 *
 * One linear path, because that is what it is: no account → link Plex → pick a
 * library if there is a choice → mirror the catalogue → listen. Each state
 * carries what its screen needs and nothing else.
 */
sealed interface AppState {
    /** Opening the library and re-attaching saved accounts. */
    data object Starting : AppState

    data object SignedOut : AppState

    /** Plex has issued a PIN; the user approves it in a browser. */
    data class Linking(val link: PlexLink, val waiting: Boolean = true) : AppState

    /** More than one music library on the server, so the choice is theirs. */
    data class ChoosingLibrary(
        val account: ServerAccount,
        val libraries: List<MusicLibrary>,
    ) : AppState

    data class Syncing(val serverName: String, val status: SyncStatus?) : AppState

    data class Ready(val account: ServerAccount) : AppState

    /**
     * [resumeLink] is the Plex link this failed during, if any. Retrying with it
     * resumes the *same* PIN: the user may already have approved it, and issuing
     * a fresh one silently throws that approval away and asks them to do it
     * again — which is what made a transient error look like a broken sign-in.
     */
    data class Failed(
        val message: String,
        val canRetry: Boolean = true,
        val resumeLink: PlexLink? = null,
    ) : AppState
}

class AppViewModel(
    private val server: MozzServer,
    private val library: MozzLibrary,
) : ViewModel() {

    private val _state = MutableStateFlow<AppState>(AppState.Starting)
    val state: StateFlow<AppState> = _state.asStateFlow()

    init {
        restore()
    }

    /**
     * Re-attach whatever was signed in last time.
     *
     * The core forgets tokens between launches by design, so nothing works until
     * the saved account is attached again — including playback of an album the
     * user was halfway through.
     */
    private fun restore() = viewModelScope.launch {
        _state.value = AppState.Starting
        runCatching {
            val account = server.savedAccounts().firstOrNull()
                ?: return@runCatching null
            server.attach(account)
            account
        }.onSuccess { account ->
            when {
                account == null -> _state.value = AppState.SignedOut
                // Attached, but nothing was ever mirrored — a sign-in that broke
                // partway leaves exactly this state, and showing an empty Home
                // makes it look like the server has no music.
                library.counts(account.serverId).tracks == 0 -> sync(account)
                else -> _state.value = AppState.Ready(account)
            }
        }.onFailure { error ->
            // A stored account that will not attach is not fatal — the token may
            // simply have been revoked. Offer signing in again rather than a
            // dead screen.
            fail("Reopening your library", error)
        }
    }

    /** Ask Plex for a PIN. The returned link is what the user opens in a browser. */
    fun beginPlexLink() = viewModelScope.launch {
        _state.value = AppState.Starting
        runCatching { server.beginPlexLink() }
            .onSuccess { link ->
                _state.value = AppState.Linking(link)
                awaitLink(link)
            }
            .onFailure { fail("Asking Plex for a PIN", it) }
    }

    private fun awaitLink(link: PlexLink) = viewModelScope.launch {
        runCatching { server.awaitPlexLink(link) }
            .onSuccess { account -> chooseLibraryOrSync(account) }
            .onFailure { fail("Plex link", it, resumeLink = link) }
    }

    /**
     * Plex addresses its catalogue by library section, and a freshly linked
     * account has none. One music library is not a decision worth interrupting
     * someone for; several is.
     */
    private suspend fun chooseLibraryOrSync(account: ServerAccount) {
        runCatching {
            server.attach(account)
            server.libraries(account.serverId)
        }.onSuccess { libraries ->
            when {
                libraries.isEmpty() -> _state.value = AppState.Failed(
                    "${account.serverName} has no music library for Mozz to sync.",
                    canRetry = false,
                )
                libraries.size == 1 -> selectLibrary(account, libraries.first().id)
                else -> _state.value = AppState.ChoosingLibrary(account, libraries)
            }
        }.onFailure { fail("Reading libraries", it) }
    }

    fun selectLibrary(account: ServerAccount, libraryId: String) = viewModelScope.launch {
        runCatching { server.selectMusicLibrary(account, libraryId) }
            .onSuccess { sync(it) }
            .onFailure { fail("Selecting a library", it) }
    }

    private fun sync(account: ServerAccount) = viewModelScope.launch {
        _state.value = AppState.Syncing(account.serverName, null)
        runCatching {
            server.sync(account.serverId).collect { status ->
                _state.value = AppState.Syncing(account.serverName, status)
            }
        }.onSuccess { _state.value = AppState.Ready(account) }
            .onFailure { fail("Sync", it) }
    }

    /** Re-mirror the catalogue for the account already signed in. */
    fun resync() {
        (state.value as? AppState.Ready)?.let { sync(it.account) }
    }

    fun signOut() = viewModelScope.launch {
        server.forgetAllAccounts()
        _state.value = AppState.SignedOut
    }

    /**
     * Resume from wherever this broke, in order of how much would otherwise be
     * lost: an approved Plex PIN first, then a signed-in account that has not
     * finished mirroring, and only then a cold restart.
     */
    fun retry() {
        val failure = state.value as? AppState.Failed
        val link = failure?.resumeLink
        when {
            link != null -> {
                _state.value = AppState.Linking(link)
                awaitLink(link)
            }
            server.savedAccounts().isNotEmpty() -> viewModelScope.launch {
                chooseLibraryOrSync(server.savedAccounts().first())
            }
            else -> restore()
        }
    }

    private fun fail(what: String, error: Throwable, resumeLink: PlexLink? = null) {
        // Logged as well as shown: an on-screen message the user reads aloud is
        // not a stack trace, and this is exactly where a wire-shape mismatch
        // surfaces.
        Log.e(TAG, "$what failed", error)
        _state.value = AppState.Failed(
            message = error.message ?: "$what did not work.",
            resumeLink = resumeLink,
        )
    }

    companion object {
        val Factory: ViewModelProvider.Factory = viewModelFactory {
            initializer {
                val application =
                    this[ViewModelProvider.AndroidViewModelFactory.APPLICATION_KEY]
                        as MozzApplication
                AppViewModel(application.server, application.library)
            }
        }

        private const val TAG = "Mozz"
    }
}
