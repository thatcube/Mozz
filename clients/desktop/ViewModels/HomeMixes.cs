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
                ? "No generated mixes yet — sync more of your library and try again."
                : null);
    }
}
