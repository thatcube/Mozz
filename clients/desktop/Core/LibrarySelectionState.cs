namespace Mozz.Desktop.Core;

public sealed record MusicLibrarySelectionOption(string Id, string Name, bool IsSelected);

public static class LibrarySelectionState
{
    public static IReadOnlyList<MusicLibrarySelectionOption> Build(
        IReadOnlyList<MusicLibrary> libraries,
        string? selectedLibraryId)
    {
        if (libraries.Count == 0) return [];
        var selected = string.IsNullOrWhiteSpace(selectedLibraryId)
            ? libraries[0].Id
            : selectedLibraryId;
        return libraries
            .Select(library => new MusicLibrarySelectionOption(
                library.Id,
                library.Name,
                string.Equals(library.Id, selected, StringComparison.Ordinal)))
            .ToList();
    }

    public static string? Apply(
        IReadOnlyList<MusicLibrarySelectionOption> options,
        string requestedId)
    {
        if (string.IsNullOrWhiteSpace(requestedId)) return null;
        return options.Any(option => string.Equals(option.Id, requestedId, StringComparison.Ordinal))
            ? requestedId
            : null;
    }
}
