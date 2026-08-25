using Mozz.Desktop.Core;

namespace Mozz.Desktop.ViewModels;

public static class HomeMixIds
{
    public const string LikedSongs = "liked-songs";
}

public sealed record HomeMix(
    string Id,
    string Title,
    string? Subtitle,
    string Kind,
    string? ArtworkKey,
    double? GeneratedAt);

public sealed record HomeMixTile(
    string Id,
    string Title,
    string? Subtitle,
    string? Kind,
    string? ArtworkKey,
    string? ServerId,
    bool IsLiked,
    int? TrackCount)
{
    public string FallbackText => Title;
}

public abstract record HomeRow;

public sealed record HomeMixGridRow(IReadOnlyList<HomeMixTile> Mixes) : HomeRow;

public sealed record HomeSectionTitleRow(string Title) : HomeRow;

public sealed record HomeTrackCard(Track Track, string Subtitle);

public sealed record HomeTrackShelfRow(IReadOnlyList<HomeTrackCard> Tracks) : HomeRow;

public sealed record HomeAlbumShelfRow(IReadOnlyList<Album> Albums) : HomeRow;

public sealed record HomePlaylistShelfRow(IReadOnlyList<Playlist> Playlists) : HomeRow;

public static class HomeMixPresentation
{
    public static IReadOnlyList<HomeMixTile> BuildTiles(int likedCount, IEnumerable<HomeMix> mixes, string? artworkServerId = null)
    {
        var tiles = new List<HomeMixTile>();
        if (likedCount > 0)
        {
            tiles.Add(new HomeMixTile(
                HomeMixIds.LikedSongs,
                "Liked Songs",
                FormatSongCount(likedCount),
                "liked",
                ArtworkKey: null,
                ServerId: null,
                IsLiked: true,
                TrackCount: likedCount));
        }

        tiles.AddRange(mixes.Select(mix => new HomeMixTile(
            mix.Id,
            mix.Title,
            FormatSubtitle(mix.Subtitle),
            mix.Kind,
            mix.ArtworkKey,
            artworkServerId,
            IsLiked: false,
            TrackCount: null)));

        return tiles;
    }

    public static string FormatSongCount(int count) => count == 1 ? "1 song" : $"{count} songs";

    public static string? FormatSubtitle(string? subtitle) =>
        string.IsNullOrWhiteSpace(subtitle) ? "Made for You" : subtitle.Trim();

    public static string TrackCollectionMeta(IReadOnlyCollection<Track> tracks)
    {
        var parts = new List<string>();
        if (tracks.Count > 0) parts.Add(FormatSongCount(tracks.Count));
        var duration = MediaDetailFormatting.FormatLongDuration(tracks.Sum(t => t.DurationSeconds));
        if (!string.IsNullOrEmpty(duration)) parts.Add(duration);
        return string.Join(" · ", parts);
    }

    public static string? HeroSubtitle(HomeMixTile mix, string metadata)
    {
        if (string.IsNullOrWhiteSpace(mix.Subtitle)) return null;
        if (mix.IsLiked && MetadataAlreadyStartsWith(metadata, mix.Subtitle)) return null;
        return mix.Subtitle;
    }

    private static bool MetadataAlreadyStartsWith(string metadata, string subtitle) =>
        metadata.Equals(subtitle, StringComparison.CurrentCultureIgnoreCase)
        || metadata.StartsWith($"{subtitle} ·", StringComparison.CurrentCultureIgnoreCase);
}

public static class HomeComposition
{
    public static IReadOnlyList<HomeRow> BuildRows(
        IReadOnlyList<HomeMixTile> mixes,
        IReadOnlyList<Track> recentlyPlayed,
        IReadOnlyList<Album> recentlyAddedAlbums,
        IReadOnlyList<Playlist> playlists,
        int mixColumns,
        int trackColumns,
        int albumColumns,
        int playlistColumns)
    {
        var rows = new List<HomeRow>();
        foreach (var row in MediaDetailFormatting.ChunkRows(mixes, mixColumns))
            rows.Add(new HomeMixGridRow(row));

        AddTrackShelf(rows, "Recently Played", recentlyPlayed, trackColumns);
        AddAlbumShelf(rows, "Recently Added", recentlyAddedAlbums, albumColumns);
        AddPlaylistShelf(rows, "Your Playlists", playlists, playlistColumns);
        return rows;
    }

    public static bool IsEmpty(
        IReadOnlyCollection<HomeMixTile> mixes,
        IReadOnlyCollection<Track> recentlyPlayed,
        IReadOnlyCollection<Album> recentlyAddedAlbums,
        IReadOnlyCollection<Playlist> playlists) =>
        mixes.Count == 0
        && recentlyPlayed.Count == 0
        && recentlyAddedAlbums.Count == 0
        && playlists.Count == 0;

    private static void AddTrackShelf(List<HomeRow> rows, string title, IReadOnlyList<Track> tracks, int columns)
    {
        if (tracks.Count == 0) return;
        rows.Add(new HomeSectionTitleRow(title));
        var cards = tracks
            .Select(track => new HomeTrackCard(track, string.IsNullOrWhiteSpace(track.ArtistName) ? track.AlbumTitle ?? "" : track.ArtistName))
            .ToList();
        foreach (var row in MediaDetailFormatting.ChunkRows(cards, columns))
            rows.Add(new HomeTrackShelfRow(row));
    }

    private static void AddAlbumShelf(List<HomeRow> rows, string title, IReadOnlyList<Album> albums, int columns)
    {
        if (albums.Count == 0) return;
        rows.Add(new HomeSectionTitleRow(title));
        foreach (var row in MediaDetailFormatting.ChunkRows(albums, columns))
            rows.Add(new HomeAlbumShelfRow(row));
    }

    private static void AddPlaylistShelf(List<HomeRow> rows, string title, IReadOnlyList<Playlist> playlists, int columns)
    {
        if (playlists.Count == 0) return;
        rows.Add(new HomeSectionTitleRow(title));
        foreach (var row in MediaDetailFormatting.ChunkRows(playlists, columns))
            rows.Add(new HomePlaylistShelfRow(row));
    }
}

public sealed record HomeMixLoadResult(
    IReadOnlyList<HomeMix> Mixes,
    IReadOnlyList<Track> LikedTracks,
    bool Generated,
    string? Message);

public static class HomeMixLoader
{
    public static async Task<HomeMixLoadResult> LoadAsync(
        Func<Task<IReadOnlyList<HomeMix>>> readMixes,
        Func<Task<IReadOnlyList<Track>>> readLikedTracks,
        Func<string, Task> generateMixes,
        IReadOnlyList<string> serverIds,
        Action? generationStarted = null)
    {
        var mixes = await readMixes();
        var liked = await readLikedTracks();
        if (mixes.Count > 0)
        {
            return new HomeMixLoadResult(mixes, liked, Generated: false, Message: null);
        }

        if (serverIds.Count == 0)
        {
            return new HomeMixLoadResult(
                mixes,
                liked,
                Generated: false,
                Message: "No generated mixes yet — connect or sync a server to build Home.");
        }

        try
        {
            generationStarted?.Invoke();
            foreach (var serverId in serverIds.Where(id => !string.IsNullOrWhiteSpace(id)).Distinct(StringComparer.Ordinal))
            {
                await generateMixes(serverId);
            }
        }
        catch (Exception ex)
        {
            return new HomeMixLoadResult(
                mixes,
                liked,
                Generated: false,
                Message: $"Could not generate Home mixes: {ex.Message}");
        }

        mixes = await readMixes();
        return new HomeMixLoadResult(
            mixes,
            liked,
            Generated: true,
            Message: mixes.Count == 0
                ? "No generated mixes yet — play more music and check back soon."
                : null);
    }
}
