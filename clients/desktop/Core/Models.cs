using System.Text.Json.Serialization;

namespace Mozz.Desktop.Core;

// The wire contract with the Swift core. Deliberately mirrors the Wire* types
// in Sources/MozzFFI/MozzSession.swift — a change on either side must be made on
// both, which is why the shapes are kept small and obvious.

public sealed record Server(
    string Id,
    string Kind,
    string Name,
    string BaseUrl);

public sealed record Artist(
    long Id,
    string RemoteId,
    string ServerId,
    string Name,
    string? ArtworkKey,
    string? HeroArtworkKey = null,
    string? SortName = null,
    int? AlbumCount = null,
    IReadOnlyList<string>? Genres = null,
    bool IsFavorite = false);

public sealed record Album(
    long Id,
    string RemoteId,
    string ServerId,
    string Title,
    string ArtistName,
    string? ArtistRemoteId,
    int? Year,
    int? TrackCount,
    string? ArtworkKey,
    string GroupKey = "",
    string? SortTitle = null,
    IReadOnlyList<string>? Genres = null,
    bool IsFavorite = false,
    double? AddedAt = null,
    string? ReleaseKind = null,
    [property: JsonPropertyName("isSingleOrEP")]
    bool? IsSingleOrEp = null);

public sealed record Track(
    long Id,
    string RemoteId,
    string ServerId,
    string Title,
    string ArtistName,
    string? AlbumTitle,
    string? AlbumRemoteId,
    int? TrackNumber,
    int? DiscNumber,
    double DurationSeconds,
    string? ArtworkKey,
    bool IsFavorite,
    double? NormalizationGainDB = null,
    int? Rating = null,
    bool FavoritePending = false,
    bool RatingPending = false)
{
    /// <summary>m:ss, the form every music player uses.</summary>
    public string Duration
    {
        get
        {
            if (DurationSeconds <= 0 || double.IsNaN(DurationSeconds)) return "--:--";
            var span = TimeSpan.FromSeconds(DurationSeconds);
            return span.TotalHours >= 1
                ? $"{(int)span.TotalHours}:{span.Minutes:00}:{span.Seconds:00}"
                : $"{span.Minutes}:{span.Seconds:00}";
        }
    }

    public string FavoriteLabel => IsFavorite
        ? (FavoritePending ? "Liked, waiting to sync" : "Liked")
        : (FavoritePending ? "Unliked, waiting to sync" : "Like");

    public string RatingText => Rating is > 0 ? $"{Rating}/5" : "Not rated";
}

public sealed record FavoriteMutationResult(
    string ServerId,
    string RemoteId,
    string ItemType,
    string Kind,
    int? Value,
    bool Liked,
    bool Queued,
    bool Synced);

public sealed record RatingMutationResult(
    string ServerId,
    string RemoteId,
    string ItemType,
    string Kind,
    int? Value,
    bool? Liked,
    bool Queued,
    bool Synced);

public sealed record PlaybackReportResult(bool Reported);

public sealed record LyricsPayload(
    string Status,
    bool StaySilent,
    int? ActiveLineIndex,
    LyricsDocument? Lyrics);

public sealed record LyricsDocument(
    string? Source,
    string? SourceDisplayName,
    bool IsSynced,
    IReadOnlyList<LyricLine> Lines);

public sealed record LyricLine(string Text, double? StartSeconds);

public sealed record SyncPhaseDetail(
    string Phase,
    string Label,
    string State,
    int Synced,
    int? Total,
    bool IsComplete);

public static class FavoriteStateProjector
{
    public static Track Optimistic(Track track, bool liked) =>
        track with { IsFavorite = liked, FavoritePending = true };

    public static Track Reconciled(Track track, FavoriteMutationResult result) =>
        track with { IsFavorite = result.Liked, FavoritePending = !result.Synced };
}

public sealed record Playlist(
    long Id,
    string RemoteId,
    string ServerId,
    string Title,
    int? TrackCount,
    string? ArtworkKey = null,
    string? Description = null);

public sealed record LibraryCounts(
    int Artists,
    int Albums,
    int Tracks);

public sealed record SuppressedRef(
    [property: JsonPropertyName("scope")] string Scope,
    [property: JsonPropertyName("ref")] string Ref,
    [property: JsonPropertyName("createdAt")] double CreatedAt);

public sealed record SearchResults(
    IReadOnlyList<Artist> Artists,
    IReadOnlyList<Album> Albums,
    IReadOnlyList<Track> Tracks,
    IReadOnlyList<Playlist>? Playlists = null);

public sealed record AlbumReleaseKind(
    string Kind,
    [property: JsonPropertyName("isSingleOrEP")] bool IsSingleOrEp);

public sealed record RadioBatch(
    IReadOnlyList<string> RemoteIds,
    IReadOnlyList<Track> Tracks);

public sealed record MixPayload(
    string Id,
    string Title,
    string Kind,
    double? GeneratedAt);

public sealed record AlbumPagePayload(
    IReadOnlyList<Album> Items,
    string? NextCursor);

// MARK: - Requests

/// <summary>
/// One command to the core. Only the fields a command needs are serialized;
/// the rest are omitted rather than sent as null.
/// </summary>
public sealed record CoreRequest(
    [property: JsonPropertyName("cmd")] string Cmd)
{
    [JsonPropertyName("serverId")] public string? ServerId { get; init; }
    [JsonPropertyName("offset")] public int? Offset { get; init; }
    [JsonPropertyName("limit")] public int? Limit { get; init; }
    [JsonPropertyName("query")] public string? Query { get; init; }
    [JsonPropertyName("remoteId")] public string? RemoteId { get; init; }
    [JsonPropertyName("groupKey")] public string? GroupKey { get; init; }
    [JsonPropertyName("genre")] public string? Genre { get; init; }
    [JsonPropertyName("artistRemoteId")] public string? ArtistRemoteId { get; init; }
    [JsonPropertyName("trackCount")] public int? TrackCount { get; init; }
    [JsonPropertyName("seedTitle")] public string? SeedTitle { get; init; }
    [JsonPropertyName("seedGenres")] public IReadOnlyList<string>? SeedGenres { get; init; }
    [JsonPropertyName("seedArtistIds")] public IReadOnlyList<string>? SeedArtistIds { get; init; }
    [JsonPropertyName("seedTrackRef")] public string? SeedTrackRef { get; init; }
    [JsonPropertyName("excluding")] public IReadOnlyList<string>? Excluding { get; init; }
    [JsonPropertyName("setId")] public string? SetId { get; init; }
    [JsonPropertyName("seed")] public int? Seed { get; init; }
    /// <summary>Opaque resume position from a previous page's <c>nextCursor</c>.</summary>
    [JsonPropertyName("cursor")] public string? Cursor { get; init; }
    [JsonPropertyName("kind")] public string? Kind { get; init; }
    [JsonPropertyName("deviceID")] public string? DeviceID { get; init; }
    [JsonPropertyName("deviceName")] public string? DeviceName { get; init; }
    [JsonPropertyName("positionMS")] public long? PositionMS { get; init; }
    [JsonPropertyName("durationMS")] public long? DurationMS { get; init; }
    [JsonPropertyName("createdAtMS")] public long? CreatedAtMS { get; init; }
    [JsonPropertyName("sinceMS")] public long? SinceMS { get; init; }
    [JsonPropertyName("maxBytes")] public int? MaxBytes { get; init; }
    [JsonPropertyName("year")] public int? Year { get; init; }
    [JsonPropertyName("liked")] public bool? Liked { get; init; }
    [JsonPropertyName("flush")] public bool? Flush { get; init; }
    [JsonPropertyName("rating")] public int? Rating { get; init; }
    [JsonPropertyName("state")] public string? State { get; init; }
    [JsonPropertyName("positionSeconds")] public double? PositionSeconds { get; init; }
    [JsonPropertyName("useLRCLIB")] public bool? UseLRCLIB { get; init; }
}

/// <summary>
/// One page of a listing and where to resume it. <c>NextCursor</c> is null on
/// the last page, which is the only end signal — the core does not report a
/// total for these listings, and counting rows would be wrong the moment a
/// background sync added one.
/// </summary>
public sealed record Page<T>(T? Rows, string? NextCursor);
