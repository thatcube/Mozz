namespace Mozz.Desktop.Audio.Decoding;

/// <summary>
/// Chooses a decoder for a source. Local <c>.wav</c> goes through the managed
/// reader so the pipeline works with no external tools; everything else — every
/// compressed format and every HTTP(S) stream — goes through FFmpeg.
/// </summary>
internal static class DecoderFactory
{
    public static IPcmDecoder Create(AudioSource source, int targetRate, int targetChannels)
    {
        bool isHttp = source.Uri.StartsWith("http://", StringComparison.OrdinalIgnoreCase)
                      || source.Uri.StartsWith("https://", StringComparison.OrdinalIgnoreCase);

        if (!isHttp && HasExtension(source.Uri, ".wav"))
        {
            try
            {
                return WavPcmDecoder.Open(source.Uri, targetRate, targetChannels);
            }
            catch (Exception ex) when (ex is InvalidDataException or IOException)
            {
                // A malformed or exotic WAV (e.g. compressed-in-WAV) still has a
                // decoder of last resort.
                return new FfmpegProcessDecoder(source, targetRate, targetChannels);
            }
        }

        return new FfmpegProcessDecoder(source, targetRate, targetChannels);
    }

    private static bool HasExtension(string uri, string ext)
        => uri.EndsWith(ext, StringComparison.OrdinalIgnoreCase);
}
