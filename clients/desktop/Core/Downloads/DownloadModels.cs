namespace Mozz.Desktop.Core.Downloads;

/// <summary>
/// The lifecycle state of one track's offline download, mirroring the core's
/// <c>DownloadState</c> enum (schema <c>mozz/v1/library.proto</c>).
///
/// The names are the desktop's own rather than the generated
/// <see cref="Mozz.V1.DownloadState"/> so the view models and tests never
/// depend on the protobuf types. <see cref="NotDownloaded"/> is the schema's
/// <c>UNSPECIFIED</c>: the absence of a record, which a status query answers
/// with rather than an error.
/// </summary>
public enum DownloadPhase
{
    NotDownloaded = 0,
    Queued = 1,
    Downloading = 2,
    Downloaded = 3,
    Failed = 4,
}

/// <summary>
/// The desktop's view of one durable download record. A faithful projection of
/// the wire <see cref="Mozz.V1.Download"/>: every numeric field keeps the proto's
/// width (bytes are <c>long</c>, timestamps are <c>double</c>) so nothing is lost
/// crossing into managed code, and the two optional counters stay nullable rather
/// than defaulting to a value the core never sent.
/// </summary>
public sealed record DownloadItem(
    long TrackId,
    string ServerId,
    string RemoteId,
    DownloadPhase State,
    long ReceivedBytes,
    long? TotalBytes,
    string? LocalPath,
    string? ErrorMessage,
    double RequestedAt,
    double? CompletedAt)
{
    /// <summary>
    /// Completed fraction in 0..1, or null when the total is not yet known — the
    /// record stores counters, not a fraction, so a client that wants one derives
    /// it and a client that has no total (a transfer that never announced its
    /// size) simply has none rather than a fabricated zero.
    /// </summary>
    public double? Fraction =>
        TotalBytes is { } total and > 0
            ? Math.Clamp((double)ReceivedBytes / total, 0, 1)
            : null;

    public bool IsTerminal => State is DownloadPhase.Downloaded or DownloadPhase.Failed;

    /// <summary>
    /// A cancellation is recorded by the core as a <see cref="DownloadPhase.Failed"/>
    /// record whose message is exactly "Cancelled" — the same shape a genuine
    /// failure takes, which is deliberate (see the schema's CancelDownload note).
    /// This distinguishes the two for display without inventing a fifth state.
    /// </summary>
    public bool WasCancelled =>
        State == DownloadPhase.Failed &&
        string.Equals(ErrorMessage, "Cancelled", StringComparison.Ordinal);
}

/// <summary>
/// How much space completed downloads occupy, for a storage screen. The two
/// numbers travel together because a caller presents them together.
/// </summary>
public sealed record StorageUsage(int DownloadedTrackCount, long TotalBytes);

/// <summary>
/// Where a track's bytes can be fetched from: the resolved URL plus whatever
/// headers authenticate the request. Produced by the same <c>streamURL</c>
/// command the player already uses, so a download carries the same credentials a
/// stream does rather than a second, parallel auth path.
/// </summary>
public sealed record DownloadSource(string Url, IReadOnlyDictionary<string, string> Headers);
