using Avalonia;
using Avalonia.Media;
using Avalonia.Media.Immutable;
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

    /// <summary>
    /// The name as it appears on the cover, with a trailing number split off.
    /// "Daily Mix 3" becomes "Daily Mix" plus "3", so the three of them read as
    /// one series rather than three unrelated titles — the arrangement Spotify
    /// uses for the same reason.
    /// </summary>
    public string ChipTitle => SplitOrdinal().Title;

    public string? ChipOrdinal => SplitOrdinal().Ordinal;

    public bool HasOrdinal => ChipOrdinal is not null;

    private (string Title, string? Ordinal) SplitOrdinal()
    {
        var cut = Title.LastIndexOf(' ');
        if (cut <= 0) return (Title, null);
        var tail = Title[(cut + 1)..];
        return tail.Length is > 0 and <= 2 && tail.All(char.IsDigit)
            ? (Title[..cut], tail)
            : (Title, null);
    }

    /// <summary>
    /// The colour the cover is built from.
    ///
    /// Deliberately a fixed palette keyed by the mix's own id rather than
    /// anything sampled: a Daily Mix keeps the same colour every day even as its
    /// artwork changes, which is what makes the set recognisable at a glance,
    /// and two mixes never collide by accident the way two sampled covers can.
    /// Liked Songs keeps the app's own accent, because it is not a mix.
    /// </summary>
    public string AccentColor => IsLiked ? "#D8213F" : MixAccents[
        (int)((uint)StableHash(Id) % (uint)MixAccents.Length)];

    private static readonly string[] MixAccents =
    [
        "#F2C94C", // amber
        "#EB5757", // coral
        "#56CCF2", // sky
        "#BB6BD9", // orchid
        "#6FCF97", // mint
        "#F2994A", // tangerine
        "#7B8CFF", // periwinkle
        "#EF5DA8", // rose
    ];

    public IBrush AccentBrush => new ImmutableSolidColorBrush(Color.Parse(AccentColor));

    /// <summary>
    /// Ink for the chip: black on a light accent, white on a dark one. Picked
    /// from the colour's own luminance rather than fixed, because the palette
    /// spans amber to orchid and one ink cannot read on both.
    /// </summary>
    public IBrush ChipForeground
    {
        get
        {
            var c = Color.Parse(AccentColor);
            var luma = (0.2126 * c.R + 0.7152 * c.G + 0.0722 * c.B) / 255.0;
            return new ImmutableSolidColorBrush(luma > 0.55
                ? Color.FromRgb(0x10, 0x10, 0x14)
                : Colors.White);
        }
    }

    /// <summary>
    /// The wash up the cover, in the mix's own colour rather than plain black.
    /// It is what ties the artwork to the chips below it — a black scrim would
    /// read as a caption laid over someone else's record, which is exactly what
    /// the borrowed cover is.
    /// </summary>
    public IBrush AccentWash
    {
        get
        {
            var c = Color.Parse(AccentColor);
            return new ImmutableLinearGradientBrush(
                [
                    new ImmutableGradientStop(0.0, Color.FromArgb(0x00, c.R, c.G, c.B)),
                    new ImmutableGradientStop(0.45, Color.FromArgb(0x40, c.R, c.G, c.B)),
                    new ImmutableGradientStop(0.78, Color.FromArgb(0xB8, 0x0A, 0x0A, 0x0C)),
                    new ImmutableGradientStop(1.0, Color.FromArgb(0xE6, 0x0A, 0x0A, 0x0C)),
                ],
                startPoint: new RelativePoint(0, 0, RelativeUnit.Relative),
                endPoint: new RelativePoint(0, 1, RelativeUnit.Relative));
        }
    }

    /// <summary>FNV-1a, so the colour is the same on every machine and every run.</summary>
    private static int StableHash(string value)
    {
        unchecked
        {
            var hash = 2166136261;
            foreach (var ch in value) hash = (hash ^ ch) * 16777619;
            return (int)hash;
        }
    }
}

public abstract record HomeRow;

public sealed record HomeMixGridRow(IReadOnlyList<HomeMixTile> Mixes) : HomeRow;

public sealed record HomeSectionTitleRow(string Title) : HomeRow;

public sealed record HomeMessageRow(string Message) : HomeRow;

public sealed record HomeTrackCard(Track Track, string Subtitle);

public sealed record HomeTrackShelfRow(IReadOnlyList<HomeTrackCard> Tracks) : HomeRow;

public sealed record HomeAlbumShelfRow(IReadOnlyList<Album> Albums) : HomeRow;

public sealed record HomePlaylistShelfRow(IReadOnlyList<Playlist> Playlists) : HomeRow;

public static class HomeMixPresentation
{
    public const string NoAttachedHomeServerMessage = "Choose a server in Settings to fill Home.";
    public const string CardSurfaceToken = "SurfaceRaised";
    public const string PrimaryTextToken = "primary";
    public const string SecondaryTextToken = "secondary";
    public const string LikedLeadingFillToken = "Accent";
    public const string LikedLeadingContent = "heart";
    public const string ArtworkLeadingContent = "artwork";

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

    public static HomeMixCardStructure BuildCardStructure(HomeMixTile tile) =>
        new(
            CardSurfaceToken,
            PrimaryTextToken,
            SecondaryTextToken,
            tile.IsLiked ? LikedLeadingFillToken : null,
            tile.IsLiked ? LikedLeadingContent : ArtworkLeadingContent);

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

public sealed record HomeMixCardStructure(
    string CardSurfaceToken,
    string TitleTextToken,
    string SubtitleTextToken,
    string? LeadingFillToken,
    string LeadingContent);

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
        int playlistColumns,
        string? message = null)
    {
        var rows = new List<HomeRow>();
        foreach (var row in MediaDetailFormatting.ChunkRows(mixes, mixColumns))
            rows.Add(new HomeMixGridRow(row));

        if (!string.IsNullOrWhiteSpace(message))
            rows.Add(new HomeMessageRow(message));

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

public static class HomeShelfLoader
{
    public static async Task<IReadOnlyList<T>> LoadAsync<T>(
        string label,
        CoreRequest request,
        Func<CoreRequest, Task<IReadOnlyList<T>?>> load,
        ICollection<string> messages)
    {
        try
        {
            var rows = await load(request);
            if (rows is not null) return rows;
            messages.Add($"Could not load {label}: no data returned.");
        }
        catch (Exception ex)
        {
            messages.Add($"Could not load {label}: {ex.Message}");
        }

        return [];
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
        var attachedServerIds = serverIds
            .Where(id => !string.IsNullOrWhiteSpace(id))
            .Distinct(StringComparer.Ordinal)
            .ToList();
        if (mixes.Count > 0)
        {
            return new HomeMixLoadResult(mixes, liked, Generated: false, Message: null);
        }

        if (attachedServerIds.Count == 0)
        {
            return new HomeMixLoadResult(
                mixes,
                liked,
                Generated: false,
                Message: HomeMixPresentation.NoAttachedHomeServerMessage);
        }

        try
        {
            generationStarted?.Invoke();
            foreach (var serverId in attachedServerIds)
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
