using System;
using System.IO;
using System.Linq;
using Mozz.Desktop.Core;
using Xunit;

namespace Mozz.Desktop.Tests;

public sealed class MozzServerSyncTests
{
    private static (
        MozzServer Server,
        FileSecretStore Secrets,
        string AccountsPath
    ) MakeServer()
    {
        var root = Path.Combine(
            Path.GetTempPath(), "mozz-server-sync-" + Guid.NewGuid().ToString("N"));
        var secrets = new FileSecretStore(Path.Combine(root, "secrets"));
        var accounts = Path.Combine(root, "accounts.json");
        return (new MozzServer(new MozzCore(), secrets, accounts), secrets, accounts);
    }

    private static ServerAccount Account(string id = "plex:machine") => new()
    {
        ServerId = id,
        Kind = BackendKind.Plex,
        BaseUrl = "https://plex.example.test",
        ServerName = "Home Plex",
        UserId = "managed-user",
        Username = "Music Room",
        ClientIdentifier = "local-client",
        ServerMachineIdentifier = "machine",
        MusicSectionId = "music",
    };

    [Fact]
    public void ExistingSavedAccountsSeedTheSyncJournal()
    {
        var (server, _, _) = MakeServer();
        server.SaveAccount(
            Account(), secret: "server-token",
            accountToken: "switched-profile-token");

        var record = server.ExportSyncedServers().Single();

        Assert.Equal("server-token", record.Token);
        Assert.Equal("switched-profile-token", record.AccountToken);
        Assert.Equal("managed-user", record.UserId);
        Assert.NotNull(record.MusicSectionIds);
        Assert.Equal(["music"], record.MusicSectionIds);
        var json = System.Text.Json.JsonSerializer.Serialize(record);
        Assert.DoesNotContain("local-client", json);
    }

    [Fact]
    public void ImportedServerUsesThisInstallationsClientIdentifier()
    {
        var (server, secrets, _) = MakeServer();
        secrets.Set("clientIdentifier", "this-device-client");
        var remote = new RelayServerRecordDto
        {
            Id = "jellyfin:user",
            Kind = "jellyfin",
            Name = "Home Music",
            BaseUrl = "https://music.example.test",
            Token = "remote-token",
            UserId = "user",
            Username = "listener",
            UpdatedAtMS = 100,
        };

        var imported = server.ImportSyncedServers([remote]);

        Assert.Single(imported.Added);
        Assert.Single(imported.Changed);
        var account = server.SavedAccounts().Single();
        Assert.Equal("this-device-client", account.ClientIdentifier);
        Assert.Equal("remote-token", secrets.Get("token.jellyfin:user"));
    }

    [Fact]
    public void RemoteTombstoneRemovesAccountAndCredential()
    {
        var (server, secrets, _) = MakeServer();
        server.SaveAccount(Account(), "server-token");
        var canonicalID = server.ExportSyncedServers().Single().Id;
        var removed = new RelayServerRecordDto
        {
            Id = canonicalID,
            Kind = "plex",
            UpdatedAtMS = long.MaxValue,
            RemovedAtMS = long.MaxValue,
        };

        server.ImportSyncedServers([removed]);

        Assert.Empty(server.SavedAccounts());
        Assert.Null(secrets.Get($"token.{canonicalID}"));
    }

    [Fact]
    public void ImportingTheSameServerTwiceDoesNotReportItNewTwice()
    {
        var (server, _, _) = MakeServer();
        var remote = new RelayServerRecordDto
        {
            Id = "subsonic:user",
            Kind = "subsonic",
            Name = "Navidrome",
            BaseUrl = "https://music.example.test",
            Token = "credential-envelope",
            UserId = "user",
            UpdatedAtMS = 100,
        };

        Assert.Single(server.ImportSyncedServers([remote]).Added);
        var replay = server.ImportSyncedServers([remote]);
        Assert.Empty(replay.Added);
        Assert.Empty(replay.Changed);
    }

    [Fact]
    public void NewerCredentialForExistingServerIsChangedButNotAdded()
    {
        var (server, secrets, _) = MakeServer();
        server.SaveAccount(Account(), "old-token");
        var existing = server.ExportSyncedServers().Single();
        var remote = existing with
        {
            Token = "new-token",
            UpdatedAtMS = existing.UpdatedAtMS + 1,
        };

        var imported = server.ImportSyncedServers([remote]);

        Assert.Empty(imported.Added);
        Assert.Single(imported.Changed);
        Assert.Equal("new-token", secrets.Get($"token.{existing.Id}"));
    }
}
