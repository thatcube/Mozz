using Mozz.Desktop.Core;
using Mozz.Desktop.ViewModels;
using Xunit;

namespace Mozz.Desktop.Tests;

public class PlaybackQueueTests
{
    [Fact]
    public void RemoveBeforeCurrentKeepsSameTrackPlaying()
    {
        var queue = new PlaybackQueue();
        var tracks = Tracks("one", "two", "three");
        queue.Start(tracks, 2);

        Assert.True(queue.Remove(tracks[0]));

        Assert.Equal("three", queue.Current?.Title);
        Assert.Equal(1, queue.CurrentIndex);
        Assert.Equal(["two", "three"], queue.Tracks.Select(t => t.Title).ToArray());
    }

    [Fact]
    public void MoveCurrentUpdatesCurrentIndex()
    {
        var queue = new PlaybackQueue();
        var tracks = Tracks("one", "two", "three");
        queue.Start(tracks, 1);

        Assert.True(queue.Move(tracks[1], 1));

        Assert.Equal("two", queue.Current?.Title);
        Assert.Equal(2, queue.CurrentIndex);
        Assert.Equal(["one", "three", "two"], queue.Tracks.Select(t => t.Title).ToArray());
    }

    [Fact]
    public void RepeatAllWrapsNextAndPrevious()
    {
        var queue = new PlaybackQueue();
        var tracks = Tracks("one", "two");
        queue.Start(tracks, 1);

        queue.CycleRepeat();

        Assert.Equal(0, queue.NextIndex());
        var secondQueue = new PlaybackQueue();
        secondQueue.Start(tracks, 0);
        secondQueue.CycleRepeat();
        Assert.Equal(1, secondQueue.PreviousIndex());
    }

    [Fact]
    public void AppendGrowsTheQueueWithoutMovingWhatIsPlaying()
    {
        // A station tops itself up this way. Restarting the queue with a longer
        // list would jump the listener back to its beginning mid-song.
        var queue = new PlaybackQueue();
        var tracks = Tracks("one", "two", "three");
        queue.Start(tracks, 1);

        queue.Append(Tracks("four", "five"));

        Assert.Equal("two", queue.Current?.Title);
        Assert.Equal(1, queue.CurrentIndex);
        Assert.Equal(5, queue.Tracks.Count);
        Assert.Equal("five", queue.Tracks[^1].Title);
    }

    [Fact]
    public void InsertNextLandsDirectlyAfterTheCurrentTrack()
    {
        var queue = new PlaybackQueue();
        var tracks = Tracks("one", "two", "three");
        queue.Start(tracks, 0);

        queue.InsertNext(Tracks("jumped")[0]);

        Assert.Equal(["one", "jumped", "two", "three"], queue.Tracks.Select(t => t.Title).ToArray());
        Assert.Equal("one", queue.Current?.Title);
    }

    [Fact]
    public void InsertNextIntoAnEmptyQueueJustPlaysIt()
    {
        // "Next" in an empty queue means the same thing, and refusing would be
        // a menu item that does nothing.
        var queue = new PlaybackQueue();
        queue.InsertNext(Tracks("only")[0]);
        Assert.Single(queue.Tracks);
    }

    private static List<Track> Tracks(params string[] titles) => titles
        .Select((title, index) => new Track(index + 1, $"remote-{index}", "server", title, "Artist", "Album", "album", index + 1, 1, 180, null, false))
        .ToList();
}
