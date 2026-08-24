using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
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
}

public sealed partial class MainViewModel : ViewModelBase, IDisposable
{
    private readonly MozzCore _core = new();
    private CancellationTokenSource? _searchCts;

    [ObservableProperty] private LibrarySection _section = LibrarySection.Home;
    [ObservableProperty] private string _pageTitle = "Home";
    [ObservableProperty] private string? _statusMessage;
    [ObservableProperty] private bool _isBusy;
    [ObservableProperty] private string _searchText = string.Empty;

    [ObservableProperty] private int _artistCount;
    [ObservableProperty] private int _albumCount;
    [ObservableProperty] private int _trackCount;

    [ObservableProperty] private Track? _nowPlaying;
    [ObservableProperty] private bool _isPlaying;

    public ObservableCollection<Track> Tracks { get; } = [];
    public ObservableCollection<Album> Albums { get; } = [];
    public ObservableCollection<Artist> Artists { get; } = [];
    public ObservableCollection<Playlist> Playlists { get; } = [];

    public bool IsHomeSelected => Section == LibrarySection.Home;
    public bool IsSongsSelected => Section == LibrarySection.Songs;
    public bool IsAlbumsSelected => Section == LibrarySection.Albums;
    public bool IsArtistsSelected => Section == LibrarySection.Artists;
    public bool IsPlaylistsSelected => Section == LibrarySection.Playlists;

    public bool ShowTracks => Section is LibrarySection.Songs or LibrarySection.Search;
    public bool ShowAlbums => Section is LibrarySection.Home or LibrarySection.Albums;
    public bool ShowArtists => Section is LibrarySection.Artists;

    /// <summary>Nothing loaded, so the pane shows its empty state.</summary>
    public bool IsLibraryEmpty => TrackCount == 0 && !IsBusy;

    public string LibrarySummary =>
        TrackCount == 0
            ? "No music yet"
            : $"{TrackCount:N0} songs · {AlbumCount:N0} albums · {ArtistCount:N0} artists";

    public MainViewModel()
    {
        // The previewer builds view models with no library present; don't try to
        // open a database from the designer.
        if (Avalonia.Controls.Design.IsDesignMode) return;
        _ = InitializeAsync();
    }

    private async Task InitializeAsync()
    {
        try
        {
            IsBusy = true;
            StatusMessage = "Opening library…";

            var dbPath = DefaultLibraryPath();
            Directory.CreateDirectory(Path.GetDirectoryName(dbPath)!);
            _core.Open(dbPath);

            await RefreshCountsAsync();
            await LoadSectionAsync(LibrarySection.Home);

            StatusMessage = TrackCount > 0
                ? null
                : "No music yet — connect a server to sync your library.";
        }
        catch (Exception ex)
        {
            StatusMessage = $"Could not open the library: {ex.Message}";
        }
        finally
        {
            IsBusy = false;
            RaiseDerived();
        }
    }

    /// <summary>
    /// Where the library lives. `MOZZ_LIBRARY` overrides it, which is how the
    /// app is pointed at a test library without a sync.
    /// </summary>
    public static string DefaultLibraryPath()
    {
        var overridePath = Environment.GetEnvironmentVariable("MOZZ_LIBRARY");
        if (!string.IsNullOrWhiteSpace(overridePath)) return overridePath;

        var baseDir = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return Path.Combine(baseDir, "Mozz", "library.sqlite");
    }

    private async Task RefreshCountsAsync()
    {
        var counts = await _core.CallAsync<LibraryCounts>(new CoreRequest("counts"));
        if (counts is null) return;
        ArtistCount = counts.Artists;
        AlbumCount = counts.Albums;
        TrackCount = counts.Tracks;
        RaiseDerived();
    }

    [RelayCommand]
    private Task SelectSection(LibrarySection section) => LoadSectionAsync(section);

    private async Task LoadSectionAsync(LibrarySection section)
    {
        Section = section;
        PageTitle = section switch
        {
            LibrarySection.Home => "Home",
            LibrarySection.Songs => "Songs",
            LibrarySection.Albums => "Albums",
            LibrarySection.Artists => "Artists",
            LibrarySection.Playlists => "Playlists",
            LibrarySection.Search => "Search",
            _ => "Mozz",
        };
        RaiseDerived();

        if (!_core.IsOpen) return;

        try
        {
            IsBusy = true;
            switch (section)
            {
                case LibrarySection.Home:
                    // Home leads with album art, the way Apple Music and Spotify
                    // both open. A wall of covers reads as a library; a list of
                    // song titles reads as a spreadsheet.
                    await LoadAlbumsAsync();
                    break;
                case LibrarySection.Songs:
                    await LoadTracksAsync();
                    break;
                case LibrarySection.Albums:
                    await LoadAlbumsAsync();
                    break;
                case LibrarySection.Artists:
                    await LoadArtistsAsync();
                    break;
                case LibrarySection.Playlists:
                    Playlists.Clear();
                    break;
            }
        }
        catch (Exception ex)
        {
            StatusMessage = ex.Message;
        }
        finally
        {
            IsBusy = false;
            RaiseDerived();
        }
    }

    private async Task LoadTracksAsync()
    {
        // One page for now. Windowed paging as the list scrolls is next, and the
        // core already takes offset/limit for it.
        var rows = await _core.CallAsync<List<Track>>(
            new CoreRequest("tracks") { Offset = 0, Limit = 500 });
        Replace(Tracks, rows);
    }

    private async Task LoadAlbumsAsync()
    {
        var rows = await _core.CallAsync<List<Album>>(
            new CoreRequest("albums") { Offset = 0, Limit = 500 });
        Replace(Albums, rows);
    }

    private async Task LoadArtistsAsync()
    {
        var rows = await _core.CallAsync<List<Artist>>(
            new CoreRequest("artists") { Offset = 0, Limit = 500 });
        Replace(Artists, rows);
    }

    partial void OnSearchTextChanged(string value) => _ = RunSearchAsync(value);

    /// <summary>
    /// Debounced as-you-type search. Each keystroke supersedes the last: search
    /// is fast, but a burst of typing would still queue queries whose answers
    /// are stale by the time they land.
    /// </summary>
    private async Task RunSearchAsync(string query)
    {
        _searchCts?.Cancel();
        var cts = new CancellationTokenSource();
        _searchCts = cts;

        if (string.IsNullOrWhiteSpace(query))
        {
            if (Section == LibrarySection.Search) await LoadSectionAsync(LibrarySection.Songs);
            return;
        }

        try
        {
            await Task.Delay(140, cts.Token);
            var results = await _core.CallAsync<SearchResults>(
                new CoreRequest("search") { Query = query, Limit = 50 }, cts.Token);
            if (cts.Token.IsCancellationRequested || results is null) return;

            Section = LibrarySection.Search;
            PageTitle = "Search";
            Replace(Tracks, results.Tracks);
            Replace(Albums, results.Albums);
            Replace(Artists, results.Artists);
            RaiseDerived();
        }
        catch (OperationCanceledException)
        {
            // Superseded by a later keystroke; nothing to report.
        }
        catch (Exception ex)
        {
            StatusMessage = ex.Message;
        }
    }

    [RelayCommand]
    private void PlayTrack(Track? track)
    {
        if (track is null) return;
        NowPlaying = track;
        IsPlaying = true;
    }

    [RelayCommand]
    private void TogglePlayPause()
    {
        if (NowPlaying is null) return;
        IsPlaying = !IsPlaying;
    }

    private void RaiseDerived()
    {
        OnPropertyChanged(nameof(IsHomeSelected));
        OnPropertyChanged(nameof(IsSongsSelected));
        OnPropertyChanged(nameof(IsAlbumsSelected));
        OnPropertyChanged(nameof(IsArtistsSelected));
        OnPropertyChanged(nameof(IsPlaylistsSelected));
        OnPropertyChanged(nameof(ShowTracks));
        OnPropertyChanged(nameof(ShowAlbums));
        OnPropertyChanged(nameof(ShowArtists));
        OnPropertyChanged(nameof(IsLibraryEmpty));
        OnPropertyChanged(nameof(LibrarySummary));
    }

    private static void Replace<T>(ObservableCollection<T> target, IReadOnlyList<T>? source)
    {
        target.Clear();
        if (source is null) return;
        foreach (var item in source) target.Add(item);
    }

    public void Dispose() => _core.Dispose();
}
