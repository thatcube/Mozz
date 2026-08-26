using Mozz.Desktop.Core;
using Xunit;

namespace Mozz.Desktop.Tests;

/// <summary>
/// Something has to keep asking after album art fails.
///
/// macOS only prompts for local network access once the app actually tries,
/// and granting it tells the app nothing. By then every visible tile has
/// failed and drawn its letter placeholder, and a tile never asks twice - so
/// the covers stayed blank until the user happened to navigate away and back.
/// The retry has to be patient enough not to hammer a server that is genuinely
/// off, and prompt enough that granting permission feels like it just worked.
/// </summary>
public class RetryScheduleTests
{
    [Fact]
    public void TheFirstWaitIsShortSoAGrantIsNoticedAlmostImmediately()
    {
        var schedule = new RetrySchedule();
        Assert.Equal(TimeSpan.FromSeconds(2), schedule.Next());
    }

    [Fact]
    public void EachWaitDoublesSoADeadServerIsNotHammered()
    {
        var schedule = new RetrySchedule();
        Assert.Equal(TimeSpan.FromSeconds(2), schedule.Next());
        Assert.Equal(TimeSpan.FromSeconds(4), schedule.Next());
        Assert.Equal(TimeSpan.FromSeconds(8), schedule.Next());
        Assert.Equal(TimeSpan.FromSeconds(16), schedule.Next());
    }

    /// <summary>
    /// A server that is off for an hour should still be asked about now and
    /// then, rather than the wait growing until it may as well have stopped.
    /// </summary>
    [Fact]
    public void TheWaitStopsGrowingAtTheCeiling()
    {
        var schedule = new RetrySchedule();
        for (var i = 0; i < 6; i++) schedule.Next();
        Assert.Equal(TimeSpan.FromSeconds(30), schedule.Next());
        Assert.Equal(TimeSpan.FromSeconds(30), schedule.Next());
    }

    /// <summary>
    /// The exponent is capped before the shift, not after. Left-shifting past
    /// 62 overflows into a negative delay, which would turn a schedule meant to
    /// slow down into one that fires continuously and forever.
    /// </summary>
    [Fact]
    public void AVeryLongOutageNeverProducesANegativeOrInstantWait()
    {
        var schedule = new RetrySchedule();
        for (var i = 0; i < 200; i++)
        {
            var wait = schedule.Next();
            Assert.True(wait > TimeSpan.Zero, $"attempt {i} produced {wait}");
            Assert.True(wait <= TimeSpan.FromSeconds(30), $"attempt {i} produced {wait}");
        }
    }

    [Fact]
    public void SucceedingStartsTheWaitsOverForTheNextOutage()
    {
        var schedule = new RetrySchedule();
        schedule.Next();
        schedule.Next();
        schedule.Reset();
        Assert.Equal(TimeSpan.FromSeconds(2), schedule.Next());
    }
}
