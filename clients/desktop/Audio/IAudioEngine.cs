namespace Mozz.Desktop.Audio;

/// <summary>What the transport shows: the three states a player can be in.</summary>
public enum PlaybackState
{
    Stopped,
    Playing,
    Paused,
}

/// <summary>Which ReplayGain tag to honour, if any.</summary>
public enum ReplayGainMode
{
    Off,
    Track,
    Album,
}

/// <summary>
/// A single thing to play. The engine deliberately knows nothing about a
/// <c>Track</c>, a server, or how a URL was minted — only how to fetch and
/// decode the bytes at <see cref="Uri"/>. Turning a library row into one of
/// these is app logic and lives in the view model, exactly as
/// "what plays next" does.
/// </summary>
/// <param name="Uri">A local path or an http(s) URL. FFmpeg reads either.</param>
/// <param name="Headers">
/// Auth headers sent verbatim on the HTTP request (bearer token, cookie, …).
/// Ignored for local files.
/// </param>
/// <param name="ReplayGainTrackDb">Per-track ReplayGain, in dB, if the tag was present.</param>
/// <param name="ReplayGainAlbumDb">Per-album ReplayGain, in dB, if the tag was present.</param>
/// <param name="KnownDuration">
/// Duration from the library's metadata. Streamed sources can't always be
/// probed cheaply, so the caller supplies what it already knows for the
/// progress bar; the engine falls back to the decoder when this is null.
/// </param>
public sealed record AudioSource(
    string Uri,
    IReadOnlyDictionary<string, string>? Headers = null,
    double? ReplayGainTrackDb = null,
    double? ReplayGainAlbumDb = null,
    TimeSpan? KnownDuration = null);

/// <summary>One peaking band of the parametric EQ.</summary>
/// <param name="FrequencyHz">Centre frequency.</param>
/// <param name="GainDb">Cut or boost, in dB.</param>
/// <param name="Q">Quality factor — higher is narrower.</param>
public readonly record struct EqBand(double FrequencyHz, double GainDb, double Q = 1.0);

/// <summary>The whole equaliser: on/off plus the bands and preamp to apply.</summary>
public sealed record EqualizerSettings(bool Enabled, IReadOnlyList<EqBand> Bands, double PreampDb = 0)
{
    /// <summary>The ten ISO centre frequencies a graphic EQ conventionally uses.</summary>
    public static readonly double[] IsoCentres =
        [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];

    /// <summary>A flat ten-band EQ — every band at 0 dB — as a starting point.</summary>
    public static EqualizerSettings Flat()
        => new(false, Array.ConvertAll(IsoCentres, f => new EqBand(f, 0.0)), 0);
}

/// <summary>Raised when the current source changes as playback flows into a preloaded track.</summary>
public sealed class TrackChangedEventArgs(object? token) : EventArgs
{
    /// <summary>The token the caller passed to <see cref="IAudioEngine.PreloadNext"/> for this source.</summary>
    public object? Token { get; } = token;
}

/// <summary>Raised when decoding or the output device fails.</summary>
public sealed class AudioErrorEventArgs(string message, Exception? exception = null) : EventArgs
{
    public string Message { get; } = message;
    public Exception? Exception { get; } = exception;
}

/// <summary>
/// The whole surface the rest of the app is allowed to see. One implementation
/// (<see cref="MiniAudioEngine"/>) hides the output device and the decoders
/// behind it, the same way <c>MozzCore</c> is the only file that knows the core
/// is native. Swapping the backend must not touch a single view model.
/// </summary>
public interface IAudioEngine : IDisposable
{
    PlaybackState State { get; }

    /// <summary>Position within the current track. Advances only while audio is actually leaving the device.</summary>
    TimeSpan Position { get; }

    /// <summary>Length of the current track, from metadata or the decoder; <see cref="TimeSpan.Zero"/> if unknown.</summary>
    TimeSpan Duration { get; }

    /// <summary>0.0–1.0, applied with a short ramp so a change never clicks.</summary>
    double Volume { get; set; }

    /// <summary>Load <paramref name="source"/> and begin playing it immediately, replacing whatever was playing.</summary>
    /// <param name="token">An opaque caller tag echoed back by <see cref="TrackChanged"/>; the view model passes the track id.</param>
    bool Play(AudioSource source, object? token = null);

    /// <summary>
    /// Open <paramref name="source"/> now so it is buffered and ready. When the
    /// current track ends the engine flows straight into it with no device stop
    /// and no silence — this is what makes playback gapless.
    /// </summary>
    void PreloadNext(AudioSource source, object? token = null);

    void Pause();
    void Resume();
    void Stop();

    /// <summary>Jump to <paramref name="position"/> within the current track (HTTP range request for streams).</summary>
    void Seek(TimeSpan position);

    void SetEqualizer(EqualizerSettings settings);

    /// <summary>Choose which ReplayGain tag to honour and add a global pre-amp on top.</summary>
    void SetReplayGain(ReplayGainMode mode, double preampDb = 0.0);

    /// <summary>Playback crossed into a preloaded track; the argument carries that track's token.</summary>
    event EventHandler<TrackChangedEventArgs>? TrackChanged;

    /// <summary>The last track finished and nothing was preloaded — the queue has run dry.</summary>
    event EventHandler? PlaybackEnded;

    event EventHandler<AudioErrorEventArgs>? Error;
}
