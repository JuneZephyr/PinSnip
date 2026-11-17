using System;
using System.Runtime.InteropServices;
using Gdi = System.Drawing;
using GdiImaging = System.Drawing.Imaging;

namespace PinSnip;

/// <summary>A growable BGRA canvas. Row 0 of the finished image is the top of
/// the page; new rows are appended at the bottom. Storing the canvas top-down
/// is what keeps the long screenshot the right way up.</summary>
internal sealed class StitchBuffer
{
    private const int BytesPerPixel = 4;

    private byte[] _data;
    private int _capacity;

    public StitchBuffer(int width, int initialHeight)
    {
        Width = Math.Max(1, width);
        _capacity = Math.Max(1, Math.Min(initialHeight, MaxHeight));
        _data = new byte[_capacity * Width * BytesPerPixel];
    }

    public int Width { get; }
    public int Height { get; private set; }
    public int MaxHeight { get; set; } = 30000;

    private int RowBytes => Width * BytesPerPixel;

    public void AppendRows(Gdi.Bitmap strip, int rows)
    {
        if (rows <= 0) return;
        int allowed = Math.Min(rows, Math.Max(0, MaxHeight - Height));
        if (allowed <= 0) return;

        if (Height + allowed > _capacity)
        {
            int target = Math.Min(Math.Max(Height + allowed, _capacity * 2), MaxHeight);
            if (target > _capacity) Grow(target);
        }
        if (Height + allowed > _capacity)
        {
            allowed = _capacity - Height;
            if (allowed <= 0) return;
        }

        byte[] source = ScreenCapture.ReadPixels(strip);
        int rowBytes = Math.Min(RowBytes, strip.Width * BytesPerPixel);
        for (int y = 0; y < allowed && y < strip.Height; y++)
        {
            Buffer.BlockCopy(source, y * rowBytes, _data, (Height + y) * RowBytes, rowBytes);
        }
        Height += allowed;
    }

    private void Grow(int newCapacity)
    {
        var bigger = new byte[newCapacity * RowBytes];
        Buffer.BlockCopy(_data, 0, bigger, 0, Height * RowBytes);
        _data = bigger;
        _capacity = newCapacity;
    }

    public Gdi.Bitmap ToBitmap()
    {
        int height = Math.Max(1, Height);
        var bitmap = new Gdi.Bitmap(Width, height, GdiImaging.PixelFormat.Format32bppArgb);
        GdiImaging.BitmapData data = bitmap.LockBits(
            new Gdi.Rectangle(0, 0, Width, height),
            GdiImaging.ImageLockMode.WriteOnly,
            GdiImaging.PixelFormat.Format32bppArgb);
        try
        {
            int rowBytes = RowBytes;
            if (data.Stride == rowBytes)
            {
                Marshal.Copy(_data, 0, data.Scan0, Math.Min(Height, height) * rowBytes);
            }
            else
            {
                for (int y = 0; y < Math.Min(Height, height); y++)
                {
                    Marshal.Copy(_data, y * rowBytes, IntPtr.Add(data.Scan0, y * data.Stride), rowBytes);
                }
            }
        }
        finally
        {
            bitmap.UnlockBits(data);
        }
        return bitmap;
    }
}

internal readonly struct FrameShift
{
    public FrameShift(int pixels, double quality)
    {
        Pixels = pixels;
        Quality = quality;
    }

    public int Pixels { get; }
    public double Quality { get; }
}

/// <summary>Finds how far the page scrolled between two frames and extracts the
/// newly revealed rows.</summary>
internal static class Stitcher
{
    public static FrameShift Detect(Gdi.Bitmap previous, Gdi.Bitmap next)
    {
        if (previous.Width != next.Width || previous.Height != next.Height)
        {
            return new FrameShift(0, double.MaxValue);
        }
        if (previous.Width <= 8 || previous.Height <= 8)
        {
            return new FrameShift(0, double.MaxValue);
        }

        int smallWidth = Math.Max(2, previous.Width / 4);
        int smallHeight = Math.Max(8, previous.Height / 4);
        byte[] a = ScreenCapture.Downsample(previous, smallWidth, smallHeight);
        byte[] b = ScreenCapture.Downsample(next, smallWidth, smallHeight);

        int strip = Math.Max(3, smallHeight / 8);
        int limit = smallHeight - strip;
        // Start at "no movement": a blank or repeating region matches many
        // places equally, and the smallest move invents no gap.
        int bestY = limit;
        double bestScore = double.MaxValue;

        for (int candidate = 0; candidate <= limit; candidate++)
        {
            double score = 0;
            for (int row = 0; row < strip; row++)
            {
                int aRow = (smallHeight - strip + row) * smallWidth;
                int bRow = (candidate + row) * smallWidth;
                for (int column = 0; column < smallWidth; column++)
                {
                    int ai = (aRow + column) * 4;
                    int bi = (bRow + column) * 4;
                    score += Math.Abs(a[ai] - b[bi]);
                    score += Math.Abs(a[ai + 1] - b[bi + 1]);
                    score += Math.Abs(a[ai + 2] - b[bi + 2]);
                }
            }
            double slack = Math.Max(1.5, bestScore * 0.08);
            if (score + 0.01 < bestScore)
            {
                bestScore = score;
                bestY = candidate;
            }
            else if (candidate > bestY && score <= bestScore + slack)
            {
                bestY = candidate;
            }
        }

        double scale = previous.Height / (double)smallHeight;
        int pixels = (int)Math.Round((limit - bestY) * scale);
        double quality = bestScore / (strip * smallWidth * 3.0);
        return new FrameShift(Math.Max(0, pixels), quality);
    }

    /// <summary>The bottom `rows` of the frame — the part that just scrolled
    /// into view.</summary>
    public static Gdi.Bitmap? NewRows(Gdi.Bitmap frame, int rows)
    {
        int count = Math.Min(Math.Max(0, rows), frame.Height);
        if (count <= 0) return null;
        return frame.Clone(
            new Gdi.Rectangle(0, frame.Height - count, frame.Width, count),
            GdiImaging.PixelFormat.Format32bppArgb);
    }

    /// <summary>Mean absolute difference of two frames, 0 (identical) to 255.</summary>
    public static double Difference(Gdi.Bitmap a, Gdi.Bitmap b)
    {
        const int size = 48;
        byte[] ba = ScreenCapture.Downsample(a, size, size);
        byte[] bb = ScreenCapture.Downsample(b, size, size);
        double sum = 0;
        for (int index = 0; index < ba.Length; index += 4)
        {
            sum += Math.Abs(ba[index] - bb[index]);
            sum += Math.Abs(ba[index + 1] - bb[index + 1]);
            sum += Math.Abs(ba[index + 2] - bb[index + 2]);
        }
        return sum / (size * size * 3.0);
    }
}
