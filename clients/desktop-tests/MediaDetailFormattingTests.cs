using Mozz.Desktop.Core;
using Mozz.Desktop.ViewModels;
using Xunit;

namespace Mozz.Desktop.Tests;

public class MediaDetailFormattingTests
{
    [Fact]
    public void AlbumTracksSortByDiscThenTrackNumber()
    {
        var rows = MediaDetailFormatting.AlbumTrackRows([
            Track("finale", disc: 2, number: 2, id: 4),
            Track("intro", disc: 1, number: 1, id: 1),
            Track("interlude", disc: 2, number: 1, id: 3),
            Track("untagged", disc: null, number: null, id: 5),
            Track("single", disc: 1, number: 2, id: 2),
        ]);

        Assert.Equal(["intro", "single", "untagged", "interlude", "finale"],
            rows.Select(r => r.Track.Title));
    }

    [Fact]
    public void MultiDiscAlbumsMarkDiscBoundaries()
    {
        var rows = MediaDetailFormatting.AlbumTrackRows([
            Track("a", disc: 1, number: 1),
            Track("b", disc: 2, number: 1),
            Track("c", disc: 2, number: 2),
        ]);

        Assert.True(rows[0].StartsDisc);
        Assert.Equal("Disc 1", rows[0].DiscTitle);
        Assert.True(rows[1].StartsDisc);
        Assert.Equal("Disc 2", rows[1].DiscTitle);
        Assert.False(rows[2].StartsDisc);
    }

    [Fact]
    public void SingleDiscAlbumsDoNotShowDiscHeaders()
    {
        var rows = MediaDetailFormatting.AlbumTrackRows([
            Track("a", disc: null, number: 1),
            Track("b", disc: 1, number: 2),
        ]);

        Assert.All(rows, row => Assert.False(row.StartsDisc));
        Assert.All(rows, row => Assert.Null(row.DiscTitle));
    }

    [Theory]
    [InlineData(59, "1 min")]
    [InlineData(48 * 60, "48 min")]
    [InlineData(62 * 60, "1 hr 2 min")]
    [InlineData(2 * 60 * 60, "2 hr")]
    [InlineData(0, "")]
    public void FormatsLongDurations(double seconds, string expected)
    {
        Assert.Equal(expected, MediaDetailFormatting.FormatLongDuration(seconds));
    }

    [Fact]
    public void AlbumMetaOmitsUnknownPieces()
    {
        var album = new Album(1, "album", "server", "Title", "Artist", null, 2024, 12, null, "group", Genres: ["Rock"]);
        var tracks = new[]
        {
            Track("a", duration: 120),
            Track("b", duration: 180),
        };

        Assert.Equal("Rock · 2024 · 2 songs · 5 min", MediaDetailFormatting.AlbumMeta(album, tracks));
    }

    [Fact]
    public void PlaylistMetaFallsBackToDeclaredTrackCount()
    {
        var playlist = new Playlist(1, "mix", "server", "Favorites", 12);

        Assert.Equal("12 songs", MediaDetailFormatting.PlaylistMeta(playlist, []));
    }

    [Fact]
    public void MoreByArtistExcludesCurrentAlbum()
    {
        var current = Album("current", 2024);
        var more = MediaDetailFormatting.MoreByArtist([
            Album("other", 2023),
            current,
            current with { Id = 99, Title = "duplicate" },
        ], current);

        Assert.Equal(["other"], more.Select(a => a.Title));
    }

    [Theory]
    [InlineData(1600, 900, false)]
    [InlineData(1000, 1000, true)]
    [InlineData(900, 1200, true)]
    public void ArtistHeroUsesCircularPortraitForSquareishArtwork(double width, double height, bool expected)
    {
        Assert.Equal(expected, ArtworkPresentation.ShouldUseCircularArtistPortrait(width, height));
    }

    [Fact]
    public void SinglesAndEpsOnlyUsesCoreClassification()
    {
        var coreContract = new AlbumReleaseKindLookup(
            unknownIsSingleOrEp: false,
            new Dictionary<int, bool> { [1] = true, [2] = true, [3] = true, [4] = false });
        var unknownAlbum = Album("unknown-count", 2024) with { TrackCount = null };
        var singleFromContract = Album("three-track-single", 2024) with { TrackCount = 3 };
        var albumFromContract = Album("four-track-album", 2024) with { TrackCount = 4 };
        var single = Album("core-single", 2024) with { IsSingleOrEp = true };

        var singles = MediaDetailFormatting.SinglesAndEps(
            [unknownAlbum, singleFromContract, albumFromContract, single],
            coreContract);

        Assert.Equal(["core-single", "three-track-single"], singles.Select(a => a.Title));
        Assert.Equal(["four-track-album", "unknown-count"],
            MediaDetailFormatting.StudioAlbums([unknownAlbum, singleFromContract, albumFromContract], coreContract)
                .Select(a => a.Title));
    }

    [Fact]
    public void TrackSubtitleIncludesAlbumAndYearWhenKnown()
    {
        Assert.Equal("Album · 2024",
            MediaDetailFormatting.TrackAlbumYear(Track("song"), Album("Album", 2024)));
        Assert.Equal("Album", MediaDetailFormatting.TrackAlbumYear(Track("song")));
    }

    [Fact]
    public void ShelfRowsChunkWithoutDroppingItems()
    {
        var albums = Enumerable.Range(1, 5).Select(i => Album($"album-{i}", 2024)).ToList();

        var rows = MediaDetailFormatting.ChunkRows(albums, columns: 2);

        Assert.Equal([2, 2, 1], rows.Select(r => r.Count));
        Assert.Equal(albums, rows.SelectMany(r => r));
    }

    private static Album Album(string title, int? year) =>
        new(1, $"remote-{title}", "server", title, "Artist", "artist", year, 10, null, $"group-{title}");

    private static Track Track(
        string title,
        int? disc = 1,
        int? number = 1,
        long id = 1,
        double duration = 180) =>
        new(
            Id: id,
            RemoteId: $"remote-{id}-{title}",
            ServerId: "server",
            Title: title,
            ArtistName: "Artist",
            AlbumTitle: "Album",
            AlbumRemoteId: "album",
            TrackNumber: number,
            DiscNumber: disc,
            DurationSeconds: duration,
            ArtworkKey: null,
            IsFavorite: false);
}
