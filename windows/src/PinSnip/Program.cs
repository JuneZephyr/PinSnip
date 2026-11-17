using System;
using System.Threading;
using WinForms = System.Windows.Forms;

namespace PinSnip;

internal static class Program
{
    private const string MutexName = @"Local\PinSnip.SingleInstance.4f8c2b";

    [STAThread]
    private static void Main()
    {
        // The manifest already asks for per-monitor DPI. WinForms still has
        // to be told, or the notification icon is created in the wrong DPI
        // context and Windows draws nothing in the tray.
        try
        {
            WinForms.Application.SetHighDpiMode(WinForms.HighDpiMode.PerMonitorV2);
        }
        catch (Exception ex)
        {
            App.Log($"dpi mode: {ex.Message}");
        }

        // One tray icon per user session. A second launch exits quietly.
        using var mutex = new Mutex(true, MutexName, out bool created);
        if (!created)
        {
            return;
        }

        var app = new App();
        app.Run();
    }
}
