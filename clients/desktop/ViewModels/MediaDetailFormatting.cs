using Mozz.Desktop.Core;

namespace Mozz.Desktop.ViewModels;

public sealed record AlbumTrackRow(
    Track Track,
    string TrackNumberText,
    bool StartsDisc,
    string? DiscTitle);

public sealed class AlbumReleaseKindLookup(bool unknownIsSingleOrEp, IReadOnlyDictionary<int, bool> byTrackCount)
{
    private readonly int _largestSingleOrEpCount = byTrackCount
        .Where(kv => kv.Value)
        .Select(kv => kv.Key)
        .DefaultIfEmpty(-1)
        .Max();

    public bool IsSingleOrEp(int? trackCount)
    {
        if (trackCount is null) return unknownIsSingleOrEp;
        if (byTrackCount.TryGetValue(trackCount.Value, out var exact)) return exact;
        return trackCount.Value <= _largestSingleOrEpCount;
    }
}

public static class MediaDetailFormatting
{
    public const int ShelfPageSize = 20;

    public static IReadOnlyList<AlbumTrackRow> AlbumTrackRows(IEnumerable<Track> tracks)
    {
        var ordered = OrderAlbumTracks(tracks).ToList();
        var hasMultipleDiscs = ordered
            .Select(t => t.DiscNumber ?? 1)
            .Distinct()
            .Skip(1)
            .Any();

        var rows = new List<AlbumTrackRow>(ordered.Count);
        int? previousDisc = null;
        foreach (var track in ordered)
        {
            var disc = track.DiscNumber ?? 1;
            var startsDisc = hasMultipleDiscs && disc != previousDisc;
            rows.Add(new AlbumTrackRow(
                track,
                track.TrackNumber is > 0 ? track.TrackNumber.Value.ToString() : "—",
                startsDisc,
                startsDisc ? $"Disc {disc}" : null));
            previousDisc = disc;
        }

        return rows;
    }

    public static IEnumerable<Track> OrderAlbumTracks(IEnumerable<Track> tracks) =>
        tracks.OrderBy(t => t.DiscNumber ?? 1)
              .ThenBy(t => t.TrackNumber ?? int.MaxValue)
              .ThenBy(t => t.Title, StringComparer.CurrentCultureIgnoreCase)
              .ThenBy(t => t.Id);

    public static IEnumerable<Track> OrderArtistTracks(IEnumerable<Track> tracks) =>
        tracks.OrderBy(t => t.AlbumTitle ?? string.Empty, StringComparer.CurrentCultureIgnoreCase)
              .ThenBy(t => t.DiscNumber ?? 1)
              .ThenBy(t => t.TrackNumber ?? int.MaxValue)
              .ThenBy(t => t.Title, StringComparer.CurrentCultureIgnoreCase)
              .ThenBy(t => t.Id);

    public static string AlbumMeta(Album album, IReadOnlyCollection<Track> tracks)
    {
        var parts = new List<string>();
        var genre = FirstGenre(album.Genres);
        if (!string.IsNullOrEmpty(genre)) parts.Add(genre);
        if (album.Year is not null) parts.Add(album.Year.Value.ToString());

        var count = tracks.Count > 0 ? tracks.Count : album.TrackCount ?? 0;
        if (count > 0) parts.Add(count == 1 ? "1 song" : $"{count} songs");

        var duration = FormatLongDuration(tracks.Sum(t => t.DurationSeconds));
        if (!string.IsNullOrEmpty(duration)) parts.Add(duration);

        return string.Join(" · ", parts);
    }

    public static string PlaylistMeta(Playlist playlist, IReadOnlyCollection<Track> tracks)
    {
        var count = tracks.Count > 0 ? tracks.Count : playlist.TrackCount ?? 0;
        var parts = new List<string>();
        if (count > 0) parts.Add(count == 1 ? "1 song" : $"{count} songs");
        var duration = FormatLongDuration(tracks.Sum(t => t.DurationSeconds));
        if (!string.IsNullOrEmpty(duration)) parts.Add(duration);
        return string.Join(" · ", parts);
    }

    public static string ArtistMeta(IReadOnlyCollection<Album> albums, IReadOnlyCollection<Track> tracks)
    {
        var parts = new List<string>();
        if (albums.Count > 0) parts.Add(albums.Count == 1 ? "1 album" : $"{albums.Count} albums");
        if (tracks.Count > 0) parts.Add(tracks.Count == 1 ? "1 song" : $"{tracks.Count} songs");
        return string.Join(" · ", parts);
    }

    public static string ArtistMeta(Artist artist, IReadOnlyCollection<Album> albums, IReadOnlyCollection<Track> tracks)
    {
        var parts = new List<string>();
        var genre = FirstGenre(artist.Genres);
        if (!string.IsNullOrWhiteSpace(genre)) parts.Add(genre);
        var albumCount = artist.AlbumCount ?? albums.Count;
        if (albumCount > 0) parts.Add(albumCount == 1 ? "1 album" : $"{albumCount} albums");
        if (tracks.Count > 0) parts.Add(tracks.Count == 1 ? "1 top song" : $"{tracks.Count} top songs");
        return string.Join(" · ", parts);
    }

    public static string FormatLongDuration(double seconds)
    {
        if (seconds <= 0 || double.IsNaN(seconds)) return string.Empty;
        var roundedMinutes = (int)Math.Round(seconds / 60.0, MidpointRounding.AwayFromZero);
        if (roundedMinutes < 60) return $"{roundedMinutes} min";

        var hours = roundedMinutes / 60;
        var minutes = roundedMinutes % 60;
        return minutes == 0 ? $"{hours} hr" : $"{hours} hr {minutes} min";
    }

    public static string TrackAlbumYear(Track track, Album? album = null)
    {
        var albumTitle = track.AlbumTitle;
        var year = album?.Year;
        return (string.IsNullOrWhiteSpace(albumTitle), year) switch
        {
            (false, not null) => $"{albumTitle} · {year}",
            (false, null) => albumTitle!,
            (true, not null) => year.Value.ToString(),
            _ => string.Empty,
        };
    }

    public static IReadOnlyList<Album> MoreByArtist(IEnumerable<Album> albums, Album current) =>
        albums.Where(a => !SameAlbum(a, current))
              .OrderByDescending(a => a.Year ?? int.MinValue)
              .ThenBy(a => a.Title, StringComparer.CurrentCultureIgnoreCase)
              .Take(ShelfPageSize)
              .ToList();

    public static IReadOnlyList<Album> StudioAlbums(IEnumerable<Album> albums, AlbumReleaseKindLookup? releaseKinds = null) =>
        albums.Where(a => !IsSingleOrEpFromCore(a, releaseKinds))
              .OrderByDescending(a => a.Year ?? int.MinValue)
              .ThenBy(a => a.Title, StringComparer.CurrentCultureIgnoreCase)
              .Take(ShelfPageSize)
              .ToList();

    public static IReadOnlyList<Album> SinglesAndEps(IEnumerable<Album> albums, AlbumReleaseKindLookup? releaseKinds = null) =>
        albums.Where(a => IsSingleOrEpFromCore(a, releaseKinds))
              .OrderByDescending(a => a.Year ?? int.MinValue)
              .ThenBy(a => a.Title, StringComparer.CurrentCultureIgnoreCase)
              .Take(ShelfPageSize)
              .ToList();

    public static bool IsSingleOrEpFromCore(Album album, AlbumReleaseKindLookup? releaseKinds = null)
    {
        if (album.IsSingleOrEp is not null) return album.IsSingleOrEp.Value;
        if (!string.IsNullOrWhiteSpace(album.ReleaseKind))
            return album.ReleaseKind.Equals("singleOrEP", StringComparison.OrdinalIgnoreCase);
        return releaseKinds?.IsSingleOrEp(album.TrackCount) ?? false;
    }

    public static IReadOnlyList<IReadOnlyList<T>> ChunkRows<T>(IReadOnlyList<T> items, int columns)
    {
        columns = Math.Max(1, columns);
        var rows = new List<IReadOnlyList<T>>();
        for (var i = 0; i < items.Count; i += columns)
        {
            rows.Add(items.Skip(i).Take(Math.Min(columns, items.Count - i)).ToList());
        }
        return rows;
    }

    private static bool SameAlbum(Album a, Album b)
    {
        if (!string.IsNullOrWhiteSpace(a.RemoteId) && !string.IsNullOrWhiteSpace(b.RemoteId))
        {
            return a.ServerId == b.ServerId && a.RemoteId == b.RemoteId;
        }

        if (!string.IsNullOrWhiteSpace(a.GroupKey) && !string.IsNullOrWhiteSpace(b.GroupKey))
        {
            return a.GroupKey == b.GroupKey;
        }

        return a.Id != 0 && a.Id == b.Id;
    }

    private static string? FirstGenre(IReadOnlyList<string>? genres) =>
        genres?.FirstOrDefault(g => !string.IsNullOrWhiteSpace(g));
}
