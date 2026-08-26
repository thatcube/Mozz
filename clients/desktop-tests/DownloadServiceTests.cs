using Mozz.Desktop.Audio.Streaming;
using Mozz.Desktop.Core.Downloads;
using Xunit;

namespace Mozz.Desktop.Tests;

/// <summary>
/// The download service is the shell half of the split: it drives the byte
/// transfer and keeps the core's record honest about it. These exercise the whole
/// conversation with in-memory stand-ins for the three things it talks to — the
/// core's record commands, the source resolver, and the byte stream — so the
/// lifecycle, a failure that keeps its reason, a cancellation, and delete are all
/// checked without a server, a socket, or the dylib.
///
/// The record commands are a faithful fake: it applies the same rules the core
/// does (enqueue is idempotent, the first progress report moves queued to
/// downloading, a cancel is a failure whose message is exactly "Cancelled"), so
/// what these tests pin is the orchestration on top of that contract.
/// </summary>
public class DownloadServiceTests
{
    // MARK: In-memory doubles

    private sealed class FakeDownloadCommands : IDownloadCommands
    {
        private readonly Dictionary<(string, string), DownloadItem> _records = new();
        private long _nextTrackId = 1;
        private double _clock = 1;

        public List<long> ProgressReports { get; } = new();

        public void Seed(DownloadItem item) => _records[(item.ServerId, item.RemoteId)] = item;

        private DownloadItem Fresh(string serverId, string remoteId) =>
            new(_nextTrackId++, serverId, remoteId, DownloadPhase.Queued, 0, null, null, null, _clock++, null);

        public Task<DownloadItem> EnqueueAsync(string serverId, string remoteId, CancellationToken token = default)
        {
            var key = (serverId, remoteId);
            if (!_records.TryGetValue(key, out var record))
            {
                record = Fresh(serverId, remoteId);
                _records[key] = record;
            }

            return Task.FromResult(record);
        }

        public Task<DownloadItem> ReportProgressAsync(
            string serverId, string remoteId, long receivedBytes, long? totalBytes, CancellationToken token = default)
        {
            ProgressReports.Add(receivedBytes);
            var key = (serverId, remoteId);
            var record = _records[key];
            if (record.State == DownloadPhase.Downloaded) return Task.FromResult(record);

            record = record with
            {
                State = DownloadPhase.Downloading,
                ReceivedBytes = receivedBytes,
                TotalBytes = totalBytes ?? record.TotalBytes,
            };
            _records[key] = record;
            return Task.FromResult(record);
        }

        public Task<DownloadItem> CompleteAsync(
            string serverId, string remoteId, string localPath, long sizeBytes, CancellationToken token = default)
        {
            var key = (serverId, remoteId);
            var record = _records[key] with
            {
                State = DownloadPhase.Downloaded,
                LocalPath = localPath,
                ReceivedBytes = sizeBytes,
                TotalBytes = _records[key].TotalBytes ?? sizeBytes,
                CompletedAt = _clock++,
            };
            _records[key] = record;
            return Task.FromResult(record);
        }

        public Task<DownloadItem> FailAsync(
            string serverId, string remoteId, string message, CancellationToken token = default)
        {
            var key = (serverId, remoteId);
            var record = (_records.TryGetValue(key, out var e) ? e : Fresh(serverId, remoteId)) with
            {
                State = DownloadPhase.Failed,
                ErrorMessage = message,
            };
            _records[key] = record;
            return Task.FromResult(record);
        }

        public Task<DownloadItem> CancelAsync(string serverId, string remoteId, CancellationToken token = default)
        {
            var key = (serverId, remoteId);
            var record = (_records.TryGetValue(key, out var e) ? e : Fresh(serverId, remoteId)) with
            {
                State = DownloadPhase.Failed,
                ErrorMessage = "Cancelled",
            };
            _records[key] = record;
            return Task.FromResult(record);
        }

        public Task<string?> DeleteAsync(string serverId, string remoteId, CancellationToken token = default)
        {
            var key = (serverId, remoteId);
            if (_records.TryGetValue(key, out var record))
            {
                _records.Remove(key);
                return Task.FromResult(record.LocalPath);
            }

            return Task.FromResult<string?>(null);
        }

        public Task<DownloadItem?> StatusAsync(string serverId, string remoteId, CancellationToken token = default)
            => Task.FromResult(_records.TryGetValue((serverId, remoteId), out var record) ? record : null);

        public Task<IReadOnlyList<DownloadItem>> ListAsync(
            IReadOnlyList<DownloadPhase>? states = null, CancellationToken token = default)
        {
            IEnumerable<DownloadItem> items = _records.Values;
            if (states is { Count: > 0 }) items = items.Where(i => states.Contains(i.State));
            return Task.FromResult<IReadOnlyList<DownloadItem>>(items.ToList());
        }

        public Task<StorageUsage> StorageUsageAsync(CancellationToken token = default)
        {
            var done = _records.Values.Where(i => i.State == DownloadPhase.Downloaded).ToList();
            return Task.FromResult(new StorageUsage(done.Count, done.Sum(i => i.ReceivedBytes)));
        }
    }

    private sealed class FakeResolver(DownloadSource? source) : IDownloadSourceResolver
    {
        public int Calls { get; private set; }

        public Task<DownloadSource?> ResolveAsync(string serverId, string remoteId, CancellationToken token = default)
        {
            Calls++;
            return Task.FromResult(source);
        }
    }

    private sealed class FakeFactory(Func<ByteStreamSource> make) : IByteStreamFactory
    {
        public ByteStreamSource Open(string url, IReadOnlyDictionary<string, string> headers) => make();
    }

    /// <summary>An in-memory, fully seekable byte source over a fixed payload.</summary>
    private class MemoryByteStreamSource(byte[] data) : ByteStreamSource
    {
        protected readonly byte[] Data = data;
        protected long Position;

        public override int Read(Span<byte> buffer)
        {
            if (Position >= Data.Length) return 0;
            var count = (int)Math.Min(buffer.Length, Data.Length - Position);
            Data.AsSpan((int)Position, count).CopyTo(buffer);
            Position += count;
            return count;
        }

        public override long Seek(long offset, int whence)
        {
            var origin = whence switch { 0 => 0L, 1 => Position, 2 => Data.Length, _ => -1L };
            if (origin < 0) return -1;
            var target = origin + offset;
            if (target < 0) return -1;
            Position = target;
            return Position;
        }

        public override void Close() { }
    }

    /// <summary>Reports a length, then errors on the first read.</summary>
    private sealed class ErroringByteStreamSource : ByteStreamSource
    {
        public override int Read(Span<byte> buffer) => -1;
        public override long Seek(long offset, int whence) => whence == 2 ? 10 : 0;
        public override void Close() { }
    }

    /// <summary>Delivers one chunk, then trips the token so the next loop turn cancels.</summary>
    private sealed class CancelOnFirstReadByteStreamSource(byte[] data, CancellationTokenSource trigger)
        : MemoryByteStreamSource(data)
    {
        public override int Read(Span<byte> buffer)
        {
            var read = base.Read(buffer);
            trigger.Cancel();
            return read;
        }
    }

    // MARK: Fixtures

    private static readonly DownloadSource FlacSource =
        new("https://host/media/a.flac", new Dictionary<string, string> { ["Authorization"] = "token" });

    private static string NewRoot()
    {
        var root = Path.Combine(Path.GetTempPath(), "mozz-downloads-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        return root;
    }

    private static byte[] Payload(int length)
    {
        var bytes = new byte[length];
        new Random(1234).NextBytes(bytes);
        return bytes;
    }

    // MARK: Tests

    [Fact]
    public async Task AFullDownloadWritesTheFileReportsProgressAndCompletesTheRecord()
    {
        var root = NewRoot();
        try
        {
            var payload = Payload(600_000);
            var commands = new FakeDownloadCommands();
            var resolver = new FakeResolver(FlacSource);
            var factory = new FakeFactory(() => new MemoryByteStreamSource(payload));
            var service = new DownloadService(commands, resolver, factory, root);

            var result = await service.DownloadAsync("srv", "rem");

            Assert.Equal(DownloadPhase.Downloaded, result.State);
            Assert.Equal("srv/rem.flac", result.LocalPath);
            Assert.Equal(payload.Length, result.ReceivedBytes);
            Assert.Equal(1, resolver.Calls);

            var written = await File.ReadAllBytesAsync(Path.Combine(root, "srv", "rem.flac"));
            Assert.Equal(payload, written);

            // A progress report before completion, and one mid-transfer (neither
            // the opening zero nor the final total) — the UI has something to show.
            Assert.Contains(0L, commands.ProgressReports);
            Assert.Contains(commands.ProgressReports, r => r > 0 && r < payload.Length);

            // No partial file left behind.
            Assert.False(File.Exists(Path.Combine(root, "srv", "rem.flac.part")));
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task AnUnresolvableSourceIsRecordedAsAFailureWithAReason()
    {
        var root = NewRoot();
        try
        {
            var commands = new FakeDownloadCommands();
            var resolver = new FakeResolver(source: null);
            var factory = new FakeFactory(() => throw new InvalidOperationException("should not open"));
            var service = new DownloadService(commands, resolver, factory, root);

            var result = await service.DownloadAsync("srv", "rem");

            Assert.Equal(DownloadPhase.Failed, result.State);
            Assert.False(result.WasCancelled);
            Assert.Contains("resolve", result.ErrorMessage, StringComparison.OrdinalIgnoreCase);
            Assert.Empty(Directory.GetFiles(root, "*", SearchOption.AllDirectories));
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task AReadErrorFailsTheDownloadWithItsReasonAndLeavesNoPartial()
    {
        var root = NewRoot();
        try
        {
            var commands = new FakeDownloadCommands();
            var resolver = new FakeResolver(FlacSource);
            var factory = new FakeFactory(() => new ErroringByteStreamSource());
            var service = new DownloadService(commands, resolver, factory, root);

            var result = await service.DownloadAsync("srv", "rem");

            Assert.Equal(DownloadPhase.Failed, result.State);
            Assert.False(result.WasCancelled);
            Assert.Equal("The download source reported a read error.", result.ErrorMessage);
            Assert.Empty(Directory.GetFiles(root, "*", SearchOption.AllDirectories));
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task CancellingMidTransferRecordsACancelledFailureAndRemovesThePartial()
    {
        var root = NewRoot();
        try
        {
            var payload = Payload(600_000);
            var trigger = new CancellationTokenSource();
            var commands = new FakeDownloadCommands();
            var resolver = new FakeResolver(FlacSource);
            var factory = new FakeFactory(() => new CancelOnFirstReadByteStreamSource(payload, trigger));
            var service = new DownloadService(commands, resolver, factory, root);

            var result = await service.DownloadAsync("srv", "rem", trigger.Token);

            Assert.Equal(DownloadPhase.Failed, result.State);
            Assert.True(result.WasCancelled);
            Assert.Equal("Cancelled", result.ErrorMessage);
            Assert.False(File.Exists(Path.Combine(root, "srv", "rem.flac")));
            Assert.False(File.Exists(Path.Combine(root, "srv", "rem.flac.part")));
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task AnAlreadyDownloadedTrackShortCircuitsWithoutResolvingOrFetching()
    {
        var root = NewRoot();
        try
        {
            var commands = new FakeDownloadCommands();
            commands.Seed(new DownloadItem(
                5, "srv", "rem", DownloadPhase.Downloaded, 100, 100, "srv/rem.flac", null, 1.0, 2.0));
            var resolver = new FakeResolver(FlacSource);
            var factory = new FakeFactory(() => throw new InvalidOperationException("should not open"));
            var service = new DownloadService(commands, resolver, factory, root);

            var result = await service.DownloadAsync("srv", "rem");

            Assert.Equal(DownloadPhase.Downloaded, result.State);
            Assert.Equal(0, resolver.Calls);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task DeleteRemovesBothTheRecordAndTheBytes()
    {
        var root = NewRoot();
        try
        {
            var payload = Payload(4_096);
            var commands = new FakeDownloadCommands();
            var resolver = new FakeResolver(FlacSource);
            var factory = new FakeFactory(() => new MemoryByteStreamSource(payload));
            var service = new DownloadService(commands, resolver, factory, root);

            await service.DownloadAsync("srv", "rem");
            var file = Path.Combine(root, "srv", "rem.flac");
            Assert.True(File.Exists(file));

            await service.DeleteAsync("srv", "rem");

            Assert.False(File.Exists(file));
            Assert.Null(await service.StatusAsync("srv", "rem"));
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task StorageUsageCountsCompletedDownloads()
    {
        var root = NewRoot();
        try
        {
            var payload = Payload(4_096);
            var commands = new FakeDownloadCommands();
            var resolver = new FakeResolver(FlacSource);
            var factory = new FakeFactory(() => new MemoryByteStreamSource(payload));
            var service = new DownloadService(commands, resolver, factory, root);

            await service.DownloadAsync("srv", "rem");

            var usage = await service.StorageUsageAsync();
            Assert.Equal(1, usage.DownloadedTrackCount);
            Assert.Equal(payload.Length, usage.TotalBytes);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }
}
