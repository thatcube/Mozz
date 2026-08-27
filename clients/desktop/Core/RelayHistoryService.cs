using System;
using System.Threading;
using System.Threading.Tasks;

namespace Mozz.Desktop.Core;

public sealed record RelayHistorySyncResult(
    int Imported,
    string RelayKey,
    long ExpiresAtMS);

public sealed record RelaySyncOutcome(
    int ImportedHistoryEvents,
    int ImportedServers);

/// <summary>
/// Schedules one universal history exchange through the shared Swift core.
/// </summary>
/// <remarks>
/// The desktop owns only cadence and secure persistence. B2 authorization,
/// provisioning, encryption, manifests, object layout, import-before-publish,
/// and history merging all execute in MozzRelay/MozzDatabase through the FFI,
/// exactly as they do on Apple.
/// </remarks>
public sealed class RelayHistoryService
{
    public const string DefaultEndpoint = "https://relay.mozzmusic.com";

    private readonly MozzCore _core;
    private readonly string _deviceID;
    private readonly MozzServer _server;

    public RelayHistoryService(
        MozzCore core,
        string deviceID,
        MozzServer server)
    {
        _core = core;
        _deviceID = deviceID;
        _server = server;
    }

    public async Task<RelaySyncOutcome?> SyncAsync(
        CancellationToken token = default)
    {
        var circle = PairingService.LoadCircle();
        if (circle is null) return null;

        var result = await _core.CallAsync<RelayHistorySyncResult>(new
        {
            cmd = "relaySyncHistory",
            circle,
            deviceId = _deviceID,
            deviceName = CircleRoster.DeviceName,
            relayEndpoint = DefaultEndpoint,
        }, token).ConfigureAwait(false);
        if (result is null) return null;

        if (!string.Equals(
                circle.RelayKey,
                result.RelayKey,
                StringComparison.Ordinal))
        {
            PairingService.StoreCircle(circle with
            {
                RelayKey = result.RelayKey,
            });
            circle = circle with { RelayKey = result.RelayKey };
        }

        var localServers = _server.ExportSyncedServers();
        var serverResult = await _core.CallAsync<RelayServerSyncResult>(new
        {
            cmd = "relaySyncServers",
            circle,
            deviceId = _deviceID,
            servers = localServers,
            relayEndpoint = DefaultEndpoint,
        }, token).ConfigureAwait(false);
        var importedServerCount = 0;
        if (serverResult is not null)
        {
            var imported = _server.ImportSyncedServers(
                serverResult.Servers);
            importedServerCount = imported.Added.Count;
            var addedIDs = imported.Added
                .Select(account => account.ServerId)
                .ToHashSet(StringComparer.Ordinal);
            foreach (var account in imported.Changed)
            {
                var prepared = await _server.AttachForSyncAsync(
                    account, token).ConfigureAwait(false);
                if (addedIDs.Contains(account.ServerId))
                {
                    await _server.SyncAsync(
                        prepared.ServerId,
                        token: token).ConfigureAwait(false);
                }
            }
            if (!string.Equals(
                    circle.RelayKey,
                    serverResult.RelayKey,
                    StringComparison.Ordinal))
            {
                PairingService.StoreCircle(circle with
                {
                    RelayKey = serverResult.RelayKey,
                });
            }
        }
        return new RelaySyncOutcome(
            result.Imported,
            importedServerCount);
    }
}
