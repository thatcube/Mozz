using Avalonia;
using Avalonia.Logging;
using System;
using System.Diagnostics;

namespace Mozz.Desktop;

sealed class Program
{
    // Initialization code. Don't use any Avalonia, third-party APIs or any
    // SynchronizationContext-reliant code before AppMain is called: things aren't initialized
    // yet and stuff might break.
    [STAThread]
    public static void Main(string[] args) => BuildAvaloniaApp()
        .StartWithClassicDesktopLifetime(args);

    // Avalonia configuration, don't remove; also used by visual designer.
    public static AppBuilder BuildAvaloniaApp()
    {
        // LogToTrace writes to System.Diagnostics.Trace, which drops everything
        // on the floor unless a listener is attached — so in a release bundle it
        // is silent, and its silence means nothing. That matters because the
        // failure it would catch is a binding that resolves to nothing: the page
        // renders, blank, and no test can see it because the test project cannot
        // construct Avalonia controls at all.
        //
        // MOZZ_TRACE=1 attaches a listener to stderr so those warnings surface
        // when you go looking for them, without making an ordinary launch noisy.
        var level = LogEventLevel.Warning;
        if (Environment.GetEnvironmentVariable("MOZZ_TRACE") is { Length: > 0 } trace)
        {
            Trace.Listeners.Add(new ConsoleTraceListener(useErrorStream: true));
            Trace.AutoFlush = true;
            if (trace is "2" or "verbose") level = LogEventLevel.Debug;
        }

        return AppBuilder.Configure<App>()
            .UsePlatformDetect()
#if DEBUG
            .WithDeveloperTools()
#endif
            .WithInterFont()
            .LogToTrace(level);
    }
}
