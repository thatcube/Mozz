using Mozz.Desktop.Core;
using Mozz.Desktop.ViewModels;
using Xunit;

namespace Mozz.Desktop.Tests;

public sealed class SharedCommandPresentationTests
{
    [Fact]
    public void FavoriteStateOptimisticThenQueuedReconciled()
    {
        var track = Track(false);
        var optimistic = FavoriteStateProjector.Optimistic(track, liked: true);
        Assert.True(optimistic.IsFavorite);
        Assert.True(optimistic.FavoritePending);

        var reconciled = FavoriteStateProjector.Reconciled(optimistic, new FavoriteMutationResult(
            "srv", "trk", "track", "favorite", 1, true, Queued: true, Synced: false));
        Assert.True(reconciled.IsFavorite);
        Assert.True(reconciled.FavoritePending);

        var synced = FavoriteStateProjector.Reconciled(reconciled, new FavoriteMutationResult(
            "srv", "trk", "track", "favorite", 1, true, Queued: false, Synced: true));
        Assert.True(synced.IsFavorite);
        Assert.False(synced.FavoritePending);
    }

    [Fact]
    public void LyricLineSelectionHandlesTimedAndSilentCases()
    {
        LyricLine[] lines =
        [
            new("first", 0),
            new("second", 12.5),
            new("third", 20),
        ];

        Assert.Equal(1, LyricLineSelector.ActiveIndex(lines, 13));
        Assert.Null(LyricLineSelector.ActiveIndex(null, 13));
        Assert.Empty(LyricLineSelector.Rows(null, null));
    }

    /// <summary>
    /// The numbers the phones use. Both of them dim and soften a lyric column
    /// on exactly this curve, and a desktop that picked its own would read as a
    /// different app rather than the same one on a bigger screen.
    /// </summary>
    [Fact]
    public void LyricDepthMatchesThePhones()
    {
        Assert.Equal(1, LyricDepth.Opacity(0));
        Assert.Equal(0.4, LyricDepth.Opacity(1));
        Assert.Equal(0.28, LyricDepth.Opacity(2));
        Assert.Equal(0.2, LyricDepth.Opacity(9));

        // Nothing being sung: one even brightness, not one line picked out.
        Assert.Equal(0.8, LyricDepth.Opacity(null));

        // The line you are about to read stays sharp.
        Assert.Equal(0, LyricDepth.BlurRadius(0));
        Assert.Equal(0, LyricDepth.BlurRadius(1));
        Assert.Equal(1.1, LyricDepth.BlurRadius(2), 3);
        Assert.Equal(LyricDepth.BlurCeiling, LyricDepth.BlurRadius(40));
        Assert.Equal(0, LyricDepth.BlurRadius(null));
    }

    /// <summary>
    /// Re-lighting happens in place. The highlight moves ten times a second, and
    /// rebuilding the collection that often threw away every list container —
    /// which reset the scroll, so the column could never follow the song.
    /// </summary>
    [Fact]
    public void LightingTheColumnKeepsTheSameRows()
    {
        LyricLine[] lines = [new("first", 0), new("second", 12.5), new("third", 20)];
        var rows = LyricLineSelector.Rows(lines, 0);

        Assert.True(rows[0].IsActive);
        Assert.Equal(1, rows[1].Distance);

        LyricLineSelector.Light(rows, 2);

        Assert.False(rows[0].IsActive);
        Assert.True(rows[2].IsActive);
        Assert.Equal(2, rows[0].Distance);
        Assert.Equal(LyricDepth.Opacity(2), rows[0].LineOpacity);
    }

    /// <summary>
    /// An unsynced line has no timestamp, so there is nowhere for a click to go
    /// and the row must not offer one.
    /// </summary>
    [Fact]
    public void UnsyncedLyricsOfferNoSeek()
    {
        LyricLine[] lines = [new("first", null), new("second", null)];
        var rows = LyricLineSelector.Rows(lines, LyricLineSelector.ActiveIndex(lines, 30));

        Assert.All(rows, row => Assert.False(row.IsSynced));
        Assert.All(rows, row => Assert.Null(row.Distance));
        Assert.All(rows, row => Assert.Equal(0.8, row.LineOpacity));
    }

    /// <summary>
    /// A blank line is a beat of silence in the song. It has to keep its height
    /// or the column closes over it and the timing stops matching the record.
    /// </summary>
    [Fact]
    public void EmptyLyricLinesKeepTheirHeight()
    {
        var row = new LyricLineRow(string.Empty, 4);
        Assert.Equal(" ", row.DisplayText);
    }

    [Fact]
    public void SyncProgressSmootherNeverRunsAheadOfReportedCounts()
    {
        var smoother = new SyncProgressSmoother();
        var start = DateTimeOffset.Parse("2026-08-25T12:00:00Z");
        var first = Status("tracks", "Songs", "syncing", 10, 100);
        var second = Status("tracks", "Songs", "syncing", 50, 100);

        Assert.Equal(10, smoother.Update(first, start).Single().Synced);
        var eased = smoother.Update(second, start.AddSeconds(1)).Single();

        Assert.InRange(eased.Synced, 10, 50);
        Assert.Equal("10 / 100", new SyncPhaseRow("Songs", "syncing", 10, 100, false).CountText);
    }

    private static Track Track(bool liked) =>
        new(0, "trk", "srv", "Song", "Artist", "Album", null, null, null, 180, null, liked);

    private static SyncStatus Status(string phase, string label, string state, int synced, int total) =>
        new(
            Running: state != "done",
            Finished: state == "done",
            Phase: phase,
            ItemsSynced: synced,
            Total: total,
            Error: null,
            Artists: null,
            Albums: null,
            Tracks: null,
            Playlists: null,
            Details: [new SyncPhaseDetail(phase, label, state, synced, total, state == "done")],
            PhaseLabel: label);
}
