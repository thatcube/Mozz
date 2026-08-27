using System.Net;
using Mozz.Desktop.Core;
using Xunit;

namespace Mozz.Desktop.Tests;

public sealed class PairingDiscoveryTests
{
    [Fact]
    public void APrivateLanBeatsATailscaleAddress()
    {
        var selected = PairingDiscovery.SelectBestAddress([
            IPAddress.Parse("100.81.93.19"),
            IPAddress.Parse("192.168.68.156"),
        ]);

        Assert.Equal(IPAddress.Parse("192.168.68.156"), selected);
    }

    [Fact]
    public void TailscaleStillWorksWhenItIsTheOnlyRoute()
    {
        var selected = PairingDiscovery.SelectBestAddress([
            IPAddress.Loopback,
            IPAddress.Parse("100.81.93.19"),
        ]);

        Assert.Equal(IPAddress.Parse("100.81.93.19"), selected);
    }

    [Fact]
    public void LoopbackIsNeverOfferedAsAnotherDevice()
    {
        Assert.Null(PairingDiscovery.SelectBestAddress([
            IPAddress.Loopback,
            IPAddress.IPv6Loopback,
        ]));
    }
}
