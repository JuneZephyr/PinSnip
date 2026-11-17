using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace PinSnip;

internal enum MarkKind
{
    Rectangle,
    Ellipse,
    Arrow,
    Pen,
    Text,
    Mosaic
}

/// <summary>One annotation. Points are in the overlay view's DIP space; they are
/// mapped to pixels only when the finished image is rendered.</summary>
internal sealed class Mark
{
    public Mark(MarkKind kind)
    {
        Kind = kind;
    }

    public MarkKind Kind { get; }
    public List<Point> Points { get; } = new();
    public Color Color { get; set; } = Colors.Red;
    public double Thickness { get; set; } = 3;
    public string Text { get; set; } = "";
    public double FontSize { get; set; } = 18;
    public int BlockSize { get; set; } = 12;
}

/// <summary>Draws marks either into the live overlay (scale 1) or into the
/// finished bitmap (scale = pixels per DIP).</summary>
internal static class MarkPainter
{
    private static readonly FontFamily LabelFont = new FontFamily("Segoe UI, Microsoft YaHei UI");

    public static void Draw(DrawingContext dc, Mark mark, Func<Point, Point> map, double scale, Size canvas, BitmapSource? pixelated)
    {
        if (mark.Points.Count == 0) return;
        Point[] points = mark.Points.Select(map).ToArray();
        Pen pen = MakePen(mark, scale);

        switch (mark.Kind)
        {
            case MarkKind.Rectangle:
                if (points.Length < 2) return;
                dc.DrawRectangle(null, pen, Normalize(points[0], points[1]));
                break;

            case MarkKind.Ellipse:
                if (points.Length < 2) return;
                Rect box = Normalize(points[0], points[1]);
                dc.DrawEllipse(null, pen, new Point(box.Left + box.Width / 2, box.Top + box.Height / 2),
                    box.Width / 2, box.Height / 2);
                break;

            case MarkKind.Arrow:
                if (points.Length < 2) return;
                DrawArrow(dc, pen, points[0], points[1], scale, mark.Color);
                break;

            case MarkKind.Pen:
                DrawFreehand(dc, pen, points);
                break;

            case MarkKind.Text:
                DrawText(dc, mark, points[0], scale);
                break;

            case MarkKind.Mosaic:
                DrawMosaic(dc, points, canvas, pixelated);
                break;
        }
    }

    private static Pen MakePen(Mark mark, double scale)
    {
        return new Pen(new SolidColorBrush(mark.Color), Math.Max(1, mark.Thickness * scale))
        {
            StartLineCap = PenLineCap.Round,
            EndLineCap = PenLineCap.Round,
            LineJoin = PenLineJoin.Round
        };
    }

    public static Rect Normalize(Point a, Point b)
    {
        return new Rect(
            Math.Min(a.X, b.X),
            Math.Min(a.Y, b.Y),
            Math.Abs(a.X - b.X),
            Math.Abs(a.Y - b.Y));
    }

    private static void DrawArrow(DrawingContext dc, Pen pen, Point start, Point end, double scale, Color color)
    {
        double angle = Math.Atan2(end.Y - start.Y, end.X - start.X);
        double head = Math.Max(10 * scale, pen.Thickness * 3.6);
        double spread = Math.PI / 7;

        var shaftEnd = new Point(
            end.X - head * 0.75 * Math.Cos(angle),
            end.Y - head * 0.75 * Math.Sin(angle));
        dc.DrawLine(pen, start, shaftEnd);

        var geometry = new StreamGeometry();
        using (StreamGeometryContext context = geometry.Open())
        {
            context.BeginFigure(end, isFilled: true, isClosed: true);
            context.LineTo(new Point(
                end.X - head * Math.Cos(angle - spread),
                end.Y - head * Math.Sin(angle - spread)), true, false);
            context.LineTo(new Point(
                end.X - head * Math.Cos(angle + spread),
                end.Y - head * Math.Sin(angle + spread)), true, false);
        }
        geometry.Freeze();
        dc.DrawGeometry(new SolidColorBrush(color), null, geometry);
    }

    private static void DrawFreehand(DrawingContext dc, Pen pen, Point[] points)
    {
        if (points.Length == 1)
        {
            double radius = pen.Thickness / 2;
            dc.DrawEllipse(pen.Brush, null, points[0], radius, radius);
            return;
        }
        var geometry = new StreamGeometry();
        using (StreamGeometryContext context = geometry.Open())
        {
            context.BeginFigure(points[0], isFilled: false, isClosed: false);
            context.PolyLineTo(points.Skip(1).ToList(), isStroked: true, isSmoothJoin: true);
        }
        geometry.Freeze();
        dc.DrawGeometry(null, pen, geometry);
    }

    public static Rect TextBounds(Mark mark)
    {
        if (mark.Points.Count == 0) return Rect.Empty;
        FormattedText text = Format(mark.Text.Length == 0 ? " " : mark.Text, mark.FontSize, 1);
        var bounds = new Rect(mark.Points[0], new Size(
            Math.Max(8, text.WidthIncludingTrailingWhitespace),
            Math.Max(text.Height, mark.FontSize)));
        return Rect.Inflate(bounds, 6, 4);
    }

    private static void DrawText(DrawingContext dc, Mark mark, Point origin, double scale)
    {
        double fontSize = Math.Max(6, mark.FontSize * scale);
        FormattedText text = Format(mark.Text, fontSize, 1);
        text.SetForegroundBrush(new SolidColorBrush(mark.Color));
        dc.DrawText(text, origin);
    }

    private static FormattedText Format(string value, double fontSize, double pixelsPerDip)
    {
        return new FormattedText(
            value,
            CultureInfo.CurrentUICulture,
            FlowDirection.LeftToRight,
            new Typeface(LabelFont, FontStyles.Normal, FontWeights.Normal, FontStretches.Normal),
            fontSize,
            Brushes.Black,
            pixelsPerDip);
    }

    private static void DrawMosaic(DrawingContext dc, Point[] points, Size canvas, BitmapSource? pixelated)
    {
        Rect area = points.Length >= 2 ? Normalize(points[0], points[1]) : default;
        if (area.Width < 1 || area.Height < 1) return;

        dc.PushClip(new RectangleGeometry(area));
        if (pixelated != null)
        {
            dc.DrawImage(pixelated, new Rect(0, 0, canvas.Width, canvas.Height));
        }
        else
        {
            dc.DrawRectangle(new SolidColorBrush(Color.FromArgb(190, 64, 64, 64)), null, area);
        }
        dc.Pop();
    }
}
