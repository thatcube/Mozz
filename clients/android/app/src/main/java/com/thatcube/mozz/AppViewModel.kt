package com.thatcube.mozz

import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.thatcube.mozz.core.MusicLibrary
import com.thatcube.mozz.core.MozzLibrary
import com.thatcube.mozz.core.MozzPlaybackSettings
import com.thatcube.mozz.core.MozzServer
import com.thatcube.mozz.core.PlaybackSettings
import com.thatcube.mozz.core.PlexHomeUser
import com.thatcube.mozz.core.PlexLink
import com.thatcube.mozz.core.ServerAccount
import com.thatcube.mozz.core.SyncStatus
import com.thatcube.mozz.continuity.ContinuityCoordinator
import com.thatcube.mozz.continuity.ContinuityOffer
import com.thatcube.mozz.playback.PlayerController
import com.thatcube.mozz.relay.RelayService
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

    /**
     * More than one person on this Plex Home, so the choice is theirs.
     *
     * Carries the account token because the choice is not finished until it is
     * made: a managed profile has to be switched to before there is a session
     * at all.
     */
    data class ChoosingProfile(
        val accountToken: String,
        val clientIdentifier: String,
        val users: List<PlexHomeUser>,
    ) : AppState

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
    /**
     * Null where nothing has wired it — the relay is the one dependency here
     * that a device may legitimately not have, and an optional says so more
     * honestly than a stub that quietly does nothing.
     */
    private val relay: RelayService? = null,
    /**
     * Cross-device resume. Null where nothing wired it, which is the same
     * honesty as [relay]: a device may legitimately not have one.
     */
    private val continuity: ContinuityCoordinator? = null,
    private val playback: PlayerController? = null,
    /** The sound-shaping settings the core owns and the relay carries. */
    private val playbackSettings: MozzPlaybackSettings? = null,
    /**
     * Where to put the levelling flag so the player can read it without a round
     * trip. The core is the record; this is the mirror in front of it.
     */
    private val mirrorNormalization: ((Boolean) -> Unit)? = null,
) : ViewModel() {

    private val _continuityOffer = MutableStateFlow<ContinuityOffer?>(null)

    /**
     * What another device left off at, when it is worth offering.
     *
     * Null is the ordinary state: nothing stored, this device's own
     * checkpoint, something already playing here, or a server with no store
     * for it at all — which is every Plex server, and is not a failure.
     */
    val continuityOffer: StateFlow<ContinuityOffer?> = _continuityOffer.asStateFlow()

    fun dismissContinuityOffer() {
        _continuityOffer.value = null
    }

    /**
     * Turn loudness levelling on or off, in the place that syncs.
     *
     * The switch has already moved locally; this is the record. Everything else
     * in the stored settings is carried through untouched — Android has no
     * equalizer screen, and a phone that wrote a flat curve whenever somebody
     * touched this switch would erase the curve its owner set on their desktop.
     */
    suspend fun setNormalization(enabled: Boolean) {
        val client = playbackSettings ?: return
        val current = runCatching { client.get() }.getOrNull() ?: PlaybackSettings()
        runCatching { client.set(current.normalizing(enabled)) }
    }

    /**
     * Adopt whatever the core holds, which may be what another device chose.
     *
     * Read on attach rather than only written: settings that only ever travel
     * outward are not synced settings, they are a local copy with extra steps.
     */
    private fun adoptPlaybackSettings() = viewModelScope.launch {
        val stored = runCatching { playbackSettings?.get() }.getOrNull() ?: return@launch
        mirrorNormalization?.invoke(stored.normalizesVolume)
    }

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
                else -> {
                    _state.value = AppState.Ready(account)
                    verifyReachable(account)
                    flushFavorites(account.serverId)
                    syncCircle(account)
                    watchContinuity(account)
                    adoptPlaybackSettings()
                }
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
        runCatching { server.awaitPlexAccountToken(link) }
            .onSuccess { accountToken -> chooseProfileOrComplete(accountToken, link) }
            .onFailure { fail("Plex link", it, resumeLink = link) }
    }

    /**
     * Ask who this is, when the account holds more than one person.
     *
     * One person is not a decision worth interrupting anybody for, and neither
     * is a Home the account cannot tell us about: if the lookup fails we sign
     * in as the account owner, which is exactly what happened before this
     * existed. Sign-in must not hinge on an optional Plex feature.
     */
    private suspend fun chooseProfileOrComplete(accountToken: String, link: PlexLink) {
        val users = runCatching { server.plexHomeUsers(accountToken, link.clientIdentifier) }
            .getOrDefault(emptyList())
        if (users.size > 1) {
            _state.value = AppState.ChoosingProfile(accountToken, link.clientIdentifier, users)
            return
        }
        completeLogin(accountToken, link.clientIdentifier, users.firstOrNull(), profilePin = null)
    }

    fun selectProfile(
        accountToken: String,
        clientIdentifier: String,
        user: PlexHomeUser,
        profilePin: String? = null,
    ) = viewModelScope.launch {
        _state.value = AppState.Starting
        completeLogin(accountToken, clientIdentifier, user, profilePin)
    }

    private suspend fun completeLogin(
        accountToken: String,
        clientIdentifier: String,
        user: PlexHomeUser?,
        profilePin: String?,
    ) {
        runCatching { server.completePlexLogin(accountToken, clientIdentifier, user, profilePin) }
            .onSuccess { account -> chooseLibraryOrSync(account) }
            .onFailure { fail("Signing in", it) }
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

    /**
     * Check that the address this account is pinned to still answers, and quietly
     * move to one that does if it does not.
     *
     * Runs after the library is already on screen, not before, because it costs a
     * round trip and the catalogue is local — making launch wait on the network
     * to show music that is already on the device would be a bad trade. The
     * symptom this catches is otherwise silent and total: every cover grey, every
     * track refusing to play, with a library that looks intact. See ADR-0017.
     */
    private fun verifyReachable(account: ServerAccount) = viewModelScope.launch {
        // `libraries` is a real request to the server (Plex answers it from
        // library/sections), so it fails exactly when the address is dead.
        val repointed = if (runCatching { server.libraries(account.serverId) }.isSuccess) {
            // It answers — but answering is not the same as being the right
            // address. A phone that fell back to its server's public address
            // keeps it for as long as it works, sending every byte of audio out
            // of the house and back while the server sits on the same wifi.
            runCatching { server.preferLocalAddress(account) }.getOrNull()
        } else {
            runCatching { server.repointAccount(account) }.getOrNull()
        } ?: return@launch
        if (_state.value is AppState.Ready) _state.value = AppState.Ready(repointed)
    }

    private fun sync(account: ServerAccount) = viewModelScope.launch {
        _state.value = AppState.Syncing(account.serverName, null)
        var target = account
        runCatching {
            // Not a plain attach. A Plex account carries no library section
            // until something resolves one, and syncing without it fails with
            // "Plex music section not resolved" every time it is retried. The
            // library picker resolves it at onboarding — but an account whose
            // onboarding was interrupted reaches here without ever having been
            // asked, and would then be permanently unsyncable.
            target = server.attachForSync(target)
            server.sync(target.serverId).collect { status ->
                _state.value = AppState.Syncing(target.serverName, status)
            }
        }.recoverCatching { error ->
            // A sync that fails against a dead address fails the same way every
            // time it is retried, because every retry goes to the same address.
            // Ask the account for a working one and run it again — once. A null
            // means there was nothing better to move to, and the original error
            // is the honest one to report.
            target = server.attachForSync(server.repointAccount(target) ?: throw error)
            server.sync(target.serverId).collect { status ->
                _state.value = AppState.Syncing(target.serverName, status)
            }
        }.onSuccess {
            _state.value = AppState.Ready(target)
            flushFavorites(target.serverId)
            syncCircle(target)
            watchContinuity(target)
            adoptPlaybackSettings()
        }
            .onFailure { fail("Sync", it) }
    }

    /**
     * Send likes and ratings that never reached the server.
     *
     * Called where the server has just proved it answers — a fresh attach and a
     * finished sync — because those are the two moments something queued while
     * offline is most likely to go through. Failure is not reported: a like
     * that stays queued is exactly what the queue is for.
     */
    private fun flushFavorites(serverId: String) = viewModelScope.launch {
        runCatching { library.flushFavoriteOutbox(serverId) }
    }

    /**
     * Trade with the rest of the circle: listening history out and back, and
     * the analysed vectors this phone would otherwise spend an evening
     * recomputing.
     *
     * Does nothing on a device that has not been paired, which is not a
     * failure and is not reported as one. Fired at the same two moments the
     * favourite flush is, for the same reason: those are when the network has
     * just proved it works.
     */
    private fun syncCircle(account: ServerAccount) = viewModelScope.launch {
        runCatching { relay?.sync(account) }
    }

    /**
     * Read what another device left, then start writing what this one is doing.
     *
     * In that order and not the other way round: a phone paused in a pocket
     * while a laptop took over would otherwise publish what it remembered and
     * clobber the newer session before it had read it.
     */
    private fun watchContinuity(account: ServerAccount) = viewModelScope.launch {
        val coordinator = continuity ?: return@launch
        val player = playback ?: return@launch
        _continuityOffer.value = runCatching {
            coordinator.reconcile(
                serverId = account.serverId,
                isPlayingLocally = player.state.value.isPlaying,
            )
        }.getOrNull()

        player.onCheckpoint = { reason ->
            val snapshot = player.state.value
            viewModelScope.launch {
                coordinator.checkpoint(
                    reason = reason,
                    account = account,
                    queue = snapshot.queue,
                    indexInQueue = snapshot.indexInQueue,
                    positionMS = snapshot.positionMillis,
                    isPlaying = snapshot.intendsToPlay,
                    repeatMode = snapshot.repeat.name.lowercase(),
                    isShuffled = snapshot.shuffle,
                )
            }
        }
    }

    /**
     * Take up the offer: rebuild what the other device was playing and drop in
     * where it left off.
     *
     * The queue is resolved a track at a time through the catalogue, because a
     * checkpoint carries locators and titles rather than playable rows. A queue
     * that cannot be rebuilt still leaves the one song, which is the part
     * somebody actually wanted back.
     */
    fun resumeContinuity() = viewModelScope.launch {
        val offer = _continuityOffer.value ?: return@launch
        val account = (state.value as? AppState.Ready)?.account ?: return@launch
        val player = playback ?: return@launch
        _continuityOffer.value = null

        val cursor = offer.snapshot.cursor
        val hydrated = offer.snapshot.hydratedTracks.associateBy { it.remoteId }
        val wanted = offer.snapshot.queue?.items?.map { it.locator.remoteId }
            ?: listOf(cursor.current.remoteId)
        val tracks = wanted.take(RESUME_QUEUE_LIMIT).mapNotNull { remoteId ->
            hydrated[remoteId]
                ?: runCatching { library.track(account.serverId, remoteId) }.getOrNull()
        }
        if (tracks.isEmpty()) return@launch

        val startAt = tracks.indexOfFirst { it.remoteId == cursor.current.remoteId }.coerceAtLeast(0)
        player.play(tracks, startAt).join()
        if (cursor.positionMS > 0) player.seekTo(cursor.positionMS)
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
                AppViewModel(
                    application.server,
                    application.library,
                    application.relay,
                    application.continuity,
                    application.playback,
                    application.playbackSettings,
                    { application.settings.normalizeVolume = it },
                )
            }
        }

        private const val TAG = "Mozz"
    }
}

/**
 * How much of another device's queue to rebuild.
 *
 * A screen's worth, not a library: resolving is a round trip per track, and
 * nobody resumes into two hundred songs they need immediately.
 */
private const val RESUME_QUEUE_LIMIT = 200
