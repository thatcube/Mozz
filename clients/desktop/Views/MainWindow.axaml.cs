using System.Linq;
using Avalonia;
using Avalonia.VisualTree;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Mozz.Desktop.Core;
using Mozz.Desktop.ViewModels;

namespace Mozz.Desktop.Views;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
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