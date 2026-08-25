using Mozz.Desktop.Core;
using Xunit;

namespace Mozz.Desktop.Tests;

public sealed class AppVersionTests
{
    [Fact]
    public void DisplayIncludesBuildNumber()
    {
        Assert.Equal("2026.8.25 (204)", AppVersion.Display("2026.8.25", "204"));
    }

    [Fact]
    public void DisplayOmitsMissingBuildNumber()
    {
        Assert.Equal("2026.8.25", AppVersion.Display("2026.8.25", ""));
    }

    [Fact]
    public void DisplayStripsLeadingZeroesFromMarketingVersionComponents()
    {
        Assert.Equal("2026.8.5 (204)", AppVersion.Display("2026.08.05", "204"));
    }

    [Fact]
    public void CalVerUsesUnpaddedMonthAndDay()
    {
        Assert.Equal("2026.8.5", AppVersion.CalVer(new DateTime(2026, 08, 05)));
    }
}
