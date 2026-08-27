using System;
using System.Linq;
using System.Net;
using System.Threading;
using System.Threading.Tasks;
using Mozz.Desktop.Core;
using Xunit;

namespace Mozz.Desktop.Tests;

/// <summary>
/// The reverse direction: a fresh Windows/macOS/Linux desktop listens while an
/// established device connects. mDNS itself is integration-tested against the
/// real iPhone; this pins the socket lifecycle without making CI depend on
/// multicast being enabled.
/// </summary>
public sealed class PairingHostTests
{
    [Fact]
    public async Task AHostAcceptsARealFramedConnection()
    {
        using var host = PairingHost.Start("Mozz desktop test");
        using var client = await PairingLink.ConnectAsync(IPAddress.Loopback, host.Port);
        using var accepted = await host.AcceptAsync();

        var frame = Enumerable.Repeat((byte)0x5A, 73).ToArray();
        await client.SendAsync(frame);

        Assert.Equal(frame, await accepted.ReceiveAsync());
    }

    [Fact]
    public async Task WaitingForADeviceCanBeCancelled()
    {
        using var host = PairingHost.Start("Mozz cancellation test");
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => host.AcceptAsync(cancellation.Token));
    }
}
