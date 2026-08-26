using System.Text;

namespace Mozz.Desktop.Core.Downloads;

/// <summary>
/// Where a downloaded file lives, as a path relative to the shell's downloads
/// root. The layout is a portable decision — every platform lays files out the
/// same way — so this mirrors the core's <c>DownloadFileStore</c> exactly:
/// <c>&lt;serverId&gt;/&lt;remoteId&gt;.&lt;ext&gt;</c>, with each id sanitised to
/// a filesystem-safe form. Only the absolute root differs per platform.
/// </summary>
public static class DownloadLayout
{
    // The audio containers a media server hands out. Anything else — a transcode
    // endpoint with no extension, a query-only URL — falls back to "audio", the
    // same neutral extension the core's file store uses when it has none.
    private static readonly HashSet<string> KnownAudioExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        "mp3", "flac", "m4a", "m4b", "aac", "alac", "ogg", "oga", "opus",
        "wav", "wave", "aif", "aiff", "aifc", "wma", "mp4", "mka", "ape", "wv",
    };

    public static string RelativePath(string serverId, string remoteId, string fileExtension)
    {
        var server = Sanitize(serverId);
        var remote = Sanitize(remoteId);
        var ext = string.IsNullOrEmpty(fileExtension) ? "audio" : fileExtension;
        return $"{server}/{remote}.{ext}";
    }

    /// <summary>
    /// Best-effort file extension from a stream URL: the last path segment's
    /// extension when it is a container we recognise, else "audio". The query
    /// string is ignored — it is where transcode parameters live, not the format.
    /// </summary>
    public static string ExtensionFromUrl(string url)
    {
        if (string.IsNullOrWhiteSpace(url)) return "audio";

        var path = url;
        var query = path.IndexOfAny(['?', '#']);
        if (query >= 0) path = path[..query];

        var lastSlash = path.LastIndexOf('/');
        if (lastSlash >= 0) path = path[(lastSlash + 1)..];

        var dot = path.LastIndexOf('.');
        if (dot < 0 || dot == path.Length - 1) return "audio";

        var ext = path[(dot + 1)..];
        return KnownAudioExtensions.Contains(ext) ? ext.ToLowerInvariant() : "audio";
    }

    /// <summary>
    /// Replace anything outside <c>[A-Za-z0-9-_.]</c> with an underscore, and map
    /// only an empty input to "item" — byte-for-byte the rule the core applies
    /// (an all-disallowed component becomes all underscores, it does NOT collapse
    /// to "item"), so a path built on either side names the same file.
    /// </summary>
    private static string Sanitize(string component)
    {
        if (string.IsNullOrEmpty(component)) return "item";

        var builder = new StringBuilder(component.Length);
        foreach (var ch in component)
        {
            var ok = char.IsAsciiLetterOrDigit(ch) || ch is '-' or '_' or '.';
            builder.Append(ok ? ch : '_');
        }

        return builder.ToString();
    }
}
