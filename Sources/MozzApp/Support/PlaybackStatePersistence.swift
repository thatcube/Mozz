import Foundation
import MozzPlayback

/// Persists the playback session (current queue + position) to disk so it can be
/// restored on a later cold launch — enabling "resume where you left off" in the
/// app, and letting the Home-Screen widget's play button resume after the app
/// has been terminated.
enum PlaybackStatePersistence {
    private static var fileURL: URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        return support.appendingPathComponent("playback_state.json")
    }

    static func save(_ state: PlaybackPersistentState) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> PlaybackPersistentState? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PlaybackPersistentState.self, from: data)
    }

    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
