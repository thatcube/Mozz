using Mozz.Desktop.Core;
using Xunit;

namespace Mozz.Desktop.Tests;

/// <summary>
/// The queue's behaviour is what a listener actually notices — whether shuffle
/// interrupts the song that is playing, whether repeat-one survives pressing
/// next, whether turning shuffle off gives the album back. All of it is decided
/// here, with no engine and no window, so it can be pinned down exactly.
/// </summary>
public class PlaybackQueueTests
{
    private static Track T(string id) => new(
        Id: 0, RemoteId: id, ServerId: "srv", Title: id, ArtistName: "A",
        AlbumTitle: "Album", AlbumRemoteId: "alb", TrackNumber: null, DiscNumber: null,
        DurationSeconds: 100, ArtworkKey: null, IsFavorite: false);

    private static List<Track> Tracks(int count) =>
        Enumerable.Range(1, count).Select(i => T($"t{i}")).ToList();

    private static PlaybackQueue Loaded(int count, int start = 0)
    {
        var queue = new PlaybackQueue();
        queue.SetItems(Tracks(count), start);
        return queue;
    }

    [Fact]
    public void SetItems_StartsWhereAsked()
    {
        var queue = Loaded(5, start: 2);
        Assert.Equal("t3", queue.Current!.RemoteId);
        Assert.Equal(["t4", "t5"], queue.UpNext.Select(t => t.RemoteId));
    }

    [Fact]
    public void SetItems_ClampsAnOutOfRangeStart()
    {
        var queue = Loaded(3, start: 99);
        Assert.Equal("t3", queue.Current!.RemoteId);
    }

    [Fact]
    public void EmptyQueue_HasNothingToPlay()
    {
        var queue = new PlaybackQueue();
        Assert.Null(queue.Current);
        Assert.Null(queue.PeekNext);
        Assert.False(queue.HasNext);
        Assert.False(queue.Advance());
        Assert.False(queue.Retreat());
    }

    [Fact]
    public void Advance_StopsAtTheEndWithRepeatOff()
    {
        var queue = Loaded(2);
        Assert.True(queue.Advance());
        Assert.Equal("t2", queue.Current!.RemoteId);
        Assert.False(queue.HasNext);
        Assert.Null(queue.PeekNext);
        Assert.False(queue.Advance());
        Assert.Equal("t2", queue.Current!.RemoteId);
    }

    [Fact]
    public void Advance_WrapsWithRepeatAll()
    {
        var queue = Loaded(2);
        queue.Repeat = RepeatMode.All;
        queue.Advance();
        Assert.Equal("t1", queue.PeekNext!.RemoteId);
        Assert.True(queue.Advance());
        Assert.Equal("t1", queue.Current!.RemoteId);
    }

    /// <summary>
    /// The distinction the whole split exists for: a track that plays out
    /// repeats, but the user pressing next always moves on.
    /// </summary>
    [Fact]
    public void RepeatOne_RepeatsOnFinishButNotOnNext()
    {
        var queue = Loaded(3);
        queue.Repeat = RepeatMode.One;

        Assert.Equal("t1", queue.PeekNext!.RemoteId);
        Assert.True(queue.AdvanceAfterFinish());
        Assert.Equal("t1", queue.Current!.RemoteId);

        Assert.True(queue.Advance());
        Assert.Equal("t2", queue.Current!.RemoteId);
    }

    [Fact]
    public void Retreat_WrapsOnlyWhenRepeating()
    {
        var queue = Loaded(3);
        Assert.False(queue.HasPrevious);
        Assert.False(queue.Retreat());

        queue.Repeat = RepeatMode.All;
        Assert.True(queue.HasPrevious);
        Assert.True(queue.Retreat());
        Assert.Equal("t3", queue.Current!.RemoteId);
    }

    [Fact]
    public void Shuffle_KeepsTheCurrentTrackPlaying()
    {
        var queue = Loaded(50, start: 17);
        var playing = queue.Current!;

        queue.SetShuffled(true);

        Assert.Equal(playing, queue.Current);
        Assert.Equal(0, queue.Position);
        Assert.Equal(50, queue.Count);
    }

    [Fact]
    public void Shuffle_IsAPermutation_LosingAndDuplicatingNothing()
    {
        var queue = Loaded(200, start: 3);
        queue.SetShuffled(true);

        var played = new List<string> { queue.Current!.RemoteId };
        while (queue.Advance()) played.Add(queue.Current!.RemoteId);

        Assert.Equal(200, played.Count);
        Assert.Equal(200, played.Distinct().Count());
    }

    [Fact]
    public void Shuffle_ActuallyReordersALargeQueue()
    {
        var queue = Loaded(200);
        queue.SetShuffled(true);
        var order = queue.UpNext.Select(t => t.RemoteId).ToList();
        // Chance of a 199-element Fisher-Yates reproducing the base order is
        // 1/199!, so this is not a flake risk.
        Assert.NotEqual(Enumerable.Range(2, 199).Select(i => $"t{i}"), order);
    }

    [Fact]
    public void UnShuffle_GivesTheAlbumBackAtTheCurrentTrack()
    {
        var queue = Loaded(10, start: 6);
        queue.SetShuffled(true);
        var playing = queue.Current!;

        queue.SetShuffled(false);

        Assert.Equal(playing, queue.Current);
        Assert.Equal(["t8", "t9", "t10"], queue.UpNext.Select(t => t.RemoteId));
    }

    [Fact]
    public void SetItems_KeepsShuffleOn()
    {
        var queue = new PlaybackQueue();
        queue.SetShuffled(true);
        queue.SetItems(Tracks(30), 4);

        Assert.True(queue.IsShuffled);
        Assert.Equal("t5", queue.Current!.RemoteId);
        Assert.Equal(30, queue.Count);
    }

    [Fact]
    public void MoveToOrderIndex_JumpsWithinThePlaybackOrder()
    {
        var queue = Loaded(5);
        Assert.True(queue.MoveToOrderIndex(3));
        Assert.Equal("t4", queue.Current!.RemoteId);
        Assert.False(queue.MoveToOrderIndex(99));
        Assert.Equal("t4", queue.Current!.RemoteId);
    }

    /// <summary>
    /// A queue can legitimately hold the same track twice, and reconciling with
    /// the engine must not silently rewind to the first copy — which is why the
    /// caller advances first and only searches if that disagreed.
    /// </summary>
    [Fact]
    public void MoveToTrack_FindsTheTrackTheEngineReports()
    {
        var queue = Loaded(4);
        Assert.True(queue.MoveToTrack(T("t3")));
        Assert.Equal("t3", queue.Current!.RemoteId);
        Assert.False(queue.MoveToTrack(T("nope")));
        Assert.Equal("t3", queue.Current!.RemoteId);
    }

    [Fact]
    public void RepeatingShuffle_ReshufflesWhenItWraps()
    {
        var queue = Loaded(120);
        queue.SetShuffled(true);
        queue.Repeat = RepeatMode.All;

        var first = new List<string> { queue.Current!.RemoteId };
        while (queue.Position + 1 < queue.Count)
        {
            queue.Advance();
            first.Add(queue.Current!.RemoteId);
        }

        queue.Advance(); // wraps
        var second = new List<string> { queue.Current!.RemoteId };
        second.AddRange(queue.UpNext.Select(t => t.RemoteId));

        Assert.Equal(120, second.Count);
        Assert.Equal(120, second.Distinct().Count());
        Assert.NotEqual(first, second);
    }
}
