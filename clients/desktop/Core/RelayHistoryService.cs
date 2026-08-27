using System;
using System.Threading;
using System.Threading.Tasks;

namespace Mozz.Desktop.Core;

public sealed record RelayHistorySyncResult(
    int Imported,
    string RelayKey,
    long ExpiresAtMS);

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

    public RelayHistoryService(MozzCore core, string deviceID)
    {
        _core = core;
        _deviceID = deviceID;
    }

    public async Task<int?> SyncAsync(CancellationToken token = default)
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
        }
        return result.Imported;
    }
}
