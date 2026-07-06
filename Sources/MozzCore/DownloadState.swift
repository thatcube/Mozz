import Foundation

/// The lifecycle state of an offline download for a single track.
///
/// The *absence* of a download record means "not downloaded". Once a download
/// is requested a record exists and moves through these states. Keeping this in
/// the domain layer lets the database schema, the download engine and the UI
/// all speak the same vocabulary.
public enum DownloadState: String, Codable, Sendable, Hashable, CaseIterable {
    /// Requested, waiting for a transfer slot.
    case queued
    /// Bytes are actively transferring.
    case downloading
    /// Fully downloaded and available offline.
    case downloaded
    /// The transfer failed; `errorMessage` on the record explains why.
    case failed

    /// Whether the track is fully available for offline playback.
    public var isAvailableOffline: Bool { self == .downloaded }

    /// Whether the download is still working toward completion.
    public var isInFlight: Bool { self == .queued || self == .downloading }
}

/// A snapshot of how much space downloads are using, for the storage UI.
public struct StorageUsage: Sendable, Hashable {
    /// Number of fully-downloaded tracks.
    public var downloadedTrackCount: Int
    /// Total bytes on disk for completed downloads.
    public var totalBytes: Int64

    public init(downloadedTrackCount: Int = 0, totalBytes: Int64 = 0) {
        self.downloadedTrackCount = downloadedTrackCount
        self.totalBytes = totalBytes
    }
}
