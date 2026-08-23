import Foundation

/// A stable, re-resolvable name for something Mozz can play in answer to Siri.
///
/// It round-trips through `INMediaItem.identifier`, which matters twice over.
/// Siri hands `handle(intent:)` the media item that *resolution* produced rather
/// than the words that were spoken, and the system replays donated intents —
/// from Shortcuts, or an audio suggestion offered days later — long after the
/// search that created them. Both paths have to rebuild the same queue from this
/// string alone, so it names the user's intent ("this artist", "everything,
/// shuffled") rather than freezing a track list that the next sync would
/// invalidate.
enum MediaIntentSubject: Hashable {
    case song(String)
    case album(String)
    case artist(String)
    case playlist(String)
    case genre(String)
    /// A precomputed recommendation set — "Mozz Weekly" or a daily Home mix.
    case mix(String)
    case liked
    case recentlyAdded
    /// The whole library, shuffled: the answer to a bare "play music".
    case library
}

extension MediaIntentSubject: RawRepresentable {
    var rawValue: String {
        switch self {
        case .song(let id): return "mozz:song:\(id)"
        case .album(let id): return "mozz:album:\(id)"
        case .artist(let id): return "mozz:artist:\(id)"
        case .playlist(let id): return "mozz:playlist:\(id)"
        case .genre(let name): return "mozz:genre:\(name)"
        case .mix(let id): return "mozz:mix:\(id)"
        case .liked: return "mozz:liked"
        case .recentlyAdded: return "mozz:recent"
        case .library: return "mozz:library"
        }
    }

    init?(rawValue: String) {
        // Split at most twice: server remote ids and genre names may themselves
        // contain colons, and everything past the second one is payload.
        let parts = rawValue.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "mozz" else { return nil }
        let payload = parts.count > 2 ? String(parts[2]) : ""
        switch parts[1] {
        case "song" where !payload.isEmpty: self = .song(payload)
        case "album" where !payload.isEmpty: self = .album(payload)
        case "artist" where !payload.isEmpty: self = .artist(payload)
        case "playlist" where !payload.isEmpty: self = .playlist(payload)
        case "genre" where !payload.isEmpty: self = .genre(payload)
        case "mix" where !payload.isEmpty: self = .mix(payload)
        case "liked": self = .liked
        case "recent": self = .recentlyAdded
        case "library": self = .library
        default: return nil
        }
    }
}
