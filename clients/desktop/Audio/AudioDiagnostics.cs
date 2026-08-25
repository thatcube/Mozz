using System.Text;
using System.Text.RegularExpressions;

namespace Mozz.Desktop.Audio;

/// <summary>
/// Turns the raw, noisy things a failed decode produces — a query URL carrying a
/// credential, a wall of <c>ffmpeg</c> stderr — into one short line fit to show a
/// human, with the secret taken out first.
///
/// It lives in its own file, apart from <see cref="MiniAudioEngine"/>, on purpose:
/// that engine is the one audio file the headless test project cannot compile
/// (it binds the native device), and redaction is exactly the sort of
/// string-wrangling that must be tested. Everything here is pure and
/// side-effect-free.
/// </summary>
internal static class AudioDiagnostics
{
    // Query/header keys whose *value* is a credential and must never be shown or
    // logged. Plex puts its token in the URL as ?X-Plex-Token=…, which is how it
    // ends up on a status bar; Jellyfin/Emby use api_key / X-Emby-Token; the rest
    // are the usual suspects so this stays useful if a source URL ever changes.
    private const string SensitiveKeys =
        "X-Plex-Token|X-Emby-Token|X-MediaBrowser-Token|PlexToken|api_key|apikey|" +
        "access_token|token|auth|password|passwd|jwt|sig|signature";

    // ?key=secret  or  &key=secret  (stops at the next separator/quote/space).
    private static readonly Regex QueryCredential =
        new($"([?&;])({SensitiveKeys})=[^&\\s\"'<>]+", RegexOptions.IgnoreCase | RegexOptions.Compiled);

    // X-Plex-Token: secret  or  X-Plex-Token=secret, as it appears in a header
    // dump or an ffmpeg log line rather than a query string.
    private static readonly Regex HeaderCredential =
        new("(X-Plex-Token|X-Emby-Token|X-MediaBrowser-Token)\\s*[:=]\\s*[^\\s&\"'<>]+",
            RegexOptions.IgnoreCase | RegexOptions.Compiled);

    // ffmpeg prefixes most lines with the emitting component and a heap address,
    // e.g. "[tls @ 0x72cc34000] …" — noise once the message itself is kept.
    private static readonly Regex FfmpegComponentPrefix =
        new("^\\[[^\\]]*\\]\\s*", RegexOptions.Compiled);

    /// <summary>
    /// Replace the value of any credential-bearing parameter with
    /// <c>REDACTED</c>, wherever it appears in <paramref name="text"/> — a bare
    /// URL, a header line, or an ffmpeg message that quoted the URL back. The
    /// token is a credential; it has no business on a status bar or in a log.
    /// </summary>
    public static string Redact(string? text)
    {
        if (string.IsNullOrEmpty(text)) return text ?? "";
        var once = QueryCredential.Replace(text, "$1$2=REDACTED");
        return HeaderCredential.Replace(once, m => RedactHeader(m.Value));
    }

    private static string RedactHeader(string matched)
    {
        int cut = matched.IndexOfAny([':', '=']);
        return cut < 0 ? matched : matched[..(cut + 1)] + "REDACTED";
    }

    /// <summary>
    /// Distil an ffmpeg stderr tail down to the one line worth reading, with the
    /// token stripped and the component/address noise removed. Prefers a line
    /// that names a known failure (a bad certificate, a 404, a refused
    /// connection) and phrases the common ones in plain words; otherwise returns
    /// the most specific line ffmpeg produced. Empty when there is nothing to
    /// say.
    /// </summary>
    public static string SummariseFfmpeg(string? stderr)
    {
        if (string.IsNullOrWhiteSpace(stderr)) return "";

        var lines = Redact(stderr)
            .Replace("\r", "\n")
            .Split('\n')
            .Select(l => FfmpegComponentPrefix.Replace(l.Trim(), ""))
            .Where(l => l.Length > 0)
            .ToList();
        if (lines.Count == 0) return "";

        foreach (var line in lines)
            if (Friendly(line) is { } friendly)
                return friendly;

        // No recognised signal: the last line that is not ffmpeg's generic
        // "Error opening input file <url>" trailer carries the most detail.
        var best = lines.LastOrDefault(l =>
                       !l.StartsWith("Error opening input file", StringComparison.OrdinalIgnoreCase) &&
                       !l.StartsWith("Error opening input files", StringComparison.OrdinalIgnoreCase))
                   ?? lines[^1];
        return Clamp(best);
    }

    /// <summary>
    /// A complete, user-facing sentence for a decode that failed after ffmpeg had
    /// started: the reason first (so a truncating status bar keeps the part that
    /// matters), the ffmpeg exit code kept as a breadcrumb.
    /// </summary>
    public static string DescribeFfmpegFailure(int? exitCode, string? stderr)
    {
        var reason = SummariseFfmpeg(stderr);
        if (reason.Length == 0)
            reason = "the audio stream could not be opened";

        var sb = new StringBuilder("Couldn’t play this track — ").Append(reason);
        if (exitCode is { } code and not 0)
            sb.Append(" (ffmpeg exit ").Append(code).Append(')');
        return sb.ToString();
    }

    /// <summary>
    /// The message shown when a track cannot be opened at all (the decoder threw
    /// before playback began — most often ffmpeg not being found). The reason
    /// comes first so a status bar that truncates keeps the part that matters;
    /// the source location comes second and with its token stripped, because a
    /// URL carrying <c>X-Plex-Token</c> is a credential and does not belong on
    /// screen. Contrast the old form, which led with the whole URL and pushed the
    /// reason off the end — the very reason this bug was so hard to see.
    /// </summary>
    public static string DescribeOpenFailure(string? uri, string? exMessage)
    {
        var reason = string.IsNullOrWhiteSpace(exMessage)
            ? "the track could not be opened"
            : exMessage!.Trim();

        var where = Redact(uri);
        return where.Length == 0 ? reason : $"{reason} — {where}";
    }

    private static string? Friendly(string line)
    {
        bool Has(string s) => line.Contains(s, StringComparison.OrdinalIgnoreCase);

        if (Has("certificate verify failed") || Has("self-signed") || Has("self signed") ||
            Has("unable to get local issuer") || Has("certificate has expired"))
            return "the server’s TLS certificate could not be verified";
        if (Has("unauthorized") || Has("401") || Has("403") || Has("forbidden"))
            return "the server rejected the request — the access token may be wrong or expired";
        if (Has("404") || Has("not found"))
            return "the server could not find this track (404)";
        if (Has("connection refused"))
            return "the server refused the connection";
        if (Has("name or service not known") || Has("temporary failure in name resolution") ||
            Has("failed to resolve") || Has("could not resolve"))
            return "the server’s address could not be resolved";
        if (Has("timed out") || Has("timeout"))
            return "the connection to the server timed out";
        if (Has("network is unreachable") || Has("no route to host"))
            return "the server could not be reached on the network";
        if (Has("connection reset"))
            return "the server reset the connection";
        if (Has("protocol not found"))
            return "this build of ffmpeg cannot speak the URL’s protocol";
        if (Has("server returned 5"))
            return "the server reported an internal error (5xx)";
        return null;
    }

    private static string Clamp(string s, int max = 180)
        => s.Length <= max ? s : s[..(max - 1)].TrimEnd() + "…";
}
