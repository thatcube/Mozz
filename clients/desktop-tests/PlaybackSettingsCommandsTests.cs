using Mozz.Desktop.Core;
using Mozz.Desktop.Core.Downloads;
using Mozz.V1;
using Xunit;

namespace Mozz.Desktop.Tests;

public sealed class PlaybackSettingsCommandsTests
{
    [Fact]
    public async Task SaveUsesTheGeneratedCommandAndProjectsTheEffectiveSettings()
    {
        var invoker = new PlaybackSettingsInvoker();
        var commands = new PlaybackSettingsCommands(invoker);
        var input = new CorePlaybackSettings(
            true,
            Enumerable.Range(0, 10).Select(value => (double)value).ToArray(),
            -3,
            "album",
            1.5);

        var result = await commands.SaveAsync(input);

        Assert.NotNull(invoker.LastRequest);
        Assert.Equal(
            Request.CommandOneofCase.SetPlaybackSettings,
            invoker.LastRequest.CommandCase);
        Assert.Equal(
            Mozz.V1.ReplayGainMode.Album,
            invoker.LastRequest.SetPlaybackSettings.Settings.ReplayGainMode);
        Assert.Equal(input.EqualizerEnabled, result.EqualizerEnabled);
        Assert.Equal(
            input.EqualizerBandGainsDB,
            result.EqualizerBandGainsDB);
        Assert.Equal(input.EqualizerPreampDB, result.EqualizerPreampDB);
        Assert.Equal(input.ReplayGainMode, result.ReplayGainMode);
        Assert.Equal(input.ReplayGainPreampDB, result.ReplayGainPreampDB);
    }

    private sealed class PlaybackSettingsInvoker : ICoreInvoker
    {
        public Request? LastRequest { get; private set; }

        public Response Invoke(Request request)
        {
            LastRequest = request;
            return request.CommandCase switch
            {
                Request.CommandOneofCase.SetPlaybackSettings => new Response
                {
                    Id = request.Id,
                    SetPlaybackSettings = new SetPlaybackSettingsResponse
                    {
                        Settings = request.SetPlaybackSettings.Settings.Clone(),
                    },
                },
                Request.CommandOneofCase.GetPlaybackSettings => new Response
                {
                    Id = request.Id,
                    GetPlaybackSettings = new GetPlaybackSettingsResponse
                    {
                        Settings = new Mozz.V1.PlaybackSettings(),
                    },
                },
                _ => throw new InvalidOperationException(
                    $"Unexpected command {request.CommandCase}"),
            };
        }

        public Task<Response> InvokeAsync(
            Request request,
            CancellationToken token = default) =>
            Task.FromResult(Invoke(request));
    }
}
