using System;
using System.Collections.Specialized;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows;
using System.Windows.Media.Imaging;

namespace PinSnip;

internal static class ClipboardHelper
{
    private const string IgnoreFormat = "Clipboard Viewer Ignore";
    private const string ExcludeFormat = "ExcludeClipboardContentFromMonitorProcessing";
    private const string HistoryFormat = "CanIncludeInClipboardHistory";

    /// <summary>Password managers mark copied secrets so clipboard tools leave
    /// them alone. The Windows equivalent of the macOS concealed-type check.</summary>
    public static bool IsMarkedPrivate()
    {
        try
        {
            IDataObject? data = Clipboard.GetDataObject();
            if (data == null) return false;
            if (data.GetDataPresent(IgnoreFormat)) return true;
            if (data.GetDataPresent(ExcludeFormat)) return true;
            if (data.GetDataPresent(HistoryFormat) && data.GetData(HistoryFormat) is int allowed && allowed == 0)
            {
                return true;
            }
            return false;
        }
        catch
        {
            return false;
        }
    }

    public static bool TryGetImage(out BitmapSource? image)
    {
        image = null;
        try
        {
            if (!Clipboard.ContainsImage()) return false;
            image = Clipboard.GetImage();
            image?.Freeze();
            return image != null && image.PixelWidth > 0;
        }
        catch
        {
            return false;
        }
    }

    public static string? TryGetText()
    {
        try
        {
            if (!Clipboard.ContainsText()) return null;
            string text = Clipboard.GetText();
            return string.IsNullOrWhiteSpace(text) ? null : text;
        }
        catch
        {
            return null;
        }
    }

    public static bool TryGetFileImage(out BitmapSource? image)
    {
        image = null;
        try
        {
            if (!Clipboard.ContainsFileDropList()) return false;
            StringCollection? files = Clipboard.GetFileDropList();
            if (files == null) return false;
            string? path = files.Cast<string?>().FirstOrDefault(IsImageFile);
            if (path == null) return false;
            image = Imaging.TryLoad(path);
            return image != null;
        }
        catch
        {
            return false;
        }
    }

    private static bool IsImageFile(string? path)
    {
        if (string.IsNullOrEmpty(path) || !File.Exists(path)) return false;
        return Path.GetExtension(path).ToLowerInvariant() switch
        {
            ".png" or ".jpg" or ".jpeg" or ".bmp" or ".gif" or ".tif" or ".tiff" => true,
            _ => false
        };
    }

    public static bool SetImage(BitmapSource image)
    {
        for (int attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                Clipboard.SetImage(image);
                return true;
            }
            catch
            {
                // Another program can hold the clipboard open for a moment.
                Thread.Sleep(60);
            }
        }
        return false;
    }
}
