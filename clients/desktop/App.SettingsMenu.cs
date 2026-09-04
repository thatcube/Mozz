using System;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Media;
using Avalonia.Platform;
using Mozz.Desktop.ViewModels;

namespace Mozz.Desktop;

public partial class App
{
    private Window? _settingsWindow;

    private void OnSettingsMozz(object? sender, System.EventArgs e)
    {
        if (ApplicationLifetime is not IClassicDesktopStyleApplicationLifetime { MainWindow: { } owner })
            return;

        owner.Activate();
        if (owner.DataContext is MainViewModel vm)
            _ = vm.OpenSettingsCommand.ExecuteAsync(null);
    }

    private void OnPairDevice(object? sender, EventArgs e)
    {
        if (ApplicationLifetime is not IClassicDesktopStyleApplicationLifetime { MainWindow: { } owner })
            return;
        if (owner.DataContext is not MainViewModel vm) return;

        vm.SelectSettingsCategoryCommand.Execute(SettingsCategory.Devices);
        _ = vm.OpenSettingsCommand.ExecuteAsync(null);
    }

    /// <summary>
    /// Presents the existing settings control tree in one native, movable
    /// system window. No overlay and no second Devices dialog.
    /// </summary>
    internal void ShowSettingsWindow()
    {
        if (ApplicationLifetime is not IClassicDesktopStyleApplicationLifetime
            {
                MainWindow: Views.MainWindow owner
            })
        {
            return;
        }
        if (owner.DataContext is not MainViewModel vm) return;
        if (_settingsWindow is { } existing)
        {
            existing.Activate();
            return;
        }

        var surface = owner.TakeSettingsSurface();
        var window = new Window
        {
            Title = "Mozz Settings",
            Width = 1120,
            Height = 760,
            MinWidth = 820,
            MinHeight = 600,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Background = (this.FindResource("AppBackground") as IBrush)
                         ?? Brushes.Black,
            Icon = new WindowIcon(
                AssetLoader.Open(new Uri("avares://Mozz.Desktop/Assets/mozz.ico"))),
            DataContext = vm,
            Content = surface,
        };
        _settingsWindow = window;
        window.Closed += (_, _) =>
        {
            window.Content = null;
            owner.ReturnSettingsSurface(surface);
            _settingsWindow = null;
            vm.SettingsWindowClosed();
            vm.RefreshCircle();
        };
        window.Show(owner);
    }
}
