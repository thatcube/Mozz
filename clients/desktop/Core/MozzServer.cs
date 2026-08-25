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
    public async Task<ServerAccount?> PollPlexLinkAsync(PlexLink link, CancellationToken token = default)
    {
        var session = await core.CallAsync<SessionPayload>(new
        {
            cmd = "plexPinCheck",
            pinId = link.PinId,
            code = link.Code,
            clientIdentifier = link.ClientIdentifier,
        }, token).ConfigureAwait(false);

        // The core answers `{ "url": null }` for "not linked yet", which
        // deserializes to a session with no token.
        if (session is null || string.IsNullOrEmpty(session.Token)) return null;
        return Persist(session, username: null, link.ClientIdentifier);
    }

    // MARK: Attach

    /// <summary>
    /// Give the core the credentials for a saved account so sync and playback
    /// work. Called at launch for every saved account.
    /// </summary>
    public async Task AttachAsync(ServerAccount account, CancellationToken token = default)
    {
        var secret = secrets.Get(SecretKey(account.ServerId))
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
            musicSectionID = account.MusicSectionId,
        }, token).ConfigureAwait(false);
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

    public async Task<string?> ArtworkUrlAsync(
        string serverId, string artworkKey, int size = 512, CancellationToken token = default)
    {
        var result = await core.CallAsync<UrlPayload>(new
        {
            cmd = "artworkURL", serverId, artworkKey, size,
        }, token).ConfigureAwait(false);
        return result?.Url;
    }

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
            return JsonSerializer.Deserialize<List<ServerAccount>>(File.ReadAllText(path)) ?? [];
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
        var remaining = SavedAccounts().Where(a => a.ServerId != serverId).ToList();
        WriteAccounts(remaining);
        secrets.Set(SecretKey(serverId), null);
        secrets.Set($"plex.account.{serverId}", null);
    }

    public void ForgetAllAccounts()
    {
        foreach (var account in SavedAccounts())
        {
            secrets.Set(SecretKey(account.ServerId), null);
            secrets.Set($"plex.account.{account.ServerId}", null);
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
            MusicSectionId = null,
        };

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
        var accounts = SavedAccounts().Where(a => a.ServerId != account.ServerId).ToList();
        accounts.Add(account);
        WriteAccounts(accounts);
    }

    internal void SaveAccount(ServerAccount account, string secret, string? accountToken = null)
    {
        secrets.Set(SecretKey(account.ServerId), secret);
        if (accountToken is not null) secrets.Set($"plex.account.{account.ServerId}", accountToken);
        SaveAccount(account);
    }

    private void WriteAccounts(IReadOnlyList<ServerAccount> accounts)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_accountsPath)!);
        File.WriteAllText(_accountsPath, JsonSerializer.Serialize(accounts,
            new JsonSerializerOptions { WriteIndented = true }));
    }

    private static string SecretKey(string serverId) => $"token.{serverId}";

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
    public string? MusicSectionId { get; init; }
}

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
    [property: JsonPropertyName("playlists")] int? Playlists)
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

public sealed record StreamSource(
    [property: JsonPropertyName("url")] string Url,
    [property: JsonPropertyName("isTranscoded")] bool IsTranscoded,
    [property: JsonPropertyName("sessionID")] string? SessionId);

internal sealed record SessionPayload(
    [property: JsonPropertyName("serverId")] string ServerId,
    [property: JsonPropertyName("kind")] string Kind,
    [property: JsonPropertyName("baseURL")] string BaseUrl,
    [property: JsonPropertyName("token")] string Token,
    [property: JsonPropertyName("userID")] string? UserId,
    [property: JsonPropertyName("serverName")] string ServerName,
    [property: JsonPropertyName("clientIdentifier")] string ClientIdentifier,
    [property: JsonPropertyName("accountToken")] string? AccountToken);

internal sealed record PlexPinPayload(
    [property: JsonPropertyName("pinId")] int PinId,
    [property: JsonPropertyName("code")] string Code,
    [property: JsonPropertyName("clientIdentifier")] string ClientIdentifier,
    [property: JsonPropertyName("linkURL")] string? LinkUrl);

internal sealed record AttachPayload(
    [property: JsonPropertyName("serverId")] string ServerId);

internal sealed record UrlPayload(
    [property: JsonPropertyName("url")] string? Url);
