using System.Collections.ObjectModel;
using System.Diagnostics;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Mozz.Desktop.Audio;
using Mozz.Desktop.Audio.Platform;
using Mozz.Desktop.Core;

namespace Mozz.Desktop.ViewModels;

public sealed partial class MainViewModel : ViewModelBase, IDisposable
{
    private readonly MozzCore _core = new();
    private readonly ArtworkService? _artwork;
    private CancellationTokenSource? _searchCts;
    private readonly NavigationStack<LibraryPage> _navigation =
        new(LibraryPage.ForSection(LibrarySection.Home));

    /// Sign-in and sync. Its own view model because it is its own job — see the
    /// note on the type.
    public ConnectViewModel Connect { get; }

    // Playback engine. Null in the designer (we never open an audio device there).
    private readonly IAudioEngine? _engine;
    private readonly INowPlayingIntegration? _nowPlaying_os;
    private readonly DispatcherTimer? _positionTimer;
    private readonly DispatcherTimer? _seekDebounce;
    // The queue is app logic — the engine only ever knows "current" and "next".
    private readonly List<Track> _queue = [];
    private int _queueIndex = -1;
    private bool _suppressSeek;
    private double _pendingSeek;
    private long _lastUserSeekTicks;

    [ObservableProperty] private LibrarySection _section = LibrarySection.Home;
    [ObservableProperty] private string _pageTitle = "Home";
    [ObservableProperty] private string? _statusMessage;
    [ObservableProperty] private bool _isBusy;
    [ObservableProperty] private string _searchText = string.Empty;
    [ObservableProperty] private Album? _selectedAlbum;
    [ObservableProperty] private Artist? _selectedArtist;
    [ObservableProperty] private Playlist? _selectedPlaylist;
    [ObservableProperty] private string? _detailMeta;

    [ObservableProperty] private int _artistCount;
    [ObservableProperty] private int _albumCount;
    [ObservableProperty] private int _trackCount;

    [ObservableProperty] private Track? _nowPlaying;
    [ObservableProperty] private bool _isPlaying;

    // Transport surface bound by the player bar.
    [ObservableProperty] private double _positionSeconds;
    [ObservableProperty] private double _durationSeconds;
    [ObservableProperty] private double _volume = 0.85;

    /// <summary>Left counter in the player bar (m:ss of the play head).</summary>
    public string PositionText => FormatClock(PositionSeconds);

    /// <summary>Right counter in the player bar (m:ss of the track length).</summary>
    public string DurationText => FormatClock(DurationSeconds);

    /// <summary>The play button glyph flips with transport state.</summary>
    public string PlayPauseGlyph => IsPlaying ? "\u23F8" : "\u23F5";

    public ObservableCollection<Track> Tracks { get; } = [];
    public ObservableCollection<Album> Albums { get; } = [];
    public ObservableCollection<Artist> Artists { get; } = [];
    public ObservableCollection<Playlist> Playlists { get; } = [];
    public ObservableCollection<AlbumTrackRow> AlbumTrackRows { get; } = [];
    public ObservableCollection<Album> ArtistAlbums { get; } = [];
    public ObservableCollection<Track> ArtistTracks { get; } = [];
    public ObservableCollection<Track> PlaylistTracks { get; } = [];
    public ObservableCollection<DetailRow> DetailRows { get; } = [];

    /// The album and artist walls, chunked into rows so a VirtualizingStackPanel
    /// can own them — see GridRows for why that indirection exists.
    public GridRows<Album> AlbumGrid { get; } = new();
    public GridRows<Artist> ArtistGrid { get; } = new();
    public GridRows<Album> ArtistAlbumGrid { get; } = new();
    public GridRows<Playlist> PlaylistGrid { get; } = new();

    /// Width available to the content pane, set by the view on layout. Drives
    /// how many tiles fit across.
    public double ContentWidth
    {
        get => _contentWidth;
        set
        {
            if (Math.Abs(value - _contentWidth) < 1) return;
            _contentWidth = value;
            AlbumGrid.SetColumns(ColumnsFor(AlbumTilePitch));
            ArtistGrid.SetColumns(ColumnsFor(ArtistTilePitch));
            ArtistAlbumGrid.SetColumns(ColumnsFor(AlbumTilePitch));
            PlaylistGrid.SetColumns(ColumnsFor(PlaylistTilePitch));
            RebuildDetailRows();
        }
    }

    private double _contentWidth;

    // Tile width plus its right margin, matching the templates.
    private const double AlbumTilePitch = 196;
    private const double ArtistTilePitch = 178;
    private const double PlaylistTilePitch = 236;
    private const double TopSongPitch = 360;

    private List<AlbumTrackRow> _detailAlbumTracks = [];
    private List<Album> _detailMoreByAlbums = [];
    private List<Album> _detailArtistAlbums = [];
    private List<Album> _detailArtistSingles = [];
    private List<Album> _detailArtistAppearsOn = [];
    private List<Track> _detailArtistTopTracks = [];
    private Album? _detailLatestRelease;
    private List<Track> _detailPlaylistTracks = [];

    private int ColumnsFor(double pitch) => Math.Max(1, (int)(_contentWidth / pitch));

    public bool CanGoBack => _navigation.CanGoBack;
    public bool IsHomeSelected => Section == LibrarySection.Home;
    public bool IsSongsSelected => Section == LibrarySection.Songs;
    public bool IsAlbumsSelected => Section == LibrarySection.Albums;
    public bool IsArtistsSelected => Section == LibrarySection.Artists;
    public bool IsPlaylistsSelected => Section == LibrarySection.Playlists;
    public bool IsConnectSelected => Section == LibrarySection.Connect;

    public bool ShowTracks => _navigation.Current is { Kind: LibraryPageKind.Section, Section: LibrarySection.Songs };
    public bool ShowAlbums => _navigation.Current is { Kind: LibraryPageKind.Section, Section: LibrarySection.Home or LibrarySection.Albums };
    public bool ShowArtists => _navigation.Current is { Kind: LibraryPageKind.Section, Section: LibrarySection.Artists };
    public bool ShowPlaylists => _navigation.Current is { Kind: LibraryPageKind.Section, Section: LibrarySection.Playlists };
    public bool ShowSearch => _navigation.Current is { Kind: LibraryPageKind.Section, Section: LibrarySection.Search };
    public bool ShowConnect => _navigation.Current is { Kind: LibraryPageKind.Section, Section: LibrarySection.Connect };
    public bool ShowAlbumDetail => _navigation.Current.Kind == LibraryPageKind.AlbumDetail;
    public bool ShowArtistDetail => _navigation.Current.Kind == LibraryPageKind.ArtistDetail;
    public bool ShowPlaylistDetail => _navigation.Current.Kind == LibraryPageKind.PlaylistDetail;
    public bool ShowDetailPage => ShowAlbumDetail || ShowArtistDetail || ShowPlaylistDetail;
    public bool HasSearchAlbums => ShowSearch && Albums.Count > 0;
    public bool HasSearchArtists => ShowSearch && Artists.Count > 0;
    public bool HasSearchTracks => ShowSearch && Tracks.Count > 0;
    public bool HasArtistAlbums => ArtistAlbums.Count > 0;

    /// <summary>
    /// Nothing loaded, so the pane shows its empty state — but never on the
    /// Servers pane, which is where someone goes precisely because the library
    /// is empty and would otherwise be told so on top of the sign-in form.
    /// </summary>
    public bool IsLibraryEmpty => TrackCount == 0 && !IsBusy && ShowConnect == false
                                  && ShowDetailPage == false;

    public string LibrarySummary =>
        TrackCount == 0
            ? "No music yet"
            : $"{TrackCount:N0} songs · {AlbumCount:N0} albums · {ArtistCount:N0} artists";

    public MainViewModel()
    {
        // Constructed before the design-mode bail-out because the previewer binds
        // to it. Nothing here touches the disk or the network until a command runs.
        var server = new MozzServer(_core, SecretStore.ForCurrentPlatform());
        Connect = new ConnectViewModel(server, onLibraryChanged: ReloadAfterSyncAsync);

        // The previewer builds view models with no library present; don't try to
        // open a database from the designer.
        if (Avalonia.Controls.Design.IsDesignMode) return;

        // Publish the artwork pipeline the tiles draw from. It shares this one
        // server, so covers resolve against the same attached backends playback
        // does, and it is ambient because the tiles are made by data templates and
        // have no constructor to hand it to.
        _artwork = ArtworkService.Install(server);

        _engine = new MiniAudioEngine { Volume = Volume };
        // Track gain rather than album: Mozz plays across a whole library far
        // more than it plays an album end to end, and album mode deliberately
        // preserves the loudness relationship *within* a record — which is the
        // wrong choice when the next song is from somewhere else entirely.
        //
        // No pre-amp. ReplayGain figures are almost always negative (they
        // attenuate to a reference level), so adding headroom back invites the
        // clipping the standard exists to avoid.
        _engine.SetReplayGain(ReplayGainMode.Track);
        _engine.TrackChanged += OnEngineTrackChanged;
        _engine.PlaybackEnded += OnEnginePlaybackEnded;
        _engine.Error += OnEngineError;

        _nowPlaying_os = NowPlayingIntegration.Create();
        _nowPlaying_os.PlayPauseRequested += (_, _) => Dispatcher.UIThread.Post(TogglePlayPause);
        _nowPlaying_os.NextRequested += (_, _) => Dispatcher.UIThread.Post(() => _ = NextAsync());
        _nowPlaying_os.PreviousRequested += (_, _) => Dispatcher.UIThread.Post(() => _ = PreviousAsync());
        _nowPlaying_os.StopRequested += (_, _) => Dispatcher.UIThread.Post(StopPlayback);

        // ~10 Hz is enough for a smooth progress bar and costs almost nothing.
        _positionTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(100) };
        _positionTimer.Tick += OnPositionTick;
        _positionTimer.Start();

        // A one-shot debounce so dragging the scrubber issues one seek, not fifty.
        _seekDebounce = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(140) };
        _seekDebounce.Tick += OnSeekDebounceTick;

        _ = InitializeAsync();
    }

    /// Called when a sync finishes: the counts and whatever page is showing are
    /// both stale, and the empty-library message may no longer be true.
    private async Task ReloadAfterSyncAsync()
    {
        await RefreshCountsAsync();
        await LoadSectionAsync(Section == LibrarySection.Connect ? LibrarySection.Home : Section, clearBackStack: true);
        StatusMessage = TrackCount > 0 ? null : StatusMessage;
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

            // Before anything can be played: the tracks come from the local
            // database, but their stream URLs come from an attached backend.
            await Connect.AttachSavedAccountsAsync();

            await RefreshCountsAsync();
            await LoadSectionAsync(LibrarySection.Home, clearBackStack: true);

            StatusMessage = TrackCount > 0
                ? null
                : "No music yet — connect a server to sync your library.";

            await MaybeDemoAutoplayAsync();
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

    /// <summary>
    /// Verification-only convenience. When <c>MOZZ_DEMO_AUTOPLAY</c> is set, jump to
    /// Songs and start the first track so the playback pipeline can be exercised
    /// (and screenshotted) without a pointer. A no-op unless the variable is set.
    /// </summary>
    private async Task MaybeDemoAutoplayAsync()
    {
        if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("MOZZ_DEMO_AUTOPLAY"))) return;
        await LoadSectionAsync(LibrarySection.Songs, clearBackStack: true);
        if (Tracks.Count > 0) PlayTrack(Tracks[0]);
    }

    [RelayCommand]
    private Task SelectSection(LibrarySection section) => LoadSectionAsync(section, clearBackStack: true);

    private async Task LoadSectionAsync(LibrarySection section, bool clearBackStack)
    {
        _navigation.Replace(LibraryPage.ForSection(section), clearBackStack);
        Section = section;
        _pagingGeneration++;
        _nextCursor = null;
        SelectedAlbum = null;
        SelectedArtist = null;
        SelectedPlaylist = null;
        DetailMeta = null;
        ClearDetailState();
        PageTitle = section switch
        {
            LibrarySection.Home => "Home",
            LibrarySection.Songs => "Songs",
            LibrarySection.Albums => "Albums",
            LibrarySection.Artists => "Artists",
            LibrarySection.Playlists => "Playlists",
            LibrarySection.Search => "Search",
            LibrarySection.Connect => "Servers",
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
                    await LoadPlaylistsAsync();
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

    // MARK: Paging
    //
    // A real self-hosted library is not a few hundred rows. Mozz's own benchmark
    // library is 100,000 tracks, 12,500 albums and 4,000 artists, and until this
    // existed the app loaded exactly the first 500 of each and offered no way to
    // reach anything after that — 99.5% of the library was simply unreachable,
    // silently, with no scrollbar hint that anything was missing.
    //
    // Pages are appended as the list nears its end. The page is smaller than the
    // old fixed cap on purpose: the first screenful should arrive quickly, and
    // after that the reader is always further from the end than one page.

    private const int PageSize = 200;

    /// Where to resume the current section's listing. Null means the end has
    /// been reached — the core does not report a total, and counting rows would
    /// be wrong the moment a background sync added one.
    private string? _nextCursor;
    private bool _isLoadingMore;
    /// Bumped on every section change so a page still in flight from the
    /// previous section cannot append its rows to the new one.
    private int _pagingGeneration;

    private async Task LoadTracksAsync()
    {
        var page = await _core.CallPageAsync<List<Track>>(
            new CoreRequest("tracks") { Limit = PageSize });
        Replace(Tracks, page.Rows);
        _nextCursor = page.NextCursor;
    }

    private async Task LoadAlbumsAsync()
    {
        var page = await _core.CallPageAsync<List<Album>>(
            new CoreRequest("albums") { Limit = PageSize });
        Replace(Albums, page.Rows);
        AlbumGrid.Reset(page.Rows);
        _nextCursor = page.NextCursor;
    }

    private async Task LoadArtistsAsync()
    {
        var page = await _core.CallPageAsync<List<Artist>>(
            new CoreRequest("artists") { Limit = PageSize });
        Replace(Artists, page.Rows);
        ArtistGrid.Reset(page.Rows);
        _nextCursor = page.NextCursor;
    }

    private async Task LoadPlaylistsAsync()
    {
        var page = await _core.CallPageAsync<List<Playlist>>(
            new CoreRequest("playlists") { Limit = PageSize });
        Replace(Playlists, page.Rows);
        PlaylistGrid.Reset(page.Rows);
        _nextCursor = page.NextCursor;
    }

    /// <summary>
    /// Append the next page. Called by the view when the scroll position nears
    /// the end of the list; safe to call spuriously.
    /// </summary>
    public async Task LoadMoreAsync()
    {
        // Search results are a single ranked set, not a pageable listing —
        // scrolling one must not start appending the whole library to it.
        if (_nextCursor is null || _isLoadingMore || !_core.IsOpen) return;
        if (Section is LibrarySection.Search or LibrarySection.Connect) return;

        _isLoadingMore = true;
        try
        {
            switch (Section)
            {
                case LibrarySection.Songs when _navigation.Current.Kind == LibraryPageKind.Section:
                    await AppendAsync(Tracks, "tracks");
                    break;
                case LibrarySection.Home or LibrarySection.Albums when _navigation.Current.Kind == LibraryPageKind.Section:
                    await AppendAsync(Albums, "albums");
                    break;
                case LibrarySection.Artists when _navigation.Current.Kind == LibraryPageKind.Section:
                    await AppendAsync(Artists, "artists");
                    break;
                case LibrarySection.Playlists when _navigation.Current.Kind == LibraryPageKind.Section:
                    await AppendAsync(Playlists, "playlists");
                    break;
                case LibrarySection.Playlists when _navigation.Current.Kind == LibraryPageKind.PlaylistDetail:
                    await AppendPlaylistTracksAsync();
                    break;
            }
        }
        catch (Exception ex)
        {
            // A failed page must not poison the list that is already showing.
            StatusMessage = ex.Message;
            _nextCursor = null;
        }
        finally
        {
            _isLoadingMore = false;
        }
    }

    private async Task AppendAsync<T>(ObservableCollection<T> target, string cmd)
    {
        var generation = _pagingGeneration;
        var page = await _core.CallPageAsync<List<T>>(
            new CoreRequest(cmd) { Limit = PageSize, Cursor = _nextCursor });

        // A section switch while this was in flight would otherwise append one
        // section's rows to another's collection.
        if (generation != _pagingGeneration) return;

        if (page.Rows is { Count: > 0 })
        {
            foreach (var row in page.Rows) target.Add(row);
            // Keep the chunked view in step without rebuilding it — see GridRows.
            if (page.Rows is List<Album> albums) AlbumGrid.Append(albums);
            else if (page.Rows is List<Artist> artists) ArtistGrid.Append(artists);
            else if (page.Rows is List<Playlist> playlists) PlaylistGrid.Append(playlists);
        }
        _nextCursor = page.NextCursor;
        RaiseDerived();
    }

    [RelayCommand]
    private async Task GoBack()
    {
        if (!_navigation.TryPop(out var page)) return;
        await ApplyPageAsync(page, reload: page.Kind != LibraryPageKind.Section);
    }

    [RelayCommand]
    private async Task OpenAlbum(Album? album)
    {
        if (album is null) return;
        _navigation.Push(LibraryPage.ForAlbum(album));
        await ApplyPageAsync(_navigation.Current, reload: true);
    }

    [RelayCommand]
    private async Task OpenArtist(Artist? artist)
    {
        if (artist is null) return;
        _navigation.Push(LibraryPage.ForArtist(artist));
        await ApplyPageAsync(_navigation.Current, reload: true);
    }

    [RelayCommand]
    private async Task OpenPlaylist(Playlist? playlist)
    {
        if (playlist is null) return;
        _navigation.Push(LibraryPage.ForPlaylist(playlist));
        await ApplyPageAsync(_navigation.Current, reload: true);
    }

    [RelayCommand]
    private Task OpenTrackAlbum(Track? track)
    {
        if (track is null || string.IsNullOrWhiteSpace(track.AlbumRemoteId)) return Task.CompletedTask;
        var album = new Album(
            Id: 0,
            RemoteId: track.AlbumRemoteId,
            ServerId: track.ServerId,
            Title: string.IsNullOrWhiteSpace(track.AlbumTitle) ? "Album" : track.AlbumTitle,
            ArtistName: track.ArtistName,
            ArtistRemoteId: null,
            Year: null,
            TrackCount: null,
            ArtworkKey: track.ArtworkKey,
            GroupKey: string.Empty);
        return OpenAlbum(album);
    }

    [RelayCommand]
    private Task OpenTrackArtist(Track? track)
    {
        if (track is null || string.IsNullOrWhiteSpace(track.ArtistName)) return Task.CompletedTask;
        var artist = new Artist(0, string.Empty, track.ServerId, track.ArtistName, null);
        return OpenArtist(artist);
    }

    [RelayCommand]
    private Task OpenSelectedAlbumArtist()
    {
        if (SelectedAlbum is null || string.IsNullOrWhiteSpace(SelectedAlbum.ArtistRemoteId))
            return Task.CompletedTask;

        var artist = new Artist(
            0,
            SelectedAlbum.ArtistRemoteId,
            SelectedAlbum.ServerId,
            SelectedAlbum.ArtistName,
            null);
        return OpenArtist(artist);
    }

    private async Task ApplyPageAsync(LibraryPage page, bool reload)
    {
        _pagingGeneration++;
        _nextCursor = null;
        StatusMessage = null;

        switch (page.Kind)
        {
            case LibraryPageKind.Section:
                await LoadSectionAsync(page.Section ?? LibrarySection.Home, clearBackStack: false);
                return;
            case LibraryPageKind.AlbumDetail:
                Section = LibrarySection.Albums;
                SelectedAlbum = page.Album;
                SelectedArtist = null;
                SelectedPlaylist = null;
                PageTitle = "Album";
                if (reload && page.Album is not null) await LoadAlbumDetailAsync(page.Album);
                break;
            case LibraryPageKind.ArtistDetail:
                Section = LibrarySection.Artists;
                SelectedArtist = page.Artist;
                SelectedAlbum = null;
                SelectedPlaylist = null;
                PageTitle = "Artist";
                if (reload && page.Artist is not null) await LoadArtistDetailAsync(page.Artist);
                break;
            case LibraryPageKind.PlaylistDetail:
                Section = LibrarySection.Playlists;
                SelectedPlaylist = page.Playlist;
                SelectedAlbum = null;
                SelectedArtist = null;
                PageTitle = "Playlist";
                if (reload && page.Playlist is not null) await LoadPlaylistDetailAsync(page.Playlist);
                break;
            case LibraryPageKind.MixDetail:
                PageTitle = page.Title ?? "Mix";
                break;
        }

        RaiseDerived();
    }

    private async Task LoadAlbumDetailAsync(Album album)
    {
        AlbumTrackRows.Clear();
        _detailAlbumTracks = [];
        _detailMoreByAlbums = [];
        DetailMeta = MediaDetailFormatting.AlbumMeta(album, []);
        RebuildDetailRows();
        RaiseDerived();

        if (!_core.IsOpen) return;

        try
        {
            IsBusy = true;
            album = await ResolveAlbumAsync(album);
            SelectedAlbum = album;
            var request = new CoreRequest("albumTracks")
            {
                ServerId = album.ServerId,
                RemoteId = string.IsNullOrWhiteSpace(album.RemoteId) ? null : album.RemoteId,
                GroupKey = string.IsNullOrWhiteSpace(album.GroupKey) ? null : album.GroupKey,
            };
            var tracks = await _core.CallAsync<List<Track>>(request) ?? [];
            _detailAlbumTracks = MediaDetailFormatting.AlbumTrackRows(tracks).ToList();
            Replace(AlbumTrackRows, _detailAlbumTracks);
            DetailMeta = MediaDetailFormatting.AlbumMeta(album, _detailAlbumTracks.Select(r => r.Track).ToList());

            if (!string.IsNullOrWhiteSpace(album.ArtistRemoteId))
            {
                var more = await LoadAlbumsForArtistAsync(
                    new Artist(0, album.ArtistRemoteId, album.ServerId, album.ArtistName, null));
                _detailMoreByAlbums = MediaDetailFormatting.MoreByArtist(more, album).ToList();
            }

            RebuildDetailRows();
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

    private async Task LoadArtistDetailAsync(Artist artist)
    {
        ArtistAlbums.Clear();
        ArtistAlbumGrid.Reset([]);
        ArtistTracks.Clear();
        _detailArtistAlbums = [];
        _detailArtistSingles = [];
        _detailArtistAppearsOn = [];
        _detailArtistTopTracks = [];
        _detailLatestRelease = null;
        DetailMeta = null;
        RebuildDetailRows();
        RaiseDerived();

        if (!_core.IsOpen) return;

        try
        {
            IsBusy = true;
            artist = await ResolveArtistAsync(artist);
            SelectedArtist = artist;

            var albums = await LoadAlbumsForArtistAsync(artist, MediaDetailFormatting.ShelfPageSize);
            _detailLatestRelease = MediaDetailFormatting.LatestRelease(albums);
            _detailArtistAlbums = MediaDetailFormatting.StudioAlbums(albums).ToList();
            _detailArtistSingles = MediaDetailFormatting.SinglesAndEps(albums).ToList();
            Replace(ArtistAlbums, _detailArtistAlbums);
            ArtistAlbumGrid.Reset(_detailArtistAlbums);

            _detailArtistTopTracks = await LoadArtistTopTracksAsync(artist);
            Replace(ArtistTracks, _detailArtistTopTracks);
            _detailArtistAppearsOn = await LoadAppearsOnAsync(artist);
            DetailMeta = MediaDetailFormatting.ArtistMeta(artist, albums, _detailArtistTopTracks);
            RebuildDetailRows();
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

    private async Task<Artist> ResolveArtistAsync(Artist artist)
    {
        if (!string.IsNullOrWhiteSpace(artist.RemoteId))
        {
            try
            {
                return await _core.CallAsync<Artist>(new CoreRequest("artist")
                {
                    ServerId = artist.ServerId,
                    RemoteId = artist.RemoteId,
                }) ?? artist;
            }
            catch (MozzCoreException)
            {
                return artist;
            }
        }

        var results = await _core.CallAsync<SearchResults>(
            new CoreRequest("search") { Query = artist.Name, Limit = 50 });
        return results?.Artists.FirstOrDefault(a =>
            string.Equals(a.Name, artist.Name, StringComparison.CurrentCultureIgnoreCase)
            && a.ServerId == artist.ServerId) ?? artist;
    }

    private async Task<Album> ResolveAlbumAsync(Album album)
    {
        if (string.IsNullOrWhiteSpace(album.RemoteId)) return album;

        try
        {
            return await _core.CallAsync<Album>(new CoreRequest("album")
            {
                ServerId = album.ServerId,
                RemoteId = album.RemoteId,
            }) ?? album;
        }
        catch (MozzCoreException)
        {
            return album;
        }
    }

    private async Task<List<Album>> LoadAlbumsForArtistAsync(Artist artist, int limit = PageSize)
    {
        if (!string.IsNullOrWhiteSpace(artist.RemoteId))
        {
            var page = await _core.CallPageAsync<List<Album>>(new CoreRequest("artistAlbums")
            {
                ServerId = artist.ServerId,
                RemoteId = artist.RemoteId,
                Limit = limit,
            });
            return page.Rows ?? [];
        }

        var results = await _core.CallAsync<SearchResults>(
            new CoreRequest("search") { Query = artist.Name, Limit = 50 });
        return results?.Albums
            .Where(a => string.Equals(a.ArtistName, artist.Name, StringComparison.CurrentCultureIgnoreCase))
            .Take(limit)
            .ToList() ?? [];
    }

    private async Task LoadPlaylistDetailAsync(Playlist playlist)
    {
        _detailPlaylistTracks = [];
        PlaylistTracks.Clear();
        DetailMeta = MediaDetailFormatting.PlaylistMeta(playlist, []);
        RebuildDetailRows();
        RaiseDerived();

        if (!_core.IsOpen) return;

        try
        {
            IsBusy = true;
            var page = await _core.CallPageAsync<List<Track>>(new CoreRequest("playlistTracks")
            {
                ServerId = playlist.ServerId,
                RemoteId = playlist.RemoteId,
                Limit = PageSize,
            });
            _detailPlaylistTracks = page.Rows ?? [];
            Replace(PlaylistTracks, _detailPlaylistTracks);
            _nextCursor = page.NextCursor;
            DetailMeta = MediaDetailFormatting.PlaylistMeta(playlist, _detailPlaylistTracks);
            RebuildDetailRows();
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

    private async Task AppendPlaylistTracksAsync()
    {
        if (SelectedPlaylist is null || _nextCursor is null) return;

        var generation = _pagingGeneration;
        var page = await _core.CallPageAsync<List<Track>>(new CoreRequest("playlistTracks")
        {
            ServerId = SelectedPlaylist.ServerId,
            RemoteId = SelectedPlaylist.RemoteId,
            Limit = PageSize,
            Cursor = _nextCursor,
        });

        if (generation != _pagingGeneration) return;
        if (page.Rows is { Count: > 0 })
        {
            _detailPlaylistTracks.AddRange(page.Rows);
            foreach (var track in page.Rows) PlaylistTracks.Add(track);
            DetailMeta = MediaDetailFormatting.PlaylistMeta(SelectedPlaylist, _detailPlaylistTracks);
            RebuildDetailRows();
        }
        _nextCursor = page.NextCursor;
    }

    private async Task<List<Track>> LoadArtistTopTracksAsync(Artist artist)
    {
        if (string.IsNullOrWhiteSpace(artist.RemoteId)) return [];
        try
        {
            return await _core.CallAsync<List<Track>>(new CoreRequest("artistTopTracks")
            {
                ServerId = artist.ServerId,
                ArtistRemoteId = artist.RemoteId,
                Limit = 10,
            }) ?? [];
        }
        catch (MozzCoreException)
        {
            return [];
        }
    }

    private async Task<List<Album>> LoadAppearsOnAsync(Artist artist)
    {
        if (string.IsNullOrWhiteSpace(artist.RemoteId)) return [];
        try
        {
            var page = await _core.CallPageAsync<List<Album>>(new CoreRequest("artistAppearsOn")
            {
                ServerId = artist.ServerId,
                ArtistRemoteId = artist.RemoteId,
                Limit = MediaDetailFormatting.ShelfPageSize,
            });
            return page.Rows ?? [];
        }
        catch (MozzCoreException)
        {
            return [];
        }
    }

    private void ClearDetailState()
    {
        DetailRows.Clear();
        AlbumTrackRows.Clear();
        ArtistAlbums.Clear();
        ArtistTracks.Clear();
        PlaylistTracks.Clear();
        _detailAlbumTracks = [];
        _detailMoreByAlbums = [];
        _detailArtistAlbums = [];
        _detailArtistSingles = [];
        _detailArtistAppearsOn = [];
        _detailArtistTopTracks = [];
        _detailLatestRelease = null;
        _detailPlaylistTracks = [];
    }

    private void RebuildDetailRows()
    {
        if (!ShowDetailPage)
        {
            DetailRows.Clear();
            return;
        }

        var rows = new List<DetailRow>();
        switch (_navigation.Current.Kind)
        {
            case LibraryPageKind.AlbumDetail when SelectedAlbum is not null:
                rows.Add(new AlbumHeroRow(SelectedAlbum, DetailMeta ?? string.Empty));
                foreach (var track in _detailAlbumTracks)
                {
                    if (track.StartsDisc && track.DiscTitle is not null) rows.Add(new DetailSectionRow(track.DiscTitle));
                    rows.Add(new AlbumTrackItemRow(track));
                }
                AddAlbumShelf(rows, $"More By {SelectedAlbum.ArtistName}", _detailMoreByAlbums);
                break;

            case LibraryPageKind.ArtistDetail when SelectedArtist is not null:
                rows.Add(new ArtistHeroRow(SelectedArtist));
                if (_detailLatestRelease is not null)
                {
                    rows.Add(new DetailSectionRow("Latest Release"));
                    rows.Add(new DetailAlbumShelfRow([_detailLatestRelease]));
                }
                AddTrackGrid(rows, "Top Songs", _detailArtistTopTracks, _detailArtistAlbums.Concat(_detailArtistSingles).ToList());
                AddAlbumShelf(rows, "Albums", _detailArtistAlbums);
                AddAlbumShelf(rows, "Singles & EPs", _detailArtistSingles);
                AddAlbumShelf(rows, "Appears On", _detailArtistAppearsOn);
                break;

            case LibraryPageKind.PlaylistDetail when SelectedPlaylist is not null:
                rows.Add(new PlaylistHeroRow(SelectedPlaylist, DetailMeta ?? string.Empty));
                if (_detailPlaylistTracks.Count > 0) rows.Add(new PlaylistTrackHeaderRow());
                rows.AddRange(_detailPlaylistTracks.Select(t => new PlaylistTrackItemRow(t)));
                break;
        }

        Replace(DetailRows, rows);
    }

    private void AddAlbumShelf(List<DetailRow> rows, string title, IReadOnlyList<Album> albums)
    {
        if (albums.Count == 0) return;
        rows.Add(new DetailSectionRow(title));
        foreach (var row in MediaDetailFormatting.ChunkRows(albums, ColumnsFor(AlbumTilePitch)))
            rows.Add(new DetailAlbumShelfRow(row));
    }

    private void AddTrackGrid(List<DetailRow> rows, string title, IReadOnlyList<Track> tracks, IReadOnlyList<Album> albums)
    {
        if (tracks.Count == 0) return;
        var albumsByRemoteId = albums
            .Where(a => !string.IsNullOrWhiteSpace(a.RemoteId))
            .GroupBy(a => $"{a.ServerId}\n{a.RemoteId}", StringComparer.Ordinal)
            .ToDictionary(g => g.Key, g => g.First(), StringComparer.Ordinal);
        var cards = tracks.Select(track =>
        {
            albumsByRemoteId.TryGetValue($"{track.ServerId}\n{track.AlbumRemoteId}", out var album);
            return new TrackCard(track, MediaDetailFormatting.TrackAlbumYear(track, album));
        }).ToList();
        rows.Add(new DetailSectionRow(title));
        foreach (var row in MediaDetailFormatting.ChunkRows(cards, ColumnsFor(TopSongPitch)))
            rows.Add(new DetailTrackGridRow(row));
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
            if (Section == LibrarySection.Search) await LoadSectionAsync(LibrarySection.Songs, clearBackStack: true);
            return;
        }

        try
        {
            await Task.Delay(140, cts.Token);
            var results = await _core.CallAsync<SearchResults>(
                new CoreRequest("search") { Query = query, Limit = 50 }, cts.Token);
            if (cts.Token.IsCancellationRequested || results is null) return;

            _navigation.Replace(LibraryPage.ForSection(LibrarySection.Search), clearBackStack: true);
            Section = LibrarySection.Search;
            _pagingGeneration++;
            _nextCursor = null;
            PageTitle = "Search";
            Replace(Tracks, results.Tracks);
            Replace(Albums, results.Albums);
            Replace(Artists, results.Artists);
            AlbumGrid.Reset(results.Albums);
            ArtistGrid.Reset(results.Artists);
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
        // The list the user clicked in becomes the queue; "what plays next" is
        // app logic, never the engine's concern.
        var context = Tracks.Contains(track) ? Tracks.ToList() : [track];
        int index = context.IndexOf(track);
        _ = StartQueueAsync(context, index < 0 ? 0 : index);
    }

    [RelayCommand]
    private void PlayAlbumTrack(AlbumTrackRow? row)
    {
        if (row is null) return;
        var context = AlbumTrackRows.Select(r => r.Track).ToList();
        int index = context.IndexOf(row.Track);
        _ = StartQueueAsync(context, index < 0 ? 0 : index);
    }

    [RelayCommand]
    private void PlayArtistTrack(Track? track)
    {
        if (track is null) return;
        var context = ArtistTracks.ToList();
        int index = context.IndexOf(track);
        _ = StartQueueAsync(context.Count == 0 ? [track] : context, index < 0 ? 0 : index);
    }

    [RelayCommand]
    private void PlaySelectedAlbum()
    {
        var context = AlbumTrackRows.Select(r => r.Track).ToList();
        if (context.Count > 0) _ = StartQueueAsync(context, 0);
    }

    [RelayCommand]
    private void ShuffleSelectedAlbum()
    {
        var context = AlbumTrackRows.Select(r => r.Track).OrderBy(_ => Random.Shared.Next()).ToList();
        if (context.Count > 0) _ = StartQueueAsync(context, 0);
    }

    [RelayCommand]
    private void PlaySelectedArtist()
    {
        var context = ArtistTracks.ToList();
        if (context.Count > 0) _ = StartQueueAsync(context, 0);
    }

    [RelayCommand]
    private void PlaySelectedPlaylist()
    {
        var context = PlaylistTracks.ToList();
        if (context.Count > 0) _ = StartQueueAsync(context, 0);
    }

    [RelayCommand]
    private void ShuffleSelectedPlaylist()
    {
        var context = PlaylistTracks.OrderBy(_ => Random.Shared.Next()).ToList();
        if (context.Count > 0) _ = StartQueueAsync(context, 0);
    }

    [RelayCommand]
    private void TogglePlayPause()
    {
        if (_engine is null || NowPlaying is null) return;
        switch (_engine.State)
        {
            case PlaybackState.Playing:
                _engine.Pause();
                IsPlaying = false;
                break;
            case PlaybackState.Paused:
                _engine.Resume();
                IsPlaying = true;
                break;
            default:
                _ = PlayIndexAsync(_queueIndex < 0 ? 0 : _queueIndex);
                break;
        }
        _nowPlaying_os?.UpdateState(_engine.State);
    }

    [RelayCommand]
    private Task Next() => NextAsync();

    [RelayCommand]
    private Task Previous() => PreviousAsync();

    private async Task StartQueueAsync(IReadOnlyList<Track> tracks, int index)
    {
        _queue.Clear();
        _queue.AddRange(tracks);
        await PlayIndexAsync(index);
    }

    private async Task PlayIndexAsync(int index)
    {
        if (_engine is null || index < 0 || index >= _queue.Count) return;
        _queueIndex = index;
        var track = _queue[index];

        // Resolving a source can spawn ffprobe or call the core, so keep it off
        // the UI thread.
        var source = await Task.Run(() => ResolveSource(track));
        if (source is null) return; // ResolveSource reported why.

        NowPlaying = track;
        DurationSeconds = source.KnownDuration?.TotalSeconds
            ?? (track.DurationSeconds > 0 ? track.DurationSeconds : 0);
        _suppressSeek = true;
        PositionSeconds = 0;
        _suppressSeek = false;

        _engine.Play(source, track);
        IsPlaying = true;

        _nowPlaying_os?.UpdateMetadata(new NowPlayingMetadata(
            track.Title, track.ArtistName, track.AlbumTitle,
            source.KnownDuration ?? TimeSpan.FromSeconds(track.DurationSeconds)));
        _nowPlaying_os?.UpdateState(PlaybackState.Playing);

        await PreloadNeighborAsync();
    }

    /// <summary>Hand the engine the next track so it can stitch it in gaplessly.</summary>
    private async Task PreloadNeighborAsync()
    {
        if (_engine is null) return;
        int next = _queueIndex + 1;
        if (next < 0 || next >= _queue.Count) return;
        var track = _queue[next];
        var source = await Task.Run(() => ResolveSource(track));
        if (source is not null) _engine.PreloadNext(source, track);
    }

    private async Task NextAsync()
    {
        if (_queueIndex + 1 < _queue.Count)
            await PlayIndexAsync(_queueIndex + 1);
        else
        {
            _engine?.Stop();
            IsPlaying = false;
        }
    }

    private async Task PreviousAsync()
    {
        if (_engine is null) return;
        // Standard behaviour: restart the track unless we're near its start.
        if (_engine.Position.TotalSeconds > 3 || _queueIndex <= 0)
        {
            _engine.Seek(TimeSpan.Zero);
            _suppressSeek = true;
            PositionSeconds = 0;
            _suppressSeek = false;
        }
        else
        {
            await PlayIndexAsync(_queueIndex - 1);
        }
    }

    private void StopPlayback()
    {
        _engine?.Stop();
        IsPlaying = false;
        _nowPlaying_os?.UpdateState(PlaybackState.Stopped);
    }

    private void OnPositionTick(object? sender, EventArgs e)
    {
        if (_engine is null) return;
        IsPlaying = _engine.State == PlaybackState.Playing;

        var duration = _engine.Duration.TotalSeconds;
        if (duration > 0) DurationSeconds = duration;

        // Don't fight the user while they're dragging the scrubber.
        var msSinceUserSeek = (Stopwatch.GetTimestamp() - _lastUserSeekTicks) * 1000.0 / Stopwatch.Frequency;
        if (msSinceUserSeek < 250) return;

        _suppressSeek = true;
        var pos = _engine.Position.TotalSeconds;
        PositionSeconds = DurationSeconds > 0 ? Math.Min(pos, DurationSeconds) : pos;
        _suppressSeek = false;

        _nowPlaying_os?.UpdatePosition(_engine.Position, _engine.Duration);
    }

    partial void OnPositionSecondsChanged(double value)
    {
        OnPropertyChanged(nameof(PositionText));
        if (_suppressSeek || _engine is null) return;
        // The change came from the slider: remember it and debounce the seek.
        _pendingSeek = value;
        _lastUserSeekTicks = Stopwatch.GetTimestamp();
        _seekDebounce?.Stop();
        _seekDebounce?.Start();
    }

    private void OnSeekDebounceTick(object? sender, EventArgs e)
    {
        _seekDebounce?.Stop();
        _engine?.Seek(TimeSpan.FromSeconds(_pendingSeek));
    }

    partial void OnDurationSecondsChanged(double value) => OnPropertyChanged(nameof(DurationText));

    partial void OnIsPlayingChanged(bool value)
    {
        OnPropertyChanged(nameof(PlayPauseGlyph));
        _nowPlaying_os?.UpdateState(value ? PlaybackState.Playing : PlaybackState.Paused);
    }

    partial void OnVolumeChanged(double value)
    {
        if (_engine is not null) _engine.Volume = value;
    }

    private void OnEngineTrackChanged(object? sender, TrackChangedEventArgs e)
    {
        // Fired from the engine's notifier thread — marshal to the UI thread.
        Dispatcher.UIThread.Post(() =>
        {
            if (e.Token is not Track track) return;
            NowPlaying = track;
            int idx = _queue.IndexOf(track);
            if (idx >= 0) _queueIndex = idx;
            DurationSeconds = _engine?.Duration.TotalSeconds is > 0 and var d ? d : track.DurationSeconds;
            _suppressSeek = true;
            PositionSeconds = 0;
            _suppressSeek = false;
            IsPlaying = true;
            _nowPlaying_os?.UpdateMetadata(new NowPlayingMetadata(
                track.Title, track.ArtistName, track.AlbumTitle,
                _engine?.Duration ?? TimeSpan.FromSeconds(track.DurationSeconds)));
            _ = PreloadNeighborAsync();
        });
    }

    private void OnEnginePlaybackEnded(object? sender, EventArgs e)
    {
        Dispatcher.UIThread.Post(() =>
        {
            IsPlaying = false;
            _nowPlaying_os?.UpdateState(PlaybackState.Stopped);
        });
    }

    private void OnEngineError(object? sender, AudioErrorEventArgs e)
        => Dispatcher.UIThread.Post(() => StatusMessage = e.Message);

    private static readonly HashSet<string> AudioExtensions = new(StringComparer.OrdinalIgnoreCase)
    { ".wav", ".flac", ".mp3", ".m4a", ".aac", ".ogg", ".oga", ".opus", ".alac", ".aif", ".aiff", ".wma" };

    /// <summary>
    /// Turn a library <see cref="Track"/> into something the engine can open.
    /// For development, <c>MOZZ_DEMO_AUDIO</c> points at a file or a folder of
    /// audio so the pipeline can be heard end to end. Otherwise we try the core
    /// for a stream URL; the core has no such command yet, so that path fails
    /// gracefully with a status message rather than throwing into the engine.
    /// </summary>
    private AudioSource? ResolveSource(Track track)
    {
        var demo = Environment.GetEnvironmentVariable("MOZZ_DEMO_AUDIO");
        if (!string.IsNullOrWhiteSpace(demo))
        {
            var file = ResolveDemoFile(demo, track);
            if (file is not null)
            {
                var probed = TryProbeDuration(file);
                var known = probed ?? (track.DurationSeconds > 0
                    ? TimeSpan.FromSeconds(track.DurationSeconds)
                    : (TimeSpan?)null);
                return new AudioSource(Path.GetFullPath(file),
                                       ReplayGainTrackDb: track.NormalizationGainDB,
                                       KnownDuration: known);
            }
        }

        try
        {
            var stream = _core.Call<StreamSource>(new CoreRequest("streamURL")
            {
                RemoteId = track.RemoteId,
                ServerId = track.ServerId,
            });
            if (stream is not null && !string.IsNullOrWhiteSpace(stream.Url))
            {
                return new AudioSource(
                    stream.Url,
                    stream.Headers,
                    // The server's own ReplayGain figure, so two albums mastered
                    // at different loudness play at the same level. Jellyfin and
                    // Subsonic both report it; Plex does not, and those tracks
                    // simply play unattenuated.
                    ReplayGainTrackDb: track.NormalizationGainDB,
                    KnownDuration: track.DurationSeconds > 0 ? TimeSpan.FromSeconds(track.DurationSeconds) : null);
            }
        }
        catch
        {
            // The core doesn't expose a stream URL yet; fall through to the hint.
        }

        Dispatcher.UIThread.Post(() => StatusMessage =
            "No audio source for this track yet — set MOZZ_DEMO_AUDIO to a file or folder to hear playback.");
        return null;
    }

    private string? ResolveDemoFile(string demo, Track track)
    {
        try
        {
            if (File.Exists(demo)) return demo;
            if (Directory.Exists(demo))
            {
                var files = Directory.EnumerateFiles(demo)
                    .Where(f => AudioExtensions.Contains(Path.GetExtension(f)))
                    .OrderBy(f => f, StringComparer.Ordinal)
                    .ToList();
                if (files.Count == 0) return null;
                // Map each queue slot to a distinct file so a two-track queue
                // exercises the gapless hand-off with real, different audio.
                int i = _queue.IndexOf(track);
                if (i < 0) i = 0;
                return files[i % files.Count];
            }
        }
        catch
        {
            // Unreadable path; treat as "no demo file".
        }
        return null;
    }

    private static TimeSpan? TryProbeDuration(string file)
    {
        try
        {
            var probe = Environment.GetEnvironmentVariable("MOZZ_FFPROBE") ?? "ffprobe";
            var psi = new ProcessStartInfo
            {
                FileName = probe,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            psi.ArgumentList.Add("-v");
            psi.ArgumentList.Add("error");
            psi.ArgumentList.Add("-show_entries");
            psi.ArgumentList.Add("format=duration");
            psi.ArgumentList.Add("-of");
            psi.ArgumentList.Add("default=nw=1:nk=1");
            psi.ArgumentList.Add(file);

            using var p = Process.Start(psi);
            if (p is null) return null;
            var text = p.StandardOutput.ReadToEnd();
            p.WaitForExit(2000);
            if (double.TryParse(text.Trim(), System.Globalization.NumberStyles.Float,
                    System.Globalization.CultureInfo.InvariantCulture, out var seconds) && seconds > 0)
                return TimeSpan.FromSeconds(seconds);
        }
        catch
        {
            // ffprobe missing or failed; the decoder still reports duration for WAV.
        }
        return null;
    }

    private static string FormatClock(double seconds)
    {
        if (double.IsNaN(seconds) || seconds < 0) seconds = 0;
        var span = TimeSpan.FromSeconds(seconds);
        return span.TotalHours >= 1
            ? $"{(int)span.TotalHours}:{span.Minutes:D2}:{span.Seconds:D2}"
            : $"{span.Minutes}:{span.Seconds:D2}";
    }

    private sealed record StreamSource(
        [property: System.Text.Json.Serialization.JsonPropertyName("url")] string Url,
        [property: System.Text.Json.Serialization.JsonPropertyName("headers")] Dictionary<string, string>? Headers);

    private void RaiseDerived()
    {
        OnPropertyChanged(nameof(CanGoBack));
        OnPropertyChanged(nameof(IsHomeSelected));
        OnPropertyChanged(nameof(IsSongsSelected));
        OnPropertyChanged(nameof(IsAlbumsSelected));
        OnPropertyChanged(nameof(IsArtistsSelected));
        OnPropertyChanged(nameof(IsPlaylistsSelected));
        OnPropertyChanged(nameof(IsConnectSelected));
        OnPropertyChanged(nameof(ShowTracks));
        OnPropertyChanged(nameof(ShowAlbums));
        OnPropertyChanged(nameof(ShowArtists));
        OnPropertyChanged(nameof(ShowPlaylists));
        OnPropertyChanged(nameof(ShowSearch));
        OnPropertyChanged(nameof(ShowConnect));
        OnPropertyChanged(nameof(ShowAlbumDetail));
        OnPropertyChanged(nameof(ShowArtistDetail));
        OnPropertyChanged(nameof(ShowPlaylistDetail));
        OnPropertyChanged(nameof(ShowDetailPage));
        OnPropertyChanged(nameof(HasSearchAlbums));
        OnPropertyChanged(nameof(HasSearchArtists));
        OnPropertyChanged(nameof(HasSearchTracks));
        OnPropertyChanged(nameof(HasArtistAlbums));
        OnPropertyChanged(nameof(IsLibraryEmpty));
        OnPropertyChanged(nameof(LibrarySummary));
    }

    private static void Replace<T>(ObservableCollection<T> target, IReadOnlyList<T>? source)
    {
        target.Clear();
        if (source is null) return;
        foreach (var item in source) target.Add(item);
    }

    public void Dispose()
    {
        _positionTimer?.Stop();
        _seekDebounce?.Stop();
        _engine?.Dispose();
        _nowPlaying_os?.Dispose();
        _artwork?.Dispose();
        _core.Dispose();
    }
}
