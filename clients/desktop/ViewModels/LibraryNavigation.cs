using Mozz.Desktop.Core;

namespace Mozz.Desktop.ViewModels;

/// <summary>Which pane the sidebar is showing.</summary>
public enum LibrarySection
{
    Home,
    Songs,
    Albums,
    Artists,
    Playlists,
    Search,
    Connect,
}

public enum LibraryPageKind
{
    Section,
    AlbumDetail,
    ArtistDetail,
    MixDetail,
}

public sealed record LibraryPage(
    LibraryPageKind Kind,
    LibrarySection? Section = null,
    Album? Album = null,
    Artist? Artist = null,
    string? MixId = null,
    string? Title = null)
{
    public static LibraryPage ForSection(LibrarySection section) =>
        new(LibraryPageKind.Section, Section: section);

    public static LibraryPage ForAlbum(Album album) =>
        new(LibraryPageKind.AlbumDetail, Album: album, Title: album.Title);

    public static LibraryPage ForArtist(Artist artist) =>
        new(LibraryPageKind.ArtistDetail, Artist: artist, Title: artist.Name);

    public static LibraryPage ForMix(string id, string title) =>
        new(LibraryPageKind.MixDetail, MixId: id, Title: title);
}

public sealed class NavigationStack<T>(T initial)
{
    private readonly List<T> _back = [];

    public T Current { get; private set; } = initial;
    public IReadOnlyList<T> BackStack => _back;
    public bool CanGoBack => _back.Count > 0;

    public void Push(T page)
    {
        _back.Add(Current);
        Current = page;
    }

    public void Replace(T page, bool clearBackStack = true)
    {
        Current = page;
        if (clearBackStack) _back.Clear();
    }

    public bool TryPop(out T page)
    {
        if (_back.Count == 0)
        {
            page = Current;
            return false;
        }

        page = _back[^1];
        _back.RemoveAt(_back.Count - 1);
        Current = page;
        return true;
    }
}
