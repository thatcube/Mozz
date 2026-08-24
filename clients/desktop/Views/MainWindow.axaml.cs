using Avalonia.Controls;
using Avalonia.Input;
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
}