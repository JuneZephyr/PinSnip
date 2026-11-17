using System;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace PinSnip.Platform;

/// <summary>The application icon, loaded from the assembly itself. Reading it
/// out of the exe with ExtractAssociatedIcon fails for a single-file publish:
/// the notification area then stays blank or shows the generic program icon.</summary>
internal static class AppImages
{
    private const string ResourceName = "PinSnip.app.ico";
    private static ImageSource? _windowIcon;

    public static Icon TrayIcon()
    {
        int size = 32;
        try
        {
            int metric = GetSystemMetrics(49 /* SM_CXSMICON */);
            if (metric > size) size = metric;
        }
        catch (Exception ex)
        {
            App.Log($"tray icon size failed: {ex.Message}");
        }

        Stream? stream = Open();
        if (stream != null)
        {
            using (stream)
            {
                return new Icon(stream, new Size(size, size));
            }
        }

        // Never hand out the shared system icon: disposing the tray would
        // dispose it for the rest of the session.
        return (Icon)SystemIcons.Application.Clone();
    }

    public static ImageSource? WindowIcon
    {
        get
        {
            if (_windowIcon != null) return _windowIcon;
            Stream? stream = Open();
            if (stream == null) return null;
            using (stream)
            {
                var frame = BitmapFrame.Create(stream, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
                frame.Freeze();
                _windowIcon = frame;
                return frame;
            }
        }
    }

    private static Stream? Open()
    {
        return Assembly.GetExecutingAssembly().GetManifestResourceStream(ResourceName);
    }

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);
}
