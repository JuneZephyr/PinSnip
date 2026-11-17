using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Gdi = System.Drawing;

namespace PinSnip;

/// <summary>Burns the annotations into the cropped screenshot. Everything is
/// drawn in physical pixels so the result is as sharp as the capture.</summary>
internal static class AnnotationRenderer
{
    public static BitmapSource Render(
        Gdi.Bitmap crop,
        IReadOnlyList<Mark> marks,
        double scaleX,
        double scaleY,
        Gdi.Rectangle selectionPixels)
    {
        BitmapSource source = Imaging.ToSource(crop);
        int width = crop.Width;
        int height = crop.Height;

        BitmapSource? pixelated = null;
        if (marks.Count > 0 && marks.Any(m => m.Kind == MarkKind.Mosaic))
        {
            int block = marks.First(m => m.Kind == MarkKind.Mosaic).BlockSize;
            int pixels = Math.Max(2, (int)Math.Round(block * Math.Max(scaleX, scaleY)));
            pixelated = Imaging.Pixelate(source, pixels);
        }

        var visual = new DrawingVisual();
        RenderOptions.SetBitmapScalingMode(visual, BitmapScalingMode.NearestNeighbor);
        using (DrawingContext dc = visual.RenderOpen())
        {
            dc.DrawImage(source, new Rect(0, 0, width, height));
            if (marks.Count > 0)
            {
                double scale = (scaleX + scaleY) / 2;
                var origin = new Point(selectionPixels.X, selectionPixels.Y);
                Point Map(Point point) => new Point(point.X * scaleX - origin.X, point.Y * scaleY - origin.Y);
                foreach (Mark mark in marks)
                {
                    MarkPainter.Draw(dc, mark, Map, scale, new Size(width, height), pixelated);
                }
            }
        }

        var target = new RenderTargetBitmap(Math.Max(1, width), Math.Max(1, height), 96, 96, PixelFormats.Pbgra32);
        target.Render(visual);
        target.Freeze();
        return target;
    }
}
