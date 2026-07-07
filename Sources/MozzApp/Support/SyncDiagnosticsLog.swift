import Foundation
import os

/// Appends sync-timing diagnostics to a file in the app's Documents directory so
/// they can be pulled off a physical device without any user interaction:
///
///   xcrun devicectl device copy from --device <UDID> \
///     --domain-type appDataContainer --domain-identifier com.thatcube.Mozz \
///     --source Documents/sync-diagnostics.log --destination /tmp/
///
/// (Live `os_log` streaming from a physical device is blocked by Apple on modern
/// iOS, so a pulled file is the reliable path for headless debugging.)
public struct SyncDiagnosticsLog: Sendable {
    private let fileURL: URL

    public init() {
        let docs = (try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.fileURL = docs.appendingPathComponent("sync-diagnostics.log")
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Append one line, timestamped. Best-effort; never throws into a sync.
    public func append(_ line: String) {
        let entry = "[\(Self.stamp.string(from: Date()))] \(line)\n"
        guard let data = entry.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// A `@Sendable` sink for the sync engine's `diag` parameter.
    public var sink: @Sendable (String) -> Void {
        { line in self.append(line) }
    }
}
