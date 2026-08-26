namespace Mozz.Desktop.Core.Downloads;

/// <summary>
/// The core's download record lifecycle, as the desktop calls it. Every mutating
/// method addresses a track by its (server, remote) id — the same way every other
/// command does — and returns the durable record as it now stands.
///
/// The split this interface sits on: the core owns the <em>record</em> (what is
/// queued, downloading, downloaded or failed, and where the file went); the shell
/// owns the <em>bytes</em> (fetching the audio, writing it to disk) and reports
/// back through <see cref="ReportProgressAsync"/> / <see cref="CompleteAsync"/> /
/// <see cref="FailAsync"/>. <see cref="DownloadService"/> is the shell side that
/// drives that conversation.
/// </summary>
public interface IDownloadCommands
{
    /// <summary>Record the intent to download a track. Idempotent: enqueuing an
    /// already-tracked download returns its current record rather than resetting
    /// it.</summary>
    Task<DownloadItem> EnqueueAsync(string serverId, string remoteId, CancellationToken token = default);

    /// <summary>Report transfer progress. The first report moves a queued
    /// download to downloading.</summary>
    Task<DownloadItem> ReportProgressAsync(
        string serverId, string remoteId, long receivedBytes, long? totalBytes,
        CancellationToken token = default);

    /// <summary>Record that the file was written. <paramref name="localPath"/> is
    /// relative to the shell's downloads root.</summary>
    Task<DownloadItem> CompleteAsync(
        string serverId, string remoteId, string localPath, long sizeBytes,
        CancellationToken token = default);

    /// <summary>Record that the transfer failed, keeping the reason.</summary>
    Task<DownloadItem> FailAsync(string serverId, string remoteId, string message, CancellationToken token = default);

    /// <summary>Cancel a queued or in-flight download. The core records this as a
    /// failure whose message is exactly "Cancelled".</summary>
    Task<DownloadItem> CancelAsync(string serverId, string remoteId, CancellationToken token = default);

    /// <summary>Drop the core's record and return the file's former relative path
    /// so the shell can delete the bytes it owns. Null when there was nothing to
    /// remove.</summary>
    Task<string?> DeleteAsync(string serverId, string remoteId, CancellationToken token = default);

    /// <summary>The current record for one track, or null when the core has none
    /// ("not downloaded").</summary>
    Task<DownloadItem?> StatusAsync(string serverId, string remoteId, CancellationToken token = default);

    /// <summary>Every download the core knows about, optionally narrowed to
    /// certain states. An empty/absent filter means every state.</summary>
    Task<IReadOnlyList<DownloadItem>> ListAsync(
        IReadOnlyList<DownloadPhase>? states = null, CancellationToken token = default);

    /// <summary>How much space completed downloads occupy.</summary>
    Task<StorageUsage> StorageUsageAsync(CancellationToken token = default);
}

/// <summary>
/// Resolves a track to the URL and headers its bytes can be fetched from. The
/// desktop's implementation is <see cref="MozzServer"/>, which answers with the
/// same <c>streamURL</c> result the player uses — so a download authenticates
/// exactly as a stream does.
/// </summary>
public interface IDownloadSourceResolver
{
    Task<DownloadSource?> ResolveAsync(string serverId, string remoteId, CancellationToken token = default);
}

/// <summary>
/// Opens an authenticated byte stream for a resolved source. The production
/// implementation returns a <see cref="Audio.Streaming.HttpByteStreamSource"/> —
/// the desktop's one existing authenticated fetch — rather than a second HTTP
/// path invented for downloads.
/// </summary>
public interface IByteStreamFactory
{
    Audio.Streaming.ByteStreamSource Open(string url, IReadOnlyDictionary<string, string> headers);
}

/// <summary>
/// The production <see cref="IByteStreamFactory"/>: it hands back the same
/// ranged, credential-carrying HTTP source the audio engine reads through.
/// </summary>
public sealed class HttpByteStreamFactory : IByteStreamFactory
{
    public Audio.Streaming.ByteStreamSource Open(string url, IReadOnlyDictionary<string, string> headers)
        => new Audio.Streaming.HttpByteStreamSource(url, headers);
}
