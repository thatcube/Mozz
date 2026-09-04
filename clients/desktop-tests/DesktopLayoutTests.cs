using Mozz.Desktop.ViewModels;
using Xunit;

namespace Mozz.Desktop.Tests;

public class DesktopLayoutTests
{
    [Theory]
    [InlineData(DesktopLayout.ExpandedWidth, DesktopLayoutTier.Expanded)]
    [InlineData(DesktopLayout.ExpandedWidth - 1, DesktopLayoutTier.Medium)]
    [InlineData(DesktopLayout.MediumWidth, DesktopLayoutTier.Medium)]
    [InlineData(DesktopLayout.MediumWidth - 1, DesktopLayoutTier.Compact)]
    public void TierForWindowWidthChangesAtNamedBreakpoints(double width, DesktopLayoutTier expected)
    {
        Assert.Equal(expected, DesktopLayout.TierForWindowWidth(width));
    }

    [Fact]
    public void BreakpointsLeaveRoomForTheNavigationStatesTheySelect()
    {
        Assert.True(DesktopLayout.ExpandedWidth > DesktopLayout.ExpandedSidebarWidth);
        Assert.True(DesktopLayout.MediumWidth > DesktopLayout.MediumSidebarWidth);
        Assert.True(DesktopLayout.MediumSidebarWidth < DesktopLayout.ExpandedSidebarWidth);
    }
}
