using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Mozz.Desktop.Core;
using Xunit;

namespace Mozz.Desktop.Tests;

/// <summary>
/// The framing is the one piece of pairing written twice, so these mirror
/// <c>Tests/MozzPairingTests/PairingWireTests.swift</c> case for case. Two
/// implementations that are only tested differently will eventually differ.
/// </summary>
public class PairingWireTests
{
    private static byte[] Payload(byte value, int count) => Enumerable.Repeat(value, count).ToArray();

    [Fact]
    public void AWholeFrameInOneRead()
    {
        var wire = new PairingWire();
        var body = Payload(0xAA, 40);
        var frames = wire.Append(PairingWire.Frame(body));
        Assert.Single(frames);
        Assert.Equal(body, frames[0]);
        Assert.Equal(0, wire.PendingByteCount);
    }

    [Fact]
    public void AFrameSplitAcrossTwoReads()
    {
        var wire = new PairingWire();
        var framed = PairingWire.Frame(Payload(0xBB, 100));
        var half = framed.Length / 2;

        Assert.Empty(wire.Append(framed.AsSpan(0, half)));
        Assert.Single(wire.Append(framed.AsSpan(half)));
    }

    [Fact]
    public void ALengthPrefixSplitDownTheMiddle()
    {
        var wire = new PairingWire();
        var framed = PairingWire.Frame(Payload(0xCC, 10));

        // A reader that assumes it can always see the whole prefix at once
        // corrupts here.
        Assert.Empty(wire.Append(framed.AsSpan(0, 2)));
        var frames = wire.Append(framed.AsSpan(2));
        Assert.Single(frames);
        Assert.Equal(Payload(0xCC, 10), frames[0]);
    }

    [Fact]
    public void TwoFramesInOneRead()
    {
        var wire = new PairingWire();
        var combined = PairingWire.Frame(Payload(0x01, 8))
            .Concat(PairingWire.Frame(Payload(0x02, 12))).ToArray();

        var frames = wire.Append(combined);
        Assert.Equal(2, frames.Count);
        Assert.Equal(Payload(0x01, 8), frames[0]);
        Assert.Equal(Payload(0x02, 12), frames[1]);
    }

    [Fact]
    public void AFrameAndAHalf()
    {
        var wire = new PairingWire();
        var second = PairingWire.Frame(Payload(0x02, 30));
        var combined = PairingWire.Frame(Payload(0x01, 8))
            .Concat(second.Take(10)).ToArray();

        Assert.Single(wire.Append(combined));
        Assert.Equal(10, wire.PendingByteCount);

        var frames = wire.Append(second.AsSpan(10));
        Assert.Single(frames);
        Assert.Equal(Payload(0x02, 30), frames[0]);
    }

    [Fact]
    public void ByteAtATime()
    {
        var wire = new PairingWire();
        var framed = PairingWire.Frame(Payload(0xDD, 64));
        var delivered = new List<byte[]>();

        foreach (var b in framed)
        {
            delivered.AddRange(wire.Append(new[] { b }));
        }

        // The worst case a real socket can produce.
        Assert.Single(delivered);
        Assert.Equal(Payload(0xDD, 64), delivered[0]);
    }

    [Fact]
    public void AnEmptyFrameIsStillAFrame()
    {
        var wire = new PairingWire();
        var frames = wire.Append(PairingWire.Frame(Array.Empty<byte>()));
        Assert.Single(frames);
        Assert.Empty(frames[0]);
    }

    [Fact]
    public void EmptyReadsChangeNothing()
    {
        var wire = new PairingWire();
        Assert.Empty(wire.Append(Array.Empty<byte>()));
        Assert.Single(wire.Append(PairingWire.Frame(Payload(0x01, 4))));
    }

    [Fact]
    public void AnOversizedLengthIsRefusedBeforeBuffering()
    {
        var wire = new PairingWire();
        // Claims 4 GiB. A reader that waits for it holds the buffer open
        // forever; one that reserves it first falls over immediately.
        Assert.Throws<InvalidDataException>(() =>
        {
            wire.Append(new byte[] { 0xFF, 0xFF, 0xFF, 0xFF });
        });
    }

    [Theory]
    [InlineData(0xFF, 0xFF, 0xFF, 0xFF)]   // 4 GiB, and negative once cast to int
    [InlineData(0x80, 0x00, 0x00, 0x00)]   // exactly the high bit
    [InlineData(0x00, 0x01, 0x00, 0x00)]   // 64 KiB: positive, still over the limit
    public void AnyLengthOverTheLimitIsRefusedHoweverItIsEncoded(byte a, byte b, byte c, byte d)
    {
        var wire = new PairingWire();
        // The first two are the interesting ones: cast to int before comparing
        // and they become negative, pass the limit check, and index out of
        // bounds. Swift reads into a 64-bit Int and refuses them, so a narrowing
        // bug here is a divergence on precisely the input an attacker chooses.
        Assert.Throws<InvalidDataException>(() =>
        {
            wire.Append(new[] { a, b, c, d });
        });
    }

    /// <summary>
    /// The framing produced here must be byte-identical to Swift's. These are
    /// the exact bytes <c>PairingWire.frame</c> emits for the same input.
    /// </summary>
    [Fact]
    public void TheLengthPrefixMatchesSwiftByteForByte()
    {
        Assert.Equal(new byte[] { 0x00, 0x00, 0x00, 0x00 }, PairingWire.Frame(Array.Empty<byte>()));
        Assert.Equal(new byte[] { 0x00, 0x00, 0x00, 0x03, 0x01, 0x02, 0x03 },
                     PairingWire.Frame(new byte[] { 0x01, 0x02, 0x03 }));
        // 300 bytes exercises the second length byte, where a little-endian
        // mistake would still pass every single-byte case above.
        var long300 = PairingWire.Frame(Payload(0x07, 300));
        Assert.Equal(new byte[] { 0x00, 0x00, 0x01, 0x2C }, long300.Take(4).ToArray());
    }
}
