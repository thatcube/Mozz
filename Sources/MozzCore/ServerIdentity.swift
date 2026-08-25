import Foundation

/// Cross-platform server identity rules. Keep this in the shared core so iOS,
/// desktop and Android scope catalog rows and credentials the same way.
public enum ServerIdentity {
    public static func id(
        kind: BackendKind,
        baseURL: URL,
        username: String? = nil,
        serverMachineIdentifier: String? = nil
    ) -> String {
        if kind == .plex, let machine = serverMachineIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !machine.isEmpty {
            return "\(kind.rawValue)-\(machine)"
        }
        if kind == .subsonic, let username, !username.isEmpty {
            return "\(kind.rawValue)-\(username.lowercased())-\(baseURL.absoluteString)"
        }
        return "\(kind.rawValue)-\(baseURL.absoluteString)"
    }
}
