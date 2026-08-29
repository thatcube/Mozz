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
        let explicitMachine = serverMachineIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .plex,
           let machine = explicitMachine?.isEmpty == false
                ? explicitMachine
                : plexMachineIdentifier(from: baseURL) {
            return "\(kind.rawValue)-\(machine)"
        }
        if kind == .subsonic, let username, !username.isEmpty {
            return "\(kind.rawValue)-\(username.lowercased())-\(baseURL.absoluteString)"
        }
        return "\(kind.rawValue)-\(baseURL.absoluteString)"
    }

    private static func plexMachineIdentifier(from baseURL: URL) -> String? {
        guard let host = baseURL.host?.lowercased() else { return nil }
        let suffix = ".plex.direct"
        guard host.hasSuffix(suffix) else { return nil }
        let withoutSuffix = host.dropLast(suffix.count)
        guard let separator = withoutSuffix.lastIndex(of: ".") else {
            return nil
        }
        let machine = withoutSuffix[withoutSuffix.index(after: separator)...]
        return machine.isEmpty ? nil : String(machine)
    }
}
