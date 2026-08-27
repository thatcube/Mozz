using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace Mozz.Desktop.Core;

/// <summary>One instruction from the core about what to do next.</summary>
public sealed record PairingStepDto(
    string Kind,
    string? Frame = null,
    string? Digits = null,
    string? Transcript = null,
    string? JoinerPublicKey = null,
    string? Encapsulated = null,
    string? Ciphertext = null);

public sealed record PairingBegan(
    string PairingId,
    string PublicKey,
    string? QrText,
    PairingStepDto[] Steps);

public sealed record PairingSteps(
    PairingStepDto[] Steps,
    string? PeerName = null,
    string? PeerDeviceID = null);

public sealed record PairingPeer(string? Name, string? DeviceID);

/// <summary>The circle this device belongs to, as the core reports it.</summary>
public sealed record CircleDto(
    string ChannelId,
    string ChannelKey,
    string CredentialsKey,
    int Epoch,
    string RelayKey);

/// <summary>
/// Runs a pairing ceremony from the desktop.
/// </summary>
/// <remarks>
/// Every decision belongs to the core: what to send, when to ask a human, when
/// it is finished. This owns the socket and the discovery, which are the only
/// parts Network.framework cannot do on Windows, and pumps frames between the
/// two. No protocol logic and no cryptography lives here, which is why the
/// desktop needed roughly eighty lines rather than an implementation of
/// RFC 9180.
/// </remarks>
public sealed class PairingService
{
    private readonly MozzCore _core;
    private readonly string _deviceID;

    public PairingService(MozzCore core, string deviceID)
    {
        _core = core;
        _deviceID = deviceID;
    }

    public static bool HasCircle =>
        SecretStore.ForCurrentPlatform().Get("circle.channelId") is not null;

    /// <summary>
    /// Join a circle from a fresh desktop. The desktop advertises and waits;
    /// an established device discovers it from Devices and hands over the
    /// circle after both screens confirm the digits.
    /// </summary>
    public async Task JoinAsync(
        Func<string, Task<bool>> confirmDigits,
        CancellationToken token = default)
    {
        var began = await Call<PairingBegan>(new
        {
            cmd = "pairingBegin",
            role = "joiner",
            pairingPath = "digits",
            deviceName = CircleRoster.DeviceName,
            deviceId = _deviceID,
        }, token).ConfigureAwait(false);

        using var host = PairingHost.Start(CircleRoster.DeviceName);
        using var link = await host.AcceptAsync(token).ConfigureAwait(false);

        try
        {
            foreach (var step in began.Steps.Where(s => s.Kind == "send"))
            {
                await link.SendAsync(Convert.FromBase64String(step.Frame!), token)
                    .ConfigureAwait(false);
            }

            var peer = await PumpAsync(
                began.PairingId, link, confirmDigits, isJoiner: true, token)
                .ConfigureAwait(false);
            CircleRoster.Remember(_deviceID, CircleRoster.DeviceName, isSelf: true);
            if (!string.IsNullOrWhiteSpace(peer.Name)
                && !string.IsNullOrWhiteSpace(peer.DeviceID))
            {
                CircleRoster.Remember(peer.DeviceID, peer.Name, isSelf: false);
            }
        }
        finally
        {
            await SafeEndAsync(began.PairingId).ConfigureAwait(false);
        }
    }

    /// <summary>
    /// Admit a device that is showing a code. The desktop is the member: it
    /// holds the circle (forming one if it has none) and hands it over.
    /// </summary>
    /// <param name="scannedQrText">The code text, typed or pasted — a desktop
    /// usually has no camera worth pointing at a phone.</param>
    /// <param name="confirmDigits">Asked only on the digit path.</param>
    public async Task AdmitAsync(
        string? scannedQrText,
        PairingCandidate device,
        Func<string, Task<bool>> confirmDigits,
        CancellationToken token = default)
    {
        // No code means the digit path: both sides show six digits and a person
        // compares them. That is the whole reason the digit path exists — a
        // desktop has no camera worth pointing at a phone, and the QR payload is
        // sixty characters of base64 that nobody should be asked to retype.
        var usingCode = !string.IsNullOrWhiteSpace(scannedQrText);

        var began = await Call<PairingBegan>(new
        {
            cmd = "pairingBegin",
            role = "member",
            pairingPath = usingCode ? "qr" : "digits",
            scannedCode = usingCode ? scannedQrText : null,
            deviceName = CircleRoster.DeviceName,
            deviceId = _deviceID,
        }, token).ConfigureAwait(false);

        using var link = await PairingLink.ConnectAsync(device.Address, device.Port, token)
            .ConfigureAwait(false);

        try
        {
            var peer = await PumpAsync(
                began.PairingId, link, confirmDigits, isJoiner: false, token)
                .ConfigureAwait(false);

            // Both sides go in the roster, so "it worked" is something the
            // screen can show rather than something the user has to trust.
            CircleRoster.Remember(_deviceID, CircleRoster.DeviceName, isSelf: true);
            CircleRoster.Remember(
                peer.DeviceID ?? $"{device.Address}:{device.Port}",
                peer.Name ?? device.Name,
                isSelf: false);
        }
        finally
        {
            // Let the core drop the session even when this went wrong, so a
            // failed attempt does not leave a handle alive holding a key.
            await SafeEndAsync(began.PairingId).ConfigureAwait(false);
        }
    }

    /// <summary>
    /// Pumps frames until the ceremony finishes. Both roles share this: the
    /// core decides what each side does, so the loop does not need to know
    /// which one it is driving beyond where the circle ends up.
    /// </summary>
    private async Task<PairingPeer> PumpAsync(
        string pairingId,
        PairingLink link,
        Func<string, Task<bool>> confirmDigits,
        bool isJoiner,
        CancellationToken token)
    {
        var pending = new Queue<PairingStepDto>();
        string? peerName = null;
        string? peerDeviceID = null;

        while (true)
        {
            if (pending.Count == 0)
            {
                var frame = await link.ReceiveAsync(token).ConfigureAwait(false);
                var steps = await Call<PairingSteps>(new
                {
                    cmd = "pairingReceive",
                    pairingId,
                    frame = Convert.ToBase64String(frame),
                }, token).ConfigureAwait(false);

                peerName ??= steps.PeerName;
                peerDeviceID ??= steps.PeerDeviceID;
                foreach (var step in steps.Steps) pending.Enqueue(step);
                if (pending.Count == 0) continue;
            }

            var next = pending.Dequeue();
            switch (next.Kind)
            {
                case "send":
                    await link.SendAsync(Convert.FromBase64String(next.Frame!), token)
                        .ConfigureAwait(false);
                    break;

                case "digits":
                    var matched = await confirmDigits(next.Digits!).ConfigureAwait(false);
                    var after = await Call<PairingSteps>(new
                    {
                        cmd = "pairingConfirm", pairingId, matched,
                    }, token).ConfigureAwait(false);
                    peerName ??= after.PeerName;
                    peerDeviceID ??= after.PeerDeviceID;
                    foreach (var step in after.Steps) pending.Enqueue(step);
                    break;

                case "seal":
                    var sealed_ = await Call<PairingSteps>(new
                    {
                        cmd = "pairingSeal",
                        pairingId,
                        circle = await CircleForSharingAsync(token).ConfigureAwait(false),
                        transcript = next.Transcript,
                        joinerPublicKey = next.JoinerPublicKey,
                    }, token).ConfigureAwait(false);
                    peerName ??= sealed_.PeerName;
                    peerDeviceID ??= sealed_.PeerDeviceID;
                    foreach (var step in sealed_.Steps) pending.Enqueue(step);
                    break;

                case "open":
                    // The core opens it with a key this process has never held.
                    var circle = await Call<CircleDto>(new
                    {
                        cmd = "pairingOpen",
                        pairingId,
                        encapsulated = next.Encapsulated,
                        ciphertext = next.Ciphertext,
                        transcript = next.Transcript,
                    }, token).ConfigureAwait(false);
                    StoreCircle(circle);
                    return new PairingPeer(peerName, peerDeviceID);

                case "finished":
                    return new PairingPeer(peerName, peerDeviceID);
            }
        }
    }

    /// <summary>
    /// The circle to hand over, formed here if this device is not in one — the
    /// first pairing anyone does is between two devices where neither is.
    /// </summary>
    private async Task<object> CircleForSharingAsync(CancellationToken token)
    {
        var stored = LoadCircle();
        if (stored is not null) return stored;

        var created = await Call<CircleDto>(new { cmd = "circleCreate" }, token).ConfigureAwait(false);
        StoreCircle(created);
        return created;
    }

    internal static CircleDto? LoadCircle()
    {
        var store = SecretStore.ForCurrentPlatform();
        var channelId = store.Get("circle.channelId");
        var channelKey = store.Get("circle.channelKey");
        var credentialsKey = store.Get("circle.credentialsKey");
        var relayKey = store.Get("circle.relayKey") ?? string.Empty;
        var epoch = store.Get("circle.epoch");

        if (channelId is null || channelKey is null || credentialsKey is null) return null;
        return new CircleDto(channelId, channelKey, credentialsKey,
                             int.TryParse(epoch, out var e) ? e : 1, relayKey);
    }

    internal static void StoreCircle(CircleDto circle)
    {
        // Both halves go to the secure store here. Unlike Apple, where the
        // channel key sits in ordinary app storage and only the credentials key
        // needs the keychain, DPAPI is cheap enough per item that splitting
        // buys nothing on this platform.
        var store = SecretStore.ForCurrentPlatform();
        store.Set("circle.channelId", circle.ChannelId);
        store.Set("circle.channelKey", circle.ChannelKey);
        store.Set("circle.credentialsKey", circle.CredentialsKey);
        store.Set("circle.relayKey", circle.RelayKey);
        store.Set("circle.epoch", circle.Epoch.ToString());
    }

    private async Task SafeEndAsync(string pairingId)
    {
        try
        {
            await _core.CallAsync<PairingSteps>(new { cmd = "pairingEnd", pairingId })
                .ConfigureAwait(false);
        }
        catch
        {
            // Best effort; the session is discarded either way.
        }
    }

    private async Task<T> Call<T>(object request, CancellationToken token) where T : class
    {
        var response = await _core.CallAsync<T>(request, token).ConfigureAwait(false);
        return response ?? throw new InvalidOperationException("The core returned an empty pairing response");
    }
}
