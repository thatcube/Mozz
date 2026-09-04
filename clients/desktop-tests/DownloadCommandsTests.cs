using Mozz.Desktop.Core.Downloads;
using Mozz.V1;
using Xunit;

namespace Mozz.Desktop.Tests;

/// <summary>
/// The typed download client, checked in isolation from the core. Two things can
/// go wrong here and nowhere else: the request it builds (the wrong command, or
/// an optional field sent as a defaulted zero when it should be absent) and the
/// projection back (an optional wire field read without checking its presence,
/// so an unset total reads as a real 0). A fake invoker stands in for the core so
/// both directions are visible without the dylib.
/// </summary>
public class DownloadCommandsTests
{
    /// <summary>Captures the request and returns whatever the test scripts.</summary>
    private sealed class FakeInvoker(Func<Request, Response> responder) : ICoreInvoker
    {
        public Request? Last { get; private set; }

        public Response Invoke(Request request)
        {
            Last = request;
            return responder(request);
        }

        public Task<Response> InvokeAsync(Request request, CancellationToken token = default)
            => Task.FromResult(Invoke(request));
    }

    private static Download Sample(DownloadState state) => new()
    {
        TrackId = 7,
        ServerId = "srv",
        RemoteId = "rem",
        State = state,
        ReceivedBytes = 10,
        RequestedAt = 100.0,
    };

    [Fact]
    public async Task EnqueueSendsAnEnqueueCommandAndProjectsTheRecord()
    {
        var invoker = new FakeInvoker(_ => new Response
        {
            EnqueueDownload = new EnqueueDownloadResponse { Download = Sample(DownloadState.Queued) },
        });
        var commands = new DownloadCommands(invoker);

        var item = await commands.EnqueueAsync("srv", "rem");

        Assert.Equal(Request.CommandOneofCase.EnqueueDownload, invoker.Last!.CommandCase);
        Assert.Equal("srv", invoker.Last.EnqueueDownload.ServerId);
        Assert.Equal("rem", invoker.Last.EnqueueDownload.RemoteId);
        Assert.Equal(DownloadPhase.Queued, item.State);
        Assert.Equal(7, item.TrackId);
    }

    [Fact]
    public async Task AnAbsentTotalIsSentAsAbsentNotZero()
    {
        var invoker = new FakeInvoker(_ => new Response
        {
            ReportDownloadProgress = new ReportDownloadProgressResponse { Download = Sample(DownloadState.Downloading) },
        });
        var commands = new DownloadCommands(invoker);

        await commands.ReportProgressAsync("srv", "rem", receivedBytes: 512, totalBytes: null);

        Assert.False(invoker.Last!.ReportDownloadProgress.HasTotalBytes);
        Assert.Equal(512, invoker.Last.ReportDownloadProgress.ReceivedBytes);
    }

    [Fact]
    public async Task AKnownTotalIsSentThrough()
    {
        var invoker = new FakeInvoker(_ => new Response
        {
            ReportDownloadProgress = new ReportDownloadProgressResponse { Download = Sample(DownloadState.Downloading) },
        });
        var commands = new DownloadCommands(invoker);

        await commands.ReportProgressAsync("srv", "rem", receivedBytes: 512, totalBytes: 4096);

        Assert.True(invoker.Last!.ReportDownloadProgress.HasTotalBytes);
        Assert.Equal(4096, invoker.Last.ReportDownloadProgress.TotalBytes);
    }

    [Fact]
    public async Task ProjectionKeepsOptionalFieldsAbsentRatherThanDefaulted()
    {
        // No total, no path, no completed-at set on the wire record.
        var invoker = new FakeInvoker(_ => new Response
        {
            EnqueueDownload = new EnqueueDownloadResponse { Download = Sample(DownloadState.Queued) },
        });
        var commands = new DownloadCommands(invoker);

        var item = await commands.EnqueueAsync("srv", "rem");

        Assert.Null(item.TotalBytes);
        Assert.Null(item.LocalPath);
        Assert.Null(item.ErrorMessage);
        Assert.Null(item.CompletedAt);
        Assert.Null(item.Fraction); // No total -> no fraction, not 0%.
    }

    [Fact]
    public async Task ProjectionReadsOptionalFieldsWhenPresent()
    {
        var download = Sample(DownloadState.Downloaded);
        download.TotalBytes = 200;
        download.ReceivedBytes = 100;
        download.LocalPath = "srv/rem.flac";
        download.CompletedAt = 250.0;
        var invoker = new FakeInvoker(_ => new Response
        {
            CompleteDownload = new CompleteDownloadResponse { Download = download },
        });
        var commands = new DownloadCommands(invoker);

        var item = await commands.CompleteAsync("srv", "rem", "srv/rem.flac", 100);

        Assert.Equal(200, item.TotalBytes);
        Assert.Equal("srv/rem.flac", item.LocalPath);
        Assert.Equal(250.0, item.CompletedAt);
        Assert.Equal(0.5, item.Fraction);
    }

    [Fact]
    public async Task ACancelledRecordProjectsAsFailedWithTheCancelledMarker()
    {
        // The core records a cancel as a Failed record whose message is exactly
        // "Cancelled"; the projection must preserve that so the UI can tell a
        // cancellation from a genuine failure.
        var download = Sample(DownloadState.Failed);
        download.ErrorMessage = "Cancelled";
        var invoker = new FakeInvoker(_ => new Response
        {
            CancelDownload = new CancelDownloadResponse { Download = download },
        });
        var commands = new DownloadCommands(invoker);

        var item = await commands.CancelAsync("srv", "rem");

        Assert.Equal(Request.CommandOneofCase.CancelDownload, invoker.Last!.CommandCase);
        Assert.Equal(DownloadPhase.Failed, item.State);
        Assert.True(item.WasCancelled);
    }

    [Fact]
    public async Task AFailureKeepsItsReason()
    {
        var download = Sample(DownloadState.Failed);
        download.ErrorMessage = "disk full";
        var invoker = new FakeInvoker(_ => new Response
        {
            FailDownload = new FailDownloadResponse { Download = download },
        });
        var commands = new DownloadCommands(invoker);

        var item = await commands.FailAsync("srv", "rem", "disk full");

        Assert.Equal("disk full", invoker.Last!.FailDownload.Message);
        Assert.Equal(DownloadPhase.Failed, item.State);
        Assert.Equal("disk full", item.ErrorMessage);
        Assert.False(item.WasCancelled);
    }

    [Fact]
    public async Task DeleteReturnsTheRemovedPathWhenPresentAndNullWhenNot()
    {
        var withPath = new FakeInvoker(_ => new Response
        {
            DeleteDownload = new DeleteDownloadResponse { RemovedLocalPath = "srv/rem.flac" },
        });
        Assert.Equal("srv/rem.flac", await new DownloadCommands(withPath).DeleteAsync("srv", "rem"));

        var withoutPath = new FakeInvoker(_ => new Response
        {
            DeleteDownload = new DeleteDownloadResponse(),
        });
        Assert.Null(await new DownloadCommands(withoutPath).DeleteAsync("srv", "rem"));
    }

    [Fact]
    public async Task StatusReturnsNullWhenTheCoreHasNoRecord()
    {
        var invoker = new FakeInvoker(_ => new Response
        {
            DownloadStatus = new DownloadStatusResponse(), // Download left unset.
        });
        var commands = new DownloadCommands(invoker);

        Assert.Null(await commands.StatusAsync("srv", "rem"));
    }

    [Fact]
    public async Task ListForwardsTheStateFilterAndMapsEveryRecord()
    {
        var invoker = new FakeInvoker(_ =>
        {
            var response = new Response { Downloads = new DownloadsResponse() };
            response.Downloads.Downloads.Add(Sample(DownloadState.Downloaded));
            response.Downloads.Downloads.Add(Sample(DownloadState.Failed));
            return response;
        });
        var commands = new DownloadCommands(invoker);

        var items = await commands.ListAsync(new[] { DownloadPhase.Downloaded, DownloadPhase.Failed });

        Assert.Equal(
            new[] { DownloadState.Downloaded, DownloadState.Failed },
            invoker.Last!.Downloads.States);
        Assert.Equal(2, items.Count);
    }

    [Fact]
    public async Task AnEmptyFilterSendsNoStates()
    {
        var invoker = new FakeInvoker(_ => new Response { Downloads = new DownloadsResponse() });
        var commands = new DownloadCommands(invoker);

        await commands.ListAsync(states: null);

        Assert.Empty(invoker.Last!.Downloads.States);
    }

    [Fact]
    public async Task StorageUsageMapsBothCounters()
    {
        var invoker = new FakeInvoker(_ => new Response
        {
            StorageUsage = new StorageUsageResponse { DownloadedTrackCount = 3, TotalBytes = 9000 },
        });
        var commands = new DownloadCommands(invoker);

        var usage = await commands.StorageUsageAsync();

        Assert.Equal(Request.CommandOneofCase.StorageUsage, invoker.Last!.CommandCase);
        Assert.Equal(3, usage.DownloadedTrackCount);
        Assert.Equal(9000, usage.TotalBytes);
    }
}
