import Foundation

// MARK: - Host identity
//
// Every backend wants to know who is calling: Plex and Jellyfin both put the
// product, version and platform in an auth header and surface them in their
// "devices" list, so a listener can see and revoke "Mozz on Windows". Getting
// this wrong is not fatal, but it makes an unrecognisable entry in someone's
// account settings, which is a bad thing to do to a self-hoster.

/// The version reported to servers. Deliberately the *client* version rather
/// than a per-module one — it is what a user sees in their server's device list.
public let mozzClientVersion = "1.0"

/// Human-readable OS name, used both as the platform and the device name.
public let mozzHostPlatform: String = {
    #if os(Windows)
    return "Windows"
    #elseif os(macOS)
    return "macOS"
    #elseif os(Linux)
    return "Linux"
    #elseif os(Android)
    return "Android"
    #elseif os(iOS)
    return "iOS"
    #else
    return "Unknown"
    #endif
}()

/// OS version string, best effort. `ProcessInfo` reports this on every platform
/// Swift supports, including Windows and Linux.
public let mozzHostPlatformVersion: String = {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
}()
