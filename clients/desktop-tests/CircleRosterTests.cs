using System;
using Mozz.Desktop.Core;
using Xunit;

namespace Mozz.Desktop.Tests;

/// <summary>
/// The device name is what someone reads when deciding whether the device
/// asking to join their circle is their own. A name that is the same on every
/// machine makes that check impossible, which is what "Mozz" did.
/// </summary>
public class CircleRosterTests
{
    [Fact]
    public void TheDeviceNameIsNotTheAppName()
    {
        Assert.NotEqual("Mozz", CircleRoster.DeviceName);
        Assert.False(string.IsNullOrWhiteSpace(CircleRoster.DeviceName));
    }

    [Fact]
    public void TheDeviceNameIsReadableRatherThanAHostname()
    {
        // Environment.MachineName cannot contain spaces, so a machine called
        // "Brandons MacBook Pro" arrives hyphenated. Reading the hyphens back
        // is a guess, but a better one than showing a hostname to a person.
        Assert.DoesNotContain("-", CircleRoster.DeviceName);
    }

    [Fact]
    public void TheDeviceNameFitsTheProtocolLimit()
    {
        // PairingFrame caps names at 64 UTF-8 bytes and truncates beyond it;
        // producing something that would be silently cut is worse than trimming
        // it here where the reason is visible.
        Assert.True(CircleRoster.DeviceName.Length <= 64);
    }

    [Fact]
    public void AMemberRowSaysWhichDeviceYouAreHolding()
    {
        var self = new CircleMemberRow(
            "This Mac", DateTimeOffset.UtcNow, IsSelf: true, ID: "mac-id");
        var other = new CircleMemberRow(
            "iPhone", DateTimeOffset.UtcNow, IsSelf: false, ID: "phone-id");

        Assert.Equal("This device", self.JoinedDescription);
        Assert.NotEqual("This device", other.JoinedDescription);
    }
}
