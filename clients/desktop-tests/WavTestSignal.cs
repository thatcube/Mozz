using System.Text;

namespace Mozz.Desktop.Tests;

/// <summary>
/// Builds tiny in-memory WAV files for the decoder and pipeline tests. Everything
/// is IEEE float32 so a round-trip through the decoder is exact (no quantisation),
/// which is what lets the gapless test assert sample-accurate contiguity.
/// </summary>
internal static class WavTestSignal
{
    /// <summary>
    /// A float32 WAV holding <paramref name="frameCount"/> frames of a sine at
    /// <paramref name="frequencyHz"/>, phased as if it started at absolute frame
    /// <paramref name="startFrame"/>. Two files generated with contiguous
    /// start frames therefore join into one continuous wave.
    /// </summary>
    public static byte[] SineFloat(int sampleRate, int channels, long startFrame, int frameCount, double frequencyHz, double amplitude = 0.8)
    {
        int bytesPerSample = 4;
        int blockAlign = channels * bytesPerSample;
        int dataBytes = frameCount * blockAlign;

        using var ms = new MemoryStream(44 + dataBytes);
        // BinaryWriter is little-endian on every platform we target, which is the
        // byte order WAV requires.
        using var w = new BinaryWriter(ms, Encoding.ASCII, leaveOpen: true);

        w.Write("RIFF"u8.ToArray());
        w.Write((uint)(36 + dataBytes));
        w.Write("WAVE"u8.ToArray());

        w.Write("fmt "u8.ToArray());
        w.Write(16u);
        w.Write((ushort)3);                 // IEEE float
        w.Write((ushort)channels);
        w.Write((uint)sampleRate);
        w.Write((uint)(sampleRate * blockAlign));
        w.Write((ushort)blockAlign);
        w.Write((ushort)(bytesPerSample * 8));

        w.Write("data"u8.ToArray());
        w.Write((uint)dataBytes);

        for (int i = 0; i < frameCount; i++)
        {
            float v = Expected(startFrame + i, sampleRate, frequencyHz, amplitude);
            for (int c = 0; c < channels; c++) w.Write(v);
        }

        w.Flush();
        return ms.ToArray();
    }

    /// <summary>The exact sample value the decoder should produce for global frame <paramref name="frame"/>.</summary>
    public static float Expected(long frame, int sampleRate, double frequencyHz, double amplitude = 0.8)
        => (float)(amplitude * Math.Sin(2 * Math.PI * frequencyHz * frame / sampleRate));
}
