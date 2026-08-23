#if os(iOS)
import CarPlay
import MozzPlayback
import Observation
import UIKit

/// The CarPlay scene.
///
/// CarPlay can launch the app entirely on its own — you get in, the head unit
/// connects, and this runs with no window scene ever created. Everything it needs
/// therefore comes from ``SharedEnvironment``, which owns the database, playback
/// engine and session for the whole process rather than for any one scene.
@objc(MozzCarPlaySceneDelegate)
@MainActor
final class MozzCarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var browser: CarPlayBrowser?
    private var nowPlayingObserver: CarPlayNowPlayingObserver?
    private var failureObserver: CarPlayFailureObserver?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        // No actor hop needed: CarPlay annotates its template APIs
        // NS_SWIFT_UI_ACTOR, so these callbacks already arrive on the main actor.
        do {
            let env = SharedEnvironment.shared
            let browser = CarPlayBrowser(env: env, interfaceController: interfaceController)
            self.browser = browser
            self.nowPlayingObserver = CarPlayNowPlayingObserver(
                playback: env.playback, interfaceController: interfaceController
            )
            // Surface a failed play as an alert instead of the silence the engine
            // used to leave behind.
            self.failureObserver = CarPlayFailureObserver(playback: env.playback) { [weak browser] failure in
                browser?.presentFailure(failure)
            }

            // Never pass a nil completion to a CarPlay template operation: the
            // framework raises an ObjC exception when an operation fails and no
            // completion was given, and an exception out of a delegate callback
            // is an instant crash in the car.
            interfaceController.setRootTemplate(
                browser.makeRootTemplate(), animated: false
            ) { _, _ in }

            // A cold start from the car has not restored the session yet, so the
            // first templates would query an unopened library. Kick the shared
            // startup and rebuild once it lands; when the phone got there first
            // this is already complete and returns immediately.
            let wasSignedIn = env.active != nil
            Task { @MainActor [weak self] in
                // Know what's playable without the server before the first list is
                // built, so downloads are marked from the outset rather than
                // appearing a beat later.
                await browser.refreshOfflineState()
                await SharedEnvironment.start()
                guard let self, self.interfaceController === interfaceController else { return }
                // Only rebuild if the wait actually changed anything, and only if
                // the driver hasn't navigated in the meantime. Startup can take
                // seconds on a cold start, the first root is live and interactive
                // throughout, and setRootTemplate replaces the WHOLE stack — so
                // rebuilding unconditionally would yank someone browsing an album
                // back to the root with no explanation. On the warm path it was
                // also pure waste: a second tab bar and five more queries.
                await browser.refreshOfflineState()
                let signedInNow = env.active != nil
                if signedInNow != wasSignedIn, interfaceController.templates.count <= 1 {
                    interfaceController.setRootTemplate(
                        browser.makeRootTemplate(), animated: false
                    ) { _, _ in }
                }
                // Something already playing when the car connects (the phone was
                // mid-song) should be visible, not buried under the library.
                if env.playback.currentTrack != nil, interfaceController.templates.count <= 1 {
                    interfaceController.pushTemplate(
                        CPNowPlayingTemplate.shared, animated: false
                    ) { _, _ in }
                }
            }
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        // Everything here holds the interface controller, directly or otherwise;
        // dropping it all is what keeps the app from leaking a dead car session.
        nowPlayingObserver = nil
        failureObserver = nil
        browser = nil
        self.interfaceController = nil
    }
}

/// Keeps `CPNowPlayingTemplate` in step with the player.
///
/// The template reads title, artist, artwork and progress from
/// `MPNowPlayingInfoCenter`, which the app already maintains, so none of that
/// needs repeating here. What it does NOT infer is the state of its own buttons —
/// shuffle and repeat have to be rebuilt whenever the mode changes, and the
/// up-next button has to be disabled when the queue is empty.
@MainActor
final class CarPlayNowPlayingObserver: NSObject, CPNowPlayingTemplateObserver {
    private let playback: PlaybackEngine
    /// Weak: the interface controller owns this scene's navigation, and holding it
    /// strongly here would keep a disconnected car session alive.
    private weak var interfaceController: CPInterfaceController?
    private let queueTitle: String

    init(playback: PlaybackEngine, interfaceController: CPInterfaceController) {
        self.playback = playback
        self.interfaceController = interfaceController
        self.queueTitle = "Up Next"
        super.init()
        CPNowPlayingTemplate.shared.add(self)
        apply()
        observe()
    }

    deinit {
        // The template is a process-wide singleton and outlives every car
        // session, so an observer that doesn't remove itself here is a leak that
        // accumulates one entry per connect.
        CPNowPlayingTemplate.shared.remove(self)
    }

    // MARK: CPNowPlayingTemplateObserver

    /// Show what's coming up. The button is only enabled when there IS something,
    /// so this always has content to display.
    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        let upNext = playback.upNext
        guard !upNext.isEmpty, let interfaceController else { return }
        // CarPlay caps the navigation stack at five. The deepest browse route —
        // tabs ▸ genres ▸ albums ▸ tracks ▸ Now Playing — already sits exactly at
        // the cap, so pushing from there would fail; with no completion block
        // that failure is a raised exception rather than a no-op.
        guard interfaceController.templates.count < Self.maximumStackDepth else { return }

        let items: [CPListItem] = upNext.prefix(CPListTemplate.maximumItemCount).map { track in
            let item = CPListItem(text: track.title, detailText: track.artistName)
            let trackID = track.id
            item.handler = { [weak self, weak interfaceController] _, completion in
                // Resolve the track's CURRENT position at tap time rather than
                // trusting the index this row was built with. These rows are a
                // snapshot; if a song finishes while the driver is reading the
                // list, every stored offset is one out and tapping would play the
                // wrong song. The phone's queue avoids this by recomputing the
                // base in the same pass that renders the rows — a template gets
                // no such re-render, so identity is the only stable handle.
                guard let self, let interfaceController else { return completion() }
                guard let offset = playback.upNext.firstIndex(where: { $0.id == trackID }) else {
                    // Already played or removed — do nothing rather than jump
                    // somewhere arbitrary.
                    return completion()
                }
                playback.jump(toOrderPosition: playback.history.count + 1 + offset)
                interfaceController.popTemplate(animated: true) { _, _ in completion() }
            }
            return item
        }
        let template = CPListTemplate(title: queueTitle, sections: [CPListSection(items: items)])
        interfaceController.pushTemplate(template, animated: true) { _, _ in }
    }

    /// CarPlay's maximum template navigation depth.
    private static let maximumStackDepth = 5

    /// Re-apply whenever the queue or the shuffle/repeat mode changes.
    ///
    /// `queueRevision` is bumped on every queue publish — track changes,
    /// reordering, mode toggles — and it is an `Int`, so observing it is far
    /// cheaper than watching the track arrays. Observation is re-armed after each
    /// change because `withObservationTracking` fires once.
    private func observe() {
        withObservationTracking {
            _ = playback.queueRevision
        } onChange: { [weak self] in
            // `onChange` fires just BEFORE the value is committed, so read it on
            // the next main-actor turn to see the settled state.
            Task { @MainActor [weak self] in
                guard let self else { return }
                apply()
                observe()
            }
        }
    }

    private func apply() {
        let template = CPNowPlayingTemplate.shared
        let snapshot = playback.snapshot
        template.isUpNextButtonEnabled = !playback.upNext.isEmpty
        template.upNextTitle = queueTitle
        // Nothing is wired to the album/artist button, so leave it off rather
        // than showing a control that does nothing.
        template.isAlbumArtistButtonEnabled = false

        let shuffle = CPNowPlayingShuffleButton { [weak self] _ in
            self?.playback.toggleShuffle()
            self?.apply()
        }
        let repeatButton = CPNowPlayingRepeatButton { [weak self] _ in
            self?.playback.cycleRepeatMode()
            self?.apply()
        }
        // CarPlay's shuffle and repeat buttons are stateless — they don't render a
        // selected state — so the modes are surfaced in the button row order and
        // through the phone. Rebuilding them on every change keeps their handlers
        // bound to the current engine state.
        _ = snapshot
        template.updateNowPlayingButtons([shuffle, repeatButton])
    }
}

/// Watches for a playback failure and hands it to the car.
///
/// Separate from the Now Playing observer because it reacts to a different thing:
/// that one mirrors queue state onto a template, this one reports an event once,
/// when it happens.
@MainActor
final class CarPlayFailureObserver {
    private let playback: PlaybackEngine
    private let onFailure: (PlaybackFailure) -> Void

    init(playback: PlaybackEngine, onFailure: @escaping (PlaybackFailure) -> Void) {
        self.playback = playback
        self.onFailure = onFailure
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = playback.lastFailure
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // `onChange` fires before the value is committed, so read it on the
                // next turn to see what actually landed.
                if let failure = playback.lastFailure { onFailure(failure) }
                observe()
            }
        }
    }
}
#endif
