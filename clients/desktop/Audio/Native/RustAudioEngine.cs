using System.Collections.Concurrent;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using Mozz.Desktop.Audio.Streaming;

namespace Mozz.Desktop.Audio.Native;

/// <summary>
/// <see cref="IAudioEngine"/> implemented over the shared Rust engine in
/// audio/. The C# side owns nothing about decoding, the output device or DSP —
/// it opens the bytes, hands them over as callbacks, and reflects what the
/// engine reports back. This replaces the old all-managed pipeline so the
/// desktop and Apple apps cannot drift apart again.
///
/// The engine is poll-based (state, position and current-track are getters);
/// <see cref="IAudioEngine"/> is event-based. A background thread bridges the
/// two by watching those getters and raising <see cref="TrackChanged"/>,
/// <see cref="PlaybackEnded"/> and <see cref="Error"/> on the transitions a
/// listener would notice.
/// </summary>
public sealed class RustAudioEngine : IAudioEngine
{
    // 48 kHz stereo is only the device's starting spec; the engine adopts each
    // decoder's real rate per track. ~2 s of frames of headroom in the ring.
    private const uint DeviceSampleRate = 48000;
    private const ushort DeviceChannels = 2;
    private const nuint CapacityFrames = 96000;

    private readonly nint _player;
    private readonly Thread _monitor;
    private volatile bool _running = true;

    // id → the token the caller gave us and the duration it already knew. The
    // engine speaks in u64 track ids; the app speaks in opaque tokens (a Track).
    // This is the only place the two are related.
    private readonly ConcurrentDictionary<ulong, (object? Token, TimeSpan Duration)> _tracks = new();
    private long _nextId;

    // Cross-thread state. _observedTrack and _lastState belong to the monitor;
    // _suppressAnnounceId is written by Play and read by the monitor; the
    // duration ticks are written by both and read by the UI thread, so they go
    // through Volatile.
    private ulong _observedTrack;
    private uint _lastState;
    private ulong _suppressAnnounceId;
    private long _currentDurationTicks;

    private double _volume = 1.0;

    public RustAudioEngine()
    {
        _player = MozzAudioInterop.mozz_player_new(DeviceSampleRate, DeviceChannels, CapacityFrames);
        if (_player == 0)
            throw new InvalidOperationException("The audio engine's decode thread could not be started.");

        _monitor = new Thread(MonitorLoop)
        {
            IsBackground = true,
            Name = "mozz-audio-monitor",
        };
        _monitor.Start();
    }

    public PlaybackState State => MapState(MozzAudioInterop.mozz_player_state(_player));

    public TimeSpan Position => TimeSpan.FromSeconds(MozzAudioInterop.mozz_player_position_seconds(_player));

    public TimeSpan Duration => TimeSpan.FromTicks(Volatile.Read(ref _currentDurationTicks));

    public double Volume
    {
        get => _volume;
        set
        {
            _volume = value;
            MozzAudioInterop.mozz_player_set_volume(_player, value);
        }
    }

    public bool Play(AudioSource source, object? token = null)
    {
        ulong id = (ulong)Interlocked.Increment(ref _nextId);
        _tracks[id] = (token, source.KnownDuration ?? TimeSpan.Zero);

        ByteStreamSource? stream;
        try
        {
            stream = OpenSource(source);
        }
        catch (Exception ex)
        {
            // A file that will not open is worth failing loudly and now, before
            // pretending to play. Streams open lazily and cannot fail here.
            _tracks.TryRemove(id, out _);
            Error?.Invoke(this, new AudioErrorEventArgs(
                AudioDiagnostics.DescribeOpenFailure(source.Uri, ex.Message), ex));
            return false;
        }

        // MainViewModel sets NowPlaying itself for a Play, so the track it just
        // chose must not come back as a TrackChanged. Suppress this id; a track
        // that arrives by the natural preload hand-off is a different id and
        // still announces.
        Volatile.Write(ref _currentDurationTicks, (source.KnownDuration ?? TimeSpan.Zero).Ticks);
        Interlocked.Exchange(ref _suppressAnnounceId, id);

        Hand(source, stream, id, MozzAudioInterop.mozz_player_play_now);
        return true;
    }

    public void PreloadNext(AudioSource source, object? token = null)
    {
        ulong id = (ulong)Interlocked.Increment(ref _nextId);
        _tracks[id] = (token, source.KnownDuration ?? TimeSpan.Zero);

        ByteStreamSource stream;
        try
        {
            stream = OpenSource(source);
        }
        catch (Exception ex)
        {
            // A preload that cannot open is not fatal to what is playing now;
            // report it and let the current track finish.
            _tracks.TryRemove(id, out _);
            Error?.Invoke(this, new AudioErrorEventArgs(
                AudioDiagnostics.DescribeOpenFailure(source.Uri, ex.Message), ex));
            return;
        }

        Hand(source, stream, id, MozzAudioInterop.mozz_player_play_next);
    }

    private delegate void HandOff(
        nint player, MozzAudioInterop.MozzSource source, nint extension, ulong track,
        double gainDb, bool hasGain);

    private void Hand(AudioSource source, ByteStreamSource stream, ulong id, HandOff handoff)
    {
        // Attach roots the stream with a GCHandle and returns the callbacks; the
        // handle is released by the engine's close callback. There must be no
        // fallible work between Attach and the FFI call, or the handle leaks.
        var native = MozzAudioInterop.Attach(stream);
        double? gain = source.ReplayGainTrackDb ?? source.ReplayGainAlbumDb;
        nint extension = MarshalExtension(source.Uri);
        try
        {
            handoff(_player, native, extension, id, gain ?? 0.0, gain.HasValue);
        }
        finally
        {
            if (extension != 0) Marshal.FreeCoTaskMem(extension);
        }
    }

    public void Pause() => MozzAudioInterop.mozz_player_pause(_player);

    public void Resume() => MozzAudioInterop.mozz_player_resume(_player);

    public void Stop() => MozzAudioInterop.mozz_player_stop(_player);

    public void Seek(TimeSpan position) => MozzAudioInterop.mozz_player_seek(_player, position.TotalSeconds);

    public unsafe void SetEqualizer(EqualizerSettings settings)
    {
        // The engine wants exactly ten gains in ISO-centre order. Pull each
        // band by its centre frequency rather than trusting list order, and
        // leave any missing band flat.
        Span<double> gains = stackalloc double[EqualizerSettings.IsoCentres.Length];
        for (int i = 0; i < gains.Length; i++)
        {
            double centre = EqualizerSettings.IsoCentres[i];
            gains[i] = 0.0;
            foreach (var band in settings.Bands)
            {
                if (Math.Abs(band.FrequencyHz - centre) < 0.5)
                {
                    gains[i] = band.GainDb;
                    break;
                }
            }
        }

        fixed (double* p = gains)
        {
            MozzAudioInterop.mozz_player_set_equalizer(_player, p, settings.PreampDb, settings.Enabled);
        }
    }

    public void SetReplayGain(ReplayGainMode mode, double preampDb = 0.0)
    {
        uint m = mode switch
        {
            ReplayGainMode.Track => 1,
            ReplayGainMode.Album => 2,
            _ => 0,
        };
        MozzAudioInterop.mozz_player_set_replay_gain(_player, m, preampDb);
    }

    public event EventHandler<TrackChangedEventArgs>? TrackChanged;
    public event EventHandler? PlaybackEnded;
    public event EventHandler<AudioErrorEventArgs>? Error;

    private void MonitorLoop()
    {
        // Poll fast enough that a track hand-off or a stall is noticed
        // promptly, slow enough to cost nothing.
        while (_running)
        {
            try
            {
                Poll();
            }
            catch
            {
                // The monitor must never die on a stray exception; a dead
                // monitor is silently missed track changes.
            }
            Thread.Sleep(30);
        }
    }

    private void Poll()
    {
        ulong cur = MozzAudioInterop.mozz_player_current_track(_player);
        uint state = MozzAudioInterop.mozz_player_state(_player);

        if (cur != _observedTrack)
        {
            ulong previous = _observedTrack;
            _observedTrack = cur;

            if (cur != 0 && _tracks.TryGetValue(cur, out var info))
            {
                // Whether or not we announce, adopt the new track's duration so
                // the progress bar is right the instant audio flows into it.
                Volatile.Write(ref _currentDurationTicks, info.Duration.Ticks);
                if (cur != Interlocked.Read(ref _suppressAnnounceId))
                {
                    TrackChanged?.Invoke(this, new TrackChangedEventArgs(info.Token));
                }
            }

            // Forget ids we have moved past; a preloaded track is a higher id
            // than the one playing, so this never drops something still needed.
            foreach (var key in _tracks.Keys)
            {
                if (key < cur) _tracks.TryRemove(key, out _);
            }
            _ = previous;
        }

        if (state != _lastState)
        {
            _lastState = state;
            if (state == 3) // ended
            {
                if (MozzAudioInterop.mozz_player_has_failed(_player))
                {
                    Error?.Invoke(this, new AudioErrorEventArgs(
                        "Playback stopped: the track could not be decoded."));
                }
                else
                {
                    PlaybackEnded?.Invoke(this, EventArgs.Empty);
                }
            }
        }
    }

    private static PlaybackState MapState(uint state) => state switch
    {
        1 => PlaybackState.Playing,
        2 => PlaybackState.Paused,
        _ => PlaybackState.Stopped, // 0 idle and 3 ended both read as stopped
    };

    private static ByteStreamSource OpenSource(AudioSource source)
    {
        if (Uri.TryCreate(source.Uri, UriKind.Absolute, out var uri)
            && (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps))
        {
            return new HttpByteStreamSource(source.Uri, source.Headers);
        }

        // Anything else is a local path. Open eagerly so a missing file fails
        // Play rather than starting a silent track.
        return new FileByteStreamSource(source.Uri);
    }

    private static nint MarshalExtension(string uri)
    {
        string path = uri;
        int query = path.IndexOf('?');
        if (query >= 0) path = path[..query];
        string ext = Path.GetExtension(path).TrimStart('.');
        if (string.IsNullOrEmpty(ext)) return 0;
        return Marshal.StringToCoTaskMemUTF8(ext);
    }

    public void Dispose()
    {
        // Stop the monitor before freeing the player: the monitor reads the
        // player every 30 ms, and reading a freed handle is a crash.
        _running = false;
        if (_monitor.IsAlive) _monitor.Join(TimeSpan.FromSeconds(1));
        MozzAudioInterop.mozz_player_free(_player);
    }
}
