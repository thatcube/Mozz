using Mozz.Desktop.Core;
using Mozz.Desktop.ViewModels;
using Xunit;

namespace Mozz.Desktop.Tests;

public class ContinuityPresentationTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeMilliseconds(2_000_000_000_000);

    [Fact]
    public void OffersAttributedRemoteResumeWithAge()
    {
        var snapshot = Snapshot(deviceId: "phone-1", deviceName: "your iPhone", capturedAt: Now.AddMinutes(-5));

        var offer = ContinuityPresentation.OfferFor(snapshot, "desktop-1", isPlayingLocally: false, Now);

        Assert.NotNull(offer);
        Assert.Equal("Resume from your iPhone, 5 minutes ago", offer.Headline);
        Assert.Equal("Song · Artist", offer.Subtitle);
    }

    [Fact]
    public void SuppressesSameDevicePosition()
    {
        var snapshot = Snapshot(deviceId: "desktop-1", deviceName: "Mac", capturedAt: Now.AddMinutes(-1));

        var offer = ContinuityPresentation.OfferFor(snapshot, "desktop-1", isPlayingLocally: false, Now);

        Assert.Null(offer);
    }

    [Fact]
    public void SuppressesStalePosition()
    {
        var snapshot = Snapshot(deviceId: "phone-1", deviceName: "Phone", capturedAt: Now.AddDays(-15));

        var offer = ContinuityPresentation.OfferFor(snapshot, "desktop-1", isPlayingLocally: false, Now);

        Assert.Null(offer);
    }

    [Fact]
    public void SuppressesOfferWhilePlayingLocally()
    {
        var snapshot = Snapshot(deviceId: "phone-1", deviceName: "Phone", capturedAt: Now.AddMinutes(-1));

        var offer = ContinuityPresentation.OfferFor(snapshot, "desktop-1", isPlayingLocally: true, Now);

        Assert.Null(offer);
    }

    [Theory]
    [InlineData(30, "just now")]
    [InlineData(60, "1 minute")]
    [InlineData(300, "5 minutes")]
    [InlineData(3600, "1 hour")]
    [InlineData(7200, "2 hours")]
    [InlineData(172800, "2 days")]
    public void FormatsOfferAge(int seconds, string expected)
    {
        Assert.Equal(expected, ContinuityPresentation.FormatAge(Now.AddSeconds(-seconds), Now));
    }

    [Fact]
    public void QueueInputPreservesBaseOrdinalsAfterShuffle()
    {
        var queue = new PlaybackQueue();
        var tracks = new[] { Track("one"), Track("two"), Track("three") };
        queue.Start([(tracks[0], 0), (tracks[2], 2), (tracks[1], 1)], 0);

        var input = ContinuityPresentation.QueueInput(Account(), queue);

        Assert.Equal([0, 2, 1], input.Items.Select(i => i.BaseOrdinal).ToArray());
    }

    private static ContinuitySnapshot Snapshot(string deviceId, string deviceName, DateTimeOffset capturedAt)
    {
        var fingerprint = new ContinuityFingerprint("jellyfin", "server-identity", "user-1");
        var locator = new ContinuityTrackLocator(fingerprint, "remote-1");
        var cursor = new ContinuityCursor(
            "00000000-0000-0000-0000-000000000001",
            deviceId,
            deviceName,
            "phone",
            4,
            capturedAt.ToUnixTimeMilliseconds(),
            "paused",
            locator,
            0,
            45_000,
            "hash");
        var item = new ContinuityItem(locator, 0, "Song", "Artist", 180_000, "art");
        var queue = new ContinuityQueue("hash", new ContinuityDescriptor("adHoc"), [item], 0, 1, false, "off", false);
        return new ContinuitySnapshot(cursor, queue, false, [Track("remote-1")]);
    }

    private static Track Track(string remoteId) =>
        new(1, remoteId, "server", "Song", "Artist", "Album", "album", 1, 1, 180, "art", false);

    private static ServerAccount Account() => new()
    {
        ServerId = "server",
        Kind = BackendKind.Jellyfin,
        BaseUrl = "http://localhost",
        ServerName = "Server",
        UserId = "user-1",
        ClientIdentifier = "client",
        ServerMachineIdentifier = "server-identity",
    };
}
