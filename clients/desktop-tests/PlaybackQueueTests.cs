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

    private static List<Track> Tracks(params string[] titles) => titles
        .Select((title, index) => new Track(index + 1, $"remote-{index}", "server", title, "Artist", "Album", "album", index + 1, 1, 180, null, false))
        .ToList();
}
