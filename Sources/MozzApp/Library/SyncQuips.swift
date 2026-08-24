import Foundation
import MozzSync

/// Rotating status lines for a running sync.
///
/// A long first sync on a big library can run for many minutes, and a single
/// fixed label makes that feel stuck. These rotate so there is always something
/// new, and they say the quiet part out loud: it's slow, it's the server's pace,
/// and nothing is broken.
///
/// The tone is teasing-but-reassuring — never blaming the user, and never
/// claiming a speed we can't deliver.
enum SyncQuips {

    /// Lines shown while the catalog is being pulled.
    static let syncing: [String] = [
        "Politely asking your server for the next page…",
        "Your server is thinking. We're waiting. It's fine.",
        "This is the boring part. It only happens once.",
        "Counting your songs so you never have to.",
        "We'd go faster, but your server sets the pace.",
        "Still going. Nothing is on fire.",
        "Somewhere in here is an album you forgot you owned.",
        "Reading every tag your server will part with.",
        "Filing everything alphabetically, at great personal cost.",
        "Long libraries take long. We don't make the rules.",
        "Negotiating with your server, one page at a time.",
        "This is faster than it looks. Slightly.",
    ]

    /// Shown once the pages are in and the last of the work is local.
    static let finishing: [String] = [
        "Tidying up the last few shelves…",
        "Almost there — putting everything in its place.",
        "Nearly done. Don't go anywhere.",
    ]

    /// The line for a given moment, rotating on `index`.
    ///
    /// `fraction` switches to the closing set near the end so the copy stops
    /// promising more waiting when there's barely any left.
    static func line(index: Int, fraction: Double?) -> String {
        let pool = (fraction ?? 0) >= 0.95 ? finishing : syncing
        guard !pool.isEmpty else { return "" }
        return pool[abs(index) % pool.count]
    }
}
