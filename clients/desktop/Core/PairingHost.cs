using System;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;
using Makaretu.Dns;

namespace Mozz.Desktop.Core;

/// <summary>
/// A fresh desktop waiting to join an existing circle.
/// </summary>
/// <remarks>
/// This is the reverse of <see cref="PairingDiscovery"/>. A desktop with no
/// circle listens and advertises; an established phone or computer opens
/// Devices, discovers it, and connects. That makes setup order irrelevant:
/// phone first and desktop first are the same ceremony with the roles reversed.
/// </remarks>
public sealed class PairingHost : IDisposable
{
    private readonly TcpListener _listener;
    private readonly ServiceDiscovery _discovery;
    private readonly ServiceProfile _profile;

    private PairingHost(string name)
    {
        _listener = new TcpListener(IPAddress.Any, 0);
        _listener.Start();
        var port = ((IPEndPoint)_listener.LocalEndpoint).Port;

        _discovery = new ServiceDiscovery();
        _profile = new ServiceProfile(
            name,
            PairingDiscovery.ServiceType,
            checked((ushort)port));
        _discovery.Advertise(_profile);
        _discovery.Announce(_profile);
    }

    public static PairingHost Start(string name) => new(name);

    internal int Port => ((IPEndPoint)_listener.LocalEndpoint).Port;

    public async Task<PairingLink> AcceptAsync(CancellationToken token = default)
    {
        var client = await _listener.AcceptTcpClientAsync(token).ConfigureAwait(false);
        return PairingLink.FromAcceptedClient(client);
    }

    public void Dispose()
    {
        _discovery.Unadvertise(_profile);
        _discovery.Dispose();
        _listener.Stop();
    }
}
