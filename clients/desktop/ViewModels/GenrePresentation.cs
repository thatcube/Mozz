using Mozz.Desktop.Core;

namespace Mozz.Desktop.ViewModels;

public sealed record GenreTile(string Name)
{
    public string FallbackText => Name.Length == 0 ? "Genre" : Name;
}

public static class GenrePresentation
{
    public static IReadOnlyList<GenreTile> Build(IEnumerable<string>? genres) => (genres ?? [])
        .Select(g => g.Trim())
        .Where(g => !string.IsNullOrWhiteSpace(g))
        .Distinct(StringComparer.CurrentCultureIgnoreCase)
        .OrderBy(g => g, StringComparer.CurrentCultureIgnoreCase)
        .Select(g => new GenreTile(g))
        .ToList();

    public static string Metadata(string genre, IReadOnlyList<Album> albums) =>
        albums.Count == 0 ? genre : $"{albums.Count:N0} album{(albums.Count == 1 ? string.Empty : "s")}";
}
