using System.Linq;
using Avalonia;
using Avalonia.VisualTree;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
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
        Opened += (_, _) => ApplyLayoutForWidth(Bounds.Width);
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

        // Full now-playing can afford two columns. At compact width the artwork
        // and metadata stack so the scrubber and queue do not become horizontal
        // scroll traps inside the page.
        NowPlayingHeroGrid.ColumnDefinitions = compact
            ? new ColumnDefinitions("*")
            : new ColumnDefinitions("320,*");
        NowPlayingHeroGrid.RowDefinitions = compact
            ? new RowDefinitions("Auto,Auto")
            : new RowDefinitions("Auto");
        Grid.SetColumn(NowPlayingText, compact ? 0 : 1);
        Grid.SetRow(NowPlayingText, compact ? 1 : 0);
        NowPlayingText.Margin = compact ? new Thickness(0, 16, 0, 0) : new Thickness(0);

        NowPlayingLowerGrid.ColumnDefinitions = compact
            ? new ColumnDefinitions("*")
            : new ColumnDefinitions("*,*");
        NowPlayingLowerGrid.RowDefinitions = compact
            ? new RowDefinitions("Auto,Auto")
            : new RowDefinitions("Auto");
        Grid.SetColumn(NowPlayingQueuePanel, compact ? 0 : 1);
        Grid.SetRow(NowPlayingQueuePanel, compact ? 1 : 0);
        NowPlayingQueuePanel.Margin = compact ? new Thickness(0, 16, 0, 0) : new Thickness(0);
    }

    private void ApplyTransportLayout(DesktopLayoutTier tier)
    {
        var expanded = tier == DesktopLayoutTier.Expanded;
        var compact = tier == DesktopLayoutTier.Compact;

        BottomTransportGrid.ColumnDefinitions = expanded
            ? new ColumnDefinitions("*,Auto,*")
            : new ColumnDefinitions("*,Auto,0");
        BottomTransportBar.Height = compact ? 76 : 88;
        BottomVolumeControls.IsVisible = expanded;

        // Shuffle, repeat and volume are useful, but they are secondary. When the
        // bar narrows, preserving the track identity and the play/skip cluster
        // avoids the failure mode where the player is still visible but cannot
        // actually be driven.
        BottomShuffleButton.IsVisible = expanded;
        BottomRepeatButton.IsVisible = expanded;
        BottomPositionRow.IsVisible = !compact;
        BottomScrubber.Width = expanded ? 420 : 240;
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
    }
}