using Mozz.Desktop.Core;
using Xunit;

namespace Mozz.Desktop.Tests;

/// <summary>
/// Exercises whichever credential store this platform selects, against the real
/// OS facility — DPAPI on Windows, the Keychain on macOS, a mode-0600 file
/// elsewhere.
///
/// Deliberately not mocked. The whole point of this class is that it calls a
/// native API correctly, and a mock would test only that the interface compiles.
/// Every defect this code can plausibly have — a wrong CFString constant, an
/// unbalanced CFRelease, DPAPI's add-vs-update distinction, a UTF-8 length
/// mistake — is invisible to a mock and caught here.
///
/// Windows is the one that most needs this: DPAPI cannot be exercised on a
/// developer's Mac at all, so CI is the only place it is ever run before a user
/// signs in.
/// </summary>
public class SecretStoreTests : IDisposable
{
    private readonly ISecretStore _store = SecretStore.ForCurrentPlatform();
    private readonly List<string> _keys = [];

    private string Key(string name)
    {
        // Unique per run so a crashed earlier run cannot leave an item that
        // makes a later one pass or fail spuriously.
        var key = $"mozz-test-{name}-{Guid.NewGuid():N}";
        _keys.Add(key);
        return key;
    }

    public void Dispose()
    {
        foreach (var key in _keys)
        {
            try { _store.Set(key, null); } catch { /* best effort cleanup */ }
        }
        GC.SuppressFinalize(this);
    }

    [Fact]
    public void PlatformStoreIsSelected()
    {
        Assert.False(string.IsNullOrWhiteSpace(_store.Description));
        if (OperatingSystem.IsWindows()) Assert.IsType<WindowsSecretStore>(_store);
        else if (OperatingSystem.IsMacOS()) Assert.IsType<MacKeychainSecretStore>(_store);
        else Assert.IsType<FileSecretStore>(_store);
    }

    [Fact]
    public void AbsentKeyReadsAsNull()
    {
        Assert.Null(_store.Get(Key("absent")));
    }

    [Fact]
    public void ValueRoundTrips()
    {
        var key = Key("roundtrip");
        var secret = $"tok-{Guid.NewGuid()}";
        _store.Set(key, secret);
        Assert.Equal(secret, _store.Get(key));
    }

    /// <summary>
    /// Signing in again to a server already saved must replace the token.
    /// macOS's SecItemAdd fails with errSecDuplicateItem rather than replacing,
    /// so this is a real branch and not a formality.
    /// </summary>
    [Fact]
    public void OverwriteReplacesRatherThanFailing()
    {
        var key = Key("overwrite");
        _store.Set(key, "first");
        _store.Set(key, "second");
        Assert.Equal("second", _store.Get(key));
    }

    [Fact]
    public void DeleteRemovesTheValue()
    {
        var key = Key("delete");
        _store.Set(key, "value");
        _store.Set(key, null);
        Assert.Null(_store.Get(key));
    }

    [Fact]
    public void DeletingAnAbsentKeyIsNotAnError()
    {
        _store.Set(Key("absent-delete"), null);
    }

    /// <summary>
    /// Server names and passwords are not ASCII, and a Subsonic credential is an
    /// encoded struct rather than a short token — so neither a byte-vs-character
    /// length mistake nor a small fixed buffer can be allowed to survive.
    /// </summary>
    [Theory]
    [InlineData("ü–é 🎵 mixed unicode")]
    [InlineData("with\nnewlines\tand\ttabs")]
    [InlineData("\"quotes\" and \\backslashes\\ and %percent%")]
    public void AwkwardValuesRoundTrip(string value)
    {
        var key = Key("awkward");
        _store.Set(key, value);
        Assert.Equal(value, _store.Get(key));
    }

    [Fact]
    public void LargeValueRoundTrips()
    {
        var key = Key("large");
        var value = new string('x', 8192);
        _store.Set(key, value);
        Assert.Equal(value, _store.Get(key));
    }

    [Fact]
    public void EmptyStringIsDistinctFromAbsent()
    {
        var key = Key("empty");
        _store.Set(key, "");
        Assert.Equal("", _store.Get(key));
    }

    [Fact]
    public void KeysDoNotCollideAcrossServers()
    {
        // Server ids contain a URL, so they are full of characters a filename
        // cannot hold. Sanitizing must not map two different servers onto one.
        var a = Key("token.subsonic-https://music.example.com");
        var b = Key("token.subsonic-https://music.example.org");
        _store.Set(a, "alpha");
        _store.Set(b, "bravo");
        Assert.Equal("alpha", _store.Get(a));
        Assert.Equal("bravo", _store.Get(b));
    }

    [Fact]
    public void SupportDirectoryExists()
    {
        Assert.True(Directory.Exists(AppPaths.SupportDirectory));
    }

    [Fact]
    public void LibraryPathHonoursTheEnvironmentOverride()
    {
        var original = Environment.GetEnvironmentVariable("MOZZ_LIBRARY");
        try
        {
            var custom = Path.Combine(Directory.GetCurrentDirectory(), "custom-library.sqlite");
            Environment.SetEnvironmentVariable("MOZZ_LIBRARY", custom);
            Assert.Equal(custom, AppPaths.LibraryPath);

            Environment.SetEnvironmentVariable("MOZZ_LIBRARY", null);
            Assert.EndsWith("library.sqlite", AppPaths.LibraryPath);
            Assert.StartsWith(AppPaths.SupportDirectory, AppPaths.LibraryPath);
        }
        finally
        {
            Environment.SetEnvironmentVariable("MOZZ_LIBRARY", original);
        }
    }
}
