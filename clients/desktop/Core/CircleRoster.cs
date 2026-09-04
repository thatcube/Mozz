using System;
using System.Collections.Generic;
using System.Text.Json;

namespace Mozz.Desktop.Core;

/// <summary>A device known to be in this circle.</summary>
public sealed record CircleMemberRow(
    string Name,
    DateTimeOffset JoinedAt,
    bool IsSelf,
    string? ID = null)
{
    public string JoinedDescription => IsSelf ? "This device" : JoinedAt.LocalDateTime.ToString("d MMM, HH:mm");
}

/// <summary>
/// The devices this one knows are in the circle.
/// </summary>
/// <remarks>
/// Mirrors <c>CircleStore.members</c> on Apple. Without it the desktop could
/// say a device had been added and then show nothing at all afterwards, which
/// is the state Brandon found: no way to tell whether it had worked, or what it
/// had worked with.
///
/// Local knowledge rather than authoritative membership — a device learns about
/// another by taking part in a ceremony with it.
/// </remarks>
public static class CircleRoster
{
    private const string Key = "circle.members";

    public static IReadOnlyList<CircleMemberRow> Load()
    {
        var stored = SecretStore.ForCurrentPlatform().Get(Key);
        if (string.IsNullOrWhiteSpace(stored)) return Array.Empty<CircleMemberRow>();
        try
        {
            return JsonSerializer.Deserialize<List<CircleMemberRow>>(stored) ?? new List<CircleMemberRow>();
        }
        catch (JsonException)
        {
            // A roster that cannot be read is a display problem, not a reason to
            // pretend the device is not in a circle.
            return Array.Empty<CircleMemberRow>();
        }
    }

    public static void Remember(string id, string name, bool isSelf)
    {
        var known = new List<CircleMemberRow>(Load());
        known.RemoveAll(m => string.Equals(m.ID ?? m.Name, id, StringComparison.Ordinal));
        known.Add(new CircleMemberRow(name, DateTimeOffset.UtcNow, isSelf, id));
        known.Sort((a, b) => b.JoinedAt.CompareTo(a.JoinedAt));
        SecretStore.ForCurrentPlatform().Set(Key, JsonSerializer.Serialize(known));
    }

    public static RelayMemberDto[] Export(string localDeviceID) =>
        Load()
            .Where(member => !member.IsSelf || member.ID == localDeviceID)
            .Select(member => new RelayMemberDto(
                member.ID ?? $"legacy:{member.Name}",
                member.Name,
                member.JoinedAt.ToUnixTimeMilliseconds(),
                null))
            .Append(new RelayMemberDto(
                localDeviceID,
                DeviceName,
                Load().FirstOrDefault(member => member.ID == localDeviceID)?
                    .JoinedAt.ToUnixTimeMilliseconds()
                    ?? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
                null))
            .GroupBy(member => member.Id, StringComparer.Ordinal)
            .Select(group => group.Last())
            .ToArray();

    public static void Replace(
        IEnumerable<RelayMemberDto> records,
        string localDeviceID)
    {
        var members = records
            .Where(record => record.RemovedAtMS is null)
            .Select(record => new CircleMemberRow(
                record.Name,
                DateTimeOffset.FromUnixTimeMilliseconds(record.JoinedAtMS),
                record.Id == localDeviceID,
                record.Id))
            .OrderByDescending(member => member.JoinedAt)
            .ToArray();
        SecretStore.ForCurrentPlatform().Set(Key, JsonSerializer.Serialize(members));
    }

    public static void Clear() => SecretStore.ForCurrentPlatform().Set(Key, null);

    /// <summary>
    /// What this device calls itself to the others.
    /// </summary>
    /// <remarks>
    /// <c>Environment.MachineName</c> is the computer's name on Windows, macOS
    /// and Linux alike — "BRANDON-PC", "Brandons-MacBook-Pro" — which is a name
    /// a person chose rather than a product name. Hyphens read back as spaces
    /// because a hostname cannot contain one.
    ///
    /// The point is not tidiness. This is the name someone reads when deciding
    /// whether the device asking to join is theirs, so "Mozz" for every device
    /// made that check impossible.
    /// </remarks>
    public static string DeviceName
    {
        get
        {
            var machine = Environment.MachineName?.Trim() ?? "";
            foreach (var suffix in new[] { ".local", ".lan" })
            {
                if (machine.EndsWith(suffix, StringComparison.OrdinalIgnoreCase))
                {
                    machine = machine[..^suffix.Length];
                    break;
                }
            }
            var readable = machine.Replace('-', ' ').Trim();
            if (readable.Length == 0 || readable.Equals("localhost", StringComparison.OrdinalIgnoreCase))
            {
                return OperatingSystem.IsWindows() ? "Windows PC"
                     : OperatingSystem.IsMacOS() ? "Mac"
                     : "Linux PC";
            }
            return readable.Length > 64 ? readable[..64] : readable;
        }
    }
}
