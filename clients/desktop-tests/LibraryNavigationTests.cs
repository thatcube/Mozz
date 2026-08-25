using Mozz.Desktop.ViewModels;
using Xunit;

namespace Mozz.Desktop.Tests;

public class LibraryNavigationTests
{
    [Fact]
    public void StartsAtTheInitialPageWithNoBackTarget()
    {
        var nav = new NavigationStack<string>("Home");

        Assert.Equal("Home", nav.Current);
        Assert.False(nav.CanGoBack);
        Assert.Empty(nav.BackStack);
    }

    [Fact]
    public void PushAddsCurrentPageToTheBackStack()
    {
        var nav = new NavigationStack<string>("Albums");

        nav.Push("Album Detail");
        nav.Push("Artist Detail");

        Assert.Equal("Artist Detail", nav.Current);
        Assert.True(nav.CanGoBack);
        Assert.Equal(["Albums", "Album Detail"], nav.BackStack);
    }

    [Fact]
    public void PopReturnsToTheMostRecentPage()
    {
        var nav = new NavigationStack<string>("Search");
        nav.Push("Album");
        nav.Push("Artist");

        Assert.True(nav.TryPop(out var first));
        Assert.Equal("Album", first);
        Assert.Equal("Album", nav.Current);

        Assert.True(nav.TryPop(out var second));
        Assert.Equal("Search", second);
        Assert.Equal("Search", nav.Current);
        Assert.False(nav.CanGoBack);
    }

    [Fact]
    public void ReplaceClearsHistoryByDefault()
    {
        var nav = new NavigationStack<string>("Songs");
        nav.Push("Album");

        nav.Replace("Artists");

        Assert.Equal("Artists", nav.Current);
        Assert.False(nav.CanGoBack);
    }

    [Fact]
    public void ReplaceCanPreserveHistoryForPageReapplication()
    {
        var nav = new NavigationStack<string>("Songs");
        nav.Push("Album");

        nav.Replace("Album", clearBackStack: false);

        Assert.Equal("Album", nav.Current);
        Assert.True(nav.CanGoBack);
        Assert.Equal(["Songs"], nav.BackStack);
    }

    [Fact]
    public void PopOnRootIsANoop()
    {
        var nav = new NavigationStack<string>("Home");

        Assert.False(nav.TryPop(out var page));
        Assert.Equal("Home", page);
        Assert.Equal("Home", nav.Current);
    }
}
