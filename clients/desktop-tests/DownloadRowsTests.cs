using Mozz.Desktop.Core.Downloads;
using Mozz.Desktop.ViewModels;
using Xunit;

namespace Mozz.Desktop.Tests;

public class DownloadFormattingTests
{
    private static DownloadItem Item(
        DownloadPhase state,
        long received = 0,
        long? total = null,
        string? error = null) =>
        new(
            TrackId: 1,
            ServerId: "server",
            RemoteId: "remote",
            State: state,
            ReceivedBytes: received,
            TotalBytes: total,
            LocalPath: null,
            ErrorMessage: error,
            RequestedAt: 0,
            CompletedAt: null);

    [Theory]
    [InlineData(0, "0 B")]
    [InlineData(512, "512 B")]
    [InlineData(1024, "1 KB")]
    [InlineData(1536, "1.5 KB")]
    [InlineData(1048576, "1 MB")]
    [InlineData(1572864, "1.5 MB")]
    public void BytesReadsInBinaryUnits(long value, string expected) =>
        Assert.Equal(expected, DownloadFormatting.Bytes(value));

    [Fact]
    public void NegativeBytesClampToZero() =>
        Assert.Equal("0 B", DownloadFormatting.Bytes(-5));

    [Fact]
    public void DownloadedShowsItsSize()
    {
        var detail = DownloadFormatting.Detail(Item(DownloadPhase.Downloaded, received: 1024, total: 2048));
        // The completed size is the total, not what a mid-transfer counter held.
        Assert.Equal("2 KB", detail);
    }

    [Fact]
    public void DownloadingWithTotalShowsPercent()
    {
        var detail = DownloadFormatting.Detail(Item(DownloadPhase.Downloading, received: 512, total: 1024));
        Assert.Equal("Downloading… 50%", detail);
    }

    [Fact]
    public void DownloadingWithoutTotalShowsTransferred()
    {
        var detail = DownloadFormatting.Detail(Item(DownloadPhase.Downloading, received: 2048));
        Assert.Equal("Downloading… 2 KB", detail);
    }

    [Fact]
    public void QueuedReadsAsQueued() =>
        Assert.Equal("Queued", DownloadFormatting.Detail(Item(DownloadPhase.Queued)));

    [Fact]
    public void CancelledFailureReadsAsCancelled()
    {
        // The core records a cancel as Failed("Cancelled"); the label must not
        // leak that it is technically a failure.
        var item = Item(DownloadPhase.Failed, error: "Cancelled");
        Assert.Equal("Cancelled", DownloadFormatting.Detail(item));
        Assert.Equal("Cancelled", DownloadFormatting.StateLabel(item));
    }

    [Fact]
    public void GenuineFailureCarriesItsReason()
    {
        var item = Item(DownloadPhase.Failed, error: "network down");
        Assert.Equal("Failed: network down", DownloadFormatting.Detail(item));
        Assert.Equal("Failed", DownloadFormatting.StateLabel(item));
    }

    [Fact]
    public void FailureWithNoReasonStillReads()
    {
        var detail = DownloadFormatting.Detail(Item(DownloadPhase.Failed));
        Assert.Equal("Failed: unknown error", detail);
    }
}

public class DownloadRowTests
{
    private static DownloadItem Item(
        DownloadPhase state,
        long received = 0,
        long? total = null,
        string? error = null) =>
        new(1, "server", "remote", state, received, total, null, error, 0, null);

    [Fact]
    public void ProgressBarShowsOnlyWhileDownloadingWithKnownTotal()
    {
        var withTotal = DownloadRow.From(Item(DownloadPhase.Downloading, 512, 1024), "Song");
        Assert.True(withTotal.ShowProgress);
        Assert.Equal(0.5, withTotal.ProgressFraction, 3);

        // Downloading but the size was never announced: no honest bar to draw.
        var noTotal = DownloadRow.From(Item(DownloadPhase.Downloading, 512), "Song");
        Assert.False(noTotal.ShowProgress);
        Assert.Equal(0, noTotal.ProgressFraction);

        // Done is not "in progress", so the determinate bar is gone.
        var done = DownloadRow.From(Item(DownloadPhase.Downloaded, 1024, 1024), "Song");
        Assert.False(done.ShowProgress);
    }

    [Fact]
    public void CarriesIdentityAndTitle()
    {
        var row = DownloadRow.From(Item(DownloadPhase.Downloaded, 1024, 1024), "Song");
        Assert.Equal("server", row.ServerId);
        Assert.Equal("remote", row.RemoteId);
        Assert.Equal("Song", row.Title);
        Assert.True(row.IsDownloaded);
        Assert.False(row.IsFailed);
    }

    [Fact]
    public void FailedRowFlagsFailure()
    {
        var row = DownloadRow.From(Item(DownloadPhase.Failed, error: "boom"), "Song");
        Assert.True(row.IsFailed);
        Assert.False(row.IsDownloaded);
    }
}
