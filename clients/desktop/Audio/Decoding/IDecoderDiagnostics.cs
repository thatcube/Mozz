namespace Mozz.Desktop.Audio.Decoding;

/// <summary>
/// An optional companion to <see cref="IPcmDecoder"/> for decoders that run a
/// fallible external process and can explain, after the fact, why their stream
/// ended early. The pipeline treats a decoder that stops producing frames as a
/// finished track; a decoder that also implements this can turn "produced
/// nothing and exited with an error" into a message the listener actually sees,
/// instead of a track that silently refuses to play.
/// </summary>
internal interface IDecoderDiagnostics
{
    /// <summary>
    /// True if the decode terminated abnormally, with <paramref name="reason"/>
    /// set to a user-facing, credential-free explanation. False for a clean
    /// end-of-stream or a decoder that was torn down deliberately (seek, stop,
    /// dispose), so a normal finish is never mistaken for a failure.
    /// </summary>
    bool TryGetFailure(out string reason);
}
