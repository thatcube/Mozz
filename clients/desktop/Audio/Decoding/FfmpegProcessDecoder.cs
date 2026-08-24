using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace Mozz.Desktop.Audio.Decoding;

/// <summary>
/// Decodes anything FFmpeg can, by driving the <c>ffmpeg</c> binary as a child
/// process and reading raw <c>f32le</c> from its stdout. Going out-of-process is
/// a deliberate choice: it is immune to libav ABI churn (the machine's FFmpeg 9
/// ships avcodec 63), it puts FFmpeg's GPL/LGPL code behind a process boundary
/// rather than linking it in, and FFmpeg already solves HTTP(S) with auth
/// headers, byte-range seeking, reconnection and buffering — the exact things a
/// remote music library needs. The cost is one process per track and pipe I/O,
/// which is nothing next to audio decoding itself.
///
/// All the work happens on the engine's pump thread, so a network stall blocks
/// only decoding; the device keeps draining the ring buffer and the UI never
/// feels it.
/// </summary>
internal sealed class FfmpegProcessDecoder : IPcmDecoder
{
    private readonly AudioSource _source;
    private readonly string _ffmpegPath;
    private Process? _process;
    private Stream? _stdout;

    private readonly int _frameBytes;
    private byte[] _buffer = [];
    private readonly byte[] _residual;
    private int _residualLen;

    private readonly StringBuilder _stderrTail = new();
    private readonly object _stderrLock = new();

    public int SampleRate { get; }
    public int Channels { get; }
    public TimeSpan? Duration { get; }
    public bool CanSeek => true;

    public FfmpegProcessDecoder(AudioSource source, int targetRate, int targetChannels, string? ffmpegPath = null)
    {
        _source = source;
        SampleRate = targetRate;
        Channels = targetChannels;
        Duration = source.KnownDuration;
        _frameBytes = targetChannels * sizeof(float);
        _residual = new byte[_frameBytes];
        _ffmpegPath = ffmpegPath
            ?? Environment.GetEnvironmentVariable("MOZZ_FFMPEG")
            ?? "ffmpeg";

        Start(TimeSpan.Zero);
    }

    /// <summary>The last few stderr lines, for surfacing a decode failure to the user.</summary>
    public string LastError
    {
        get { lock (_stderrLock) return _stderrTail.ToString().Trim(); }
    }

    private void Start(TimeSpan seekTo)
    {
        var psi = new ProcessStartInfo
        {
            FileName = _ffmpegPath,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };

        psi.ArgumentList.Add("-nostdin");
        psi.ArgumentList.Add("-hide_banner");
        psi.ArgumentList.Add("-loglevel");
        psi.ArgumentList.Add("error");

        bool isHttp = _source.Uri.StartsWith("http://", StringComparison.OrdinalIgnoreCase)
                      || _source.Uri.StartsWith("https://", StringComparison.OrdinalIgnoreCase);
        if (isHttp)
        {
            // Survive transient drops on a long stream rather than ending the track.
            psi.ArgumentList.Add("-reconnect");
            psi.ArgumentList.Add("1");
            psi.ArgumentList.Add("-reconnect_streamed");
            psi.ArgumentList.Add("1");
            psi.ArgumentList.Add("-reconnect_delay_max");
            psi.ArgumentList.Add("4");

            if (_source.Headers is { Count: > 0 })
            {
                var sb = new StringBuilder();
                foreach (var (k, v) in _source.Headers)
                    sb.Append(k).Append(": ").Append(v).Append("\r\n");
                psi.ArgumentList.Add("-headers");
                psi.ArgumentList.Add(sb.ToString());
            }
        }

        // Input seeking (before -i) makes FFmpeg issue an HTTP Range request and
        // jump the demuxer, so a seek costs a reconnect, not a full re-download.
        if (seekTo > TimeSpan.Zero)
        {
            psi.ArgumentList.Add("-ss");
            psi.ArgumentList.Add(seekTo.TotalSeconds.ToString("R", System.Globalization.CultureInfo.InvariantCulture));
        }

        psi.ArgumentList.Add("-i");
        psi.ArgumentList.Add(_source.Uri);

        psi.ArgumentList.Add("-vn");
        psi.ArgumentList.Add("-f");
        psi.ArgumentList.Add("f32le");
        psi.ArgumentList.Add("-acodec");
        psi.ArgumentList.Add("pcm_f32le");
        psi.ArgumentList.Add("-ac");
        psi.ArgumentList.Add(Channels.ToString());
        psi.ArgumentList.Add("-ar");
        psi.ArgumentList.Add(SampleRate.ToString());
        psi.ArgumentList.Add("-");

        Process process;
        try
        {
            process = Process.Start(psi)
                ?? throw new InvalidOperationException($"Could not start '{_ffmpegPath}'");
        }
        catch (Exception ex)
        {
            throw new AudioDecodeException(
                $"FFmpeg could not be started ('{_ffmpegPath}'). Install FFmpeg or set MOZZ_FFMPEG.", ex);
        }

        _process = process;
        _stdout = process.StandardOutput.BaseStream;
        _residualLen = 0;

        // Drain stderr so the pipe never fills (which would stall FFmpeg), and
        // keep the tail for diagnostics.
        var stderr = process.StandardError;
        var t = new Thread(() =>
        {
            string? line;
            while ((line = stderr.ReadLine()) is not null)
            {
                lock (_stderrLock)
                {
                    _stderrTail.AppendLine(line);
                    if (_stderrTail.Length > 2000)
                        _stderrTail.Remove(0, _stderrTail.Length - 2000);
                }
            }
        })
        { IsBackground = true, Name = "ffmpeg-stderr" };
        t.Start();
    }

    public int ReadFrames(Span<float> destination, int frameCount)
    {
        var stdout = _stdout;
        if (stdout is null) return 0;

        int want = frameCount * _frameBytes;
        if (_buffer.Length < want + _frameBytes)
            _buffer = new byte[want + _frameBytes];

        int have = _residualLen;
        if (_residualLen > 0)
        {
            Array.Copy(_residual, 0, _buffer, 0, _residualLen);
            _residualLen = 0;
        }

        while (have < want)
        {
            int n;
            try { n = stdout.Read(_buffer, have, want - have); }
            catch (IOException) { n = 0; }
            if (n <= 0) break; // end of stream
            have += n;
        }

        int frames = have / _frameBytes;
        int used = frames * _frameBytes;
        int leftover = have - used;
        if (leftover > 0)
        {
            Array.Copy(_buffer, used, _residual, 0, leftover);
            _residualLen = leftover;
        }

        if (frames > 0)
        {
            var src = MemoryMarshal.Cast<byte, float>(_buffer.AsSpan(0, used));
            src.CopyTo(destination[..(frames * Channels)]);
        }
        return frames;
    }

    public void Seek(TimeSpan position)
    {
        KillProcess();
        Start(position < TimeSpan.Zero ? TimeSpan.Zero : position);
    }

    private void KillProcess()
    {
        var process = _process;
        _process = null;
        _stdout = null;
        if (process is null) return;

        try
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
        }
        catch
        {
            // Already gone; nothing to do.
        }
        finally
        {
            process.Dispose();
        }
    }

    public void Dispose() => KillProcess();
}

/// <summary>A decode failure worth showing the user (missing codec, unreadable source, no FFmpeg).</summary>
internal sealed class AudioDecodeException(string message, Exception? inner = null)
    : Exception(message, inner);
