namespace Mozz.Desktop.Audio.Decoding;

/// <summary>
/// Everything that can turn a source into a stream of PCM the engine can play.
/// Implementations always hand back interleaved 32-bit float at the engine's
/// device rate and channel count, so the mixer downstream never has to care
/// where the audio came from or what it was encoded as.
/// </summary>
internal interface IPcmDecoder : IDisposable
{
    /// <summary>Sample rate of the frames produced — always the engine rate.</summary>
    int SampleRate { get; }

    /// <summary>Channel count of the frames produced — always the engine channel count.</summary>
    int Channels { get; }

    /// <summary>Track length if it is known, else null.</summary>
    TimeSpan? Duration { get; }

    /// <summary>Whether <see cref="Seek"/> is supported for this source.</summary>
    bool CanSeek { get; }

    /// <summary>
    /// Fill up to <paramref name="frameCount"/> interleaved frames into
    /// <paramref name="destination"/> and return how many were produced. A
    /// return of 0 means end of stream. May block (network, disk); it is always
    /// called on the pump thread, never the UI or audio thread.
    /// </summary>
    int ReadFrames(Span<float> destination, int frameCount);

    /// <summary>Reposition to <paramref name="position"/>. No-op if the source can't seek.</summary>
    void Seek(TimeSpan position);
}
