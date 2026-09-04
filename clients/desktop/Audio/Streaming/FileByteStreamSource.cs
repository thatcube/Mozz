using System.IO;

namespace Mozz.Desktop.Audio.Streaming;

/// <summary>
/// Reads a track from a file on disk — the simple case, and the one downloads
/// use. Kept separate from the HTTP source rather than folded into it: a local
/// file needs none of the range requests, retries or buffering a network
/// stream does, and one class doing both would drag that machinery into the
/// path that has no use for it.
/// </summary>
public sealed class FileByteStreamSource : ByteStreamSource
{
    private readonly FileStream _stream;
    private bool _closed;

    /// <summary>
    /// Opens <paramref name="path"/> for reading. Throws if the file is
    /// missing or unreadable, so the caller can report why and refuse to play
    /// rather than starting a track that will never make a sound.
    /// </summary>
    public FileByteStreamSource(string path)
    {
        _stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
    }

    public override int Read(Span<byte> buffer)
    {
        if (_closed || buffer.Length == 0) return 0;
        try
        {
            // FileStream.Read returns 0 only at end of file; a short read
            // mid-file is normal and must not be mistaken for the end.
            return _stream.Read(buffer);
        }
        catch
        {
            return -1;
        }
    }

    public override long Seek(long offset, int whence)
    {
        if (_closed) return -1;
        try
        {
            // Length does not move the cursor, so unlike the Swift FileHandle
            // version there is no "read the position before asking the size"
            // hazard here: the .NET Position setter is an absolute seek.
            long size = _stream.Length;
            long origin = whence switch
            {
                1 => _stream.Position,
                2 => size,
                _ => 0,
            };
            long target = Math.Clamp(origin + offset, 0, size);
            _stream.Position = target;
            return target;
        }
        catch
        {
            return -1;
        }
    }

    public override void Close()
    {
        if (_closed) return;
        _closed = true;
        _stream.Dispose();
    }
}
