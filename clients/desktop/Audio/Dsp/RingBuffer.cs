namespace Mozz.Desktop.Audio.Dsp;

/// <summary>
/// A single-producer / single-consumer float ring buffer — the seam between the
/// decode thread that fills it and the audio callback that drains it. One thread
/// writes, one thread reads, so it needs no lock: the two monotonic sequence
/// counters are published with <see cref="Volatile"/> writes and everything else
/// follows from their difference.
///
/// The audio callback must never block or allocate, so <see cref="Read"/> takes
/// only what is there and the caller pads the rest with silence.
/// </summary>
internal sealed class RingBuffer(int capacitySamples)
{
    private readonly float[] _buffer = new float[capacitySamples];
    private readonly int _capacity = capacitySamples;

    // Total samples ever written / read. They only grow; the physical index is
    // the sequence modulo capacity. Published with Volatile so the other thread
    // sees a consistent value without a lock.
    private long _written;
    private long _read;

    public int Capacity => _capacity;

    public long TotalWritten => Volatile.Read(ref _written);
    public long TotalRead => Volatile.Read(ref _read);

    public int Count => (int)(Volatile.Read(ref _written) - Volatile.Read(ref _read));
    public int Space => _capacity - Count;

    /// <summary>Producer side. Writes as much as fits and reports how much that was.</summary>
    public int Write(ReadOnlySpan<float> source)
    {
        int n = Math.Min(Space, source.Length);
        if (n == 0) return 0;

        long w = Volatile.Read(ref _written);
        int idx = (int)(w % _capacity);
        int first = Math.Min(n, _capacity - idx);
        source[..first].CopyTo(_buffer.AsSpan(idx));
        if (n > first) source.Slice(first, n - first).CopyTo(_buffer.AsSpan(0));

        Volatile.Write(ref _written, w + n);
        return n;
    }

    /// <summary>Consumer side. Reads as much as is available and reports how much that was.</summary>
    public int Read(Span<float> destination)
    {
        int n = Math.Min(Count, destination.Length);
        if (n == 0) return 0;

        long r = Volatile.Read(ref _read);
        int idx = (int)(r % _capacity);
        int first = Math.Min(n, _capacity - idx);
        _buffer.AsSpan(idx, first).CopyTo(destination);
        if (n > first) _buffer.AsSpan(0, n - first).CopyTo(destination[first..]);

        Volatile.Write(ref _read, r + n);
        return n;
    }

    /// <summary>
    /// Discard everything buffered by fast-forwarding the read cursor to the write
    /// cursor. Only the producer calls this, and only when the consumer has been
    /// told to output silence (during a seek), so the two never race here.
    /// </summary>
    public void Clear() => Volatile.Write(ref _read, Volatile.Read(ref _written));
}
