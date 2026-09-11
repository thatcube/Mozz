using System.Linq;
using Avalonia.Automation;
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
        // The rating row's header is the strip itself, so it is named for what
        // it carries.
        Assert.Equal(
            ["Like", "<rating strip>", "Play Next", "Add to Queue", "Start Radio", "Go to Artist",
             "Go to Album", "Download", "Don't recommend this track", "Don't recommend this artist"],
            flyout.ItemsSource!.Cast<object>().OfType<MenuItem>().Select(Name));
    }

    [Fact]
    public void TheRatingStripLinesUpWithTheIconsBelowIt()
    {
        var row = new Border();
        TrackMenu.SetTrack(row, Song());

        var flyout = Assert.IsType<MenuFlyout>(row.ContextFlyout);
        // It used to be a submenu of eleven typed-out glyphs ("½", "★", "★½" …)
        // you had to open a second menu to reach. A rating is a value, not a
        // command: it is five stars now, clicked or dragged across, the way
        // both phones have always shown it.
        var rating = flyout.ItemsSource!.Cast<object>().OfType<MenuItem>()
            .Single(i => i.Header is RatingStrip);
        var strip = Assert.IsType<RatingStrip>(rating.Header);

        // Pulled back across the empty icon column so the first star lands on
        // the same edge as the icons below it. Left where the header column
        // puts it, the row read as indented past everything else in the menu.
        Assert.True(strip.Margin.Left < 0);
        Assert.True(rating.StaysOpenOnClick);
    }

    /// <summary>
    /// The rating row is stars and nothing else.
    ///
    /// It briefly carried a readout ("2.5 stars") beside them, and that one
    /// label caused both of this menu's layout bugs. Sized to its text it
    /// re-measured the whole flyout on every half step — which moved the strip
    /// out from under the pointer, snapped a different star, and changed the
    /// text again, so the menu shook. Pinning its width stopped the shake and
    /// made the rating row permanently the widest thing here, leaving dead
    /// space beside every other item.
    ///
    /// The strip is a fixed size, so a header that is only the strip cannot do
    /// either. The value still reaches anyone not reading the stars, through
    /// the control's automation name.
    /// </summary>
    [Fact]
    public void TheRatingRowCarriesNoTextToResizeTheMenu()
    {
        var row = new Border();
        TrackMenu.SetTrack(row, Song());

        var flyout = Assert.IsType<MenuFlyout>(row.ContextFlyout);
        var strip = flyout.ItemsSource!.Cast<object>().OfType<MenuItem>()
            .Select(i => i.Header).OfType<RatingStrip>().Single();

        Assert.False(string.IsNullOrEmpty(AutomationProperties.GetName(strip)));
    }

    /// <summary>The header is a control now, so tests name items by what they carry.</summary>
    private static object? Name(MenuItem item) =>
        item.Header is RatingStrip ? "<rating strip>" : item.Header;

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
