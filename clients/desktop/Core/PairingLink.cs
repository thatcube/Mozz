using System;
using System.Buffers;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;

namespace Mozz.Desktop.Core;

/// <summary>
/// One pairing conversation over one socket.
/// </summary>
/// <remarks>
/// Deliberately thin, and the mirror of <c>PairingLink</c> in Swift. The
/// protocol and the crypto live in the core and are reached through
/// <c>pairingReceive</c>; what is left here is a socket and a length prefix.
/// </remarks>
public sealed class PairingLink : IDisposable
{
    private readonly TcpClient _client;
    private readonly NetworkStream _stream;
    private readonly PairingWire _wire = new();
    private readonly Queue<byte[]> _buffered = new();

    private PairingLink(TcpClient client)
    {
        _client = client;
        _stream = client.GetStream();
    }

    public static async Task<PairingLink> ConnectAsync(
        IPAddress address, int port, CancellationToken token = default)
    {
        var client = new TcpClient();
        // A device that is on the network but not listening should fail quickly
        // rather than leave someone watching a spinner; pairing is face to face
        // and a person is waiting on both ends.
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(TimeSpan.FromSeconds(10));
        await client.ConnectAsync(address, port, timeout.Token).ConfigureAwait(false);
        return new PairingLink(client);
    }

    internal static PairingLink FromAcceptedClient(TcpClient client) =>
        new(client);

    public async Task SendAsync(byte[] frame, CancellationToken token = default)
    {
        var framed = PairingWire.Frame(frame);
        await _stream.WriteAsync(framed, token).ConfigureAwait(false);
        await _stream.FlushAsync(token).ConfigureAwait(false);
    }

    /// <summary>
    /// Reads until one whole frame is available. A read returning fewer bytes
    /// than a frame is ordinary rather than exceptional, which is why the loop
    /// is here and the reassembly is in <see cref="PairingWire"/>.
    /// </summary>
    public async Task<byte[]> ReceiveAsync(CancellationToken token = default)
    {
        while (true)
        {
            if (_buffered.Count > 0) return _buffered.Dequeue();

            var rented = ArrayPool<byte>.Shared.Rent(PairingWire.MaxFrameLength);
            try
            {
                var read = await _stream.ReadAsync(rented.AsMemory(0, PairingWire.MaxFrameLength), token)
                    .ConfigureAwait(false);
                if (read == 0) throw new IOException("the other device closed the connection");

                foreach (var frame in _wire.Append(rented.AsSpan(0, read)))
                {
                    _buffered.Enqueue(frame);
                }
            }
            finally
            {
                ArrayPool<byte>.Shared.Return(rented);
            }
        }
    }

    public void Dispose()
    {
        _stream.Dispose();
        _client.Dispose();
    }
}
