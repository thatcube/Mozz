using Avalonia.Controls.ApplicationLifetimes;
using Mozz.Desktop.ViewModels;

namespace Mozz.Desktop;

public partial class App
{
    private void OnSettingsMozz(object? sender, System.EventArgs e)
    {
        if (ApplicationLifetime is not IClassicDesktopStyleApplicationLifetime { MainWindow: { } owner })
            return;

        owner.Activate();
        if (owner.DataContext is MainViewModel vm)
            _ = vm.OpenSettingsCommand.ExecuteAsync(null);
    }

    private void OnPairDevice(object? sender, System.EventArgs e) => ShowPairingWindow();

    /// <summary>
    /// Opened from Settings → Devices, and from the menu.
    ///
    /// It lives in Settings because that is where someone looks for it — the
    /// phone puts it there, and a menu item was somewhere only I knew about.
    /// </summary>
    internal void ShowPairingWindow()
    {
        if (ApplicationLifetime is not IClassicDesktopStyleApplicationLifetime { MainWindow: { } owner })
            return;
        if (owner.DataContext is not MainViewModel vm) return;

        var window = new Views.PairingWindow
        {
            DataContext = new PairingViewModel(vm.Core),
        };
        // Re-read the roster when it closes, so a device added in that window
        // appears in Settings without reopening it.
        window.Closed += (_, _) => vm.RefreshCircle();
        window.ShowDialog(owner);
    }
}
