using Mozz.Desktop.Core;
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
