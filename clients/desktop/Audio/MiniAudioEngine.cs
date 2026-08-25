using System.Collections.Concurrent;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Hexa.NET.MiniAudio;
using Mozz.Desktop.Audio.Decoding;

namespace Mozz.Desktop.Audio;

/// <summary>
/// The one implementation of <see cref="IAudioEngine"/>, and the only file in the
/// app that knows an output device is a native library. It pairs miniaudio (the
/// cross-platform device: WASAPI on Windows, CoreAudio on macOS, ALSA/PulseAudio
/// on Linux) with FFmpeg for decode/HTTP, and puts a sample-accurate
/// <see cref="PcmPipeline"/> between them so playback is gapless. See
/// <c>Audio/README.md</c> for the backend rationale and licensing.
///
/// miniaudio drives everything from its own real-time callback, which on every
/// platform runs on a thread miniaudio owns — on macOS that thread is serviced by
/// the process run loop, which Avalonia already pumps. If the device cannot be
/// opened at all (a headless CI box with no audio), the engine falls back to a
/// silent clock so position still advances and the queue still turns over.
/// </summary>
public sealed unsafe class MiniAudioEngine : IAudioEngine
{
    public const int DeviceSampleRate = 48000;
    public const int DeviceChannels = 2;

    private static readonly ConcurrentDictionary<nint, MiniAudioEngine> Instances = new();

    private readonly PcmPipeline _pipeline;
    private nint _devicePtr;
    private bool _deviceOpen;
    private volatile bool _shuttingDown;

    private Thread? _silentClock;
    private volatile bool _running = true;

    public event EventHandler<TrackChangedEventArgs>? TrackChanged;
    public event EventHandler? PlaybackEnded;
    public event EventHandler<AudioErrorEventArgs>? Error;

    public MiniAudioEngine()
    {
        _pipeline = new PcmPipeline(DeviceSampleRate, DeviceChannels);
        _pipeline.TrackChanged += token => TrackChanged?.Invoke(this, new TrackChangedEventArgs(token));
        _pipeline.PlaybackEnded += () => PlaybackEnded?.Invoke(this, EventArgs.Empty);
        _pipeline.Error += message => Error?.Invoke(this, new AudioErrorEventArgs(message));

        TryOpenDevice();
    }

    public PlaybackState State => _pipeline.State;
    public TimeSpan Position => _pipeline.Position;
    public TimeSpan Duration => _pipeline.Duration;

    public double Volume
    {
        get => _pipeline.Volume;
        set => _pipeline.Volume = value;
    }

    public bool Play(AudioSource source, object? token = null)
    {
        if (!TryCreateDecoder(source, out var decoder)) return false;
        _pipeline.LoadCurrent(decoder, source, token);
        return true;
    }

    public void PreloadNext(AudioSource source, object? token = null)
    {
        if (!TryCreateDecoder(source, out var decoder)) return;
        _pipeline.PreloadNext(decoder, source, token);
    }

    public void Pause() => _pipeline.Pause();
    public void Resume() => _pipeline.Resume();
    public void Stop() => _pipeline.Stop();
    public void Seek(TimeSpan position) => _pipeline.Seek(position);
    public void SetEqualizer(EqualizerSettings settings) => _pipeline.SetEqualizer(settings);
    public void SetReplayGain(ReplayGainMode mode, double preampDb = 0.0) => _pipeline.SetReplayGain(mode, preampDb);

    private bool TryCreateDecoder(AudioSource source, out IPcmDecoder decoder)
    {
        try
        {
            decoder = DecoderFactory.Create(source, DeviceSampleRate, DeviceChannels);
            return true;
        }
        catch (Exception ex)
        {
            decoder = null!;
            Error?.Invoke(this, new AudioErrorEventArgs(
                AudioDiagnostics.DescribeOpenFailure(source.Uri, ex.Message), ex));
            return false;
        }
    }

    private void TryOpenDevice()
    {
        try
        {
            var config = MiniAudio.DeviceConfigInit(MaDeviceType.Playback);
            config.Playback.Format = MaFormat.F32;
            config.Playback.Channels = DeviceChannels;
            config.SampleRate = DeviceSampleRate;
            config.DataCallback = (void*)(delegate* unmanaged[Cdecl]<nint, void*, void*, uint, void>)&DeviceDataCallback;

            _devicePtr = (nint)NativeMemory.AllocZeroed((nuint)sizeof(MaDevice));
            Instances[_devicePtr] = this;

            var initResult = MiniAudio.DeviceInit((MaContextPtr)default, &config, (MaDevice*)_devicePtr);
            if (initResult != MaResult.Success)
            {
                Instances.TryRemove(_devicePtr, out _);
                NativeMemory.Free((void*)_devicePtr);
                _devicePtr = 0;
                StartSilentClock($"audio device init failed ({initResult})");
                return;
            }

            var startResult = MiniAudio.DeviceStart((MaDevice*)_devicePtr);
            if (startResult != MaResult.Success)
            {
                MiniAudio.DeviceUninit((MaDevice*)_devicePtr);
                Instances.TryRemove(_devicePtr, out _);
                NativeMemory.Free((void*)_devicePtr);
                _devicePtr = 0;
                StartSilentClock($"audio device start failed ({startResult})");
                return;
            }

            _deviceOpen = true;
        }
        catch (Exception ex)
        {
            StartSilentClock($"audio device unavailable ({ex.Message})");
        }
    }

    /// <summary>
    /// No usable device: run the pipeline against a discard buffer at real time so
    /// the transport still advances and end-of-track still drives the queue. Silent,
    /// and reported to the app so it can say so.
    /// </summary>
    private void StartSilentClock(string reason)
    {
        _silentClock = new Thread(() =>
        {
            const int blockFrames = DeviceSampleRate / 100; // 10 ms
            var buffer = new float[blockFrames * DeviceChannels];
            var sw = System.Diagnostics.Stopwatch.StartNew();
            long produced = 0;
            while (_running)
            {
                _pipeline.Render(buffer);
                produced += blockFrames;
                double dueMs = produced * 1000.0 / DeviceSampleRate;
                double aheadMs = dueMs - sw.Elapsed.TotalMilliseconds;
                if (aheadMs > 1) Thread.Sleep((int)aheadMs);
            }
        })
        { IsBackground = true, Name = "audio-silent-clock" };
        _silentClock.Start();

        Error?.Invoke(this, new AudioErrorEventArgs($"Playing silently: {reason}."));
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) })]
    private static void DeviceDataCallback(nint pDevice, void* pOutput, void* pInput, uint frameCount)
    {
        int samples = (int)frameCount * DeviceChannels;
        var output = new Span<float>(pOutput, samples);

        if (!Instances.TryGetValue(pDevice, out var engine) || engine._shuttingDown)
        {
            output.Clear();
            return;
        }

        engine._pipeline.Render(output);
    }

    public void Dispose()
    {
        _running = false;
        _shuttingDown = true;
        _silentClock?.Join(500);

        if (_deviceOpen && _devicePtr != 0)
        {
            Instances.TryRemove(_devicePtr, out _);
            MiniAudio.DeviceUninit((MaDevice*)_devicePtr); // stops the device and joins its callback thread
            NativeMemory.Free((void*)_devicePtr);
            _devicePtr = 0;
            _deviceOpen = false;
        }

        _pipeline.Dispose();
        GC.SuppressFinalize(this);
    }
}
