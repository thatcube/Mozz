using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;

namespace Mozz.Desktop.Core;

/// <summary>
/// Turns a stream of bytes back into pairing frames, matching
/// <c>Sources/MozzPairing/PairingWire.swift</c>.
/// </summary>
/// <remarks>
/// This is the only part of pairing written twice, and it is deliberately the
/// smallest part. The desktop never decodes a frame's contents — it hands the
/// bytes straight to the core through <c>pairingReceive</c> and gets steps back
/// — so the protocol and the crypto have exactly one implementation. What
/// remains here is a four-byte length prefix, which is small enough to be
/// obviously the same on both sides.
///
/// TCP does not preserve message boundaries, so a frame can arrive in pieces,
/// two frames can arrive in one read, and both can happen at once.
/// </remarks>
public sealed class PairingWire
{
    /// <summary>Matches <c>PairingWire.maxFrameLength</c> in Swift: 8 KiB of
    /// ciphertext plus room for the envelope.</summary>
    public const int MaxFrameLength = 8 * 1024 + 1024;

    private readonly MemoryStream _buffer = new();

    /// <summary>Prefix a payload for the wire.</summary>
    public static byte[] Frame(ReadOnlySpan<byte> payload)
    {
        var framed = new byte[payload.Length + 4];
        BinaryPrimitives.WriteUInt32BigEndian(framed.AsSpan(0, 4), (uint)payload.Length);
        payload.CopyTo(framed.AsSpan(4));
        return framed;
    }

    /// <summary>
    /// Feed whatever arrived; returns every frame that is now complete, which
    /// may be none, one, or several.
    /// </summary>
    public IReadOnlyList<byte[]> Append(ReadOnlySpan<byte> bytes)
    {
        _buffer.Seek(0, SeekOrigin.End);
        _buffer.Write(bytes);

        var held = _buffer.ToArray();
        var frames = new List<byte[]>();
        var offset = 0;

        while (held.Length - offset >= 4)
        {
            // Compare BEFORE narrowing to int. A length with the high bit set
            // casts to a negative int, which sails past a `> MaxFrameLength`
            // check and then indexes out of bounds — so the cast has to come
            // after the limit, not before it. Swift reads this into a 64-bit Int
            // and rejects it correctly, so getting this wrong made the two
            // implementations disagree on exactly the input an attacker picks.
            var claimed = BinaryPrimitives.ReadUInt32BigEndian(held.AsSpan(offset, 4));
            if (claimed > MaxFrameLength)
            {
                // Refuse before reserving anything. A length is a claim, and a
                // claim from a peer we have not authenticated yet is exactly the
                // kind not to act on.
                throw new InvalidDataException($"pairing frame of {claimed} bytes exceeds the limit");
            }
            var length = (int)claimed;
            if (held.Length - offset - 4 < length) break;

            frames.Add(held.AsSpan(offset + 4, length).ToArray());
            offset += 4 + length;
        }

        _buffer.SetLength(0);
        if (offset < held.Length)
        {
            _buffer.Write(held.AsSpan(offset));
        }
        return frames;
    }

    /// <summary>Bytes held back waiting for the rest of their frame.</summary>
    public int PendingByteCount => (int)_buffer.Length;
}
