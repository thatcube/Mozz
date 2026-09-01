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
    /// <summary>
    /// The star rating, where the backend keeps one. Carried alongside
    /// <see cref="IsFavorite"/> because on a ratings backend (Plex) that flag is
    /// always false and this is what "liked" actually means — see IsLiked.
    /// </summary>
    double? Rating = null,
    /// <summary>Codec and bitrate as the server reported them.</summary>
    string? Codec = null,
    int? BitrateKbps = null,
    double? NormalizationGainDB = null)
{
    /// <summary>
    /// Whether this counts as liked, by the same rule every Mozz client uses:
    /// a boolean favourite, or four stars and up. Matches LikePolicy in the core.
    /// </summary>
    public bool IsLiked => IsFavorite || (Rating ?? 0) >= 4.0;

    /// <summary>A short format badge — "FLAC", "AAC" — or null when unreported.</summary>
    public string? Format =>
        string.IsNullOrWhiteSpace(Codec) ? null : Codec!.ToUpperInvariant();

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
    [property: JsonPropertyName("createdAt")] double CreatedAt,
    /// <summary>The track title or artist name, resolved by the core.</summary>
    [property: JsonPropertyName("title")] string? Title = null,
    /// <summary>The artist name, for a track. Null for an artist.</summary>
    [property: JsonPropertyName("subtitle")] string? Subtitle = null,
    [property: JsonPropertyName("artworkKey")] string? ArtworkKey = null);

public sealed record SearchResults(
    IReadOnlyList<Artist> Artists,
    IReadOnlyList<Album> Albums,
    IReadOnlyList<Track> Tracks);

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
}

/// <summary>
/// One page of a listing and where to resume it. <c>NextCursor</c> is null on
/// the last page, which is the only end signal — the core does not report a
/// total for these listings, and counting rows would be wrong the moment a
/// background sync added one.
/// </summary>
public sealed record Page<T>(T? Rows, string? NextCursor);
