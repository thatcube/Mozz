using System.Linq;
using Avalonia.Controls;
using Mozz.Desktop.Controls;
using Xunit;
using Track = Mozz.Desktop.Core.Track;

namespace Mozz.Desktop.Tests;

/// <summary>
/// The menu used to be written inline in one template and so existed on one
/// list: right-clicking a song on an album page, in a playlist or on Home did
/// nothing, while the same right-click in Songs offered seven actions.
/// </summary>
public class TrackMenuTests
{
    [Fact]
    public void ARowThatNamesItsTrackGetsTheMenu()
    {
        var row = new Border();

        TrackMenu.SetTrack(row, Song());

        var flyout = Assert.IsType<MenuFlyout>(row.ContextFlyout);
        // Both ways of saying "I like this" are built; which one is shown is
        // decided when the menu opens, from what the server can actually keep —
        // Plex records star ratings and no favourite, Jellyfin the reverse.
        // The rating item's header is the strip itself rather than a word, so
        // it is named by the control it carries.
        Assert.Equal(
            ["Like", "<rating strip>", "Play Next", "Add to Queue", "Start Radio", "Go to Artist",
             "Go to Album", "Download", "Don't recommend this track", "Don't recommend this artist"],
            flyout.ItemsSource!.Cast<object>().OfType<MenuItem>().Select(Name));
    }

    [Fact]
    public void RatingIsAStripRatherThanAListOfSpelledOutStars()
    {
        var row = new Border();
        TrackMenu.SetTrack(row, Song());

        var flyout = Assert.IsType<MenuFlyout>(row.ContextFlyout);
        var rating = flyout.ItemsSource!.Cast<object>().OfType<MenuItem>()
            .Single(i => i.Header is StackPanel);

        // It used to be a submenu of eleven typed-out glyphs ("½", "★", "★½" …)
        // you had to open a second menu to reach. A rating is a value, not a
        // command: it is five stars now, clicked or dragged across, the way
        // both phones have always shown it.
        var panel = Assert.IsType<StackPanel>(rating.Header);
        Assert.Single(panel.Children.OfType<RatingStrip>());
        Assert.Null(rating.ItemsSource);

        // And the menu survives setting one. A rating is usually adjusted
        // twice, half a step either way, so closing after the first touch makes
        // the second adjustment cost a reopen.
        Assert.True(rating.StaysOpenOnClick);
    }

    /// <summary>The header is a control now, so tests name items by what they carry.</summary>
    private static object? Name(MenuItem item) =>
        item.Header is StackPanel panel && panel.Children.OfType<RatingStrip>().Any()
            ? "<rating strip>"
            : item.Header;

    [Fact]
    public void ARowWithNoTrackHasNoMenu()
    {
        var row = new Border();

        TrackMenu.SetTrack(row, null);

        Assert.Null(row.ContextFlyout);
    }

    [Fact]
    public void ARecycledRowKeepsOneMenuAndFollowsTheNewTrack()
    {
        // A virtualized list hands the same Border a different song as it
        // scrolls. Building a second flyout each time would leak one per row
        // per scroll; reading the track when the menu opens is what keeps the
        // one flyout correct.
        var row = new Border();
        TrackMenu.SetTrack(row, Song("first"));
        var first = row.ContextFlyout;

        TrackMenu.SetTrack(row, Song("second"));

        Assert.Same(first, row.ContextFlyout);
        Assert.Equal("second", TrackMenu.GetTrack(row)!.RemoteId);
    }

    private static Track Song(string remoteId = "remote") =>
        new(
            Id: 1,
            RemoteId: remoteId,
            ServerId: "server",
            Title: "Song",
            ArtistName: "Artist",
            AlbumTitle: "Album",
            AlbumRemoteId: "album",
            TrackNumber: 1,
            DiscNumber: 1,
            DurationSeconds: 180,
            ArtworkKey: "art",
            IsFavorite: false);
}
