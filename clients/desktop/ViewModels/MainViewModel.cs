using System.Globalization;
using System.Collections.ObjectModel;
using System.Diagnostics;
using Avalonia.Threading;
using Avalonia.Styling;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Mozz.Desktop.Audio;
using Mozz.Desktop.Audio.Platform;
using Mozz.Desktop.Core;

namespace Mozz.Desktop.ViewModels;

public sealed partial class MainViewModel : ViewModelBase, IDisposable
{
    private readonly MozzCore _core = new();
    private readonly AppPreferences _preferences = new();
    private readonly ISecretStore _secrets;
    private readonly MozzServer _server;
    private readonly string _deviceId;
    private readonly PlayHistoryRecorder _playHistory;
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
    private readonly DispatcherTimer? _continuityReconcileTimer;
    private bool _themeObserverAttached;
    // The queue is app logic — the engine only ever knows "current" and "next".
    private readonly PlaybackQueue _queue = new();
    private bool _suppressSeek;
    private double _pendingSeek;
    private long _lastUserSeekTicks;
    private Guid _continuityRunId = Guid.NewGuid();
    private ulong _continuitySequence;
    private bool _continuityReconciled;
    private string? _lastWrittenContinuityQueueHash;
    private DateTimeOffset _lastPeriodicContinuity = DateTimeOffset.MinValue;
    private CancellationTokenSource? _continuityFlushCts;
    private long _continuityGeneration;
    private readonly SemaphoreSlim _continuityFlushGate = new(1, 1);

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
    public ObservableCollection<GenreTile> Genres { get; } = [];
    public ObservableCollection<AlbumTrackRow> AlbumTrackRows { get; } = [];
    public ObservableCollection<Album> ArtistAlbums { get; } = [];
    public ObservableCollection<Track> ArtistTracks { get; } = [];
    public ObservableCollection<Track> PlaylistTracks { get; } = [];
    public ObservableCollection<DetailRow> DetailRows { get; } = [];
    public ObservableCollection<HomeRow> HomeRows { get; } = [];
    public ObservableCollection<SearchRow> SearchRows { get; } = [];
    public ObservableCollection<QueueItemRow> QueueRows { get; } = [];
    public ObservableCollection<LyricLineRow> LyricRows { get; } = [];
    public ObservableCollection<SettingsLibraryOption> SettingsLibraries { get; } = [];
    public ObservableCollection<SuppressedSettingsItem> SuppressedArtists { get; } = [];
    public ObservableCollection<SuppressedSettingsItem> SuppressedTracks { get; } = [];
    public ObservableCollection<EqualizerBandSetting> EqualizerBands { get; } = [];
    public IReadOnlyList<SettingsCategoryDefinition> SettingsCategories { get; } =
        Mozz.Desktop.ViewModels.SettingsCategories.All;
    public IReadOnlyList<SettingsOption> AppearanceOptions { get; } =
    [
        new("system", "System"),
        new("light", "Light"),
        new("dark", "Dark"),
    ];
    public IReadOnlyList<SettingsOption> DarkStyleOptions { get; } =
    [
        new("dim", "Dim"),
        new("black", "Black"),
    ];
    public IReadOnlyList<SettingsOption> EqualizerPresetOptions { get; } =
        DesktopEqualizerPresets.All.Select(p => new SettingsOption(p.ToString(), p.DisplayName())).ToList();

    /// The Home mixes, album and artist walls, chunked into rows so a VirtualizingStackPanel
    /// can own them — see GridRows for why that indirection exists.
    public GridRows<HomeMixTile> HomeMixGrid { get; } = new();
    public GridRows<Album> AlbumGrid { get; } = new();
    public GridRows<Artist> ArtistGrid { get; } = new();
    public GridRows<GenreTile> GenreGrid { get; } = new();
    public GridRows<Album> GenreAlbumGrid { get; } = new();
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
            AlbumGrid.SetColumns(ColumnsFor(DesktopLayout.AlbumTilePitch));
            ArtistGrid.SetColumns(ColumnsFor(DesktopLayout.ArtistTilePitch));
            GenreGrid.SetColumns(ColumnsFor(DesktopLayout.GenreTilePitch));
            GenreAlbumGrid.SetColumns(ColumnsFor(DesktopLayout.AlbumTilePitch));
            ArtistAlbumGrid.SetColumns(ColumnsFor(DesktopLayout.AlbumTilePitch));
            PlaylistGrid.SetColumns(ColumnsFor(DesktopLayout.PlaylistTilePitch));
            HomeMixGrid.SetColumns(Math.Min(2, ColumnsFor(DesktopLayout.HomeMixTilePitch)));
            RebuildHomeRows();
            RebuildDetailRows();
        }
    }

    private double _contentWidth;

    private List<AlbumTrackRow> _detailAlbumTracks = [];
    private List<Album> _detailMoreByAlbums = [];
    private List<Album> _detailArtistAlbums = [];
    private List<Album> _detailArtistSingles = [];
    private List<Album> _detailArtistAppearsOn = [];
    private List<Track> _detailArtistTopTracks = [];
    private List<Track> _detailPlaylistTracks = [];
    private List<Album> _detailGenreAlbums = [];
    private List<HomeMixTile> _homeMixTiles = [];
    private List<Track> _homeRecentlyPlayed = [];
    private List<Album> _homeRecentlyAddedAlbums = [];
    private List<Playlist> _homePlaylists = [];
    private string? _homeMessage;
    private HomeMixTile? _selectedMix;
    private AlbumReleaseKindLookup? _releaseKindLookup;
    private readonly SettingsCategorySelectionState _settingsCategorySelection = new();

    private int ColumnsFor(double pitch) => DesktopLayout.ColumnsFor(_contentWidth, pitch);

    public bool CanGoBack => _navigation.CanGoBack;
    public bool IsHomeSelected => Section == LibrarySection.Home;
    public bool IsSongsSelected => Section == LibrarySection.Songs;
    public bool IsAlbumsSelected => Section == LibrarySection.Albums;
    public bool IsArtistsSelected => Section == LibrarySection.Artists;
    public bool IsGenresSelected => Section == LibrarySection.Genres;
    public bool IsPlaylistsSelected => Section == LibrarySection.Playlists;
    public bool IsConnectSelected => Section == LibrarySection.Connect;
    public bool IsSettingsSelected => IsSettingsDialogOpen;

    public bool ShowTracks => _navigation.Current is { Kind: LibraryPageKind.Section, Section: LibrarySection.Songs };
    public bool ShowHomeRows => _navigation.Current is { Kind: LibraryPageKind.Section, Section: LibrarySection.Home }
                                && HomeRows.Count > 0;
    public bool ShowHomeEmpty => _navigation.Current is { Kind: LibraryPageKind.Section, Section: LibrarySection.Home }
                                 && !IsBusy
                                 && HomeRows.Count == 0
                                 && TrackCount > 0
                                 && HomeComposition.IsEmpty(
                                     _homeMixTiles,
                                     _homeRecentlyPlayed,
                                     _homeRecentlyAddedAlbums,
                                     _homePlaylists);
    public bool ShowAlbums => _navigation.Current is { Kind: LibraryPageKind.Section, Section: LibrarySection.Albums };
    public bool ShowArtists => _navigation.Current is { Kind: LibraryPageKind.Section, Section: LibrarySection.Artists };
    public bool ShowGenres => _navigation.Current is { Kind: LibraryPageKind.Section, Section: LibrarySection.Genres };
    public bool ShowPlaylists => _navigation.Current is { Kind: LibraryPageKind.Section, Section: LibrarySection.Playlists };
    public bool ShowSearch => _navigation.Current is { Kind: LibraryPageKind.Section, Section: LibrarySection.Search };
    public bool ShowConnect => _navigation.Current is { Kind: LibraryPageKind.Section, Section: LibrarySection.Connect };
    public bool ShowSettings => false;
    public bool ShowAlbumDetail => _navigation.Current.Kind == LibraryPageKind.AlbumDetail;
    public bool ShowArtistDetail => _navigation.Current.Kind == LibraryPageKind.ArtistDetail;
    public bool ShowPlaylistDetail => _navigation.Current.Kind == LibraryPageKind.PlaylistDetail;
    public bool ShowMixDetail => _navigation.Current.Kind == LibraryPageKind.MixDetail;
    public bool ShowGenreDetail => _navigation.Current.Kind == LibraryPageKind.GenreDetail;
    public bool ShowNowPlaying => _navigation.Current.Kind == LibraryPageKind.NowPlaying;
    public bool ShowDetailPage => ShowAlbumDetail || ShowArtistDetail || ShowPlaylistDetail || ShowMixDetail || ShowGenreDetail;
    public bool HasSearchRows => ShowSearch && SearchRows.Count > 0;
    public bool HasQueue => QueueRows.Count > 0;
    public bool HasLyrics => LyricRows.Count > 0;
    public bool ShowLyricsSilent => ShowNowPlaying && !IsLyricsLoading && LyricStatus == "silent";
    public string ShuffleStateText => _queue.Shuffle == ShuffleMode.On ? "Shuffle On" : "Shuffle";
    public string RepeatStateText => _queue.Repeat switch
    {
        RepeatMode.All => "Repeat All",
        RepeatMode.One => "Repeat One",
        _ => "Repeat",
    };
    public bool HasArtistAlbums => ArtistAlbums.Count > 0;

    /// <summary>
    /// Nothing loaded, so the pane shows its empty state — but never on the
    /// Servers pane, which is where someone goes precisely because the library
    /// is empty and would otherwise be told so on top of the sign-in form.
    /// </summary>
    public bool IsLibraryEmpty => TrackCount == 0 && !IsBusy && ShowConnect == false && ShowSettings == false
                                  && ShowDetailPage == false && ShowNowPlaying == false && ShowHomeRows == false;

    public string LibrarySummary =>
        TrackCount == 0
            ? "No music yet"
            : $"{TrackCount:N0} songs · {AlbumCount:N0} albums · {ArtistCount:N0} artists";

    public ServerAccount? ActiveAccount => Connect.Accounts.FirstOrDefault();
    public bool HasActiveAccount => ActiveAccount is not null;
    public string SidebarProfileTitle => SettingsPresentation.ProfileTitle(ActiveAccount);
    public string SidebarProfileSubtitle => SettingsPresentation.ProfileSubtitle(ActiveAccount, LibrarySummary);
    public string? ActiveAccountAvatarUrl => ActiveAccountProfile?.AvatarUrl;
    public bool HasActiveAccountAvatar => ActiveAccountAvatarUrl is { Length: > 0 };
    public string ActiveAccountFallbackText =>
        ActiveAccountProfile?.DisplayName
        ?? ActiveAccountProfile?.Username
        ?? ActiveAccount?.Username
        ?? ActiveAccount?.ServerName
        ?? "Settings";
    public string ActiveServerTitle => SettingsPresentation.ServerSectionTitle(ActiveAccount);
    public string ActiveServerSubtitle => SettingsPresentation.ServerSectionSubtitle(ActiveAccount);
    public SettingsCategory SelectedSettingsCategory => _settingsCategorySelection.Selected;
    public string SettingsCategoryTitle => _settingsCategorySelection.SelectedDefinition.Label;
    public string SettingsCategorySubtitle => _settingsCategorySelection.SelectedDefinition.Subtitle;
    public bool IsSettingsAccountSelected => _settingsCategorySelection.IsSelected(SettingsCategory.AccountServers);
    public bool IsSettingsLibrarySelected => _settingsCategorySelection.IsSelected(SettingsCategory.Library);
    public bool IsSettingsPlaybackSelected => _settingsCategorySelection.IsSelected(SettingsCategory.Playback);
    public bool IsSettingsLyricsSelected => _settingsCategorySelection.IsSelected(SettingsCategory.Lyrics);
    public bool IsSettingsRecommendationsSelected => _settingsCategorySelection.IsSelected(SettingsCategory.Recommendations);
    public bool IsSettingsAppearanceSelected => _settingsCategorySelection.IsSelected(SettingsCategory.Appearance);
    public bool IsSettingsDiagnosticsSelected => _settingsCategorySelection.IsSelected(SettingsCategory.Diagnostics);
    public bool IsSettingsAboutSelected => _settingsCategorySelection.IsSelected(SettingsCategory.About);
    public bool HasSettingsLibraries => SettingsLibraries.Count > 0;
    public bool HasSuppressions => SuppressedArtists.Count > 0 || SuppressedTracks.Count > 0;
    public string SettingsStorageDescription => $"Preferences: {_preferences.Path}";
    public string SecretStorageDescription => $"Secrets: {_secrets.Description}";
    public string DeviceIdentityDescription => $"History device: {_deviceId}";

    [ObservableProperty] private bool _normalizationEnabled;
    [ObservableProperty] private bool _enrichmentEnabled;
    [ObservableProperty] private string _appearance = "system";
    [ObservableProperty] private string _darkStyle = "dim";
    [ObservableProperty] private bool _equalizerEnabled;
    [ObservableProperty] private double _equalizerPreamp;
    [ObservableProperty] private string? _settingsMessage;
    [ObservableProperty] private bool _isSettingsBusy;
    [ObservableProperty] private bool _isSettingsDialogOpen;
    [ObservableProperty] private ServerAccountProfile? _activeAccountProfile;
    [ObservableProperty] private string? _lyricStatus;
    [ObservableProperty] private bool _isLyricsLoading;
    [ObservableProperty] private string? _lyricsMessage;
    [ObservableProperty] private ContinuityResumeOffer? _continuityOffer;

    public bool HasContinuityOffer => ContinuityOffer is not null;

    public MainViewModel()
    {
        // Constructed before the design-mode bail-out because the previewer binds
        // to it. Nothing here touches the disk or the network until a command runs.
        _deviceId = _preferences.GetOrCreateDeviceId();
        _playHistory = new PlayHistoryRecorder(
            evt => _ = RecordPlayEventAsync(evt),
            report => _ = ReportPlaybackAsync(report));
        _secrets = SecretStore.ForCurrentPlatform();
        _server = new MozzServer(_core, _secrets);
        Connect = new ConnectViewModel(_server, onLibraryChanged: ReloadAfterSyncAsync);
        Connect.Accounts.CollectionChanged += (_, _) =>
        {
            OnPropertyChanged(nameof(ActiveAccount));
            OnPropertyChanged(nameof(HasActiveAccount));
            OnPropertyChanged(nameof(SidebarProfileTitle));
            OnPropertyChanged(nameof(SidebarProfileSubtitle));
            OnPropertyChanged(nameof(ActiveAccountAvatarUrl));
            OnPropertyChanged(nameof(HasActiveAccountAvatar));
            OnPropertyChanged(nameof(ActiveAccountFallbackText));
            OnPropertyChanged(nameof(ActiveServerTitle));
            OnPropertyChanged(nameof(ActiveServerSubtitle));
            _ = RefreshActiveAccountProfileAsync();
        };
        RestoreSettings();

        // The previewer builds view models with no library present; don't try to
        // open a database from the designer.
        if (Avalonia.Controls.Design.IsDesignMode) return;

        // Publish the artwork pipeline the tiles draw from. It shares this one
        // server, so covers resolve against the same attached backends playback
        // does, and it is ambient because the tiles are made by data templates and
        // have no constructor to hand it to.
        _artwork = ArtworkService.Install(_server);
        // Covers failing used to be silent, so a wall of letter placeholders
        // looked the same whether the server had no art, the network was
        // refusing the connection, or nothing had attached yet.
        _artwork.ArtworkFailed += reason => Dispatcher.UIThread.Post(() => StatusMessage = reason);
        // And take the complaint back down once covers start arriving, so a
        // solved problem stops being advertised.
        ArtworkService.ArtworkRecovered += () => Dispatcher.UIThread.Post(() =>
        {
            if (StatusMessage?.Contains("album art", StringComparison.OrdinalIgnoreCase) == true)
            {
                StatusMessage = null;
            }
        });

        _engine = new Mozz.Desktop.Audio.Native.RustAudioEngine { Volume = Volume };
        // Track gain rather than album: Mozz plays across a whole library far
        // more than it plays an album end to end, and album mode deliberately
        // preserves the loudness relationship *within* a record — which is the
        // wrong choice when the next song is from somewhere else entirely.
        //
        // No pre-amp. ReplayGain figures are almost always negative (they
        // attenuate to a reference level), so adding headroom back invites the
        // clipping the standard exists to avoid.
        _engine.SetReplayGain(NormalizationEnabled ? ReplayGainMode.Track : ReplayGainMode.Off);
        ApplyEqualizerToEngine();
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

        _continuityReconcileTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(30) };
        _continuityReconcileTimer.Tick += (_, _) =>
        {
            if (!IsPlaying) _ = ReconcileContinuityAsync();
        };
        _continuityReconcileTimer.Start();

        _ = InitializeAsync();
    }

    partial void OnActiveAccountProfileChanged(ServerAccountProfile? value)
    {
        OnPropertyChanged(nameof(ActiveAccountAvatarUrl));
        OnPropertyChanged(nameof(HasActiveAccountAvatar));
        OnPropertyChanged(nameof(ActiveAccountFallbackText));
    }

    partial void OnContinuityOfferChanged(ContinuityResumeOffer? value) =>
        OnPropertyChanged(nameof(HasContinuityOffer));

    private void RestoreSettings()
    {
        NormalizationEnabled = _preferences.GetBool(AppPreferences.NormalizationEnabledKey, true);
        EnrichmentEnabled = _preferences.GetBool(AppPreferences.EnrichmentEnabledKey, true);
        Appearance = _preferences.GetString(AppPreferences.AppearanceKey, "system");
        DarkStyle = _preferences.GetString(AppPreferences.DarkStyleKey, "dim");
        EqualizerEnabled = _preferences.GetBool(AppPreferences.EqualizerEnabledKey, false);
        var profile = _preferences.GetEqualizerProfile();
        EqualizerPreamp = profile.PreampDB;
        EqualizerBands.Clear();
        for (var i = 0; i < DesktopEqualizerProfile.BandCount; i++)
        {
            EqualizerBands.Add(new EqualizerBandSetting(
                i,
                DesktopEqualizerProfile.FrequencyLabel(i),
                profile.Gains[i],
                (_, _) => PersistEqualizer()));
        }
        ApplyAppearance();
    }

    partial void OnNormalizationEnabledChanged(bool value)
    {
        _preferences.SetBool(AppPreferences.NormalizationEnabledKey, value);
        _engine?.SetReplayGain(value ? ReplayGainMode.Track : ReplayGainMode.Off);
    }

    partial void OnEnrichmentEnabledChanged(bool value) =>
        _preferences.SetBool(AppPreferences.EnrichmentEnabledKey, value);

    partial void OnAppearanceChanged(string value)
    {
        if (value is not ("system" or "light" or "dark")) value = "system";
        _preferences.SetString(AppPreferences.AppearanceKey, value);
        ApplyAppearance();
    }

    partial void OnDarkStyleChanged(string value)
    {
        if (value is not ("dim" or "black")) value = "dim";
        _preferences.SetString(AppPreferences.DarkStyleKey, value);
        ApplyAppearance();
    }

    partial void OnEqualizerEnabledChanged(bool value)
    {
        _preferences.SetBool(AppPreferences.EqualizerEnabledKey, value);
        ApplyEqualizerToEngine();
    }

    partial void OnEqualizerPreampChanged(double value)
    {
        var clamped = DesktopEqualizerProfile.ClampGain(value);
        if (Math.Abs(clamped - value) > 0.001)
        {
            EqualizerPreamp = clamped;
            return;
        }
        PersistEqualizer();
    }

    public string EqualizerPreampText => EqualizerBandSetting.FormatGain(EqualizerPreamp);

    private DesktopEqualizerProfile CurrentEqualizerProfile() =>
        new DesktopEqualizerProfile(EqualizerBands.Select(b => b.Gain).ToArray(), EqualizerPreamp).Normalized();

    private void PersistEqualizer()
    {
        OnPropertyChanged(nameof(EqualizerPreampText));
        var profile = CurrentEqualizerProfile();
        _preferences.SetEqualizerProfile(profile);
        ApplyEqualizerToEngine();
    }

    private void ApplyEqualizerToEngine() =>
        _engine?.SetEqualizer(CurrentEqualizerProfile().ToAudioSettings(EqualizerEnabled));

    private void ApplyAppearance()
    {
        if (Avalonia.Application.Current is not { } app) return;
        if (!_themeObserverAttached)
        {
            app.ActualThemeVariantChanged += OnActualThemeVariantChanged;
            _themeObserverAttached = true;
        }

        MozzThemeApplicator.Apply(app, Appearance, DarkStyle);
    }

    private void OnActualThemeVariantChanged(object? sender, EventArgs e) => ApplyAppearance();

    /// Called when a sync finishes: the counts and whatever page is showing are
    /// both stale, and the empty-library message may no longer be true.
    private async Task ReloadAfterSyncAsync()
    {
        await RefreshCountsAsync();
        await LoadSectionAsync(Section == LibrarySection.Connect ? LibrarySection.Settings : Section, clearBackStack: true);
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

            // Artwork resolves through an attached backend, and tiles start
            // asking as soon as anything renders — which is before this point.
            // Those requests come back "no attached server", which the cache
            // cannot tell apart from "no such cover", so without this the whole
            // library keeps its letter placeholders until the app restarts.
            _artwork.ForgetFailures();
            _artwork.ResetFailureReport();

            await RefreshActiveAccountProfileAsync();
            await ReconcileContinuityAsync();

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

    private async Task RefreshSettingsAsync()
    {
        IsSettingsBusy = true;
        SettingsMessage = null;
        try
        {
            OnPropertyChanged(nameof(ActiveAccount));
            OnPropertyChanged(nameof(HasActiveAccount));
            OnPropertyChanged(nameof(ActiveAccountAvatarUrl));
            OnPropertyChanged(nameof(HasActiveAccountAvatar));
            OnPropertyChanged(nameof(ActiveAccountFallbackText));
            SettingsLibraries.Clear();
            SuppressedArtists.Clear();
            SuppressedTracks.Clear();
            await RefreshActiveAccountProfileAsync();

            if (ActiveAccount is not { } account || !_core.IsOpen) return;

            var libraries = await _server.LibrariesAsync(account.ServerId) ?? [];
            foreach (var option in LibrarySelectionState.Build(libraries, account.MusicSectionId))
            {
                SettingsLibraries.Add(new SettingsLibraryOption(option.Id, option.Name, option.IsSelected));
            }

            var suppressions = await _core.CallAsync<List<SuppressedRef>>(
                new CoreRequest("suppressions") { ServerId = account.ServerId }) ?? [];
            foreach (var item in suppressions.Select(s => new SuppressedSettingsItem(s.Scope, s.Ref, s.CreatedAt)))
            {
                if (item.Scope == "artist") SuppressedArtists.Add(item);
                else SuppressedTracks.Add(item);
            }
        }
        catch (Exception ex)
        {
            SettingsMessage = ex.Message;
        }
        finally
        {
            OnPropertyChanged(nameof(HasSettingsLibraries));
            OnPropertyChanged(nameof(HasSuppressions));
            IsSettingsBusy = false;
        }
    }

    private async Task RefreshActiveAccountProfileAsync()
    {
        var account = ActiveAccount;
        if (account is null || !_core.IsOpen)
        {
            ActiveAccountProfile = null;
            return;
        }

        try
        {
            ActiveAccountProfile = await _server.AccountAsync(account.ServerId, size: 120);
        }
        catch
        {
            ActiveAccountProfile = null;
        }
    }

    [RelayCommand]
    private Task RefreshSettingsPanel() => RefreshSettingsAsync();

    [RelayCommand]
    private async Task SyncNowAsync()
    {
        if (ActiveAccount is null) return;
        await Connect.SyncAccountCommand.ExecuteAsync(ActiveAccount);
        await RefreshCountsAsync();
        await RefreshSettingsAsync();
    }

    [RelayCommand]
    private async Task UseServerAsync(ServerAccount? account)
    {
        if (account is null) return;
        var index = Connect.Accounts.IndexOf(account);
        if (index > 0) Connect.Accounts.Move(index, 0);

        try
        {
            IsSettingsBusy = true;
            await _server.AttachAsync(account);
            _artwork.ForgetFailures();
            _lastWrittenContinuityQueueHash = null;
            await RefreshActiveAccountProfileAsync();
            await ReconcileContinuityAsync();
            await RefreshCountsAsync();
            await RefreshSettingsAsync();
        }
        catch (Exception ex)
        {
            SettingsMessage = ex.Message;
        }
        finally
        {
            IsSettingsBusy = false;
            RaiseDerived();
        }
    }

    [RelayCommand]
    private async Task SelectMusicLibraryAsync(SettingsLibraryOption? option)
    {
        if (option is null || ActiveAccount is null) return;
        var applied = LibrarySelectionState.Apply(
            SettingsLibraries.Select(l => new MusicLibrarySelectionOption(l.Id, l.Name, l.IsSelected)).ToList(),
            option.Id);
        if (applied is null) return;

        try
        {
            IsSettingsBusy = true;
            var updated = await _server.SelectMusicLibraryAsync(ActiveAccount, applied);
            ReplaceAccount(updated);
            await Connect.SyncAccountCommand.ExecuteAsync(updated);
            await RefreshCountsAsync();
            await RefreshSettingsAsync();
        }
        catch (Exception ex)
        {
            SettingsMessage = ex.Message;
        }
        finally
        {
            IsSettingsBusy = false;
        }
    }

    [RelayCommand]
    private async Task RestoreSuppressionAsync(SuppressedSettingsItem? item)
    {
        if (item is null || ActiveAccount is null || !_core.IsOpen) return;
        try
        {
            var cmd = item.Scope == "artist" ? "unsuppressArtist" : "unsuppressTrack";
            await _core.CallAsync<object>(new CoreRequest(cmd)
            {
                ServerId = ActiveAccount.ServerId,
                RemoteId = item.Ref,
            });
            await RefreshSettingsAsync();
        }
        catch (Exception ex)
        {
            SettingsMessage = ex.Message;
        }
    }

    [RelayCommand]
    private async Task ApplyEqualizerPresetAsync(SettingsOption? option)
    {
        if (option is null || !Enum.TryParse<DesktopEqualizerPreset>(option.Id, out var preset)) return;
        var profile = preset.Profile().Normalized();
        for (var i = 0; i < EqualizerBands.Count && i < profile.Gains.Count; i++)
        {
            EqualizerBands[i].SetSilently(profile.Gains[i]);
        }
        EqualizerPreamp = profile.PreampDB;
        PersistEqualizer();
        await Task.CompletedTask;
    }

    [RelayCommand]
    private void ResetEqualizer()
    {
        var profile = DesktopEqualizerProfile.Flat;
        for (var i = 0; i < EqualizerBands.Count; i++) EqualizerBands[i].SetSilently(profile.Gains[i]);
        EqualizerPreamp = 0;
        PersistEqualizer();
    }

    [RelayCommand]
    private async Task SignOutAsync()
    {
        StopPlayback();
        _server.ForgetAllAccounts();
        Connect.Accounts.Clear();
        ActiveAccountProfile = null;
        OnPropertyChanged(nameof(ActiveAccount));
        OnPropertyChanged(nameof(HasActiveAccount));
        OnPropertyChanged(nameof(ActiveAccountAvatarUrl));
        OnPropertyChanged(nameof(HasActiveAccountAvatar));
        OnPropertyChanged(nameof(ActiveAccountFallbackText));
        SettingsLibraries.Clear();
        SuppressedArtists.Clear();
        SuppressedTracks.Clear();
        OnPropertyChanged(nameof(HasSettingsLibraries));
        OnPropertyChanged(nameof(HasSuppressions));
        ClearLibrary();
        TrackCount = AlbumCount = ArtistCount = 0;
        SettingsMessage = "Signed out.";
        await Task.CompletedTask;
    }

    private void ReplaceAccount(ServerAccount updated)
    {
        for (var i = 0; i < Connect.Accounts.Count; i++)
        {
            if (Connect.Accounts[i].ServerId != updated.ServerId) continue;
            Connect.Accounts[i] = updated;
            OnPropertyChanged(nameof(ActiveAccount));
            OnPropertyChanged(nameof(HasActiveAccount));
            OnPropertyChanged(nameof(ActiveAccountAvatarUrl));
            OnPropertyChanged(nameof(HasActiveAccountAvatar));
            OnPropertyChanged(nameof(ActiveAccountFallbackText));
            return;
        }
    }

    private void ClearLibrary()
    {
        Tracks.Clear();
        Albums.Clear();
        Artists.Clear();
        Playlists.Clear();
        Genres.Clear();
        SearchRows.Clear();
        QueueRows.Clear();
        LyricRows.Clear();
        AlbumTrackRows.Clear();
        ArtistAlbums.Clear();
        ArtistTracks.Clear();
        PlaylistTracks.Clear();
        DetailRows.Clear();
        HomeRows.Clear();
        HomeMixGrid.Reset([]);
        AlbumGrid.Reset([]);
        ArtistGrid.Reset([]);
        GenreGrid.Reset([]);
        GenreAlbumGrid.Reset([]);
        ArtistAlbumGrid.Reset([]);
        PlaylistGrid.Reset([]);
    }

    private async Task RecordPlayEventAsync(DesktopPlayEvent playEvent)
    {
        if (!_core.IsOpen) return;
        try
        {
            await _core.CallAsync<object>(new CoreRequest("recordPlayEvent")
            {
                ServerId = playEvent.ServerId,
                RemoteId = playEvent.RemoteId,
                Kind = playEvent.Kind,
                DeviceID = _deviceId,
                CreatedAtMS = playEvent.CreatedAt.ToUnixTimeMilliseconds(),
                PositionMS = Milliseconds(playEvent.PositionSeconds),
                DurationMS = Milliseconds(playEvent.DurationSeconds),
            });
        }
        catch (Exception ex)
        {
            Dispatcher.UIThread.Post(() => StatusMessage = $"Could not record play history: {ex.Message}");
        }
    }

    private async Task ReportPlaybackAsync(DesktopPlaybackReport report)
    {
        if (!_core.IsOpen) return;
        try
        {
            await _core.CallAsync<PlaybackReportResult>(new CoreRequest("reportPlayback")
            {
                ServerId = report.ServerId,
                RemoteId = report.RemoteId,
                State = report.State,
                PositionSeconds = report.PositionSeconds,
            });
        }
        catch
        {
            // Best-effort scrobbling must never interrupt or block audio.
        }
    }

    private async Task ReconcileContinuityAsync()
    {
        if (!_core.IsOpen || ActiveAccount is not { } account)
        {
            _continuityReconciled = true;
            _lastWrittenContinuityQueueHash = null;
            ContinuityOffer = null;
            return;
        }

        try
        {
            var snapshot = await _core.CallAsync<ContinuitySnapshot>(
                new CoreRequest("continuityLoad") { ServerId = account.ServerId });
            _continuityReconciled = true;
            ContinuityOffer = ContinuityPresentation.OfferFor(
                snapshot,
                _deviceId,
                IsPlaying,
                DateTimeOffset.UtcNow);
        }
        catch
        {
            _continuityReconciled = true;
        }
    }

    private void BeginContinuityRun()
    {
        _continuityRunId = Guid.NewGuid();
        _continuitySequence = 0;
        _lastPeriodicContinuity = DateTimeOffset.MinValue;
    }

    private void CheckpointContinuity(ContinuityCheckpointReason reason)
    {
        if (!_continuityReconciled || ActiveAccount is not { } account || NowPlaying is null || _queue.Current is null)
            return;

        if (reason == ContinuityCheckpointReason.Periodic)
        {
            var now = DateTimeOffset.UtcNow;
            if (now - _lastPeriodicContinuity < TimeSpan.FromSeconds(20)) return;
            _lastPeriodicContinuity = now;
        }

        _continuitySequence++;
        var checkpoint = new PendingContinuityCheckpoint(
            Interlocked.Increment(ref _continuityGeneration),
            account,
            _continuityRunId,
            _continuitySequence,
            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
            ContinuityPresentation.State(IsPlaying),
            _queue.Current.RemoteId,
            _queue.CurrentIndex,
            ContinuityPresentation.Milliseconds(PositionSeconds),
            ContinuityPresentation.QueueInput(account, _queue),
            reason);
        ScheduleContinuityFlush(checkpoint);
    }

    private void ScheduleContinuityFlush(PendingContinuityCheckpoint checkpoint)
    {
        _continuityFlushCts?.Cancel();
        _continuityFlushCts?.Dispose();
        _continuityFlushCts = new CancellationTokenSource();
        var token = _continuityFlushCts.Token;
        var delay = checkpoint.Reason == ContinuityCheckpointReason.Periodic
            ? TimeSpan.FromSeconds(3)
            : TimeSpan.Zero;

        _ = Task.Run(async () =>
        {
            try
            {
                if (delay > TimeSpan.Zero) await Task.Delay(delay, token);
                if (!token.IsCancellationRequested) await FlushContinuityAsync(checkpoint, token);
            }
            catch (OperationCanceledException)
            {
            }
        }, token);
    }

    private async Task FlushContinuityAsync(PendingContinuityCheckpoint checkpoint, CancellationToken token)
    {
        if (!_core.IsOpen) return;
        await _continuityFlushGate.WaitAsync(CancellationToken.None);
        try
        {
            if (checkpoint.Generation != Volatile.Read(ref _continuityGeneration)) return;
            var hash = await _core.CallAsync<ContinuityHash>(
                new CoreRequest("continuityQueueHash") { Queue = checkpoint.Queue },
                token);
            if (checkpoint.Generation != Volatile.Read(ref _continuityGeneration)) return;
            var queueChanged = hash?.QueueHash != _lastWrittenContinuityQueueHash;
            var shouldSendQueue = queueChanged || checkpoint.Account.Kind == BackendKind.Subsonic;
            var saved = await _core.CallAsync<ContinuitySaveResult>(
                new CoreRequest("continuitySave")
                {
                    ServerId = checkpoint.Account.ServerId,
                    PlaybackRunID = checkpoint.RunId.ToString(),
                    DeviceID = _deviceId,
                    DeviceName = Environment.MachineName,
                    Kind = "desktop",
                    CursorSequence = checkpoint.Sequence,
                    CapturedAtMS = checkpoint.CapturedAtMS,
                    State = checkpoint.State,
                    CurrentRemoteID = checkpoint.CurrentRemoteID,
                    CurrentAbsoluteIndex = checkpoint.CurrentAbsoluteIndex,
                    PositionMS = checkpoint.PositionMS,
                    Queue = shouldSendQueue ? checkpoint.Queue : null,
                },
                token);

            if (shouldSendQueue && (saved?.QueueHash ?? hash?.QueueHash) is { } written)
                _lastWrittenContinuityQueueHash = written;
        }
        catch
        {
            // Continuity is opportunistic: the next checkpoint supersedes this one.
        }
        finally
        {
            _continuityFlushGate.Release();
        }
    }

    private void StartHistoryFor(Track track) => _playHistory.Start(track);

    private void CompleteHistoryForCurrent()
    {
        var pending = _playHistory.Pending;
        _playHistory.CompleteCurrent(pending?.DurationSeconds, pending?.DurationSeconds);
    }

    private void SkipHistoryForCurrent() =>
        _playHistory.SkipCurrent(CurrentPositionSeconds(), CurrentDurationSeconds());

    private void SeekHistoryForCurrent(double positionSeconds) =>
        _playHistory.SeekCurrent(positionSeconds, CurrentDurationSeconds());

    private double? CurrentPositionSeconds()
    {
        var value = _engine?.Position.TotalSeconds ?? PositionSeconds;
        return double.IsFinite(value) && value >= 0 ? value : null;
    }

    private double? CurrentDurationSeconds()
    {
        var value = _engine?.Duration.TotalSeconds is > 0 and var engineDuration
            ? engineDuration
            : DurationSeconds;
        return double.IsFinite(value) && value > 0 ? value : null;
    }

    private static long? Milliseconds(double? seconds) =>
        seconds is { } value && double.IsFinite(value)
            ? (long)Math.Round(value * 1000.0, MidpointRounding.AwayFromZero)
            : null;

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
    private Task SelectSection(LibrarySection section) =>
        section == LibrarySection.Settings
            ? OpenSettingsAsync()
            : LoadSectionAsync(section, clearBackStack: true);

    [RelayCommand]
    private async Task OpenSettingsAsync()
    {
        IsSettingsDialogOpen = true;
        OnPropertyChanged(nameof(IsSettingsSelected));
        await RefreshSettingsAsync();
    }

    [RelayCommand]
    private void CloseSettings()
    {
        IsSettingsDialogOpen = false;
        OnPropertyChanged(nameof(IsSettingsSelected));
    }

    [RelayCommand]
    private void SelectSettingsCategory(SettingsCategory category)
    {
        if (!_settingsCategorySelection.Select(category)) return;
        RaiseSettingsCategoryDerived();
    }

    private void RaiseSettingsCategoryDerived()
    {
        OnPropertyChanged(nameof(SelectedSettingsCategory));
        OnPropertyChanged(nameof(SettingsCategoryTitle));
        OnPropertyChanged(nameof(SettingsCategorySubtitle));
        OnPropertyChanged(nameof(IsSettingsAccountSelected));
        OnPropertyChanged(nameof(IsSettingsLibrarySelected));
        OnPropertyChanged(nameof(IsSettingsPlaybackSelected));
        OnPropertyChanged(nameof(IsSettingsLyricsSelected));
        OnPropertyChanged(nameof(IsSettingsRecommendationsSelected));
        OnPropertyChanged(nameof(IsSettingsAppearanceSelected));
        OnPropertyChanged(nameof(IsSettingsDiagnosticsSelected));
        OnPropertyChanged(nameof(IsSettingsAboutSelected));
    }

    private async Task LoadSectionAsync(LibrarySection section, bool clearBackStack)
    {
        _navigation.Replace(LibraryPage.ForSection(section), clearBackStack);
        Section = section;
        _pagingGeneration++;
        _nextCursor = null;
        SelectedAlbum = null;
        SelectedArtist = null;
        SelectedPlaylist = null;
        _selectedMix = null;
        DetailMeta = null;
        ClearDetailState();
        PageTitle = section switch
        {
            LibrarySection.Home => "Home",
            LibrarySection.Songs => "Songs",
            LibrarySection.Albums => "Albums",
            LibrarySection.Artists => "Artists",
            LibrarySection.Genres => "Genres",
            LibrarySection.Playlists => "Playlists",
            LibrarySection.Search => "Search",
            LibrarySection.Connect => "Servers",
            LibrarySection.Settings => "Settings",
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
                    // Home is the same "Made For You" surface as the phone:
                    // quick, generated mixes first, with Liked Songs leading
                    // when the library has any.
                    await LoadHomeMixesAsync();
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
                case LibrarySection.Genres:
                    await LoadGenresAsync();
                    break;
                case LibrarySection.Playlists:
                    await LoadPlaylistsAsync();
                    break;
                case LibrarySection.Settings:
                    await RefreshSettingsAsync();
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

    private async Task LoadHomeMixesAsync()
    {
        StatusMessage = null;
        HomeMixGrid.Reset([]);
        _homeMixTiles = [];
        _homeRecentlyPlayed = [];
        _homeRecentlyAddedAlbums = [];
        _homePlaylists = [];
        _homeMessage = null;
        HomeRows.Clear();
        RaiseDerived();

        var attachedServerIds = Connect.Accounts
            .Select(a => a.ServerId)
            .Where(id => !string.IsNullOrWhiteSpace(id))
            .Distinct(StringComparer.Ordinal)
            .ToList();
        var serverId = attachedServerIds.FirstOrDefault();
        var result = await HomeMixLoader.LoadAsync(
            ReadHomeMixesAsync,
            LoadLikedTracksAsync,
            GenerateHomeMixesAsync,
            attachedServerIds,
            () => StatusMessage = "Generating mixes for Home…");

        _homeMixTiles = HomeMixPresentation.BuildTiles(
            result.LikedTracks.Count,
            result.Mixes,
            serverId).ToList();
        HomeMixGrid.Reset(_homeMixTiles);
        var messages = new List<string>();
        if (!string.IsNullOrWhiteSpace(result.Message)) messages.Add(result.Message);
        if (!string.IsNullOrWhiteSpace(serverId))
        {
            var server = serverId!;
            _homeRecentlyPlayed = (await HomeShelfLoader.LoadAsync<Track>(
                   "Recently Played",
                   new CoreRequest("recentlyPlayedTracks") { ServerId = server, Limit = MediaDetailFormatting.ShelfPageSize },
                   async request => await _core.CallAsync<List<Track>>(request),
                   messages))
               .ToList();
            _homeRecentlyAddedAlbums = (await HomeShelfLoader.LoadAsync<Album>(
                   "Recently Added",
                   new CoreRequest("recentlyAddedAlbums") { ServerId = server, Limit = MediaDetailFormatting.ShelfPageSize },
                   async request => await _core.CallAsync<List<Album>>(request),
                   messages))
               .ToList();
            _homePlaylists = (await HomeShelfLoader.LoadAsync<Playlist>(
                   "Your Playlists",
                   new CoreRequest("playlists") { ServerId = server, Limit = MediaDetailFormatting.ShelfPageSize },
                   async request => await _core.CallAsync<List<Playlist>>(request),
                   messages))
               .Take(MediaDetailFormatting.ShelfPageSize)
               .ToList();
        }
        else
        {
            _homeMessage = HomeMixPresentation.NoAttachedHomeServerMessage;
        }

        RebuildHomeRows();
        StatusMessage = messages.Count == 0 ? null : string.Join(" ", messages.Distinct(StringComparer.Ordinal));
        RaiseDerived();
    }

    private async Task<IReadOnlyList<HomeMix>> ReadHomeMixesAsync() =>
        await _core.CallAsync<List<HomeMix>>(new CoreRequest("homeMixes")) ?? [];

    private async Task<IReadOnlyList<Track>> LoadLikedTracksAsync() =>
        await _core.CallAsync<List<Track>>(new CoreRequest("likedTracks")) ?? [];

    private async Task GenerateHomeMixesAsync(string serverId) =>
        await _core.CallAsync<object>(new CoreRequest("generateHomeMixes") { ServerId = serverId });

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

    private async Task LoadGenresAsync()
    {
        var serverId = Connect.Accounts.FirstOrDefault()?.ServerId;
        var names = string.IsNullOrWhiteSpace(serverId)
            ? new List<string>()
            : await _core.CallAsync<List<string>>(new CoreRequest("genres") { ServerId = serverId }) ?? [];
        var genres = GenrePresentation.Build(names);
        Replace(Genres, genres);
        GenreGrid.Reset(genres);
        _nextCursor = null;
    }

    private async Task LoadPlaylistsAsync()
    {
        var serverId = Connect.Accounts.FirstOrDefault()?.ServerId;
        var page = await _core.CallPageAsync<List<Playlist>>(
            new CoreRequest("playlists") { ServerId = serverId, Limit = PageSize });
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
        if (Section is LibrarySection.Search or LibrarySection.Connect or LibrarySection.Settings) return;

        _isLoadingMore = true;
        try
        {
            switch (Section)
            {
                case LibrarySection.Songs when _navigation.Current.Kind == LibraryPageKind.Section:
                    await AppendAsync(Tracks, "tracks");
                    break;
                case LibrarySection.Albums when _navigation.Current.Kind == LibraryPageKind.Section:
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
    private async Task OpenGenre(GenreTile? genre)
    {
        if (genre is null) return;
        _navigation.Push(LibraryPage.ForGenre(genre.Name));
        await ApplyPageAsync(_navigation.Current, reload: true);
    }

    [RelayCommand]
    private async Task OpenNowPlaying()
    {
        _navigation.Push(LibraryPage.ForNowPlaying());
        await ApplyPageAsync(_navigation.Current, reload: false);
    }

    [RelayCommand]
    private async Task OpenMix(HomeMixTile? mix)
    {
        if (mix is null) return;
        _selectedMix = mix;
        _navigation.Push(LibraryPage.ForMix(mix.Id, mix.Title));
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
                _selectedMix = null;
                PageTitle = "Album";
                if (reload && page.Album is not null) await LoadAlbumDetailAsync(page.Album);
                break;
            case LibraryPageKind.ArtistDetail:
                Section = LibrarySection.Artists;
                SelectedArtist = page.Artist;
                SelectedAlbum = null;
                SelectedPlaylist = null;
                _selectedMix = null;
                PageTitle = "Artist";
                if (reload && page.Artist is not null) await LoadArtistDetailAsync(page.Artist);
                break;
            case LibraryPageKind.PlaylistDetail:
                Section = LibrarySection.Playlists;
                SelectedPlaylist = page.Playlist;
                SelectedAlbum = null;
                SelectedArtist = null;
                _selectedMix = null;
                PageTitle = "Playlist";
                if (reload && page.Playlist is not null) await LoadPlaylistDetailAsync(page.Playlist);
                break;
            case LibraryPageKind.GenreDetail:
                Section = LibrarySection.Genres;
                SelectedAlbum = null;
                SelectedArtist = null;
                SelectedPlaylist = null;
                _selectedMix = null;
                PageTitle = page.Genre ?? "Genre";
                if (reload && page.Genre is not null) await LoadGenreDetailAsync(page.Genre);
                break;
            case LibraryPageKind.MixDetail:
                Section = LibrarySection.Home;
                SelectedAlbum = null;
                SelectedArtist = null;
                SelectedPlaylist = null;
                PageTitle = page.Title ?? "Mix";
                if (reload && page.MixId is not null) await LoadMixDetailAsync(page.MixId, page.Title);
                break;
            case LibraryPageKind.NowPlaying:
                Section = LibrarySection.Search;
                SelectedAlbum = null;
                SelectedArtist = null;
                SelectedPlaylist = null;
                _selectedMix = null;
                PageTitle = "Now Playing";
                RefreshQueueRows();
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
            albums = await EnrichReleaseKindsAsync(albums);
            var releaseKinds = await EnsureAlbumReleaseKindsAsync();
            _detailArtistAlbums = MediaDetailFormatting.StudioAlbums(albums, releaseKinds).ToList();
            _detailArtistSingles = MediaDetailFormatting.SinglesAndEps(albums, releaseKinds).ToList();
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

    private async Task<List<Album>> EnrichReleaseKindsAsync(IReadOnlyList<Album> albums)
    {
        var releaseKinds = await EnsureAlbumReleaseKindsAsync();
        return albums
            .Select(album => album.IsSingleOrEp is not null
                ? album
                : album with { IsSingleOrEp = releaseKinds.IsSingleOrEp(album.TrackCount) })
            .ToList();
    }

    private async Task<AlbumReleaseKindLookup> EnsureAlbumReleaseKindsAsync()
    {
        if (_releaseKindLookup is not null) return _releaseKindLookup;

        var unknown = await AlbumReleaseKindForAsync(null);
        var byTrackCount = new Dictionary<int, bool>();
        for (var count = 1; count <= 8; count++)
        {
            byTrackCount[count] = (await AlbumReleaseKindForAsync(count)).IsSingleOrEp;
        }

        _releaseKindLookup = new AlbumReleaseKindLookup(unknown.IsSingleOrEp, byTrackCount);
        return _releaseKindLookup;
    }

    private async Task<AlbumReleaseKind> AlbumReleaseKindForAsync(int? trackCount) =>
        await _core.CallAsync<AlbumReleaseKind>(new CoreRequest("albumReleaseKind")
        {
            TrackCount = trackCount,
        }) ?? new AlbumReleaseKind("album", false);

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

    private async Task LoadMixDetailAsync(string mixId, string? title)
    {
        _detailPlaylistTracks = [];
        PlaylistTracks.Clear();
        var mix = _selectedMix ?? new HomeMixTile(
            mixId,
            string.IsNullOrWhiteSpace(title) ? "Mix" : title!,
            null,
            mixId == HomeMixIds.LikedSongs ? "liked" : "mix",
            null,
            null,
            IsLiked: mixId == HomeMixIds.LikedSongs,
            TrackCount: null);
        _selectedMix = mix;
        DetailMeta = string.Empty;
        RebuildDetailRows();
        RaiseDerived();

        if (!_core.IsOpen) return;

        try
        {
            IsBusy = true;
            if (mixId != HomeMixIds.LikedSongs)
            {
                var payload = await _core.CallAsync<MixPayload>(new CoreRequest("mix") { SetId = mixId });
                if (payload is not null)
                {
                    mix = mix with { Title = payload.Title, Kind = payload.Kind };
                    _selectedMix = mix;
                    PageTitle = payload.Title;
                }
            }

            var tracks = mixId == HomeMixIds.LikedSongs
                ? await LoadLikedTracksAsync()
                : await _core.CallAsync<List<Track>>(new CoreRequest("mixTracks") { SetId = mixId }) ?? [];
            _detailPlaylistTracks = tracks.ToList();
            Replace(PlaylistTracks, _detailPlaylistTracks);
            DetailMeta = HomeMixPresentation.TrackCollectionMeta(_detailPlaylistTracks);
            if (_selectedMix is not null && _selectedMix.IsLiked)
            {
                _selectedMix = _selectedMix with
                {
                    Subtitle = HomeMixPresentation.FormatSongCount(_detailPlaylistTracks.Count),
                    TrackCount = _detailPlaylistTracks.Count,
                };
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

    private async Task LoadGenreDetailAsync(string genre)
    {
        _detailGenreAlbums = [];
        GenreAlbumGrid.Reset([]);
        DetailMeta = GenrePresentation.Metadata(genre, _detailGenreAlbums);
        RebuildDetailRows();
        RaiseDerived();

        if (!_core.IsOpen) return;

        try
        {
            IsBusy = true;
            var serverId = Connect.Accounts.FirstOrDefault()?.ServerId;
            if (string.IsNullOrWhiteSpace(serverId)) return;
            var albums = await _core.CallAsync<List<Album>>(new CoreRequest("genreAlbums")
            {
                ServerId = serverId,
                Genre = genre,
            }) ?? [];
            _detailGenreAlbums = albums;
            GenreAlbumGrid.Reset(albums);
            DetailMeta = GenrePresentation.Metadata(genre, albums);
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
            var page = await _core.CallAsync<AlbumPagePayload>(new CoreRequest("artistAppearsOn")
            {
                ServerId = artist.ServerId,
                ArtistRemoteId = artist.RemoteId,
                Limit = MediaDetailFormatting.ShelfPageSize,
            });
            return page?.Items.ToList() ?? [];
        }
        catch (MozzCoreException)
        {
            return [];
        }
    }

    private async Task<List<Track>> LoadArtistRadioAsync(Artist artist)
    {
        if (string.IsNullOrWhiteSpace(artist.RemoteId)) return [];
        try
        {
            var batch = await _core.CallAsync<RadioBatch>(new CoreRequest("radioBatch")
            {
                ServerId = artist.ServerId,
                Limit = PageSize,
                SeedTitle = $"{artist.Name} Radio",
                SeedGenres = artist.Genres,
                SeedArtistIds = [artist.RemoteId],
            });
            return batch?.Tracks.ToList() ?? [];
        }
        catch (MozzCoreException ex)
        {
            StatusMessage = $"Could not start radio: {ex.Message}";
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
        _detailPlaylistTracks = [];
        _detailGenreAlbums = [];
        GenreAlbumGrid.Reset([]);
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
                // Ordered by the same rule the phone uses, so the two apps can
                // never name different records as this artist's latest.
                if (MediaDetailFormatting.LatestRelease(
                        _detailArtistAlbums.Concat(_detailArtistSingles)) is { } latest)
                {
                    AddAlbumShelf(rows, "Latest Release", new[] { latest });
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

            case LibraryPageKind.MixDetail when _selectedMix is not null:
                var metadata = DetailMeta ?? string.Empty;
                rows.Add(new MixHeroRow(
                    _selectedMix,
                    metadata,
                    HomeMixPresentation.HeroSubtitle(_selectedMix, metadata)));
                if (_detailPlaylistTracks.Count > 0) rows.Add(new PlaylistTrackHeaderRow());
                rows.AddRange(_detailPlaylistTracks.Select(t => new PlaylistTrackItemRow(t)));
                break;
            case LibraryPageKind.GenreDetail:
                rows.Add(new GenreHeroRow(_navigation.Current.Genre ?? "Genre", DetailMeta ?? string.Empty));
                AddAlbumShelf(rows, "Albums", _detailGenreAlbums);
                break;
        }

        Replace(DetailRows, rows);
    }

    private void RebuildHomeRows()
    {
        if (_navigation.Current is not { Kind: LibraryPageKind.Section, Section: LibrarySection.Home })
        {
            HomeRows.Clear();
            return;
        }

        Replace(HomeRows, HomeComposition.BuildRows(
            _homeMixTiles,
            _homeRecentlyPlayed,
            _homeRecentlyAddedAlbums,
            _homePlaylists,
            Math.Min(2, ColumnsFor(DesktopLayout.HomeMixTilePitch)),
            ColumnsFor(DesktopLayout.TrackCardPitch),
            ColumnsFor(DesktopLayout.AlbumTilePitch),
            ColumnsFor(DesktopLayout.PlaylistTilePitch),
            _homeMessage));
    }

    private void AddAlbumShelf(List<DetailRow> rows, string title, IReadOnlyList<Album> albums)
    {
        if (albums.Count == 0) return;
        rows.Add(new DetailSectionRow(title));
        foreach (var row in MediaDetailFormatting.ChunkRows(albums, ColumnsFor(DesktopLayout.AlbumTilePitch)))
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
        foreach (var row in MediaDetailFormatting.ChunkRows(cards, ColumnsFor(DesktopLayout.TrackCardPitch)))
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
            await Task.Delay(SearchTiming.DebounceDelay, cts.Token);
            var results = await _core.CallAsync<SearchResults>(
                new CoreRequest("search") { Query = query, Limit = 50 }, cts.Token);
            if (cts.Token.IsCancellationRequested || results is null) return;
            var playlists = await SearchPlaylistsAsync(query, cts.Token);

            _navigation.Replace(LibraryPage.ForSection(LibrarySection.Search), clearBackStack: true);
            Section = LibrarySection.Search;
            _pagingGeneration++;
            _nextCursor = null;
            PageTitle = "Search";
            Replace(Tracks, results.Tracks);
            Replace(Albums, results.Albums);
            Replace(Artists, results.Artists);
            Replace(SearchRows, SearchPresentation.Build(results, playlists, query));
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

    private async Task<IReadOnlyList<Playlist>> SearchPlaylistsAsync(string query, CancellationToken token)
    {
        var serverId = Connect.Accounts.FirstOrDefault()?.ServerId;
        if (string.IsNullOrWhiteSpace(serverId)) return [];
        try
        {
            var page = await _core.CallPageAsync<List<Playlist>>(
                new CoreRequest("playlists") { ServerId = serverId, Limit = PageSize }, token);
            return SearchPresentation.Build(new SearchResults([], [], []), page.Rows, query)
                .OfType<SearchPlaylistRow>()
                .Select(r => r.Playlist)
                .ToList();
        }
        catch
        {
            return [];
        }
    }

    [RelayCommand]
    private async Task ToggleFavoriteAsync(Track? track)
    {
        if (track is null || !_core.IsOpen) return;
        var liked = !track.IsFavorite;
        ApplyTrackUpdate(track, t => t with { IsFavorite = liked, FavoritePending = true });
        try
        {
            var result = await _core.CallAsync<FavoriteMutationResult>(new CoreRequest("setFavorite")
            {
                ServerId = track.ServerId,
                RemoteId = track.RemoteId,
                Liked = liked,
                Flush = true,
            });
            ApplyTrackUpdate(track, t => t with
            {
                IsFavorite = result?.Liked ?? liked,
                FavoritePending = result is { Synced: false },
            });
            StatusMessage = result is { Synced: false, Queued: true }
                ? "Favorite queued — it will sync when the server is reachable."
                : null;
        }
        catch (Exception ex)
        {
            ApplyTrackUpdate(track, t => t with { IsFavorite = track.IsFavorite, FavoritePending = false });
            StatusMessage = $"Could not update favorite: {ex.Message}";
        }
    }

    [RelayCommand]
    private async Task RateNowPlayingAsync(string? value)
    {
        if (NowPlaying is not { } track || !_core.IsOpen) return;
        // Half-stars are real values in a library, so parse as a double and clamp
        // to the half-step range rather than rounding to whole stars on the way in.
        var rating = double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed)
            ? Math.Clamp(parsed, 0.5, 5.0)
            : (double?)null;
        ApplyTrackUpdate(track, t => t with { Rating = rating, RatingPending = true });
        try
        {
            var result = await _core.CallAsync<RatingMutationResult>(new CoreRequest("setRating")
            {
                ServerId = track.ServerId,
                RemoteId = track.RemoteId,
                Rating = rating,
                Flush = true,
            });
            ApplyTrackUpdate(track, t => t with
            {
                Rating = result?.Value ?? rating,
                RatingPending = result is { Synced: false },
            });
            StatusMessage = result is { Synced: false, Queued: true }
                ? "Rating queued — it will sync when the server is reachable."
                : null;
        }
        catch (Exception ex)
        {
            ApplyTrackUpdate(track, t => t with { Rating = track.Rating, RatingPending = false });
            StatusMessage = $"Could not update rating: {ex.Message}";
        }
    }

    private void ApplyTrackUpdate(Track original, Func<Track, Track> update)
    {
        static bool Same(Track a, Track b) => a.ServerId == b.ServerId && a.RemoteId == b.RemoteId;
        Track Update(Track current) => Same(current, original) ? update(current) : current;

        Replace(Tracks, Tracks.Select(Update).ToList());
        Replace(ArtistTracks, ArtistTracks.Select(Update).ToList());
        Replace(PlaylistTracks, PlaylistTracks.Select(Update).ToList());
        _homeRecentlyPlayed = _homeRecentlyPlayed.Select(Update).ToList();
        _detailArtistTopTracks = _detailArtistTopTracks.Select(Update).ToList();
        _detailPlaylistTracks = _detailPlaylistTracks.Select(Update).ToList();
        _detailAlbumTracks = _detailAlbumTracks
            .Select(row => row with { Track = Update(row.Track) })
            .ToList();
        _queue.ReplaceTracks(Update);
        if (NowPlaying is { } now && Same(now, original)) NowPlaying = Update(now);
        RefreshQueueRows();
        RebuildHomeRows();
        RebuildDetailRows();
        RaiseDerived();
    }

    private async Task LoadLyricsAsync(Track track, double positionSeconds)
    {
        LyricRows.Clear();
        LyricsMessage = null;
        LyricStatus = null;
        OnPropertyChanged(nameof(HasLyrics));
        OnPropertyChanged(nameof(ShowLyricsSilent));
        if (!_core.IsOpen) return;

        try
        {
            IsLyricsLoading = true;
            var payload = await _core.CallAsync<LyricsPayload>(new CoreRequest("lyrics")
            {
                ServerId = track.ServerId,
                RemoteId = track.RemoteId,
                UseLRCLIB = true,
                PositionSeconds = positionSeconds,
            });
            if (NowPlaying is null || NowPlaying.ServerId != track.ServerId || NowPlaying.RemoteId != track.RemoteId) return;
            LyricStatus = payload?.Status;
            if (payload?.Status == "silent")
            {
                LyricsMessage = "No lyrics for this track.";
                LyricRows.Clear();
                return;
            }

            var active = payload?.ActiveLineIndex ?? LyricLineSelector.ActiveIndex(payload?.Lyrics?.Lines, positionSeconds);
            Replace(LyricRows, LyricLineSelector.Rows(payload?.Lyrics?.Lines, active));
            LyricsMessage = LyricRows.Count == 0 ? "No lyrics for this track." : payload?.Lyrics?.SourceDisplayName;
        }
        catch (Exception ex)
        {
            LyricsMessage = $"Could not load lyrics: {ex.Message}";
        }
        finally
        {
            IsLyricsLoading = false;
            OnPropertyChanged(nameof(HasLyrics));
            OnPropertyChanged(nameof(ShowLyricsSilent));
        }
    }

    private void UpdateActiveLyric(double positionSeconds)
    {
        if (LyricRows.Count == 0) return;
        var lines = LyricRows.Select(r => new LyricLine(r.Text, r.StartSeconds)).ToList();
        var active = LyricLineSelector.ActiveIndex(lines, positionSeconds);
        Replace(LyricRows, LyricLineSelector.Rows(lines, active));
        OnPropertyChanged(nameof(HasLyrics));
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
    private void PlayHomeTrack(HomeTrackCard? card)
    {
        if (card is null) return;
        var context = _homeRecentlyPlayed;
        var index = context.IndexOf(card.Track);
        _ = StartQueueAsync(context.Count == 0 ? [card.Track] : context, index < 0 ? 0 : index);
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
    private void ShuffleSelectedArtist()
    {
        var context = ArtistTracks.OrderBy(_ => Random.Shared.Next()).ToList();
        if (context.Count > 0) _ = StartQueueAsync(context, 0);
    }

    [RelayCommand]
    private async Task StartSelectedArtistRadio()
    {
        if (SelectedArtist is null) return;
        var tracks = await LoadArtistRadioAsync(SelectedArtist);
        if (tracks.Count > 0) await StartQueueAsync(tracks, 0);
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
    private void PlaySelectedMix()
    {
        var context = PlaylistTracks.ToList();
        if (context.Count > 0) _ = StartQueueAsync(context, 0);
    }

    [RelayCommand]
    private void ShuffleSelectedMix()
    {
        var context = PlaylistTracks.OrderBy(_ => Random.Shared.Next()).ToList();
        if (context.Count > 0) _ = StartQueueAsync(context, 0);
    }

    [RelayCommand]
    private void PlayPlaylistTrack(Track? track)
    {
        if (track is null) return;
        var context = PlaylistTracks.ToList();
        int index = context.IndexOf(track);
        _ = StartQueueAsync(context.Count == 0 ? [track] : context, index < 0 ? 0 : index);
    }

    [RelayCommand]
    private void TogglePlayPause()
    {
        if (_engine is null || NowPlaying is null) return;
        switch (_engine.State)
        {
            case PlaybackState.Playing:
                _engine.Pause();
                _playHistory.PauseCurrent(CurrentPositionSeconds());
                IsPlaying = false;
                CheckpointContinuity(ContinuityCheckpointReason.TransportChanged);
                break;
            case PlaybackState.Paused:
                _engine.Resume();
                _playHistory.ResumeCurrent(CurrentPositionSeconds());
                IsPlaying = true;
                CheckpointContinuity(ContinuityCheckpointReason.TransportChanged);
                break;
            default:
                _ = PlayIndexAsync(_queue.CurrentIndex < 0 ? 0 : _queue.CurrentIndex);
                break;
        }
        _nowPlaying_os?.UpdateState(_engine.State);
    }

    [RelayCommand]
    private Task Next() => NextAsync();

    [RelayCommand]
    private Task Previous() => PreviousAsync();

    [RelayCommand]
    private void ToggleShuffle()
    {
        if (_queue.ToggleShuffle() == ShuffleMode.On) _queue.ShuffleUpcoming();
        RefreshQueueRows();
        OnPropertyChanged(nameof(ShuffleStateText));
        CheckpointContinuity(ContinuityCheckpointReason.QueueChanged);
    }

    [RelayCommand]
    private void CycleRepeat()
    {
        _queue.CycleRepeat();
        OnPropertyChanged(nameof(RepeatStateText));
        CheckpointContinuity(ContinuityCheckpointReason.QueueChanged);
    }

    [RelayCommand]
    private async Task JumpToQueueItem(QueueItemRow? row)
    {
        if (row is null || !_queue.JumpTo(row.Track, out var index)) return;
        await PlayIndexAsync(index);
    }

    [RelayCommand]
    private void MoveQueueItemUp(QueueItemRow? row)
    {
        if (row is null || !_queue.Move(row.Track, -1)) return;
        RefreshQueueRows();
        _ = PreloadNeighborAsync();
        CheckpointContinuity(ContinuityCheckpointReason.QueueChanged);
    }

    [RelayCommand]
    private void MoveQueueItemDown(QueueItemRow? row)
    {
        if (row is null || !_queue.Move(row.Track, 1)) return;
        RefreshQueueRows();
        _ = PreloadNeighborAsync();
        CheckpointContinuity(ContinuityCheckpointReason.QueueChanged);
    }

    [RelayCommand]
    private void RemoveQueueItem(QueueItemRow? row)
    {
        if (row is null || !_queue.Remove(row.Track)) return;
        RefreshQueueRows();
        _ = PreloadNeighborAsync();
        CheckpointContinuity(ContinuityCheckpointReason.QueueChanged);
    }

    private void RefreshQueueRows()
    {
        QueueProjection.ReplaceRows(QueueRows, _queue);
        OnPropertyChanged(nameof(HasQueue));
    }

    private async Task StartQueueAsync(IReadOnlyList<Track> tracks, int index)
        => await StartQueueAsync(tracks.Select((track, ordinal) => (track, ordinal)).ToList(), index, 0);

    private async Task StartQueueAsync(IReadOnlyList<(Track Track, int BaseOrdinal)> tracks, int index, double initialPositionSeconds)
    {
        SkipHistoryForCurrent();
        BeginContinuityRun();
        _queue.Start(tracks, index);
        RefreshQueueRows();
        await PlayIndexAsync(index, initialPositionSeconds);
    }

    private async Task PlayIndexAsync(int index, double initialPositionSeconds = 0)
    {
        if (_engine is null || index < 0 || index >= _queue.Tracks.Count) return;
        var track = _queue.Tracks[index];
        _queue.JumpTo(track, out _);
        RefreshQueueRows();

        // Resolving a source can spawn ffprobe or call the core, so keep it off
        // the UI thread.
        var source = await Task.Run(() => ResolveSource(track));
        if (source is null) return; // ResolveSource reported why.

        NowPlaying = track;
        _ = LoadLyricsAsync(track, 0);
        _ = LoadLyricsAsync(track, 0);
        DurationSeconds = source.KnownDuration?.TotalSeconds
            ?? (track.DurationSeconds > 0 ? track.DurationSeconds : 0);
        _suppressSeek = true;
        PositionSeconds = Math.Max(0, initialPositionSeconds);
        _suppressSeek = false;

        if (!_engine.Play(source, track)) return;
        StartHistoryFor(track);
        if (initialPositionSeconds > 0)
        {
            _engine.Seek(TimeSpan.FromSeconds(initialPositionSeconds));
            SeekHistoryForCurrent(initialPositionSeconds);
        }
        IsPlaying = true;
        CheckpointContinuity(ContinuityCheckpointReason.TrackChanged);

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
        var next = _queue.NextIndex();
        if (next is null || next.Value == _queue.CurrentIndex) return;
        var track = _queue.Tracks[next.Value];
        var source = await Task.Run(() => ResolveSource(track));
        if (source is not null) _engine.PreloadNext(source, track);
    }

    private async Task NextAsync()
    {
        SkipHistoryForCurrent();
        if (_queue.NextIndex() is { } next)
            await PlayIndexAsync(next);
        else
        {
            _engine?.Stop();
            IsPlaying = false;
            CheckpointContinuity(ContinuityCheckpointReason.TransportChanged);
        }
    }

    private async Task PreviousAsync()
    {
        if (_engine is null) return;
        // Standard behaviour: restart the track unless we're near its start.
        if (_engine.Position.TotalSeconds > 3 || _queue.PreviousIndex() is null)
        {
            _engine.Seek(TimeSpan.Zero);
            SeekHistoryForCurrent(0);
            _suppressSeek = true;
            PositionSeconds = 0;
            _suppressSeek = false;
            CheckpointContinuity(ContinuityCheckpointReason.Seeked);
        }
        else
        {
            SkipHistoryForCurrent();
            await PlayIndexAsync(_queue.PreviousIndex()!.Value);
        }
    }

    private void StopPlayback()
    {
        SkipHistoryForCurrent();
        _engine?.Stop();
        IsPlaying = false;
        _nowPlaying_os?.UpdateState(PlaybackState.Stopped);
        CheckpointContinuity(ContinuityCheckpointReason.TransportChanged);
    }

    [RelayCommand]
    private async Task ContinueHereAsync()
    {
        var offer = ContinuityOffer;
        var account = ActiveAccount;
        if (offer is null || account is null) return;

        var tracks = ContinuityPresentation.TracksForResume(offer.Snapshot, account.ServerId);
        if (tracks.Count == 0) return;

        ContinuityOffer = null;
        var index = ContinuityPresentation.ResumeIndex(offer.Snapshot, tracks.Count);
        await StartQueueAsync(tracks, index, offer.Snapshot.Cursor.PositionMS / 1000.0);
    }

    [RelayCommand]
    private void DismissContinuityOffer() => ContinuityOffer = null;

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
        _playHistory.ProgressCurrent(PositionSeconds);
        UpdateActiveLyric(PositionSeconds);
        CheckpointContinuity(ContinuityCheckpointReason.Periodic);

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
        SeekHistoryForCurrent(_pendingSeek);
        CheckpointContinuity(ContinuityCheckpointReason.Seeked);
    }

    partial void OnDurationSecondsChanged(double value) => OnPropertyChanged(nameof(DurationText));

    partial void OnIsPlayingChanged(bool value)
    {
        OnPropertyChanged(nameof(PlayPauseGlyph));
        _nowPlaying_os?.UpdateState(value ? PlaybackState.Playing : PlaybackState.Paused);
        if (value) ContinuityOffer = null;
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
            CompleteHistoryForCurrent();
            var changedTrack = NowPlaying?.RemoteId != track.RemoteId;
            NowPlaying = track;
            _queue.JumpTo(track, out _);
            RefreshQueueRows();
            DurationSeconds = _engine?.Duration.TotalSeconds is > 0 and var d ? d : track.DurationSeconds;
            _suppressSeek = true;
            PositionSeconds = 0;
            _suppressSeek = false;
            IsPlaying = true;
            StartHistoryFor(track);
            _nowPlaying_os?.UpdateMetadata(new NowPlayingMetadata(
                track.Title, track.ArtistName, track.AlbumTitle,
                _engine?.Duration ?? TimeSpan.FromSeconds(track.DurationSeconds)));
            if (changedTrack) CheckpointContinuity(ContinuityCheckpointReason.TrackChanged);
            _ = PreloadNeighborAsync();
        });
    }

    private void OnEnginePlaybackEnded(object? sender, EventArgs e)
    {
        Dispatcher.UIThread.Post(() =>
        {
            CompleteHistoryForCurrent();
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
                int i = _queue.Tracks.ToList().IndexOf(track);
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

    private sealed record PendingContinuityCheckpoint(
        long Generation,
        ServerAccount Account,
        Guid RunId,
        ulong Sequence,
        long CapturedAtMS,
        string State,
        string CurrentRemoteID,
        int CurrentAbsoluteIndex,
        long PositionMS,
        ContinuityQueueInput Queue,
        ContinuityCheckpointReason Reason);

    private void RaiseDerived()
    {
        OnPropertyChanged(nameof(CanGoBack));
        OnPropertyChanged(nameof(IsHomeSelected));
        OnPropertyChanged(nameof(IsSongsSelected));
        OnPropertyChanged(nameof(IsAlbumsSelected));
        OnPropertyChanged(nameof(IsArtistsSelected));
        OnPropertyChanged(nameof(IsGenresSelected));
        OnPropertyChanged(nameof(IsPlaylistsSelected));
        OnPropertyChanged(nameof(IsConnectSelected));
        OnPropertyChanged(nameof(IsSettingsSelected));
        OnPropertyChanged(nameof(ShowTracks));
        OnPropertyChanged(nameof(ShowHomeRows));
        OnPropertyChanged(nameof(ShowHomeEmpty));
        OnPropertyChanged(nameof(ShowAlbums));
        OnPropertyChanged(nameof(ShowArtists));
        OnPropertyChanged(nameof(ShowGenres));
        OnPropertyChanged(nameof(ShowPlaylists));
        OnPropertyChanged(nameof(ShowSearch));
        OnPropertyChanged(nameof(ShowConnect));
        OnPropertyChanged(nameof(ShowSettings));
        OnPropertyChanged(nameof(ShowAlbumDetail));
        OnPropertyChanged(nameof(ShowArtistDetail));
        OnPropertyChanged(nameof(ShowPlaylistDetail));
        OnPropertyChanged(nameof(ShowMixDetail));
        OnPropertyChanged(nameof(ShowGenreDetail));
        OnPropertyChanged(nameof(ShowNowPlaying));
        OnPropertyChanged(nameof(ShowDetailPage));
        OnPropertyChanged(nameof(HasSearchRows));
        OnPropertyChanged(nameof(HasQueue));
        OnPropertyChanged(nameof(HasLyrics));
        OnPropertyChanged(nameof(ShowLyricsSilent));
        OnPropertyChanged(nameof(ShuffleStateText));
        OnPropertyChanged(nameof(RepeatStateText));
        OnPropertyChanged(nameof(HasArtistAlbums));
        OnPropertyChanged(nameof(IsLibraryEmpty));
        OnPropertyChanged(nameof(LibrarySummary));
        OnPropertyChanged(nameof(ActiveAccount));
        OnPropertyChanged(nameof(HasActiveAccount));
        OnPropertyChanged(nameof(SidebarProfileTitle));
        OnPropertyChanged(nameof(SidebarProfileSubtitle));
        OnPropertyChanged(nameof(ActiveAccountAvatarUrl));
        OnPropertyChanged(nameof(HasActiveAccountAvatar));
        OnPropertyChanged(nameof(ActiveAccountFallbackText));
        OnPropertyChanged(nameof(ActiveServerTitle));
        OnPropertyChanged(nameof(ActiveServerSubtitle));
    }

    private static void Replace<T>(ObservableCollection<T> target, IReadOnlyList<T>? source)
    {
        target.Clear();
        if (source is null) return;
        foreach (var item in source) target.Add(item);
    }

    public void Dispose()
    {
        if (_themeObserverAttached && Avalonia.Application.Current is { } app)
            app.ActualThemeVariantChanged -= OnActualThemeVariantChanged;
        _positionTimer?.Stop();
        _seekDebounce?.Stop();
        _continuityReconcileTimer?.Stop();
        _continuityFlushCts?.Cancel();
        _continuityFlushCts?.Dispose();
        _engine?.Dispose();
        _nowPlaying_os?.Dispose();
        _artwork?.Dispose();
        _core.Dispose();
    }
}
