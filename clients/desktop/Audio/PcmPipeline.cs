using Mozz.Desktop.Audio.Decoding;
using Mozz.Desktop.Audio.Dsp;

namespace Mozz.Desktop.Audio;

/// <summary>
/// The gapless mixing core, deliberately separated from any output device so it
/// can be unit-tested by pulling frames from <see cref="Render"/> directly — no
/// speakers required. It owns the ring buffer, the background decode pump, the
/// DSP chain (ReplayGain → EQ → volume) and the frame-accurate bookkeeping that
/// makes one track flow into the next without a device stop.
///
/// Threading model, kept strict on purpose:
/// <list type="bullet">
///   <item>The <b>pump thread</b> is the only thread that mutates structure —
///   which decoder is current, which is preloaded, and clearing the ring. Public
///   mutators just enqueue a command for it.</item>
///   <item><see cref="Render"/> runs on the <b>audio thread</b>. It only reads
///   from the ring and advances the read cursor. It never blocks or allocates on
///   the steady path.</item>
///   <item>When the pump must clear the ring (load/seek/stop) it briefly mutes
///   the renderer and waits for an acknowledgement, so the ring's read cursor
///   never has two writers.</item>
///   <item>Events are raised on a <b>notifier thread</b>, never from the audio
///   callback.</item>
/// </list>
/// </summary>
internal sealed class PcmPipeline : IDisposable
{
    public int SampleRate { get; }
    public int Channels { get; }

    private readonly RingBuffer _ring;
    private readonly TenBandEqualizer _eq;

    private readonly Thread _pumpThread;
    private readonly Thread _notifyThread;
    private readonly SemaphoreSlim _notifySignal = new(0);
    private readonly System.Collections.Concurrent.ConcurrentQueue<PipelineCommand> _commands = new();
    private readonly System.Collections.Concurrent.ConcurrentQueue<Boundary> _boundaries = new();
    private readonly System.Collections.Concurrent.ConcurrentQueue<Notification> _notifications = new();

    private Segment? _current;
    private Segment? _next;

    private volatile int _state = (int)PlaybackState.Stopped;
    private volatile bool _running = true;
    private volatile bool _muteRender;
    private volatile bool _renderAck;

    private long _baseFrame;            // absolute frame index where the playing track began
    private long _currentDurationTicks; // duration of the playing track
    private long _endFrame = -1;        // frame index the whole queue ends at, or -1
    private bool _playbackEndedFired;

    private double _volume = 1.0;
    private double _appliedVolume = 1.0;
    private volatile int _rgMode = (int)ReplayGainMode.Off;
    private double _rgPreampDb;

    private readonly float[] _pumpBuffer;

    public event Action<object?>? TrackChanged;
    public event Action? PlaybackEnded;
    public event Action<string>? Error;

    public PcmPipeline(int sampleRate, int channels, double ringSeconds = 2.0)
    {
        SampleRate = sampleRate;
        Channels = channels;
        int capacity = (int)(sampleRate * channels * ringSeconds);
        _ring = new RingBuffer(capacity);
        _eq = new TenBandEqualizer(sampleRate, channels);
        _pumpBuffer = new float[sampleRate / 10 * channels]; // ~100 ms of work per pass

        _pumpThread = new Thread(PumpLoop) { IsBackground = true, Name = "audio-pump" };
        _notifyThread = new Thread(NotifyLoop) { IsBackground = true, Name = "audio-notify" };
        _pumpThread.Start();
        _notifyThread.Start();
    }

    public PlaybackState State => (PlaybackState)_state;

    public TimeSpan Position
    {
        get
        {
            long consumed = _ring.TotalRead / Channels;
            long frames = consumed - Interlocked.Read(ref _baseFrame);
            if (frames < 0) frames = 0;
            return TimeSpan.FromSeconds((double)frames / SampleRate);
        }
    }

    public TimeSpan Duration => TimeSpan.FromTicks(Interlocked.Read(ref _currentDurationTicks));

    public double Volume
    {
        get => Volatile.Read(ref _volume);
        set => Volatile.Write(ref _volume, Math.Clamp(value, 0.0, 1.0));
    }

    public void SetEqualizer(EqualizerSettings settings) => _eq.Configure(settings.Bands, settings.Enabled);

    public void SetReplayGain(ReplayGainMode mode, double preampDb)
    {
        _rgMode = (int)mode;
        Volatile.Write(ref _rgPreampDb, preampDb);
    }

    public void LoadCurrent(IPcmDecoder decoder, AudioSource source, object? token)
        => _commands.Enqueue(new PipelineCommand(PipelineCommandKind.LoadCurrent, Segment.From(decoder, source, token)));

    public void PreloadNext(IPcmDecoder decoder, AudioSource source, object? token)
        => _commands.Enqueue(new PipelineCommand(PipelineCommandKind.PreloadNext, Segment.From(decoder, source, token)));

    public void Pause()
    {
        if (_state == (int)PlaybackState.Playing) _state = (int)PlaybackState.Paused;
    }

    public void Resume()
    {
        if (_state == (int)PlaybackState.Paused) _state = (int)PlaybackState.Playing;
    }

    public void Stop() => _commands.Enqueue(new PipelineCommand(PipelineCommandKind.Stop, null));

    public void Seek(TimeSpan position)
        => _commands.Enqueue(new PipelineCommand(PipelineCommandKind.Seek, null, position.Ticks));

    /// <summary>
    /// Fill <paramref name="output"/> with interleaved frames for the device. The
    /// only method on the audio thread: reads what the ring has, pads the rest
    /// with silence, applies the volume ramp, and advances the transport.
    /// </summary>
    public void Render(Span<float> output)
    {
        if (_muteRender)
        {
            _renderAck = true;
            output.Clear();
            return;
        }
        _renderAck = false;

        var state = (PlaybackState)_state;
        if (state != PlaybackState.Playing)
        {
            output.Clear();
            return;
        }

        int got = _ring.Read(output);
        if (got < output.Length)
            output[got..].Clear();

        ApplyVolume(output);

        long consumed = _ring.TotalRead / Channels;

        while (_boundaries.TryPeek(out var boundary) && consumed >= boundary.Frame)
        {
            _boundaries.TryDequeue(out _);
            Interlocked.Exchange(ref _baseFrame, boundary.Frame);
            Interlocked.Exchange(ref _currentDurationTicks, boundary.DurationTicks);
            Enqueue(new Notification(NotificationKind.TrackChanged, boundary.Token));
        }

        long end = Interlocked.Read(ref _endFrame);
        if (end >= 0 && !_playbackEndedFired && consumed >= end && _ring.Count == 0)
        {
            _playbackEndedFired = true;
            _state = (int)PlaybackState.Stopped;
            Enqueue(new Notification(NotificationKind.Ended, null));
        }
    }

    private void ApplyVolume(Span<float> output)
    {
        double target = Volatile.Read(ref _volume);
        double start = _appliedVolume;
        if (Math.Abs(target - start) < 1e-4)
        {
            if (target < 0.999)
                for (int i = 0; i < output.Length; i++) output[i] *= (float)target;
            _appliedVolume = target;
            return;
        }

        int frames = output.Length / Channels;
        for (int f = 0; f < frames; f++)
        {
            double v = start + (target - start) * ((double)f / frames);
            int baseIdx = f * Channels;
            for (int c = 0; c < Channels; c++) output[baseIdx + c] *= (float)v;
        }
        _appliedVolume = target;
    }

    private void PumpLoop()
    {
        while (_running)
        {
            bool didWork = DrainCommands();

            var current = _current;
            if (current is null)
            {
                if (!didWork) Thread.Sleep(5);
                continue;
            }

            int spaceFrames = _ring.Space / Channels;
            if (spaceFrames < 64)
            {
                Thread.Sleep(3);
                continue;
            }

            int wantFrames = Math.Min(spaceFrames, _pumpBuffer.Length / Channels);
            int frames = current.Decoder.ReadFrames(_pumpBuffer, wantFrames);

            if (frames <= 0)
            {
                OnCurrentEnded();
                continue;
            }

            var span = _pumpBuffer.AsSpan(0, frames * Channels);
            ApplyReplayGain(span, current);
            _eq.Process(span, frames);
            _ring.Write(span);
        }
    }

    private void OnCurrentEnded()
    {
        long producedFrames = _ring.TotalWritten / Channels;
        var next = _next;
        if (next is not null)
        {
            _boundaries.Enqueue(new Boundary(producedFrames, next.Token, next.DurationTicks));
            _current?.Decoder.Dispose();
            _current = next;
            _next = null;
        }
        else
        {
            Interlocked.Exchange(ref _endFrame, producedFrames);
            _current?.Decoder.Dispose();
            _current = null;
        }
    }

    /// <summary>
    /// Take up a preload that arrived after the current track's decoder had
    /// already run dry, provided the listener has not yet reached the end.
    ///
    /// The pump reads ahead by the ring's depth (two seconds), so a decoder
    /// finishes a couple of seconds before the audio is heard. A caller that
    /// preloads the moment a track starts — which is what the view model does —
    /// is never in this position. But resolving the next track's URL is a
    /// network round trip, and on a slow server, or for a very short track, it
    /// can land in that window. Without this the preload is silently discarded:
    /// playback stops, the "ended" notification advances the queue, and the
    /// listener hears a gap between two tracks that were supposed to be
    /// continuous. It is not a stall, but on a gapless album it is the one
    /// artefact this whole design exists to prevent.
    ///
    /// Safe because nothing has been consumed past the boundary yet: the frame
    /// where the next track begins is exactly where the previous one stopped
    /// producing, and clearing the end marker un-arms an "ended" that has not
    /// fired.
    /// </summary>
    private void AdoptPreloadIfTheCurrentTrackAlreadyDrained()
    {
        if (_current is not null || _next is null) return;

        long end = Interlocked.Read(ref _endFrame);
        if (end < 0) return;

        long consumed = _ring.TotalRead / Channels;
        if (consumed >= end) return;   // already heard the end; too late to stitch

        _boundaries.Enqueue(new Boundary(end, _next.Token, _next.DurationTicks));
        _current = _next;
        _next = null;
        Interlocked.Exchange(ref _endFrame, -1);
    }

    private void ApplyReplayGain(Span<float> span, Segment segment)
    {
        double gain = ReplayGain.LinearFor(
            (ReplayGainMode)_rgMode,
            Volatile.Read(ref _rgPreampDb),
            segment.TrackDb,
            segment.AlbumDb);
        if (Math.Abs(gain - 1.0) < 1e-6) return;
        for (int i = 0; i < span.Length; i++) span[i] = (float)(span[i] * gain);
    }

    private bool DrainCommands()
    {
        bool any = false;
        while (_commands.TryDequeue(out var cmd))
        {
            any = true;
            switch (cmd.Kind)
            {
                case PipelineCommandKind.LoadCurrent:
                    DoLoadCurrent(cmd.Segment!);
                    break;
                case PipelineCommandKind.PreloadNext:
                    _next?.Decoder.Dispose();
                    _next = cmd.Segment;
                    AdoptPreloadIfTheCurrentTrackAlreadyDrained();
                    break;
                case PipelineCommandKind.Seek:
                    DoSeek(TimeSpan.FromTicks(cmd.SeekTicks));
                    break;
                case PipelineCommandKind.Stop:
                    DoStop();
                    break;
            }
        }
        return any;
    }

    private void DoLoadCurrent(Segment segment)
    {
        MuteAndClear(() =>
        {
            _current?.Decoder.Dispose();
            _next?.Decoder.Dispose();
            _next = null;
            _current = segment;
            _eq.Reset();

            long frame = _ring.TotalWritten / Channels;
            Interlocked.Exchange(ref _baseFrame, frame);
            Interlocked.Exchange(ref _currentDurationTicks, segment.DurationTicks);
            Interlocked.Exchange(ref _endFrame, -1);
            _playbackEndedFired = false;
            while (_boundaries.TryDequeue(out _)) { }
            _state = (int)PlaybackState.Playing;
        });
    }

    private void DoSeek(TimeSpan position)
    {
        var current = _current;
        if (current is null) return;

        MuteAndClear(() =>
        {
            current.Decoder.Seek(position < TimeSpan.Zero ? TimeSpan.Zero : position);
            _eq.Reset();

            long producedFrames = _ring.TotalWritten / Channels;
            long seekFrames = (long)(position.TotalSeconds * SampleRate);
            Interlocked.Exchange(ref _baseFrame, producedFrames - seekFrames);
            Interlocked.Exchange(ref _endFrame, -1);
            _playbackEndedFired = false;
            _state = (int)PlaybackState.Playing;
        });
    }

    private void DoStop()
    {
        MuteAndClear(() =>
        {
            _current?.Decoder.Dispose();
            _next?.Decoder.Dispose();
            _current = null;
            _next = null;
            _eq.Reset();
            Interlocked.Exchange(ref _currentDurationTicks, 0);
            Interlocked.Exchange(ref _endFrame, -1);
            _playbackEndedFired = false;
            while (_boundaries.TryDequeue(out _)) { }
            _state = (int)PlaybackState.Stopped;
        });
    }

    /// <summary>
    /// Run a structural change that clears the ring, with the renderer muted so
    /// its read cursor is not touched from two threads. Falls through after a
    /// short wait if the renderer is not being called at all (device stopped),
    /// which is safe because then nothing reads the ring either.
    /// </summary>
    private void MuteAndClear(Action mutate)
    {
        _muteRender = true;
        var spin = new SpinWait();
        long deadline = Environment.TickCount64 + 40;
        while (!_renderAck && Environment.TickCount64 < deadline) spin.SpinOnce();

        _ring.Clear();
        mutate();

        _muteRender = false;
    }

    private void NotifyLoop()
    {
        while (_running)
        {
            _notifySignal.Wait();
            while (_notifications.TryDequeue(out var n))
            {
                switch (n.Kind)
                {
                    case NotificationKind.TrackChanged: TrackChanged?.Invoke(n.Token); break;
                    case NotificationKind.Ended: PlaybackEnded?.Invoke(); break;
                    case NotificationKind.Error: Error?.Invoke((string?)n.Token ?? "audio error"); break;
                }
            }
        }
    }

    private void Enqueue(Notification n)
    {
        _notifications.Enqueue(n);
        _notifySignal.Release();
    }

    public void ReportError(string message) => Enqueue(new Notification(NotificationKind.Error, message));

    public void Dispose()
    {
        _running = false;
        _notifySignal.Release();
        if (_pumpThread.IsAlive) _pumpThread.Join(500);
        if (_notifyThread.IsAlive) _notifyThread.Join(500);
        _current?.Decoder.Dispose();
        _next?.Decoder.Dispose();
        _notifySignal.Dispose();
    }

    private sealed class Segment
    {
        public required IPcmDecoder Decoder { get; init; }
        public object? Token { get; init; }
        public long DurationTicks { get; init; }
        public double? TrackDb { get; init; }
        public double? AlbumDb { get; init; }

        public static Segment From(IPcmDecoder decoder, AudioSource source, object? token)
        {
            var duration = source.KnownDuration ?? decoder.Duration ?? TimeSpan.Zero;
            return new Segment
            {
                Decoder = decoder,
                Token = token,
                DurationTicks = duration.Ticks,
                TrackDb = source.ReplayGainTrackDb,
                AlbumDb = source.ReplayGainAlbumDb,
            };
        }
    }

    private enum PipelineCommandKind { LoadCurrent, PreloadNext, Seek, Stop }

    private readonly struct PipelineCommand(PipelineCommandKind kind, object? segment, long seekTicks = 0)
    {
        public PipelineCommandKind Kind { get; } = kind;
        public Segment? Segment { get; } = (Segment?)segment;
        public long SeekTicks { get; } = seekTicks;
    }

    private readonly record struct Boundary(long Frame, object? Token, long DurationTicks);

    private enum NotificationKind { TrackChanged, Ended, Error }

    private readonly record struct Notification(NotificationKind Kind, object? Token);
}
