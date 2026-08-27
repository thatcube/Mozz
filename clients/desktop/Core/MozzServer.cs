using System.Text.Json;
using System.Text.Json.Serialization;

namespace Mozz.Desktop.Core;

/// <summary>
/// Signing in, mirroring a catalog, and turning a track into a playable URL.
///
/// A thin, typed layer over <see cref="MozzCore"/>'s command dispatcher. It
/// exists so the rest of the app never composes a request dictionary by hand and
/// never sees a magic command string — those belong next to the types they
/// produce, not scattered through view models.
///
/// It also owns the one thing the Swift core deliberately does not: persistence
/// of the auth token, via <see cref="ISecretStore"/>. The core hands a token out
/// of <c>Connect</c> and forgets it; this puts it in the platform's keystore and
/// hands it back on the next launch through <c>Attach</c>.
/// </summary>
public sealed class MozzServer(MozzCore core, ISecretStore secrets, string? accountsPath = null)
    : Downloads.IDownloadSourceResolver
{
    private const string AccountsKey = "accounts.json";
    private readonly string _accountsPath = accountsPath ?? Path.Combine(AppPaths.SupportDirectory, AccountsKey);

    // MARK: Sign-in

    /// <summary>
    /// Jellyfin and Subsonic sign in with a username and password. Plex does not
    /// — see <see cref="BeginPlexLinkAsync"/>.
    /// </summary>
    public async Task<ServerAccount> ConnectAsync(
        BackendKind kind, string baseUrl, string username, string? password,
        string? apiKey = null, CancellationToken token = default)
    {
        var identifier = ClientIdentifier;
        var session = await core.CallAsync<SessionPayload>(new
        {
            cmd = "connect",
            kind = kind.Wire(),
            baseURL = baseUrl,
            username,
            password,
            apiKey,
            clientIdentifier = identifier,
        }, token).ConfigureAwait(false)
            ?? throw new MozzCoreException("The server returned no session");

        return Persist(session, username, identifier);
    }

    /// <summary>
    /// Start Plex's PIN flow. The user opens <see cref="PlexLink.LinkUrl"/> (or
    /// scans it), then <see cref="PollPlexLinkAsync"/> is called until it
    /// returns an account.
    /// </summary>
    public async Task<PlexLink> BeginPlexLinkAsync(CancellationToken token = default)
    {
        var pin = await core.CallAsync<PlexPinPayload>(new
        {
            cmd = "plexPin",
            clientIdentifier = ClientIdentifier,
        }, token).ConfigureAwait(false)
            ?? throw new MozzCoreException("Plex returned no PIN");

        return new PlexLink(pin.PinId, pin.Code, pin.ClientIdentifier, pin.LinkUrl);
    }

    /// <summary>
    /// Poll once. Returns null while the user has not finished linking, which is
    /// the normal case for the first several seconds.
    /// </summary>
    public async Task<string?> PollPlexTokenAsync(
        PlexLink link,
        CancellationToken token = default)
    {
        var payload = await core.CallAsync<PlexAccountTokenPayload>(new
        {
            cmd = "plexPinToken",
            pinId = link.PinId,
            code = link.Code,
            clientIdentifier = link.ClientIdentifier,
        }, token).ConfigureAwait(false);
        return payload?.AccountToken;
    }

    public async Task<IReadOnlyList<PlexHomeUser>> PlexHomeUsersAsync(
        string accountToken,
        string clientIdentifier,
        CancellationToken token = default)
    {
        return await core.CallAsync<IReadOnlyList<PlexHomeUser>>(new
        {
            cmd = "plexHomeUsers",
            accountToken,
            clientIdentifier,
        }, token).ConfigureAwait(false) ?? [];
    }

    /// <summary>
    /// Finish Plex login for the selected Home profile. If it is managed, the
    /// owner token is used once to switch and only the switched token survives.
    /// </summary>
    public async Task<ServerAccount> CompletePlexLoginAsync(
        string accountToken,
        string clientIdentifier,
        PlexHomeUser? user,
        string? profilePIN,
        CancellationToken token = default)
    {
        var selectedToken = accountToken;
        if (user is { IsAdmin: false })
        {
            var switched = await core.CallAsync<PlexSwitchedTokenPayload>(new
            {
                cmd = "plexHomeSwitch",
                accountToken,
                homeUserID = user.Id,
                profilePIN,
                clientIdentifier,
            }, token).ConfigureAwait(false)
                ?? throw new MozzCoreException("Plex returned no profile token");
            selectedToken = switched.AccountToken;
        }

        var session = await core.CallAsync<SessionPayload>(new
        {
            cmd = "plexCompleteLogin",
            accountToken = selectedToken,
            homeUserID = user?.Id,
            clientIdentifier,
        }, token).ConfigureAwait(false)
            ?? throw new MozzCoreException("Plex returned no session");
        return Persist(session, user?.Name, clientIdentifier);
    }

    // MARK: Attach

    /// <summary>
    /// Give the core the credentials for a saved account so sync and playback
    /// work. Called at launch for every saved account.
    /// </summary>
    public async Task AttachAsync(ServerAccount account, CancellationToken token = default)
    {
        var originalAccount = account;
        account = NormalizeSavedAccount(account);
        var secret = await Task.Run(() => SecretFor(account, originalAccount), token).ConfigureAwait(false)
            ?? throw new MozzCoreException(
                $"No stored credential for {account.ServerName}. Sign in again.");

        await core.CallAsync<AttachPayload>(new
        {
            cmd = "attach",
            kind = account.Kind.Wire(),
            baseURL = account.BaseUrl,
            token = secret,
            userID = account.UserId,
            username = account.Username,
            serverName = account.ServerName,
            clientIdentifier = account.ClientIdentifier,
            serverMachineIdentifier = account.ServerMachineIdentifier,
            musicSectionID = account.MusicSectionId,
        }, token).ConfigureAwait(false);
        ServerSyncJournal.Upsert(
            secrets,
            account,
            secret,
            secrets.Get($"plex.account.{account.ServerId}"));
    }

    /// <summary>
    /// Attach an account and leave it ready to sync.
    ///
    /// Plex addresses its catalog by library section, and a newly signed-in
    /// account has none — the PIN flow yields an account and a server, never a
    /// section. Syncing in that state fails with "Plex music section not
    /// resolved". So resolve it once, save it, and re-attach, because the core
    /// builds its backend at attach time and the one built above still has no
    /// section. Returns the account to sync with, which may differ from the one
    /// passed in.
    /// </summary>
    public async Task<ServerAccount> AttachForSyncAsync(
        ServerAccount account, CancellationToken token = default)
    {
        await AttachAsync(account, token).ConfigureAwait(false);

        if (account.Kind != BackendKind.Plex || account.MusicSectionId is { Length: > 0 })
        {
            return account;
        }

        // Needs the attach above: `libraries` resolves against an attached
        // backend. For Plex it is musicSections(), which reads library/sections
        // directly and so does not itself need a section.
        var libraries = await LibrariesAsync(account.ServerId, token).ConfigureAwait(false);
        if (libraries is not { Count: > 0 })
        {
            throw new MozzCoreException(
                $"{account.ServerName} has no music library for Mozz to sync.");
        }

        var resolved = account with { MusicSectionId = libraries[0].Id };
        SaveAccount(resolved);
        await AttachAsync(resolved, token).ConfigureAwait(false);
        return resolved;
    }

    public Task<IReadOnlyList<MusicLibrary>?> LibrariesAsync(
        string serverId, CancellationToken token = default)
        => core.CallAsync<IReadOnlyList<MusicLibrary>>(new { cmd = "libraries", serverId }, token);

    public async Task<ServerAccount> SelectMusicLibraryAsync(
        ServerAccount account,
        string libraryId,
        CancellationToken token = default)
    {
        if (string.IsNullOrWhiteSpace(libraryId)) return account;
        var updated = account with { MusicSectionId = libraryId };
        SaveAccount(updated);
        await AttachAsync(updated, token).ConfigureAwait(false);
        return updated;
    }

    // MARK: Sync

    public Task<SyncStart?> StartSyncAsync(string serverId, CancellationToken token = default)
        => core.CallAsync<SyncStart>(new { cmd = "sync", serverId }, token);

    public Task<SyncStatus?> SyncStatusAsync(string serverId, CancellationToken token = default)
        => core.CallAsync<SyncStatus>(new { cmd = "syncStatus", serverId }, token);

    /// <summary>
    /// Run a sync to completion, reporting progress. Polls rather than taking a
    /// callback because the C ABI is synchronous — see the note in
    /// <c>MozzSessionServer.swift</c>. Throws if the sync fails.
    /// </summary>
    public async Task<SyncStatus> SyncAsync(
        string serverId, IProgress<SyncStatus>? progress = null,
        CancellationToken token = default)
    {
        var start = await StartSyncAsync(serverId, token).ConfigureAwait(false);
        if (start is { Started: false, Reason: { } reason })
        {
            throw new MozzCoreException($"Sync did not start: {reason}");
        }

        while (true)
        {
            token.ThrowIfCancellationRequested();
            await Task.Delay(TimeSpan.FromMilliseconds(400), token).ConfigureAwait(false);

            var status = await SyncStatusAsync(serverId, token).ConfigureAwait(false);
            if (status is null) continue;
            progress?.Report(status);

            if (!status.Finished) continue;
            if (status.Error is { Length: > 0 } error) throw new MozzCoreException(error);
            return status;
        }
    }

    // MARK: Playback

    public Task<StreamSource?> StreamAsync(
        string serverId, string remoteId, int? maxBitrateKbps = null,
        CancellationToken token = default)
        => core.CallAsync<StreamSource>(new
        {
            cmd = "streamURL",
            serverId,
            remoteId,
            maxBitrateKbps,
        }, token);

    /// <summary>
    /// Resolve a track to the URL and auth headers its bytes are fetched from,
    /// for the download service. This is the same <c>streamURL</c> command the
    /// player resolves through — so a download carries exactly the credentials a
    /// stream does — but it keeps the <c>headers</c> the playback
    /// <see cref="StreamSource"/> record throws away. Null when the core has no
    /// URL for the track.
    /// </summary>
    public async Task<Downloads.DownloadSource?> ResolveAsync(
        string serverId, string remoteId, CancellationToken token = default)
    {
        var payload = await core.CallAsync<DownloadStreamPayload>(new
        {
            cmd = "streamURL",
            serverId,
            remoteId,
        }, token).ConfigureAwait(false);

        if (payload is null || string.IsNullOrWhiteSpace(payload.Url)) return null;

        IReadOnlyDictionary<string, string> headers =
            payload.Headers ?? new Dictionary<string, string>();
        return new Downloads.DownloadSource(payload.Url, headers);
    }

    public async Task<string?> ArtworkUrlAsync(
        string serverId, string artworkKey, int size = 512, CancellationToken token = default)
    {
        var result = await core.CallAsync<UrlPayload>(new
        {
            cmd = "artworkURL", serverId, artworkKey, size,
        }, token).ConfigureAwait(false);
        return result?.Url;
    }

    public Task<ServerAccountProfile?> AccountAsync(
        string serverId, int size = 120, CancellationToken token = default)
        => core.CallAsync<ServerAccountProfile>(new
        {
            cmd = "account",
            serverId,
            size,
        }, token);

    // MARK: Saved accounts

    /// <summary>
    /// The accounts this installation knows about. Non-secret: the token itself
    /// is in the platform keystore, and this file holds only what is needed to
    /// look it up and to label the account in the UI.
    /// </summary>
    public IReadOnlyList<ServerAccount> SavedAccounts()
    {
        var path = _accountsPath;
        if (!File.Exists(path)) return [];
        try
        {
            var decoded = JsonSerializer.Deserialize<List<ServerAccount>>(File.ReadAllText(path)) ?? [];
            return NormalizeSavedAccounts(decoded, writeIfChanged: true);
        }
        catch (JsonException)
        {
            // A corrupt accounts file must not brick the app. The tokens are
            // still in the keystore; the worst case is signing in again.
            return [];
        }
    }

    public void ForgetAccount(string serverId)
    {
        var accounts = SavedAccounts();
        var canonical = CanonicalServerId(accounts.FirstOrDefault(a => a.ServerId == serverId)) ?? serverId;
        var removed = accounts.Where(a => a.ServerId == serverId || CanonicalServerId(a) == canonical).ToList();
        foreach (var account in removed)
        {
            ServerSyncJournal.Tombstone(
                secrets, account.ServerId, account.Kind);
        }
        var remaining = accounts.Except(removed).ToList();
        WriteAccounts(remaining);
        foreach (var account in removed)
        {
            DeleteCredentialKeys(account);
        }
        secrets.Set(SecretKey(canonical), null);
        secrets.Set($"plex.account.{canonical}", null);
    }

    public void ForgetAllAccounts()
    {
        foreach (var account in SavedAccounts())
        {
            ServerSyncJournal.Tombstone(
                secrets, account.ServerId, account.Kind);
            DeleteCredentialKeys(account);
        }
        WriteAccounts([]);
    }

    private ServerAccount Persist(SessionPayload session, string? username, string identifier)
    {
        var account = new ServerAccount
        {
            ServerId = session.ServerId,
            Kind = BackendKindExtensions.Parse(session.Kind),
            BaseUrl = session.BaseUrl,
            ServerName = session.ServerName,
            UserId = session.UserId,
            Username = username,
            ClientIdentifier = string.IsNullOrEmpty(session.ClientIdentifier)
                ? identifier
                : session.ClientIdentifier,
            ServerMachineIdentifier = session.ServerMachineIdentifier,
            MusicSectionId = null,
        };
        account = NormalizeSavedAccount(account);

        secrets.Set(SecretKey(account.ServerId), session.Token);
        if (session.AccountToken is { Length: > 0 } accountToken)
        {
            // Plex's account token is distinct from the per-server access token
            // and is what re-discovers the account's other servers later.
            secrets.Set($"plex.account.{account.ServerId}", accountToken);
        }

        SaveAccount(account);
        return account;
    }

    /// <summary>Insert or replace one account, leaving the others alone.</summary>
    internal void SaveAccount(ServerAccount account)
    {
        account = NormalizeSavedAccount(account);
        var accounts = SavedAccounts()
            .Where(a => a.ServerId != account.ServerId && CanonicalServerId(a) != account.ServerId)
            .ToList();
        accounts.Add(account);
        WriteAccounts(accounts);
        if (SecretFor(account) is { } token)
        {
            ServerSyncJournal.Upsert(
                secrets,
                account,
                token,
                secrets.Get($"plex.account.{account.ServerId}"));
        }
    }

    internal void SaveAccount(ServerAccount account, string secret, string? accountToken = null)
    {
        account = NormalizeSavedAccount(account);
        secrets.Set(SecretKey(account.ServerId), secret);
        if (accountToken is not null) secrets.Set($"plex.account.{account.ServerId}", accountToken);
        SaveAccount(account);
    }

    internal IReadOnlyList<RelayServerRecordDto> ExportSyncedServers()
    {
        // Seed journals created by builds before server sync existed.
        foreach (var account in SavedAccounts())
        {
            if (SecretFor(account) is { } token)
            {
                ServerSyncJournal.Upsert(
                    secrets,
                    account,
                    token,
                    secrets.Get($"plex.account.{account.ServerId}"));
            }
        }
        return ServerSyncJournal.Load(secrets);
    }

    internal SyncedServerImport ImportSyncedServers(
        IReadOnlyList<RelayServerRecordDto> remote)
    {
        var previousAccounts = SavedAccounts();
        var previousIDs = previousAccounts
            .Select(account => account.ServerId)
            .ToHashSet(StringComparer.Ordinal);
        var previousRecords = ServerSyncJournal.Load(secrets)
            .ToDictionary(record => record.Id, StringComparer.Ordinal);
        var merged = ServerSyncJournal.Merge(
            ServerSyncJournal.Load(secrets), remote);
        ServerSyncJournal.Save(secrets, merged);

        var accounts = new List<ServerAccount>();
        foreach (var record in merged)
        {
            if (record.IsRemoved)
            {
                secrets.Set(SecretKey(record.Id), null);
                secrets.Set($"plex.account.{record.Id}", null);
                continue;
            }
            if (record.Token is not { Length: > 0 } token
                || record.BaseUrl is not { Length: > 0 } baseUrl
                || record.Name is not { Length: > 0 } name)
            {
                continue;
            }
            var account = new ServerAccount
            {
                ServerId = record.Id,
                Kind = BackendKindExtensions.Parse(record.Kind),
                BaseUrl = baseUrl,
                ServerName = name,
                UserId = record.UserId,
                Username = record.Username,
                ClientIdentifier = ClientIdentifier,
                ServerMachineIdentifier = record.ServerMachineIdentifier,
                MusicSectionId = record.MusicSectionIds?.FirstOrDefault(),
            };
            accounts.Add(account);
            secrets.Set(SecretKey(account.ServerId), token);
            if (record.AccountToken is not null)
            {
                secrets.Set(
                    $"plex.account.{account.ServerId}",
                    record.AccountToken);
            }
        }
        WriteAccounts(accounts);
        var added = accounts
            .Where(account => !previousIDs.Contains(account.ServerId))
            .ToArray();
        var changed = accounts
            .Where(account =>
            {
                var next = merged.First(record => record.Id == account.ServerId);
                return !previousRecords.TryGetValue(account.ServerId, out var old)
                    || next.MutationAtMS > old.MutationAtMS;
            })
            .ToArray();
        return new SyncedServerImport(changed, added);
    }

    private void WriteAccounts(IReadOnlyList<ServerAccount> accounts)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_accountsPath)!);
        File.WriteAllText(_accountsPath, JsonSerializer.Serialize(accounts,
            new JsonSerializerOptions { WriteIndented = true }));
    }

    private static string SecretKey(string serverId) => $"token.{serverId}";

    private string? SecretFor(ServerAccount account, ServerAccount? originalAccount = null)
    {
        var canonical = NormalizeSavedAccount(account);
        var key = SecretKey(canonical.ServerId);
        if (secrets.Get(key) is { } current) return current;

        var legacyIds = LegacyServerIds(account)
            .Concat(originalAccount is null ? Enumerable.Empty<string>() : LegacyServerIds(originalAccount));
        foreach (var legacyKey in legacyIds.Select(SecretKey))
        {
            if (legacyKey == key) continue;
            if (secrets.Get(legacyKey) is { } legacy)
            {
                secrets.Set(key, legacy);
                return legacy;
            }
        }
        return null;
    }

    private IReadOnlyList<ServerAccount> NormalizeSavedAccounts(
        IReadOnlyList<ServerAccount> accounts,
        bool writeIfChanged)
    {
        var normalized = new List<ServerAccount>();
        var changed = false;

        foreach (var account in accounts.Where(a => a.Kind != BackendKind.Plex || PlexMachineIdentifier(a) is null))
        {
            var fixedAccount = NormalizeSavedAccount(account);
            changed |= fixedAccount != account;
            normalized.Add(fixedAccount);
        }

        foreach (var group in accounts
                     .Where(a => a.Kind == BackendKind.Plex && PlexMachineIdentifier(a) is not null)
                     .GroupBy(a => PlexMachineIdentifier(a)!))
        {
            var chosen = group
                .OrderBy(a => PlexAddressRank(a.BaseUrl))
                .ThenByDescending(a => HasCredential(a))
                .First();
            var machine = group.Key;
            var canonical = chosen with
            {
                ServerId = $"plex-{machine}",
                ServerMachineIdentifier = machine,
                MusicSectionId = chosen.MusicSectionId ?? group.Select(a => a.MusicSectionId).FirstOrDefault(s => !string.IsNullOrWhiteSpace(s)),
            };
            normalized.Add(canonical);

            if (canonical != chosen || group.Count() > 1) changed = true;
            MigrateCredential(group, canonical.ServerId, SecretKey);
            MigrateCredential(group, canonical.ServerId, id => $"plex.account.{id}");
        }

        if (writeIfChanged && changed) WriteAccounts(normalized);
        return normalized;
    }

    private void MigrateCredential(
        IEnumerable<ServerAccount> accounts,
        string canonicalServerId,
        Func<string, string> keyFor)
    {
        var canonicalKey = keyFor(canonicalServerId);
        if (secrets.Get(canonicalKey) is not null) return;

        foreach (var legacyId in accounts.SelectMany(LegacyServerIds))
        {
            var legacyKey = keyFor(legacyId);
            if (legacyKey == canonicalKey) continue;
            if (secrets.Get(legacyKey) is { } value)
            {
                secrets.Set(canonicalKey, value);
                return;
            }
        }
    }

    private ServerAccount NormalizeSavedAccount(ServerAccount account)
    {
        var machine = PlexMachineIdentifier(account);
        if (account.Kind != BackendKind.Plex || string.IsNullOrWhiteSpace(machine)) return account;
        return account with
        {
            ServerId = $"plex-{machine}",
            ServerMachineIdentifier = machine,
        };
    }

    private static string? CanonicalServerId(ServerAccount? account)
        => account is null ? null : NormalizeServerId(account);

    private static string NormalizeServerId(ServerAccount account)
    {
        var machine = PlexMachineIdentifier(account);
        return account.Kind == BackendKind.Plex && !string.IsNullOrWhiteSpace(machine)
            ? $"plex-{machine}"
            : account.ServerId;
    }

    private static IEnumerable<string> LegacyServerIds(ServerAccount account)
    {
        yield return account.ServerId;
        if (PlexMachineIdentifier(account) is { Length: > 0 } machine)
        {
            yield return $"plex-{machine}";
        }
    }

    private bool HasCredential(ServerAccount account)
        => LegacyServerIds(account).Any(id => secrets.Get(SecretKey(id)) is not null);

    private void DeleteCredentialKeys(ServerAccount account)
    {
        foreach (var id in LegacyServerIds(account).Distinct())
        {
            secrets.Set(SecretKey(id), null);
            secrets.Set($"plex.account.{id}", null);
        }
    }

    private static string? PlexMachineIdentifier(ServerAccount account)
    {
        if (account.Kind != BackendKind.Plex) return null;
        if (!string.IsNullOrWhiteSpace(account.ServerMachineIdentifier)) return account.ServerMachineIdentifier;
        if (account.ServerId.StartsWith("plex-", StringComparison.Ordinal)
            && !account.ServerId.StartsWith("plex-http://", StringComparison.Ordinal)
            && !account.ServerId.StartsWith("plex-https://", StringComparison.Ordinal))
        {
            return account.ServerId["plex-".Length..];
        }

        if (!Uri.TryCreate(account.BaseUrl, UriKind.Absolute, out var uri)) return null;
        var host = uri.Host;
        const string suffix = ".plex.direct";
        if (!host.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)) return null;
        var withoutSuffix = host[..^suffix.Length];
        var dot = withoutSuffix.LastIndexOf('.');
        return dot < 0 || dot == withoutSuffix.Length - 1 ? null : withoutSuffix[(dot + 1)..];
    }

    private static int PlexAddressRank(string baseUrl)
    {
        if (!Uri.TryCreate(baseUrl, UriKind.Absolute, out var uri)) return 1;
        var host = uri.Host;
        const string suffix = ".plex.direct";
        if (host.EndsWith(suffix, StringComparison.OrdinalIgnoreCase))
        {
            var encodedIp = host[..^suffix.Length].Split('.').FirstOrDefault()?.Replace('-', '.');
            if (IsDockerBridgeAddress(encodedIp)) return 2;
        }
        return 0;
    }

    private static bool IsDockerBridgeAddress(string? address)
    {
        if (string.IsNullOrWhiteSpace(address)) return false;
        var parts = address.Split('.');
        if (parts.Length != 4) return false;
        if (!int.TryParse(parts[0], out var a) || !int.TryParse(parts[1], out var b)) return false;
        return a == 172 && b is >= 16 and <= 31;
    }

    /// <summary>
    /// A stable per-installation id. Servers show it in their device list, so it
    /// must survive restarts — a new one each launch litters someone's Plex
    /// account with dozens of "Mozz on Windows" entries.
    /// </summary>
    private string ClientIdentifier
    {
        get
        {
            const string key = "clientIdentifier";
            var existing = secrets.Get(key);
            if (existing is { Length: > 0 }) return existing;
            var created = Guid.NewGuid().ToString();
            secrets.Set(key, created);
            return created;
        }
    }
}

// MARK: - Types

public enum BackendKind { Plex, Jellyfin, Subsonic }

public static class BackendKindExtensions
{
    public static string Wire(this BackendKind kind) => kind switch
    {
        BackendKind.Plex => "plex",
        BackendKind.Jellyfin => "jellyfin",
        BackendKind.Subsonic => "subsonic",
        _ => throw new ArgumentOutOfRangeException(nameof(kind)),
    };

    public static BackendKind Parse(string wire) => wire switch
    {
        "plex" => BackendKind.Plex,
        "jellyfin" => BackendKind.Jellyfin,
        "subsonic" => BackendKind.Subsonic,
        _ => throw new ArgumentOutOfRangeException(nameof(wire), wire, "unknown backend"),
    };

    public static string Display(this BackendKind kind) => kind switch
    {
        BackendKind.Plex => "Plex",
        BackendKind.Jellyfin => "Jellyfin",
        BackendKind.Subsonic => "Subsonic",
        _ => kind.ToString(),
    };
}

/// <summary>A saved server, minus its secret.</summary>
public sealed record ServerAccount
{
    public required string ServerId { get; init; }
    public required BackendKind Kind { get; init; }
    public required string BaseUrl { get; init; }
    public required string ServerName { get; init; }
    public string? UserId { get; init; }
    public string? Username { get; init; }
    public required string ClientIdentifier { get; init; }
    public string? ServerMachineIdentifier { get; init; }
    public string? MusicSectionId { get; init; }
}

public sealed record ServerAccountProfile(
    [property: JsonPropertyName("displayName")] string? DisplayName,
    [property: JsonPropertyName("username")] string? Username,
    [property: JsonPropertyName("avatarURL")] string? AvatarUrl);

public sealed record PlexLink(int PinId, string Code, string ClientIdentifier, string? LinkUrl);

public sealed record MusicLibrary(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("name")] string Name);

public sealed record SyncStart(
    [property: JsonPropertyName("started")] bool Started,
    [property: JsonPropertyName("reason")] string? Reason);

public sealed record SyncStatus(
    [property: JsonPropertyName("running")] bool Running,
    [property: JsonPropertyName("finished")] bool Finished,
    [property: JsonPropertyName("phase")] string? Phase,
    [property: JsonPropertyName("itemsSynced")] int ItemsSynced,
    [property: JsonPropertyName("total")] int? Total,
    [property: JsonPropertyName("error")] string? Error,
    [property: JsonPropertyName("artists")] int? Artists,
    [property: JsonPropertyName("albums")] int? Albums,
    [property: JsonPropertyName("tracks")] int? Tracks,
    [property: JsonPropertyName("playlists")] int? Playlists,
    [property: JsonPropertyName("details")] IReadOnlyList<SyncPhaseDetail>? Details = null,
    [property: JsonPropertyName("phaseLabel")] string? PhaseLabel = null)
{
    /// <summary>Short label for a progress row, e.g. "Songs 3,712 / 20,004".</summary>
    public string Describe()
    {
        var phase = Phase switch
        {
            "capabilities" => "Connecting",
            "syncing" => "Syncing",
            "artists" => "Artists",
            "albums" => "Albums",
            "tracks" => "Songs",
            "playlists" => "Playlists",
            "pruning" => "Finishing up",
            "done" => "Done",
            _ => "Syncing",
        };
        return Total is > 0
            ? $"{phase} {ItemsSynced:N0} / {Total:N0}"
            : $"{phase} {ItemsSynced:N0}";
    }
}

public sealed record SyncPhaseRow(string Label, string State, int Synced, int? Total, bool IsComplete)
{
    public string CountText => State switch
    {
        "done" when Synced == 0 => "None",
        "pending" when Synced == 0 && (Total ?? 0) == 0 => string.Empty,
        _ => Total is > 0 ? $"{Synced:N0} / {Total.Value:N0}" : $"{Synced:N0}",
    };

    public bool IsDone => State == "done" || IsComplete;
    public bool IsSyncing => State == "syncing";
}

public sealed class SyncProgressSmoother
{
    private readonly Dictionary<string, SyncCounterPacer> _pacers = new(StringComparer.Ordinal);
    private DateTimeOffset? _lastUpdate;

    public IReadOnlyList<SyncPhaseRow> Update(SyncStatus status, DateTimeOffset? now = null)
    {
        var at = now ?? DateTimeOffset.UtcNow;
        var elapsed = _lastUpdate is { } last ? Math.Max(0, (at - last).TotalSeconds) : 0;
        _lastUpdate = at;

        var details = status.Details is { Count: > 0 }
            ? status.Details
            : [new SyncPhaseDetail(status.Phase ?? "syncing", status.PhaseLabel ?? "Syncing", status.Finished ? "done" : "syncing", status.ItemsSynced, status.Total, status.Finished)];

        var rows = new List<SyncPhaseRow>(details.Count);
        foreach (var detail in details)
        {
            var pacer = _pacers.TryGetValue(detail.Phase, out var existing) ? existing : new SyncCounterPacer();
            if (detail.State == "done" || detail.IsComplete) pacer.Settle(detail.Synced);
            else pacer.Report(detail.Synced, at);
            if (elapsed > 0) pacer.Advance(elapsed);
            _pacers[detail.Phase] = pacer;
            rows.Add(new SyncPhaseRow(detail.Label, detail.State, pacer.Displayed, detail.Total, detail.IsComplete));
        }
        return rows;
    }
}

public sealed class SyncCounterPacer
{
    private const double Stretch = 1.25;
    private const double MinimumSpread = 4.0;
    private const double MaximumSpread = 60.0;
    private const double MinimumRate = 0.8;
    private double _position;
    private double _target;
    private double _pageInterval = 15;
    private DateTimeOffset? _lastArrival;
    private bool _seeded;

    public int Displayed => (int)Math.Floor(_position);

    public void Report(int count, DateTimeOffset now)
    {
        var value = (double)count;
        if (!_seeded)
        {
            _position = value;
            _target = value;
            _lastArrival = now;
            _seeded = true;
            return;
        }
        if (Math.Abs(value - _target) < 0.001) return;
        if (value > _target && _lastArrival is { } last)
        {
            var elapsed = (now - last).TotalSeconds;
            if (elapsed > 0.25 && elapsed < 300) _pageInterval = _pageInterval * 0.6 + elapsed * 0.4;
            _lastArrival = now;
        }
        _target = value;
        if (_position > _target) _position = _target;
    }

    public void Settle(int count)
    {
        _position = count;
        _target = count;
        _seeded = true;
    }

    public bool Advance(double elapsed)
    {
        if (_position >= _target)
        {
            _position = Math.Min(_position, _target);
            return false;
        }
        var spread = Math.Min(Math.Max(_pageInterval * Stretch, MinimumSpread), MaximumSpread);
        var gap = _target - _position;
        var rate = Math.Max(gap / spread, MinimumRate);
        _position = Math.Min(_position + rate * elapsed, _target);
        return _position < _target;
    }
}

public sealed record StreamSource(
    [property: JsonPropertyName("url")] string Url,
    [property: JsonPropertyName("isTranscoded")] bool IsTranscoded,
    [property: JsonPropertyName("sessionID")] string? SessionId);

internal sealed record DownloadStreamPayload(
    [property: JsonPropertyName("url")] string? Url,
    [property: JsonPropertyName("headers")] Dictionary<string, string>? Headers);

internal sealed record SessionPayload(
    [property: JsonPropertyName("serverId")] string ServerId,
    [property: JsonPropertyName("kind")] string Kind,
    [property: JsonPropertyName("baseURL")] string BaseUrl,
    [property: JsonPropertyName("token")] string Token,
    [property: JsonPropertyName("userID")] string? UserId,
    [property: JsonPropertyName("serverName")] string ServerName,
    [property: JsonPropertyName("clientIdentifier")] string ClientIdentifier,
    [property: JsonPropertyName("serverMachineIdentifier")] string? ServerMachineIdentifier,
    [property: JsonPropertyName("accountToken")] string? AccountToken);

internal sealed record PlexPinPayload(
    [property: JsonPropertyName("pinId")] int PinId,
    [property: JsonPropertyName("code")] string Code,
    [property: JsonPropertyName("clientIdentifier")] string ClientIdentifier,
    [property: JsonPropertyName("linkURL")] string? LinkUrl);

public sealed record PlexHomeUser(
    string Id,
    string Name,
    bool RequiresPIN,
    bool IsAdmin,
    bool IsRestricted,
    string? AvatarURL);

internal sealed record PlexAccountTokenPayload(string? AccountToken);
internal sealed record PlexSwitchedTokenPayload(string AccountToken);

internal sealed record AttachPayload(
    [property: JsonPropertyName("serverId")] string ServerId);

internal sealed record UrlPayload(
    [property: JsonPropertyName("url")] string? Url);
