using System;
using System.Threading;
using System.Threading.Tasks;
using System.Text.Json.Serialization;

namespace Mozz.Desktop.Core;

public sealed record RelayHistorySyncResult(
    int Imported,
    string RelayKey,
    long ExpiresAtMS);

public sealed record RelaySyncOutcome(
    int ImportedHistoryEvents,
    int ImportedServers,
    int ImportedCatalogTracks,
    RelayPlaybackSettingsDto? PlaybackSettings,
    bool PlaybackSettingsChanged);

public sealed record RelayEqualizerSettingsDto(
    [property: JsonPropertyName("gains")] double[] Gains,
    [property: JsonPropertyName("preampDB")] double PreampDB);

public sealed record RelayPlaybackSettingsDto(
    [property: JsonPropertyName("equalizerEnabled")] bool EqualizerEnabled,
    [property: JsonPropertyName("equalizer")] RelayEqualizerSettingsDto Equalizer,
    [property: JsonPropertyName("replayGainMode")] string ReplayGainMode,
    [property: JsonPropertyName("replayGainPreampDB")] double ReplayGainPreampDB);

public sealed record RelayPlaybackSettingsSyncResult(
    RelayPlaybackSettingsDto Settings,
    bool Changed,
    string RelayKey,
    long ExpiresAtMS);

public sealed record RelayCatalogCounts(
    int Artists,
    int Albums,
    int Tracks,
    int Playlists,
    int PlaylistItems);

public sealed record RelayCatalogSyncResult(
    string Status,
    RelayCatalogCounts Counts,
    bool Published,
    string RelayKey,
    long ExpiresAtMS);

/// <summary>
/// Schedules universal history, server, and catalog exchange through the shared
/// Swift core.
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

    public event Action? CatalogChanged;
    public event Action<Exception>? BackgroundSyncFailed;

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
        RelayPlaybackSettingsDto playbackSettings,
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

        RelayPlaybackSettingsSyncResult? playbackResult = null;
        try
        {
            playbackResult = await _core.CallAsync<RelayPlaybackSettingsSyncResult>(
                new
                {
                    cmd = "relaySyncPlaybackSettings",
                    circle,
                    deviceId = _deviceID,
                    playbackSettings,
                    relayEndpoint = DefaultEndpoint,
                },
                token).ConfigureAwait(false);
            if (playbackResult is not null
                && !string.Equals(
                    circle.RelayKey,
                    playbackResult.RelayKey,
                    StringComparison.Ordinal))
            {
                PairingService.StoreCircle(circle with
                {
                    RelayKey = playbackResult.RelayKey,
                });
                circle = circle with
                {
                    RelayKey = playbackResult.RelayKey,
                };
            }
        }
        catch (Exception error)
        {
            BackgroundSyncFailed?.Invoke(error);
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
        var importedCatalogTracks = 0;
        var addedIDs = new HashSet<string>(StringComparer.Ordinal);
        var preparedAccounts = new Dictionary<string, ServerAccount>(
            StringComparer.Ordinal);
        var accountsToReconcile = new Dictionary<string, ServerAccount>(
            StringComparer.Ordinal);
        if (serverResult is not null)
        {
            var imported = _server.ImportSyncedServers(
                serverResult.Servers);
            importedServerCount = imported.Added.Count;
            addedIDs = imported.Added
                .Select(account => account.ServerId)
                .ToHashSet(StringComparer.Ordinal);
            foreach (var account in imported.Changed)
            {
                var prepared = await _server.AttachForSyncAsync(
                    account, token).ConfigureAwait(false);
                preparedAccounts[account.ServerId] = prepared;
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
                circle = circle with { RelayKey = serverResult.RelayKey };
            }

            foreach (var account in _server.SavedAccounts())
            {
                var prepared = preparedAccounts.GetValueOrDefault(
                    account.ServerId, account);
                try
                {
                    var catalogResult = await _core.CallAsync<RelayCatalogSyncResult>(
                        new
                        {
                            cmd = "relaySyncCatalog",
                            circle,
                            deviceId = _deviceID,
                            serverId = prepared.ServerId,
                            musicSectionIDs = MozzServer.EffectiveMusicSectionIds(
                                prepared),
                            allMusicLibraries = prepared.AllMusicLibraries,
                            relayEndpoint = DefaultEndpoint,
                        },
                        token).ConfigureAwait(false);
                    if (catalogResult is null) continue;
                    if (string.Equals(
                            catalogResult.Status,
                            "imported",
                            StringComparison.Ordinal))
                    {
                        importedCatalogTracks += catalogResult.Counts.Tracks;
                        accountsToReconcile[prepared.ServerId] = prepared;
                    }
                    if (!string.Equals(
                            circle.RelayKey,
                            catalogResult.RelayKey,
                            StringComparison.Ordinal))
                    {
                        PairingService.StoreCircle(circle with
                        {
                            RelayKey = catalogResult.RelayKey,
                        });
                        circle = circle with
                        {
                            RelayKey = catalogResult.RelayKey,
                        };
                    }
                }
                catch (Exception error)
                {
                    BackgroundSyncFailed?.Invoke(error);
                }
            }

            foreach (var account in preparedAccounts.Values
                         .Where(account => addedIDs.Contains(account.ServerId)))
            {
                accountsToReconcile[account.ServerId] = account;
            }
            foreach (var account in accountsToReconcile.Values)
            {
                _ = ReconcileImportedCatalogAsync(account);
            }
        }
        return new RelaySyncOutcome(
            result.Imported,
            importedServerCount,
            importedCatalogTracks,
            playbackResult?.Settings,
            playbackResult?.Changed ?? false);
    }

    private async Task ReconcileImportedCatalogAsync(ServerAccount account)
    {
        try
        {
            await _server.SyncAsync(account.ServerId).ConfigureAwait(false);
            CatalogChanged?.Invoke();
        }
        catch (Exception error)
        {
            BackgroundSyncFailed?.Invoke(error);
        }
    }
}
