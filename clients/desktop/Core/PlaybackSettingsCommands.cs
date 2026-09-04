using Mozz.V1;
using Mozz.Desktop.Core.Downloads;

namespace Mozz.Desktop.Core;

public sealed record CorePlaybackSettings(
    bool EqualizerEnabled,
    double[] EqualizerBandGainsDB,
    double EqualizerPreampDB,
    string ReplayGainMode,
    double ReplayGainPreampDB);

/// <summary>
/// Typed access to the schema-defined playback settings commands.
/// </summary>
public sealed class PlaybackSettingsCommands(ICoreInvoker core)
{
    private readonly ICoreInvoker _core = core;
    private int _nextId;

    private ulong NextId() => (ulong)Interlocked.Increment(ref _nextId);

    public async Task<CorePlaybackSettings> LoadAsync(
        CancellationToken token = default)
    {
        var response = await _core.InvokeAsync(new Request
        {
            Id = NextId(),
            GetPlaybackSettings = new GetPlaybackSettingsRequest(),
        }, token).ConfigureAwait(false);
        return Project(response.GetPlaybackSettings.Settings);
    }

    public async Task<CorePlaybackSettings> SaveAsync(
        CorePlaybackSettings value,
        CancellationToken token = default)
    {
        var settings = new Mozz.V1.PlaybackSettings
        {
            EqualizerEnabled = value.EqualizerEnabled,
            EqualizerPreampDb = value.EqualizerPreampDB,
            ReplayGainMode = value.ReplayGainMode switch
            {
                "off" => Mozz.V1.ReplayGainMode.Off,
                "album" => Mozz.V1.ReplayGainMode.Album,
                _ => Mozz.V1.ReplayGainMode.Track,
            },
            ReplayGainPreampDb = value.ReplayGainPreampDB,
        };
        settings.EqualizerBandGainsDb.Add(value.EqualizerBandGainsDB);
        var response = await _core.InvokeAsync(new Request
        {
            Id = NextId(),
            SetPlaybackSettings = new SetPlaybackSettingsRequest
            {
                Settings = settings,
            },
        }, token).ConfigureAwait(false);
        return Project(response.SetPlaybackSettings.Settings);
    }

    private static CorePlaybackSettings Project(
        Mozz.V1.PlaybackSettings settings) =>
        new(
            settings.EqualizerEnabled,
            settings.EqualizerBandGainsDb.ToArray(),
            settings.EqualizerPreampDb,
            settings.ReplayGainMode switch
            {
                Mozz.V1.ReplayGainMode.Off => "off",
                Mozz.V1.ReplayGainMode.Album => "album",
                _ => "track",
            },
            settings.ReplayGainPreampDb);
}
