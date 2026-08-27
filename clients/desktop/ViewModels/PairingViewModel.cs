using System;
using System.Collections.ObjectModel;
using System.Threading;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Mozz.Desktop.Core;

namespace Mozz.Desktop.ViewModels;

/// <summary>
/// Drives a pairing ceremony for the desktop window.
/// </summary>
/// <remarks>
/// The desktop is the member: it holds the music, so it holds the circle and
/// hands it over. It has no camera worth pointing at a phone, so the code is
/// pasted or typed rather than scanned — which is also why the phone is the one
/// displaying it.
/// </remarks>
public sealed partial class PairingViewModel : ObservableObject
{
    private readonly PairingService _pairing;
    private readonly PairingDiscovery _discovery = new();
    private CancellationTokenSource? _watching;
    private TaskCompletionSource<bool>? _awaitingAnswer;
    private bool _startedAutomatically;

    public PairingViewModel(MozzCore core)
    {
        _pairing = new PairingService(core);
    }

    public ObservableCollection<PairingCandidate> Devices { get; } = new();

    [ObservableProperty] private string _code = string.Empty;
    [ObservableProperty] private PairingCandidate? _selectedDevice;
    [ObservableProperty] private string _status = "Open Mozz on the other device and go to Settings → Your Devices.";
    [ObservableProperty] private string _digits = string.Empty;
    [ObservableProperty] private bool _isComparing;
    [ObservableProperty] private bool _isBusy;
    [ObservableProperty] private bool _isDone;

    // A code is optional. Without one this uses the digit path, which is the
    // normal way to pair a desktop.
    public bool CanPair => !IsBusy && SelectedDevice is not null;

    partial void OnCodeChanged(string value) => OnPropertyChanged(nameof(CanPair));
    partial void OnSelectedDeviceChanged(PairingCandidate? value) => OnPropertyChanged(nameof(CanPair));
    partial void OnIsBusyChanged(bool value) => OnPropertyChanged(nameof(CanPair));

    /// <summary>Starts watching for phones showing a code.</summary>
    public void StartWatching()
    {
        _watching?.Cancel();
        _watching = new CancellationTokenSource();
        var token = _watching.Token;

        _ = Task.Run(async () =>
        {
            try
            {
                await foreach (var device in _discovery.WatchAsync(token))
                {
                    await Avalonia.Threading.Dispatcher.UIThread.InvokeAsync(() =>
                    {
                        Devices.Add(device);
                        SelectedDevice ??= device;
                        Status = $"{device.Name} is asking to join.";

                        // Opening Devices is the intent. Once exactly one device
                        // answers, making the person select it and press Add asks
                        // the same question twice; go straight to the decision
                        // that matters, which is whether the six digits match.
                        if (!_startedAutomatically)
                        {
                            _startedAutomatically = true;
                            _ = PairAsync();
                        }
                    });
                }
            }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                await Avalonia.Threading.Dispatcher.UIThread.InvokeAsync(() =>
                    Status = $"Could not look for devices: {ex.Message}");
            }
        }, token);
    }

    public void StopWatching()
    {
        _watching?.Cancel();
        _watching = null;
        // Release anyone waiting on an answer, or the ceremony never unwinds and
        // the window closes over a suspended task.
        _awaitingAnswer?.TrySetResult(false);
        _awaitingAnswer = null;
    }

    [RelayCommand]
    private async Task PairAsync()
    {
        if (SelectedDevice is null) return;

        IsBusy = true;
        Status = "Pairing…";
        try
        {
            var code = string.IsNullOrWhiteSpace(Code) ? null : Code.Trim();
            await _pairing.AdmitAsync(code, SelectedDevice, AskAsync).ConfigureAwait(true);
            IsDone = true;
            Status = "Added. These devices now share listening, library and servers.";
        }
        catch (Exception ex)
        {
            Status = Explain(ex);
        }
        finally
        {
            IsBusy = false;
            IsComparing = false;
        }
    }

    [RelayCommand]
    private void Matches() => Answer(true);

    [RelayCommand]
    private void DoesNotMatch() => Answer(false);

    private void Answer(bool matched)
    {
        IsComparing = false;
        _awaitingAnswer?.TrySetResult(matched);
        _awaitingAnswer = null;
    }

    private Task<bool> AskAsync(string digits)
    {
        var source = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        _awaitingAnswer = source;
        Avalonia.Threading.Dispatcher.UIThread.Post(() =>
        {
            Digits = digits.Length == 6 ? $"{digits[..3]} {digits[3..]}" : digits;
            IsComparing = true;
            Status = "Check that both devices show the same number.";
        });
        return source.Task;
    }

    private static string Explain(Exception error) => error switch
    {
        MozzCoreException core => core.Message,
        System.Net.Sockets.SocketException => "Could not reach that device. Is it still showing its code?",
        OperationCanceledException => "Pairing timed out. Try again.",
        _ => $"Pairing did not finish: {error.Message}",
    };
}
