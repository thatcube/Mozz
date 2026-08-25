using Mozz.Desktop.Core;
using Xunit;

namespace Mozz.Desktop.Tests;

public sealed class PlayHistoryRecorderTests
{
    private readonly List<DesktopPlayEvent> _events = [];
    private readonly PlayHistoryRecorder _recorder;

    public PlayHistoryRecorderTests()
    {
        _recorder = new PlayHistoryRecorder(_events.Add);
    }

    [Fact]
    public void EmitsStartedThenOneCompletedForNaturalEnd()
    {
        var track = Track("one", duration: 120);

        _recorder.Start(track);
        _recorder.CompleteCurrent(positionSeconds: 119.5, durationSeconds: 120);
        _recorder.CompleteCurrent(positionSeconds: 120, durationSeconds: 120);

        Assert.Collection(_events,
            started =>
            {
                Assert.Equal("started", started.Kind);
                Assert.Equal("one", started.RemoteId);
                Assert.Equal(0, started.PositionSeconds);
                Assert.Equal(120, started.DurationSeconds);
            },
            completed =>
            {
                Assert.Equal("completed", completed.Kind);
                Assert.Equal("one", completed.RemoteId);
                Assert.Equal(119.5, completed.PositionSeconds);
                Assert.Equal(120, completed.DurationSeconds);
            });
    }

    [Fact]
    public void EmitsSkippedWhenUserLeavesBeforeNaturalEnd()
    {
        _recorder.Start(Track("one", duration: 180));
        _recorder.SkipCurrent(positionSeconds: 42, durationSeconds: 180);
        _recorder.Start(Track("two", duration: 90));

        Assert.Equal(["started", "skipped", "started"], _events.Select(e => e.Kind));
        Assert.Equal("one", _events[1].RemoteId);
        Assert.Equal(42, _events[1].PositionSeconds);
        Assert.Equal("two", _events[2].RemoteId);
    }

    [Fact]
    public void EmitsSeekWithoutTerminatingPendingTrack()
    {
        _recorder.Start(Track("one", duration: 240));
        _recorder.SeekCurrent(positionSeconds: 15, durationSeconds: 240);
        Assert.Equal("one", _recorder.Pending?.RemoteId);
        _recorder.CompleteCurrent(positionSeconds: 240, durationSeconds: 240);

        Assert.Equal(["started", "seek", "completed"], _events.Select(e => e.Kind));
        Assert.Null(_recorder.Pending);
    }

    private static Track Track(string remoteId, double duration) =>
        new(0, remoteId, "srv", $"Track {remoteId}", "Artist", "Album", null, null, null, duration, null, false);
}
