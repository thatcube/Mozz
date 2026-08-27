using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Mozz.Desktop.Core;

public sealed record RelayServerRecordDto
{
    public required string Id { get; init; }
    public required string Kind { get; init; }
    public string? Name { get; init; }
    [JsonPropertyName("baseURL")] public string? BaseUrl { get; init; }
    public string? Token { get; init; }
    public string? AccountToken { get; init; }
    [JsonPropertyName("userID")] public string? UserId { get; init; }
    public string? Username { get; init; }
    public string? ServerMachineIdentifier { get; init; }
    [JsonPropertyName("musicSectionIDs")] public string[]? MusicSectionIds { get; init; }
    public bool? AllMusicLibraries { get; init; }
    public long UpdatedAtMS { get; init; }
    public long? RemovedAtMS { get; init; }

    [JsonIgnore] public long MutationAtMS => Math.Max(UpdatedAtMS, RemovedAtMS ?? long.MinValue);
    [JsonIgnore] public bool IsRemoved => RemovedAtMS is not null;
}

public sealed record RelayServerSyncResult(
    RelayServerRecordDto[] Servers,
    string RelayKey,
    long ExpiresAtMS);

public sealed record SyncedServerImport(
    IReadOnlyList<ServerAccount> Changed,
    IReadOnlyList<ServerAccount> Added);

/// <summary>
/// Local, encrypted journal of server records and tombstones.
/// </summary>
public static class ServerSyncJournal
{
    private const string Key = "server.syncJournal";
    private static readonly JsonSerializerOptions JSON = new(JsonSerializerDefaults.Web);

    public static IReadOnlyList<RelayServerRecordDto> Load(ISecretStore store)
    {
        var text = store.Get(Key);
        if (string.IsNullOrWhiteSpace(text)) return [];
        try
        {
            return JsonSerializer.Deserialize<List<RelayServerRecordDto>>(text, JSON) ?? [];
        }
        catch (JsonException)
        {
            return [];
        }
    }

    public static void Upsert(
        ISecretStore store,
        ServerAccount account,
        string token,
        string? accountToken,
        DateTimeOffset? now = null)
    {
        var candidate = new RelayServerRecordDto
        {
            Id = account.ServerId,
            Kind = account.Kind.Wire(),
            Name = account.ServerName,
            BaseUrl = account.BaseUrl,
            Token = token,
            AccountToken = accountToken,
            UserId = account.UserId,
            Username = account.Username,
            ServerMachineIdentifier = account.ServerMachineIdentifier,
            MusicSectionIds = MozzServer.EffectiveMusicSectionIds(account),
            AllMusicLibraries = account.Kind == BackendKind.Plex
                ? account.AllMusicLibraries
                : null,
            UpdatedAtMS = (now ?? DateTimeOffset.UtcNow).ToUnixTimeMilliseconds(),
        };
        var records = Load(store).ToList();
        var previous = records.FirstOrDefault(record => record.Id == candidate.Id);
        if (previous is not null && SameContent(previous, candidate)) return;
        records.RemoveAll(record => record.Id == candidate.Id);
        records.Add(candidate);
        Save(store, records);
    }

    public static void Tombstone(
        ISecretStore store,
        string serverID,
        BackendKind kind,
        DateTimeOffset? now = null)
    {
        var removedAt = (now ?? DateTimeOffset.UtcNow).ToUnixTimeMilliseconds();
        var records = Load(store).Where(record => record.Id != serverID).ToList();
        records.Add(new RelayServerRecordDto
        {
            Id = serverID,
            Kind = kind.Wire(),
            UpdatedAtMS = removedAt,
            RemovedAtMS = removedAt,
        });
        Save(store, records);
    }

    public static IReadOnlyList<RelayServerRecordDto> Merge(
        IEnumerable<RelayServerRecordDto> local,
        IEnumerable<RelayServerRecordDto> remote)
    {
        var selected = new Dictionary<string, RelayServerRecordDto>();
        foreach (var candidate in local.Concat(remote))
        {
            if (!selected.TryGetValue(candidate.Id, out var current)
                || CandidateWins(candidate, current))
            {
                selected[candidate.Id] = candidate;
            }
        }
        return selected.Values.OrderBy(record => record.Id).ToArray();
    }

    public static void Save(
        ISecretStore store,
        IReadOnlyList<RelayServerRecordDto> records) =>
        store.Set(Key, JsonSerializer.Serialize(records, JSON));

    private static bool CandidateWins(
        RelayServerRecordDto candidate,
        RelayServerRecordDto current)
    {
        if (candidate.MutationAtMS != current.MutationAtMS)
            return candidate.MutationAtMS > current.MutationAtMS;
        if (candidate.IsRemoved != current.IsRemoved)
            return candidate.IsRemoved;
        // Same mutation: stable content order, so every platform converges even
        // if two devices edited within the same millisecond.
        return string.CompareOrdinal(
            JsonSerializer.Serialize(candidate, JSON),
            JsonSerializer.Serialize(current, JSON)) > 0;
    }

    private static bool SameContent(
        RelayServerRecordDto first,
        RelayServerRecordDto second) =>
        first.Id == second.Id
        && first.Kind == second.Kind
        && first.Name == second.Name
        && first.BaseUrl == second.BaseUrl
        && first.Token == second.Token
        && first.AccountToken == second.AccountToken
        && first.UserId == second.UserId
        && first.Username == second.Username
        && first.ServerMachineIdentifier == second.ServerMachineIdentifier
        && (first.MusicSectionIds ?? []).SequenceEqual(
            second.MusicSectionIds ?? [])
        && first.AllMusicLibraries == second.AllMusicLibraries
        && first.RemovedAtMS == second.RemovedAtMS;
}
