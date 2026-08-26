using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Threading;
using System.Threading.Tasks;
using Makaretu.Dns;

namespace Mozz.Desktop.Core;

/// <summary>A Mozz device found on the network, waiting to be paired.</summary>
public sealed record PairingCandidate(string Name, IPAddress Address, int Port);

/// <summary>
/// Finds devices advertising <c>_mozz._tcp</c>.
/// </summary>
/// <remarks>
/// The joining device advertises, because it is the one asking to be let in;
/// this side goes looking, because it is the one holding something worth
/// giving. Several may answer at once in a house with more than one Mozz
/// device, so this yields all of them and the caller tries each — a device that
/// is not the one whose code was scanned is rejected by the core, so "wrong
/// device" and "impostor" need no separate handling here.
///
/// Verified against a real iPhone advertising through Network.framework, which
/// matters because a discovery implementation that only ever talks to itself
/// proves very little.
/// </remarks>
public sealed class PairingDiscovery : IDisposable
{
    public const string ServiceType = "_mozz._tcp";

    private readonly ServiceDiscovery _discovery = new();

    /// <summary>
    /// Watches for devices until <paramref name="token"/> is cancelled,
    /// reporting each one once.
    /// </summary>
    public async IAsyncEnumerable<PairingCandidate> WatchAsync(
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken token = default)
    {
        var queue = new System.Collections.Concurrent.ConcurrentQueue<PairingCandidate>();
        var seen = new HashSet<string>();

        void OnInstance(object? sender, ServiceInstanceDiscoveryEventArgs e)
        {
            var name = e.ServiceInstanceName.ToString();
            if (!name.Contains(ServiceType, StringComparison.Ordinal)) return;

            var candidate = Resolve(name, e.Message);
            if (candidate is not null) queue.Enqueue(candidate);
        }

        _discovery.ServiceInstanceDiscovered += OnInstance;
        try
        {
            // Ask repeatedly rather than once. The other device may not have
            // reached its pairing screen yet, and an announcement missed while
            // it was starting up would otherwise never be seen again.
            _ = Task.Run(async () =>
            {
                while (!token.IsCancellationRequested)
                {
                    try { _discovery.QueryServiceInstances(ServiceType); } catch { /* transient */ }
                    try { await Task.Delay(TimeSpan.FromSeconds(3), token); } catch { return; }
                }
            }, token);

            while (!token.IsCancellationRequested)
            {
                while (queue.TryDequeue(out var candidate))
                {
                    if (seen.Add($"{candidate.Address}:{candidate.Port}")) yield return candidate;
                }
                try { await Task.Delay(150, token); } catch { yield break; }
            }
        }
        finally
        {
            _discovery.ServiceInstanceDiscovered -= OnInstance;
        }
    }

    /// <summary>
    /// Pulls an address and port out of the answer, when the responder included
    /// them. Apple's mDNS usually sends SRV and A records alongside the PTR, so
    /// a second round trip is normally unnecessary.
    /// </summary>
    private static PairingCandidate? Resolve(string instanceName, Message message)
    {
        var srv = message.AdditionalRecords.OfType<SRVRecord>()
            .Concat(message.Answers.OfType<SRVRecord>())
            .FirstOrDefault();
        if (srv is null) return null;

        var address = message.AdditionalRecords.OfType<ARecord>().Select(a => a.Address)
            .Concat(message.AdditionalRecords.OfType<AAAARecord>().Select(a => a.Address))
            .FirstOrDefault();
        if (address is null) return null;

        var label = instanceName.Split('.').FirstOrDefault() ?? "Mozz device";
        return new PairingCandidate(label.Replace("\\032", " "), address, srv.Port);
    }

    public void Dispose() => _discovery.Dispose();
}
