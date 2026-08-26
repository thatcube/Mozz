using Mozz.Desktop.Core;
using Xunit;

namespace Mozz.Desktop.Tests;

/// <summary>
/// A cover that fails to load has to say why, once.
///
/// It used to say nothing at all — not to the user, not to a log — so a library
/// rendering every tile as a letter placeholder looked identical whether the
/// server genuinely had no art, the network was refusing the connection, or the
/// app had simply not attached to a server yet. Those need different responses
/// from the person looking at the screen, and hours went into telling them apart
/// by hand when one sentence would have done it.
/// </summary>
public class FailureReporterTests
{
    [Fact]
    public void TheSameReasonIsAnnouncedOnceRatherThanPerTile()
    {
        var reporter = new FailureReporter();
        var announced = new List<string>();
        reporter.Reported += announced.Add;

        // Five thousand albums failing for one reason is still one thing the
        // user needs to know.
        for (var i = 0; i < 50; i++) reporter.Report("Can't reach your server.");

        Assert.Single(announced);
        Assert.Equal("Can't reach your server.", announced[0]);
    }

    [Fact]
    public void ADifferentReasonIsStillAnnounced()
    {
        var reporter = new FailureReporter();
        var announced = new List<string>();
        reporter.Reported += announced.Add;

        reporter.Report("Waiting for the server.");
        reporter.Report("Can't reach your server.");

        Assert.Equal(2, announced.Count);
    }

    /// <summary>
    /// Attaching a server is the moment the previous complaint might have
    /// stopped being true, so the next genuine failure must be able to speak
    /// even if it repeats an earlier message.
    /// </summary>
    [Fact]
    public void ResettingLetsAnOldReasonBeAnnouncedAgain()
    {
        var reporter = new FailureReporter();
        var announced = new List<string>();
        reporter.Reported += announced.Add;

        reporter.Report("Waiting for the server.");
        reporter.Reset();
        reporter.Report("Waiting for the server.");

        Assert.Equal(2, announced.Count);
    }
}
