using Avalonia.Controls;
using Avalonia.Markup.Xaml;
using Mozz.Desktop.ViewModels;

namespace Mozz.Desktop.Views;

public partial class PairingWindow : Window
{
    public PairingWindow()
    {
        InitializeComponent();
        // Discovery starts when the window opens and stops when it closes, so
        // the app is not sending multicast queries for the rest of the session.
        Opened += (_, _) => (DataContext as PairingViewModel)?.StartWatching();
        Closed += (_, _) => (DataContext as PairingViewModel)?.StopWatching();
    }

    private void InitializeComponent() => AvaloniaXamlLoader.Load(this);
}
