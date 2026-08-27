using System;
using System.Linq;
using Mozz.Desktop.Core;
using Xunit;

namespace Mozz.Desktop.Tests;

public sealed class ServerSyncJournalTests
{
    private static ServerAccount Account(string section = "music") => new()
    {
        ServerId = "plex:machine",
        Kind = BackendKind.Plex,
        BaseUrl = "https://plex.example.test",
        ServerName = "Home Plex",
        UserId = "managed-user",
        Username = "Music Room",
        ClientIdentifier = "must-not-sync",
        ServerMachineIdentifier = "machine",
        MusicSectionId = section,
    };

    [Fact]
    public void RelaunchDoesNotCreateANewMutation()
    {
        var store = new FileSecretStore(
            System.IO.Path.Combine(
                System.IO.Path.GetTempPath(), Guid.NewGuid().ToString("N")));
        ServerSyncJournal.Upsert(
            store, Account(), "token", "profile-token",
            DateTimeOffset.FromUnixTimeMilliseconds(100));
        ServerSyncJournal.Upsert(
            store, Account(), "token", "profile-token",
            DateTimeOffset.FromUnixTimeMilliseconds(200));

        Assert.Equal(100, ServerSyncJournal.Load(store).Single().UpdatedAtMS);
    }

    [Fact]
    public void LibraryChangeCreatesANewMutation()
    {
        var store = new FileSecretStore(
            System.IO.Path.Combine(
                System.IO.Path.GetTempPath(), Guid.NewGuid().ToString("N")));
        ServerSyncJournal.Upsert(
            store, Account(), "token", "profile-token",
            DateTimeOffset.FromUnixTimeMilliseconds(100));
        ServerSyncJournal.Upsert(
            store, Account("other"), "token", "profile-token",
            DateTimeOffset.FromUnixTimeMilliseconds(200));

        var record = ServerSyncJournal.Load(store).Single();
        Assert.Equal(200, record.UpdatedAtMS);
        Assert.NotNull(record.MusicSectionIds);
        Assert.Equal(["other"], record.MusicSectionIds);
    }

    [Fact]
    public void LocalClientIdentifierNeverEntersTheRecord()
    {
        var store = new FileSecretStore(
            System.IO.Path.Combine(
                System.IO.Path.GetTempPath(), Guid.NewGuid().ToString("N")));
        ServerSyncJournal.Upsert(
            store, Account(), "token", "profile-token");

        var json = System.Text.Json.JsonSerializer.Serialize(
            ServerSyncJournal.Load(store));
        Assert.DoesNotContain("must-not-sync", json);
    }

    [Fact]
    public void TombstoneBeatsStaleActiveRecord()
    {
        var active = new RelayServerRecordDto
        {
            Id = "server",
            Kind = "jellyfin",
            Name = "Music",
            BaseUrl = "https://music.example.test",
            Token = "token",
            UpdatedAtMS = 100,
        };
        var removed = new RelayServerRecordDto
        {
            Id = "server",
            Kind = "jellyfin",
            UpdatedAtMS = 200,
            RemovedAtMS = 200,
        };

        var merged = ServerSyncJournal.Merge([active], [removed]);

        Assert.True(merged.Single().IsRemoved);
    }

    [Fact]
    public void TombstoneWinsAnExactTimestampTie()
    {
        var active = new RelayServerRecordDto
        {
            Id = "server",
            Kind = "jellyfin",
            Name = "Music",
            BaseUrl = "https://music.example.test",
            Token = "token",
            UpdatedAtMS = 200,
        };
        var removed = new RelayServerRecordDto
        {
            Id = "server",
            Kind = "jellyfin",
            UpdatedAtMS = 200,
            RemovedAtMS = 200,
        };

        Assert.True(ServerSyncJournal.Merge([active], [removed]).Single().IsRemoved);
    }
}
