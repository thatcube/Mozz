using Mozz.Desktop.Core;
using Mozz.Desktop.ViewModels;
using Xunit;

namespace Mozz.Desktop.Tests;

public class HomeMixTests
{
    [Fact]
    public void TilesPutLikedSongsBeforeGeneratedMixes()
    {
        var tiles = HomeMixPresentation.BuildTiles(2, [
            Mix("supermix", "Supermix", "Glass Animals, The Beach Boys"),
            Mix("daily-1", "Daily Mix 1", "Poison, Jimi Hendrix"),
        ]);

        Assert.Equal(["Liked Songs", "Supermix", "Daily Mix 1"], tiles.Select(t => t.Title));
        Assert.True(tiles[0].IsLiked);
        Assert.Equal("2 songs", tiles[0].Subtitle);
        Assert.Equal("Glass Animals, The Beach Boys", tiles[1].Subtitle);
    }

    [Fact]
    public void TilesDoNotInventLikedSongsForEmptyFavorites()
    {
        var tiles = HomeMixPresentation.BuildTiles(0, [Mix("supermix", "Supermix", null)]);

        var tile = Assert.Single(tiles);
        Assert.Equal("Supermix", tile.Title);
        Assert.Equal("Made for You", tile.Subtitle);
    }

    [Fact]
    public void LikedAndMixCardsShareSurfaceAndTextStructure()
    {
        var tiles = HomeMixPresentation.BuildTiles(2, [Mix("supermix", "Supermix", null)]);

        var liked = HomeMixPresentation.BuildCardStructure(tiles[0]);
        var mix = HomeMixPresentation.BuildCardStructure(tiles[1]);

        Assert.Equal(mix.CardSurfaceToken, liked.CardSurfaceToken);
        Assert.Equal(mix.TitleTextToken, liked.TitleTextToken);
        Assert.Equal(mix.SubtitleTextToken, liked.SubtitleTextToken);
        Assert.Equal(HomeMixPresentation.LikedLeadingFillToken, liked.LeadingFillToken);
        Assert.Null(mix.LeadingFillToken);
        Assert.Equal(HomeMixPresentation.LikedLeadingContent, liked.LeadingContent);
        Assert.Equal(HomeMixPresentation.ArtworkLeadingContent, mix.LeadingContent);
    }

    [Fact]
    public void TrackCollectionMetaFormatsCountAndDuration()
    {
        var meta = HomeMixPresentation.TrackCollectionMeta([
            Track("one", duration: 120),
            Track("two", duration: 180),
        ]);

        Assert.Equal("2 songs · 5 min", meta);
    }

    [Fact]
    public void LikedSongsHeroDoesNotRepeatSongCountSubtitle()
    {
        var mix = HomeMixPresentation.BuildTiles(100, []).Single();

        Assert.Null(HomeMixPresentation.HeroSubtitle(mix, "100 songs · 6 hr 55 min"));
    }

    [Fact]
    public void GeneratedMixHeroKeepsEditorialSubtitle()
    {
        var mix = HomeMixPresentation.BuildTiles(0, [
            Mix("supermix", "Supermix", "Glass Animals, The Beach Boys"),
        ]).Single();

        Assert.Equal("Glass Animals, The Beach Boys",
            HomeMixPresentation.HeroSubtitle(mix, "20 songs · 1 hr 12 min"));
    }

    [Fact]
    public void HomeMixTilesChunkIntoVirtualizedRows()
    {
        var grid = new GridRows<HomeMixTile>();
        var tiles = HomeMixPresentation.BuildTiles(1, [
            Mix("supermix", "Supermix", "Glass Animals"),
            Mix("daily-1", "Daily Mix 1", "Poison"),
            Mix("daily-2", "Daily Mix 2", "Jimi Hendrix"),
        ]);

        grid.SetColumns(2);
        grid.Reset(tiles);

        Assert.Equal([2, 2], grid.Rows.Select(r => r.Count));
        Assert.Equal(["Liked Songs", "Supermix", "Daily Mix 1", "Daily Mix 2"],
            grid.Rows.SelectMany(r => r).Select(t => t.Title));
    }

    [Fact]
    public void HomeRowsKeepPhoneOrderAfterMixGrid()
    {
        var rows = HomeComposition.BuildRows(
            HomeMixPresentation.BuildTiles(1, [Mix("supermix", "Supermix", "Glass Animals")]),
            [Track("played")],
            [Album("added")],
            [Playlist("playlist")],
            mixColumns: 2,
            trackColumns: 3,
            albumColumns: 4,
            playlistColumns: 4);

        Assert.Collection(rows,
            row => Assert.IsType<HomeMixGridRow>(row),
            row => Assert.Equal("Recently Played", Assert.IsType<HomeSectionTitleRow>(row).Title),
            row => Assert.IsType<HomeTrackShelfRow>(row),
            row => Assert.Equal("Recently Added", Assert.IsType<HomeSectionTitleRow>(row).Title),
            row => Assert.IsType<HomeAlbumShelfRow>(row),
            row => Assert.Equal("Your Playlists", Assert.IsType<HomeSectionTitleRow>(row).Title),
            row => Assert.IsType<HomePlaylistShelfRow>(row));
    }

    [Fact]
    public void HomeRowsShowNoServerMessageInsteadOfBlankHome()
    {
        var rows = HomeComposition.BuildRows(
            [],
            [],
            [],
            [],
            mixColumns: 2,
            trackColumns: 3,
            albumColumns: 4,
            playlistColumns: 4,
            message: HomeMixPresentation.NoAttachedHomeServerMessage);

        var row = Assert.Single(rows);
        Assert.Equal(HomeMixPresentation.NoAttachedHomeServerMessage, Assert.IsType<HomeMessageRow>(row).Message);
    }

    [Fact]
    public void HomeEmptyStateWaitsForEveryShelfToBeEmpty()
    {
        Assert.True(HomeComposition.IsEmpty([], [], [], []));
        Assert.False(HomeComposition.IsEmpty([], [Track("played")], [], []));
        Assert.False(HomeComposition.IsEmpty([], [], [Album("added")], []));
        Assert.False(HomeComposition.IsEmpty([], [], [], [Playlist("playlist")]));
        Assert.False(HomeComposition.IsEmpty(HomeMixPresentation.BuildTiles(1, []), [], [], []));
    }

    [Fact]
    public async Task EmptyMixReadGeneratesThenReadsAgain()
    {
        var reads = 0;
        var generated = new List<string>();

        var result = await HomeMixLoader.LoadAsync(
            readMixes: () =>
            {
                reads++;
                return Task.FromResult<IReadOnlyList<HomeMix>>(
                    reads == 1 ? [] : [Mix("supermix", "Supermix", "Glass Animals")]);
            },
            readLikedTracks: () => Task.FromResult<IReadOnlyList<Track>>([Track("liked")]),
            generateMixes: serverId =>
            {
                generated.Add(serverId);
                return Task.CompletedTask;
            },
            serverIds: ["srv"]);

        Assert.True(result.Generated);
        Assert.Equal(2, reads);
        Assert.Equal(["srv"], generated);
        Assert.Single(result.Mixes);
        Assert.Null(result.Message);
        Assert.Single(result.LikedTracks);
    }

    [Fact]
    public async Task GenerationFailureReturnsPlainMessageAndKeepsLikedTracks()
    {
        var result = await HomeMixLoader.LoadAsync(
            readMixes: () => Task.FromResult<IReadOnlyList<HomeMix>>([]),
            readLikedTracks: () => Task.FromResult<IReadOnlyList<Track>>([Track("liked")]),
            generateMixes: _ => throw new InvalidOperationException("library is still syncing"),
            serverIds: ["srv"]);

        Assert.False(result.Generated);
        Assert.Empty(result.Mixes);
        Assert.Single(result.LikedTracks);
        Assert.Equal("Could not generate Home mixes: library is still syncing", result.Message);
    }

    [Fact]
    public async Task EmptyMixesWithoutServerExplainsWhatIsMissing()
    {
        var result = await HomeMixLoader.LoadAsync(
            readMixes: () => Task.FromResult<IReadOnlyList<HomeMix>>([]),
            readLikedTracks: () => Task.FromResult<IReadOnlyList<Track>>([]),
            generateMixes: _ => throw new InvalidOperationException("should not run"),
            serverIds: [""]);

        Assert.False(result.Generated);
        Assert.Equal(HomeMixPresentation.NoAttachedHomeServerMessage, result.Message);
    }

    [Fact]
    public async Task ShelfFailuresReturnNoRowsAndSurfaceStatusMessage()
    {
        var messages = new List<string>();

        var rows = await HomeShelfLoader.LoadAsync<Track>(
            "Recently Played",
            new CoreRequest("recentlyPlayedTracks") { ServerId = "server" },
            _ => throw new InvalidOperationException("server unavailable"),
            messages);

        Assert.Empty(rows);
        Assert.Equal(["Could not load Recently Played: server unavailable"], messages);
    }

    [Fact]
    public async Task ShelfNullPayloadReturnsNoRowsAndSurfaceStatusMessage()
    {
        var messages = new List<string>();

        var rows = await HomeShelfLoader.LoadAsync<Album>(
            "Recently Added",
            new CoreRequest("recentlyAddedAlbums") { ServerId = "server" },
            _ => Task.FromResult<IReadOnlyList<Album>?>(null),
            messages);

        Assert.Empty(rows);
        Assert.Equal(["Could not load Recently Added: no data returned."], messages);
    }

    [Fact]
    public async Task EmptyMixesAfterGenerationPointsAtListeningHistory()
    {
        var result = await HomeMixLoader.LoadAsync(
            readMixes: () => Task.FromResult<IReadOnlyList<HomeMix>>([]),
            readLikedTracks: () => Task.FromResult<IReadOnlyList<Track>>([]),
            generateMixes: _ => Task.CompletedTask,
            serverIds: ["srv"]);

        Assert.True(result.Generated);
        Assert.Equal("No generated mixes yet — play more music and check back soon.", result.Message);
    }

    private static HomeMix Mix(string id, string title, string? subtitle) =>
        new(id, title, subtitle, "supermix", "art", 123);

    private static Track Track(string title, double duration = 180) =>
        new(
            Id: title.GetHashCode(),
            RemoteId: $"remote-{title}",
            ServerId: "server",
            Title: title,
            ArtistName: "Artist",
            AlbumTitle: "Album",
            AlbumRemoteId: "album",
            TrackNumber: 1,
            DiscNumber: 1,
            DurationSeconds: duration,
            ArtworkKey: "art",
            IsFavorite: true);

    private static Album Album(string title) =>
        new(1, $"remote-{title}", "server", title, "Artist", "artist", 2024, 10, "art", $"group-{title}");

    private static Playlist Playlist(string title) =>
        new(1, $"remote-{title}", "server", title, 10, "art");
}
