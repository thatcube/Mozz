using Mozz.Desktop.Core;

namespace Mozz.Desktop.ViewModels;

public abstract record SearchRow;
public sealed record SearchHeaderRow(string Title, int Count) : SearchRow;
public sealed record SearchTrackRow(Track Track) : SearchRow;
public sealed record SearchAlbumRow(Album Album) : SearchRow;
public sealed record SearchArtistRow(Artist Artist) : SearchRow;
public sealed record SearchPlaylistRow(Playlist Playlist) : SearchRow;
public sealed record SearchEmptyRow(string Message) : SearchRow;

public static class SearchPresentation
{
    public static IReadOnlyList<SearchRow> Build(SearchResults? results, IReadOnlyList<Playlist>? playlists, string query)
    {
        var rows = new List<SearchRow>();
        var trimmed = query.Trim();
        if (string.IsNullOrWhiteSpace(trimmed)) return rows;

        Add(rows, "Songs", results?.Tracks, t => new SearchTrackRow(t));
        Add(rows, "Albums", results?.Albums, a => new SearchAlbumRow(a));
        Add(rows, "Artists", results?.Artists, a => new SearchArtistRow(a));
        Add(rows, "Playlists", MatchingPlaylists(playlists, trimmed), p => new SearchPlaylistRow(p));

        if (rows.Count == 0) rows.Add(new SearchEmptyRow($"No results for “{trimmed}”."));
        return rows;
    }

    private static void Add<T>(List<SearchRow> rows, string title, IReadOnlyList<T>? items, Func<T, SearchRow> project)
    {
        if (items is not { Count: > 0 }) return;
        rows.Add(new SearchHeaderRow(title, items.Count));
        rows.AddRange(items.Select(project));
    }

    private static IReadOnlyList<Playlist> MatchingPlaylists(IReadOnlyList<Playlist>? playlists, string query)
    {
        if (playlists is not { Count: > 0 }) return [];
        return playlists
            .Where(p => p.Title.Contains(query, StringComparison.CurrentCultureIgnoreCase))
            .Take(20)
            .ToList();
    }
}

public sealed class SearchDebouncePlanner(TimeSpan delay)
{
    public TimeSpan Delay { get; } = delay;

    public string? ReadyQuery(IEnumerable<(TimeSpan At, string Query)> inputs, TimeSpan now)
    {
        string? latest = null;
        TimeSpan latestAt = TimeSpan.Zero;
        foreach (var (at, query) in inputs)
        {
            if (at > now) continue;
            latest = query;
            latestAt = at;
        }

        if (latest is null || now - latestAt < Delay) return null;
        return string.IsNullOrWhiteSpace(latest) ? string.Empty : latest.Trim();
    }
}

public static class SearchTiming
{
    public static readonly TimeSpan DebounceDelay = TimeSpan.FromMilliseconds(140);
}
