using Avalonia.Input.Platform;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Mozz.Desktop.Core;

namespace Mozz.Desktop.ViewModels;

/// <summary>
/// Signing in to a music server, and mirroring its catalog.
///
/// Kept apart from <see cref="MainViewModel"/> because it is a different job
/// with a different lifetime: this runs once, at the start, and then usually
/// never again. Folding it into the browsing view model would put a sign-in
/// state machine — three backends, one of them an out-of-band PIN poll — inside
/// the thing that has to stay responsive while paging a hundred thousand tracks.
/// </summary>
public sealed partial class ConnectViewModel : ViewModelBase
{
    private readonly MozzServer _server;
    private readonly Func<Task> _onLibraryChanged;
    private CancellationTokenSource? _plexPoll;

    public ConnectViewModel(MozzServer server, Func<Task> onLibraryChanged)
    {
        _server = server;
        _onLibraryChanged = onLibraryChanged;
        Accounts = new(server.SavedAccounts());
    }

    public System.Collections.ObjectModel.ObservableCollection<ServerAccount> Accounts { get; }

    [ObservableProperty] private BackendKind _kind = BackendKind.Jellyfin;
    [ObservableProperty] private string _serverUrl = string.Empty;
    [ObservableProperty] private string _username = string.Empty;
    [ObservableProperty] private string _password = string.Empty;

    [ObservableProperty] private bool _isBusy;
    [ObservableProperty] private string? _message;
    [ObservableProperty] private bool _isSyncing;
    [ObservableProperty] private double _syncProgress;
    [ObservableProperty] private string? _syncDetail;

    /// <summary>Plex's link code, shown while its PIN flow is in progress.</summary>
    [ObservableProperty] private string? _plexCode;
    [ObservableProperty] private string? _plexLinkUrl;

    public bool IsPlex => Kind == BackendKind.Plex;
    public bool NeedsCredentials => Kind != BackendKind.Plex;
    public bool HasAccounts => Accounts.Count > 0;

    partial void OnKindChanged(BackendKind value)
    {
        CancelPlexPoll();
        Message = null;
        OnPropertyChanged(nameof(IsPlex));
        OnPropertyChanged(nameof(NeedsCredentials));
    }

    // MARK: Sign in

    [RelayCommand]
    private async Task SignInAsync()
    {
        if (IsBusy) return;
        Message = null;

        if (Kind == BackendKind.Plex)
        {
            await BeginPlexAsync();
            return;
        }

        var url = NormalizeUrl(ServerUrl);
        if (url is null)
        {
            Message = "That does not look like a server address. Try http://192.168.1.10:8096";
            return;
        }
        if (string.IsNullOrWhiteSpace(Username))
        {
            Message = "A username is required.";
            return;
        }

        try
        {
            IsBusy = true;
            Message = "Signing in…";
            var account = await _server.ConnectAsync(Kind, url, Username.Trim(), Password);
            Password = string.Empty;   // never keep it in memory past the exchange
            await AfterSignInAsync(account);
        }
        catch (Exception ex)
        {
            Message = Explain(ex);
        }
        finally
        {
            IsBusy = false;
        }
    }

    private async Task BeginPlexAsync()
    {
        try
        {
            IsBusy = true;
            Message = "Asking Plex for a link code…";
            var link = await _server.BeginPlexLinkAsync();
            PlexCode = link.Code;
            PlexLinkUrl = link.LinkUrl;
            Message = "Waiting for you to approve Mozz on plex.tv…";

            CancelPlexPoll();
            _plexPoll = new CancellationTokenSource();
            var token = _plexPoll.Token;

            // Plex's PIN expires; polling forever would keep a dead request warm
            // and leave the user staring at a code that can no longer work.
            var deadline = DateTime.UtcNow.AddMinutes(5);
            while (!token.IsCancellationRequested && DateTime.UtcNow < deadline)
            {
                await Task.Delay(TimeSpan.FromSeconds(2), token);
                var account = await _server.PollPlexLinkAsync(link, token);
                if (account is null) continue;

                PlexCode = null;
                PlexLinkUrl = null;
                await AfterSignInAsync(account);
                return;
            }
            if (!token.IsCancellationRequested)
            {
                PlexCode = null;
                PlexLinkUrl = null;
                Message = "That link code expired. Try again.";
            }
        }
        catch (OperationCanceledException)
        {
            // The user changed their mind; nothing to report.
        }
        catch (Exception ex)
        {
            Message = Explain(ex);
        }
        finally
        {
            IsBusy = false;
        }
    }

    private async Task AfterSignInAsync(ServerAccount account)
    {
        Message = $"Connected to {account.ServerName}.";

        // Resolves and saves the Plex music section, so read the accounts back
        // only after it has run — otherwise the list shows the unresolved one.
        var prepared = await _server.AttachForSyncAsync(account);

        Accounts.Clear();
        foreach (var saved in _server.SavedAccounts()) Accounts.Add(saved);
        OnPropertyChanged(nameof(HasAccounts));

        await SyncAsync(prepared);
    }

    /// <summary>
    /// Hand the core the credentials for every saved account, at launch.
    ///
    /// The library is on disk, so a relaunch shows it without touching the
    /// network — but playing any of it needs a stream URL, and the core resolves
    /// one only against an ATTACHED backend. Without this the app came back up
    /// looking fine and then refused to play anything ("No audio source for this
    /// track yet") until the user happened to visit Servers and press Sync.
    /// </summary>
    public async Task AttachSavedAccountsAsync()
    {
        foreach (var account in _server.SavedAccounts())
        {
            try
            {
                await _server.AttachAsync(account);
            }
            catch (Exception ex)
            {
                // A server that has been signed out of, or whose credential no
                // longer decrypts, must not stop the others being attached — and
                // must not stop the app from opening.
                Message = Explain(ex);
            }
        }
    }

    // MARK: Sync

    [RelayCommand]
    private async Task SyncAccountAsync(ServerAccount account)
    {
        try
        {
            var prepared = await _server.AttachForSyncAsync(account);
            await SyncAsync(prepared);
        }
        catch (Exception ex)
        {
            Message = Explain(ex);
        }
    }

    private async Task SyncAsync(ServerAccount account)
    {
        IsSyncing = true;
        SyncProgress = 0;
        SyncDetail = "Starting…";
        try
        {
            var progress = new Progress<SyncStatus>(status =>
            {
                SyncDetail = status.Describe();
                // Only a fraction when the server told us a total; otherwise the
                // bar stays indeterminate rather than inventing a position.
                SyncProgress = status.Total is > 0
                    ? Math.Min(1.0, (double)status.ItemsSynced / status.Total.Value)
                    : 0;
            });

            var final = await _server.SyncAsync(account.ServerId, progress);
            SyncDetail = $"{final.Tracks:N0} songs · {final.Albums:N0} albums · {final.Artists:N0} artists";
            Message = $"{account.ServerName} is ready.";
            await _onLibraryChanged();
        }
        catch (Exception ex)
        {
            Message = Explain(ex);
            SyncDetail = null;
        }
        finally
        {
            IsSyncing = false;
        }
    }

    [RelayCommand]
    private void ForgetAccount(ServerAccount account)
    {
        _server.ForgetAccount(account.ServerId);
        Accounts.Remove(account);
        OnPropertyChanged(nameof(HasAccounts));
        Message = $"Signed out of {account.ServerName}.";
    }

    /// <summary>
    /// Send the user to plex.tv. Opening it for them is the whole point — the
    /// "strong" PIN Mozz requests is a 25-character token that app.plex.tv needs
    /// and that no one should be retyping.
    /// </summary>
    [RelayCommand]
    private void OpenPlexLink()
    {
        if (PlexLinkUrl is not { Length: > 0 } url) return;
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url)
            {
                UseShellExecute = true,
            });
        }
        catch (Exception)
        {
            // No browser, or a locked-down desktop. Copy is the fallback, and
            // saying so beats a dialog about a failed shell execute.
            Message = "Could not open a browser — use Copy link and paste it into one.";
        }
    }

    [RelayCommand]
    private async Task CopyPlexLinkAsync()
    {
        if (PlexLinkUrl is not { Length: > 0 } url) return;
        var clipboard = Avalonia.Application.Current?.ApplicationLifetime
            is Avalonia.Controls.ApplicationLifetimes.IClassicDesktopStyleApplicationLifetime desktop
            ? desktop.MainWindow?.Clipboard
            : null;
        if (clipboard is null) return;
        await clipboard.SetTextAsync(url);
        Message = "Link copied. Paste it into a browser and approve Mozz.";
    }

    [RelayCommand]
    private void CancelPlex()
    {
        CancelPlexPoll();
        PlexCode = null;
        PlexLinkUrl = null;
        Message = null;
    }

    private void CancelPlexPoll()
    {
        _plexPoll?.Cancel();
        _plexPoll?.Dispose();
        _plexPoll = null;
    }

    // MARK: Helpers

    /// <summary>
    /// Accepts what people actually type. A bare host is the common case —
    /// self-hosters know their server as "192.168.1.10:8096", not as a URL — and
    /// rejecting that for want of a scheme is a bad first impression.
    /// </summary>
    internal static string? NormalizeUrl(string input)
    {
        var text = input.Trim().TrimEnd('/');
        if (text.Length == 0) return null;

        if (!text.Contains("://")) text = "http://" + text;
        if (!Uri.TryCreate(text, UriKind.Absolute, out var uri)) return null;
        if (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps) return null;
        if (string.IsNullOrEmpty(uri.Host)) return null;

        return uri.GetLeftPart(UriPartial.Path).TrimEnd('/');
    }

    /// <summary>
    /// Turn an exception into something worth reading. The core reports transport
    /// failures as typed errors whose descriptions are accurate but not useful to
    /// somebody who just mistyped a port.
    /// </summary>
    internal static string Explain(Exception ex)
    {
        var text = ex.Message;
        if (text.Contains("serverUnreachable", StringComparison.OrdinalIgnoreCase))
            return "Could not reach that server. Check the address and that it is switched on.";
        if (text.Contains("unauthorized", StringComparison.OrdinalIgnoreCase))
            return "That username or password was not accepted.";
        if (text.Contains("no stored credential", StringComparison.OrdinalIgnoreCase))
            return text;
        if (text.Contains("cancelled", StringComparison.OrdinalIgnoreCase))
            return "Cancelled.";
        return text;
    }
}
