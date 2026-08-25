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
        var album = new Album(1, "album", "server", "Title", "Artist", null, 2024, 12, null, "group");
        var tracks = new[]
        {
            Track("a", duration: 120),
            Track("b", duration: 180),
        };

        Assert.Equal("2024 · 2 songs · 5 min", MediaDetailFormatting.AlbumMeta(album, tracks));
    }

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
