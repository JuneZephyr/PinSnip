using System;
using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Gdi = System.Drawing;
using GdiImaging = System.Drawing.Imaging;

namespace PinSnip;

/// <summary>Conversions between GDI+ bitmaps (what screen capture produces) and
/// WPF images (what the windows and the clipboard use).</summary>
internal static class Imaging
{
    public static BitmapSource ToSource(Gdi.Bitmap bitmap)
    {
        GdiImaging.BitmapData data = bitmap.LockBits(
            new Gdi.Rectangle(0, 0, bitmap.Width, bitmap.Height),
            GdiImaging.ImageLockMode.ReadOnly,
            GdiImaging.PixelFormat.Format32bppArgb);
        try
        {
            BitmapSource source = BitmapSource.Create(
                bitmap.Width, bitmap.Height, 96, 96, PixelFormats.Bgra32, null,
                data.Scan0, data.Stride * bitmap.Height, data.Stride);
            source.Freeze();
            return source;
        }
        finally
        {
            bitmap.UnlockBits(data);
        }
    }

    public static Gdi.Bitmap Crop(Gdi.Bitmap bitmap, Gdi.Rectangle rect)
    {
        Gdi.Rectangle bounds = new Gdi.Rectangle(0, 0, bitmap.Width, bitmap.Height);
        rect.Intersect(bounds);
        if (rect.Width < 1) rect.Width = 1;
        if (rect.Height < 1) rect.Height = 1;
        return bitmap.Clone(rect, GdiImaging.PixelFormat.Format32bppArgb);
    }

    /// <summary>An image made of square blocks, used as the mosaic fill.</summary>
    public static BitmapSource Pixelate(BitmapSource source, int block)
    {
        block = Math.Max(1, block);
        if (block == 1)
        {
            return source;
        }
        // Shrinking averages neighbouring pixels; the caller draws the result
        // with nearest-neighbour scaling, which makes the square blocks.
        var small = new TransformedBitmap(source, new ScaleTransform(1.0 / block, 1.0 / block));
        small.Freeze();
        var big = new TransformedBitmap(small, new ScaleTransform(block, block));
        big.Freeze();
        return big;
    }

    public static void SavePng(BitmapSource image, string path)
    {
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(image));
        using FileStream stream = File.Create(path);
        encoder.Save(stream);
    }

    public static BitmapSource? TryLoad(string path)
    {
        try
        {
            var image = new BitmapImage();
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.UriSource = new Uri(path, UriKind.Absolute);
            image.EndInit();
            image.Freeze();
            return image;
        }
        catch
        {
            return null;
        }
    }

    private static readonly FontFamily CardFont = new FontFamily("Segoe UI, Microsoft YaHei UI");
    private const double CardMaxWidth = 420;
    private const double CardPadding = 18;
    private const double CardFontSize = 15;
    private const int CardMaxCharacters = 12000;
    private const double CardMaxHeight = 20000;

    /// <summary>Renders clipboard text into a light card that can be pinned,
    /// the same idea as the macOS version's text pins.</summary>
    public static BitmapSource RenderTextCard(string text)
    {
        string body = text.Replace("\r\n", "\n").Replace('\r', '\n').TrimEnd();
        if (body.Length > CardMaxCharacters)
        {
            body = body.Substring(0, CardMaxCharacters);
        }

        FormattedText Create(string value) => new FormattedText(
            value,
            CultureInfo.CurrentUICulture,
            FlowDirection.LeftToRight,
            new Typeface(CardFont, FontStyles.Normal, FontWeights.Normal, FontStretches.Normal),
            CardFontSize,
            Brushes.Black,
            96)
        {
            MaxTextWidth = CardMaxWidth - CardPadding * 2,
            MaxTextHeight = CardMaxHeight
        };

        FormattedText formatted = Create(body);
        if (formatted.Height + CardPadding * 2 > CardMaxHeight)
        {
            // Cut by measurement rather than guesswork, so a very long chat log
            // still produces a card instead of a memory failure.
            int low = 0;
            int high = body.Length;
            while (low < high)
            {
                int middle = (low + high + 1) / 2;
                FormattedText probe = Create(body.Substring(0, middle) + "\n…（内容过长，已截断）");
                if (probe.Height + CardPadding * 2 <= CardMaxHeight)
                {
                    low = middle;
                }
                else
                {
                    high = middle - 1;
                }
            }
            body = body.Substring(0, low) + "\n…（内容过长，已截断）";
            formatted = Create(body);
        }

        double width = Math.Min(CardMaxWidth, Math.Ceiling(formatted.WidthIncludingTrailingWhitespace) + CardPadding * 2);
        double height = Math.Ceiling(formatted.Height) + CardPadding * 2;
        width = Math.Max(80, width);
        height = Math.Max(40, height);

        var visual = new DrawingVisual();
        using (DrawingContext dc = visual.RenderOpen())
        {
            var background = new SolidColorBrush(Color.FromRgb(0xFA, 0xFA, 0xFA));
            dc.DrawRoundedRectangle(background, new Pen(new SolidColorBrush(Color.FromRgb(0xD0, 0xD0, 0xD0)), 1),
                new Rect(0.5, 0.5, width - 1, height - 1), 6, 6);
            dc.DrawText(formatted, new Point(CardPadding, CardPadding));
        }

        var target = new RenderTargetBitmap(
            Math.Max(1, (int)Math.Ceiling(width)),
            Math.Max(1, (int)Math.Ceiling(height)),
            96, 96, PixelFormats.Pbgra32);
        target.Render(visual);
        target.Freeze();
        return target;
    }
}
