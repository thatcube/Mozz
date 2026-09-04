using CommunityToolkit.Mvvm.ComponentModel;
using Mozz.Desktop.Core;

namespace Mozz.Desktop.ViewModels;

public sealed record SettingsOption(string Id, string Label);

public enum SettingsCategory
{
    AccountServers,
    Library,
    Playback,
    Lyrics,
    Recommendations,
    Appearance,
    Devices,
    Diagnostics,
    About,
}

public enum SettingsSetting
{
    AccountHeader,
    ServerAccounts,
    AddServer,
    SyncNow,
    MusicLibraries,
    VolumeNormalization,
    Equalizer,
    LyricsOnlineLookup,
    LyricsOfflineCapture,
    ImproveRecommendations,
    SuppressedItems,
    AppearanceTheme,
    DarkStyle,
    Diagnostics,
    About,
}

public sealed record SettingsCategoryDefinition(SettingsCategory Category, string Label, string Subtitle);

public static class SettingsCategories
{
    public static readonly IReadOnlyList<SettingsCategoryDefinition> All =
    [
        new(SettingsCategory.AccountServers, "Account & Servers", "Sign in, switch servers and sync"),
        new(SettingsCategory.Library, "Library", "Music libraries"),
        new(SettingsCategory.Playback, "Playback", "Normalization and equalizer"),
        new(SettingsCategory.Lyrics, "Lyrics", "Lookup and offline lyrics"),
        new(SettingsCategory.Recommendations, "Recommendations", "Enrichment and hidden items"),
        new(SettingsCategory.Devices, "Sync", "Music, history and settings across devices"),
        new(SettingsCategory.Appearance, "Appearance", "Theme"),
        new(SettingsCategory.Diagnostics, "Diagnostics", "Storage and sync details"),
        new(SettingsCategory.About, "About", "Version and source"),
    ];

    public static SettingsCategory CategoryFor(SettingsSetting setting) => setting switch
    {
        SettingsSetting.AccountHeader or
        SettingsSetting.ServerAccounts or
        SettingsSetting.AddServer or
        SettingsSetting.SyncNow => SettingsCategory.AccountServers,
        SettingsSetting.MusicLibraries => SettingsCategory.Library,
        SettingsSetting.VolumeNormalization or
        SettingsSetting.Equalizer => SettingsCategory.Playback,
        SettingsSetting.LyricsOnlineLookup or
        SettingsSetting.LyricsOfflineCapture => SettingsCategory.Lyrics,
        SettingsSetting.ImproveRecommendations or
        SettingsSetting.SuppressedItems => SettingsCategory.Recommendations,
        SettingsSetting.AppearanceTheme or
        SettingsSetting.DarkStyle => SettingsCategory.Appearance,
        SettingsSetting.Diagnostics => SettingsCategory.Diagnostics,
        SettingsSetting.About => SettingsCategory.About,
        _ => throw new ArgumentOutOfRangeException(nameof(setting), setting, null),
    };

    public static SettingsCategoryDefinition Definition(SettingsCategory category) =>
        All.First(d => d.Category == category);
}

public sealed class SettingsCategorySelectionState
{
    public SettingsCategory Selected { get; private set; } = SettingsCategory.AccountServers;

    public SettingsCategoryDefinition SelectedDefinition => SettingsCategories.Definition(Selected);

    public bool Select(SettingsCategory category)
    {
        if (Selected == category) return false;
        Selected = category;
        return true;
    }

    public bool IsSelected(SettingsCategory category) => Selected == category;
}

public sealed record SettingsLibraryOption(string Id, string Name, bool IsSelected)
{
    public string Status => IsSelected ? "Syncing" : "Not syncing";
}

public sealed record SuppressedSettingsItem(
    string Scope, string Ref, double CreatedAt, string? Name = null, string? Detail = null)
{
    /// The name the core resolved. The ref is the fallback for something
    /// suppressed and then removed from the library — a list that shows remote
    /// ids where names belong is not a list anyone can act on.
    public string Title => string.IsNullOrEmpty(Name) ? Ref : Name;

    public string Subtitle => string.IsNullOrEmpty(Detail)
        ? (Scope == "artist" ? "Artist" : "Track")
        : Detail;
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
