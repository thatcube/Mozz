using CommunityToolkit.Mvvm.ComponentModel;
using Mozz.Desktop.Core;

namespace Mozz.Desktop.ViewModels;

public sealed record SettingsOption(string Id, string Label);

public sealed record SettingsLibraryOption(string Id, string Name, bool IsSelected)
{
    public string Status => IsSelected ? "Syncing" : "Not syncing";
}

public sealed record SuppressedSettingsItem(string Scope, string Ref, double CreatedAt)
{
    public string Title => Ref;
    public string Subtitle => Scope == "artist" ? "Artist" : "Track";
}

public static class SettingsPresentation
{
    public static string ProfileTitle(ServerAccount? account) =>
        account?.ServerName is { Length: > 0 } name ? name : "Settings";

    public static string ProfileSubtitle(ServerAccount? account, string librarySummary) =>
        account is null ? "Connect a server" : librarySummary;

    public static string ServerSectionTitle(ServerAccount? account) =>
        account is null ? "No server signed in" : account.ServerName;

    public static string ServerSectionSubtitle(ServerAccount? account) =>
        account is null
            ? "Add Plex, Jellyfin or Subsonic to sync your music."
            : $"{account.Kind.Display()} · {account.BaseUrl}";
}

public static class EqualizerFaderScale
{
    public static double NormalizedPosition(double db)
    {
        var clamped = DesktopEqualizerProfile.ClampGain(db);
        return (clamped - DesktopEqualizerProfile.MinGainDb)
            / (DesktopEqualizerProfile.MaxGainDb - DesktopEqualizerProfile.MinGainDb);
    }

    public static double ZeroLinePosition =>
        NormalizedPosition(0);
}

public sealed partial class EqualizerBandSetting(
    int index,
    string label,
    double gain,
    Action<int, double> onChanged) : ObservableObject
{
    public int Index { get; } = index;
    public string Label { get; } = label;
    private readonly Action<int, double> _onChanged = onChanged;
    private bool _suppressChanged;

    [ObservableProperty] private double _gain = gain;

    public string GainText => FormatGain(Gain);
    public double NormalizedPosition => EqualizerFaderScale.NormalizedPosition(Gain);

    partial void OnGainChanged(double value)
    {
        if (_suppressChanged) return;
        var clamped = DesktopEqualizerProfile.ClampGain(value);
        if (Math.Abs(clamped - value) > 0.001)
        {
            Gain = clamped;
            return;
        }

        OnPropertyChanged(nameof(GainText));
        OnPropertyChanged(nameof(NormalizedPosition));
        _onChanged(Index, clamped);
    }

    public void SetSilently(double value)
    {
        _suppressChanged = true;
        try
        {
            Gain = DesktopEqualizerProfile.ClampGain(value);
            OnPropertyChanged(nameof(GainText));
            OnPropertyChanged(nameof(NormalizedPosition));
        }
        finally
        {
            _suppressChanged = false;
        }
    }

    public static string FormatGain(double value)
    {
        var rounded = Math.Round(value * 2, MidpointRounding.AwayFromZero) / 2;
        return Math.Abs(rounded) < 0.05 ? "0 dB" : $"{rounded:+0.0;-0.0} dB";
    }
}
