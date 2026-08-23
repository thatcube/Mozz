#if os(iOS)
import Foundation
import Intents
import MozzCore
import MozzDatabase

/// Teaches the system what Mozz plays, so Siri gets better at it over time.
///
/// Handling `INPlayMediaIntent` is enough for "play jazz **on Mozz**". Dropping
/// the app's name is a separate thing: App Selection decides that on its own, and
/// it decides using donations, a picture of the user's library, and the names it
/// has been taught to recognise. None of that arrives by itself, so this is what
/// turns "play music on Mozz" into plain "play music".
@MainActor
enum SiriMediaSuggestions {
    /// Record that this is what someone chose to listen to.
    ///
    /// Apple asks for the container rather than the song where there is one — the
    /// playlist or album, not each track off it — because a queue of forty songs
    /// donated one at a time says far less about what the user actually wanted
    /// than one donation naming the playlist.
    static func donate(_ resolution: MediaIntentResolution) {
        let item = INMediaItem(identifier: resolution.subject.rawValue,
                               title: resolution.title,
                               type: resolution.type,
                               artwork: nil,
                               artist: resolution.artist)
        let isContainer: Bool
        switch resolution.type {
        case .song: isContainer = false
        default: isContainer = true
        }
        let intent = INPlayMediaIntent(mediaItems: isContainer ? nil : [item],
                                       mediaContainer: isContainer ? item : nil,
                                       playShuffled: resolution.prefersShuffle,
                                       playbackRepeatMode: .unknown,
                                       resumePlayback: false)
        intent.suggestedInvocationPhrase = "Play \(resolution.title) on Mozz"

        let interaction = INInteraction(intent: intent, response: nil)
        // Stable per subject, so replaying the same playlist repeatedly sharpens
        // one suggestion instead of littering Siri with near-duplicates.
        interaction.identifier = resolution.subject.rawValue
        interaction.donate(completion: nil)
    }

    /// Donate a play the user started in the app itself.
    ///
    /// This is the larger half of the signal by far: someone who never once says
    /// "on Mozz" still trains App Selection every time they tap a playlist, and
    /// that is precisely the person who later expects a bare "play music" on a
    /// HomePod to reach their own library.
    static func donatePlayedInApp(title: String, artist: String?,
                                  subject: MediaIntentSubject, type: INMediaItemType,
                                  shuffled: Bool = false) {
        donate(MediaIntentResolution(subject: subject, title: title, artist: artist,
                                     type: type, tracks: [], prefersShuffle: shuffled))
    }

    /// Describe the user to App Selection: how much music they have, and whether
    /// they can actually play it. A signed-in Mozz user has unrestricted access to
    /// their own server, which is what `subscribed` means here — the system uses
    /// it to avoid routing requests to an app that would only refuse them.
    static func updateUserContext(libraryItemCount: Int?, isSignedIn: Bool) {
        let context = INMediaUserContext()
        context.numberOfLibraryItems = libraryItemCount
        context.subscriptionStatus = isSignedIn ? .subscribed : .notSubscribed
        context.becomeCurrent()
    }

    /// Teach Siri the names only this user's library contains.
    ///
    /// Speech recognition has no chance with a playlist called "Weeknight Kitchen"
    /// or a band whose name isn't a word until it is told they exist. Playlists
    /// come first — they are the names people invent themselves, and so the ones
    /// Siri is most likely to mangle.
    static func registerVocabulary(playlists: [String], artists: [String]) {
        let playlists = Self.distinct(playlists, limit: 100)
        let artists = Self.distinct(artists, limit: 200)
        // Off the main thread: this hands potentially hundreds of strings to
        // another process, and nothing is waiting on the result.
        Task.detached(priority: .utility) {
            if !playlists.isEmpty {
                INVocabulary.shared().setVocabularyStrings(NSOrderedSet(array: playlists),
                                                           of: .mediaPlaylistTitle)
            }
            if !artists.isEmpty {
                INVocabulary.shared().setVocabularyStrings(NSOrderedSet(array: artists),
                                                           of: .mediaMusicArtistName)
            }
        }
    }

    private static func distinct(_ values: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
            if result.count == limit { break }
        }
        return result
    }
}
#endif
