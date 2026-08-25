using Mozz.Desktop.Core;
using Mozz.Desktop.ViewModels;
using System.Text.Json;
using Xunit;

namespace Mozz.Desktop.Tests;

public sealed class SettingsTests : IDisposable
{
    private readonly string _root = Path.Combine(
        Directory.GetCurrentDirectory(),
        "settings-test-data",
        Guid.NewGuid().ToString("N"));

    public SettingsTests()
    {
        Directory.CreateDirectory(_root);
    }

    public void Dispose()
    {
        if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true);
    }

    [Fact]
    public void PreferencesUseIosKeysAndDefaults()
    {
        var prefs = new AppPreferences(Path.Combine(_root, "preferences.json"));

        Assert.True(prefs.GetBool(AppPreferences.NormalizationEnabledKey, true));
        Assert.True(prefs.GetBool(AppPreferences.EnrichmentEnabledKey, true));
        Assert.Equal("system", prefs.GetString(AppPreferences.AppearanceKey, "system"));
        Assert.Equal("dim", prefs.GetString(AppPreferences.DarkStyleKey, "dim"));
        Assert.False(prefs.GetBool(AppPreferences.EqualizerEnabledKey, false));
        Assert.Equal(DesktopEqualizerProfile.Flat.Gains, prefs.GetEqualizerProfile().Gains);
        Assert.Equal(DesktopEqualizerProfile.Flat.PreampDB, prefs.GetEqualizerProfile().PreampDB);
    }

    [Fact]
    public void PreferencesPersistRoundTrip()
    {
        var prefs = new AppPreferences(Path.Combine(_root, "preferences.json"));
        prefs.SetBool(AppPreferences.NormalizationEnabledKey, false);
        prefs.SetString(AppPreferences.DarkStyleKey, "black");
        prefs.SetEqualizerProfile(new DesktopEqualizerProfile([99, 1], -99));

        var reloaded = new AppPreferences(Path.Combine(_root, "preferences.json"));
        Assert.False(reloaded.GetBool(AppPreferences.NormalizationEnabledKey, true));
        Assert.Equal("black", reloaded.GetString(AppPreferences.DarkStyleKey, "dim"));
        Assert.Equal(12, reloaded.GetEqualizerProfile().Gains[0]);
        Assert.Equal(-12, reloaded.GetEqualizerProfile().PreampDB);
        Assert.Equal(10, reloaded.GetEqualizerProfile().Gains.Count);
    }

    [Fact]
    public void DeviceIdIsStablePerPreferencesFile()
    {
        var path = Path.Combine(_root, "preferences.json");
        var first = new AppPreferences(path).GetOrCreateDeviceId();
        var second = new AppPreferences(path).GetOrCreateDeviceId();

        Assert.StartsWith("desktop-", first);
        Assert.Equal(first, second);
    }

    [Fact]
    public void EqualizerPresetsMatchSwiftCurves()
    {
        Assert.Equal([6.0, 5.0, 4.0, 2.0, 0.5, 0, 0, 0, 0, 0],
            DesktopEqualizerPreset.BassBoost.Profile().Gains);
        Assert.Equal([-2.0, -1.5, -1.0, 1.0, 3.0, 4.0, 3.5, 2.0, 0.5, -0.5],
            DesktopEqualizerPreset.Vocal.Profile().Gains);
        Assert.Equal("1k", DesktopEqualizerProfile.FrequencyLabel(5));
        Assert.Equal(DesktopEqualizerPreset.Rock,
            DesktopEqualizerPresets.Matching(DesktopEqualizerPreset.Rock.Profile()));
    }

    [Fact]
    public void SettingsCategoriesMirrorIosOrderWithDesktopAccountFirst()
    {
        var labels = SettingsCategories.All.Select(c => c.Label).ToArray();

        Assert.Equal([
            "Account & Servers",
            "Library",
            "Playback",
            "Lyrics",
            "Recommendations",
            "Appearance",
            "Diagnostics",
            "About",
        ], labels);
    }

    [Fact]
    public void SettingsPlacementPutsEqualizerInsidePlayback()
    {
        Assert.Equal(SettingsCategory.AccountServers, SettingsCategories.CategoryFor(SettingsSetting.ServerAccounts));
        Assert.Equal(SettingsCategory.Library, SettingsCategories.CategoryFor(SettingsSetting.MusicLibraries));
        Assert.Equal(SettingsCategory.Playback, SettingsCategories.CategoryFor(SettingsSetting.VolumeNormalization));
        Assert.Equal(SettingsCategory.Playback, SettingsCategories.CategoryFor(SettingsSetting.Equalizer));
        Assert.Equal(SettingsCategory.Recommendations, SettingsCategories.CategoryFor(SettingsSetting.SuppressedItems));
        Assert.Equal(SettingsCategory.Diagnostics, SettingsCategories.CategoryFor(SettingsSetting.Diagnostics));
    }

    [Fact]
    public void SettingsCategorySelectionTracksCurrentCategory()
    {
        var state = new SettingsCategorySelectionState();

        Assert.True(state.IsSelected(SettingsCategory.AccountServers));
        Assert.True(state.Select(SettingsCategory.Playback));
        Assert.False(state.Select(SettingsCategory.Playback));
        Assert.True(state.IsSelected(SettingsCategory.Playback));
        Assert.Equal("Playback", state.SelectedDefinition.Label);
    }

    [Fact]
    public void EqualizerFaderScaleCentersZeroDb()
    {
        Assert.Equal(0, EqualizerFaderScale.NormalizedPosition(-12));
        Assert.Equal(0.5, EqualizerFaderScale.ZeroLinePosition);
        Assert.Equal(0.5, EqualizerFaderScale.NormalizedPosition(0));
        Assert.Equal(1, EqualizerFaderScale.NormalizedPosition(12));
        Assert.Equal(1, EqualizerFaderScale.NormalizedPosition(99));
        Assert.Equal(0.5, EqualizerFaderScale.NormalizedPosition(double.NaN));
    }

    [Fact]
    public void SettingsPresentationUsesServerWhenSignedIn()
    {
        var account = new ServerAccount
        {
            ServerId = "jellyfin-http://server",
            Kind = BackendKind.Jellyfin,
            BaseUrl = "http://server",
            ServerName = "Living Room",
            ClientIdentifier = "client",
        };

        Assert.Equal("Living Room", SettingsPresentation.ProfileTitle(account));
        Assert.Equal("152 songs · 12 albums · 4 artists",
            SettingsPresentation.ProfileSubtitle(account, "152 songs · 12 albums · 4 artists"));
        Assert.Equal("Living Room", SettingsPresentation.ServerSectionTitle(account));
        Assert.Equal("Jellyfin · http://server", SettingsPresentation.ServerSectionSubtitle(account));
    }

    [Fact]
    public void ServerAccountProfileAcceptsNullSubsonicAvatar()
    {
        var profile = new ServerAccountProfile("brandon", "brandon", null);

        Assert.Equal("brandon", profile.DisplayName);
        Assert.Null(profile.AvatarUrl);
    }

    [Fact]
    public void SettingsPresentationPromptsForServerWhenSignedOut()
    {
        Assert.Equal("Settings", SettingsPresentation.ProfileTitle(null));
        Assert.Equal("Connect a server", SettingsPresentation.ProfileSubtitle(null, "No music yet"));
        Assert.Equal("No server signed in", SettingsPresentation.ServerSectionTitle(null));
        Assert.Equal("Add Plex, Jellyfin or Subsonic to sync your music.",
            SettingsPresentation.ServerSectionSubtitle(null));
    }

    [Fact]
    public void SignOutRemovesServerAndCredentials()
    {
        var secrets = new MemorySecretStore();
        var server = new MozzServer(new MozzCore(), secrets, Path.Combine(_root, "accounts.json"));
        var account = new ServerAccount
        {
            ServerId = "plex-http://server",
            Kind = BackendKind.Plex,
            BaseUrl = "http://server",
            ServerName = "Server",
            ClientIdentifier = "client",
        };
        server.SaveAccount(account, "server-token", "account-token");

        server.ForgetAllAccounts();

        Assert.Empty(server.SavedAccounts());
        Assert.Null(secrets.Get("token.plex-http://server"));
        Assert.Null(secrets.Get("plex.account.plex-http://server"));
    }

    [Fact]
    public void SavedAccountsDeduplicatePlexMachineAndMigrateCredential()
    {
        var secrets = new MemorySecretStore();
        var accountsPath = Path.Combine(_root, "accounts.json");
        var machine = "50acfe994de74f8998deb9fc43e6262e";
        var docker = new ServerAccount
        {
            ServerId = $"plex-https://172-18-0-1.{machine}.plex.direct:32400/",
            Kind = BackendKind.Plex,
            BaseUrl = $"https://172-18-0-1.{machine}.plex.direct:32400/",
            ServerName = "Brandoland",
            ClientIdentifier = "client",
        };
        var lan = new ServerAccount
        {
            ServerId = $"plex-https://192-168-68-71.{machine}.plex.direct:32400/",
            Kind = BackendKind.Plex,
            BaseUrl = $"https://192-168-68-71.{machine}.plex.direct:32400/",
            ServerName = "Brandoland",
            ClientIdentifier = "client",
            MusicSectionId = "1",
        };
        Directory.CreateDirectory(Path.GetDirectoryName(accountsPath)!);
        File.WriteAllText(accountsPath, JsonSerializer.Serialize(new[] { docker, lan }));
        secrets.Set($"token.{lan.ServerId}", "server-token");
        secrets.Set($"plex.account.{lan.ServerId}", "account-token");

        var server = new MozzServer(new MozzCore(), secrets, accountsPath);
        var saved = server.SavedAccounts();

        var account = Assert.Single(saved);
        Assert.Equal($"plex-{machine}", account.ServerId);
        Assert.Equal(machine, account.ServerMachineIdentifier);
        Assert.Equal(lan.BaseUrl, account.BaseUrl);
        Assert.Equal("1", account.MusicSectionId);
        Assert.Equal("server-token", secrets.Get($"token.plex-{machine}"));
        Assert.Equal("account-token", secrets.Get($"plex.account.plex-{machine}"));
    }

    [Fact]
    public void LibrarySelectionMarksCurrentAndRejectsUnknown()
    {
        var libraries = new[]
        {
            new MusicLibrary("1", "Main"),
            new MusicLibrary("2", "Archive"),
        };

        var options = LibrarySelectionState.Build(libraries, selectedLibraryId: "2");

        Assert.False(options[0].IsSelected);
        Assert.True(options[1].IsSelected);
        Assert.Equal("1", LibrarySelectionState.Apply(options, "1"));
        Assert.Null(LibrarySelectionState.Apply(options, "missing"));
    }

    private sealed class MemorySecretStore : ISecretStore
    {
        private readonly Dictionary<string, string> _values = [];
        public string Description => "memory";
        public string? Get(string key) => _values.GetValueOrDefault(key);
        public void Set(string key, string? value)
        {
            if (value is null) _values.Remove(key);
            else _values[key] = value;
        }
    }
}
