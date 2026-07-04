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
}
