using System.Globalization;
using System.Reflection;

namespace Mozz.Desktop.Core;

public static class AppVersion
{
    public static string FromAssembly(Assembly assembly)
    {
        var informational = assembly
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?
            .InformationalVersion;

        if (!string.IsNullOrWhiteSpace(informational))
        {
            var plus = informational.IndexOf('+', StringComparison.Ordinal);
            return plus > 0 ? informational[..plus] : informational.Trim();
        }

        return assembly.GetName().Version?.ToString() ?? "unknown";
    }

    public static string Display(string? marketingVersion, string? buildNumber)
    {
        var marketing = NormalizeMarketingVersion(marketingVersion);
        if (string.IsNullOrEmpty(marketing))
        {
            marketing = "unknown";
        }

        var build = buildNumber?.Trim();
        return string.IsNullOrEmpty(build) ? marketing : $"{marketing} ({build})";
    }

    public static string CalVer(DateTime date) =>
        FormattableString.Invariant($"{date.Year}.{date.Month}.{date.Day}");

    private static string NormalizeMarketingVersion(string? marketingVersion)
    {
        var trimmed = marketingVersion?.Trim() ?? "";
        if (trimmed.Length == 0) return "";

        var parts = trimmed.Split('.');
        if (parts.Length < 2 || parts.Any(part => !int.TryParse(part, NumberStyles.None, CultureInfo.InvariantCulture, out _)))
        {
            return trimmed;
        }

        return string.Join(".", parts.Select(part => int.Parse(part, CultureInfo.InvariantCulture).ToString(CultureInfo.InvariantCulture)));
    }
}
