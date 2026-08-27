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

    private void OnPairDevice(object? sender, System.EventArgs e)
    {
        if (ApplicationLifetime is not IClassicDesktopStyleApplicationLifetime { MainWindow: { } owner })
            return;
        if (owner.DataContext is not MainViewModel vm) return;

        var window = new Views.PairingWindow
        {
            DataContext = new PairingViewModel(vm.Core),
        };
        window.ShowDialog(owner);
    }
}
