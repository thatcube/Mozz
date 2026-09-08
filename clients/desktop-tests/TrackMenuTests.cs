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
        Assert.Equal(
            ["Like", "Rating", "Play Next", "Add to Queue", "Start Radio", "Go to Artist",
             "Go to Album", "Download", "Don't recommend this track", "Don't recommend this artist"],
            flyout.ItemsSource!.Cast<object>().OfType<MenuItem>().Select(i => i.Header));
    }

    [Fact]
    public void RatingOffersFiveStarsAndAWayBackToNone()
    {
        var row = new Border();
        TrackMenu.SetTrack(row, Song());

        var flyout = Assert.IsType<MenuFlyout>(row.ContextFlyout);
        var rating = flyout.ItemsSource!.Cast<object>().OfType<MenuItem>()
            .Single(i => Equals(i.Header, "Rating"));

        // Half steps, because the core clamps to 0.5 and Plex stores halves;
        // whole stars only would round somebody's four-and-a-half down every
        // time they opened this. And "No Rating", because a rating and no
        // rating are different things — a control that cannot say the second
        // turns a misclick into a permanent opinion.
        Assert.Equal(
            ["½", "★", "★½", "★★", "★★½", "★★★", "★★★½", "★★★★", "★★★★½", "★★★★★", "No Rating"],
            rating.ItemsSource!.Cast<object>().OfType<MenuItem>().Select(i => i.Header));
    }

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
