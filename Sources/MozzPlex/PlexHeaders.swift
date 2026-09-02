import Foundation
import MozzCore

/// The `X-Plex-*` identity headers Plex expects on every request. The token is
/// sent as a header for JSON API calls; for *media* URLs it must instead be a
/// query parameter (AVPlayer / the download session don't share these headers),
/// which the backend handles when building stream/artwork URLs.
enum PlexHeaders {
    static func common(clientInfo: ClientInfo, clientIdentifier: String, token: String?) -> [String: String] {
        var headers = [
            "X-Plex-Product": clientInfo.product,
            "X-Plex-Version": clientInfo.version,
            "X-Plex-Client-Identifier": clientIdentifier,
            "X-Plex-Device": clientInfo.deviceName,
            "X-Plex-Device-Name": clientInfo.deviceName,
            "X-Plex-Platform": clientInfo.platform,
            "X-Plex-Platform-Version": clientInfo.platformVersion,
            "Accept": "application/json",
        ]
        if let token { headers["X-Plex-Token"] = token }
        return headers
    }

    /// The same identity, as query items.
    ///
    /// For a media URL fetched outside the API client — a transcode read by the
    /// analyzer, say — there are no default headers, and Plex's universal
    /// transcoder builds its decision from this identity. Without it the
    /// endpoint has no client to decide *for* and answers 400.
    static func commonQuery(clientInfo: ClientInfo, clientIdentifier: String, token: String?) -> [URLQueryItem] {
        common(clientInfo: clientInfo, clientIdentifier: clientIdentifier, token: token)
            .filter { $0.key.hasPrefix("X-Plex-") }
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
    }
}
