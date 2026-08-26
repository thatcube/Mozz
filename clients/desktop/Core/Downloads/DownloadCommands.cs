using Mozz.V1;

namespace Mozz.Desktop.Core.Downloads;

/// <summary>
/// The nine download commands, reachable at last from the desktop.
///
/// Every method here builds a generated <see cref="Request"/>, sends it down the
/// typed <see cref="MozzCore.Invoke"/> path, and projects the generated response
/// back into a plain <see cref="DownloadItem"/>. The typed path is the whole
/// point: the request and response are generated from <c>schema/</c>, so a field
/// cannot quietly change shape underneath this code and a command this build does
/// not know about cannot be constructed. The untyped <see cref="MozzCore.Call"/>
/// path most of <see cref="MozzServer"/> uses would work too, but it hand-writes
/// a request dictionary and trusts <c>System.Text.Json</c> to accept the reply —
/// and a single numeric-width mismatch there rejects the entire response, which
/// is exactly the class of bug the schema exists to make impossible.
/// </summary>
public sealed class DownloadCommands(ICoreInvoker invoker) : IDownloadCommands
{
    private readonly ICoreInvoker _invoker = invoker;

    // The core echoes the request id back; a monotonic counter makes a response
    // traceable to its call without any two in-flight requests colliding.
    private int _nextId;

    private ulong NextId() => (ulong)Interlocked.Increment(ref _nextId);

    public async Task<DownloadItem> EnqueueAsync(
        string serverId, string remoteId, CancellationToken token = default)
    {
        var request = new Request
        {
            Id = NextId(),
            EnqueueDownload = new EnqueueDownloadRequest { ServerId = serverId, RemoteId = remoteId },
        };
        var response = await _invoker.InvokeAsync(request, token).ConfigureAwait(false);
        return Project(response.EnqueueDownload.Download);
    }

    public async Task<DownloadItem> ReportProgressAsync(
        string serverId, string remoteId, long receivedBytes, long? totalBytes,
        CancellationToken token = default)
    {
        var arguments = new ReportDownloadProgressRequest
        {
            ServerId = serverId,
            RemoteId = remoteId,
            ReceivedBytes = receivedBytes,
        };
        // Left unset rather than sent as zero when the transfer does not yet know
        // the size, so the core's optional total stays genuinely absent.
        if (totalBytes is { } total) arguments.TotalBytes = total;

        var request = new Request { Id = NextId(), ReportDownloadProgress = arguments };
        var response = await _invoker.InvokeAsync(request, token).ConfigureAwait(false);
        return Project(response.ReportDownloadProgress.Download);
    }

    public async Task<DownloadItem> CompleteAsync(
        string serverId, string remoteId, string localPath, long sizeBytes,
        CancellationToken token = default)
    {
        var request = new Request
        {
            Id = NextId(),
            CompleteDownload = new CompleteDownloadRequest
            {
                ServerId = serverId,
                RemoteId = remoteId,
                LocalPath = localPath,
                SizeBytes = sizeBytes,
            },
        };
        var response = await _invoker.InvokeAsync(request, token).ConfigureAwait(false);
        return Project(response.CompleteDownload.Download);
    }

    public async Task<DownloadItem> FailAsync(
        string serverId, string remoteId, string message, CancellationToken token = default)
    {
        var request = new Request
        {
            Id = NextId(),
            FailDownload = new FailDownloadRequest
            {
                ServerId = serverId,
                RemoteId = remoteId,
                Message = message,
            },
        };
        var response = await _invoker.InvokeAsync(request, token).ConfigureAwait(false);
        return Project(response.FailDownload.Download);
    }

    public async Task<DownloadItem> CancelAsync(
        string serverId, string remoteId, CancellationToken token = default)
    {
        var request = new Request
        {
            Id = NextId(),
            CancelDownload = new CancelDownloadRequest { ServerId = serverId, RemoteId = remoteId },
        };
        var response = await _invoker.InvokeAsync(request, token).ConfigureAwait(false);
        return Project(response.CancelDownload.Download);
    }

    public async Task<string?> DeleteAsync(
        string serverId, string remoteId, CancellationToken token = default)
    {
        var request = new Request
        {
            Id = NextId(),
            DeleteDownload = new DeleteDownloadRequest { ServerId = serverId, RemoteId = remoteId },
        };
        var response = await _invoker.InvokeAsync(request, token).ConfigureAwait(false);
        var payload = response.DeleteDownload;
        // Absent when there was no record, or it had no file yet — "removed
        // nothing", which is not a failure.
        return payload.HasRemovedLocalPath ? payload.RemovedLocalPath : null;
    }

    public async Task<DownloadItem?> StatusAsync(
        string serverId, string remoteId, CancellationToken token = default)
    {
        var request = new Request
        {
            Id = NextId(),
            DownloadStatus = new DownloadStatusRequest { ServerId = serverId, RemoteId = remoteId },
        };
        var response = await _invoker.InvokeAsync(request, token).ConfigureAwait(false);
        // An unset download means "not downloaded"; report null rather than
        // inventing an empty record.
        var download = response.DownloadStatus.Download;
        return download is null ? null : Project(download);
    }

    public async Task<IReadOnlyList<DownloadItem>> ListAsync(
        IReadOnlyList<DownloadPhase>? states = null, CancellationToken token = default)
    {
        var arguments = new DownloadsRequest();
        // An empty states list means "every state", so only forward filters the
        // caller actually asked for.
        if (states is { Count: > 0 })
        {
            foreach (var state in states)
            {
                arguments.States.Add(ToWireState(state));
            }
        }

        var request = new Request { Id = NextId(), Downloads = arguments };
        var response = await _invoker.InvokeAsync(request, token).ConfigureAwait(false);
        return response.Downloads.Downloads.Select(Project).ToList();
    }

    public async Task<StorageUsage> StorageUsageAsync(CancellationToken token = default)
    {
        var request = new Request { Id = NextId(), StorageUsage = new StorageUsageRequest() };
        var response = await _invoker.InvokeAsync(request, token).ConfigureAwait(false);
        var payload = response.StorageUsage;
        return new StorageUsage(payload.DownloadedTrackCount, payload.TotalBytes);
    }

    /// <summary>
    /// Turn a wire <see cref="Download"/> into the desktop's own record. The two
    /// optional counters are read only when present so an absent total does not
    /// collapse to zero, which would read as a stalled 0% download.
    /// </summary>
    private static DownloadItem Project(Download download) => new(
        TrackId: download.TrackId,
        ServerId: download.ServerId,
        RemoteId: download.RemoteId,
        State: FromWireState(download.State),
        ReceivedBytes: download.ReceivedBytes,
        TotalBytes: download.HasTotalBytes ? download.TotalBytes : null,
        LocalPath: download.HasLocalPath ? download.LocalPath : null,
        ErrorMessage: download.HasErrorMessage ? download.ErrorMessage : null,
        RequestedAt: download.RequestedAt,
        CompletedAt: download.HasCompletedAt ? download.CompletedAt : null);

    private static DownloadPhase FromWireState(DownloadState state) => state switch
    {
        DownloadState.Queued => DownloadPhase.Queued,
        DownloadState.Downloading => DownloadPhase.Downloading,
        DownloadState.Downloaded => DownloadPhase.Downloaded,
        DownloadState.Failed => DownloadPhase.Failed,
        _ => DownloadPhase.NotDownloaded,
    };

    private static DownloadState ToWireState(DownloadPhase phase) => phase switch
    {
        DownloadPhase.Queued => DownloadState.Queued,
        DownloadPhase.Downloading => DownloadState.Downloading,
        DownloadPhase.Downloaded => DownloadState.Downloaded,
        DownloadPhase.Failed => DownloadState.Failed,
        _ => DownloadState.Unspecified,
    };
}
