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
