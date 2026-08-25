namespace Mozz.Desktop.Audio.Decoding;

/// <summary>
/// Works out which <c>ffmpeg</c> to run. Extracted from the decoder so the
/// ordering — the part that has actually bitten us — can be unit-tested without
/// spawning anything.
///
/// The bug this exists to prevent: on macOS a double-clicked <c>.app</c> is
/// launched by <c>launchd</c>, not a shell, so it inherits <c>launchd</c>'s
/// minimal <c>PATH</c> (<c>/usr/bin:/bin:/usr/sbin:/sbin</c>) — which does not
/// include <c>/opt/homebrew/bin</c>. Homebrew's ffmpeg lives there, so
/// <c>Process.Start("ffmpeg")</c> throws "No such file or directory" and the app
/// reports it cannot open the track. The same binary, given by absolute path,
/// starts fine. Launching from a terminal (or <c>open</c> from one) hides this,
/// because then the process inherits the shell's full PATH — which is why it
/// looked like it worked. Windows never sees it: its release bundles ffmpeg
/// beside the app, so it is found by the app-directory probe below and PATH
/// never enters into it.
///
/// So we do not rely on the process PATH alone. After an explicit override and a
/// copy shipped beside the app, we probe the handful of absolute locations a
/// package manager actually installs ffmpeg into, and only then fall back to the
/// bare name for the OS to resolve.
/// </summary>
internal static class FfmpegLocator
{
    /// <summary>
    /// The absolute directories a system package manager installs ffmpeg into,
    /// which a GUI process with a stripped PATH would otherwise miss.
    /// </summary>
    private static readonly string[] UnixInstallDirs =
    [
        "/opt/homebrew/bin", // Homebrew, Apple silicon
        "/usr/local/bin",    // Homebrew, Intel; hand-built; much of Linux
        "/opt/local/bin",    // MacPorts
        "/usr/bin",          // system packages on Linux
        "/bin",
        "/snap/bin",         // Ubuntu snap
    ];

    /// <summary>
    /// The ordered list of concrete paths to probe, most-trusted first: a copy
    /// shipped beside the app (the one we tested against), then the well-known
    /// install locations. Does not include the bare fallback — that is
    /// <see cref="Resolve"/>'s last resort when nothing here exists.
    /// </summary>
    public static IEnumerable<string> Candidates(string appDir, bool isWindows)
    {
        var exe = isWindows ? "ffmpeg.exe" : "ffmpeg";

        // Joined against the separator of the *target* platform, not the host's.
        // This method takes `isWindows` so the Windows and Unix orderings can
        // both be tested from any machine; Path.Combine would quietly punctuate
        // the Unix candidates with a backslash when those tests run on Windows,
        // yielding "/opt/homebrew/bin\ffmpeg".
        var sep = isWindows ? '\\' : '/';
        string Join(params string[] parts) => string.Join(sep, parts);

        yield return Join(appDir.TrimEnd('/', '\\'), exe);
        yield return Join(appDir.TrimEnd('/', '\\'), "ffmpeg", exe);
        yield return Join(appDir.TrimEnd('/', '\\'), "runtimes", "ffmpeg", exe);

        if (!isWindows)
            foreach (var dir in UnixInstallDirs)
                yield return $"{dir}/{exe}";
    }

    /// <summary>
    /// Resolve the ffmpeg path. An explicit <c>MOZZ_FFMPEG</c> override wins
    /// outright and is returned even if it does not exist, so a wrong override
    /// produces an error that names it rather than being silently ignored.
    /// Otherwise the first existing <see cref="Candidates"/> path is used; if
    /// none exist, the bare executable name is returned for the OS to resolve on
    /// PATH — and if that fails too, the caller's error tells the user how to fix
    /// it.
    /// </summary>
    /// <param name="exists">Filesystem probe, injected so tests need no real files.</param>
    public static string Resolve(string appDir, bool isWindows, string? mozzOverride, Func<string, bool> exists)
    {
        if (!string.IsNullOrEmpty(mozzOverride)) return mozzOverride;

        foreach (var candidate in Candidates(appDir, isWindows))
            if (exists(candidate))
                return candidate;

        return isWindows ? "ffmpeg.exe" : "ffmpeg";
    }
}
