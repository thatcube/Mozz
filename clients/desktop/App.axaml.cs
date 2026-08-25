using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Layout;
using Avalonia.Markup.Xaml;
using Avalonia.Media;
using Mozz.Desktop.Core;
using Mozz.Desktop.ViewModels;
using Mozz.Desktop.Views;

namespace Mozz.Desktop;

public partial class App : Application
{
    public override void Initialize()
    {
        AvaloniaXamlLoader.Load(this);
    }

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            desktop.MainWindow = new MainWindow
            {
                DataContext = new MainViewModel(),
            };
        }

        base.OnFrameworkInitializationCompleted();
    }

    /// <summary>
    /// The About box. Built in code rather than XAML because it is one label and
    /// a version string, and a second .axaml file for that is not worth the
    /// build plumbing.
    /// </summary>
    private void OnAboutMozz(object? sender, System.EventArgs e)
    {
        var version = AppVersion.FromAssembly(typeof(App).Assembly);

        var window = new Window
        {
            Title = "About Mozz",
            Width = 360,
            Height = 220,
            CanResize = false,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Background = (this.FindResource("AppBackground") as IBrush) ?? Brushes.Black,
            Content = new StackPanel
            {
                Margin = new Thickness(28),
                Spacing = 8,
                VerticalAlignment = VerticalAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Center,
                Children =
                {
                    new TextBlock
                    {
                        Text = "Mozz",
                        FontSize = 30,
                        FontWeight = FontWeight.Bold,
                        HorizontalAlignment = HorizontalAlignment.Center,
                        Foreground = (this.FindResource("TextPrimary") as IBrush) ?? Brushes.White,
                    },
                    new TextBlock
                    {
                        Text = $"Version {version}",
                        HorizontalAlignment = HorizontalAlignment.Center,
                        Foreground = (this.FindResource("TextSecondary") as IBrush) ?? Brushes.Gray,
                    },
                    new TextBlock
                    {
                        Text = "One app for your music, wherever it lives.",
                        Margin = new Thickness(0, 12, 0, 0),
                        TextAlignment = TextAlignment.Center,
                        TextWrapping = TextWrapping.Wrap,
                        Foreground = (this.FindResource("TextSecondary") as IBrush) ?? Brushes.Gray,
                    },
                    new TextBlock
                    {
                        Text = "Free forever. Open source.",
                        TextAlignment = TextAlignment.Center,
                        Foreground = (this.FindResource("TextTertiary") as IBrush) ?? Brushes.Gray,
                    },
                },
            },
        };

        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime { MainWindow: { } owner })
            window.ShowDialog(owner);
        else
            window.Show();
    }
}