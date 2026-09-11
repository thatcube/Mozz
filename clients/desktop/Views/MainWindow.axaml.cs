using System.Collections.Specialized;
using System.Linq;
using Avalonia;
using Avalonia.VisualTree;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media.Transformation;
using Mozz.Desktop.Core;
using Mozz.Desktop.ViewModels;

namespace Mozz.Desktop.Views;

public partial class MainWindow : Window
{
    private DesktopLayoutTier _layoutTier = DesktopLayoutTier.Expanded;
    private bool _compactNavigationOpen;

    public MainWindow()
    {
        InitializeComponent();
        Opened += (_, _) =>
        {
            ApplyLayoutForWidth(Bounds.Width);
            ObserveLyrics();
        };
        DataContextChanged += (_, _) => ObserveLyrics();
    }

    /// <summary>
    /// The keys a desktop music player is expected to answer to.
    /// </summary>
    /// <remarks>
    /// There were none at all: not space, not the arrow keys, nothing. Every
    /// command below already existed and was reachable only by aiming a mouse
    /// at a small round button, which is not how anybody uses a player on a
    /// computer while doing something else.
    ///
    /// Deliberately the shortcuts people already know from other players rather
    /// than a set of our own — space, arrows, M, S, R — because a shortcut you
    /// have to learn is one you will not use.
    /// </remarks>
    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (e.Handled || DataContext is not MainViewModel model) return;

        // Somebody typing a search query is not asking to pause the music. Any
        // text field swallows the whole set, not just the letters, because
        // space and the arrows mean something inside a text box too.
        if (FocusManager?.GetFocusedElement() is TextBox) return;

        var command = e.KeyModifiers.HasFlag(KeyModifiers.Meta)
                      || e.KeyModifiers.HasFlag(KeyModifiers.Control);

        switch (e.Key)
        {
            case Key.Space:
                model.TogglePlayPauseCommand.Execute(null);
                break;

            // Arrows alone scrub, with the platform's command key they skip.
            // The pairing matches every other player: the small move is the
            // cheap key and the big one asks for a modifier.
            case Key.Right when command:
                model.NextCommand.Execute(null);
                break;
            case Key.Left when command:
                model.PreviousCommand.Execute(null);
                break;
            case Key.Right:
                model.SeekSeconds(SeekStepSeconds);
                break;
            case Key.Left:
                model.SeekSeconds(-SeekStepSeconds);
                break;

            case Key.Up:
                model.Volume = System.Math.Clamp(model.Volume + VolumeStep, 0, 1);
                break;
            case Key.Down:
                model.Volume = System.Math.Clamp(model.Volume - VolumeStep, 0, 1);
                break;

            case Key.M:
                model.ToggleMuteCommand.Execute(null);
                break;
            case Key.S:
                model.ToggleShuffleCommand.Execute(null);
                break;
            case Key.R:
                model.CycleRepeatCommand.Execute(null);
                break;

            case Key.F when command:
                SidebarSearch.Focus();
                SidebarSearch.SelectAll();
                break;

            // The sidebar in order, the way every desktop player numbers its
            // own. Reaching Albums should not require finding a small target
            // with a mouse when the list it opens is the app's whole point.
            case >= Key.D1 and <= Key.D7 when command:
                model.SelectSectionCommand.Execute(NumberedSections[e.Key - Key.D1]);
                break;

            default:
                return;
        }

        // Only reached when something above ran, so a key this does not claim
        // still reaches the list underneath it.
        e.Handled = true;
    }

    /// <summary>
    /// What ⌘1 through ⌘7 open, top to bottom as the sidebar lists them.
    ///
    /// Search is deliberately absent: it has ⌘F, which is where every other
    /// application puts it, and giving it a number as well would push the rest
    /// out of step with the list somebody is looking at.
    /// </summary>
    private static readonly LibrarySection[] NumberedSections =
    [
        LibrarySection.Home,
        LibrarySection.Songs,
        LibrarySection.Albums,
        LibrarySection.Artists,
        LibrarySection.Genres,
        LibrarySection.Playlists,
        LibrarySection.Downloads,
    ];

    /// <summary>How far an arrow key moves the play head.</summary>
    private const double SeekStepSeconds = 5;

    /// <summary>How much an arrow key moves the volume.</summary>
    private const double VolumeStep = 0.05;

    /// <summary>
    /// Moves the one settings control tree into a native window.
    /// </summary>
    public Control TakeSettingsSurface()
    {
        SettingsParkingLot.Children.Remove(SettingsSurface);
        return SettingsSurface;
    }

    /// <summary>
    /// Returns settings to its hidden parking place after the native window
    /// closes, ready to be opened again without rebuilding its controls.
    /// </summary>
    public void ReturnSettingsSurface(Control surface)
    {
        if (surface.Parent is Panel parent)
        {
            parent.Children.Remove(surface);
        }
        SettingsParkingLot.Children.Add(surface);
    }

    private void OnWindowResized(object? sender, SizeChangedEventArgs e)
    {
        ApplyLayoutForWidth(e.NewSize.Width);
    }

    private void ApplyLayoutForWidth(double width)
    {
        var tier = DesktopLayout.TierForWindowWidth(width);
        ApplyLayoutTier(tier);
    }

    private void ApplyLayoutTier(DesktopLayoutTier tier)
    {
        _layoutTier = tier;

        Classes.Set("expanded", tier == DesktopLayoutTier.Expanded);
        Classes.Set("medium", tier == DesktopLayoutTier.Medium);
        Classes.Set("compact", tier == DesktopLayoutTier.Compact);

        var sidebarInFlow = tier != DesktopLayoutTier.Compact;
        SidebarPane.IsVisible = sidebarInFlow;
        MainContentGrid.ColumnDefinitions[0].Width = tier switch
        {
            DesktopLayoutTier.Expanded => new GridLength(DesktopLayout.ExpandedSidebarWidth),
            DesktopLayoutTier.Medium => new GridLength(DesktopLayout.MediumSidebarWidth),
            _ => new GridLength(0)
        };

        CompactNavigationButton.IsVisible = tier == DesktopLayoutTier.Compact;
        if (tier != DesktopLayoutTier.Compact) _compactNavigationOpen = false;
        CompactNavigationLayer.IsVisible = tier == DesktopLayoutTier.Compact && _compactNavigationOpen;

        // The medium rail keeps navigation one click away while giving the
        // content pane back roughly one album column. Compact removes the rail
        // entirely because a permanent strip at that width forces detail pages
        // and track rows to choose between clipping and uselessly narrow text.
        var iconOnly = tier == DesktopLayoutTier.Medium;
        foreach (var control in IconOnlySidebarText()) control.IsVisible = !iconOnly;
        SidebarInterior.Margin = iconOnly ? new Thickness(8, 18, 8, 14) : new Thickness(14, 18, 14, 14);
        SidebarHeader.HorizontalAlignment = iconOnly ? HorizontalAlignment.Center : HorizontalAlignment.Stretch;
        foreach (var button in SidebarNavigationButtons())
        {
            button.Padding = iconOnly ? new Thickness(11, 9) : new Thickness(12, 9);
            button.HorizontalContentAlignment = iconOnly ? HorizontalAlignment.Center : HorizontalAlignment.Left;
        }

        ApplyNowPlayingPageLayout(tier);
        ApplyTransportLayout(tier);
    }

    private void ApplyNowPlayingPageLayout(DesktopLayoutTier tier)
    {
        var compact = tier == DesktopLayoutTier.Compact;

        // The hero is one centred column at every width now, so there is no
        // reflow left to do for it: the cover, the title and the transport are
        // already stacked, and the Viewbox shrinks the cover rather than letting
        // the row overflow. Only the lower half still has two columns to fold.
        // Queue and lyrics share one slot beside the hero, so there is no
        // two-column lower half left to fold. At compact width the panel would
        // leave the hero nothing, so it steps aside entirely.
        NowPlayingLowerGrid.IsVisible = !compact;
        NowPlayingLowerGrid.Width = tier == DesktopLayoutTier.Expanded ? 380 : 320;
    }

    private void ApplyTransportLayout(DesktopLayoutTier tier)
    {
        var expanded = tier == DesktopLayoutTier.Expanded;
        var compact = tier == DesktopLayoutTier.Compact;

        BottomTransportGrid.ColumnDefinitions = expanded
            ? new ColumnDefinitions("*,Auto,*")
            : new ColumnDefinitions("*,Auto,0");
        // The cover sets the height: it fills the pill less an even inset on
        // every side, and the transport plus the scrubber sit alongside it.
        BottomTransportBar.Height = compact ? 84 : 96;
        BottomVolumeControls.IsVisible = expanded;

        // Shuffle, repeat and volume are useful, but they are secondary. When the
        // bar narrows, preserving the track identity and the play/skip cluster
        // avoids the failure mode where the player is still visible but cannot
        // actually be driven.
        BottomShuffleButton.IsVisible = expanded;
        BottomRepeatButton.IsVisible = expanded;
        BottomScrubber.IsVisible = !compact;
        BottomScrubber.Width = expanded ? 400 : 280;
        NowPlayingSummaryText.MaxWidth = expanded ? 270 : compact ? 160 : 260;
    }

    private Control[] IconOnlySidebarText() =>
    [
        SidebarTitle,
        SidebarSearch,
        SidebarLibraryCard,
        LblHome,
        LblSongs,
        LblAlbums,
        LblArtists,
        LblGenres,
        LblPlaylists,
        SidebarProfileText
    ];

    private Button[] SidebarNavigationButtons() =>
    [
        NavHome,
        NavSongs,
        NavAlbums,
        NavArtists,
        NavGenres,
        NavPlaylists,
        NavSettings
    ];

    private void OnCompactNavigationButtonClicked(object? sender, RoutedEventArgs e)
    {
        if (_layoutTier != DesktopLayoutTier.Compact) return;
        _compactNavigationOpen = true;
        CompactNavigationLayer.IsVisible = true;
    }

    private void OnCompactNavigationCloseClicked(object? sender, RoutedEventArgs e)
    {
        _compactNavigationOpen = false;
        CompactNavigationLayer.IsVisible = false;
    }

    // Double-clicking a row starts playback. Kept in code-behind because it is a
    // pure view gesture (double-tap → command); the queue logic lives in the VM.
    private void OnTrackActivated(object? sender, TappedEventArgs e)
    {
        if (DataContext is MainViewModel vm &&
            sender is ListBox { SelectedItem: Track track } &&
            vm.PlayTrackCommand.CanExecute(track))
        {
            vm.PlayTrackCommand.Execute(track);
        }
    }

    private void OnAlbumTrackActivated(object? sender, TappedEventArgs e)
    {
        if (DataContext is MainViewModel vm &&
            sender is ListBox { SelectedItem: AlbumTrackRow row } &&
            vm.PlayAlbumTrackCommand.CanExecute(row))
        {
            vm.PlayAlbumTrackCommand.Execute(row);
        }
    }

    private void OnArtistTrackActivated(object? sender, TappedEventArgs e)
    {
        if (DataContext is MainViewModel vm &&
            sender is ListBox { SelectedItem: Track track } &&
            vm.PlayArtistTrackCommand.CanExecute(track))
        {
            vm.PlayArtistTrackCommand.Execute(track);
        }
    }

    private void OnDetailRowActivated(object? sender, TappedEventArgs e)
    {
        if (DataContext is not MainViewModel vm || sender is not ListBox { SelectedItem: { } item }) return;

        switch (item)
        {
            case AlbumTrackItemRow { Row: var row } when vm.PlayAlbumTrackCommand.CanExecute(row):
                vm.PlayAlbumTrackCommand.Execute(row);
                break;
            case PlaylistTrackItemRow { Track: var track } when vm.PlayPlaylistTrackCommand.CanExecute(track):
                vm.PlayPlaylistTrackCommand.Execute(track);
                break;
        }
    }

    private void OnSearchRowActivated(object? sender, TappedEventArgs e)
    {
        if (DataContext is not MainViewModel vm || sender is not ListBox { SelectedItem: { } item }) return;

        switch (item)
        {
            case SearchTrackRow { Track: var track } when vm.PlayTrackCommand.CanExecute(track):
                vm.PlayTrackCommand.Execute(track);
                break;
            case SearchAlbumRow { Album: var album } when vm.OpenAlbumCommand.CanExecute(album):
                vm.OpenAlbumCommand.Execute(album);
                break;
            case SearchArtistRow { Artist: var artist } when vm.OpenArtistCommand.CanExecute(artist):
                vm.OpenArtistCommand.Execute(artist);
                break;
            case SearchPlaylistRow { Playlist: var playlist } when vm.OpenPlaylistCommand.CanExecute(playlist):
                vm.OpenPlaylistCommand.Execute(playlist);
                break;
        }
    }

    private void OnQueueRowActivated(object? sender, TappedEventArgs e)
    {
        if (DataContext is MainViewModel vm &&
            sender is ListBox { SelectedItem: QueueItemRow row } &&
            vm.JumpToQueueItemCommand.CanExecute(row))
        {
            vm.JumpToQueueItemCommand.Execute(row);
        }
    }

    /// <summary>
    /// Tell the view model how much width the tiles have, so it can chunk the
    /// album and artist walls into rows of the right length. Layout drives this
    /// rather than the view model guessing, and the setter ignores sub-pixel
    /// churn so a resize does not rebuild the grid on every frame.
    /// </summary>
    private void OnContentResized(object? sender, SizeChangedEventArgs e)
    {
        if (DataContext is MainViewModel vm) vm.ContentWidth = e.NewSize.Width;
    }

    /// <summary>
    /// Append the next page as the reader nears the end of a list.
    ///
    /// Wired to every scrolling pane's <c>ScrollChanged</c>. The threshold is a
    /// viewport rather than a fixed number of pixels: on a tall window a page
    /// has to arrive earlier to stay ahead of the scroll, and on a short one an
    /// absolute margin would fetch far too eagerly.
    ///
    /// Safe to fire often — <see cref="MainViewModel.LoadMoreAsync"/> ignores a
    /// call while one is in flight or once the end has been reached.
    ///
    /// The handler is attached in XAML as <c>ScrollViewer.ScrollChanged</c> on
    /// the ListBox, and ScrollChanged is a bubbling routed event, so `sender` is
    /// the ListBox the handler was registered on — never the ScrollViewer that
    /// raised it. Testing `sender is ScrollViewer` therefore returned early on
    /// every scroll, and no list ever loaded a second page: the library simply
    /// stopped at 200 rows with nothing to indicate why. The ScrollViewer comes
    /// from the event's source instead.
    /// </summary>
    private void OnListScrolled(object? sender, ScrollChangedEventArgs e)
    {
        if (DataContext is not MainViewModel vm) return;

        var viewer = e.Source as ScrollViewer
                     ?? (sender as Visual)?.GetVisualDescendants().OfType<ScrollViewer>().FirstOrDefault();
        if (viewer is null) return;

        var remaining = viewer.Extent.Height - viewer.Offset.Y - viewer.Viewport.Height;
        if (remaining <= viewer.Viewport.Height) _ = vm.LoadMoreAsync();

        RevealTitleForScroll(vm, viewer.Offset.Y);
    }

    // MARK: The page title
    //
    // On a detail page the hero already names the subject in larger type just
    // below the bar, so showing the same words in both is saying it twice. The
    // bar holds the name back until the hero has scrolled away, and then takes
    // it over — which is also the point at which the reader has lost the only
    // other thing telling them where they are.

    /// <summary>Scroll offset at which the bar title starts to arrive.</summary>
    private const double TitleRevealStart = 90;

    /// <summary>And the offset by which it is fully there.</summary>
    private const double TitleRevealEnd = 170;

    private void RevealTitleForScroll(MainViewModel vm, double offsetY)
    {
        if (!vm.ShowDetailPage)
        {
            // A list page has no hero to compete with, so its title is simply
            // always there.
            PageTitleText.Opacity = 1;
            return;
        }

        var span = TitleRevealEnd - TitleRevealStart;
        PageTitleText.Opacity = Math.Clamp((offsetY - TitleRevealStart) / span, 0, 1);
    }

    /// <summary>
    /// The player's star strip committed a rating.
    /// </summary>
    /// <remarks>
    /// A plain event rather than a command binding: the strip reports a
    /// <c>double?</c>, and a XAML CommandParameter is text — which is exactly
    /// why the old control was five buttons each carrying a literal whole
    /// number and could never say 3.5.
    /// </remarks>
    private void OnNowPlayingRated(object? sender, double? rating)
    {
        if (DataContext is MainViewModel vm) _ = vm.RateNowPlayingAsync(rating);
    }

    // MARK: The lyrics column
    //
    // The column keeps the line being sung a third of the way down rather than
    // wherever the reader last left the scroll, which is the whole reason to
    // show timed lyrics at all. The phones get this from a list that can scroll
    // to an item at a given anchor; Avalonia's ScrollViewer only takes an
    // offset, so the offset is worked out here.

    /// <summary>
    /// Drives the eased scroll. A ScrollViewer moves instantly when its Offset
    /// is set, and a column of words that teleports once a line reads as a
    /// glitch — so the offset is walked to its target over
    /// <see cref="LyricScrollDuration"/> instead.
    /// </summary>
    private Avalonia.Threading.DispatcherTimer? _lyricScrollTimer;
    private double _lyricScrollFrom;
    private double _lyricScrollTo;
    private DateTime _lyricScrollStarted;
    private MainViewModel? _observedModel;

    private static readonly TimeSpan LyricScrollDuration = TimeSpan.FromMilliseconds(450);

    /// <summary>
    /// Watch the view model for the line being sung. Done by hand rather than
    /// with a binding because the answer is a scroll offset, which needs the
    /// measured height of a container the binding system knows nothing about.
    /// </summary>
    private void ObserveLyrics()
    {
        if (ReferenceEquals(_observedModel, DataContext)) return;
        if (_observedModel is not null)
        {
            _observedModel.PropertyChanged -= OnModelPropertyChanged;
            _observedModel.LyricRows.CollectionChanged -= OnLyricRowsChanged;
        }
        _observedModel = DataContext as MainViewModel;
        if (_observedModel is not null)
        {
            _observedModel.PropertyChanged += OnModelPropertyChanged;
            // A new song's lines arrive as a collection change, and the index
            // that comes with them is often unchanged from the last song's — so
            // waiting for the index alone left a column resumed from the middle
            // pinned to its first line until the singer reached the next one.
            _observedModel.LyricRows.CollectionChanged += OnLyricRowsChanged;
        }
    }

    private void OnLyricRowsChanged(object? sender, NotifyCollectionChangedEventArgs e) => ScrollLyricsToActive();

    private void OnModelPropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(MainViewModel.ActiveLyricIndex)) ScrollLyricsToActive();
        // A new page starts at the top of its own scroll, so the bar has to give
        // the title back — otherwise opening a detail page from one already
        // scrolled would show its name twice again.
        if (e.PropertyName is nameof(MainViewModel.PageTitle) && sender is MainViewModel vm)
        {
            RevealTitleForScroll(vm, 0);
            PlayPageEntrance();
        }
    }

    /// <summary>
    /// Fade and lift the content pane as a new page takes it over.
    ///
    /// Driven from the title rather than from the section, because the section
    /// does not change when you open an album from the album grid — and that is
    /// exactly the move that most needs to say something happened.
    ///
    /// The transition is declared on the Panel, so this only has to set the
    /// starting state and hand back the resting one; Avalonia animates between
    /// the two. The hand-back is posted rather than immediate because both
    /// values would otherwise be applied in the same layout pass, and a
    /// transition between a value and itself is nothing at all.
    /// </summary>
    private void PlayPageEntrance()
    {
        ContentPane.Opacity = 0;
        ContentPane.RenderTransform = TransformOperations.Parse("translateY(10px)");
        Avalonia.Threading.Dispatcher.UIThread.Post(
            () =>
            {
                ContentPane.Opacity = 1;
                ContentPane.RenderTransform = TransformOperations.Parse("translateY(0px)");
            },
            Avalonia.Threading.DispatcherPriority.Background);
    }

    /// <summary>
    /// Put the active line in the focus slot.
    ///
    /// The lead and tail pads are sized here too, and from the viewport: without
    /// them the first line can never rise to the focus slot and the last can
    /// never reach it either, so the column would snap to the top at the start
    /// of a song and stop following near the end of one.
    /// </summary>
    /// <summary>
    /// Seat the column on the active line, after the next layout pass.
    ///
    /// Deferred because the two things that ask for it — a fresh set of lines
    /// and a change of viewport — both arrive before the containers being
    /// measured exist, and measuring one that has not been realised yet scrolls
    /// nowhere at all.
    /// </summary>
    private void ScrollLyricsToActive() =>
        Avalonia.Threading.Dispatcher.UIThread.Post(SeatLyricColumn, Avalonia.Threading.DispatcherPriority.Loaded);

    private void SeatLyricColumn()
    {
        if (DataContext is not MainViewModel vm) return;
        var scroller = LyricsScroller;
        var viewport = scroller.Viewport.Height;
        if (viewport <= 0) return;

        var focusOffset = viewport * LyricDepth.FocusAnchor;
        LyricsLeadPad.Height = Math.Max(0, focusOffset - 24);
        LyricsTailPad.Height = Math.Max(0, viewport - focusOffset);

        if (vm.ActiveLyricIndex is not { } index) return;
        if (LyricsLines.ContainerFromIndex(index) is not Control container) return;

        var top = container.TranslatePoint(new Point(0, 0), LyricsColumn);
        if (top is not { } point) return;

        var target = Math.Clamp(
            point.Y - focusOffset,
            0,
            Math.Max(0, scroller.Extent.Height - viewport));
        AnimateLyricScroll(target);
    }

    private void AnimateLyricScroll(double target)
    {
        var current = LyricsScroller.Offset.Y;
        if (Math.Abs(target - current) < 0.5) return;

        _lyricScrollFrom = current;
        _lyricScrollTo = target;
        _lyricScrollStarted = DateTime.UtcNow;

        if (_lyricScrollTimer is null)
        {
            _lyricScrollTimer = new Avalonia.Threading.DispatcherTimer
            {
                Interval = TimeSpan.FromMilliseconds(16),
            };
            _lyricScrollTimer.Tick += OnLyricScrollTick;
        }
        _lyricScrollTimer.Start();
    }

    private void OnLyricScrollTick(object? sender, EventArgs e)
    {
        var elapsed = DateTime.UtcNow - _lyricScrollStarted;
        var t = Math.Clamp(elapsed.TotalMilliseconds / LyricScrollDuration.TotalMilliseconds, 0, 1);
        // Ease out: leaves quickly, settles gently, which is how the eye expects
        // a column of text to come to rest.
        var eased = 1 - Math.Pow(1 - t, 3);
        var y = _lyricScrollFrom + (_lyricScrollTo - _lyricScrollFrom) * eased;
        LyricsScroller.Offset = LyricsScroller.Offset.WithY(y);
        if (t >= 1) _lyricScrollTimer?.Stop();
    }

    /// <summary>
    /// Re-seat the column when the panel is resized: the focus slot is a
    /// fraction of the viewport, so a taller window moves it.
    /// </summary>
    private void OnLyricsScrollerSizeChanged(object? sender, SizeChangedEventArgs e) => ScrollLyricsToActive();
}
