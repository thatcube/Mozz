using System;
using System.IO;
using System.Threading;
using System.Linq;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Mozz.Desktop.Core;

namespace Mozz.Desktop.ViewModels;

/// <summary>
/// On-device sonic analysis, on the device best suited to it.
///
/// The phones do this on a charger, overnight, for hours. A desktop is already
/// plugged in, has a real processor and is not going anywhere — so it is the
/// natural place for the work, and with vectors shared between a listener's
/// devices it is the machine that can spare the others the evening.
///
/// The engine, the pass and the resumability all live in the core. This starts
/// it and reports where it got to.
/// </summary>
public partial class MainViewModel
{
    [ObservableProperty]
    private SonicProgress? _sonicProgress;

    [ObservableProperty]
    private bool _sonicAnalysisRunning;

    private CancellationTokenSource? _sonicPoll;

    /// <summary>
    /// Where the learned analyzer's weights live beside the executable.
    ///
    /// Null when they are missing, which is not fatal: the core falls back to
    /// the DSP engine. That fallback is worth knowing about rather than
    /// silently accepting, though — the two engines are coordinates in
    /// unrelated spaces, so a desktop analysing with one while the phones use
    /// the other fills a shared library with vectors that cannot be compared.
    /// </summary>
    private static string? SonicWeightsPath
    {
        get
        {
            var beside = Path.Combine(AppContext.BaseDirectory, "vggish-trunk.bin");
            return File.Exists(beside) ? beside : null;
        }
    }

    public string SonicAnalysisEngineNote => SonicWeightsPath is null
        ? "Using the simpler analyzer — the learned model's weights are not installed beside the app."
        : "Listening with the learned analyzer, the same one the phone uses.";

    [RelayCommand]
    private async Task StartSonicAnalysisAsync()
    {
        var serverId = Connect.Accounts.FirstOrDefault()?.ServerId;
        if (string.IsNullOrWhiteSpace(serverId)) return;
        try
        {
            SonicProgress = await _core.CallAsync<SonicProgress>(new CoreRequest("analyzeSonics")
            {
                ServerId = serverId,
                WeightsPath = SonicWeightsPath,
            });
            SonicAnalysisRunning = true;
            StartSonicPolling(serverId);
        }
        catch (MozzCoreException ex)
        {
            StatusMessage = $"Could not start listening: {ex.Message}";
        }
    }

    [RelayCommand]
    private async Task CancelSonicAnalysisAsync()
    {
        _sonicPoll?.Cancel();
        SonicAnalysisRunning = false;
        try { await _core.CallAsync<ActionResult>(new CoreRequest("cancelSonics")); }
        catch (MozzCoreException) { }
    }

    /// <summary>
    /// Follow the pass so the panel can show it moving. One small database read
    /// a few times a minute, which is what the phone does too.
    /// </summary>
    private void StartSonicPolling(string serverId)
    {
        _sonicPoll?.Cancel();
        var cancellation = new CancellationTokenSource();
        _sonicPoll = cancellation;
        _ = Task.Run(async () =>
        {
            while (!cancellation.IsCancellationRequested)
            {
                await Task.Delay(TimeSpan.FromSeconds(15), cancellation.Token);
                SonicProgress? progress;
                try
                {
                    progress = await _core.CallAsync<SonicProgress>(new CoreRequest("sonicProgress")
                    {
                        ServerId = serverId,
                        WeightsPath = SonicWeightsPath,
                    });
                }
                catch (MozzCoreException) { continue; }
                if (progress is null) continue;
                SonicProgress = progress;
                if (!progress.Running)
                {
                    SonicAnalysisRunning = false;
                    return;
                }
            }
        }, cancellation.Token);
    }
}
