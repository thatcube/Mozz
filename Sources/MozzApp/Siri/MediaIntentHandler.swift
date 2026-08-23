#if os(iOS)
import Foundation
import Intents
import MediaPlayer
import MozzCore
import UIKit

/// Answers Siri's media requests — including the ones that arrive from a HomePod.
///
/// A HomePod has no apps of its own: it parses the request, then forwards a
/// SiriKit media intent to the iPhone, where Mozz starts playing and the audio is
/// AirPlayed back to the speaker. The same intents arrive from CarPlay, the Siri
/// button, and Shortcuts, so this one handler serves them all.
///
/// Two constraints shape everything here. The app is frequently launched straight
/// into the background with no window ever created, so nothing may be assumed
/// about the session already being restored; and Siri abandons a request after
/// ten seconds, so every path is bounded and answers with a specific reason
/// rather than stalling.
final class MediaIntentHandler: NSObject {
    // MARK: Play

    func resolveMediaItems(for intent: INPlayMediaIntent,
                           with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void) {
        Task { @MainActor in
            let outcome = await Self.resolve(intent.mediaSearch)
            switch outcome {
            case .resolved(let resolution):
                MediaIntentCache.store(resolution)
                let item = await Self.mediaItem(for: resolution)
                completion(INPlayMediaMediaItemResolutionResult.successes(with: [item]))
            case .notFound:
                // Siri's own "I couldn't find that in your Mozz library", which is
                // exactly right when the words were specific and the library
                // simply doesn't have it.
                completion([INPlayMediaMediaItemResolutionResult.unsupported()])
            case .unsupportedMediaType:
                completion([.unsupported(forReason: .unsupportedMediaType)])
            case .signInRequired:
                completion([.unsupported(forReason: .loginRequired)])
            case .serviceUnavailable:
                completion([.unsupported(forReason: .serviceUnavailable)])
            }
        }
    }

    func handle(intent: INPlayMediaIntent,
                completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        Task { @MainActor in
            completion(await Self.play(intent))
        }
    }

    @MainActor
    private static func play(_ intent: INPlayMediaIntent) async -> INPlayMediaIntentResponse {
        guard await prepareEnvironment() else {
            return INPlayMediaIntentResponse(code: .failure, userActivity: nil)
        }
        let env = SharedEnvironment.shared

        // "Keep playing" / "resume": nothing was named, so pick up where the
        // queue left off rather than starting something new.
        if intent.resumePlayback == true, intent.mediaItems?.isEmpty ?? true,
           env.playback.currentTrack != nil {
            env.playback.resume()
            return response(.success, env: env)
        }

        guard case .resolved(let resolution) = await resolve(intent.mediaSearch,
                                                            resolved: intent.mediaItems) else {
            return INPlayMediaIntentResponse(code: .failure, userActivity: nil)
        }

        switch intent.playbackQueueLocation {
        case .next:
            env.playback.playNext(resolution.tracks)
        case .later:
            env.playback.append(resolution.tracks)
        default:
            await start(resolution, intent: intent, env: env)
        }

        switch intent.playbackRepeatMode {
        case .all: env.playback.setRepeatMode(.all)
        case .one: env.playback.setRepeatMode(.one)
        case .none: env.playback.setRepeatMode(.off)
        default: break
        }

        // Donate what Siri just played. This is how App Selection learns that
        // music requests belong to Mozz, and eventually routes a bare "play
        // music" here without the app being named at all.
        SiriMediaSuggestions.donate(resolution)
        return response(.success, env: env)
    }

    @MainActor
    private static func start(_ resolution: MediaIntentResolution,
                              intent: INPlayMediaIntent, env: AppEnvironment) async {
        if intent.playShuffled ?? resolution.prefersShuffle {
            // The same recency weighting the app's own Shuffle uses, so a spoken
            // shuffle of a large library feels as fresh as tapping the button.
            // Deliberately not the taste-ranked Smart Shuffle: scoring every track
            // would eat into the ten seconds Siri allows.
            var recency: [String: Double]?
            if resolution.tracks.count > 50, let serverId = env.active?.connection.id {
                recency = try? await env.recommendations.recencyScores(serverId: serverId)
            }
            env.playback.playShuffled(resolution.tracks, recencyScores: recency)
        } else {
            env.playback.play(tracks: resolution.tracks)
        }

        if resolution.continuesAsStation, let seed = env.playback.currentTrack {
            env.continueStation(fromTrack: seed)
        }
    }

    // MARK: Add to library

    func resolveMediaItems(for intent: INAddMediaIntent,
                           with completion: @escaping ([INAddMediaMediaItemResolutionResult]) -> Void) {
        Task { @MainActor in
            // Mozz plays a library the user already owns and cannot write
            // playlists back to a server, so only "add to my library" is
            // answerable. Say so plainly rather than silently doing something
            // else with a playlist request.
            if let destination = intent.mediaDestination, case .playlist = destination {
                completion([.unsupported(forReason: .unsupportedMediaType)])
                return
            }
            switch await Self.resolve(intent.mediaSearch) {
            case .resolved(let resolution):
                MediaIntentCache.store(resolution)
                let item = await Self.mediaItem(for: resolution)
                completion(INAddMediaMediaItemResolutionResult.successes(with: [item]))
            case .notFound:
                completion([INAddMediaMediaItemResolutionResult.unsupported()])
            case .unsupportedMediaType:
                completion([.unsupported(forReason: .unsupportedMediaType)])
            case .signInRequired:
                completion([.unsupported(forReason: .loginRequired)])
            case .serviceUnavailable:
                completion([.unsupported(forReason: .serviceUnavailable)])
            }
        }
    }

    func handle(intent: INAddMediaIntent,
                completion: @escaping (INAddMediaIntentResponse) -> Void) {
        Task { @MainActor in
            var isPlaylistDestination = false
            if let destination = intent.mediaDestination, case .playlist = destination {
                isPlaylistDestination = true
            }
            guard !isPlaylistDestination,
                  await Self.prepareEnvironment(),
                  case .resolved(let resolution) = await Self.resolve(intent.mediaSearch,
                                                                     resolved: intent.mediaItems)
            else {
                completion(INAddMediaIntentResponse(code: .failure, userActivity: nil))
                return
            }
            // The "library" here is the user's own server, which already holds the
            // song — so adding it means marking it as one they like, the same
            // write the heart button makes.
            await Self.setLiked(true, tracks: resolution.tracks)
            completion(INAddMediaIntentResponse(code: .success, userActivity: nil))
        }
    }

    // MARK: Like / dislike

    func resolveMediaItems(for intent: INUpdateMediaAffinityIntent,
                           with completion: @escaping ([INUpdateMediaAffinityMediaItemResolutionResult]) -> Void) {
        Task { @MainActor in
            switch await Self.resolve(intent.mediaSearch) {
            case .resolved(let resolution):
                MediaIntentCache.store(resolution)
                let item = await Self.mediaItem(for: resolution)
                completion(INUpdateMediaAffinityMediaItemResolutionResult.successes(with: [item]))
            case .notFound:
                completion([INUpdateMediaAffinityMediaItemResolutionResult.unsupported()])
            case .unsupportedMediaType:
                completion([.unsupported(forReason: .unsupportedMediaType)])
            case .signInRequired:
                completion([.unsupported(forReason: .loginRequired)])
            case .serviceUnavailable:
                completion([.unsupported(forReason: .serviceUnavailable)])
            }
        }
    }

    func handle(intent: INUpdateMediaAffinityIntent,
                completion: @escaping (INUpdateMediaAffinityIntentResponse) -> Void) {
        Task { @MainActor in
            guard intent.affinityType != .unknown, await Self.prepareEnvironment(),
                  case .resolved(let resolution) = await Self.resolve(intent.mediaSearch,
                                                                     resolved: intent.mediaItems)
            else {
                completion(INUpdateMediaAffinityIntentResponse(code: .failure, userActivity: nil))
                return
            }
            await Self.setLiked(intent.affinityType == .like, tracks: resolution.tracks)
            completion(INUpdateMediaAffinityIntentResponse(code: .success, userActivity: nil))
        }
    }

    /// "I like this" said to a speaker almost always means the song that is
    /// playing, so a resolution covering a whole album or artist is narrowed to
    /// the current track when it is part of it.
    @MainActor
    private static func setLiked(_ liked: Bool, tracks: [Track]) async {
        let env = SharedEnvironment.shared
        let target: Track?
        if let current = env.playback.currentTrack, tracks.contains(where: { $0.id == current.id }) {
            target = current
        } else {
            target = tracks.first
        }
        guard let target else { return }
        await env.setLiked(liked, track: target)
    }

    // MARK: Shared

    /// Resolve a request, preferring an identifier Siri already resolved.
    ///
    /// `handle` is handed the media item that resolution produced rather than the
    /// original words, and the system replays donated intents long afterwards, so
    /// both arrive carrying an identifier. Rebuilding from that — via a cache of
    /// the last few resolutions, else from the catalog — keeps the queue that
    /// plays identical to the one Siri just described out loud.
    @MainActor
    private static func resolve(_ search: INMediaSearch?,
                                resolved items: [INMediaItem]? = nil) async -> MediaIntentOutcome {
        guard await prepareEnvironment() else { return .serviceUnavailable }
        let env = SharedEnvironment.shared

        if let identifier = items?.first?.identifier ?? search?.mediaIdentifier,
           let subject = MediaIntentSubject(rawValue: identifier),
           let cached = MediaIntentCache.lookup(subject) {
            return .resolved(cached)
        }

        let resolver = MediaIntentResolver(env: env)
        if let identifier = items?.first?.identifier,
           let subject = MediaIntentSubject(rawValue: identifier) {
            let rebuilt = await resolver.resolve(subject: subject)
            if case .resolved = rebuilt { return rebuilt }
        }
        return await resolver.resolve(search)
    }

    /// What Siri says back, and what it shows: the title and artist it repeats to
    /// the user come from this item, and its identifier is what `handle` receives.
    @MainActor
    private static func mediaItem(for resolution: MediaIntentResolution) async -> INMediaItem {
        INMediaItem(identifier: resolution.subject.rawValue,
                    title: resolution.title,
                    type: resolution.type,
                    artwork: await artwork(for: resolution),
                    artist: resolution.artist)
    }

    @MainActor
    private static func artwork(for resolution: MediaIntentResolution) async -> INImage? {
        guard let key = resolution.artworkKey, !key.isEmpty,
              let backend = SharedEnvironment.shared.active?.backend,
              let url = backend.artworkURL(for: ArtworkRef(key: key), size: 320)
        else { return nil }
        // Reuses the cover the phone has almost certainly already fetched; a cache
        // miss is one small image, well inside the time Siri allows.
        var image = ArtworkImageLoader.shared.cached(url)
        if image == nil { image = await ArtworkImageLoader.shared.image(for: url) }
        guard let data = image?.jpegData(compressionQuality: 0.8) else { return nil }
        return INImage(imageData: data)
    }

    /// Tell Siri what ended up playing so it can describe it, rather than falling
    /// back on a bare "OK".
    @MainActor
    private static func response(_ code: INPlayMediaIntentResponseCode,
                                 env: AppEnvironment) -> INPlayMediaIntentResponse {
        let response = INPlayMediaIntentResponse(code: code, userActivity: nil)
        if let track = env.playback.currentTrack {
            var info: [String: Any] = [
                MPMediaItemPropertyTitle: track.title,
                MPMediaItemPropertyArtist: track.artistName,
            ]
            if let album = track.albumTitle { info[MPMediaItemPropertyAlbumTitle] = album }
            if track.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = track.duration }
            response.nowPlayingInfo = info
        }
        return response
    }

    /// Bring the process up far enough to answer, and report whether it made it.
    ///
    /// Siri launches Mozz straight into the background with no window scene, so
    /// the restore that `MozzRootScene` normally starts may never have run: there
    /// would be no signed-in server and nothing to play. `SharedEnvironment.start`
    /// is idempotent, so this either performs that work or joins it.
    ///
    /// The wait is bounded because a server that can't be reached — the phone away
    /// from home, on cellular — would otherwise burn Siri's whole ten seconds and
    /// earn a generic failure. Only the wait gives up; the restore keeps running,
    /// so the next request moments later is likely to succeed.
    @MainActor
    private static func prepareEnvironment() async -> Bool {
        if didRestore { return true }
        let completed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = SingleResume()
            Task {
                await SharedEnvironment.start()
                once.fire { continuation.resume(returning: true) }
            }
            Task {
                try? await Task.sleep(for: .seconds(6))
                once.fire { continuation.resume(returning: false) }
            }
        }
        if completed { didRestore = true }
        return completed
    }

    @MainActor private static var didRestore = false
}

/// Resumes a continuation exactly once, whichever racer gets there first.
///
/// A plain task group can't express this: it waits for *every* child before
/// returning, so a slow restore would hold the timeout hostage — the one thing
/// the timeout exists to prevent.
private final class SingleResume: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire(_ body: () -> Void) {
        lock.lock()
        let isFirst = !fired
        fired = true
        lock.unlock()
        if isFirst { body() }
    }
}

/// The last few resolutions, so `handle` replays exactly what `resolve` promised.
///
/// Siri calls resolution and handling as separate round trips and passes only the
/// resolved media item between them. Without this, handling would search the
/// catalog a second time and could reasonably land on a different album by the
/// same name from the one Siri just read out.
@MainActor
private enum MediaIntentCache {
    private static var entries: [(subject: MediaIntentSubject, resolution: MediaIntentResolution)] = []

    static func store(_ resolution: MediaIntentResolution) {
        entries.removeAll { $0.subject == resolution.subject }
        entries.append((resolution.subject, resolution))
        // A handful is plenty: only the request being handled right now matters,
        // and the entries hold whole track lists.
        if entries.count > 4 { entries.removeFirst(entries.count - 4) }
    }

    static func lookup(_ subject: MediaIntentSubject) -> MediaIntentResolution? {
        entries.last { $0.subject == subject }?.resolution
    }
}

extension MediaIntentHandler: INPlayMediaIntentHandling, INAddMediaIntentHandling,
                              INUpdateMediaAffinityIntentHandling {}
#endif
