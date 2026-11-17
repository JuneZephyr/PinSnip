using System;
using System.Collections.Generic;
using Gdi = System.Drawing;
using GdiDrawing = System.Drawing.Drawing2D;
using GdiImaging = System.Drawing.Imaging;
using WinForms = System.Windows.Forms;

namespace PinSnip;

/// <summary>One frozen monitor image taken when the capture started.</summary>
internal sealed class ScreenShot
{
    public required WinForms.Screen Screen { get; init; }
    public required Gdi.Bitmap Bitmap { get; init; }
    public Gdi.Rectangle Bounds => Screen.Bounds;
}

/// <summary>Screen pixels through GDI. The process is per-monitor DPI aware, so
/// every rectangle here is in physical pixels and cropping needs no scaling
/// beyond the one the overlay measures.</summary>
internal static class ScreenCapture
{
    public static Gdi.Bitmap Capture(Gdi.Rectangle bounds)
    {
        int width = Math.Max(1, bounds.Width);
        int height = Math.Max(1, bounds.Height);
        var bitmap = new Gdi.Bitmap(width, height, GdiImaging.PixelFormat.Format32bppArgb);
        try
        {
            using Gdi.Graphics graphics = Gdi.Graphics.FromImage(bitmap);
            graphics.CopyFromScreen(
                bounds.Left, bounds.Top, 0, 0,
                new Gdi.Size(width, height),
                Gdi.CopyPixelOperation.SourceCopy);
            return bitmap;
        }
        catch
        {
            bitmap.Dispose();
            throw;
        }
    }

    /// <summary>Captures every monitor. The caller hides the pin windows first
    /// so they cannot appear in the frozen image.</summary>
    public static List<ScreenShot> CaptureAll()
    {
        var shots = new List<ScreenShot>();
        foreach (WinForms.Screen screen in WinForms.Screen.AllScreens)
        {
            shots.Add(new ScreenShot
            {
                Screen = screen,
                Bitmap = Capture(screen.Bounds)
            });
        }
        if (shots.Count == 0 && WinForms.Screen.PrimaryScreen is { } primary)
        {
            shots.Add(new ScreenShot { Screen = primary, Bitmap = Capture(primary.Bounds) });
        }
        return shots;
    }

    public static WinForms.Screen ScreenAtCursor()
    {
        NativeCursor(out int x, out int y);
        return WinForms.Screen.FromPoint(new Gdi.Point(x, y));
    }

    private static void NativeCursor(out int x, out int y)
    {
        Platform.Native.POINT point = Platform.Native.CursorPosition();
        x = point.X;
        y = point.Y;
    }

    /// <summary>Downsamples a bitmap to a small buffer for the frame differ and
    /// the stitcher. Row 0 is the top of the picture, matching GDI+.</summary>
    public static byte[] Downsample(Gdi.Bitmap bitmap, int width, int height)
    {
        using var small = new Gdi.Bitmap(width, height, GdiImaging.PixelFormat.Format32bppArgb);
        using (Gdi.Graphics graphics = Gdi.Graphics.FromImage(small))
        {
            graphics.InterpolationMode = GdiDrawing.InterpolationMode.Low;
            graphics.PixelOffsetMode = GdiDrawing.PixelOffsetMode.HighSpeed;
            graphics.DrawImage(bitmap, new Gdi.Rectangle(0, 0, width, height));
        }
        return ReadPixels(small);
    }

    public static byte[] ReadPixels(Gdi.Bitmap bitmap)
    {
        GdiImaging.BitmapData data = bitmap.LockBits(
            new Gdi.Rectangle(0, 0, bitmap.Width, bitmap.Height),
            GdiImaging.ImageLockMode.ReadOnly,
            GdiImaging.PixelFormat.Format32bppArgb);
        try
        {
            int stride = Math.Abs(data.Stride);
            byte[] buffer = new byte[stride * bitmap.Height];
            System.Runtime.InteropServices.Marshal.Copy(data.Scan0, buffer, 0, buffer.Length);
            if (stride != bitmap.Width * 4)
            {
                // GDI+ pads rows to 4 bytes already; at 32bpp the stride is
                // exactly width * 4, so this is only a guard.
                byte[] packed = new byte[bitmap.Width * 4 * bitmap.Height];
                for (int y = 0; y < bitmap.Height; y++)
                {
                    Buffer.BlockCopy(buffer, y * stride, packed, y * bitmap.Width * 4, bitmap.Width * 4);
                }
                return packed;
            }
            if (data.Stride < 0)
            {
                // Bottom-up storage: reverse the rows so row 0 is the top.
                int rowBytes = bitmap.Width * 4;
                byte[] flipped = new byte[buffer.Length];
                for (int y = 0; y < bitmap.Height; y++)
                {
                    Buffer.BlockCopy(buffer, (bitmap.Height - 1 - y) * rowBytes, flipped, y * rowBytes, rowBytes);
                }
                return flipped;
            }
            return buffer;
        }
        finally
        {
            bitmap.UnlockBits(data);
        }
    }
}
