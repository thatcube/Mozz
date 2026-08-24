using System.Buffers.Binary;

namespace Mozz.Desktop.Audio.Decoding;

/// <summary>
/// A dependency-free RIFF/WAVE decoder. It exists so the engine can prove itself
/// — in unit tests and as a built-in fallback tone — without a working FFmpeg on
/// the machine: everything from the ring buffer up can be exercised with nothing
/// but managed code. It reads PCM (8/16/24/32-bit) and IEEE float (32/64-bit),
/// up-mixes mono to the device layout, and linearly resamples to the device rate.
/// Real, arbitrary formats (FLAC, Opus, AAC, HTTP streams) go through
/// <see cref="FfmpegProcessDecoder"/> instead.
/// </summary>
internal sealed class WavPcmDecoder : IPcmDecoder
{
    private readonly Stream _stream;
    private readonly bool _ownsStream;

    private readonly int _srcRate;
    private readonly int _srcChannels;
    private readonly int _bytesPerSample;
    private readonly bool _isFloat;
    private readonly long _dataStart;
    private readonly long _dataLength;

    private readonly int _srcFrameBytes;
    private readonly byte[] _frameBytes;

    private long _dataPos;
    private readonly float[] _a;
    private readonly float[] _b;
    private bool _hasA, _hasB, _srcEnded, _bIsHold;
    private double _t;
    private readonly double _ratio;

    public int SampleRate { get; }
    public int Channels { get; }
    public TimeSpan? Duration { get; }
    public bool CanSeek => _stream.CanSeek;

    public WavPcmDecoder(Stream stream, int targetRate, int targetChannels, bool ownsStream = true)
    {
        _stream = stream;
        _ownsStream = ownsStream;
        SampleRate = targetRate;
        Channels = targetChannels;
        _a = new float[targetChannels];
        _b = new float[targetChannels];

        (_srcRate, _srcChannels, _bytesPerSample, _isFloat, _dataStart, _dataLength) = ParseHeader(stream);
        _srcFrameBytes = _bytesPerSample * _srcChannels;
        _frameBytes = new byte[_srcFrameBytes];
        _ratio = (double)_srcRate / targetRate;

        long srcFrames = _dataLength / _srcFrameBytes;
        Duration = TimeSpan.FromSeconds((double)srcFrames / _srcRate);

        stream.Position = _dataStart;
    }

    public static WavPcmDecoder Open(string path, int targetRate, int targetChannels)
        => new(File.OpenRead(path), targetRate, targetChannels);

    public int ReadFrames(Span<float> destination, int frameCount)
    {
        int produced = 0;
        for (int f = 0; f < frameCount; f++)
        {
            if (_srcEnded) break;

            if (!_hasA)
            {
                if (!TryLoad(_a)) break; // genuinely no data left
                _hasA = true;
            }
            if (!_hasB)
            {
                // One frame of read-ahead for the interpolator. If there is no
                // next frame, hold the last one so the final source frame is
                // still emitted — dropping it would put a one-sample gap at
                // every track boundary and break gapless.
                if (!TryLoad(_b)) { Array.Copy(_a, _b, Channels); _bIsHold = true; }
                _hasB = true;
            }

            int baseIdx = f * Channels;
            for (int c = 0; c < Channels; c++)
                destination[baseIdx + c] = (float)(_a[c] + (_b[c] - _a[c]) * _t);
            produced++;

            _t += _ratio;
            while (_t >= 1.0)
            {
                _t -= 1.0;
                if (_bIsHold) { _srcEnded = true; break; } // just emitted the held final frame
                Array.Copy(_b, _a, Channels);
                if (!TryLoad(_b)) { Array.Copy(_a, _b, Channels); _bIsHold = true; }
            }
        }
        return produced;
    }

    public void Seek(TimeSpan position)
    {
        if (!_stream.CanSeek) return;
        long frame = Math.Max(0, (long)(position.TotalSeconds * _srcRate));
        long byteOffset = _dataStart + frame * _srcFrameBytes;
        _stream.Position = Math.Min(byteOffset, _dataStart + _dataLength);
        _dataPos = _stream.Position - _dataStart;
        _hasA = _hasB = _srcEnded = _bIsHold = false;
        _t = 0;
    }

    private bool TryLoad(float[] dstFrame)
    {
        if (_dataPos + _srcFrameBytes > _dataLength) return false;
        try { _stream.ReadExactly(_frameBytes, 0, _srcFrameBytes); }
        catch (EndOfStreamException) { return false; }
        _dataPos += _srcFrameBytes;

        for (int c = 0; c < Channels; c++)
        {
            int srcC = _srcChannels == 1 ? 0 : Math.Min(c, _srcChannels - 1);
            dstFrame[c] = ConvertSample(_frameBytes.AsSpan(srcC * _bytesPerSample, _bytesPerSample));
        }
        return true;
    }

    private float ConvertSample(ReadOnlySpan<byte> s)
    {
        if (_isFloat)
        {
            return _bytesPerSample == 8
                ? (float)BitConverter.ToDouble(s)
                : BitConverter.ToSingle(s);
        }

        return _bytesPerSample switch
        {
            1 => (s[0] - 128) / 128f,
            2 => BinaryPrimitives.ReadInt16LittleEndian(s) / 32768f,
            3 => Sign24(s) / 8388608f,
            4 => BinaryPrimitives.ReadInt32LittleEndian(s) / 2147483648f,
            _ => 0f,
        };
    }

    private static int Sign24(ReadOnlySpan<byte> s)
    {
        int v = s[0] | (s[1] << 8) | (s[2] << 16);
        if ((v & 0x800000) != 0) v |= unchecked((int)0xFF000000);
        return v;
    }

    private static (int rate, int channels, int bytesPerSample, bool isFloat, long dataStart, long dataLength)
        ParseHeader(Stream stream)
    {
        Span<byte> hdr = stackalloc byte[12];
        stream.ReadExactly(hdr);
        if (hdr[0] != 'R' || hdr[1] != 'I' || hdr[2] != 'F' || hdr[3] != 'F' ||
            hdr[8] != 'W' || hdr[9] != 'A' || hdr[10] != 'V' || hdr[11] != 'E')
            throw new InvalidDataException("Not a RIFF/WAVE file");

        int channels = 2, rate = 44100, bits = 16;
        bool isFloat = false;
        Span<byte> chunkHeader = stackalloc byte[8];

        while (true)
        {
            int read = stream.Read(chunkHeader);
            if (read < 8) throw new InvalidDataException("WAVE ended before a data chunk");

            uint id = BinaryPrimitives.ReadUInt32BigEndian(chunkHeader);
            uint size = BinaryPrimitives.ReadUInt32LittleEndian(chunkHeader[4..]);

            if (id == 0x666D7420) // "fmt "
            {
                byte[] fmt = new byte[size];
                stream.ReadExactly(fmt, 0, (int)size);
                int format = BinaryPrimitives.ReadUInt16LittleEndian(fmt);
                channels = BinaryPrimitives.ReadUInt16LittleEndian(fmt.AsSpan(2));
                rate = (int)BinaryPrimitives.ReadUInt32LittleEndian(fmt.AsSpan(4));
                bits = BinaryPrimitives.ReadUInt16LittleEndian(fmt.AsSpan(14));
                if (format == 0xFFFE && size >= 26)
                    format = BinaryPrimitives.ReadUInt16LittleEndian(fmt.AsSpan(24)); // extensible sub-format
                isFloat = format == 3;
                if (format is not (1 or 3))
                    throw new InvalidDataException($"Unsupported WAVE format tag {format}");
                if ((size & 1) == 1) stream.Position += 1; // chunks are word-aligned
            }
            else if (id == 0x64617461) // "data"
            {
                long dataStart = stream.Position;
                long remaining = stream.CanSeek ? stream.Length - dataStart : size;
                long length = size == 0 || size > remaining ? remaining : size;
                return (rate, channels, bits / 8, isFloat, dataStart, length);
            }
            else
            {
                stream.Position += size + (size & 1);
            }
        }
    }

    public void Dispose()
    {
        if (_ownsStream) _stream.Dispose();
    }
}
