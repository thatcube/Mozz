using Mozz.Desktop.Core;
using Mozz.Desktop.ViewModels;
using Xunit;

namespace Mozz.Desktop.Tests;

public class SearchPresentationTests
{
    [Fact]
    public void GroupsResultsByKindInStableOrder()
    {
        var results = new SearchResults(
            Artists: [new Artist(1, "artist", "server", "Artist", null)],
            Albums: [new Album(1, "album", "server", "Album", "Artist", "artist", 2024, 10, null)],
            Tracks: [Track("Song")]);
        var playlists = new[] { new Playlist(1, "playlist", "server", "Road Songs", 8) };

        var rows = SearchPresentation.Build(results, playlists, "song");

        Assert.IsType<SearchHeaderRow>(rows[0]);
        Assert.IsType<SearchTrackRow>(rows[1]);
        Assert.IsType<SearchHeaderRow>(rows[2]);
        Assert.IsType<SearchAlbumRow>(rows[3]);
        Assert.IsType<SearchHeaderRow>(rows[4]);
        Assert.IsType<SearchArtistRow>(rows[5]);
        Assert.IsType<SearchHeaderRow>(rows[6]);
        Assert.IsType<SearchPlaylistRow>(rows[7]);
    }

    [Fact]
    public void DebouncePlannerReturnsOnlyLatestSettledInput()
    {
        var planner = new SearchDebouncePlanner(TimeSpan.FromMilliseconds(140));
        var inputs = new[]
        {
            (TimeSpan.Zero, "a"),
            (TimeSpan.FromMilliseconds(80), "ab"),
            (TimeSpan.FromMilliseconds(160), "abc"),
        };

        Assert.Null(planner.ReadyQuery(inputs, TimeSpan.FromMilliseconds(250)));
        Assert.Equal("abc", planner.ReadyQuery(inputs, TimeSpan.FromMilliseconds(301)));
    }

    private static Track Track(string title) => new(1, "track", "server", title, "Artist", "Album", "album", 1, 1, 180, null, false);
}
