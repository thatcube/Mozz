using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace Mozz.Desktop.Audio.Platform;

/// <summary>
/// macOS "now playing": the card in Control Center and the media-key overlay,
/// via <c>MPNowPlayingInfoCenter</c> in MediaPlayer.framework.
///
/// WHY THIS IS OBJECTIVE-C RUNTIME INTEROP
///
/// MediaPlayer has no C API and no managed binding for .NET on macOS. The
/// framework is reached the way every non-Objective-C caller reaches it: load
/// the dylib, look classes up by name, register selectors, and send messages.
/// It is verbose but it is not clever — every call below is one
/// <c>objc_msgSend</c> with an explicitly typed signature, because P/Invoke
/// cannot express a variadic one.
///
/// EVERY STEP IS ALLOWED TO FAIL
///
/// A missing framework, a renamed class or a selector that no longer exists
/// must degrade to doing nothing, never to taking the app down — this is a
/// cosmetic surface, and a music player that crashes because it could not draw
/// a card in Control Center would be an absurd trade. <see cref="IsAvailable"/>
/// reports whether the lookups succeeded, and every method is a no-op when they
/// did not.
///
/// WHAT IS NOT HERE
///
/// Media *keys*. Those need <c>MPRemoteCommandCenter</c>, whose API takes
/// Objective-C blocks — a struct with an isa pointer, flags and a function
/// pointer, which is a materially different and riskier piece of interop than
/// message sending. The transport events on <see cref="INowPlayingIntegration"/>
/// are declared and never raised here, so wiring that in later changes this file
/// and nothing else.
/// </summary>
[SupportedOSPlatform("macos")]
internal sealed class MacNowPlayingIntegration : INowPlayingIntegration
{
    private const string Objc = "/usr/lib/libobjc.A.dylib";
    private const string Foundation =
        "/System/Library/Frameworks/Foundation.framework/Foundation";
    private const string MediaPlayerPath =
        "/System/Library/Frameworks/MediaPlayer.framework/MediaPlayer";

    [DllImport(Objc, EntryPoint = "objc_getClass")]
    private static extern nint GetClass([MarshalAs(UnmanagedType.LPStr)] string name);

    [DllImport(Objc, EntryPoint = "sel_registerName")]
    private static extern nint Selector([MarshalAs(UnmanagedType.LPStr)] string name);

    [DllImport(Objc, EntryPoint = "objc_msgSend")]
    private static extern nint Send(nint receiver, nint selector);

    [DllImport(Objc, EntryPoint = "objc_msgSend")]
    private static extern nint Send(nint receiver, nint selector, nint a1);

    [DllImport(Objc, EntryPoint = "objc_msgSend")]
    private static extern nint Send(nint receiver, nint selector, nint a1, nint a2);

    [DllImport(Objc, EntryPoint = "objc_msgSend")]
    private static extern nint SendDouble(nint receiver, nint selector, double value);

    [DllImport(Objc, EntryPoint = "objc_msgSend")]
    private static extern nint SendLong(nint receiver, nint selector, long value);

    [DllImport(Objc, EntryPoint = "objc_msgSend")]
    private static extern void SendVoidLong(nint receiver, nint selector, long value);

    [DllImport(Objc, EntryPoint = "objc_msgSend")]
    private static extern nint SendUtf8(
        nint receiver, nint selector, [MarshalAs(UnmanagedType.LPUTF8Str)] string value);

    // MPNowPlayingPlaybackState
    private const long StatePlaying = 1;
    private const long StatePaused = 2;
    private const long StateStopped = 3;

    private readonly nint _center;
    private readonly nint _nsString;
    private readonly nint _nsNumber;
    private readonly nint _nsDictionary;

    private readonly nint _selStringWithUTF8;
    private readonly nint _selNumberWithDouble;
    private readonly nint _selDictionary;
    private readonly nint _selSetObjectForKey;
    private readonly nint _selSetNowPlayingInfo;
    private readonly nint _selSetPlaybackState;

    // Keys are CFStringRef globals exported by the framework.
    private readonly nint _keyTitle;
    private readonly nint _keyArtist;
    private readonly nint _keyAlbum;
    private readonly nint _keyDuration;
    private readonly nint _keyElapsed;
    private readonly nint _keyRate;

    public bool IsAvailable { get; }

    public MacNowPlayingIntegration()
    {
        try
        {
            if (!NativeLibrary.TryLoad(MediaPlayerPath, out var mediaPlayer)) return;
            if (!NativeLibrary.TryLoad(Foundation, out _)) return;

            var centerClass = GetClass("MPNowPlayingInfoCenter");
            _nsString = GetClass("NSString");
            _nsNumber = GetClass("NSNumber");
            _nsDictionary = GetClass("NSMutableDictionary");
            if (centerClass == 0 || _nsString == 0 || _nsNumber == 0 || _nsDictionary == 0) return;

            _center = Send(centerClass, Selector("defaultCenter"));
            if (_center == 0) return;

            _selStringWithUTF8 = Selector("stringWithUTF8String:");
            _selNumberWithDouble = Selector("numberWithDouble:");
            _selDictionary = Selector("dictionary");
            _selSetObjectForKey = Selector("setObject:forKey:");
            _selSetNowPlayingInfo = Selector("setNowPlayingInfo:");
            _selSetPlaybackState = Selector("setPlaybackState:");

            _keyTitle = ReadGlobal(mediaPlayer, "MPMediaItemPropertyTitle");
            _keyArtist = ReadGlobal(mediaPlayer, "MPMediaItemPropertyArtist");
            _keyAlbum = ReadGlobal(mediaPlayer, "MPMediaItemPropertyAlbumTitle");
            _keyDuration = ReadGlobal(mediaPlayer, "MPMediaItemPropertyPlaybackDuration");
            _keyElapsed = ReadGlobal(mediaPlayer, "MPNowPlayingInfoPropertyElapsedPlaybackTime");
            _keyRate = ReadGlobal(mediaPlayer, "MPNowPlayingInfoPropertyPlaybackRate");

            IsAvailable = _keyTitle != 0 && _keyArtist != 0 && _keyDuration != 0;
        }
        catch (DllNotFoundException) { /* not macOS, or a stripped system */ }
        catch (EntryPointNotFoundException) { /* runtime shape changed */ }
    }

    /// <summary>Dereference an exported CFStringRef global.</summary>
    private static nint ReadGlobal(nint library, string symbol)
        => NativeLibrary.TryGetExport(library, symbol, out var address)
            ? Marshal.ReadIntPtr(address)
            : 0;

    private nint NsString(string value)
        => SendUtf8(_nsString, _selStringWithUTF8, value);

    private nint NsNumber(double value)
        => SendDouble(_nsNumber, _selNumberWithDouble, value);

    private void Put(nint dictionary, nint key, nint value)
    {
        if (key == 0 || value == 0) return;
        Send(dictionary, _selSetObjectForKey, value, key);
    }

    // Retained so a position update can refresh elapsed time without the caller
    // having to resend the whole record.
    private NowPlayingMetadata? _current;
    private PlaybackState _state = PlaybackState.Stopped;

    public void UpdateMetadata(NowPlayingMetadata metadata)
    {
        _current = metadata;
        if (!IsAvailable) return;
        Publish(metadata, TimeSpan.Zero);
    }

    public void UpdateState(PlaybackState state)
    {
        _state = state;
        if (!IsAvailable) return;

        SendVoidLong(_center, _selSetPlaybackState, state switch
        {
            PlaybackState.Playing => StatePlaying,
            PlaybackState.Paused => StatePaused,
            _ => StateStopped,
        });
    }

    public void UpdatePosition(TimeSpan position, TimeSpan duration)
    {
        if (!IsAvailable || _current is null) return;
        // The card interpolates from elapsed time and rate rather than being
        // driven at frame rate, so this only needs to correct drift — the view
        // model calls it about once a second, not at its 10 Hz tick.
        Publish(_current with { Duration = duration }, position);
    }

    private void Publish(NowPlayingMetadata metadata, TimeSpan elapsed)
    {
        var info = Send(_nsDictionary, _selDictionary);
        if (info == 0) return;

        Put(info, _keyTitle, NsString(metadata.Title));
        Put(info, _keyArtist, NsString(metadata.Artist));
        if (metadata.Album is { Length: > 0 } album) Put(info, _keyAlbum, NsString(album));
        Put(info, _keyDuration, NsNumber(metadata.Duration.TotalSeconds));
        Put(info, _keyElapsed, NsNumber(elapsed.TotalSeconds));
        Put(info, _keyRate, NsNumber(_state == PlaybackState.Playing ? 1.0 : 0.0));

        Send(_center, _selSetNowPlayingInfo, info);
    }

    /// <summary>
    /// Read the title back out of the info centre. Exists so the interop can be
    /// tested for real rather than assumed — every call above returns void or an
    /// object nobody inspects, so without a readback a completely broken
    /// implementation looks identical to a working one.
    /// </summary>
    internal string? DebugReadTitle()
    {
        if (!IsAvailable) return null;
        var info = Send(_center, Selector("nowPlayingInfo"));
        if (info == 0) return null;
        var value = Send(info, Selector("objectForKey:"), _keyTitle);
        if (value == 0) return null;
        var utf8 = Send(value, Selector("UTF8String"));
        return utf8 == 0 ? null : Marshal.PtrToStringUTF8(utf8);
    }

    public event EventHandler? PlayPauseRequested { add { } remove { } }
    public event EventHandler? NextRequested { add { } remove { } }
    public event EventHandler? PreviousRequested { add { } remove { } }
    public event EventHandler? StopRequested { add { } remove { } }

    public void Dispose()
    {
        if (!IsAvailable) return;
        // Clear the card rather than leaving a stopped track sitting in Control
        // Center after the app is gone.
        Send(_center, _selSetNowPlayingInfo, 0);
        SendVoidLong(_center, _selSetPlaybackState, StateStopped);
    }
}
