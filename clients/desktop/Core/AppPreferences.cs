using System.Text.Json;

namespace Mozz.Desktop.Core;

/// <summary>
/// Small, cross-platform preference store for the desktop shell.
/// </summary>
public sealed class AppPreferences
{
    public const string NormalizationEnabledKey = "mozz.normalizationEnabled";
    public const string EnrichmentEnabledKey = "mozz.enrichmentEnabled";
    public const string EqualizerEnabledKey = "mozz.equalizerEnabled";
    public const string EqualizerSettingsKey = "mozz.equalizerSettings";
    public const string LyricsOnlineLookupKey = "mozz.lyricsOnlineLookup";
    public const string LyricsOfflineCaptureKey = "mozz.lyricsOfflineCapture";
    public const string AppearanceKey = "mozz.appearance";
    public const string DarkStyleKey = "mozz.darkStyle";

    private readonly string _path;
    private readonly object _gate = new();
    private Dictionary<string, JsonElement> _values;

    public AppPreferences(string? path = null)
    {
        _path = path ?? System.IO.Path.Combine(AppPaths.SupportDirectory, "preferences.json");
        _values = Load(_path);
    }

    public string Path => _path;

    public bool GetBool(string key, bool defaultValue)
    {
        lock (_gate)
        {
            return _values.TryGetValue(key, out var value) && value.ValueKind is JsonValueKind.True or JsonValueKind.False
                ? value.GetBoolean()
                : defaultValue;
        }
    }

    public void SetBool(string key, bool value) => Set(key, value);

    public string GetString(string key, string defaultValue)
    {
        lock (_gate)
        {
            return _values.TryGetValue(key, out var value) && value.ValueKind == JsonValueKind.String
                ? value.GetString() ?? defaultValue
                : defaultValue;
        }
    }

    public void SetString(string key, string value) => Set(key, value);

    public DesktopEqualizerProfile GetEqualizerProfile()
    {
        lock (_gate)
        {
            if (!_values.TryGetValue(EqualizerSettingsKey, out var value)) return DesktopEqualizerProfile.Flat;
            try
            {
                return JsonSerializer.Deserialize<DesktopEqualizerProfile>(value.GetRawText())?.Normalized()
                       ?? DesktopEqualizerProfile.Flat;
            }
            catch (JsonException)
            {
                return DesktopEqualizerProfile.Flat;
            }
        }
    }

    public void SetEqualizerProfile(DesktopEqualizerProfile profile) => Set(EqualizerSettingsKey, profile.Normalized());

    private void Set<T>(string key, T value)
    {
        lock (_gate)
        {
            _values[key] = JsonSerializer.SerializeToElement(value);
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(_path)!);
            var options = new JsonSerializerOptions { WriteIndented = true };
            File.WriteAllText(_path, JsonSerializer.Serialize(_values, options));
        }
    }

    private static Dictionary<string, JsonElement> Load(string path)
    {
        if (!File.Exists(path)) return [];
        try
        {
            return JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(File.ReadAllText(path)) ?? [];
        }
        catch (JsonException)
        {
            return [];
        }
    }
}
