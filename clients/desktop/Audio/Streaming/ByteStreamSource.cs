namespace Mozz.Desktop.Audio.Streaming;

/// <summary>
/// A stream of encoded audio bytes the shell owns and the Rust engine reads
/// through its <c>read</c>/<c>seek</c>/<c>close</c> callbacks.
///
/// The engine never fetches anything itself — credentials, retries and range
/// requests are the shell's job, exactly as <c>MozzCore</c> owns everything
/// native. This type is the C# side of that contract and is deliberately
/// free of any native interop, so it can be exercised in a unit test without
/// the dylib present.
///
/// Every method blocks the caller. That is correct: the engine only ever
/// calls these from its decode thread, never from the audio callback, and a
/// decode thread that blocks 200ms on a slow server is a decode thread doing
/// its job.
/// </summary>
public abstract class ByteStreamSource : IDisposable
{
    /// <summary>
    /// Fill as much of <paramref name="buffer"/> as is available now. Returns
    /// the number of bytes written, <c>0</c> at the end of the stream, or a
    /// negative value on error. Fewer bytes than requested is not the end.
    /// </summary>
    public abstract int Read(Span<byte> buffer);

    /// <summary>
    /// Move the read cursor. <paramref name="whence"/> is 0 from the start, 1
    /// from the current position, 2 from the end. Returns the new absolute
    /// position, or a negative value on error. A source that cannot seek
    /// cannot be decoded, because containers keep their index at the end.
    /// </summary>
    public abstract long Seek(long offset, int whence);

    /// <summary>
    /// Release everything the source holds. Called exactly once, from the
    /// decode thread, when the decoder is finished. Safe to call again.
    /// </summary>
    public abstract void Close();

    public void Dispose() => Close();
}
