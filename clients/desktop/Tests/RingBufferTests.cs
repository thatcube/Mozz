using Mozz.Desktop.Audio.Dsp;

namespace Mozz.Desktop.Tests;

public class RingBufferTests
{
    [Fact]
    public void WriteThenRead_RoundTripsValues()
    {
        var ring = new RingBuffer(16);
        float[] input = [1, 2, 3, 4, 5];
        int wrote = ring.Write(input);
        Assert.Equal(5, wrote);
        Assert.Equal(5, ring.Count);

        var output = new float[5];
        int read = ring.Read(output);
        Assert.Equal(5, read);
        Assert.Equal(input, output);
        Assert.Equal(0, ring.Count);
    }

    [Fact]
    public void Write_StopsAtCapacity()
    {
        var ring = new RingBuffer(4);
        int wrote = ring.Write([1, 2, 3, 4, 5, 6]);
        Assert.Equal(4, wrote);
        Assert.Equal(0, ring.Space);
    }

    [Fact]
    public void WrapsAround_PreservingOrder()
    {
        // Capacity 8: fill 6, drain 6, then write 6 more so the write wraps the
        // physical buffer, and confirm the logical order is intact.
        var ring = new RingBuffer(8);
        ring.Write([1, 2, 3, 4, 5, 6]);
        var scratch = new float[6];
        ring.Read(scratch);

        ring.Write([10, 20, 30, 40, 50, 60]);
        var output = new float[6];
        int read = ring.Read(output);

        Assert.Equal(6, read);
        Assert.Equal<float[]>([10, 20, 30, 40, 50, 60], output);
    }

    [Fact]
    public void Read_OnEmpty_ReturnsZero()
    {
        var ring = new RingBuffer(8);
        Assert.Equal(0, ring.Read(new float[4]));
    }

    [Fact]
    public void Clear_DropsPendingSamples()
    {
        var ring = new RingBuffer(8);
        ring.Write([1, 2, 3, 4]);
        ring.Clear();
        Assert.Equal(0, ring.Count);
        Assert.Equal(0, ring.Read(new float[4]));
    }
}
