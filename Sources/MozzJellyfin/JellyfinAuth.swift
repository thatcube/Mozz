import Foundation
import MozzCore

/// Builds the `Authorization: MediaBrowser ...` header Jellyfin expects on
/// every request. Before login the token is omitted (Quick Connect initiation
/// only needs to identify the device); after login it is included so the
/// server ties the session to the access token.
enum JellyfinAuth {
    static func authorizationHeader(clientInfo: ClientInfo, deviceID: String, token: String?) -> String {
        var fields = [
            "Client=\"\(clientInfo.product)\"",
            "Device=\"\(clientInfo.deviceName)\"",
            "DeviceId=\"\(deviceID)\"",
            "Version=\"\(clientInfo.version)\"",
        ]
        if let token, !token.isEmpty {
            fields.append("Token=\"\(token)\"")
        }
        return "MediaBrowser " + fields.joined(separator: ", ")
    }
}
