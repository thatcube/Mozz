using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;
using System.Xml.Linq;

namespace Mozz.Desktop.Core;

/// <summary>
/// Where a server auth token lives when the app is not running.
///
/// The Swift core deliberately does not do this. Secret storage is one of the
/// few genuinely irreducible platform differences — Windows has DPAPI keyed to
/// the logged-in user, macOS has the Keychain, Linux has libsecret — and a
/// "portable" store would be the worst of all of them: either a file we pretend
/// is safe, or four conditional branches calling four native APIs from a
/// language that has to compile on all of them. The host already links these
/// APIs. So the core returns a token from <c>connect</c> and forgets it, and
/// this is the only place in the app that knows how the platform keeps it.
/// </summary>
public interface ISecretStore
{
    string? Get(string key);
    void Set(string key, string? value);

    /// <summary>
    /// Human-readable description of where secrets are going, for the settings
    /// screen. A user who self-hosts their music generally does want to know.
    /// </summary>
    string Description { get; }
}

public static class SecretStore
{
    public static ISecretStore ForCurrentPlatform()
    {
        if (OperatingSystem.IsWindows()) return new WindowsSecretStore();
        if (OperatingSystem.IsMacOS()) return new MacKeychainSecretStore();
        return new FileSecretStore();
    }
}

/// <summary>
/// DPAPI. <c>CryptProtectData</c> encrypts with a key derived from the logged-in
/// Windows account, so the ciphertext is useless to another user on the same
/// machine and useless on a different machine — which is the property we want,
/// and is what the OS itself uses for stored credentials.
///
/// P/Invoked directly rather than through
/// <c>System.Security.Cryptography.ProtectedData</c> to avoid a NuGet dependency
/// that exists only to wrap these two functions.
/// </summary>
[SupportedOSPlatform("windows")]
internal sealed class WindowsSecretStore : ISecretStore
{
    public string Description => "Windows Credential encryption (DPAPI), tied to your Windows account";

    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob
    {
        public int cbData;
        public nint pbData;
    }

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptProtectData(
        ref DataBlob input, string? description, nint entropy, nint reserved,
        nint prompt, int flags, out DataBlob output);

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(
        ref DataBlob input, nint description, nint entropy, nint reserved,
        nint prompt, int flags, out DataBlob output);

    [DllImport("kernel32.dll")]
    private static extern nint LocalFree(nint handle);

    private const int CryptProtectUiForbidden = 0x1;

    private static string StorePath =>
        Path.Combine(AppPaths.SupportDirectory, "credentials");

    public string? Get(string key)
    {
        var path = Path.Combine(StorePath, Sanitize(key));
        if (!File.Exists(path)) return null;

        var cipher = File.ReadAllBytes(path);
        var handle = GCHandle.Alloc(cipher, GCHandleType.Pinned);
        try
        {
            var input = new DataBlob { cbData = cipher.Length, pbData = handle.AddrOfPinnedObject() };
            if (!CryptUnprotectData(ref input, 0, 0, 0, 0, CryptProtectUiForbidden, out var output))
            {
                // Most often this means the file was written by a different
                // Windows account, or copied from another machine. Deleting is
                // wrong (it may be recoverable by the right user); reporting
                // "not signed in" and letting them sign in again is right.
                return null;
            }
            try
            {
                // DPAPI can return a zero-length, null-pointer blob for an empty
                // value, which Marshal.Copy rejects; empty is still stored.
                if (output.cbData == 0 || output.pbData == 0) return string.Empty;
                var plain = new byte[output.cbData];
                Marshal.Copy(output.pbData, plain, 0, output.cbData);
                var text = Encoding.UTF8.GetString(plain);
                Array.Clear(plain);
                return text;
            }
            finally
            {
                LocalFree(output.pbData);
            }
        }
        finally
        {
            handle.Free();
        }
    }

    public void Set(string key, string? value)
    {
        Directory.CreateDirectory(StorePath);
        var path = Path.Combine(StorePath, Sanitize(key));
        if (value is null)
        {
            if (File.Exists(path)) File.Delete(path);
            return;
        }

        // An empty array pins to a null pointer, which CryptProtectData rejects.
        var plain = value.Length == 0 ? new byte[] { 0 } : Encoding.UTF8.GetBytes(value);
        var payloadLength = value.Length == 0 ? 0 : plain.Length;
        var handle = GCHandle.Alloc(plain, GCHandleType.Pinned);
        try
        {
            var input = new DataBlob { cbData = payloadLength, pbData = handle.AddrOfPinnedObject() };
            if (!CryptProtectData(ref input, "Mozz server credential", 0, 0, 0, CryptProtectUiForbidden, out var output))
            {
                throw new InvalidOperationException(
                    $"DPAPI could not encrypt the credential (error {Marshal.GetLastWin32Error()})");
            }
            try
            {
                var cipher = new byte[output.cbData];
                Marshal.Copy(output.pbData, cipher, 0, output.cbData);
                File.WriteAllBytes(path, cipher);
            }
            finally
            {
                LocalFree(output.pbData);
            }
        }
        finally
        {
            Array.Clear(plain);
            handle.Free();
        }
    }

    private static string Sanitize(string key) =>
        string.Concat(key.Select(c => char.IsLetterOrDigit(c) || c is '-' or '.' ? c : '_'));
}

/// <summary>
/// The macOS Keychain, through Security.framework's generic-password items.
///
/// Generic passwords rather than internet passwords: the account and server are
/// Mozz's own concepts and a Keychain "internet password" would invite Safari
/// and other apps to offer to fill it, which is not what this is.
/// </summary>
[SupportedOSPlatform("macos")]
internal sealed class MacKeychainSecretStore : ISecretStore
{
    public string Description => _allowLocalFileFallback
        ? "macOS local development credential file — not encrypted at rest; release builds use the Keychain"
        : "macOS Keychain";

    private const string Security = "/System/Library/Frameworks/Security.framework/Security";
    private const string CoreFoundation =
        "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation";

    private const int ErrSecSuccess = 0;
    private const int ErrSecItemNotFound = -25300;
    private const int ErrSecDuplicateItem = -25299;
    private const int ErrSecMissingEntitlement = -34018;

    [DllImport(Security)] private static extern int SecItemAdd(nint query, nint result);
    [DllImport(Security)] private static extern int SecItemCopyMatching(nint query, out nint result);
    [DllImport(Security)] private static extern int SecItemDelete(nint query);
    [DllImport(Security)] private static extern int SecItemUpdate(nint query, nint attributesToUpdate);

    [DllImport(CoreFoundation)]
    private static extern nint CFStringCreateWithCString(nint alloc, byte[] cStr, uint encoding);
    [DllImport(CoreFoundation)]
    private static extern nint CFDataCreate(nint alloc, byte[] bytes, nint length);
    [DllImport(CoreFoundation)]
    private static extern nint CFDictionaryCreateMutable(nint alloc, nint capacity, nint keyCb, nint valueCb);
    [DllImport(CoreFoundation)]
    private static extern void CFDictionarySetValue(nint dict, nint key, nint value);
    [DllImport(CoreFoundation)]
    private static extern void CFRelease(nint cf);
    [DllImport(CoreFoundation)]
    private static extern nint CFDataGetBytePtr(nint data);
    [DllImport(CoreFoundation)]
    private static extern nint CFDataGetLength(nint data);

    private const uint Utf8 = 0x08000100;

    // Security.framework exports its dictionary keys as CFStringRef globals.
    private static nint Constant(string name)
    {
        var handle = NativeLibrary.Load(Security);
        return Marshal.ReadIntPtr(NativeLibrary.GetExport(handle, name));
    }

    private static readonly nint SecClass = Constant("kSecClass");
    private static readonly nint SecClassGenericPassword = Constant("kSecClassGenericPassword");
    private static readonly nint SecAttrService = Constant("kSecAttrService");
    private static readonly nint SecAttrAccount = Constant("kSecAttrAccount");
    private static readonly nint SecValueData = Constant("kSecValueData");
    private static readonly nint SecReturnData = Constant("kSecReturnData");
    private static readonly nint SecMatchLimit = Constant("kSecMatchLimit");
    private static readonly nint SecMatchLimitOne = Constant("kSecMatchLimitOne");
    private static readonly nint SecUseDataProtectionKeychain = Constant("kSecUseDataProtectionKeychain");
    private static readonly nint CFBooleanTrue = Marshal.ReadIntPtr(
        NativeLibrary.GetExport(NativeLibrary.Load(CoreFoundation), "kCFBooleanTrue"));

    /// <summary>
    /// The Keychain service these items live under.
    ///
    /// Deliberately the desktop app's own identifier rather than the iOS app's.
    /// They are different apps with different signatures, so sharing a service
    /// name buys nothing — macOS would still prompt — while making the access
    /// dialog name a bundle the user may not even have installed.
    /// </summary>
    private const string DefaultServiceName = "com.thatcube.Mozz.desktop";
    private readonly string _serviceName;
    private readonly bool _requireDataProtectionKeychain;
    private readonly bool _allowLocalFileFallback;
    private readonly FileSecretStore _fileFallback;
    private bool _dataProtectionUnavailable;

    public MacKeychainSecretStore() : this(DefaultServiceName, allowLocalFileFallback: IsLocalDevelopmentBundle()) { }

    internal MacKeychainSecretStore(
        string serviceName,
        bool requireDataProtectionKeychain = false,
        bool allowLocalFileFallback = false,
        string? fileFallbackDirectory = null)
    {
        _serviceName = serviceName;
        _requireDataProtectionKeychain = requireDataProtectionKeychain;
        _allowLocalFileFallback = allowLocalFileFallback;
        _fileFallback = new FileSecretStore(fileFallbackDirectory);
    }

    internal static bool CanUseDataProtectionKeychainForTests()
    {
        var store = new MacKeychainSecretStore($"com.thatcube.Mozz.desktop.probe.{Guid.NewGuid():N}", true);
        try
        {
            store.Set("probe", "ok", dataProtectionKeychain: true);
            store.Delete("probe", dataProtectionKeychain: true);
            return true;
        }
        catch (InvalidOperationException ex)
            when (ex.Message.Contains($"OSStatus {ErrSecMissingEntitlement}", StringComparison.Ordinal))
        {
            return false;
        }
    }

    internal static bool IsLocalDevelopmentBundle()
    {
        var processPath = Environment.ProcessPath;
        if (string.IsNullOrEmpty(processPath)) return false;

        var macOsMarker = $"{Path.DirectorySeparatorChar}Contents{Path.DirectorySeparatorChar}MacOS{Path.DirectorySeparatorChar}";
        var markerIndex = processPath.IndexOf(macOsMarker, StringComparison.Ordinal);
        if (markerIndex < 0) return false;

        var plistPath = Path.Combine(processPath[..markerIndex], "Contents", "Info.plist");
        try
        {
            var root = XDocument.Load(plistPath).Root?.Element("dict");
            if (root is null) return false;

            var elements = root.Elements().ToList();
            for (var i = 0; i < elements.Count - 1; i++)
            {
                if (elements[i].Name.LocalName == "key"
                    && elements[i].Value == "MozzLocalDevelopmentBuild")
                {
                    return elements[i + 1].Name.LocalName == "true";
                }
            }
        }
        catch
        {
            return false;
        }

        return false;
    }

    private static nint CFString(string value)
        => CFStringCreateWithCString(0, Encoding.UTF8.GetBytes(value + "\0"), Utf8);

    private nint BaseQuery(string key, List<nint> owned, bool dataProtectionKeychain)
    {
        var dict = CFDictionaryCreateMutable(0, 0, 0, 0);
        var service = CFString(_serviceName);
        var account = CFString(key);
        owned.Add(service);
        owned.Add(account);
        CFDictionarySetValue(dict, SecClass, SecClassGenericPassword);
        CFDictionarySetValue(dict, SecAttrService, service);
        CFDictionarySetValue(dict, SecAttrAccount, account);
        if (dataProtectionKeychain)
        {
            CFDictionarySetValue(dict, SecUseDataProtectionKeychain, CFBooleanTrue);
        }
        return dict;
    }

    public string? Get(string key)
    {
        if (!_dataProtectionUnavailable)
        {
            try
            {
                var protectedValue = Get(key, dataProtectionKeychain: true);
                if (protectedValue is not null) return protectedValue;
            }
            catch (InvalidOperationException ex) when (CanContinueAfterUnavailableDataProtection(ex))
            {
                _dataProtectionUnavailable = true;
            }
        }

        if (_allowLocalFileFallback && _fileFallback.Get(key) is { } fileValue) return fileValue;

        var value = Get(key, dataProtectionKeychain: false);
        if (value is null) return null;

        if (_dataProtectionUnavailable && _allowLocalFileFallback)
        {
            _fileFallback.Set(key, value);
            Delete(key, dataProtectionKeychain: false);
            return value;
        }

        try
        {
            Set(key, value, dataProtectionKeychain: true);
            Delete(key, dataProtectionKeychain: false);
        }
        catch (InvalidOperationException ex) when (CanContinueAfterUnavailableDataProtection(ex))
        {
            _dataProtectionUnavailable = true;
            if (_allowLocalFileFallback)
            {
                _fileFallback.Set(key, value);
                Delete(key, dataProtectionKeychain: false);
            }
        }
        return value;
    }

    private string? Get(string key, bool dataProtectionKeychain)
    {
        var owned = new List<nint>();
        var query = BaseQuery(key, owned, dataProtectionKeychain);
        owned.Add(query);
        try
        {
            CFDictionarySetValue(query, SecReturnData, CFBooleanTrue);
            CFDictionarySetValue(query, SecMatchLimit, SecMatchLimitOne);

            var status = SecItemCopyMatching(query, out var result);
            if (status == ErrSecItemNotFound) return null;
            if (status != ErrSecSuccess)
            {
                throw KeychainException("read", status);
            }
            try
            {
                var length = (int)CFDataGetLength(result);
                // A zero-length CFData reports a null byte pointer, which
                // Marshal.Copy rejects. An empty stored value is still a stored
                // value and must not be confused with an absent one.
                if (length == 0) return string.Empty;
                var bytes = new byte[length];
                Marshal.Copy(CFDataGetBytePtr(result), bytes, 0, length);
                var text = Encoding.UTF8.GetString(bytes);
                Array.Clear(bytes);
                return text;
            }
            finally
            {
                CFRelease(result);
            }
        }
        finally
        {
            foreach (var handle in owned) CFRelease(handle);
        }
    }

    public void Set(string key, string? value)
    {
        if (!_dataProtectionUnavailable)
        {
            try
            {
                if (value is null)
                {
                    Delete(key, dataProtectionKeychain: true);
                    Delete(key, dataProtectionKeychain: false);
                    _fileFallback.Set(key, null);
                    return;
                }

                Set(key, value, dataProtectionKeychain: true);
                Delete(key, dataProtectionKeychain: false);
                _fileFallback.Set(key, null);
                return;
            }
            catch (InvalidOperationException ex) when (CanContinueAfterUnavailableDataProtection(ex))
            {
                _dataProtectionUnavailable = true;
            }
        }

        if (_allowLocalFileFallback)
        {
            _fileFallback.Set(key, value);
            Delete(key, dataProtectionKeychain: false);
            return;
        }

        if (value is null) Delete(key, dataProtectionKeychain: false);
        else Set(key, value, dataProtectionKeychain: false);
    }

    internal void SetLegacyForMigrationTest(string key, string? value)
    {
        if (value is null) Delete(key, dataProtectionKeychain: false);
        else Set(key, value, dataProtectionKeychain: false);
    }

    internal string? GetLegacyForMigrationTest(string key)
        => Get(key, dataProtectionKeychain: false);

    private void Delete(string key, bool dataProtectionKeychain)
    {
        var owned = new List<nint>();
        var query = BaseQuery(key, owned, dataProtectionKeychain);
        owned.Add(query);
        try
        {
            var deleted = SecItemDelete(query);
            if (deleted != ErrSecSuccess && deleted != ErrSecItemNotFound)
            {
                throw KeychainException("delete", deleted);
            }
        }
        finally
        {
            foreach (var handle in owned) CFRelease(handle);
        }
    }

    private void Set(string key, string value, bool dataProtectionKeychain)
    {
        var owned = new List<nint>();
        var query = BaseQuery(key, owned, dataProtectionKeychain);
        owned.Add(query);
        try
        {
            var bytes = Encoding.UTF8.GetBytes(value);
            var data = CFDataCreate(0, bytes, bytes.Length);
            owned.Add(data);

            CFDictionarySetValue(query, SecValueData, data);
            var status = SecItemAdd(query, 0);

            if (status == ErrSecDuplicateItem)
            {
                // An add on an existing item fails rather than replacing, so
                // signing in again to the same server has to update instead.
                var updateOwned = new List<nint>();
                var findQuery = BaseQuery(key, updateOwned, dataProtectionKeychain);
                updateOwned.Add(findQuery);
                var attributes = CFDictionaryCreateMutable(0, 0, 0, 0);
                updateOwned.Add(attributes);
                CFDictionarySetValue(attributes, SecValueData, data);
                try
                {
                    status = SecItemUpdate(findQuery, attributes);
                }
                finally
                {
                    foreach (var handle in updateOwned) CFRelease(handle);
                }
            }

            Array.Clear(bytes);
            if (status != ErrSecSuccess)
            {
                throw KeychainException("write", status);
            }
        }
        finally
        {
            foreach (var handle in owned) CFRelease(handle);
        }
    }

    private bool CanContinueAfterUnavailableDataProtection(InvalidOperationException ex) =>
        !_requireDataProtectionKeychain && ex.Message.Contains($"OSStatus {ErrSecMissingEntitlement}", StringComparison.Ordinal);

    private static InvalidOperationException KeychainException(string operation, int status)
    {
        var suffix = status == ErrSecMissingEntitlement
            ? "; the macOS Data Protection Keychain requires the app to be signed with a keychain-access-groups entitlement"
            : "";
        return new InvalidOperationException($"Keychain {operation} failed (OSStatus {status}{suffix})");
    }
}

/// <summary>
/// The fallback, used on Linux and anywhere else.
///
/// This is NOT encrypted at rest — it is a file with owner-only permissions,
/// which is the same protection an SSH private key gets by default and no more.
/// libsecret would be better where a desktop session is running it, but it is
/// absent on headless systems and in containers, and a store that throws on
/// those is worse than one that is honest about its limits. <see cref="Description"/>
/// says so plainly so the settings screen can too.
/// </summary>
internal sealed class FileSecretStore : ISecretStore
{
    public string Description =>
        $"a file readable only by your user account ({Directory}) — not encrypted at rest";

    /// <summary>
    /// Where the credential files live. Injectable so a test can be pointed at
    /// a scratch directory.
    /// </summary>
    /// <remarks>
    /// A constructor parameter rather than an environment variable, because the
    /// test runner parallelises test classes and an environment variable is
    /// process-global: one class tearing it down would pull it out from under
    /// another. It needs to be injectable at all because these tests were
    /// writing into the real credential directory, beside a live install's
    /// actual token.
    /// </remarks>
    private readonly string _directory;

    public FileSecretStore(string? directory = null) =>
        _directory = directory ?? Path.Combine(AppPaths.SupportDirectory, "credentials");

    private string Directory => _directory;

    public string? Get(string key)
    {
        var path = Path.Combine(Directory, Sanitize(key));
        return File.Exists(path) ? File.ReadAllText(path) : null;
    }

    public void Set(string key, string? value)
    {
        System.IO.Directory.CreateDirectory(Directory);
        var path = Path.Combine(Directory, Sanitize(key));
        if (value is null)
        {
            if (File.Exists(path)) File.Delete(path);
            return;
        }

        File.WriteAllText(path, value);
        if (!OperatingSystem.IsWindows())
        {
            File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
            System.IO.Directory.CreateDirectory(Directory);
            File.SetUnixFileMode(Directory,
                UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        }
    }

    private static string Sanitize(string key) =>
        string.Concat(key.Select(c => char.IsLetterOrDigit(c) || c is '-' or '.' ? c : '_'));
}

/// <summary>Where Mozz keeps its library and settings on each platform.</summary>
public static class AppPaths
{
    /// <summary>
    /// Per-user application support. <c>%LOCALAPPDATA%\Mozz</c> on Windows,
    /// <c>~/Library/Application Support/Mozz</c> on macOS, and
    /// <c>$XDG_DATA_HOME/Mozz</c> (or <c>~/.local/share/Mozz</c>) on Linux —
    /// which is what <c>SpecialFolder.LocalApplicationData</c> resolves to on
    /// each.
    /// </summary>
    public static string SupportDirectory
    {
        get
        {
            var overridePath = Environment.GetEnvironmentVariable("MOZZ_SUPPORT_DIR");
            if (!string.IsNullOrWhiteSpace(overridePath))
            {
                Directory.CreateDirectory(overridePath);
                return overridePath;
            }

            var root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            var path = Path.Combine(root, "Mozz");
            Directory.CreateDirectory(path);
            return path;
        }
    }

    /// <summary>
    /// The library database. <c>MOZZ_LIBRARY</c> overrides it, which is how the
    /// development seed database is used without disturbing a real one.
    /// </summary>
    public static string LibraryPath =>
        Environment.GetEnvironmentVariable("MOZZ_LIBRARY") is { Length: > 0 } custom
            ? custom
            : Path.Combine(SupportDirectory, "library.sqlite");
}
