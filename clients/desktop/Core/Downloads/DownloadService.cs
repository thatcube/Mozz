namespace Mozz.Desktop.Core.Downloads;

/// <summary>
/// The shell half of a download: it moves the bytes and keeps the core's record
/// honest about where they got to.
///
/// The core owns the <em>record</em> — queued, downloading, downloaded, failed,
/// and the path — and this class owns the <em>transfer</em>. One download is a
/// short conversation with the core around a byte copy:
/// <c>enqueue</c> → resolve the source → fetch the bytes to a temp file, calling
/// <c>report_download_progress</c> as they arrive → move the file into place and
/// <c>complete_download</c>; or, if the copy throws, <c>fail_download</c> with the
/// reason; or, if it is cancelled, <c>cancel_download</c> (which the core records
/// as a failure whose message is exactly "Cancelled").
///
/// Progress is deliberately pull-shaped on the read side: there is no push
/// channel from the core, so a UI watches by polling <see cref="ListAsync"/> /
/// <see cref="StatusAsync"/>. This class only <em>writes</em> progress.
/// </summary>
public sealed class DownloadService
{
    private const int ReadBufferSize = 128 * 1024;

    // Report progress at most once per quarter-megabyte of new bytes. Frequent
    // enough for a smooth bar, rare enough that a fast download does not spend
    // itself round-tripping the core once per read.
    private const long ProgressReportThreshold = 256 * 1024;

    private readonly IDownloadCommands _commands;
    private readonly IDownloadSourceResolver _resolver;
    private readonly IByteStreamFactory _byteStreams;
    private readonly string _root;

    public DownloadService(
        IDownloadCommands commands,
        IDownloadSourceResolver resolver,
        IByteStreamFactory byteStreams,
        string? rootDirectory = null)
    {
        _commands = commands;
        _resolver = resolver;
        _byteStreams = byteStreams;
        _root = rootDirectory ?? AppPaths.DownloadsDirectory;
    }

    /// <summary>The absolute downloads root this service writes under.</summary>
    public string RootDirectory => _root;

    /// <summary>
    /// Download one track end to end, returning the record as it finally stands —
    /// downloaded on success, failed (with a reason, or "Cancelled") otherwise.
    ///
    /// The transfer runs off the caller's thread: the byte source reads block, and
    /// the UI thread must not. A non-cancellation failure is turned into a failed
    /// record rather than thrown, so a batch (a whole album) keeps going and the
    /// one bad track simply shows its error.
    /// </summary>
    public Task<DownloadItem> DownloadAsync(string serverId, string remoteId, CancellationToken token = default)
        => Task.Run(() => RunDownloadAsync(serverId, remoteId, token), token);

    private async Task<DownloadItem> RunDownloadAsync(string serverId, string remoteId, CancellationToken token)
    {
        // Enqueue first: it is idempotent, and if the track is already downloaded
        // the core hands back that record and there is nothing left to fetch.
        var record = await _commands.EnqueueAsync(serverId, remoteId, token).ConfigureAwait(false);
        if (record.State == DownloadPhase.Downloaded)
        {
            return record;
        }

        var source = await _resolver.ResolveAsync(serverId, remoteId, token).ConfigureAwait(false);
        if (source is null)
        {
            return await _commands
                .FailAsync(serverId, remoteId, "Could not resolve a download source for this track.", token)
                .ConfigureAwait(false);
        }

        var extension = DownloadLayout.ExtensionFromUrl(source.Url);
        var relativePath = DownloadLayout.RelativePath(serverId, remoteId, extension);
        var destination = Path.Combine(_root, relativePath);
        var tempPath = destination + ".part";

        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);

            var received = await FetchToFileAsync(source, serverId, remoteId, tempPath, token)
                .ConfigureAwait(false);

            MoveIntoPlace(tempPath, destination);

            return await _commands
                .CompleteAsync(serverId, remoteId, relativePath, received, token)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
            TryDelete(tempPath);
            // Record the cancellation with the core even though the caller's token
            // tripped — a token going quiet must not leave a QUEUED/DOWNLOADING
            // ghost behind. Use None so this bookkeeping call is not itself
            // cancelled.
            return await _commands
                .CancelAsync(serverId, remoteId, CancellationToken.None)
                .ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            TryDelete(tempPath);
            return await _commands
                .FailAsync(serverId, remoteId, ex.Message, CancellationToken.None)
                .ConfigureAwait(false);
        }
    }

    /// <summary>
    /// Copy the source's bytes into <paramref name="tempPath"/>, reporting
    /// progress to the core as they arrive, and return the total written.
    /// </summary>
    private async Task<long> FetchToFileAsync(
        DownloadSource source, string serverId, string remoteId, string tempPath, CancellationToken token)
    {
        using var bytes = _byteStreams.Open(source.Url, source.Headers);
        var total = ProbeTotalLength(bytes);

        // A first report moves the record QUEUED -> DOWNLOADING before any bytes
        // land, so the UI reflects an in-flight download immediately.
        await _commands.ReportProgressAsync(serverId, remoteId, 0, total, token).ConfigureAwait(false);

        await using var file = new FileStream(
            tempPath, FileMode.Create, FileAccess.Write, FileShare.None,
            bufferSize: ReadBufferSize, useAsync: true);

        var buffer = new byte[ReadBufferSize];
        long received = 0;
        long lastReported = 0;

        while (true)
        {
            token.ThrowIfCancellationRequested();

            var read = bytes.Read(buffer);
            if (read == 0) break; // End of stream.
            if (read < 0) throw new IOException("The download source reported a read error.");

            await file.WriteAsync(buffer.AsMemory(0, read), token).ConfigureAwait(false);
            received += read;

            if (received - lastReported >= ProgressReportThreshold)
            {
                lastReported = received;
                await _commands
                    .ReportProgressAsync(serverId, remoteId, received, total ?? (received > 0 ? received : null), token)
                    .ConfigureAwait(false);
            }
        }

        await file.FlushAsync(token).ConfigureAwait(false);
        return received;
    }

    /// <summary>
    /// Learn the source's length by seeking to its end and back, if it can. A
    /// seekable HTTP source answers this with a one-byte ranged probe; a source
    /// that cannot returns null and the download simply proceeds without a total,
    /// which the record already tolerates.
    /// </summary>
    private static long? ProbeTotalLength(Audio.Streaming.ByteStreamSource bytes)
    {
        try
        {
            var end = bytes.Seek(0, 2);
            if (end <= 0) return null;
            var reset = bytes.Seek(0, 0);
            // If we could not get back to the start, the length is not worth the
            // risk of a corrupt copy — read from wherever we are with no total.
            return reset == 0 ? end : null;
        }
        catch
        {
            return null;
        }
    }

    private static void MoveIntoPlace(string tempPath, string destination)
    {
        if (File.Exists(destination)) File.Delete(destination);
        File.Move(tempPath, destination);
    }

    private static void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path)) File.Delete(path);
        }
        catch
        {
            // A leftover .part is harmless; the next attempt overwrites it.
        }
    }

    /// <summary>Cancel a download's record. The transfer, if one is running, is
    /// stopped through its own cancellation token; this also flips the record for
    /// a download that is only queued.</summary>
    public Task<DownloadItem> CancelAsync(string serverId, string remoteId, CancellationToken token = default)
        => _commands.CancelAsync(serverId, remoteId, token);

    /// <summary>
    /// Delete a download: drop the core's record and, if it named a file, delete
    /// the bytes this shell owns. The core deletes nothing on disk — that is the
    /// shell's half of the split.
    /// </summary>
    public async Task DeleteAsync(string serverId, string remoteId, CancellationToken token = default)
    {
        var relativePath = await _commands.DeleteAsync(serverId, remoteId, token).ConfigureAwait(false);
        if (relativePath is null) return;

        var absolute = Path.Combine(_root, relativePath);
        TryDelete(absolute);
    }

    public Task<DownloadItem?> StatusAsync(string serverId, string remoteId, CancellationToken token = default)
        => _commands.StatusAsync(serverId, remoteId, token);

    public Task<IReadOnlyList<DownloadItem>> ListAsync(
        IReadOnlyList<DownloadPhase>? states = null, CancellationToken token = default)
        => _commands.ListAsync(states, token);

    public Task<StorageUsage> StorageUsageAsync(CancellationToken token = default)
        => _commands.StorageUsageAsync(token);
}
