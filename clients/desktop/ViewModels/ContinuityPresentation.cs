using Mozz.Desktop.Core;

namespace Mozz.Desktop.ViewModels;

public enum ContinuityCheckpointReason
{
    TrackChanged,
    Seeked,
    TransportChanged,
    QueueChanged,
    Periodic,
}

public sealed record ContinuityResumeOffer(
    ContinuitySnapshot Snapshot,
    string Headline,
    string Subtitle,
    string? ServerId,
    string? ArtworkKey);

public static class ContinuityPresentation
{
    public static readonly TimeSpan MaxOfferAge = TimeSpan.FromDays(14);

    public static ContinuityResumeOffer? OfferFor(
        ContinuitySnapshot? snapshot,
        string localDeviceId,
        bool isPlayingLocally,
        DateTimeOffset now)
    {
        if (snapshot is null) return null;
        var cursor = snapshot.Cursor;
        if (!string.IsNullOrWhiteSpace(cursor.DeviceID) && cursor.DeviceID == localDeviceId) return null;
        if (isPlayingLocally) return null;

        var capturedAt = cursor.CapturedAtMS > 0
            ? DateTimeOffset.FromUnixTimeMilliseconds(cursor.CapturedAtMS)
            : now;
        if (cursor.CapturedAtMS > 0 && now - capturedAt > MaxOfferAge) return null;

        var item = snapshot.Queue?.Items.FirstOrDefault(i => i.Locator.RemoteID == cursor.Current.RemoteID);
        var track = snapshot.HydratedTracks.FirstOrDefault(t => t.RemoteId == cursor.Current.RemoteID);
        var title = FirstNonEmpty(item?.Title, track?.Title);
        var artist = FirstNonEmpty(item?.Artist, track?.ArtistName);
        var subtitle = string.IsNullOrWhiteSpace(title)
            ? "Track and position"
            : string.IsNullOrWhiteSpace(artist) ? title : $"{title} · {artist}";
        if (snapshot.Queue is null || snapshot.IsQueueMissing) subtitle += " — track only";

        var device = string.IsNullOrWhiteSpace(cursor.DeviceName) ? "another device" : cursor.DeviceName.Trim();
        return new ContinuityResumeOffer(
            snapshot,
            $"Resume from {device}, {FormatAge(capturedAt, now)} ago",
            subtitle,
            track?.ServerId,
            track?.ArtworkKey ?? item?.ArtworkKey);
    }

    public static string FormatAge(DateTimeOffset capturedAt, DateTimeOffset now)
    {
        var age = now - capturedAt;
        if (age < TimeSpan.Zero) age = TimeSpan.Zero;
        if (age.TotalSeconds < 60) return "just now";
        if (age.TotalMinutes < 60) return Unit((int)Math.Round(age.TotalMinutes), "minute");
        if (age.TotalHours < 24) return Unit((int)Math.Round(age.TotalHours), "hour");
        return Unit((int)Math.Round(age.TotalDays), "day");
    }

    public static ContinuityQueueInput QueueInput(ServerAccount account, PlaybackQueue queue)
    {
        var items = queue.Tracks.Select((track, index) => new ContinuityItemInput(
            track.RemoteId,
            account.Kind.Wire(),
            account.ServerMachineIdentifier ?? "",
            account.UserId ?? account.Username ?? "",
            queue.BaseOrdinalAt(index),
            track.Title,
            track.ArtistName,
            Milliseconds(track.DurationSeconds),
            track.ArtworkKey)).ToList();

        return new ContinuityQueueInput(
            new ContinuityDescriptor("adHoc"),
            items,
            RepeatMode(queue.Repeat),
            queue.Shuffle == ShuffleMode.On,
            items.Count,
            0,
            null,
            false);
    }

    public static IReadOnlyList<(Track Track, int BaseOrdinal)> TracksForResume(
        ContinuitySnapshot snapshot,
        string fallbackServerId)
    {
        if (snapshot.Queue is null)
        {
            var track = TrackFor(snapshot.Cursor.Current.RemoteID, snapshot.HydratedTracks, null, fallbackServerId, 0);
            return track is null ? [] : [(track, 0)];
        }

        return snapshot.Queue.Items
            .Select(item => (Track: TrackFor(item.Locator.RemoteID, snapshot.HydratedTracks, item, fallbackServerId, item.BaseOrdinal),
                             item.BaseOrdinal))
            .Where(pair => pair.Track is not null)
            .Select(pair => (pair.Track!, pair.BaseOrdinal))
            .ToList();
    }

    public static int ResumeIndex(ContinuitySnapshot snapshot, int trackCount)
    {
        if (trackCount <= 0) return 0;
        if (snapshot.Queue is null) return 0;
        return Math.Clamp(snapshot.Cursor.CurrentAbsoluteIndex - snapshot.Queue.StartAbsoluteIndex, 0, trackCount - 1);
    }

    public static string State(bool isPlaying) => isPlaying ? "playing" : "paused";

    public static string RepeatMode(RepeatMode mode) => mode switch
    {
        ViewModels.RepeatMode.One => "one",
        ViewModels.RepeatMode.All => "all",
        _ => "off",
    };

    public static long Milliseconds(double seconds) =>
        double.IsFinite(seconds) ? (long)Math.Round(Math.Max(0, seconds) * 1000.0, MidpointRounding.AwayFromZero) : 0;

    private static Track? TrackFor(
        string remoteId,
        IReadOnlyList<Track> hydrated,
        ContinuityItem? item,
        string fallbackServerId,
        int ordinal)
    {
        var track = hydrated.FirstOrDefault(t => t.RemoteId == remoteId);
        if (track is not null) return track;
        if (item is null) return null;
        return new Track(
            0,
            remoteId,
            fallbackServerId,
            item.Title,
            item.Artist,
            null,
            null,
            ordinal + 1,
            null,
            item.DurationMS / 1000.0,
            item.ArtworkKey,
            false);
    }

    private static string Unit(int count, string unit)
    {
        count = Math.Max(1, count);
        return count == 1 ? $"1 {unit}" : $"{count} {unit}s";
    }

    private static string FirstNonEmpty(params string?[] values) =>
        values.FirstOrDefault(v => !string.IsNullOrWhiteSpace(v)) ?? "";
}
